#include "udpipe_parser_v3_core.h"

#include <algorithm>
#include <fstream>
#include <iomanip>
#include <memory>
#include <mutex>
#include <sstream>
#include <utility>
#include <vector>

#include "model/model.h"
#include "model/model_morphodita_parsito.h"
#include "sentence/input_format.h"
#include "sentence/sentence.h"
#include "unilib/utf8.h"

namespace tomato_udpipe_v3 {
namespace {

using ufal::udpipe::input_format;
using ufal::udpipe::model;
using ufal::udpipe::model_morphodita_parsito;
using ufal::udpipe::sentence;
using ufal::udpipe::string_piece;

std::mutex g_model_mutex;
std::string g_model_path;
std::unique_ptr<model> g_model;

std::string EscapeJson(const std::string& value) {
  std::ostringstream output;
  for (const unsigned char character : value) {
    switch (character) {
      case '"':
        output << "\\\"";
        break;
      case '\\':
        output << "\\\\";
        break;
      case '\b':
        output << "\\b";
        break;
      case '\f':
        output << "\\f";
        break;
      case '\n':
        output << "\\n";
        break;
      case '\r':
        output << "\\r";
        break;
      case '\t':
        output << "\\t";
        break;
      default:
        if (character < 0x20) {
          const char* digits = "0123456789abcdef";
          output << "\\u00" << digits[(character >> 4) & 0x0f]
                 << digits[character & 0x0f];
        } else {
          output << static_cast<char>(character);
        }
    }
  }
  return output.str();
}

struct UnicodeOffsets {
  std::vector<size_t> codepoint_to_byte;
  std::vector<size_t> codepoint_to_utf16;
};

UnicodeOffsets BuildUnicodeOffsets(const std::string& text) {
  UnicodeOffsets offsets;
  offsets.codepoint_to_byte.push_back(0);
  offsets.codepoint_to_utf16.push_back(0);
  string_piece remaining(text);
  size_t byte_offset = 0;
  size_t utf16_offset = 0;
  while (remaining.len > 0) {
    const size_t before = remaining.len;
    const char32_t codepoint =
        ufal::udpipe::unilib::utf8::decode(remaining.str, remaining.len);
    const size_t consumed = before - remaining.len;
    if (consumed == 0) {
      break;
    }
    byte_offset += consumed;
    utf16_offset += codepoint > 0xffff ? 2 : 1;
    offsets.codepoint_to_byte.push_back(byte_offset);
    offsets.codepoint_to_utf16.push_back(utf16_offset);
  }
  return offsets;
}

bool ExactCodepointIndexForByte(const UnicodeOffsets& offsets,
                                size_t byte_offset,
                                size_t* codepoint_index) {
  const auto found = std::lower_bound(offsets.codepoint_to_byte.begin(),
                                      offsets.codepoint_to_byte.end(),
                                      byte_offset);
  if (found == offsets.codepoint_to_byte.end() || *found != byte_offset) {
    return false;
  }
  *codepoint_index = static_cast<size_t>(
      std::distance(offsets.codepoint_to_byte.begin(), found));
  return true;
}

bool TokenRangeForWord(const sentence& parsed,
                       size_t word_index,
                       const std::string& source,
                       const UnicodeOffsets& offsets,
                       size_t* start,
                       size_t* end) {
  if (parsed.words[word_index].get_token_range(*start, *end)) {
    return true;
  }
  for (const auto& multiword : parsed.multiword_tokens) {
    if (static_cast<int>(word_index) >= multiword.id_first &&
        static_cast<int>(word_index) <= multiword.id_last) {
      size_t multiword_start = 0;
      size_t multiword_end = 0;
      if (!multiword.get_token_range(multiword_start, multiword_end) ||
          multiword_start >= offsets.codepoint_to_byte.size() ||
          multiword_end >= offsets.codepoint_to_byte.size()) {
        return false;
      }
      size_t cursor = offsets.codepoint_to_byte[multiword_start];
      const size_t byte_end = offsets.codepoint_to_byte[multiword_end];
      for (int component = multiword.id_first;
           component <= multiword.id_last;
           ++component) {
        const std::string& form = parsed.words[component].form;
        const size_t found = source.find(form, cursor);
        if (form.empty() || found == std::string::npos || found != cursor ||
            found + form.size() > byte_end) {
          return false;
        }
        if (static_cast<size_t>(component) == word_index) {
          return ExactCodepointIndexForByte(offsets, found, start) &&
                 ExactCodepointIndexForByte(offsets, found + form.size(), end);
        }
        cursor = found + form.size();
      }
      return false;
    }
  }
  return false;
}

model* LoadModelLocked(const std::string& model_path, std::string* error) {
  if (g_model && g_model_path == model_path) {
    return g_model.get();
  }
  std::ifstream input(model_path, std::ios::binary);
  if (!input.good()) {
    *error = "UDPipe model file cannot be opened";
    return nullptr;
  }
  std::unique_ptr<model> loaded(model::load(input));
  if (!loaded) {
    *error = "UDPipe model file cannot be loaded";
    return nullptr;
  }
  g_model_path = model_path;
  g_model = std::move(loaded);
  return g_model.get();
}

}  // namespace

ParseResult ParseToJson(const std::string& text,
                        const std::string& model_path,
                        bool presegmented) {
  if (text.empty()) {
    return {false, "", "Text is empty"};
  }
  if (model_path.empty()) {
    return {false, "", "Model path is empty"};
  }

  std::lock_guard<std::mutex> lock(g_model_mutex);
  std::string error;
  model* parser_model = LoadModelLocked(model_path, &error);
  if (!parser_model) {
    return {false, "", error};
  }

  const std::string tokenizer_options =
      presegmented
          ? model::TOKENIZER_RANGES + ";" +
                input_format::GENERIC_TOKENIZER_PRESEGMENTED
          : model::TOKENIZER_RANGES;
  std::unique_ptr<input_format> tokenizer(
      parser_model->new_tokenizer(tokenizer_options));
  if (!tokenizer) {
    return {false, "", "UDPipe tokenizer cannot be created"};
  }
  tokenizer->set_text(text, true);
  const UnicodeOffsets offsets = BuildUnicodeOffsets(text);

  std::ostringstream json;
  json << "{\"parserVersion\":\"udpipe-1.4.0\",\"healthy\":true,"
       << "\"issues\":[],\"sentences\":[";
  bool first_sentence = true;
  sentence parsed;
  while (tokenizer->next_sentence(parsed, error)) {
    if (!parser_model->tag(parsed, model::DEFAULT, error)) {
      return {false, "", "UDPipe tagging failed: " + error};
    }
    double parse_cost = 0;
    const auto* parsito_model =
        dynamic_cast<const model_morphodita_parsito*>(parser_model);
    const bool parsed_ok = parsito_model
                               ? parsito_model->parse_with_cost(
                                     parsed, model::DEFAULT, error, &parse_cost)
                               : parser_model->parse(parsed, model::DEFAULT,
                                                     error);
    if (!parsed_ok) {
      return {false, "", "UDPipe dependency parsing failed: " + error};
    }

    struct WordRange {
      size_t start;
      size_t end;
    };
    std::vector<WordRange> ranges(parsed.words.size());
    size_t sentence_start = offsets.codepoint_to_utf16.back();
    size_t sentence_end = 0;
    for (size_t index = 1; index < parsed.words.size(); ++index) {
      size_t codepoint_start = 0;
      size_t codepoint_end = 0;
      if (!TokenRangeForWord(parsed, index, text, offsets, &codepoint_start,
                             &codepoint_end) ||
          codepoint_start >= offsets.codepoint_to_utf16.size() ||
          codepoint_end >= offsets.codepoint_to_utf16.size() ||
          codepoint_end <= codepoint_start) {
        return {false, "", "UDPipe returned an unmappable token range"};
      }
      ranges[index] = {codepoint_start, codepoint_end};
      sentence_start = std::min(
          sentence_start, offsets.codepoint_to_utf16[codepoint_start]);
      sentence_end = std::max(
          sentence_end, offsets.codepoint_to_utf16[codepoint_end]);
    }

    if (!first_sentence) {
      json << ',';
    }
    first_sentence = false;
    json << "{\"start\":" << sentence_start << ",\"end\":"
         << sentence_end;
    if (parsito_model) {
      const size_t token_count = parsed.words.size() > 1
                                     ? parsed.words.size() - 1
                                     : 1;
      json << ",\"parseCost\":" << std::setprecision(17) << parse_cost
           << ",\"parseCostPerToken\":" << std::setprecision(17)
           << parse_cost / static_cast<double>(token_count);
    }
    json << ",\"tokens\":[";
    for (size_t index = 1; index < parsed.words.size(); ++index) {
      if (index > 1) {
        json << ',';
      }
      const auto& word = parsed.words[index];
      const auto range = ranges[index];
      const size_t byte_start = offsets.codepoint_to_byte[range.start];
      const size_t byte_end = offsets.codepoint_to_byte[range.end];
      const std::string source_text =
          text.substr(byte_start, byte_end - byte_start);
      json << "{\"id\":" << word.id << ",\"text\":\""
           << EscapeJson(word.form) << "\",\"sourceText\":\""
           << EscapeJson(source_text) << "\",\"start\":"
           << offsets.codepoint_to_utf16[range.start] << ",\"end\":"
           << offsets.codepoint_to_utf16[range.end] << ",\"upos\":\""
           << EscapeJson(word.upostag) << "\",\"head\":" << word.head
           << ",\"deprel\":\"" << EscapeJson(word.deprel) << "\"}";
    }
    json << "]}";
  }
  if (!error.empty()) {
    return {false, "", "UDPipe tokenization failed: " + error};
  }
  json << "]}";
  return {true, json.str(), ""};
}

}  // namespace tomato_udpipe_v3

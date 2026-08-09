#ifndef TOMATO_UDPIPE_PARSER_V3_CORE_H_
#define TOMATO_UDPIPE_PARSER_V3_CORE_H_

#include <string>

namespace tomato_udpipe_v3 {

struct ParseResult {
  bool ok;
  std::string json;
  std::string error;
};

ParseResult ParseToJson(const std::string& text,
                        const std::string& model_path,
                        bool presegmented = false);

}  // namespace tomato_udpipe_v3

#endif  // TOMATO_UDPIPE_PARSER_V3_CORE_H_

#include <fstream>
#include <iostream>
#include <sstream>
#include <string>

#include "udpipe_parser_v3_core.h"

int main(int argc, char** argv) {
  if (argc != 3 && argc != 4) {
    std::cerr << "Usage: udpipe_v3_probe MODEL_FILE UTF8_TEXT_FILE "
                 "[--presegmented]\n";
    return 64;
  }
  const bool presegmented = argc == 4 &&
                            std::string(argv[3]) == "--presegmented";
  if (argc == 4 && !presegmented) {
    std::cerr << "Unknown option: " << argv[3] << '\n';
    return 64;
  }
  std::ifstream input(argv[2], std::ios::binary);
  if (!input.good()) {
    std::cerr << "Cannot open UTF-8 text file\n";
    return 66;
  }
  std::ostringstream text;
  text << input.rdbuf();
  const tomato_udpipe_v3::ParseResult result =
      tomato_udpipe_v3::ParseToJson(text.str(), argv[1], presegmented);
  if (!result.ok) {
    std::cerr << result.error << '\n';
    return 1;
  }
  std::cout << result.json << '\n';
  return 0;
}

#include "include/udpipe_parser_v3/udpipe_parser_v3_plugin_c_api.h"

#include <flutter/method_channel.h>
#include <flutter/plugin_registrar_windows.h>
#include <flutter/standard_method_codec.h>

#include <memory>
#include <optional>
#include <string>

#include "../native/udpipe_parser_v3_core.h"

namespace {

std::optional<std::string> StringArgument(
    const flutter::EncodableMap& arguments,
    const char* name) {
  const auto iterator = arguments.find(flutter::EncodableValue(name));
  if (iterator == arguments.end()) {
    return std::nullopt;
  }
  const auto* value = std::get_if<std::string>(&iterator->second);
  return value == nullptr ? std::nullopt : std::optional<std::string>(*value);
}

bool BoolArgument(const flutter::EncodableMap& arguments,
                  const char* name,
                  bool fallback) {
  const auto iterator = arguments.find(flutter::EncodableValue(name));
  if (iterator == arguments.end()) {
    return fallback;
  }
  const auto* value = std::get_if<bool>(&iterator->second);
  return value == nullptr ? fallback : *value;
}

class UdpipeParserV3Plugin : public flutter::Plugin {
 public:
  static void RegisterWithRegistrar(
      flutter::PluginRegistrarWindows* registrar) {
    auto channel =
        std::make_unique<flutter::MethodChannel<flutter::EncodableValue>>(
            registrar->messenger(), "tomato_english/udpipe_parser_v3",
            &flutter::StandardMethodCodec::GetInstance());
    auto plugin = std::make_unique<UdpipeParserV3Plugin>();
    channel->SetMethodCallHandler(
        [plugin_pointer = plugin.get()](const auto& call, auto result) {
          plugin_pointer->HandleMethodCall(call, std::move(result));
        });
    registrar->AddPlugin(std::move(plugin));
  }

 private:
  void HandleMethodCall(
      const flutter::MethodCall<flutter::EncodableValue>& call,
      std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>> result) {
    if (call.method_name() != "parse") {
      result->NotImplemented();
      return;
    }
    const auto* arguments =
        std::get_if<flutter::EncodableMap>(call.arguments());
    if (arguments == nullptr) {
      result->Error("invalid_arguments", "Expected an argument map");
      return;
    }
    const auto text = StringArgument(*arguments, "text");
    const auto model_path = StringArgument(*arguments, "modelPath");
    if (!text.has_value() || !model_path.has_value()) {
      result->Error("invalid_arguments", "text and modelPath are required");
      return;
    }
    const bool presegmented =
        BoolArgument(*arguments, "presegmented", false);
    const tomato_udpipe_v3::ParseResult parsed =
        tomato_udpipe_v3::ParseToJson(*text, *model_path, presegmented);
    if (!parsed.ok) {
      result->Error("parse_failed", parsed.error);
      return;
    }
    result->Success(flutter::EncodableValue(parsed.json));
  }
};

}  // namespace

void UdpipeParserV3PluginCApiRegisterWithRegistrar(
    FlutterDesktopPluginRegistrarRef registrar) {
  UdpipeParserV3Plugin::RegisterWithRegistrar(
      flutter::PluginRegistrarManager::GetInstance()
          ->GetRegistrar<flutter::PluginRegistrarWindows>(registrar));
}

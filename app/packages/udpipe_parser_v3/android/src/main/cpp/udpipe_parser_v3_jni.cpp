#include <jni.h>

#include <string>

#include "udpipe_parser_v3_core.h"

namespace {

std::string FromJavaString(JNIEnv* environment, jstring value) {
  if (value == nullptr) {
    return {};
  }
  const char* utf8 = environment->GetStringUTFChars(value, nullptr);
  if (utf8 == nullptr) {
    return {};
  }
  std::string result(utf8);
  environment->ReleaseStringUTFChars(value, utf8);
  return result;
}

}  // namespace

extern "C" JNIEXPORT jstring JNICALL
Java_com_example_udpipe_1parser_1v3_UdpipeParserV3Plugin_parseNative(
    JNIEnv* environment,
    jobject,
    jstring text,
    jstring model_path,
    jboolean presegmented) {
  const tomato_udpipe_v3::ParseResult parsed =
      tomato_udpipe_v3::ParseToJson(FromJavaString(environment, text),
                                    FromJavaString(environment, model_path),
                                    presegmented == JNI_TRUE);
  if (!parsed.ok) {
    jclass exception_class = environment->FindClass("java/lang/Exception");
    environment->ThrowNew(exception_class, parsed.error.c_str());
    return nullptr;
  }
  return environment->NewStringUTF(parsed.json.c_str());
}

#include "tracker_decoder.h"

#include <jni.h>

#include <string>

namespace {
std::string ToUtf8(JNIEnv* env, jstring value) {
  if (value == nullptr) return {};
  const char* chars = env->GetStringUTFChars(value, nullptr);
  if (chars == nullptr) return {};
  std::string result(chars);
  env->ReleaseStringUTFChars(value, chars);
  return result;
}
}  // namespace

extern "C" JNIEXPORT jobjectArray JNICALL
Java_com_neonamp_neonamp_MainActivity_nativeReadTrackerInfo(
    JNIEnv* env,
    jobject /* instance */,
    jstring input_path) {
  TrackerModuleInfo info;
  std::string error;
  if (!ReadTrackerModuleInfo(ToUtf8(env, input_path), &info, &error)) {
    return nullptr;
  }
  jclass string_class = env->FindClass("java/lang/String");
  if (string_class == nullptr) return nullptr;
  jobjectArray result = env->NewObjectArray(2, string_class, nullptr);
  if (result == nullptr) return nullptr;
  const jstring title = env->NewStringUTF(info.title.c_str());
  const jstring format = env->NewStringUTF(info.format.c_str());
  if (title == nullptr || format == nullptr) return nullptr;
  env->SetObjectArrayElement(result, 0, title);
  env->SetObjectArrayElement(result, 1, format);
  env->DeleteLocalRef(title);
  env->DeleteLocalRef(format);
  return result;
}

extern "C" JNIEXPORT jboolean JNICALL
Java_com_neonamp_neonamp_MainActivity_nativeRenderTrackerToWav(
    JNIEnv* env,
    jobject /* instance */,
    jstring input_path,
    jstring output_path) {
  std::string error;
  return RenderTrackerModuleToWav(ToUtf8(env, input_path),
                                 ToUtf8(env, output_path), &error);
}

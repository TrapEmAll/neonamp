#ifndef RUNNER_FLUTTER_WINDOW_H_
#define RUNNER_FLUTTER_WINDOW_H_

#include <flutter/dart_project.h>
#include <flutter/method_channel.h>
#include <flutter/flutter_view_controller.h>
#include <flutter/standard_method_codec.h>

#include <winrt/Windows.Media.h>
#include <winrt/Windows.Foundation.h>
#include <winrt/base.h>

#include <memory>

#include "win32_window.h"

// A window that does nothing but host a Flutter view.
class FlutterWindow : public Win32Window {
 public:
  // Creates a new FlutterWindow hosting a Flutter view running |project|.
  explicit FlutterWindow(const flutter::DartProject& project);
  virtual ~FlutterWindow();

 protected:
  // Win32Window:
  bool OnCreate() override;
  void OnDestroy() override;
  LRESULT MessageHandler(HWND window, UINT const message, WPARAM const wparam,
                         LPARAM const lparam) noexcept override;

  void InitializeSystemMediaControls();
  void UpdateSystemMediaControls(const flutter::EncodableMap& values);

 private:
  // The project to run.
  flutter::DartProject project_;

  // The Flutter instance hosted by this window.
  std::unique_ptr<flutter::FlutterViewController> flutter_controller_;

  // Receives native Windows media-key messages and forwards them to Dart.
  std::unique_ptr<flutter::MethodChannel<flutter::EncodableValue>>
      system_controls_channel_;

  winrt::Windows::Media::SystemMediaTransportControls system_media_controls_{
      nullptr};
  winrt::event_token system_media_button_token_{};
};

#endif  // RUNNER_FLUTTER_WINDOW_H_

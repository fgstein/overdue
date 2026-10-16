#ifndef RUNNER_FLUTTER_WINDOW_H_
#define RUNNER_FLUTTER_WINDOW_H_

#include <flutter/dart_project.h>
#include <flutter/flutter_view_controller.h>
#include <flutter/method_channel.h>

#include <memory>

#include "tray_icon.h"
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

 private:
  // The project to run.
  flutter::DartProject project_;

  // The Flutter instance hosted by this window.
  std::unique_ptr<flutter::FlutterViewController> flutter_controller_;

  // System-wide "new task" shortcut (Ctrl+Alt+N), see flutter_window.cpp.
  std::unique_ptr<flutter::MethodChannel<flutter::EncodableValue>> hotkey_channel_;
  bool hotkey_registered_ = false;

  // Window placement helpers and the notification-area icon (Dart drives
  // both, see lib/src/platform/desktop/native_window.dart and tray.dart).
  std::unique_ptr<flutter::MethodChannel<flutter::EncodableValue>> window_channel_;
  std::unique_ptr<flutter::MethodChannel<flutter::EncodableValue>> tray_channel_;
  std::unique_ptr<TrayIcon> tray_;
};

#endif  // RUNNER_FLUTTER_WINDOW_H_

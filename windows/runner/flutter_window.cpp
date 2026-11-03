#include "flutter_window.h"

#include <flutter/standard_method_codec.h>

#include <optional>
#include <variant>

#include "flutter/generated_plugin_registrant.h"

FlutterWindow::FlutterWindow(const flutter::DartProject& project)
    : project_(project) {}

FlutterWindow::~FlutterWindow() {}

bool FlutterWindow::OnCreate() {
  if (!Win32Window::OnCreate()) {
    return false;
  }

  RECT frame = GetClientArea();

  // The size here must match the window dimensions to avoid unnecessary surface
  // creation / destruction in the startup path.
  flutter_controller_ = std::make_unique<flutter::FlutterViewController>(
      frame.right - frame.left, frame.bottom - frame.top, project_);
  // Ensure that basic setup of the controller was successful.
  if (!flutter_controller_->engine() || !flutter_controller_->view()) {
    return false;
  }
  RegisterPlugins(flutter_controller_->engine());

  window_channel_ = std::make_unique<flutter::MethodChannel<flutter::EncodableValue>>(
      flutter_controller_->engine()->messenger(), "mw75_bench/window",
      &flutter::StandardMethodCodec::GetInstance());
  window_channel_->SetMethodCallHandler(
      [this](const flutter::MethodCall<flutter::EncodableValue>& call,
             std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>> result) {
        if (call.method_name() != "setFullScreen") {
          result->NotImplemented();
          return;
        }
        bool wanted = false;
        if (const auto* args = std::get_if<flutter::EncodableMap>(call.arguments())) {
          auto it = args->find(flutter::EncodableValue("value"));
          if (it != args->end()) {
            if (const auto* value = std::get_if<bool>(&it->second)) {
              wanted = *value;
            }
          }
        }
        SetFullScreen(wanted);
        result->Success();
      });
  SetChildContent(flutter_controller_->view()->GetNativeWindow());

  flutter_controller_->engine()->SetNextFrameCallback([&]() {
    this->Show();
  });

  // Flutter can complete the first frame before the "show window" callback is
  // registered. The following call ensures a frame is pending to ensure the
  // window is shown. It is a no-op if the first frame hasn't completed yet.
  flutter_controller_->ForceRedraw();

  return true;
}

void FlutterWindow::SetFullScreen(bool full_screen) {
  HWND hwnd = GetHandle();
  if (hwnd == nullptr || full_screen == full_screen_) {
    return;
  }
  LONG_PTR style = GetWindowLongPtr(hwnd, GWL_STYLE);
  if (full_screen) {
    MONITORINFO monitor = {sizeof(MONITORINFO)};
    if (!GetWindowPlacement(hwnd, &placement_before_full_screen_) ||
        !GetMonitorInfo(MonitorFromWindow(hwnd, MONITOR_DEFAULTTONEAREST), &monitor)) {
      return;
    }
    SetWindowLongPtr(hwnd, GWL_STYLE, style & ~WS_OVERLAPPEDWINDOW);
    const RECT& r = monitor.rcMonitor;
    SetWindowPos(hwnd, HWND_TOP, r.left, r.top, r.right - r.left, r.bottom - r.top,
                 SWP_NOOWNERZORDER | SWP_FRAMECHANGED);
  } else {
    SetWindowLongPtr(hwnd, GWL_STYLE, style | WS_OVERLAPPEDWINDOW);
    SetWindowPlacement(hwnd, &placement_before_full_screen_);
    SetWindowPos(hwnd, nullptr, 0, 0, 0, 0,
                 SWP_NOMOVE | SWP_NOSIZE | SWP_NOZORDER | SWP_NOOWNERZORDER | SWP_FRAMECHANGED);
  }
  full_screen_ = full_screen;
}

void FlutterWindow::OnDestroy() {
  window_channel_ = nullptr;
  if (flutter_controller_) {
    flutter_controller_ = nullptr;
  }

  Win32Window::OnDestroy();
}

LRESULT
FlutterWindow::MessageHandler(HWND hwnd, UINT const message,
                              WPARAM const wparam,
                              LPARAM const lparam) noexcept {
  // Give Flutter, including plugins, an opportunity to handle window messages.
  if (flutter_controller_) {
    std::optional<LRESULT> result =
        flutter_controller_->HandleTopLevelWindowProc(hwnd, message, wparam,
                                                      lparam);
    if (result) {
      return *result;
    }
  }

  switch (message) {
    case WM_FONTCHANGE:
      flutter_controller_->engine()->ReloadSystemFonts();
      break;
  }

  return Win32Window::MessageHandler(hwnd, message, wparam, lparam);
}

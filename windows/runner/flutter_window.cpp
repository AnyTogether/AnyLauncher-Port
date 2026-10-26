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
  SetChildContent(flutter_controller_->view()->GetNativeWindow());

  window_channel_ =
      std::make_unique<flutter::MethodChannel<flutter::EncodableValue>>(
          flutter_controller_->engine()->messenger(), "anyps5/window",
          &flutter::StandardMethodCodec::GetInstance());
  window_channel_->SetMethodCallHandler(
      [this](const flutter::MethodCall<flutter::EncodableValue>& call,
             std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>>
                 result) {
        if (call.method_name() == "setFullscreen") {
          const auto* on = std::get_if<bool>(call.arguments());
          if (on == nullptr) {
            result->Error("bad_arguments", "setFullscreen takes a bool");
            return;
          }
          result->Success(flutter::EncodableValue(SetFullscreen(*on)));
          return;
        }
        result->NotImplemented();
      });

  flutter_controller_->engine()->SetNextFrameCallback([&]() {
    this->Show();
  });

  // Flutter can complete the first frame before the "show window" callback is
  // registered. The following call ensures a frame is pending to ensure the
  // window is shown. It is a no-op if the first frame hasn't completed yet.
  flutter_controller_->ForceRedraw();

  return true;
}

bool FlutterWindow::SetFullscreen(bool on) {
  HWND hwnd = GetHandle();
  if (hwnd == nullptr) {
    return false;
  }
  if (on == fullscreen_) {
    return true;
  }
  if (on) {
    MONITORINFO monitor{sizeof(MONITORINFO)};
    if (!::GetMonitorInfo(::MonitorFromWindow(hwnd, MONITOR_DEFAULTTONEAREST),
                          &monitor)) {
      return false;
    }
    windowed_style_ = ::GetWindowLongPtr(hwnd, GWL_STYLE);
    windowed_placement_.length = sizeof(WINDOWPLACEMENT);
    ::GetWindowPlacement(hwnd, &windowed_placement_);
    ::SetWindowLongPtr(hwnd, GWL_STYLE,
                       (windowed_style_ & ~WS_OVERLAPPEDWINDOW) | WS_POPUP);
    const RECT& area = monitor.rcMonitor;
    ::SetWindowPos(hwnd, HWND_TOP, area.left, area.top,
                   area.right - area.left, area.bottom - area.top,
                   SWP_FRAMECHANGED | SWP_NOOWNERZORDER);
  } else {
    ::SetWindowLongPtr(hwnd, GWL_STYLE,
                       windowed_style_ != 0
                           ? windowed_style_
                           : ((::GetWindowLongPtr(hwnd, GWL_STYLE) & ~WS_POPUP) |
                              WS_OVERLAPPEDWINDOW));
    if (windowed_placement_.length == sizeof(WINDOWPLACEMENT)) {
      ::SetWindowPlacement(hwnd, &windowed_placement_);
    }
    ::SetWindowPos(hwnd, nullptr, 0, 0, 0, 0,
                   SWP_NOMOVE | SWP_NOSIZE | SWP_NOZORDER | SWP_NOOWNERZORDER |
                       SWP_FRAMECHANGED);
  }
  fullscreen_ = on;
  return true;
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

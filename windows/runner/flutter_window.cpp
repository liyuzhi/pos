#include "flutter_window.h"

#include <optional>
#include <windows.h>

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
  RegisterWindowMethodChannel();
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

void FlutterWindow::OnDestroy() {
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

void FlutterWindow::RegisterWindowMethodChannel() {
  window_channel_ =
      std::make_unique<flutter::MethodChannel<flutter::EncodableValue>>(
          flutter_controller_->engine()->messenger(), "pos/window",
          &flutter::StandardMethodCodec::GetInstance());

  window_channel_->SetMethodCallHandler(
      [this](const flutter::MethodCall<flutter::EncodableValue>& call,
             std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>>
                 result) {
        if (call.method_name() == "enterFullscreen") {
          // Flutter 侧按钮触发真正的 Win32 无边框全屏，而不是只改 Dart UI。
          result->Success(flutter::EncodableValue(EnterFullscreen()));
          return;
        }
        if (call.method_name() == "exitFullscreen") {
          // 退出全屏时恢复进入全屏前保存的窗口样式和位置。
          result->Success(flutter::EncodableValue(ExitFullscreen()));
          return;
        }
        if (call.method_name() == "isFullscreen") {
          // 让 Dart 初始化时同步原生窗口状态，保证按钮启用状态正确。
          result->Success(flutter::EncodableValue(is_fullscreen_));
          return;
        }
        if (call.method_name() == "getWindowRect") {
          // Dart 侧会把这个物理屏幕坐标和触摸键盘窗口坐标相交，
          // 用于计算停靠触摸键盘遮挡的真实高度。
          RECT rect;
          if (!GetWindowRect(GetHandle(), &rect)) {
            result->Success(flutter::EncodableValue());
            return;
          }

          flutter::EncodableList rect_value = {
              flutter::EncodableValue(static_cast<int>(rect.left)),
              flutter::EncodableValue(static_cast<int>(rect.top)),
              flutter::EncodableValue(static_cast<int>(rect.right)),
              flutter::EncodableValue(static_cast<int>(rect.bottom)),
          };
          result->Success(flutter::EncodableValue(rect_value));
          return;
        }

        result->NotImplemented();
      });
}

bool FlutterWindow::EnterFullscreen() {
  if (is_fullscreen_) {
    return true;
  }

  HWND window = GetHandle();
  if (window == nullptr) {
    return false;
  }

  previous_style_ = GetWindowLongPtr(window, GWL_STYLE);
  previous_ex_style_ = GetWindowLongPtr(window, GWL_EXSTYLE);
  previous_placement_.length = sizeof(WINDOWPLACEMENT);

  // 保存当前窗口位置，退出全屏时原样恢复。
  MONITORINFO monitor_info = {sizeof(MONITORINFO)};
  if (!GetWindowPlacement(window, &previous_placement_) ||
      !GetMonitorInfo(MonitorFromWindow(window, MONITOR_DEFAULTTONEAREST),
                      &monitor_info)) {
    return false;
  }

  // 去掉标题栏和边框，覆盖当前显示器区域。
  SetWindowLongPtr(window, GWL_STYLE,
                   previous_style_ & ~static_cast<LONG_PTR>(WS_OVERLAPPEDWINDOW));
  SetWindowLongPtr(window, GWL_EXSTYLE,
                   previous_ex_style_ &
                       ~static_cast<LONG_PTR>(WS_EX_DLGMODALFRAME |
                                              WS_EX_WINDOWEDGE |
                                              WS_EX_CLIENTEDGE |
                                              WS_EX_STATICEDGE));

  const RECT& monitor = monitor_info.rcMonitor;
  SetWindowPos(window, HWND_TOP, monitor.left, monitor.top,
               monitor.right - monitor.left, monitor.bottom - monitor.top,
               SWP_NOOWNERZORDER | SWP_FRAMECHANGED);
  is_fullscreen_ = true;
  return true;
}

bool FlutterWindow::ExitFullscreen() {
  if (!is_fullscreen_) {
    return true;
  }

  HWND window = GetHandle();
  if (window == nullptr) {
    return false;
  }

  // 恢复全屏前的样式、扩展样式和窗口位置。
  SetWindowLongPtr(window, GWL_STYLE, previous_style_);
  SetWindowLongPtr(window, GWL_EXSTYLE, previous_ex_style_);
  SetWindowPlacement(window, &previous_placement_);
  SetWindowPos(window, nullptr, 0, 0, 0, 0,
               SWP_NOMOVE | SWP_NOSIZE | SWP_NOZORDER | SWP_NOOWNERZORDER |
                   SWP_FRAMECHANGED);
  is_fullscreen_ = false;
  return true;
}

#include "win32_window.h"

#include <algorithm>
#include <cwchar>
#include <dwmapi.h>
#include <flutter_windows.h>
#include <tlhelp32.h>

#include "resource.h"

namespace {

/// Window attribute that enables dark mode window decorations.
///
/// Redefined in case the developer's machine has a Windows SDK older than
/// version 10.0.22000.0.
/// See: https://docs.microsoft.com/windows/win32/api/dwmapi/ne-dwmapi-dwmwindowattribute
#ifndef DWMWA_USE_IMMERSIVE_DARK_MODE
#define DWMWA_USE_IMMERSIVE_DARK_MODE 20
#endif

constexpr const wchar_t kWindowClassName[] = L"FLUTTER_RUNNER_WIN32_WINDOW";

/// Registry key for app theme preference.
///
/// A value of 0 indicates apps should use dark mode. A non-zero or missing
/// value indicates apps should use light mode.
constexpr const wchar_t kGetPreferredBrightnessRegKey[] =
  L"Software\\Microsoft\\Windows\\CurrentVersion\\Themes\\Personalize";
constexpr const wchar_t kGetPreferredBrightnessRegValue[] = L"AppsUseLightTheme";

// The number of Win32Window objects that currently exist.
static int g_active_window_count = 0;

using EnableNonClientDpiScaling = BOOL __stdcall(HWND hwnd);

struct ChildProcessWindowContext {
  DWORD owner_process_id;
  std::vector<HWND>* windows;
  bool has_host_rect;
  RECT host_rect;
};

// Scale helper to convert logical scaler values to physical using passed in
// scale factor
int Scale(int source, double scale_factor) {
  return static_cast<int>(source * scale_factor);
}

// Dynamically loads the |EnableNonClientDpiScaling| from the User32 module.
// This API is only needed for PerMonitor V1 awareness mode.
void EnableFullDpiSupportIfAvailable(HWND hwnd) {
  HMODULE user32_module = LoadLibraryA("User32.dll");
  if (!user32_module) {
    return;
  }
  auto enable_non_client_dpi_scaling =
      reinterpret_cast<EnableNonClientDpiScaling*>(
          GetProcAddress(user32_module, "EnableNonClientDpiScaling"));
  if (enable_non_client_dpi_scaling != nullptr) {
    enable_non_client_dpi_scaling(hwnd);
  }
  FreeLibrary(user32_module);
}

DWORD GetParentProcessId(DWORD process_id) {
  DWORD parent_process_id = 0;
  HANDLE snapshot = CreateToolhelp32Snapshot(TH32CS_SNAPPROCESS, 0);
  if (snapshot == INVALID_HANDLE_VALUE) {
    return parent_process_id;
  }

  PROCESSENTRY32 entry;
  entry.dwSize = sizeof(PROCESSENTRY32);
  if (Process32First(snapshot, &entry)) {
    do {
      if (entry.th32ProcessID == process_id) {
        parent_process_id = entry.th32ParentProcessID;
        break;
      }
    } while (Process32Next(snapshot, &entry));
  }

  CloseHandle(snapshot);
  return parent_process_id;
}

bool IsDescendantProcess(DWORD process_id, DWORD ancestor_process_id) {
  DWORD current_process_id = process_id;
  for (int depth = 0; depth < 32 && current_process_id != 0; ++depth) {
    DWORD parent_process_id = GetParentProcessId(current_process_id);
    if (parent_process_id == ancestor_process_id) {
      return true;
    }
    if (parent_process_id == 0 || parent_process_id == current_process_id) {
      return false;
    }
    current_process_id = parent_process_id;
  }
  return false;
}

bool IsProcessNamed(DWORD process_id, const wchar_t* expected_name) {
  bool matches = false;
  HANDLE snapshot = CreateToolhelp32Snapshot(TH32CS_SNAPPROCESS, 0);
  if (snapshot == INVALID_HANDLE_VALUE) {
    return matches;
  }

  PROCESSENTRY32 entry;
  entry.dwSize = sizeof(PROCESSENTRY32);
  if (Process32First(snapshot, &entry)) {
    do {
      if (entry.th32ProcessID == process_id) {
        matches = _wcsicmp(entry.szExeFile, expected_name) == 0;
        break;
      }
    } while (Process32Next(snapshot, &entry));
  }

  CloseHandle(snapshot);
  return matches;
}

bool RectsOverlap(const RECT& a, const RECT& b) {
  return std::max(a.left, b.left) < std::min(a.right, b.right) &&
         std::max(a.top, b.top) < std::min(a.bottom, b.bottom);
}

bool IsChromeWindowClass(HWND window) {
  wchar_t class_name[256] = {};
  if (GetClassName(window, class_name,
                   static_cast<int>(sizeof(class_name) / sizeof(class_name[0]))) ==
      0) {
    return false;
  }
  return std::wcsncmp(class_name, L"Chrome_", 7) == 0;
}

BOOL CALLBACK CollectVisibleChildProcessWebViewWindows(HWND window,
                                                       LPARAM lparam) {
  auto* context = reinterpret_cast<ChildProcessWindowContext*>(lparam);
  DWORD process_id = 0;
  GetWindowThreadProcessId(window, &process_id);
  if (process_id == 0 || process_id == context->owner_process_id ||
      !IsChromeWindowClass(window) || !IsWindowVisible(window)) {
    return TRUE;
  }

  RECT rect = {};
  GetWindowRect(window, &rect);
  if ((rect.right - rect.left) <= 0 || (rect.bottom - rect.top) <= 0) {
    return TRUE;
  }

  const bool belongs_to_owner_process =
      IsDescendantProcess(process_id, context->owner_process_id);
  const bool is_overlapping_webview2 =
      context->has_host_rect &&
      IsProcessNamed(process_id, L"msedgewebview2.exe") &&
      RectsOverlap(rect, context->host_rect);
  if (!belongs_to_owner_process && !is_overlapping_webview2) {
    return TRUE;
  }

  if (std::find(context->windows->begin(), context->windows->end(), window) ==
      context->windows->end()) {
    context->windows->push_back(window);
  }
  return TRUE;
}

}  // namespace

// Manages the Win32Window's window class registration.
class WindowClassRegistrar {
 public:
  ~WindowClassRegistrar() = default;

  // Returns the singleton registrar instance.
  static WindowClassRegistrar* GetInstance() {
    if (!instance_) {
      instance_ = new WindowClassRegistrar();
    }
    return instance_;
  }

  // Returns the name of the window class, registering the class if it hasn't
  // previously been registered.
  const wchar_t* GetWindowClass();

  // Unregisters the window class. Should only be called if there are no
  // instances of the window.
  void UnregisterWindowClass();

 private:
  WindowClassRegistrar() = default;

  static WindowClassRegistrar* instance_;

  bool class_registered_ = false;
};

WindowClassRegistrar* WindowClassRegistrar::instance_ = nullptr;

const wchar_t* WindowClassRegistrar::GetWindowClass() {
  if (!class_registered_) {
    WNDCLASS window_class{};
    window_class.hCursor = LoadCursor(nullptr, IDC_ARROW);
    window_class.lpszClassName = kWindowClassName;
    window_class.style = CS_HREDRAW | CS_VREDRAW;
    window_class.cbClsExtra = 0;
    window_class.cbWndExtra = 0;
    window_class.hInstance = GetModuleHandle(nullptr);
    window_class.hIcon =
        LoadIcon(window_class.hInstance, MAKEINTRESOURCE(IDI_APP_ICON));
    window_class.hbrBackground = reinterpret_cast<HBRUSH>(COLOR_WINDOW + 1);
    window_class.lpszMenuName = nullptr;
    window_class.lpfnWndProc = Win32Window::WndProc;
    RegisterClass(&window_class);
    class_registered_ = true;
  }
  return kWindowClassName;
}

void WindowClassRegistrar::UnregisterWindowClass() {
  UnregisterClass(kWindowClassName, nullptr);
  class_registered_ = false;
}

Win32Window::Win32Window() {
  ++g_active_window_count;
}

Win32Window::~Win32Window() {
  --g_active_window_count;
  Destroy();
}

bool Win32Window::Create(const std::wstring& title,
                         const Point& origin,
                         const Size& size) {
  Destroy();

  const wchar_t* window_class =
      WindowClassRegistrar::GetInstance()->GetWindowClass();

  const POINT target_point = {static_cast<LONG>(origin.x),
                              static_cast<LONG>(origin.y)};
  HMONITOR monitor = MonitorFromPoint(target_point, MONITOR_DEFAULTTONEAREST);
  UINT dpi = FlutterDesktopGetDpiForMonitor(monitor);
  double scale_factor = dpi / 96.0;

  HWND window = CreateWindow(
      window_class, title.c_str(), WS_OVERLAPPEDWINDOW,
      Scale(origin.x, scale_factor), Scale(origin.y, scale_factor),
      Scale(size.width, scale_factor), Scale(size.height, scale_factor),
      nullptr, nullptr, GetModuleHandle(nullptr), this);

  if (!window) {
    return false;
  }

  UpdateTheme(window);

  return OnCreate();
}

bool Win32Window::Show() {
  has_been_shown_ = true;
  return ShowWindow(window_handle_, SW_SHOWNORMAL);
}

// static
LRESULT CALLBACK Win32Window::WndProc(HWND const window,
                                      UINT const message,
                                      WPARAM const wparam,
                                      LPARAM const lparam) noexcept {
  if (message == WM_NCCREATE) {
    auto window_struct = reinterpret_cast<CREATESTRUCT*>(lparam);
    SetWindowLongPtr(window, GWLP_USERDATA,
                     reinterpret_cast<LONG_PTR>(window_struct->lpCreateParams));

    auto that = static_cast<Win32Window*>(window_struct->lpCreateParams);
    EnableFullDpiSupportIfAvailable(window);
    that->window_handle_ = window;
  } else if (Win32Window* that = GetThisFromHandle(window)) {
    return that->MessageHandler(window, message, wparam, lparam);
  }

  return DefWindowProc(window, message, wparam, lparam);
}

LRESULT
Win32Window::MessageHandler(HWND hwnd,
                            UINT const message,
                            WPARAM const wparam,
                            LPARAM const lparam) noexcept {
  switch (message) {
    case WM_DESTROY:
      window_handle_ = nullptr;
      Destroy();
      if (quit_on_close_) {
        PostQuitMessage(0);
      }
      return 0;

    case WM_DPICHANGED: {
      auto newRectSize = reinterpret_cast<RECT*>(lparam);
      LONG newWidth = newRectSize->right - newRectSize->left;
      LONG newHeight = newRectSize->bottom - newRectSize->top;

      SetWindowPos(hwnd, nullptr, newRectSize->left, newRectSize->top, newWidth,
                   newHeight, SWP_NOZORDER | SWP_NOACTIVATE);

      return 0;
    }
    case WM_SIZE: {
      SyncChildProcessWindows(wparam != SIZE_MINIMIZED);
      RECT rect = GetClientArea();
      if (child_content_ != nullptr) {
        // Size and position the child window.
        MoveWindow(child_content_, rect.left, rect.top, rect.right - rect.left,
                   rect.bottom - rect.top, TRUE);
      }
      return 0;
    }

    case WM_SHOWWINDOW:
      SyncChildProcessWindows(wparam != FALSE);
      break;

    case WM_WINDOWPOSCHANGED:
      SyncChildProcessWindows(IsWindowVisible(hwnd) && !IsIconic(hwnd));
      break;

    case WM_ACTIVATE:
      if (child_content_ != nullptr) {
        SetFocus(child_content_);
      }
      return 0;

    case WM_DWMCOLORIZATIONCOLORCHANGED:
      UpdateTheme(hwnd);
      return 0;
  }

  return DefWindowProc(window_handle_, message, wparam, lparam);
}

void Win32Window::Destroy() {
  OnDestroy();

  if (window_handle_) {
    DestroyWindow(window_handle_);
    window_handle_ = nullptr;
  }
  has_been_shown_ = false;
  if (g_active_window_count == 0) {
    WindowClassRegistrar::GetInstance()->UnregisterWindowClass();
  }
}

Win32Window* Win32Window::GetThisFromHandle(HWND const window) noexcept {
  return reinterpret_cast<Win32Window*>(
      GetWindowLongPtr(window, GWLP_USERDATA));
}

void Win32Window::SetChildContent(HWND content) {
  child_content_ = content;
  SetParent(content, window_handle_);
  RECT frame = GetClientArea();

  MoveWindow(content, frame.left, frame.top, frame.right - frame.left,
             frame.bottom - frame.top, true);

  SetFocus(child_content_);
}

RECT Win32Window::GetClientArea() {
  RECT frame;
  GetClientRect(window_handle_, &frame);
  return frame;
}

HWND Win32Window::GetHandle() {
  return window_handle_;
}

void Win32Window::SetQuitOnClose(bool quit_on_close) {
  quit_on_close_ = quit_on_close;
}

void Win32Window::SyncChildProcessWindows(bool host_visible) {
  if (host_visible) {
    if (window_handle_ != nullptr && IsWindow(window_handle_)) {
      RECT rect = {};
      GetWindowRect(window_handle_, &rect);
      if ((rect.right - rect.left) > 0 && (rect.bottom - rect.top) > 0 &&
          !IsIconic(window_handle_)) {
        last_visible_window_rect_ = rect;
        has_last_visible_window_rect_ = true;
      }
    }
    RestoreChildProcessWebViewWindows();
  } else if (has_been_shown_) {
    HideChildProcessWebViewWindows();
  }
}

void Win32Window::HideChildProcessWebViewWindows() {
  ChildProcessWindowContext context = {GetCurrentProcessId(),
                                       &hidden_child_process_windows_,
                                       has_last_visible_window_rect_,
                                       last_visible_window_rect_};
  EnumWindows(CollectVisibleChildProcessWebViewWindows,
              reinterpret_cast<LPARAM>(&context));
  for (HWND window : hidden_child_process_windows_) {
    if (IsWindow(window)) {
      ShowWindow(window, SW_HIDE);
    }
  }
}

void Win32Window::RestoreChildProcessWebViewWindows() {
  for (HWND window : hidden_child_process_windows_) {
    if (IsWindow(window)) {
      ShowWindow(window, SW_SHOWNA);
    }
  }
  hidden_child_process_windows_.clear();
}

bool Win32Window::OnCreate() {
  // No-op; provided for subclasses.
  return true;
}

void Win32Window::OnDestroy() {
  // No-op; provided for subclasses.
}

void Win32Window::UpdateTheme(HWND const window) {
  DWORD light_mode;
  DWORD light_mode_size = sizeof(light_mode);
  LSTATUS result = RegGetValue(HKEY_CURRENT_USER, kGetPreferredBrightnessRegKey,
                               kGetPreferredBrightnessRegValue,
                               RRF_RT_REG_DWORD, nullptr, &light_mode,
                               &light_mode_size);

  if (result == ERROR_SUCCESS) {
    BOOL enable_dark_mode = light_mode == 0;
    DwmSetWindowAttribute(window, DWMWA_USE_IMMERSIVE_DARK_MODE,
                          &enable_dark_mode, sizeof(enable_dark_mode));
  }
}

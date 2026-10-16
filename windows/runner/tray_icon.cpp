#include "tray_icon.h"

#include <shellapi.h>

#include <algorithm>

#include "resource.h"

namespace {

constexpr wchar_t kTrayWindowClass[] = L"OVERDUE_TRAY_WINDOW";
constexpr UINT kTrayCallbackMessage = WM_APP + 0x51;
constexpr UINT kTrayIconId = 1;
// Menu command ids are item ids offset by this (0 means "no choice").
constexpr UINT kMenuIdBase = 1000;

}  // namespace

TrayIcon::TrayIcon(std::function<void(int)> on_select)
    : on_select_(std::move(on_select)) {}

TrayIcon::~TrayIcon() {
  Hide();
  if (window_) {
    ::DestroyWindow(window_);
    window_ = nullptr;
  }
  if (icon_) {
    ::DestroyIcon(icon_);
    icon_ = nullptr;
  }
}

bool TrayIcon::EnsureWindow() {
  if (window_) return true;
  HINSTANCE instance = ::GetModuleHandle(nullptr);
  WNDCLASSEXW wc = {};
  wc.cbSize = sizeof(wc);
  wc.lpfnWndProc = TrayIcon::WndProc;
  wc.hInstance = instance;
  wc.lpszClassName = kTrayWindowClass;
  ::RegisterClassExW(&wc);  // Fails harmlessly when already registered.
  // A hidden top-level window (not message-only: it must be able to become
  // the foreground window so that the menu closes when clicking elsewhere).
  window_ = ::CreateWindowExW(WS_EX_TOOLWINDOW, kTrayWindowClass, L"Overdue tray",
                              WS_POPUP, 0, 0, 0, 0, nullptr, nullptr, instance,
                              this);
  if (!window_) return false;
  // Sent to top-level windows when Explorer restarts: the icon must be re-added.
  taskbar_created_message_ = ::RegisterWindowMessageW(L"TaskbarCreated");
  if (!icon_) {
    icon_ = static_cast<HICON>(::LoadImageW(
        instance, MAKEINTRESOURCEW(IDI_APP_ICON), IMAGE_ICON,
        ::GetSystemMetrics(SM_CXSMICON), ::GetSystemMetrics(SM_CYSMICON), 0));
  }
  return true;
}

bool TrayIcon::AddOrModify(bool add) {
  NOTIFYICONDATAW nid = {};
  nid.cbSize = sizeof(nid);
  nid.hWnd = window_;
  nid.uID = kTrayIconId;
  nid.uFlags = NIF_ICON | NIF_MESSAGE | NIF_TIP;
  nid.uCallbackMessage = kTrayCallbackMessage;
  nid.hIcon = icon_;
  wcsncpy_s(nid.szTip, tooltip_.c_str(), _TRUNCATE);
  return ::Shell_NotifyIconW(add ? NIM_ADD : NIM_MODIFY, &nid) != FALSE;
}

void TrayIcon::Show(const std::wstring& tooltip, std::vector<Item> items) {
  tooltip_ = tooltip;
  items_ = std::move(items);
  if (!EnsureWindow()) return;
  if (visible_) {
    if (AddOrModify(false)) return;
  }
  visible_ = AddOrModify(true);
}

void TrayIcon::Hide() {
  if (!visible_ || !window_) return;
  NOTIFYICONDATAW nid = {};
  nid.cbSize = sizeof(nid);
  nid.hWnd = window_;
  nid.uID = kTrayIconId;
  ::Shell_NotifyIconW(NIM_DELETE, &nid);
  visible_ = false;
}

void TrayIcon::ShowMenu() {
  HMENU menu = ::CreatePopupMenu();
  if (!menu) return;
  for (const Item& item : items_) {
    if (item.id < 0) {
      ::AppendMenuW(menu, MF_SEPARATOR, 0, nullptr);
    } else {
      UINT flags = MF_STRING | (item.checked ? MF_CHECKED : MF_UNCHECKED) |
                   (item.enabled ? MF_ENABLED : MF_GRAYED);
      ::AppendMenuW(menu, flags, kMenuIdBase + item.id, item.label.c_str());
    }
  }
  POINT pt;
  ::GetCursorPos(&pt);
  // Required for the menu to close when the user clicks elsewhere.
  ::SetForegroundWindow(window_);
  UINT cmd = ::TrackPopupMenu(
      menu, TPM_RETURNCMD | TPM_NONOTIFY | TPM_RIGHTBUTTON | TPM_BOTTOMALIGN,
      pt.x, pt.y, 0, window_, nullptr);
  ::PostMessage(window_, WM_NULL, 0, 0);
  ::DestroyMenu(menu);
  if (cmd >= kMenuIdBase && on_select_) {
    on_select_(static_cast<int>(cmd - kMenuIdBase));
  }
}

LRESULT CALLBACK TrayIcon::WndProc(HWND hwnd, UINT message, WPARAM wparam,
                                   LPARAM lparam) noexcept {
  if (message == WM_NCCREATE) {
    auto create = reinterpret_cast<CREATESTRUCT*>(lparam);
    ::SetWindowLongPtr(hwnd, GWLP_USERDATA,
                       reinterpret_cast<LONG_PTR>(create->lpCreateParams));
    return ::DefWindowProc(hwnd, message, wparam, lparam);
  }
  auto self =
      reinterpret_cast<TrayIcon*>(::GetWindowLongPtr(hwnd, GWLP_USERDATA));
  if (self) {
    if (message == kTrayCallbackMessage) {
      switch (LOWORD(lparam)) {
        case WM_LBUTTONUP:
        case WM_RBUTTONUP:
          self->ShowMenu();
          return 0;
      }
    } else if (message == self->taskbar_created_message_ &&
               self->taskbar_created_message_ != 0 && self->visible_) {
      self->visible_ = self->AddOrModify(true);
      return 0;
    }
  }
  return ::DefWindowProc(hwnd, message, wparam, lparam);
}

void MoveWindowToPrimaryMonitor(HWND hwnd) {
  if (::IsIconic(hwnd) || ::IsZoomed(hwnd)) ::ShowWindow(hwnd, SW_RESTORE);
  const POINT origin = {0, 0};
  HMONITOR monitor = ::MonitorFromPoint(origin, MONITOR_DEFAULTTOPRIMARY);
  MONITORINFO info = {};
  info.cbSize = sizeof(info);
  if (!::GetMonitorInfo(monitor, &info)) return;
  const RECT work = info.rcWork;
  RECT rect;
  if (!::GetWindowRect(hwnd, &rect)) return;
  const LONG work_w = work.right - work.left;
  const LONG work_h = work.bottom - work.top;
  const LONG w = std::min(rect.right - rect.left, work_w);
  const LONG h = std::min(rect.bottom - rect.top, work_h);
  ::SetWindowPos(hwnd, nullptr, work.left + (work_w - w) / 2,
                 work.top + (work_h - h) / 2, w, h,
                 SWP_NOZORDER | SWP_NOACTIVATE);
}

bool EnsureWindowOnScreen(HWND hwnd) {
  if (::IsIconic(hwnd) || !::IsWindowVisible(hwnd)) return false;
  RECT rect;
  if (!::GetWindowRect(hwnd, &rect)) return false;
  // A band along the top edge, where the window is dragged from.
  RECT top = {rect.left, rect.top, rect.right, rect.top + 30};
  HMONITOR monitor = ::MonitorFromRect(&top, MONITOR_DEFAULTTONEAREST);
  MONITORINFO info = {};
  info.cbSize = sizeof(info);
  if (::GetMonitorInfo(monitor, &info)) {
    RECT visible;
    if (::IntersectRect(&visible, &top, &info.rcWork) &&
        visible.right - visible.left >= 60 &&
        visible.bottom - visible.top >= 10) {
      return false;
    }
  }
  MoveWindowToPrimaryMonitor(hwnd);
  return true;
}

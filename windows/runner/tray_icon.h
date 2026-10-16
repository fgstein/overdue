#ifndef RUNNER_TRAY_ICON_H_
#define RUNNER_TRAY_ICON_H_

#include <windows.h>

#include <functional>
#include <string>
#include <vector>

// Notification-area ("system tray") icon with a popup menu.
//
// It owns a hidden window that receives the icon's mouse messages, so that
// showing the menu (which needs a foreground window) never activates or
// raises the visible Overdue window.
class TrayIcon {
 public:
  struct Item {
    int id = -1;  // < 0: separator.
    std::wstring label;
    bool checked = false;
    bool enabled = true;
  };

  // |on_select| receives the id of the chosen menu item.
  explicit TrayIcon(std::function<void(int)> on_select);
  ~TrayIcon();

  TrayIcon(const TrayIcon&) = delete;
  TrayIcon& operator=(const TrayIcon&) = delete;

  // Adds the icon, or updates its tooltip and menu.
  void Show(const std::wstring& tooltip, std::vector<Item> items);
  void Hide();

 private:
  static LRESULT CALLBACK WndProc(HWND hwnd, UINT message, WPARAM wparam,
                                  LPARAM lparam) noexcept;
  bool EnsureWindow();
  bool AddOrModify(bool add);
  void ShowMenu();

  std::function<void(int)> on_select_;
  HWND window_ = nullptr;
  HICON icon_ = nullptr;
  bool visible_ = false;
  std::wstring tooltip_;
  std::vector<Item> items_;
  UINT taskbar_created_message_ = 0;
};

// Moves |hwnd| to the middle of the primary monitor's work area (restoring
// it first when minimised or maximised, and shrinking it to fit).
void MoveWindowToPrimaryMonitor(HWND hwnd);

// Moves |hwnd| to the primary monitor when its top edge (where the title bar
// or the overlay's header is) is not visible on any monitor, e.g. after the
// screen it was on was disconnected. Returns whether it moved.
bool EnsureWindowOnScreen(HWND hwnd);

#endif  // RUNNER_TRAY_ICON_H_

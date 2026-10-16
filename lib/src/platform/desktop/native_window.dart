import 'dart:ffi';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:window_manager/window_manager.dart';

/// Thin native helpers that the cross-platform window plugin does not cover.
abstract final class NativeWindowHelpers {
  /// Implemented by the Windows runner (`windows/runner/tray_icon.cpp`).
  static const _window = MethodChannel('app.overdue/window');

  /// Windows only: lets the process we are about to signal (the main window)
  /// take the foreground, which Windows otherwise refuses to a background
  /// process ("focus stealing prevention"). No-op elsewhere.
  static void allowForegroundForOtherProcesses() {
    if (!Platform.isWindows) return;
    try {
      final user32 = DynamicLibrary.open('user32.dll');
      final allow = user32.lookupFunction<Int32 Function(Uint32), int Function(int)>('AllowSetForegroundWindow');
      allow(0xFFFFFFFF); // ASFW_ANY
    } catch (_) {}
  }

  /// Moves this process's window to the middle of the primary screen (e.g.
  /// when it sits on a screen that is no longer connected).
  static Future<void> moveToPrimaryScreen() async {
    try {
      await _window.invokeMethod<bool>('moveToPrimary');
    } on MissingPluginException {
      // Runner without the helper (Linux): centre on the current screen.
      try {
        if (await windowManager.isMinimized()) await windowManager.restore();
        await windowManager.center();
      } catch (_) {}
    }
  }

  /// Moves the window to the primary screen if its top edge is not visible
  /// on any screen. Returns whether it moved (always false where unsupported).
  static Future<bool> ensureOnScreen() async {
    try {
      return await _window.invokeMethod<bool>('ensureOnScreen') ?? false;
    } on MissingPluginException {
      return false;
    }
  }
}

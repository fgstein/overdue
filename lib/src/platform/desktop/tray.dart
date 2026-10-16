import 'dart:async';
import 'dart:io';

import 'package:flutter/services.dart';

import '../../data/settings_repository.dart';
import 'instance_ipc.dart';

/// Entries of the notification-area menu.
enum TrayAction {
  openMain(1),
  showOverlay(2),
  overlayOnTop(3),
  moveToPrimary(4);

  const TrayAction(this.id);
  final int id;
}

/// Windows notification-area icon ("system tray", bottom right of the
/// taskbar) with a small menu; drawn by the runner (`tray_icon.cpp`).
///
/// The main window and the overlay are separate processes that may each run
/// alone. Only the one holding the `tray` lock shows the icon; the other
/// retries periodically, so the icon survives either one closing.
class TrayMenu {
  TrayMenu({required this.dataDir, required this.settings, required this.onAction});

  final Directory dataDir;
  final AppSettings settings;
  final void Function(TrayAction action) onAction;

  static const _channel = MethodChannel('app.overdue/tray');
  Timer? _retry;
  bool _owner = false;
  bool? _shownOnTop;

  Future<void> start() async {
    _channel.setMethodCallHandler((call) async {
      if (call.method != 'select') return null;
      final action = TrayAction.values.where((a) => a.id == call.arguments).firstOrNull;
      if (action != null) onAction(action);
      return null;
    });
    settings.addListener(_onSettings);
    await _tryAcquire();
    if (!_owner) {
      _retry = Timer.periodic(const Duration(seconds: 20), (_) => unawaited(_tryAcquire()));
    }
  }

  Future<void> _tryAcquire() async {
    if (_owner) return;
    if (!await InstanceChannel(dataDir, 'tray').tryAcquire()) return;
    _owner = true;
    _retry?.cancel();
    await _show();
  }

  void _onSettings() {
    if (_owner && settings.overlayAlwaysOnTop != _shownOnTop) unawaited(_show());
  }

  Future<void> _show() async {
    final onTop = settings.overlayAlwaysOnTop;
    _shownOnTop = onTop;
    Map<String, Object> item(TrayAction a, String label, {bool checked = false}) => {
      'id': a.id,
      'label': label,
      'checked': checked,
    };
    try {
      await _channel.invokeMethod<bool>('show', {
        'tooltip': 'Overdue',
        'items': [
          item(TrayAction.openMain, 'Open Overdue'),
          item(TrayAction.showOverlay, 'Show the overlay'),
          item(TrayAction.overlayOnTop, 'Overlay always on top', checked: onTop),
          {'id': -1},
          item(TrayAction.moveToPrimary, 'Move windows to the main screen'),
        ],
      });
    } on MissingPluginException {
      dispose(); // Runner without tray support.
    }
  }

  void dispose() {
    _retry?.cancel();
    settings.removeListener(_onSettings);
  }
}

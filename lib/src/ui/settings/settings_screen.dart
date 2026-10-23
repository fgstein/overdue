import 'dart:async';
import 'dart:io';

import 'package:file_selector/file_selector.dart';
import 'package:flutter/material.dart';
import 'package:path/path.dart' as p;
import 'package:url_launcher/url_launcher.dart';

import '../../app/app_services.dart';
import '../../core/local_date.dart';
import '../../domain/experiments.dart';
import '../../services/activity_export.dart';
import '../../services/backup_service.dart';
import '../../services/mlflow/mlflow_client.dart';
import '../formatting.dart';
import '../theme.dart';

class SettingsScreen extends StatelessWidget {
  const SettingsScreen({super.key, required this.dataPath});
  final String dataPath;

  @override
  Widget build(BuildContext context) {
    final s = AppScope.of(context);
    final st = s.settings;
    final platform = s.platform;
    return Scaffold(
      appBar: AppBar(title: const Text('Settings')),
      body: ListenableBuilder(
        listenable: st,
        builder: (context, _) => Align(
          alignment: Alignment.topCenter,
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 760),
            child: ListView(
              padding: const EdgeInsets.only(bottom: 48),
              children: [
                const _Header('Agenda'),
                ListTile(
                  leading: const Icon(Icons.date_range),
                  title: const Text('Upcoming days shown'),
                  subtitle: const Text('Show tomorrow and future days below today'),
                  trailing: DropdownButton<int>(
                    value: st.upcomingDays,
                    items: const [
                      DropdownMenuItem(value: 0, child: Text('None')),
                      DropdownMenuItem(value: 1, child: Text('Tomorrow')),
                      DropdownMenuItem(value: 3, child: Text('3 days')),
                      DropdownMenuItem(value: 7, child: Text('7 days')),
                      DropdownMenuItem(value: 14, child: Text('14 days')),
                      DropdownMenuItem(value: 30, child: Text('30 days')),
                    ],
                    onChanged: (v) {
                      st.upcomingDays = v!;
                      if (v > s.tasks.lookaheadDays) s.tasks.lookaheadDays = v;
                    },
                  ),
                ),
                const _Header('Reminders'),
                SwitchListTile(
                  secondary: const Icon(Icons.notifications_outlined),
                  title: const Text('Enable notifications'),
                  subtitle: Text(
                    s.reminders.isActive
                        ? 'Local notifications only — no network involved'
                        : 'Reminders are currently delivered by the Overdue overlay process',
                  ),
                  value: st.notificationsEnabled,
                  onChanged: (v) async {
                    st.notificationsEnabled = v;
                    if (v) await s.reminders.requestPermission();
                  },
                ),
                if (!platform.isDesktop)
                  ListTile(
                    leading: const Icon(Icons.verified_user_outlined),
                    title: const Text('Check notification permission'),
                    subtitle: const Text('Allow notifications and exact alarms for on-time reminders'),
                    onTap: () async {
                      final ok = await s.reminders.requestPermission();
                      if (context.mounted) {
                        ScaffoldMessenger.of(context).showSnackBar(
                          SnackBar(content: Text(ok ? 'Notifications are allowed' : 'Notifications are not allowed')),
                        );
                      }
                    },
                  ),
                ListTile(
                  leading: const Icon(Icons.schedule),
                  title: const Text('Default reminder time'),
                  subtitle: const Text('Used for reminders relative to date-only due dates'),
                  trailing: TextButton(
                    child: Text(MinuteOfDay.format(st.defaultReminderMinute)),
                    onPressed: () async {
                      final m = st.defaultReminderMinute;
                      final t = await showTimePicker(
                        context: context,
                        initialTime: TimeOfDay(hour: m ~/ 60, minute: m % 60),
                      );
                      if (t != null) st.defaultReminderMinute = t.hour * 60 + t.minute;
                    },
                  ),
                ),
                ListTile(
                  leading: const Icon(Icons.snooze),
                  title: const Text('Snooze duration'),
                  trailing: DropdownButton<int>(
                    value: st.snoozeMinutes,
                    items: const [
                      DropdownMenuItem(value: 5, child: Text('5 min')),
                      DropdownMenuItem(value: 10, child: Text('10 min')),
                      DropdownMenuItem(value: 15, child: Text('15 min')),
                      DropdownMenuItem(value: 30, child: Text('30 min')),
                      DropdownMenuItem(value: 60, child: Text('1 hour')),
                    ],
                    onChanged: (v) => st.snoozeMinutes = v!,
                  ),
                ),
                if (platform.isDesktop) ...[
                  const _Header('Keyboard'),
                  if (platform.supportsGlobalHotkey)
                    SwitchListTile(
                      secondary: const Icon(Icons.keyboard_outlined),
                      title: const Text('Global shortcut Ctrl+Alt+N'),
                      subtitle: const Text(
                        'Opens “New task” from any application, even when Overdue is in the background',
                      ),
                      value: st.globalHotkeyEnabled,
                      onChanged: (v) => st.globalHotkeyEnabled = v,
                    )
                  else
                    ListTile(
                      leading: const Icon(Icons.keyboard_outlined),
                      title: const Text('Global “New task” shortcut'),
                      subtitle: SelectableText(
                        'Add a custom shortcut in your desktop’s keyboard settings (e.g. GNOME Settings → '
                        'Keyboard → Custom Shortcuts) that runs:\n${Platform.resolvedExecutable} --new-task',
                      ),
                    ),
                ],
                if (platform.supportsOverlay) ...[
                  const _Header('Desktop overlay'),
                  SwitchListTile(
                    secondary: const Icon(Icons.picture_in_picture_alt_outlined),
                    title: const Text('Show overlay'),
                    subtitle: const Text(
                      'Compact, movable agenda summary on the desktop, shown when Overdue starts '
                      '(its × hides it until the next start)',
                    ),
                    value: st.overlayEnabled,
                    onChanged: (v) {
                      st.overlayEnabled = v;
                      platform.setOverlayVisible(v);
                    },
                  ),
                  SwitchListTile(
                    secondary: const Icon(Icons.vertical_align_top),
                    title: const Text('Always on top'),
                    subtitle: const Text('Where the window manager allows it'),
                    value: st.overlayAlwaysOnTop,
                    onChanged: (v) => st.overlayAlwaysOnTop = v,
                  ),
                  SwitchListTile(
                    secondary: const Icon(Icons.upcoming_outlined),
                    title: const Text('Include upcoming days'),
                    value: st.overlayShowUpcoming,
                    onChanged: (v) => st.overlayShowUpcoming = v,
                  ),
                  ListTile(
                    leading: const Icon(Icons.opacity),
                    title: const Text('Overlay opacity'),
                    subtitle: Slider(
                      value: st.overlayOpacityPercent.toDouble(),
                      min: 40,
                      max: 100,
                      divisions: 12,
                      label: '${st.overlayOpacityPercent}%',
                      onChanged: (v) => st.overlayOpacityPercent = v.round(),
                    ),
                  ),
                  const _AutostartTile(),
                  ListTile(
                    leading: const Icon(Icons.desktop_windows_outlined),
                    title: const Text('Move windows to the main screen'),
                    subtitle: const Text(
                      'Brings the overlay and this window back, e.g. from a screen that is no longer connected '
                      '(also in the Overdue icon of the taskbar’s notification area on Windows)',
                    ),
                    onTap: platform.moveWindowsToPrimaryScreen,
                  ),
                ],
                const _Header('MLflow'),
                const _MlflowSection(),
                const _Header('Backups'),
                const _BackupSection(),
                const _Header('Activity export'),
                const _ActivityExportSection(),
                const _Header('Appearance'),
                ListTile(
                  leading: const Icon(Icons.brightness_6_outlined),
                  title: const Text('Theme'),
                  trailing: SegmentedButton<int>(
                    showSelectedIcon: false,
                    segments: const [
                      ButtonSegment(value: 0, label: Text('System')),
                      ButtonSegment(value: 1, label: Text('Light')),
                      ButtonSegment(value: 2, label: Text('Dark')),
                    ],
                    selected: {st.themeMode},
                    onSelectionChanged: (v) => st.themeMode = v.first,
                  ),
                ),
                ListTile(
                  leading: const Icon(Icons.density_medium),
                  title: const Text('Density'),
                  subtitle: Padding(
                    padding: const EdgeInsets.only(top: 6),
                    child: Align(
                      alignment: Alignment.centerLeft,
                      child: SegmentedButton<UiDensity>(
                        showSelectedIcon: false,
                        segments: [for (final d in UiDensity.values) ButtonSegment(value: d, label: Text(d.label))],
                        selected: {UiDensity.fromCode(st.uiDensity)},
                        onSelectionChanged: (v) => st.uiDensity = v.first.index,
                      ),
                    ),
                  ),
                ),
                const _Header('Privacy & data'),
                const ListTile(
                  leading: Icon(Icons.wifi_off),
                  title: Text('Offline, except MLflow'),
                  subtitle: Text(
                    'Overdue only connects to the MLflow server you set above, to read experiments and runs. '
                    'No accounts, sync, analytics, telemetry, crash reporting or ads. '
                    'Links in descriptions open in your own browser only when you click them.',
                  ),
                ),
                ListTile(
                  leading: const Icon(Icons.storage_outlined),
                  title: const Text('Data location'),
                  subtitle: SelectableText(dataPath),
                ),
                const AboutListTile(
                  icon: Icon(Icons.info_outline),
                  applicationName: 'Overdue',
                  applicationVersion: '1.1.0',
                  applicationLegalese: 'Offline task manager. All data stays on this device.',
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// Tracking server, token, automatic refresh and a connection test.
class _MlflowSection extends StatefulWidget {
  const _MlflowSection();
  @override
  State<_MlflowSection> createState() => _MlflowSectionState();
}

class _MlflowSectionState extends State<_MlflowSection> {
  late final _s = AppScope.of(context);
  late final _server = TextEditingController(text: _s.settings.mlflowServer);
  late final _token = TextEditingController(text: _s.settings.mlflowToken);
  String? _result;
  bool _ok = false;
  bool _testing = false;

  @override
  void dispose() {
    _server.dispose();
    _token.dispose();
    super.dispose();
  }

  void _saveServer() {
    final text = _server.text.trim();
    final normalized = MlflowServer.normalize(text);
    _s.settings.mlflowServer = normalized ?? text;
    if (normalized != null && normalized != text) _server.text = normalized;
  }

  Future<void> _test() async {
    _saveServer();
    _s.settings.mlflowToken = _token.text.trim();
    setState(() => _testing = true);
    try {
      final list = await _s.mlflow.listExperiments();
      _ok = true;
      _result = 'Connected: ${list.length} experiment${list.length == 1 ? '' : 's'}';
      unawaited(_s.mlflow.syncAll());
    } on MlflowException catch (e) {
      _ok = false;
      _result = e.message;
    }
    if (mounted) setState(() => _testing = false);
  }

  @override
  Widget build(BuildContext context) {
    final st = _s.settings;
    final scheme = Theme.of(context).colorScheme;
    final invalid = _server.text.trim().isNotEmpty && MlflowServer.normalize(_server.text) == null;
    return Column(
      children: [
        ListTile(
          leading: const Icon(Icons.dns_outlined),
          title: TextField(
            controller: _server,
            decoration: InputDecoration(
              labelText: 'Tracking server',
              hintText: 'http://localhost:5000',
              helperText: 'Runs of linked experiments are read from it. user:password@host for basic auth.',
              helperMaxLines: 2,
              errorText: invalid ? 'Not an http(s) URL' : null,
            ),
            keyboardType: TextInputType.url,
            onChanged: (_) => setState(() {}),
            onSubmitted: (_) => _saveServer(),
            onTapOutside: (_) => _saveServer(),
          ),
        ),
        ListTile(
          leading: const Icon(Icons.key_outlined),
          title: TextField(
            controller: _token,
            obscureText: true,
            decoration: const InputDecoration(
              labelText: 'Token (optional)',
              helperText: 'Sent as “Authorization: Bearer” (e.g. Databricks). Stored in the local database.',
              helperMaxLines: 2,
            ),
            onSubmitted: (v) => st.mlflowToken = v.trim(),
            onTapOutside: (_) => st.mlflowToken = _token.text.trim(),
          ),
        ),
        ListTile(
          leading: const Icon(Icons.update),
          title: const Text('Refresh runs automatically'),
          subtitle: const Text('Active experiments, while the main window is open'),
          trailing: DropdownButton<int>(
            value: const [0, 1, 2, 5, 15, 60].contains(st.mlflowRefreshMinutes) ? st.mlflowRefreshMinutes : 2,
            items: const [
              DropdownMenuItem(value: 0, child: Text('Off')),
              DropdownMenuItem(value: 1, child: Text('Every minute')),
              DropdownMenuItem(value: 2, child: Text('Every 2 min')),
              DropdownMenuItem(value: 5, child: Text('Every 5 min')),
              DropdownMenuItem(value: 15, child: Text('Every 15 min')),
              DropdownMenuItem(value: 60, child: Text('Every hour')),
            ],
            onChanged: (v) => st.mlflowRefreshMinutes = v!,
          ),
        ),
        ListTile(
          leading: const Icon(Icons.network_check),
          title: Text(
            _result ?? 'Test the connection',
            style: _result == null ? null : TextStyle(color: _ok ? Colors.green : scheme.error),
          ),
          trailing: _testing
              ? const SizedBox(width: 20, height: 20, child: CircularProgressIndicator(strokeWidth: 2))
              : OutlinedButton(onPressed: invalid ? null : _test, child: const Text('Test')),
        ),
      ],
    );
  }
}

class _Header extends StatelessWidget {
  const _Header(this.text);
  final String text;
  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.fromLTRB(16, 20, 16, 4),
    child: Text(
      text,
      style: Theme.of(context).textTheme.titleSmall?.copyWith(color: Theme.of(context).colorScheme.primary),
    ),
  );
}

class _AutostartTile extends StatefulWidget {
  const _AutostartTile();
  @override
  State<_AutostartTile> createState() => _AutostartTileState();
}

class _AutostartTileState extends State<_AutostartTile> {
  bool? _enabled;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_enabled != null) return;
    AppScope.of(context).platform.overlayAutostartEnabled().then((v) {
      if (mounted) setState(() => _enabled = v);
    });
  }

  @override
  Widget build(BuildContext context) {
    final platform = AppScope.of(context).platform;
    return SwitchListTile(
      secondary: const Icon(Icons.login),
      title: const Text('Start overlay when I log in'),
      subtitle: const Text('Per-user setting; also keeps reminders running without the main window'),
      value: _enabled ?? false,
      onChanged: _enabled == null
          ? null
          : (v) async {
              await platform.setOverlayAutostart(v);
              final now = await platform.overlayAutostartEnabled();
              if (mounted) setState(() => _enabled = now);
            },
    );
  }
}

/// Regular YAML summary of what was done, written to a chosen folder.
class _ActivityExportSection extends StatefulWidget {
  const _ActivityExportSection();
  @override
  State<_ActivityExportSection> createState() => _ActivityExportSectionState();
}

class _ActivityExportSectionState extends State<_ActivityExportSection> {
  bool _busy = false;

  void _toast(String m) {
    if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(m)));
  }

  Future<void> _set(String key, String value) async {
    final s = AppScope.of(context);
    await s.settings.setRaw(key, value);
    if (key == ActivityExportService.enabledKey && value == '1') {
      // Turning it on exports the period that just ended right away.
      try {
        final files = await s.exports.runIfDue();
        if (files.isNotEmpty) _toast('Exported ${files.map((f) => p.basename(f.path)).join(', ')}');
      } catch (e) {
        _toast('Export failed: $e');
      }
    }
    if (mounted) setState(() {});
  }

  Future<void> _exportNow() async {
    setState(() => _busy = true);
    try {
      final f = await AppScope.of(context).exports.exportNow();
      _toast('Exported ${p.basename(f.path)}');
    } catch (e) {
      _toast('Export failed: $e');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _chooseFolder() async {
    final s = AppScope.of(context);
    final path = await getDirectoryPath(confirmButtonText: 'Use this folder', initialDirectory: s.exports.folder.path);
    if (path == null) return;
    await _set(ActivityExportService.folderKey, path);
  }

  @override
  Widget build(BuildContext context) {
    final ex = AppScope.of(context).exports;
    final kind = ex.period;
    return Column(
      children: [
        SwitchListTile(
          secondary: const Icon(Icons.description_outlined),
          title: const Text('Export my activity regularly'),
          subtitle: Text(
            'A small YAML file per ${kind == ExportPeriod.month ? 'month' : 'week'} '
            '(tasks completed, postponed and created), written when the period ends',
          ),
          value: ex.enabled,
          onChanged: (v) => _set(ActivityExportService.enabledKey, v ? '1' : '0'),
        ),
        ListTile(
          leading: const Icon(Icons.date_range),
          title: const Text('Period'),
          trailing: SegmentedButton<ExportPeriod>(
            showSelectedIcon: false,
            segments: [for (final k in ExportPeriod.values) ButtonSegment(value: k, label: Text(k.label))],
            selected: {kind},
            onSelectionChanged: (v) => _set(ActivityExportService.periodKey, v.first.code),
          ),
        ),
        ListTile(
          leading: const Icon(Icons.folder_outlined),
          title: const Text('Export folder'),
          subtitle: SelectableText(ex.folder.path),
          trailing: TextButton(onPressed: _chooseFolder, child: const Text('Change')),
        ),
        ListTile(
          leading: const Icon(Icons.file_download_outlined),
          title: Text('Export ${kind == ExportPeriod.month ? 'this month' : 'this week'} so far'),
          trailing: _busy
              ? const SizedBox.square(dimension: 20, child: CircularProgressIndicator(strokeWidth: 2))
              : FilledButton.tonal(onPressed: _exportNow, child: const Text('Export now')),
        ),
      ],
    );
  }
}

class _BackupSection extends StatefulWidget {
  const _BackupSection();
  @override
  State<_BackupSection> createState() => _BackupSectionState();
}

class _BackupSectionState extends State<_BackupSection> {
  List<BackupFile>? _backups;
  bool _busy = false;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_backups == null) _refresh();
  }

  Future<void> _refresh() async {
    final list = await AppScope.of(context).backups.list();
    if (mounted) setState(() => _backups = list);
  }

  void _toast(String text) => ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(text)));

  Future<void> _backupNow() async {
    setState(() => _busy = true);
    try {
      final f = await AppScope.of(context).backups.backupNow();
      _toast('Backup saved: ${p.basename(f.path)}');
    } catch (e) {
      _toast('Backup failed: $e');
    } finally {
      if (mounted) setState(() => _busy = false);
      await _refresh();
    }
  }

  Future<void> _chooseFolder() async {
    final s = AppScope.of(context);
    final path = await getDirectoryPath(confirmButtonText: 'Use this folder', initialDirectory: s.backups.folder.path);
    if (path == null) return;
    s.settings.backupFolder = path;
    await _refresh();
  }

  Future<void> _restore() async {
    final s = AppScope.of(context);
    final backups = await s.backups.list();
    if (!mounted) return;
    if (backups.isEmpty) return _toast('No backups in ${s.backups.folder.path}');
    final chosen = await showDialog<BackupFile>(
      context: context,
      builder: (c) => SimpleDialog(
        title: const Text('Restore from backup'),
        children: [
          for (final b in backups.take(60))
            SimpleDialogOption(
              onPressed: () => Navigator.pop(c, b),
              child: ListTile(
                dense: true,
                leading: const Icon(Icons.restore),
                title: Text(b.name),
                subtitle: Text('${Fmt.timestamp(b.modified, s.clock.today())} · ${(b.sizeBytes / 1024).ceil()} KB'),
              ),
            ),
        ],
      ),
    );
    if (chosen == null || !mounted) return;
    final ok = await showDialog<bool>(
      context: context,
      builder: (c) => AlertDialog(
        title: const Text('Restore this backup?'),
        content: Text(
          'All current data will be replaced by “${chosen.name}”.\n\n'
          'A copy of the current data is saved first (overdue-before-restore-….sqlite in the backup folder), '
          'so this can be undone. Overdue restarts to apply it.',
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(c, false), child: const Text('Cancel')),
          FilledButton(onPressed: () => Navigator.pop(c, true), child: const Text('Restore and restart')),
        ],
      ),
    );
    if (ok != true) return;
    await s.backups.scheduleRestore(chosen.file);
    await s.platform.restartApp();
  }

  @override
  Widget build(BuildContext context) {
    final s = AppScope.of(context);
    final st = s.settings;
    final last = _backups?.isEmpty ?? true ? null : _backups!.first;
    return Column(
      children: [
        SwitchListTile(
          secondary: const Icon(Icons.backup_outlined),
          title: const Text('Daily automatic backup'),
          subtitle: Text(
            last == null ? 'No backup yet' : 'Last: ${last.name} (${Fmt.timestamp(last.modified, s.clock.today())})',
          ),
          value: st.backupEnabled,
          onChanged: (v) => st.backupEnabled = v,
        ),
        ListTile(
          leading: const Icon(Icons.folder_outlined),
          title: const Text('Backup folder'),
          subtitle: SelectableText(s.backups.folder.path),
          trailing: s.platform.isDesktop
              ? Wrap(
                  spacing: 4,
                  children: [
                    TextButton(onPressed: _chooseFolder, child: const Text('Change…')),
                    TextButton(
                      onPressed: () async {
                        await s.backups.folder.create(recursive: true);
                        await launchUrl(Uri.directory(s.backups.folder.path));
                      },
                      child: const Text('Open'),
                    ),
                  ],
                )
              : null,
        ),
        ListTile(
          leading: const Icon(Icons.history),
          title: const Text('Daily backups kept'),
          trailing: DropdownButton<int>(
            value: const [7, 14, 30, 90, 365].contains(st.backupKeep) ? st.backupKeep : 30,
            items: const [
              DropdownMenuItem(value: 7, child: Text('7')),
              DropdownMenuItem(value: 14, child: Text('14')),
              DropdownMenuItem(value: 30, child: Text('30')),
              DropdownMenuItem(value: 90, child: Text('90')),
              DropdownMenuItem(value: 365, child: Text('365')),
            ],
            onChanged: (v) => st.backupKeep = v!,
          ),
        ),
        ListTile(
          leading: const Icon(Icons.save_alt),
          title: const Text('Back up now'),
          enabled: !_busy,
          onTap: _backupNow,
        ),
        ListTile(
          leading: const Icon(Icons.settings_backup_restore),
          title: const Text('Restore from a backup…'),
          subtitle: Text(_backups == null ? '' : '${_backups!.length} backup(s) available'),
          onTap: _restore,
        ),
      ],
    );
  }
}

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../app/app_services.dart';
import '../../domain/experiments.dart';
import '../../domain/models.dart';
import '../../domain/task_query.dart';
import '../theme.dart';
import '../widgets/live_query.dart';

/// Dialogs and small helpers shared by the experiment screens and the task editor.
abstract final class ExperimentUi {
  static Color statusColor(ExperimentStatus s, ColorScheme c) => switch (s) {
    ExperimentStatus.idea => c.outline,
    ExperimentStatus.planned => c.primary,
    ExperimentStatus.running => Colors.blue,
    ExperimentStatus.analysing => Colors.orange,
    ExperimentStatus.done => Colors.green,
    ExperimentStatus.abandoned => c.outline,
  };

  static IconData statusIcon(ExperimentStatus s) => switch (s) {
    ExperimentStatus.idea => Icons.lightbulb_outline,
    ExperimentStatus.planned => Icons.event_note_outlined,
    ExperimentStatus.running => Icons.play_circle_outline,
    ExperimentStatus.analysing => Icons.insights,
    ExperimentStatus.done => Icons.check_circle_outline,
    ExperimentStatus.abandoned => Icons.block,
  };

  static Color runColor(RunStatus s, ColorScheme c) => switch (s) {
    RunStatus.scheduled => c.outline,
    RunStatus.running => Colors.blue,
    RunStatus.finished => Colors.green,
    RunStatus.failed => c.error,
    RunStatus.killed => Colors.orange,
  };

  static IconData runIcon(RunStatus s) => switch (s) {
    RunStatus.scheduled => Icons.schedule,
    RunStatus.running => Icons.autorenew,
    RunStatus.finished => Icons.check_circle,
    RunStatus.failed => Icons.error,
    RunStatus.killed => Icons.cancel,
  };

  /// Opens an MLflow page in the browser (the OS fetches it, not Overdue).
  static Future<void> openUrl(BuildContext context, String? url) async {
    final uri = Uri.tryParse(url ?? '');
    if (uri == null || !uri.hasScheme) return;
    final ok = await launchUrl(uri, mode: LaunchMode.externalApplication);
    if (!ok && context.mounted) {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Could not open $url')));
    }
  }

  static Future<void> copy(BuildContext context, String text, String what) async {
    await Clipboard.setData(ClipboardData(text: text));
    if (context.mounted) {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('$what copied')));
    }
  }

  /// Creates or edits an experiment's name, MLflow page and project.
  /// Returns the id of the created experiment.
  static Future<int?> editExperiment(BuildContext context, {Experiment? experiment, int? projectId}) async {
    final s = AppScope.of(context);
    final name = TextEditingController(text: experiment?.name ?? '');
    final url = TextEditingController(text: experiment?.mlflowUrl ?? '');
    var project = experiment?.projectId ?? projectId;
    var status = experiment?.status ?? ExperimentStatus.planned;
    final projects = await s.projects.getAll();
    if (!context.mounted) return null;
    final ok = await showDialog<bool>(
      context: context,
      builder: (c) => StatefulBuilder(
        builder: (c, set) => AlertDialog(
          title: Text(experiment == null ? 'New experiment' : 'Edit experiment'),
          content: SizedBox(
            width: 460,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                TextField(
                  controller: name,
                  autofocus: true,
                  decoration: const InputDecoration(labelText: 'Name'),
                  onSubmitted: (_) => Navigator.pop(c, true),
                ),
                const SizedBox(height: 12),
                TextField(
                  controller: url,
                  decoration: const InputDecoration(
                    labelText: 'MLflow experiment URL (optional)',
                    hintText: 'http://localhost:5000/#/experiments/12',
                    helperText: 'Lets you paste bare run ids later; opened in your browser',
                  ),
                  onChanged: (_) => set(() {}),
                ),
                const SizedBox(height: 12),
                DropdownButtonFormField<int>(
                  initialValue: project ?? -1,
                  decoration: const InputDecoration(labelText: 'Project'),
                  items: [
                    const DropdownMenuItem(value: -1, child: Text('No project')),
                    for (final p in projects) DropdownMenuItem(value: p.id, child: Text(p.name)),
                  ],
                  onChanged: (v) => project = v == -1 ? null : v,
                ),
                if (experiment == null) ...[
                  const SizedBox(height: 12),
                  DropdownButtonFormField<ExperimentStatus>(
                    initialValue: status,
                    decoration: const InputDecoration(labelText: 'Status'),
                    items: [
                      for (final v in ExperimentStatus.values.where((v) => v.isActive))
                        DropdownMenuItem(value: v, child: Text(v.label)),
                    ],
                    onChanged: (v) => status = v ?? status,
                  ),
                ],
              ],
            ),
          ),
          actions: [
            TextButton(onPressed: () => Navigator.pop(c, false), child: const Text('Cancel')),
            FilledButton(onPressed: () => Navigator.pop(c, true), child: const Text('Save')),
          ],
        ),
      ),
    );
    // The controllers are not disposed: the dialog may still be animating
    // out and rebuilding with them. They hold no resources.
    final n = name.text.trim(), u = url.text.trim();
    if (ok != true || n.isEmpty) return null;
    if (experiment == null) {
      return s.experiments.create(n, projectId: project, status: status, mlflowUrl: u);
    }
    await s.experiments.update(
      experiment.id,
      name: n,
      setProject: true,
      projectId: project,
      setUrl: true,
      mlflowUrl: u,
    );
    return experiment.id;
  }

  /// Adds a run to [experiment] or edits [run]. The first field takes an
  /// MLflow run URL or a bare run id.
  static Future<void> editRun(BuildContext context, Experiment experiment, {ExperimentRun? run}) async {
    final s = AppScope.of(context);
    final link = TextEditingController(text: run?.url ?? run?.mlflowRunId ?? '');
    final name = TextEditingController(text: run?.name ?? '');
    final notes = TextEditingController(text: run?.notes ?? '');
    var status = run?.status ?? RunStatus.running;
    final ok = await showDialog<bool>(
      context: context,
      builder: (c) => StatefulBuilder(
        builder: (c, set) {
          final parsed = MlflowLink.parse(link.text);
          final invalid = link.text.trim().isNotEmpty && parsed == null;
          return AlertDialog(
            title: Text(run == null ? 'Add a run to ${experiment.name}' : 'Edit run'),
            content: SizedBox(
              width: 460,
              child: SingleChildScrollView(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    TextField(
                      controller: link,
                      autofocus: run == null,
                      decoration: InputDecoration(
                        labelText: 'MLflow run URL or run id (optional)',
                        hintText: 'Paste from the MLflow UI',
                        errorText: invalid ? 'Not an MLflow URL or a 32-character run id' : null,
                        helperText: parsed?.runId == null ? null : 'Run id ${parsed!.runId}',
                      ),
                      onChanged: (_) => set(() {}),
                    ),
                    const SizedBox(height: 12),
                    TextField(
                      controller: name,
                      autofocus: run != null,
                      decoration: const InputDecoration(labelText: 'Name', hintText: 'e.g. lr=3e-4, seed 2'),
                    ),
                    if (run == null) ...[
                      const SizedBox(height: 12),
                      DropdownButtonFormField<RunStatus>(
                        initialValue: status,
                        decoration: const InputDecoration(labelText: 'Status'),
                        items: [for (final v in RunStatus.values) DropdownMenuItem(value: v, child: Text(v.label))],
                        onChanged: (v) => status = v ?? status,
                      ),
                    ],
                    const SizedBox(height: 12),
                    TextField(
                      controller: notes,
                      minLines: 3,
                      maxLines: 8,
                      decoration: const InputDecoration(
                        labelText: 'Notes (Markdown)',
                        hintText: 'Parameters, observations, results…',
                        border: OutlineInputBorder(),
                      ),
                    ),
                  ],
                ),
              ),
            ),
            actions: [
              TextButton(onPressed: () => Navigator.pop(c, false), child: const Text('Cancel')),
              FilledButton(onPressed: invalid ? null : () => Navigator.pop(c, true), child: const Text('Save')),
            ],
          );
        },
      ),
    );
    // Controllers not disposed: see [editExperiment].
    final parsed = MlflowLink.parse(link.text);
    final isUrl = parsed?.baseUrl != null;
    final values = (name: name.text, notes: notes.text, pasted: link.text.trim());
    if (ok != true) return;
    final url = isUrl ? values.pasted : null;
    if (run == null) {
      await s.experiments.addRun(
        experiment.id,
        name: values.name,
        mlflowRunId: parsed?.runId,
        url: url,
        status: status,
        notes: values.notes,
      );
    } else {
      await s.experiments.updateRun(
        run.id,
        name: values.name,
        setRunId: true,
        mlflowRunId: parsed?.runId,
        setUrl: true,
        url: url ?? (parsed?.runId == null ? null : MlflowLink.runUrl(experiment.mlflowUrl, parsed!.runId!)),
        notes: values.notes,
      );
    }
  }

  static Future<bool> confirm(BuildContext context, String title, String message, {String action = 'Delete'}) async =>
      await showDialog<bool>(
        context: context,
        builder: (c) => AlertDialog(
          title: Text(title),
          content: Text(message),
          actions: [
            TextButton(onPressed: () => Navigator.pop(c, false), child: const Text('Cancel')),
            FilledButton(onPressed: () => Navigator.pop(c, true), child: Text(action)),
          ],
        ),
      ) ==
      true;

  /// Picks an experiment or one of its runs for a task. Returns null when
  /// cancelled; a record with both ids null means "unlink".
  static Future<({int? experimentId, int? runId})?> pickLink(BuildContext context, {int? current}) async {
    final s = AppScope.of(context);
    final experiments = await s.experiments.watchAll().first;
    final runs = await s.experiments.getAllRuns();
    if (!context.mounted) return null;
    final byExp = <int, List<ExperimentRun>>{};
    for (final r in runs) {
      byExp.putIfAbsent(r.experimentId, () => []).add(r);
    }
    final active = experiments.where((e) => e.status.isActive || e.id == current).toList();
    return showDialog<({int? experimentId, int? runId})>(
      context: context,
      builder: (c) {
        final scheme = Theme.of(c).colorScheme;
        return AlertDialog(
          title: const Text('Link to an experiment'),
          contentPadding: const EdgeInsets.fromLTRB(0, 12, 0, 0),
          content: SizedBox(
            width: 460,
            height: 420,
            child: active.isEmpty
                ? Padding(
                    padding: const EdgeInsets.all(24),
                    child: Text(
                      'No active experiment. Create one in the Experiments tab.',
                      style: TextStyle(color: scheme.outline),
                    ),
                  )
                : ListView(
                    children: [
                      for (final e in active) ...[
                        ListTile(
                          leading: Icon(statusIcon(e.status), color: statusColor(e.status, scheme)),
                          title: Text(e.name, style: const TextStyle(fontWeight: FontWeight.w600)),
                          subtitle: Text(e.status.label),
                          selected: e.id == current,
                          onTap: () => Navigator.pop(c, (experimentId: e.id, runId: null)),
                        ),
                        for (final r in byExp[e.id] ?? const <ExperimentRun>[])
                          ListTile(
                            dense: true,
                            contentPadding: const EdgeInsets.only(left: 56, right: 16),
                            leading: Icon(runIcon(r.status), size: 18, color: runColor(r.status, scheme)),
                            title: Text(r.label),
                            subtitle: r.mlflowRunId == null ? null : Text(MlflowLink.shortId(r.mlflowRunId!)),
                            onTap: () => Navigator.pop(c, (experimentId: e.id, runId: r.id)),
                          ),
                      ],
                    ],
                  ),
          ),
          actions: [
            if (current != null)
              TextButton(
                onPressed: () => Navigator.pop(c, (experimentId: null, runId: null)),
                child: const Text('Unlink'),
              ),
            TextButton(onPressed: () => Navigator.pop(c), child: const Text('Cancel')),
          ],
        );
      },
    );
  }

  /// Searches open tasks to link to an experiment. Returns the task id.
  static Future<int?> pickTask(BuildContext context) {
    final s = AppScope.of(context);
    var text = '';
    return showDialog<int>(
      context: context,
      builder: (c) => StatefulBuilder(
        builder: (c, set) => AlertDialog(
          title: const Text('Link an existing task'),
          content: SizedBox(
            width: 480,
            height: 420,
            child: Column(
              children: [
                TextField(
                  autofocus: true,
                  decoration: const InputDecoration(prefixIcon: Icon(Icons.search), hintText: 'Search open tasks'),
                  onChanged: (v) => set(() => text = v),
                ),
                const SizedBox(height: 8),
                Expanded(
                  child: LiveQuery<List<TaskListItem>>(
                    id: text,
                    stream: () => s.tasks.watchQuery(TaskQuery(text: text, limit: 50)),
                    builder: (c, items) => ListView(
                      children: [
                        for (final i in items ?? const <TaskListItem>[])
                          ListTile(
                            dense: true,
                            leading: Icon(
                              AppTheme.priorityIcon(i.task.priority),
                              color: AppTheme.priorityColor(i.task.priority, Theme.of(c).colorScheme),
                            ),
                            title: Text(i.task.title),
                            subtitle: Text(
                              [
                                if (i.projectName != null) i.projectName!,
                                if (i.experimentName != null) 'linked to ${i.experimentName}',
                              ].join(' · '),
                            ),
                            onTap: () => Navigator.pop(c, i.task.id),
                          ),
                      ],
                    ),
                  ),
                ),
              ],
            ),
          ),
          actions: [TextButton(onPressed: () => Navigator.pop(c), child: const Text('Cancel'))],
        ),
      ),
    );
  }
}

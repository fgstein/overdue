import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../app/app_services.dart';
import '../../domain/experiments.dart';
import '../../domain/models.dart';
import '../../domain/task_query.dart';
import '../../services/mlflow/mlflow_client.dart';
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

  /// Creates or edits an experiment: name, linked MLflow experiment (chosen
  /// from the server) and project. Returns the id of the created experiment.
  static Future<int?> editExperiment(BuildContext context, {Experiment? experiment, int? projectId}) async {
    final s = AppScope.of(context);
    final name = TextEditingController(text: experiment?.name ?? '');
    var project = experiment?.projectId ?? projectId;
    var status = experiment?.status ?? ExperimentStatus.planned;
    RemoteExperiment? remote = experiment?.mlflowExperimentId == null
        ? null
        : RemoteExperiment(id: experiment!.mlflowExperimentId!, name: '');
    final projects = await s.projects.getAll();
    if (!context.mounted) return null;
    final ok = await showDialog<bool>(
      context: context,
      builder: (c) => StatefulBuilder(
        builder: (c, set) {
          final scheme = Theme.of(c).colorScheme;
          return AlertDialog(
            title: Text(experiment == null ? 'New experiment' : 'Edit experiment'),
            content: SizedBox(
              width: 460,
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  ListTile(
                    contentPadding: EdgeInsets.zero,
                    leading: const Icon(Icons.science_outlined),
                    title: Text(
                      remote == null
                          ? 'No MLflow experiment'
                          : (remote!.name.isEmpty ? 'MLflow experiment ${remote!.id}' : remote!.name),
                    ),
                    subtitle: Text(
                      s.mlflow.configured
                          ? (remote == null ? 'Its runs are read from the MLflow server' : 'id ${remote!.id}')
                          : 'Set the MLflow server in Settings to follow runs',
                      style: TextStyle(color: scheme.outline),
                    ),
                    trailing: Wrap(
                      children: [
                        if (remote != null)
                          IconButton(
                            tooltip: 'Unlink from MLflow',
                            icon: const Icon(Icons.link_off),
                            onPressed: () => set(() => remote = null),
                          ),
                        TextButton(
                          onPressed: !s.mlflow.configured
                              ? null
                              : () async {
                                  final picked = await pickRemoteExperiment(c, current: remote?.id);
                                  if (picked == null) return;
                                  set(() {
                                    remote = picked;
                                    if (name.text.trim().isEmpty) name.text = picked.name;
                                  });
                                },
                          child: const Text('Choose…'),
                        ),
                      ],
                    ),
                  ),
                  TextField(
                    controller: name,
                    autofocus: experiment != null,
                    decoration: const InputDecoration(labelText: 'Name'),
                    onSubmitted: (_) => Navigator.pop(c, true),
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
                  if (experiment?.mlflowExperimentId != null && remote?.id != experiment!.mlflowExperimentId) ...[
                    const SizedBox(height: 12),
                    Text(
                      'The runs read from the previous MLflow experiment will be removed '
                      '(their notes and tasks links too; the tasks are kept).',
                      style: TextStyle(color: scheme.error),
                    ),
                  ],
                ],
              ),
            ),
            actions: [
              TextButton(onPressed: () => Navigator.pop(c, false), child: const Text('Cancel')),
              FilledButton(onPressed: () => Navigator.pop(c, true), child: const Text('Save')),
            ],
          );
        },
      ),
    );
    // The controller is not disposed: the dialog may still be animating out
    // and rebuilding with it. It holds no resources.
    final n = name.text.trim();
    if (ok != true || n.isEmpty) return null;
    final int id;
    if (experiment == null) {
      id = await s.experiments.create(n, projectId: project, status: status, mlflowExperimentId: remote?.id);
    } else {
      id = experiment.id;
      await s.experiments.update(
        id,
        name: n,
        setProject: true,
        projectId: project,
        setMlflow: true,
        mlflowExperimentId: remote?.id,
      );
    }
    if (remote != null && context.mounted) await syncNow(context, id);
    return id;
  }

  /// Reads the runs of an experiment now; reports errors in a snackbar.
  static Future<void> syncNow(BuildContext context, int experimentId) async {
    try {
      await AppScope.of(context).mlflow.syncExperiment(experimentId);
    } on MlflowException catch (e) {
      if (context.mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(e.message)));
    }
  }

  /// Lists the server's experiments to link one.
  static Future<RemoteExperiment?> pickRemoteExperiment(BuildContext context, {String? current}) {
    final future = AppScope.of(context).mlflow.listExperiments();
    var filter = '';
    return showDialog<RemoteExperiment>(
      context: context,
      builder: (c) => StatefulBuilder(
        builder: (c, set) => AlertDialog(
          title: const Text('MLflow experiment'),
          content: SizedBox(
            width: 480,
            height: 420,
            child: FutureBuilder<List<RemoteExperiment>>(
              future: future,
              builder: (c, snap) {
                if (snap.hasError) {
                  return Padding(
                    padding: const EdgeInsets.all(8),
                    child: Text('${snap.error}', style: TextStyle(color: Theme.of(c).colorScheme.error)),
                  );
                }
                if (!snap.hasData) return const Center(child: CircularProgressIndicator());
                final f = filter.toLowerCase();
                final shown = snap.data!
                    .where((e) => f.isEmpty || e.name.toLowerCase().contains(f) || e.id == f)
                    .toList();
                return Column(
                  children: [
                    TextField(
                      autofocus: true,
                      decoration: const InputDecoration(prefixIcon: Icon(Icons.search), hintText: 'Search'),
                      onChanged: (v) => set(() => filter = v),
                    ),
                    const SizedBox(height: 8),
                    Expanded(
                      child: ListView(
                        children: [
                          for (final e in shown)
                            ListTile(
                              dense: true,
                              title: Text(e.name),
                              subtitle: Text('id ${e.id}'),
                              selected: e.id == current,
                              onTap: () => Navigator.pop(c, e),
                            ),
                        ],
                      ),
                    ),
                  ],
                );
              },
            ),
          ),
          actions: [TextButton(onPressed: () => Navigator.pop(c), child: const Text('Cancel'))],
        ),
      ),
    );
  }

  /// Edits a run's local notes (everything else comes from MLflow).
  static Future<void> editRunNotes(BuildContext context, ExperimentRun run) async {
    final s = AppScope.of(context);
    final notes = TextEditingController(text: run.notes);
    final ok = await showDialog<bool>(
      context: context,
      builder: (c) => AlertDialog(
        title: Text('Notes · ${run.label}'),
        content: SizedBox(
          width: 460,
          child: TextField(
            controller: notes,
            autofocus: true,
            minLines: 4,
            maxLines: 12,
            decoration: const InputDecoration(
              hintText: 'Observations, what to try next… (Markdown)',
              border: OutlineInputBorder(),
            ),
          ),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(c, false), child: const Text('Cancel')),
          FilledButton(onPressed: () => Navigator.pop(c, true), child: const Text('Save')),
        ],
      ),
    );
    // Not disposed: see [editExperiment].
    if (ok == true) await s.experiments.setRunNotes(run.id, notes.text);
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
                            subtitle: Text(MlflowServer.shortId(r.mlflowRunId)),
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

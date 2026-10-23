import 'dart:async';

import 'package:flutter/material.dart';

import '../../app/app_services.dart';
import '../../core/local_date.dart';
import '../../domain/experiments.dart';
import '../../domain/models.dart';
import '../../services/mlflow/mlflow_client.dart';
import '../formatting.dart';
import '../editor/quick_add.dart';
import '../widgets/live_query.dart';
import '../widgets/markdown_editor.dart';
import '../widgets/markdown_view.dart';
import '../widgets/task_tile.dart';
import 'experiment_dialogs.dart';

/// One experiment: status, MLflow page, notes, runs, linked tasks and
/// conclusion. Text is saved as you type, like the task editor.
class ExperimentPage extends StatefulWidget {
  const ExperimentPage({super.key, required this.experimentId});
  final int experimentId;

  static Future<void> open(BuildContext context, int id) => Navigator.of(context).push(
    MaterialPageRoute<void>(
      builder: (_) => ExperimentPage(experimentId: id),
      settings: RouteSettings(name: '/experiment/$id'),
    ),
  );

  @override
  State<ExperimentPage> createState() => _ExperimentPageState();
}

class _ExperimentPageState extends State<ExperimentPage> {
  final _description = TextEditingController();
  final _conclusion = TextEditingController();
  Timer? _debounce;
  bool _loaded = false;
  bool _pending = false;
  late AppServices _s;

  int get _id => widget.experimentId;

  /// Runs being read from MLflow, and the last error.
  bool _syncing = false;
  String? _syncError;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final first = !_ready;
    _s = AppScope.of(context);
    _ready = true;
    if (first) unawaited(_sync());
  }

  bool _ready = false;

  Future<void> _sync() async {
    final e = await _s.experiments.getExperiment(_id);
    if (e?.mlflowExperimentId == null || !_s.mlflow.configured || !mounted) return;
    setState(() => _syncing = true);
    String? error;
    try {
      await _s.mlflow.syncExperiment(_id);
    } on MlflowException catch (x) {
      error = x.message;
    }
    if (mounted) {
      setState(() {
        _syncing = false;
        _syncError = error;
      });
    }
  }

  @override
  void dispose() {
    _debounce?.cancel();
    if (_pending) unawaited(_save());
    _description.dispose();
    _conclusion.dispose();
    super.dispose();
  }

  void _changed(String _) {
    _pending = true;
    _debounce?.cancel();
    _debounce = Timer(const Duration(milliseconds: 400), _save);
  }

  Future<void> _save() {
    _pending = false;
    return _s.experiments.update(_id, description: _description.text, conclusion: _conclusion.text);
  }

  Future<void> _delete(Experiment e) async {
    final ok = await ExperimentUi.confirm(
      context,
      'Delete experiment?',
      '“${e.name}” and its runs will be deleted. Linked tasks are kept and unlinked.',
    );
    if (!ok || !mounted) return;
    _debounce?.cancel();
    _pending = false;
    Navigator.of(context).pop();
    await _s.experiments.delete(e.id);
  }

  @override
  Widget build(BuildContext context) {
    return LiveQuery<Experiment?>(
      id: _id,
      stream: () => _s.experiments.watchExperiment(_id),
      builder: (context, e) {
        if (e == null) return Scaffold(appBar: AppBar());
        if (!_loaded) {
          _loaded = true;
          _description.text = e.description;
          _conclusion.text = e.conclusion;
        }
        return Scaffold(
          appBar: AppBar(
            title: Text(e.name),
            actions: [
              if (_s.mlflow.experimentUrl(e) != null)
                IconButton(
                  tooltip: 'Open in MLflow',
                  icon: const Icon(Icons.open_in_new),
                  onPressed: () => ExperimentUi.openUrl(context, _s.mlflow.experimentUrl(e)),
                ),
              IconButton(
                tooltip: 'Rename, MLflow experiment, project',
                icon: const Icon(Icons.edit_outlined),
                onPressed: () => ExperimentUi.editExperiment(context, experiment: e),
              ),
              PopupMenuButton<String>(
                onSelected: (v) {
                  if (v == 'delete') unawaited(_delete(e));
                },
                itemBuilder: (_) => const [PopupMenuItem(value: 'delete', child: Text('Delete experiment'))],
              ),
            ],
          ),
          body: Align(
            alignment: Alignment.topCenter,
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 860),
              child: ListView(
                padding: const EdgeInsets.fromLTRB(16, 8, 16, 32),
                children: [
                  _header(context, e),
                  const SizedBox(height: 16),
                  _sectionTitle(context, 'Hypothesis & notes'),
                  MarkdownEditor(controller: _description, onChanged: _changed, startInPreview: true),
                  const SizedBox(height: 20),
                  _RunsSection(experiment: e, syncing: _syncing, error: _syncError, onSync: _sync),
                  const SizedBox(height: 20),
                  _TasksSection(experiment: e),
                  const SizedBox(height: 20),
                  _sectionTitle(context, 'Conclusion'),
                  MarkdownEditor(controller: _conclusion, onChanged: _changed, startInPreview: true),
                ],
              ),
            ),
          ),
        );
      },
    );
  }

  Widget _header(BuildContext context, Experiment e) {
    final scheme = Theme.of(context).colorScheme;
    return Wrap(
      spacing: 8,
      runSpacing: 8,
      crossAxisAlignment: WrapCrossAlignment.center,
      children: [
        PopupMenuButton<ExperimentStatus>(
          tooltip: 'Status',
          initialValue: e.status,
          onSelected: (v) => _s.experiments.update(e.id, status: v),
          itemBuilder: (_) => [
            for (final v in ExperimentStatus.values)
              PopupMenuItem(
                value: v,
                child: Row(
                  children: [
                    Icon(ExperimentUi.statusIcon(v), color: ExperimentUi.statusColor(v, scheme)),
                    const SizedBox(width: 8),
                    Text(v.label),
                  ],
                ),
              ),
          ],
          child: Chip(
            avatar: Icon(
              ExperimentUi.statusIcon(e.status),
              size: 18,
              color: ExperimentUi.statusColor(e.status, scheme),
            ),
            label: Text(e.status.label),
          ),
        ),
        if (e.projectId != null)
          LiveQuery<List<Project>>(
            id: 'projects',
            stream: _s.projects.watchAll,
            builder: (context, projects) {
              final p = projects?.where((p) => p.id == e.projectId).firstOrNull;
              if (p == null) return const SizedBox.shrink();
              return Chip(
                avatar: CircleAvatar(radius: 6, backgroundColor: Color(p.color)),
                label: Text(p.name),
              );
            },
          ),
        if (e.mlflowExperimentId != null)
          ActionChip(
            avatar: const Icon(Icons.tag, size: 18),
            label: Text('MLflow experiment ${e.mlflowExperimentId}'),
            tooltip: 'Copy the experiment id',
            onPressed: () => ExperimentUi.copy(context, e.mlflowExperimentId!, 'Experiment id'),
          )
        else
          ActionChip(
            avatar: const Icon(Icons.link, size: 18),
            label: const Text('Link to MLflow'),
            onPressed: () => ExperimentUi.editExperiment(context, experiment: e),
          ),
      ],
    );
  }
}

Widget _sectionTitle(BuildContext context, String title, {List<Widget> actions = const []}) {
  final theme = Theme.of(context);
  return Padding(
    padding: const EdgeInsets.only(bottom: 6),
    child: Row(
      children: [
        Expanded(
          child: Text(title, style: theme.textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w700)),
        ),
        ...actions,
      ],
    ),
  );
}

class _RunsSection extends StatelessWidget {
  const _RunsSection({required this.experiment, required this.syncing, required this.error, required this.onSync});
  final Experiment experiment;
  final bool syncing;
  final String? error;
  final VoidCallback onSync;

  @override
  Widget build(BuildContext context) {
    final s = AppScope.of(context);
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final linked = experiment.mlflowExperimentId != null;
    final synced = experiment.syncedAt;
    return LiveQuery<List<ExperimentRun>>(
      id: experiment.id,
      stream: () => s.experiments.watchRuns(experiment.id),
      builder: (context, runs) => LiveQuery<Map<int, int>>(
        id: experiment.id,
        stream: () => s.experiments.watchOpenTasksPerRun(experiment.id),
        builder: (context, openTasks) => Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            _sectionTitle(
              context,
              'Runs',
              actions: [
                if (linked && synced != null)
                  Text(
                    'from MLflow · ${Fmt.timestamp(synced, s.today.value)}',
                    style: theme.textTheme.labelSmall?.copyWith(color: scheme.outline),
                  ),
                if (linked && s.mlflow.configured)
                  syncing
                      ? const Padding(
                          padding: EdgeInsets.all(12),
                          child: SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2)),
                        )
                      : IconButton(tooltip: 'Refresh from MLflow', icon: const Icon(Icons.refresh), onPressed: onSync),
              ],
            ),
            if (error != null)
              Padding(
                padding: const EdgeInsets.fromLTRB(8, 0, 8, 8),
                child: Text(error!, style: TextStyle(color: scheme.error)),
              ),
            if (!linked || !s.mlflow.configured)
              Padding(
                padding: const EdgeInsets.all(8),
                child: Row(
                  children: [
                    Expanded(
                      child: Text(
                        !s.mlflow.configured
                            ? 'Set the MLflow server in Settings: the runs of the linked MLflow experiment '
                                  'then appear here by themselves.'
                            : 'Link this experiment to an MLflow experiment to follow its runs.',
                        style: TextStyle(color: scheme.outline),
                      ),
                    ),
                    if (!linked && s.mlflow.configured)
                      TextButton.icon(
                        onPressed: () => ExperimentUi.editExperiment(context, experiment: experiment),
                        icon: const Icon(Icons.link),
                        label: const Text('Link to MLflow'),
                      ),
                  ],
                ),
              ),
            if (linked && (runs == null || runs.isEmpty) && s.mlflow.configured && error == null)
              Padding(
                padding: const EdgeInsets.all(8),
                child: Text(
                  syncing ? 'Reading the runs…' : 'No run in this MLflow experiment yet.',
                  style: TextStyle(color: scheme.outline),
                ),
              ),
            for (final r in runs ?? const <ExperimentRun>[])
              _RunTile(key: ValueKey(r.id), experiment: experiment, run: r, openTasks: openTasks?[r.id] ?? 0),
          ],
        ),
      ),
    );
  }
}

String _duration(Duration d) {
  if (d.inDays > 0) return '${d.inDays}d ${d.inHours % 24}h';
  if (d.inHours > 0) return '${d.inHours}h ${d.inMinutes % 60}min';
  if (d.inMinutes > 0) return '${d.inMinutes}min';
  return '${d.inSeconds}s';
}

String _number(double v) {
  if (v == v.roundToDouble() && v.abs() < 1e9) return v.toInt().toString();
  final a = v.abs();
  if (a >= 1e5 || a < 1e-3) return v.toStringAsExponential(3);
  // 4 significant digits, without trailing zeros (0.42, not 0.4200).
  final p = v.toStringAsPrecision(4);
  return p.contains('.') ? p.replaceFirst(RegExp(r'0+$'), '').replaceFirst(RegExp(r'\.$'), '') : p;
}

class _RunTile extends StatelessWidget {
  const _RunTile({super.key, required this.experiment, required this.run, required this.openTasks});
  final Experiment experiment;
  final ExperimentRun run;
  final int openTasks;

  /// Metrics shown on the row (all of them in the details).
  static const _shownMetrics = 6;

  @override
  Widget build(BuildContext context) {
    final s = AppScope.of(context);
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final today = s.today.value;
    final url = s.mlflow.runUrl(experiment, run);
    final started = run.startedAt;
    final details = [
      MlflowServer.shortId(run.mlflowRunId),
      run.status.label,
      if (started != null) Fmt.timestamp(started, today),
      if (started != null && run.endedAt != null) _duration(run.endedAt!.difference(started)),
      if (run.status.isTerminal) run.reviewed ? 'reviewed' : 'to review',
      if (openTasks > 0) '$openTasks open task${openTasks == 1 ? '' : 's'}',
    ].join(' · ');
    final metrics = run.metrics.keys.toList()..sort();
    final small = theme.textTheme.bodySmall;
    return Card(
      margin: const EdgeInsets.only(bottom: 6),
      elevation: 0,
      color: scheme.surfaceContainerLow,
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 4),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            ListTile(
              dense: true,
              contentPadding: const EdgeInsets.only(left: 12, right: 4),
              leading: Tooltip(
                message: run.status.label,
                child: Icon(ExperimentUi.runIcon(run.status), color: ExperimentUi.runColor(run.status, scheme)),
              ),
              title: Text(run.label, style: const TextStyle(fontWeight: FontWeight.w600)),
              subtitle: Text(details, style: TextStyle(color: run.toReview ? Colors.orange : scheme.outline)),
              onTap: () => _showDetails(context, url),
              trailing: Wrap(
                children: [
                  if (run.status.isTerminal)
                    IconButton(
                      tooltip: run.reviewed ? 'Reviewed (click to undo)' : 'Mark as reviewed',
                      icon: Icon(
                        run.reviewed ? Icons.task_alt : Icons.radio_button_unchecked,
                        color: run.reviewed ? Colors.green : Colors.orange,
                        size: 20,
                      ),
                      onPressed: () => s.experiments.setReviewed(run.id, !run.reviewed),
                    ),
                  if (url != null)
                    IconButton(
                      tooltip: 'Open in MLflow',
                      icon: const Icon(Icons.open_in_new, size: 20),
                      onPressed: () => ExperimentUi.openUrl(context, url),
                    ),
                  IconButton(
                    tooltip: 'New task for this run',
                    icon: const Icon(Icons.add_task, size: 20),
                    onPressed: () => QuickAdd.show(
                      context,
                      projectId: experiment.projectId,
                      experiment: (
                        experimentId: experiment.id,
                        runId: run.id,
                        label: '${experiment.name} › ${run.label}',
                      ),
                    ),
                  ),
                  PopupMenuButton<String>(
                    tooltip: 'Run actions',
                    icon: const Icon(Icons.more_vert, size: 20),
                    onSelected: (v) async {
                      switch (v) {
                        case 'notes':
                          await ExperimentUi.editRunNotes(context, run);
                        case 'details':
                          await _showDetails(context, url);
                        case 'copy':
                          await ExperimentUi.copy(context, run.mlflowRunId, 'Run id');
                      }
                    },
                    itemBuilder: (_) => const [
                      PopupMenuItem(value: 'notes', child: Text('Notes…')),
                      PopupMenuItem(value: 'details', child: Text('Metrics and params')),
                      PopupMenuItem(value: 'copy', child: Text('Copy run id')),
                    ],
                  ),
                ],
              ),
            ),
            if (metrics.isNotEmpty)
              Padding(
                padding: const EdgeInsets.fromLTRB(56, 0, 16, 6),
                child: Wrap(
                  spacing: 14,
                  runSpacing: 2,
                  children: [
                    for (final k in metrics.take(_shownMetrics))
                      Text.rich(
                        TextSpan(
                          children: [
                            TextSpan(
                              text: '$k ',
                              style: TextStyle(color: scheme.outline),
                            ),
                            TextSpan(
                              text: _number(run.metrics[k]!),
                              style: const TextStyle(fontFeatures: [FontFeature.tabularFigures()]),
                            ),
                          ],
                        ),
                        style: small,
                      ),
                    if (metrics.length > _shownMetrics)
                      Text('+${metrics.length - _shownMetrics}', style: small?.copyWith(color: scheme.outline)),
                  ],
                ),
              ),
            if (run.notes.trim().isNotEmpty)
              Padding(
                padding: const EdgeInsets.fromLTRB(56, 0, 16, 8),
                child: DefaultTextStyle.merge(style: small, child: MarkdownView(run.notes)),
              ),
          ],
        ),
      ),
    );
  }

  Future<void> _showDetails(BuildContext context, String? url) {
    final metrics = run.metrics.keys.toList()..sort();
    final params = run.params.keys.toList()..sort();
    return showDialog<void>(
      context: context,
      builder: (c) {
        final theme = Theme.of(c);
        Widget row(String k, String v) => Padding(
          padding: const EdgeInsets.symmetric(vertical: 2),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(
                child: SelectableText(k, style: TextStyle(color: theme.colorScheme.outline)),
              ),
              const SizedBox(width: 12),
              Expanded(child: SelectableText(v)),
            ],
          ),
        );
        Widget title(String t) => Padding(
          padding: const EdgeInsets.only(top: 12, bottom: 4),
          child: Text(t, style: theme.textTheme.titleSmall?.copyWith(fontWeight: FontWeight.w700)),
        );
        return AlertDialog(
          title: Text(run.label),
          content: SizedBox(
            width: 520,
            child: SingleChildScrollView(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  row('Run id', run.mlflowRunId),
                  row('Status', run.status.label),
                  title('Metrics'),
                  if (metrics.isEmpty) const Text('None'),
                  for (final k in metrics) row(k, _number(run.metrics[k]!)),
                  title('Params'),
                  if (params.isEmpty) const Text('None'),
                  for (final k in params) row(k, run.params[k]!),
                ],
              ),
            ),
          ),
          actions: [
            if (url != null)
              TextButton(onPressed: () => ExperimentUi.openUrl(c, url), child: const Text('Open in MLflow')),
            TextButton(onPressed: () => Navigator.pop(c), child: const Text('Close')),
          ],
        );
      },
    );
  }
}

class _TasksSection extends StatelessWidget {
  const _TasksSection({required this.experiment});
  final Experiment experiment;

  @override
  Widget build(BuildContext context) {
    final s = AppScope.of(context);
    final scheme = Theme.of(context).colorScheme;
    return LiveQuery<List<TaskListItem>>(
      id: experiment.id,
      stream: () => s.tasks.watchExperimentTasks(experiment.id),
      builder: (context, tasks) => ValueListenableBuilder<LocalDate>(
        valueListenable: s.today,
        builder: (context, today, _) => Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            _sectionTitle(
              context,
              'Tasks',
              actions: [
                TextButton.icon(
                  onPressed: () async {
                    final id = await ExperimentUi.pickTask(context);
                    if (id != null) await s.experiments.linkTask(id, experimentId: experiment.id);
                  },
                  icon: const Icon(Icons.link),
                  label: const Text('Link task'),
                ),
                TextButton.icon(
                  onPressed: () => QuickAdd.show(
                    context,
                    projectId: experiment.projectId,
                    experiment: (experimentId: experiment.id, runId: null, label: experiment.name),
                  ),
                  icon: const Icon(Icons.add),
                  label: const Text('New task'),
                ),
              ],
            ),
            if (tasks == null || tasks.isEmpty)
              Padding(
                padding: const EdgeInsets.all(8),
                child: Text(
                  'No task yet: what to launch, check or analyse for this experiment.',
                  style: TextStyle(color: scheme.outline),
                ),
              )
            else
              for (final t in tasks)
                Row(
                  key: ValueKey(t.task.id),
                  children: [
                    Expanded(
                      child: TaskTile(item: t, today: today, showExperiment: false),
                    ),
                    IconButton(
                      tooltip: 'Unlink from the experiment',
                      icon: Icon(Icons.link_off, size: 18, color: scheme.outline),
                      onPressed: () => s.experiments.unlinkTask(t.task.id),
                    ),
                  ],
                ),
          ],
        ),
      ),
    );
  }
}

import 'dart:async';

import 'package:flutter/material.dart';

import '../../app/app_services.dart';
import '../../core/local_date.dart';
import '../../domain/experiments.dart';
import '../../domain/models.dart';
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

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _s = AppScope.of(context);
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
              if (e.mlflowUrl != null)
                IconButton(
                  tooltip: 'Open in MLflow',
                  icon: const Icon(Icons.open_in_new),
                  onPressed: () => ExperimentUi.openUrl(context, e.mlflowUrl),
                ),
              IconButton(
                tooltip: 'Rename, MLflow page, project',
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
                  _RunsSection(experiment: e),
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
    final link = e.link;
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
        if (link?.experimentId != null)
          ActionChip(
            avatar: const Icon(Icons.tag, size: 18),
            label: Text('MLflow experiment ${link!.experimentId}'),
            tooltip: 'Copy the experiment id',
            onPressed: () => ExperimentUi.copy(context, link.experimentId!, 'Experiment id'),
          ),
        if (e.mlflowUrl == null)
          ActionChip(
            avatar: const Icon(Icons.link, size: 18),
            label: const Text('Add the MLflow page'),
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
  const _RunsSection({required this.experiment});
  final Experiment experiment;

  @override
  Widget build(BuildContext context) {
    final s = AppScope.of(context);
    final scheme = Theme.of(context).colorScheme;
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
                TextButton.icon(
                  onPressed: () => ExperimentUi.editRun(context, experiment),
                  icon: const Icon(Icons.add),
                  label: const Text('Add run'),
                ),
              ],
            ),
            if (runs == null || runs.isEmpty)
              Padding(
                padding: const EdgeInsets.all(8),
                child: Text(
                  'No run yet. Paste the URL (or id) of an MLflow run when you launch it.',
                  style: TextStyle(color: scheme.outline),
                ),
              )
            else
              for (final r in runs)
                _RunTile(key: ValueKey(r.id), experiment: experiment, run: r, openTasks: openTasks?[r.id] ?? 0),
          ],
        ),
      ),
    );
  }
}

class _RunTile extends StatelessWidget {
  const _RunTile({super.key, required this.experiment, required this.run, required this.openTasks});
  final Experiment experiment;
  final ExperimentRun run;
  final int openTasks;

  @override
  Widget build(BuildContext context) {
    final s = AppScope.of(context);
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final details = [
      if (run.mlflowRunId != null) MlflowLink.shortId(run.mlflowRunId!),
      run.status.label,
      if (run.status.isTerminal) run.reviewed ? 'reviewed' : 'to review',
      if (openTasks > 0) '$openTasks open task${openTasks == 1 ? '' : 's'}',
    ].join(' · ');
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
              contentPadding: const EdgeInsets.only(left: 4, right: 4),
              leading: PopupMenuButton<RunStatus>(
                tooltip: 'Run status',
                initialValue: run.status,
                onSelected: (v) => s.experiments.setRunStatus(run.id, v),
                itemBuilder: (_) => [
                  for (final v in RunStatus.values)
                    PopupMenuItem(
                      value: v,
                      child: Row(
                        children: [
                          Icon(ExperimentUi.runIcon(v), color: ExperimentUi.runColor(v, scheme)),
                          const SizedBox(width: 8),
                          Text(v.label),
                        ],
                      ),
                    ),
                ],
                icon: Icon(ExperimentUi.runIcon(run.status), color: ExperimentUi.runColor(run.status, scheme)),
              ),
              title: Text(run.label, style: const TextStyle(fontWeight: FontWeight.w600)),
              subtitle: Text(details, style: TextStyle(color: run.toReview ? Colors.orange : scheme.outline)),
              onTap: () => ExperimentUi.editRun(context, experiment, run: run),
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
                  if (run.url != null)
                    IconButton(
                      tooltip: 'Open in MLflow',
                      icon: const Icon(Icons.open_in_new, size: 20),
                      onPressed: () => ExperimentUi.openUrl(context, run.url),
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
                        case 'edit':
                          await ExperimentUi.editRun(context, experiment, run: run);
                        case 'copy':
                          await ExperimentUi.copy(context, run.mlflowRunId!, 'Run id');
                        case 'delete':
                          final ok = await ExperimentUi.confirm(
                            context,
                            'Delete run?',
                            '“${run.label}” will be deleted. Its tasks stay linked to the experiment.',
                          );
                          if (ok) await s.experiments.deleteRun(run.id);
                      }
                    },
                    itemBuilder: (_) => [
                      const PopupMenuItem(value: 'edit', child: Text('Edit (name, link, notes)')),
                      if (run.mlflowRunId != null) const PopupMenuItem(value: 'copy', child: Text('Copy run id')),
                      const PopupMenuItem(value: 'delete', child: Text('Delete run')),
                    ],
                  ),
                ],
              ),
            ),
            if (run.notes.trim().isNotEmpty)
              Padding(
                padding: const EdgeInsets.fromLTRB(56, 0, 16, 8),
                child: DefaultTextStyle.merge(style: theme.textTheme.bodySmall, child: MarkdownView(run.notes)),
              ),
          ],
        ),
      ),
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

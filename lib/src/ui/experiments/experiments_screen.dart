import 'dart:async';

import 'package:flutter/material.dart';

import '../../app/app_services.dart';
import '../../domain/experiments.dart';
import '../editor/quick_add.dart';
import '../widgets/live_query.dart';
import '../widgets/overlay_button.dart';
import 'experiment_dialogs.dart';
import 'experiment_page.dart';

/// Experiments (e.g. MLflow experiments) grouped by status, with the runs
/// whose results are waiting to be reviewed on top.
class ExperimentsScreen extends StatefulWidget {
  const ExperimentsScreen({super.key});

  @override
  State<ExperimentsScreen> createState() => _ExperimentsScreenState();
}

class _ExperimentsScreenState extends State<ExperimentsScreen> {
  static const _showAllKey = 'experiments.showAll';
  late bool _showAll = AppScope.of(context).settings.raw(_showAllKey) == '1';

  void _toggleShowAll() {
    setState(() => _showAll = !_showAll);
    unawaited(AppScope.of(context).settings.setRaw(_showAllKey, _showAll ? '1' : '0'));
  }

  Future<void> _create() async {
    final id = await ExperimentUi.editExperiment(context);
    if (id != null && mounted) await ExperimentPage.open(context, id);
  }

  @override
  Widget build(BuildContext context) {
    final s = AppScope.of(context);
    return Scaffold(
      floatingActionButton: FloatingActionButton.extended(
        heroTag: 'new-experiment',
        onPressed: _create,
        icon: const Icon(Icons.science_outlined),
        label: const Text('New experiment'),
      ),
      appBar: AppBar(
        title: const Text('Experiments'),
        actions: [
          ListenableBuilder(
            listenable: s.mlflow,
            builder: (context, _) {
              if (!s.mlflow.configured) return const SizedBox.shrink();
              if (s.mlflow.busy) {
                return const Padding(
                  padding: EdgeInsets.all(14),
                  child: SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2)),
                );
              }
              final error = s.mlflow.lastError;
              return IconButton(
                tooltip: error == null ? 'Refresh runs from MLflow' : 'MLflow: $error',
                icon: Icon(
                  error == null ? Icons.refresh : Icons.sync_problem,
                  color: error == null ? null : Theme.of(context).colorScheme.error,
                ),
                onPressed: s.mlflow.syncAll,
              );
            },
          ),
          FilterChip(label: const Text('Show done'), selected: _showAll, onSelected: (_) => _toggleShowAll()),
          const SizedBox(width: 4),
          const OverlayButton(),
          const SizedBox(width: 4),
        ],
      ),
      body: LiveQuery<List<RunWithExperiment>>(
        id: 'runs-to-review',
        stream: s.experiments.watchRunsToReview,
        builder: (context, toReview) => LiveQuery<List<ExperimentSummary>>(
          id: 'experiments',
          stream: s.experiments.watchSummaries,
          builder: (context, all) {
            if (all == null) return const SizedBox.shrink();
            final shown = all.where((e) => _showAll || e.experiment.status.isActive).toList()
              ..sort((a, b) => a.experiment.status.boardOrder.compareTo(b.experiment.status.boardOrder));
            final review = toReview ?? const <RunWithExperiment>[];
            if (all.isEmpty) return const _EmptyState();
            final sections = <ExperimentStatus, List<ExperimentSummary>>{};
            for (final e in shown) {
              sections.putIfAbsent(e.experiment.status, () => []).add(e);
            }
            return ListView(
              padding: const EdgeInsets.fromLTRB(12, 4, 12, 88),
              children: [
                if (review.isNotEmpty) ...[
                  _SectionHeader('Runs to review', review.length, icon: Icons.fact_check_outlined),
                  for (final r in review) _ReviewRow(key: ValueKey('review${r.run.id}'), item: r),
                  const SizedBox(height: 8),
                ],
                for (final MapEntry(key: status, value: items) in sections.entries) ...[
                  _SectionHeader(status.label, items.length, icon: ExperimentUi.statusIcon(status)),
                  for (final e in items) _ExperimentCard(key: ValueKey('exp${e.experiment.id}'), summary: e),
                ],
                if (shown.isEmpty)
                  Padding(
                    padding: const EdgeInsets.all(16),
                    child: Text(
                      'No active experiment. “Show done” lists finished ones.',
                      style: TextStyle(color: Theme.of(context).colorScheme.outline),
                    ),
                  ),
              ],
            );
          },
        ),
      ),
    );
  }
}

class _EmptyState extends StatelessWidget {
  const _EmptyState();

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Center(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 420),
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(Icons.science_outlined, size: 48, color: scheme.outline),
              const SizedBox(height: 12),
              Text(
                'Track the experiments you launch: their MLflow runs, what to check when they finish, '
                'and the tasks that go with them.',
                textAlign: TextAlign.center,
                style: TextStyle(color: scheme.outline),
              ),
              const SizedBox(height: 8),
              Text(
                'Set your MLflow server in Settings, then link each experiment to an MLflow experiment: '
                'its runs, statuses and metrics are read from the server.',
                textAlign: TextAlign.center,
                style: Theme.of(context).textTheme.bodySmall?.copyWith(color: scheme.outline),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _SectionHeader extends StatelessWidget {
  const _SectionHeader(this.title, this.count, {required this.icon});
  final String title;
  final int count;
  final IconData icon;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.fromLTRB(4, 12, 4, 6),
      child: Row(
        children: [
          Icon(icon, size: 18, color: theme.colorScheme.outline),
          const SizedBox(width: 8),
          Text(title, style: theme.textTheme.titleSmall?.copyWith(fontWeight: FontWeight.w700)),
          const SizedBox(width: 8),
          Text('$count', style: theme.textTheme.labelMedium?.copyWith(color: theme.colorScheme.outline)),
        ],
      ),
    );
  }
}

/// A finished run waiting for its results to be looked at.
class _ReviewRow extends StatelessWidget {
  const _ReviewRow({super.key, required this.item});
  final RunWithExperiment item;

  @override
  Widget build(BuildContext context) {
    final s = AppScope.of(context);
    final scheme = Theme.of(context).colorScheme;
    final run = item.run;
    final server = s.mlflow.server, expId = item.mlflowExperimentId;
    final url = server == null || expId == null ? null : MlflowServer.runUrl(server, expId, run.mlflowRunId);
    return Card(
      margin: const EdgeInsets.only(bottom: 6),
      elevation: 0,
      color: scheme.surfaceContainerLow,
      child: ListTile(
        dense: true,
        leading: Icon(ExperimentUi.runIcon(run.status), color: ExperimentUi.runColor(run.status, scheme)),
        title: Text(run.label),
        subtitle: Text('${item.experimentName} · ${run.status.label}'),
        onTap: () => ExperimentPage.open(context, run.experimentId),
        trailing: Wrap(
          children: [
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
                experiment: (
                  experimentId: run.experimentId,
                  runId: run.id,
                  label: '${item.experimentName} › ${run.label}',
                ),
              ),
            ),
            IconButton(
              tooltip: 'Mark as reviewed',
              icon: const Icon(Icons.task_alt, size: 20),
              onPressed: () => s.experiments.setReviewed(run.id, true),
            ),
          ],
        ),
      ),
    );
  }
}

class _ExperimentCard extends StatelessWidget {
  const _ExperimentCard({super.key, required this.summary});
  final ExperimentSummary summary;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final e = summary.experiment;
    final color = ExperimentUi.statusColor(e.status, scheme);
    final small = theme.textTheme.labelSmall?.copyWith(color: scheme.outline);
    return Card(
      margin: const EdgeInsets.only(bottom: 6),
      elevation: 0,
      color: scheme.surfaceContainerLow,
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: () => ExperimentPage.open(context, e.id),
        child: Container(
          decoration: BoxDecoration(
            border: Border(left: BorderSide(color: color, width: 4)),
          ),
          padding: const EdgeInsets.fromLTRB(12, 8, 4, 8),
          child: Row(
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      e.name,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: theme.textTheme.bodyLarge?.copyWith(fontWeight: FontWeight.w600),
                    ),
                    const SizedBox(height: 4),
                    Wrap(
                      spacing: 10,
                      runSpacing: 2,
                      crossAxisAlignment: WrapCrossAlignment.center,
                      children: [
                        if (summary.projectName != null)
                          Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              CircleAvatar(
                                radius: 4,
                                backgroundColor: Color(summary.projectColor ?? scheme.primary.toARGB32()),
                              ),
                              const SizedBox(width: 4),
                              Text(summary.projectName!, style: small),
                            ],
                          ),
                        Text(
                          summary.runCount == 0
                              ? 'No run'
                              : '${summary.runCount} run${summary.runCount == 1 ? '' : 's'}',
                          style: small,
                        ),
                        if (summary.runsRunning > 0)
                          Text('${summary.runsRunning} running', style: small?.copyWith(color: Colors.blue)),
                        if (summary.runsToReview > 0)
                          Text(
                            '${summary.runsToReview} to review',
                            style: small?.copyWith(color: Colors.orange, fontWeight: FontWeight.w700),
                          ),
                        if (summary.openTasks > 0)
                          Text('${summary.openTasks} open task${summary.openTasks == 1 ? '' : 's'}', style: small),
                      ],
                    ),
                  ],
                ),
              ),
              if (AppScope.of(context).mlflow.experimentUrl(e) case final url?)
                IconButton(
                  tooltip: 'Open in MLflow',
                  icon: const Icon(Icons.open_in_new, size: 20),
                  onPressed: () => ExperimentUi.openUrl(context, url),
                ),
              IconButton(
                tooltip: 'New task for this experiment',
                icon: const Icon(Icons.add_task, size: 20),
                onPressed: () => QuickAdd.show(
                  context,
                  projectId: e.projectId,
                  experiment: (experimentId: e.id, runId: null, label: e.name),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

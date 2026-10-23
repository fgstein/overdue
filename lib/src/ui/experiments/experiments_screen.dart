import 'dart:async';

import 'package:flutter/material.dart';

import '../../app/app_services.dart';
import '../../domain/experiments.dart';
import '../editor/quick_add.dart';
import '../theme.dart';
import '../widgets/live_query.dart';
import '../widgets/overlay_button.dart';
import 'experiment_dialogs.dart';
import 'experiment_page.dart';

/// Experiments grouped by status, one line each, with the runs whose
/// results are waiting to be reviewed on top. Sections collapse (done and
/// abandoned ones start collapsed); the filter matches names and projects.
class ExperimentsScreen extends StatefulWidget {
  const ExperimentsScreen({super.key});

  @override
  State<ExperimentsScreen> createState() => _ExperimentsScreenState();
}

/// Section of the "Runs to review" list in the collapsed set.
const _reviewSection = -1;

class _ExperimentsScreenState extends State<ExperimentsScreen> {
  static const _collapsedKey = 'experiments.collapsed';
  late final AppServices _s = AppScope.of(context);
  late final Set<int> _collapsed = _loadCollapsed();
  final _filter = TextEditingController();
  bool _searching = false;
  bool _allReviews = false;

  /// Runs to review listed before "Show N more".
  static const _reviewPreview = 5;

  Set<int> _loadCollapsed() {
    final raw = _s.settings.raw(_collapsedKey);
    if (raw == null) return {ExperimentStatus.done.code, ExperimentStatus.abandoned.code};
    return raw.split(',').map(int.tryParse).whereType<int>().toSet();
  }

  void _toggle(int section) {
    setState(() => _collapsed.contains(section) ? _collapsed.remove(section) : _collapsed.add(section));
    unawaited(_s.settings.setRaw(_collapsedKey, _collapsed.join(',')));
  }

  @override
  void dispose() {
    _filter.dispose();
    super.dispose();
  }

  Future<void> _create() async {
    final id = await ExperimentUi.editExperiment(context);
    if (id != null && mounted) await ExperimentPage.open(context, id);
  }

  bool _matches(String q, String name, String? project) =>
      q.isEmpty || name.toLowerCase().contains(q) || (project?.toLowerCase().contains(q) ?? false);

  @override
  Widget build(BuildContext context) {
    final wide = MediaQuery.sizeOf(context).width >= 700;
    final searchField = SizedBox(
      height: 36,
      child: TextField(
        controller: _filter,
        autofocus: !wide,
        onChanged: (_) => setState(() {}),
        style: Theme.of(context).textTheme.bodyMedium,
        decoration: InputDecoration(
          isDense: true,
          hintText: 'Filter',
          prefixIcon: const Icon(Icons.filter_list, size: 18),
          suffixIcon: _filter.text.isEmpty
              ? null
              : IconButton(
                  tooltip: 'Clear',
                  icon: const Icon(Icons.close, size: 16),
                  onPressed: () => setState(_filter.clear),
                ),
          border: const OutlineInputBorder(),
          contentPadding: EdgeInsets.zero,
        ),
      ),
    );
    return Scaffold(
      appBar: AppBar(
        toolbarHeight: 48,
        title: wide
            ? Row(
                children: [
                  const Text('Experiments'),
                  const SizedBox(width: 16),
                  SizedBox(width: 260, child: searchField),
                ],
              )
            : (_searching ? searchField : const Text('Experiments')),
        actions: [
          if (!wide)
            IconButton(
              tooltip: _searching ? 'Close the filter' : 'Filter',
              icon: Icon(_searching ? Icons.close : Icons.filter_list),
              onPressed: () => setState(() {
                _searching = !_searching;
                if (!_searching) _filter.clear();
              }),
            ),
          ListenableBuilder(
            listenable: _s.mlflow,
            builder: (context, _) {
              if (!_s.mlflow.configured) return const SizedBox.shrink();
              if (_s.mlflow.busy) {
                return const Padding(
                  padding: EdgeInsets.all(14),
                  child: SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2)),
                );
              }
              final error = _s.mlflow.lastError;
              return IconButton(
                tooltip: error == null ? 'Refresh runs from MLflow' : 'MLflow: $error',
                icon: Icon(
                  error == null ? Icons.refresh : Icons.sync_problem,
                  color: error == null ? null : Theme.of(context).colorScheme.error,
                ),
                onPressed: _s.mlflow.syncAll,
              );
            },
          ),
          IconButton(tooltip: 'New experiment', icon: const Icon(Icons.add), onPressed: _create),
          const OverlayButton(),
          const SizedBox(width: 4),
        ],
      ),
      body: LiveQuery<List<RunWithExperiment>>(
        id: 'runs-to-review',
        stream: _s.experiments.watchRunsToReview,
        builder: (context, toReview) => LiveQuery<List<ExperimentSummary>>(
          id: 'experiments',
          stream: _s.experiments.watchSummaries,
          builder: (context, all) {
            if (all == null) return const SizedBox.shrink();
            if (all.isEmpty) return const _EmptyState();
            final q = _filter.text.trim().toLowerCase();
            final shown = all.where((e) => _matches(q, e.experiment.name, e.projectName)).toList()
              ..sort((a, b) => a.experiment.status.boardOrder.compareTo(b.experiment.status.boardOrder));
            final review = (toReview ?? const <RunWithExperiment>[])
                .where((r) => _matches(q, r.run.label, r.experimentName))
                .toList();
            final sections = <ExperimentStatus, List<ExperimentSummary>>{};
            for (final e in shown) {
              sections.putIfAbsent(e.experiment.status, () => []).add(e);
            }
            // A flat, lazily built list: headers and rows.
            final rows = <Widget>[
              if (review.isNotEmpty) ...[
                _SectionHeader(
                  'Runs to review',
                  review.length,
                  icon: Icons.fact_check_outlined,
                  color: Colors.orange,
                  collapsed: _collapsed.contains(_reviewSection),
                  onToggle: () => _toggle(_reviewSection),
                ),
                if (!_collapsed.contains(_reviewSection)) ...[
                  for (final r in _allReviews ? review : review.take(_reviewPreview))
                    _ReviewRow(key: ValueKey('review${r.run.id}'), item: r),
                  if (review.length > _reviewPreview)
                    Align(
                      alignment: Alignment.centerLeft,
                      child: TextButton(
                        style: TextButton.styleFrom(
                          visualDensity: VisualDensity.compact,
                          padding: const EdgeInsets.symmetric(horizontal: 36),
                        ),
                        onPressed: () => setState(() => _allReviews = !_allReviews),
                        child: Text(_allReviews ? 'Show less' : 'Show ${review.length - _reviewPreview} more'),
                      ),
                    ),
                ],
              ],
              for (final MapEntry(key: status, value: items) in sections.entries) ...[
                _SectionHeader(
                  status.label,
                  items.length,
                  icon: ExperimentUi.statusIcon(status),
                  color: ExperimentUi.statusColor(status, Theme.of(context).colorScheme),
                  collapsed: _collapsed.contains(status.code),
                  onToggle: () => _toggle(status.code),
                ),
                if (!_collapsed.contains(status.code))
                  for (final e in items) _ExperimentRow(key: ValueKey('exp${e.experiment.id}'), summary: e),
              ],
              if (shown.isEmpty && review.isEmpty)
                Padding(
                  padding: const EdgeInsets.all(16),
                  child: Text(
                    'Nothing matches “${_filter.text}”.',
                    style: TextStyle(color: Theme.of(context).colorScheme.outline),
                  ),
                ),
            ];
            return Align(
              alignment: Alignment.topLeft,
              child: ConstrainedBox(
                // Keeps counters and actions near the names on wide windows.
                constraints: const BoxConstraints(maxWidth: 960),
                child: ListView.builder(
                  padding: const EdgeInsets.only(bottom: 24),
                  itemCount: rows.length,
                  itemBuilder: (_, i) => rows[i],
                ),
              ),
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
                'and the tasks that go with them. Create one with +.',
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

/// Row height for the current density.
double _rowHeight(BuildContext context) => switch (AppDensity.of(context)) {
  UiDensity.comfortable => 44,
  UiDensity.compact => 34,
  UiDensity.singleLine => 30,
};

const _smallButton = BoxConstraints.tightFor(width: 28, height: 28);

class _SectionHeader extends StatelessWidget {
  const _SectionHeader(
    this.title,
    this.count, {
    required this.icon,
    required this.color,
    required this.collapsed,
    required this.onToggle,
  });
  final String title;
  final int count;
  final IconData icon;
  final Color color;
  final bool collapsed;
  final VoidCallback onToggle;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final outline = theme.colorScheme.outline;
    return InkWell(
      onTap: onToggle,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(8, 8, 12, 2),
        child: Row(
          children: [
            Icon(collapsed ? Icons.chevron_right : Icons.expand_more, size: 18, color: outline),
            const SizedBox(width: 2),
            Icon(icon, size: 16, color: color),
            const SizedBox(width: 6),
            Text(
              title.toUpperCase(),
              style: theme.textTheme.labelMedium?.copyWith(fontWeight: FontWeight.w700, letterSpacing: 0.6),
            ),
            const SizedBox(width: 6),
            Text('$count', style: theme.textTheme.labelSmall?.copyWith(color: outline)),
          ],
        ),
      ),
    );
  }
}

/// Tiny icon + number; nothing when [n] is 0.
class _Counter extends StatelessWidget {
  const _Counter(this.icon, this.n, this.tooltip, {this.color, this.bold = false});
  final IconData icon;
  final int n;
  final String tooltip;
  final Color? color;
  final bool bold;

  @override
  Widget build(BuildContext context) {
    if (n == 0) return const SizedBox.shrink();
    final theme = Theme.of(context);
    final c = color ?? theme.colorScheme.outline;
    return Tooltip(
      message: tooltip,
      child: Padding(
        padding: const EdgeInsets.only(left: 10),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: 13, color: c),
            const SizedBox(width: 2),
            Text(
              '$n',
              style: theme.textTheme.labelSmall?.copyWith(color: c, fontWeight: bold ? FontWeight.w700 : null),
            ),
          ],
        ),
      ),
    );
  }
}

/// One experiment on one line: status bar, name, project, counters, actions.
class _ExperimentRow extends StatelessWidget {
  const _ExperimentRow({super.key, required this.summary});
  final ExperimentSummary summary;

  @override
  Widget build(BuildContext context) {
    final s = AppScope.of(context);
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final e = summary.experiment;
    final showProject = MediaQuery.sizeOf(context).width >= 520 && summary.projectName != null;
    final url = s.mlflow.experimentUrl(e);
    return InkWell(
      onTap: () => ExperimentPage.open(context, e.id),
      child: SizedBox(
        height: _rowHeight(context),
        child: Row(
          children: [
            const SizedBox(width: 14),
            Container(
              width: 3,
              height: _rowHeight(context) - 12,
              decoration: BoxDecoration(
                color: ExperimentUi.statusColor(e.status, scheme),
                borderRadius: BorderRadius.circular(2),
              ),
            ),
            const SizedBox(width: 10),
            Expanded(
              child: Text(e.name, maxLines: 1, overflow: TextOverflow.ellipsis, style: theme.textTheme.bodyMedium),
            ),
            if (showProject) ...[
              const SizedBox(width: 8),
              CircleAvatar(radius: 4, backgroundColor: Color(summary.projectColor ?? scheme.primary.toARGB32())),
              const SizedBox(width: 4),
              ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 140),
                child: Text(
                  summary.projectName!,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: theme.textTheme.labelSmall?.copyWith(color: scheme.outline),
                ),
              ),
            ],
            _Counter(Icons.format_list_bulleted, summary.runCount, '${summary.runCount} runs'),
            _Counter(Icons.autorenew, summary.runsRunning, '${summary.runsRunning} running', color: Colors.blue),
            _Counter(
              Icons.fact_check_outlined,
              summary.runsToReview,
              '${summary.runsToReview} to review',
              color: Colors.orange,
              bold: true,
            ),
            _Counter(Icons.check_box_outline_blank, summary.openTasks, '${summary.openTasks} open tasks'),
            const SizedBox(width: 6),
            if (url != null)
              IconButton(
                tooltip: 'Open in MLflow',
                padding: EdgeInsets.zero,
                constraints: _smallButton,
                icon: const Icon(Icons.open_in_new, size: 16),
                onPressed: () => ExperimentUi.openUrl(context, url),
              ),
            IconButton(
              tooltip: 'New task for this experiment',
              padding: EdgeInsets.zero,
              constraints: _smallButton,
              icon: const Icon(Icons.add_task, size: 16),
              onPressed: () => QuickAdd.show(
                context,
                projectId: e.projectId,
                experiment: (experimentId: e.id, runId: null, label: e.name),
              ),
            ),
            const SizedBox(width: 8),
          ],
        ),
      ),
    );
  }
}

/// A finished run waiting for its results to be looked at, on one line.
class _ReviewRow extends StatelessWidget {
  const _ReviewRow({super.key, required this.item});
  final RunWithExperiment item;

  @override
  Widget build(BuildContext context) {
    final s = AppScope.of(context);
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final run = item.run;
    final server = s.mlflow.server, expId = item.mlflowExperimentId;
    final url = server == null || expId == null ? null : MlflowServer.runUrl(server, expId, run.mlflowRunId);
    return InkWell(
      onTap: () => ExperimentPage.open(context, run.experimentId),
      child: SizedBox(
        height: _rowHeight(context),
        child: Row(
          children: [
            const SizedBox(width: 12),
            Tooltip(
              message: run.status.label,
              child: Icon(ExperimentUi.runIcon(run.status), size: 16, color: ExperimentUi.runColor(run.status, scheme)),
            ),
            const SizedBox(width: 8),
            Expanded(
              child: Text.rich(
                TextSpan(
                  children: [
                    TextSpan(text: run.label),
                    TextSpan(
                      text: '   ${item.experimentName}',
                      style: theme.textTheme.labelSmall?.copyWith(color: scheme.outline),
                    ),
                  ],
                ),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: theme.textTheme.bodyMedium,
              ),
            ),
            if (url != null)
              IconButton(
                tooltip: 'Open in MLflow',
                padding: EdgeInsets.zero,
                constraints: _smallButton,
                icon: const Icon(Icons.open_in_new, size: 16),
                onPressed: () => ExperimentUi.openUrl(context, url),
              ),
            IconButton(
              tooltip: 'New task for this run',
              padding: EdgeInsets.zero,
              constraints: _smallButton,
              icon: const Icon(Icons.add_task, size: 16),
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
              padding: EdgeInsets.zero,
              constraints: _smallButton,
              icon: const Icon(Icons.task_alt, size: 16),
              onPressed: () => s.experiments.setReviewed(run.id, true),
            ),
            const SizedBox(width: 8),
          ],
        ),
      ),
    );
  }
}

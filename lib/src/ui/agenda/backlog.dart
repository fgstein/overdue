import 'package:flutter/material.dart';

import '../../app/app_services.dart';
import '../../domain/enums.dart';
import '../../domain/models.dart';
import '../../domain/task_chains.dart';
import '../../domain/task_query.dart';
import '../bulk_actions.dart';
import '../editor/quick_add.dart';
import '../task_actions.dart';
import '../theme.dart';
import '../widgets/live_query.dart';
import '../widgets/task_chain.dart';
import '../widgets/task_drag.dart';

/// Backlog: open one-time tasks without a date. They stay visible next to
/// the agenda until they are planned, by dragging them onto a day (agenda
/// or mini calendar) or with the calendar button.
///
/// Dropping a dated task on the backlog removes its date.
class Backlog extends StatelessWidget {
  const Backlog({super.key, this.asSection = false, this.collapsed = false, this.onToggle});

  /// Narrow screens: rendered as a collapsible section below the agenda
  /// instead of a side panel.
  final bool asSection;
  final bool collapsed;
  final VoidCallback? onToggle;

  /// Setting: '0' hides the backlog (agenda and calendar).
  static const settingKey = 'agenda.backlog';

  static const query = TaskQuery(
    due: DueFilter.noDate,
    types: {TaskType.oneTime},
    includeSubtasks: false,
    sort: TaskSort.priority,
    limit: 500,
  );

  static bool accepts(TaskDragData d) =>
      d.occurrenceDate == null && d.task.type == TaskType.oneTime && d.task.dueDate != null && !d.task.isSubtask;

  @override
  Widget build(BuildContext context) {
    final s = AppScope.of(context);
    return LiveQuery<List<TaskListItem>>(
      id: 'backlog',
      stream: () => s.tasks.watchQuery(query),
      builder: (context, items) => LiveQuery<List<TaskListItem>>(
        id: 'chain-waiting',
        stream: s.tasks.watchWaitingInChain,
        builder: (context, waiting) {
          // Chained tasks are folded under the task they wait for (here or
          // in the agenda), never listed on their own.
          final rows = TaskChains(waiting ?? const [])
              .fold(items ?? const <TaskListItem>[], (i) => i.task.id)
              .where((r) => !r.$1.isWaitingInChain)
              .toList();
          return DragTarget<TaskDragData>(
            onWillAcceptWithDetails: (d) => accepts(d.data),
            onAcceptWithDetails: (d) => s.tasks.rescheduleTasks([d.data.task.id], null),
            builder: (context, candidates, _) =>
                _content(context, rows, hover: candidates.isNotEmpty, loading: items == null),
          );
        },
      ),
    );
  }

  Widget _content(
    BuildContext context,
    List<(TaskListItem, List<ChainLink>)> items, {
    required bool hover,
    required bool loading,
  }) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final header = Padding(
      padding: EdgeInsets.fromLTRB(16, asSection ? 18 : 12, 4, 4),
      child: Row(
        children: [
          Icon(Icons.inbox_outlined, size: 18, color: scheme.onSurfaceVariant),
          const SizedBox(width: 8),
          Text(
            'BACKLOG',
            style: theme.textTheme.titleSmall?.copyWith(
              color: scheme.onSurfaceVariant,
              letterSpacing: 1.1,
              fontWeight: FontWeight.w700,
            ),
          ),
          const SizedBox(width: 8),
          Text('${items.length}', style: theme.textTheme.labelMedium?.copyWith(color: scheme.outline)),
          const Spacer(),
          IconButton(
            tooltip: 'New task without a date',
            visualDensity: VisualDensity.compact,
            icon: const Icon(Icons.add, size: 20),
            onPressed: () => QuickAdd.show(context),
          ),
          if (onToggle != null)
            Icon(collapsed ? Icons.expand_more : Icons.expand_less, size: 20, color: scheme.onSurfaceVariant),
          const SizedBox(width: 4),
        ],
      ),
    );
    final hint = Padding(
      padding: const EdgeInsets.fromLTRB(16, 4, 16, 12),
      child: Text(
        hover
            ? 'Drop to remove the date'
            : 'Tasks without a date wait here. Drag one onto a day, or use the calendar button to plan it.',
        style: theme.textTheme.bodySmall?.copyWith(color: scheme.outline),
      ),
    );
    final tiles = [
      for (final (i, chain) in items)
        if (chain.isEmpty)
          BacklogTile(key: ValueKey('b${i.task.id}'), item: i)
        else
          Column(
            key: ValueKey('b${i.task.id}'),
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              BacklogTile(item: i),
              ChainFold(links: chain, color: AppTheme.projectColor(i.projectColor, scheme)),
            ],
          ),
    ];

    if (asSection) {
      return Container(
        color: hover ? scheme.primaryContainer.withValues(alpha: 0.4) : null,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            InkWell(onTap: onToggle, child: header),
            if (!collapsed) ...[if (items.isEmpty && !loading) hint, ...tiles],
          ],
        ),
      );
    }
    return AnimatedContainer(
      duration: const Duration(milliseconds: 120),
      decoration: BoxDecoration(
        color: hover ? scheme.primaryContainer.withValues(alpha: 0.4) : scheme.surfaceContainerLow,
        border: Border(left: BorderSide(color: scheme.outlineVariant)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          header,
          if (items.isEmpty && !loading) hint,
          Expanded(
            child: ListView(padding: const EdgeInsets.only(bottom: 24), children: tiles),
          ),
        ],
      ),
    );
  }
}

/// One backlog task: complete circle, title and project, plan button.
/// Draggable (mouse; long press on touch screens).
class BacklogTile extends StatelessWidget {
  const BacklogTile({super.key, required this.item});
  final TaskListItem item;

  @override
  Widget build(BuildContext context) {
    final s = AppScope.of(context);
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final t = item.task;
    final compact = AppDensity.of(context) != UiDensity.comfortable;
    final tile = InkWell(
      onTap: () => TaskActions.open(context, t.id),
      onSecondaryTapUp: (_) => TaskActions.showQuickActions(context, item),
      child: Padding(
        padding: EdgeInsets.fromLTRB(8, compact ? 0 : 2, 4, compact ? 0 : 2),
        child: Row(
          children: [
            InkResponse(
              radius: 16,
              onTap: () => TaskActions.toggleComplete(context, t),
              child: Padding(
                padding: const EdgeInsets.all(6),
                child: Icon(Icons.radio_button_unchecked, size: 18, color: AppTheme.priorityColor(t.priority, scheme)),
              ),
            ),
            const SizedBox(width: 4),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(t.title, maxLines: 2, overflow: TextOverflow.ellipsis, style: theme.textTheme.bodyMedium),
                  if (item.projectName != null)
                    Row(
                      children: [
                        Container(
                          width: 7,
                          height: 7,
                          decoration: BoxDecoration(
                            color: AppTheme.projectColor(item.projectColor, scheme),
                            shape: BoxShape.circle,
                          ),
                        ),
                        const SizedBox(width: 5),
                        Flexible(
                          child: Text(
                            item.projectName!,
                            overflow: TextOverflow.ellipsis,
                            style: theme.textTheme.labelSmall?.copyWith(color: scheme.outline),
                          ),
                        ),
                      ],
                    ),
                ],
              ),
            ),
            if (t.priority.code >= TaskPriority.high.code)
              Icon(AppTheme.priorityIcon(t.priority), size: 16, color: AppTheme.priorityColor(t.priority, scheme)),
            PopupMenuButton<RescheduleTarget>(
              tooltip: 'Plan: give it a date',
              padding: compact ? EdgeInsets.zero : const EdgeInsets.all(8),
              style: compact
                  ? IconButton.styleFrom(minimumSize: const Size(28, 28), fixedSize: const Size(28, 28))
                  : null,
              icon: Icon(Icons.event_outlined, size: 20, color: scheme.onSurfaceVariant),
              onSelected: (target) async {
                final (cancelled, date) = await BulkActions.resolve(context, target, s.clock.today());
                if (!cancelled && date != null) await s.tasks.rescheduleTasks([t.id], date);
              },
              itemBuilder: (_) => [
                for (final target in RescheduleTarget.values.where((x) => x != RescheduleTarget.noDate))
                  PopupMenuItem(
                    value: target,
                    child: Row(children: [Icon(target.icon, size: 18), const SizedBox(width: 10), Text(target.label)]),
                  ),
              ],
            ),
          ],
        ),
      ),
    );
    return DraggableTask(
      data: TaskDragData(t),
      enabled: true,
      touchLongPress: !s.platform.isDesktop,
      // Drop another task onto this one: this one starts after it.
      child: ChainDropTarget(task: t, child: tile),
    );
  }
}

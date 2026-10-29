import 'package:flutter/material.dart';

import '../../app/app_services.dart';
import '../../data/task_repository.dart';
import '../../domain/enums.dart';
import '../../domain/models.dart';
import '../task_actions.dart';
import '../theme.dart';
import 'task_drag.dart';

/// Chaining by drag and drop: dropping task A onto task B makes B wait for
/// A (B starts automatically once A is completed).
abstract final class TaskChainDrop {
  /// Quick local check while dragging; the repository validates the rest
  /// (cycles, subtasks).
  static bool canChain(TaskDragData dragged, Task target) =>
      dragged.occurrenceDate == null &&
      !dragged.task.isRecurring &&
      !target.isRecurring &&
      dragged.task.id != target.id &&
      dragged.task.status.isOpen &&
      target.status.isOpen &&
      target.afterTaskId != dragged.task.id;

  /// Makes [target] wait for the dragged task; explains a refusal.
  static Future<void> chain(BuildContext context, TaskDragData dragged, Task target) async {
    final messenger = ScaffoldMessenger.maybeOf(context);
    try {
      await AppScope.of(context).tasks.chainAfter(target.id, dragged.task.id);
      messenger?.showSnackBar(
        SnackBar(
          content: Text('“${target.title}” will start after “${dragged.task.title}”'),
          duration: const Duration(seconds: 3),
        ),
      );
    } on ChainException catch (e) {
      messenger?.showSnackBar(SnackBar(content: Text(e.message)));
    }
  }

  /// Outline drawn around a task while another one hovers it to be chained.
  static Widget highlight(BuildContext context, Widget child, {required bool active, BorderRadius? radius}) {
    if (!active) return child;
    final scheme = Theme.of(context).colorScheme;
    return DecoratedBox(
      position: DecorationPosition.foreground,
      decoration: BoxDecoration(
        border: Border.all(color: scheme.tertiary, width: 2),
        borderRadius: radius ?? BorderRadius.circular(6),
      ),
      child: child,
    );
  }
}

/// Wraps a task row or card so another task can be dropped onto it to chain
/// them (used by the backlog and the project columns; the agenda has its own
/// slot with reorder zones).
class ChainDropTarget extends StatelessWidget {
  const ChainDropTarget({super.key, required this.task, required this.child, this.radius});
  final Task task;
  final Widget child;
  final BorderRadius? radius;

  @override
  Widget build(BuildContext context) => DragTarget<TaskDragData>(
    onWillAcceptWithDetails: (d) => TaskChainDrop.canChain(d.data, task),
    onAcceptWithDetails: (d) => TaskChainDrop.chain(context, d.data, task),
    builder: (context, candidates, _) =>
        TaskChainDrop.highlight(context, child, active: candidates.isNotEmpty, radius: radius),
  );
}

/// The tasks chained after a task, folded and attached under its row:
/// "⛓ Then: B → C". Click to unfold the list (open, unchain, drag).
class ChainFold extends StatefulWidget {
  const ChainFold({super.key, required this.links, this.color, this.indent = 0});
  final List<ChainLink> links;

  /// Colour of the connector (the predecessor's project colour).
  final Color? color;

  /// Left offset so the fold lines up with the row above.
  final double indent;

  @override
  State<ChainFold> createState() => _ChainFoldState();
}

class _ChainFoldState extends State<ChainFold> {
  bool _open = false;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final links = widget.links;
    if (links.isEmpty) return const SizedBox.shrink();
    final compact = AppDensity.of(context) != UiDensity.comfortable;
    final color = widget.color ?? scheme.outline;
    final small = theme.textTheme.bodySmall?.copyWith(color: scheme.onSurfaceVariant);

    final summary = InkWell(
      onTap: () => setState(() => _open = !_open),
      child: Padding(
        padding: EdgeInsets.symmetric(vertical: compact ? 2 : 4),
        child: Row(
          children: [
            Icon(Icons.link, size: 14, color: scheme.tertiary),
            const SizedBox(width: 4),
            Text(
              'Then',
              style: small?.copyWith(fontWeight: FontWeight.w600, color: scheme.tertiary),
            ),
            const SizedBox(width: 6),
            Expanded(
              child: Text(
                links.map((l) => l.item.task.title).join('  →  '),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: small,
              ),
            ),
            if (links.length > 1)
              Padding(
                padding: const EdgeInsets.only(left: 4),
                child: Text('${links.length}', style: small?.copyWith(color: scheme.outline)),
              ),
            Icon(_open ? Icons.expand_less : Icons.expand_more, size: 16, color: scheme.outline),
            const SizedBox(width: 4),
          ],
        ),
      ),
    );

    return Padding(
      padding: EdgeInsets.only(left: widget.indent + 4, right: 4, bottom: compact ? 2 : 4),
      child: Container(
        decoration: BoxDecoration(
          color: scheme.surfaceContainerHighest.withValues(alpha: 0.5),
          border: Border(
            left: BorderSide(color: color.withValues(alpha: 0.6), width: compact ? 3 : 4),
          ),
          borderRadius: const BorderRadius.only(bottomRight: Radius.circular(6)),
        ),
        padding: const EdgeInsets.only(left: 8),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          mainAxisSize: MainAxisSize.min,
          children: [
            summary,
            if (_open)
              for (final l in links) _ChainLinkRow(link: l),
          ],
        ),
      ),
    );
  }
}

/// One unfolded chained task: waits for the row above it.
class _ChainLinkRow extends StatelessWidget {
  const _ChainLinkRow({required this.link});
  final ChainLink link;

  @override
  Widget build(BuildContext context) {
    final s = AppScope.of(context);
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final item = link.item;
    final t = item.task;
    final row = InkWell(
      onTap: () => TaskActions.open(context, t.id),
      onSecondaryTapUp: (_) => TaskActions.showQuickActions(context, item),
      onLongPress: () => TaskActions.showQuickActions(context, item),
      child: Padding(
        padding: EdgeInsets.only(left: 12.0 * (link.depth - 1)),
        child: Row(
          children: [
            Icon(Icons.subdirectory_arrow_right, size: 14, color: scheme.outline),
            const SizedBox(width: 4),
            Icon(AppTheme.statusIcon(TaskStatus.blocked), size: 12, color: scheme.outline),
            const SizedBox(width: 6),
            Expanded(
              child: Text(t.title, maxLines: 1, overflow: TextOverflow.ellipsis, style: theme.textTheme.bodySmall),
            ),
            if (item.projectName != null)
              Padding(
                padding: const EdgeInsets.only(left: 6),
                child: Icon(Icons.circle, size: 8, color: AppTheme.projectColor(item.projectColor, scheme)),
              ),
            IconButton(
              tooltip: 'Remove from the chain',
              visualDensity: VisualDensity.compact,
              padding: EdgeInsets.zero,
              constraints: const BoxConstraints.tightFor(width: 26, height: 26),
              icon: Icon(Icons.link_off, size: 16, color: scheme.outline),
              onPressed: () => s.tasks.unchain(t.id),
            ),
          ],
        ),
      ),
    );
    return DraggableTask(data: TaskDragData(t), enabled: s.platform.isDesktop, child: row);
  }
}

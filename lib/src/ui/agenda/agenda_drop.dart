import 'package:flutter/material.dart';

import '../../app/app_services.dart';
import '../../core/local_date.dart';
import '../../domain/agenda.dart';
import '../widgets/task_chain.dart';
import '../widgets/task_drag.dart';

/// Drag and drop inside the agenda (desktop):
/// * within the same day/section: reorder (remembered as a manual order);
/// * onto another day (today or an upcoming day): change the due date and
///   insert at the drop position;
/// * onto the middle of another task: chain them (that task then waits for
///   the dragged one and is folded under it).
///
/// Recurring occurrences keep their date (the rule decides), so they can
/// only be reordered within their own section. Ongoing / Recurring / Overdue
/// sections accept only their own entries.
abstract final class AgendaDrop {
  static String keyOf(TaskDragData d) =>
      d.occurrenceDate != null ? 'o${d.task.id}_${d.occurrenceDate!.epochDay}' : 't${d.task.id}';

  /// Due date given to a task dropped into [s], or null if [s] has no date
  /// semantics (ongoing, recurring, overdue).
  static LocalDate? dateOf(AgendaSection s, LocalDate today) => switch (s.kind) {
    AgendaSectionKind.todayUrgent || AgendaSectionKind.today => today,
    AgendaSectionKind.upcoming => s.date,
    _ => null,
  };

  static bool canDrop(AgendaSection s, TaskDragData d, LocalDate today) {
    final key = keyOf(d);
    if (s.entries.any((e) => e.key == key)) return true; // Reorder in place.
    if (d.occurrenceDate != null || d.task.isRecurring) return false;
    return dateOf(s, today) != null;
  }

  /// Drops [d] into [s] before the entry with [beforeKey] (end when null).
  static Future<void> drop(AppServices app, AgendaSection s, TaskDragData d, {String? beforeKey}) async {
    final key = keyOf(d);
    if (beforeKey == key) return;
    final inSection = s.entries.any((e) => e.key == key);
    if (!inSection) {
      await app.tasks.rescheduleTasks([d.task.id], dateOf(s, app.clock.today()));
    }
    // Postponed traces are not tasks of this day: they take no order.
    final rest = s.entries.where((e) => e.key != key && !e.isPostponed).toList();
    var index = beforeKey == null ? rest.length : rest.indexWhere((e) => e.key == beforeKey);
    if (index < 0) index = rest.length;
    final order = <int>[for (final e in rest) e.task.id]..insert(index, d.task.id);
    await app.tasks.setDayOrder(order.toSet().toList());
  }
}

enum _Zone { before, after, chain }

/// Wraps an agenda row: shows an insertion line while a task is dragged over
/// its top or bottom edge and drops it there; over the middle of a task row,
/// outlines it and chains the two tasks.
class AgendaDropSlot extends StatefulWidget {
  const AgendaDropSlot({
    super.key,
    required this.section,
    required this.today,
    required this.child,
    this.entry,
    this.thisKey,
    this.nextKey,
  });
  final AgendaSection section;
  final LocalDate today;

  /// Entry of this row (null for a header).
  final AgendaEntry? entry;

  /// Key of the entry in this row (null for a header: drops at the top).
  final String? thisKey;

  /// Key of the following entry in the section (null = last).
  final String? nextKey;
  final Widget child;

  @override
  State<AgendaDropSlot> createState() => _AgendaDropSlotState();
}

class _AgendaDropSlotState extends State<AgendaDropSlot> {
  _Zone _zone = _Zone.before;

  /// Task of this row that a dragged task can be chained into, if any.
  bool _chainable(TaskDragData d) {
    final e = widget.entry;
    return e != null && !e.isPostponed && !e.isOccurrence && !e.isDone && TaskChainDrop.canChain(d, e.task);
  }

  String? get _beforeKey {
    if (widget.thisKey == null) {
      // Header: insert at the top of the section.
      return widget.section.entries.isEmpty ? null : widget.section.entries.first.key;
    }
    return _zone == _Zone.after ? widget.nextKey : widget.thisKey;
  }

  @override
  Widget build(BuildContext context) {
    final app = AppScope.of(context);
    final line = Container(
      height: 3,
      decoration: BoxDecoration(color: Theme.of(context).colorScheme.primary, borderRadius: BorderRadius.circular(2)),
    );
    return DragTarget<TaskDragData>(
      onWillAcceptWithDetails: (d) => AgendaDrop.canDrop(widget.section, d.data, widget.today) || _chainable(d.data),
      onMove: (d) {
        final box = context.findRenderObject() as RenderBox?;
        if (box == null || widget.thisKey == null) return;
        final h = box.size.height, y = box.globalToLocal(d.offset).dy;
        final zone = _chainable(d.data) && y > h * 0.3 && y < h * 0.7
            ? _Zone.chain
            : (y > h / 2 ? _Zone.after : _Zone.before);
        if (zone != _zone) setState(() => _zone = zone);
      },
      onAcceptWithDetails: (d) {
        if (_zone == _Zone.chain && _chainable(d.data)) {
          TaskChainDrop.chain(context, d.data, widget.entry!.task);
        } else if (AgendaDrop.canDrop(widget.section, d.data, widget.today)) {
          AgendaDrop.drop(app, widget.section, d.data, beforeKey: _beforeKey);
        }
      },
      builder: (context, candidates, _) {
        final hovering = candidates.isNotEmpty;
        final chaining = hovering && _zone == _Zone.chain && widget.thisKey != null;
        final after = _zone == _Zone.after && widget.thisKey != null;
        final dropLine =
            hovering &&
            !chaining &&
            candidates.first != null &&
            AgendaDrop.canDrop(widget.section, candidates.first!, widget.today);
        return Stack(
          children: [
            TaskChainDrop.highlight(context, widget.child, active: chaining),
            if (dropLine) Positioned(left: 12, right: 12, top: after ? null : 0, bottom: after ? 0 : null, child: line),
          ],
        );
      },
    );
  }
}

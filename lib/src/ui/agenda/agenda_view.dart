import 'dart:async';

import 'package:flutter/material.dart';

import '../../app/app_services.dart';
import '../../core/local_date.dart';
import '../../core/startup_trace.dart';
import '../../domain/agenda.dart';
import '../../domain/models.dart';
import '../formatting.dart';
import '../task_actions.dart';
import '../theme.dart';
import '../widgets/task_chain.dart';
import '../widgets/task_tile.dart';

/// Subscribes to the live agenda for the current day and upcoming setting.
class AgendaBuilderWidget extends StatefulWidget {
  const AgendaBuilderWidget({super.key, required this.builder, this.upcomingDaysOverride});
  final Widget Function(BuildContext context, Agenda? agenda) builder;
  final int? upcomingDaysOverride;

  @override
  State<AgendaBuilderWidget> createState() => _AgendaBuilderWidgetState();
}

class _AgendaBuilderWidgetState extends State<AgendaBuilderWidget> {
  StreamSubscription<Agenda>? _sub;
  Agenda? _agenda;
  LocalDate? _day;
  int? _upcoming;
  late AppServices _s;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _s = AppScope.of(context);
    _s.today.addListener(_resubscribe);
    _s.settings.addListener(_resubscribe);
    _resubscribe();
  }

  @override
  void didUpdateWidget(AgendaBuilderWidget oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.upcomingDaysOverride != widget.upcomingDaysOverride) _resubscribe();
  }

  void _resubscribe() {
    final day = _s.today.value;
    final upcoming = widget.upcomingDaysOverride ?? _s.settings.upcomingDays;
    if (day == _day && upcoming == _upcoming && _sub != null) return;
    _day = day;
    _upcoming = upcoming;
    _sub?.cancel();
    _sub = _s.agenda.watch(today: day, upcomingDays: upcoming).listen((a) {
      StartupTrace.mark('agenda-data');
      if (mounted) setState(() => _agenda = a);
    });
  }

  @override
  void dispose() {
    _s.today.removeListener(_resubscribe);
    _s.settings.removeListener(_resubscribe);
    _sub?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => widget.builder(context, _agenda);
}

/// Flattened agenda rows (headers + entries) for a single lazy sliver list.
sealed class AgendaRow {}

class AgendaHeaderRow extends AgendaRow {
  AgendaHeaderRow(this.title, {this.count, this.big = false, this.color, this.collapsible = false, this.section});
  final String title;

  /// The section this header introduces (drop target), if any.
  final AgendaSection? section;
  final int? count;
  final bool big;
  final Color? color;
  final bool collapsible;
}

class AgendaEntryRow extends AgendaRow {
  AgendaEntryRow(this.entry, this.section);
  final AgendaEntry entry;
  final AgendaSection section;
}

/// Traces of the tasks postponed away from a section, folded into one line
/// with a counter (expands to show each of them).
class AgendaPostponedGroupRow extends AgendaRow {
  AgendaPostponedGroupRow(this.entries, this.section);
  final List<AgendaEntry> entries;
  final AgendaSection section;

  /// Stable key (list diffing, remembered expansion).
  String get key => 'pg_${section.kind.name}_${section.date?.epochDay ?? ''}';
}

/// From this many postponed traces in a section, they are folded into one
/// line: a single trace takes no more room than the counter would.
const kPostponedGroupMin = 2;

/// Rows of the entries of [s]: its tasks, then its postponed traces (folded
/// into one [AgendaPostponedGroupRow] when there are several).
List<AgendaRow> sectionRows(AgendaSection s) {
  final postponed = s.entries.where((e) => e.isPostponed).toList();
  if (postponed.length < kPostponedGroupMin) return [for (final e in s.entries) AgendaEntryRow(e, s)];
  return [
    for (final e in s.entries)
      if (!e.isPostponed) AgendaEntryRow(e, s),
    AgendaPostponedGroupRow(postponed, s),
  ];
}

List<AgendaRow> flattenAgenda(Agenda a, {required ColorScheme scheme, bool overdueCollapsed = false}) {
  final rows = <AgendaRow>[];
  final today = a.todaySections.toList();
  // Dropping on the "Today" title plans the task for today, even when the
  // day is still empty.
  final todayDrop =
      today.where((s) => s.kind == AgendaSectionKind.today).firstOrNull ??
      const AgendaSection(AgendaSectionKind.today, []);
  rows.add(AgendaHeaderRow('Today', count: a.todayCount, big: true, section: todayDrop));
  for (final s in today) {
    rows.add(
      AgendaHeaderRow(
        s.kind.label,
        count: s.openCount,
        color: s.kind == AgendaSectionKind.todayUrgent ? const Color(0xFFE03131) : null,
        section: s,
      ),
    );
    rows.addAll(sectionRows(s));
  }
  final overdue = a.overdue;
  if (overdue != null) {
    rows.add(
      AgendaHeaderRow(
        'Overdue',
        count: overdue.openCount,
        big: true,
        color: scheme.error,
        collapsible: true,
        section: overdue,
      ),
    );
    if (!overdueCollapsed) rows.addAll(sectionRows(overdue));
  }
  final upcoming = a.upcoming.toList();
  if (upcoming.isNotEmpty) {
    rows.add(AgendaHeaderRow('Upcoming', count: upcoming.fold<int>(0, (n, s) => n + s.openCount), big: true));
    for (final s in upcoming) {
      final d = s.date!;
      rows.add(
        AgendaHeaderRow(
          a.today.daysUntil(d) == 1 ? 'Tomorrow · ${Fmt.longDate(d)}' : Fmt.longDate(d),
          count: s.openCount,
          section: s,
        ),
      );
      rows.addAll(sectionRows(s));
    }
  }
  return rows;
}

class AgendaEntryTile extends StatelessWidget {
  const AgendaEntryTile({
    super.key,
    required this.entry,
    required this.today,
    this.selected,
    this.onSelect,
    this.showChain = true,
  });
  final AgendaEntry entry;
  final LocalDate today;
  final bool? selected;
  final VoidCallback? onSelect;

  /// Shows the chained tasks folded under the row (callers may place
  /// [chainFold] themselves, e.g. outside a drop target).
  final bool showChain;

  /// Chained tasks waiting for [entry], folded right under its row.
  static Widget chainFold(BuildContext context, AgendaEntry entry, {bool selecting = false}) => entry.chain.isEmpty
      ? const SizedBox.shrink()
      : ChainFold(
          links: entry.chain,
          color: AppTheme.projectColor(entry.item.projectColor, Theme.of(context).colorScheme),
          indent: selecting ? 40 : 0,
        );

  @override
  Widget build(BuildContext context) {
    if (entry.isPostponed) {
      return PostponedTile(
        postponement: entry.postponement!,
        today: today,
        onRemove: () => AppScope.of(context).tasks.archivePostponement(entry.postponement!.id),
      );
    }
    final tile = _tile(context);
    if (!showChain || entry.chain.isEmpty) return tile;
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        tile,
        chainFold(context, entry, selecting: selected != null),
      ],
    );
  }

  Widget _tile(BuildContext context) => ExpandableTaskTile(
    item: entry.item,
    occurrence: entry.occurrence,
    today: today,
    missedCount: entry.missedCount,
    // Done today: stays visible until tomorrow, unless removed now.
    onRemove: entry.isDone
        ? () {
            final tasks = AppScope.of(context).tasks;
            final occ = entry.occurrence;
            occ != null ? tasks.archiveOccurrence(entry.task.id, occ.date) : tasks.archiveTask(entry.task.id);
          }
        : null,
    selected: selected,
    onSelect: onSelect,
  );
}

/// Trace of a task postponed away from this day: struck through in red,
/// with where it went. Click opens the task; × removes the trace now.
class PostponedTile extends StatelessWidget {
  const PostponedTile({super.key, required this.postponement, required this.today, this.onRemove, this.dense = false});
  final PostponedItem postponement;
  final LocalDate today;
  final VoidCallback? onRemove;
  final bool dense;

  static String destination(PostponedItem p, LocalDate today) {
    final to = p.to;
    if (to == null) return 'Moved to backlog';
    final when = Fmt.relativeDate(to, today);
    return 'Postponed to ${today.daysUntil(to).abs() <= 1 ? when.toLowerCase() : when}';
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final red = scheme.error;
    final item = postponement.item;
    final density = AppDensity.of(context);
    final compact = density != UiDensity.comfortable;
    final small = dense || compact;
    final title = Text(
      item.task.title,
      maxLines: 1,
      overflow: TextOverflow.ellipsis,
      style: (compact ? theme.textTheme.bodyMedium : theme.textTheme.bodyLarge)?.copyWith(
        color: red.withValues(alpha: 0.8),
        decoration: TextDecoration.lineThrough,
        decorationColor: red,
        decorationThickness: 2,
      ),
    );
    final where = Text(
      destination(postponement, today),
      maxLines: 1,
      overflow: TextOverflow.ellipsis,
      style: theme.textTheme.labelSmall?.copyWith(color: red),
    );
    return InkWell(
      onTap: () => TaskActions.open(context, item.task.id),
      child: Padding(
        padding: compact
            ? EdgeInsets.fromLTRB(4, dense ? 1 : 2, 4, dense ? 1 : 2)
            : EdgeInsets.fromLTRB(16, dense ? 4 : 8, 8, dense ? 4 : 8),
        child: Row(
          children: [
            Container(
              width: compact ? 3 : 4,
              height: compact ? (density == UiDensity.singleLine ? 18 : 24) : (small ? 28 : 36),
              decoration: BoxDecoration(
                color: AppTheme.projectColor(item.projectColor, scheme).withValues(alpha: 0.5),
                borderRadius: BorderRadius.circular(2),
              ),
            ),
            SizedBox(width: compact ? 6 : 10),
            Icon(Icons.redo, size: compact ? 18 : 20, color: red),
            SizedBox(width: compact ? 6 : 12),
            Expanded(
              child: density == UiDensity.singleLine
                  ? Row(
                      children: [
                        Flexible(flex: 3, child: title),
                        const SizedBox(width: 10),
                        Flexible(flex: 2, child: where),
                      ],
                    )
                  : Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      mainAxisSize: MainAxisSize.min,
                      children: [title, where],
                    ),
            ),
            if (onRemove != null)
              IconButton(
                tooltip: 'Remove from the agenda',
                visualDensity: VisualDensity.compact,
                padding: compact ? EdgeInsets.zero : null,
                constraints: compact ? const BoxConstraints.tightFor(width: 28, height: 28) : null,
                icon: Icon(Icons.close, size: 18, color: scheme.outline),
                onPressed: onRemove,
              ),
          ],
        ),
      ),
    );
  }
}

/// Several postponed traces folded into one line: "↷ 3 postponed", which
/// expands to show each trace ([PostponedTile]). × removes them all now.
class PostponedGroupTile extends StatefulWidget {
  const PostponedGroupTile({
    super.key,
    required this.storageKey,
    required this.postponements,
    required this.today,
    this.onRemove,
    this.onRemoveAll,
    this.dense = false,
  });

  /// Identifies the group to remember whether it is expanded.
  final String storageKey;
  final List<PostponedItem> postponements;
  final LocalDate today;

  /// Removes one trace (null: traces cannot be removed, e.g. history).
  final void Function(PostponedItem p)? onRemove;

  /// Removes every trace of the group.
  final VoidCallback? onRemoveAll;
  final bool dense;

  @override
  State<PostponedGroupTile> createState() => _PostponedGroupTileState();
}

class _PostponedGroupTileState extends State<PostponedGroupTile> {
  bool _expanded = false;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    // Survives the row being rebuilt or scrolled out of the lazy list.
    _expanded = PageStorage.maybeOf(context)?.readState(context, identifier: _id) as bool? ?? _expanded;
  }

  String get _id => 'postponed-group:${widget.storageKey}';

  void _toggle() {
    setState(() => _expanded = !_expanded);
    PageStorage.maybeOf(context)?.writeState(context, _expanded, identifier: _id);
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final red = scheme.error;
    final density = AppDensity.of(context);
    final compact = density != UiDensity.comfortable;
    final small = widget.dense || compact;
    final n = widget.postponements.length;
    final titles = widget.postponements.map((p) => p.item.task.title).join(', ');
    final header = InkWell(
      onTap: _toggle,
      child: Padding(
        padding: compact
            ? EdgeInsets.fromLTRB(4, widget.dense ? 1 : 2, 4, widget.dense ? 1 : 2)
            : EdgeInsets.fromLTRB(16, widget.dense ? 2 : 4, 8, widget.dense ? 2 : 4),
        child: Row(
          children: [
            SizedBox(width: compact ? 9 : 14),
            Icon(Icons.redo, size: compact ? 18 : 20, color: red),
            SizedBox(width: compact ? 6 : 12),
            Text(
              '$n postponed',
              style: (small ? theme.textTheme.labelMedium : theme.textTheme.labelLarge)?.copyWith(
                color: red,
                fontWeight: FontWeight.w600,
              ),
            ),
            const SizedBox(width: 8),
            // Collapsed: the titles, so the line still says what moved.
            Expanded(
              child: _expanded
                  ? const SizedBox.shrink()
                  : Text(
                      titles,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: theme.textTheme.labelSmall?.copyWith(
                        color: red.withValues(alpha: 0.7),
                        decoration: TextDecoration.lineThrough,
                        decorationColor: red.withValues(alpha: 0.7),
                      ),
                    ),
            ),
            Icon(_expanded ? Icons.expand_less : Icons.expand_more, size: 20, color: scheme.outline),
            if (widget.onRemoveAll != null)
              IconButton(
                tooltip: 'Remove all from the agenda',
                visualDensity: VisualDensity.compact,
                padding: compact ? EdgeInsets.zero : null,
                constraints: compact ? const BoxConstraints.tightFor(width: 28, height: 28) : null,
                icon: Icon(Icons.close, size: 18, color: scheme.outline),
                onPressed: widget.onRemoveAll,
              ),
          ],
        ),
      ),
    );
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        header,
        if (_expanded)
          for (final p in widget.postponements)
            PostponedTile(
              key: ValueKey('p${p.id}'),
              postponement: p,
              today: widget.today,
              dense: widget.dense,
              onRemove: widget.onRemove == null ? null : () => widget.onRemove!(p),
            ),
      ],
    );
  }
}

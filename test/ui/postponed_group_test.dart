import 'package:overdue/src/core/local_date.dart';
import 'package:overdue/src/domain/models.dart';
import 'package:overdue/src/ui/agenda/agenda_view.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  final today = LocalDate(2026, 10, 5);
  final at = DateTime(2026, 10, 5, 9);
  PostponedItem trace(int id, String title) => PostponedItem(
    id: id,
    item: TaskListItem(
      task: Task(id: id, title: title, dueDate: today.addDays(1), createdAt: at, updatedAt: at),
    ),
    from: today,
    to: today.addDays(1),
    at: at,
  );

  testWidgets('folded line with a counter that expands to each trace', (tester) async {
    final removed = <int>[];
    var removedAll = false;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: PostponedGroupTile(
            storageKey: 'today',
            postponements: [trace(1, 'Report'), trace(2, 'Call'), trace(3, 'Taxes')],
            today: today,
            onRemove: (p) => removed.add(p.id),
            onRemoveAll: () => removedAll = true,
          ),
        ),
      ),
    );

    expect(find.text('3 postponed'), findsOneWidget);
    expect(find.text('Report, Call, Taxes'), findsOneWidget, reason: 'collapsed: titles on the same line');
    expect(find.byType(PostponedTile), findsNothing);

    await tester.tap(find.text('3 postponed'));
    await tester.pump();
    expect(find.byType(PostponedTile), findsNWidgets(3));
    expect(find.text('Postponed to tomorrow'), findsNWidgets(3));

    // × on one trace removes that trace only.
    await tester.tap(find.byTooltip('Remove from the agenda').at(1));
    expect(removed, [2]);
    await tester.tap(find.byTooltip('Remove all from the agenda'));
    expect(removedAll, isTrue);

    await tester.tap(find.text('3 postponed'));
    await tester.pump();
    expect(find.byType(PostponedTile), findsNothing);
  });
}

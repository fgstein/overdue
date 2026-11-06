import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:overdue/src/core/local_date.dart';
import 'package:overdue/src/ui/bulk_actions.dart';

void main() {
  // 2026-11-05 is a Thursday.
  final thursday = LocalDate(2026, 11, 5), friday = LocalDate(2026, 11, 6), saturday = LocalDate(2026, 11, 7);
  final monday = LocalDate(2026, 11, 9);

  Future<LocalDate?> resolve(WidgetTester tester, RescheduleTarget t, LocalDate today) async {
    late BuildContext ctx;
    await tester.pumpWidget(
      MaterialApp(
        home: Builder(
          builder: (c) {
            ctx = c;
            return const SizedBox();
          },
        ),
      ),
    );
    return (await BulkActions.resolve(ctx, t, today)).$2;
  }

  testWidgets('postponing to "tomorrow" skips the weekend', (tester) async {
    expect(await resolve(tester, RescheduleTarget.tomorrow, thursday), friday);
    expect(await resolve(tester, RescheduleTarget.tomorrow, friday), monday);
    expect(await resolve(tester, RescheduleTarget.tomorrow, saturday), monday);
  });

  test('labels and menu entries follow the skipped weekend', () {
    expect(RescheduleTarget.tomorrow.labelOn(thursday), 'Tomorrow');
    expect(RescheduleTarget.tomorrow.labelOn(friday), 'Monday');
    expect(RescheduleTarget.on(thursday), contains(RescheduleTarget.nextMonday));
    // From Friday "Tomorrow" is already next Monday: no duplicate entry.
    expect(RescheduleTarget.on(friday), isNot(contains(RescheduleTarget.nextMonday)));
  });
}

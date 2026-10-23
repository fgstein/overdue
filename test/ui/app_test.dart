import 'package:overdue/src/app/app_services.dart';
import 'package:overdue/src/app/overdue_app.dart';
import 'package:overdue/src/core/local_date.dart';
import 'package:overdue/src/data/database_opener.dart';
import 'package:overdue/src/domain/enums.dart';
import 'package:overdue/src/domain/experiments.dart';
import 'package:overdue/src/domain/models.dart';
import 'package:overdue/src/platform/platform_integration.dart';
import 'package:overdue/src/ui/widgets/task_tile.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  late AppServices services;

  Future<void> boot(WidgetTester tester) async {
    await tester.runAsync(() async {
      services = await AppServices.create(
        db: openMemoryDatabase(),
        platform: HeadlessIntegration(),
        clock: FixedClock(DateTime(2026, 10, 4, 10)),
      );
    });
    tester.view.physicalSize = const Size(1200, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(OverdueApp(services: services, dataPath: '/tmp'));
    await settle(tester);
  }

  testWidgets('quick add with description; completed task stays (green) until removed', (tester) async {
    await boot(tester);
    expect(find.text('All clear for today'), findsOneWidget);

    // Quick add from the rail; due today by default on the agenda.
    await tester.tap(find.byTooltip('New task (Ctrl+N)').first);
    await settle(tester);
    await tester.enterText(find.widgetWithText(TextField, 'What needs to be done?'), 'Submit tax documents');
    await tester.enterText(
      find.widgetWithText(TextField, 'Description (optional, Markdown supported)'),
      'Bring receipts',
    );
    // Ctrl+Enter saves, even from the multi-line description.
    await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
    await settle(tester);

    expect(find.text('Submit tax documents'), findsOneWidget);
    final created = await tester.runAsync(() => services.tasks.getTask(1));
    expect(created!.description, 'Bring receipts');

    await tester.tap(find.bySemanticsLabel('Mark as completed').first);
    await settle(tester);
    final task = await tester.runAsync(() => services.tasks.getTask(1));
    expect(task!.status, TaskStatus.completed);
    expect(find.text('Submit tax documents'), findsOneWidget, reason: 'completed work stays visible today');
    expect(find.byTooltip('Remove from agenda'), findsOneWidget);

    await tester.tap(find.byTooltip('Remove from agenda'));
    await settle(tester);
    expect(find.text('Submit tax documents'), findsNothing);
    await tester.runAsync(() => services.db.close());
  });

  testWidgets('"More options" without a title opens the full editor', (tester) async {
    await boot(tester);
    await tester.tap(find.byTooltip('New task (Ctrl+N)').first);
    await settle(tester);
    await tester.tap(find.text('More options'));
    await settle(tester);
    expect(find.text('Description'), findsOneWidget, reason: 'editor is open');
    await tester.enterText(find.widgetWithText(TextField, 'Task title'), 'Renew passport');
    await settle(tester, rounds: 6);
    final t = await tester.runAsync(() => services.tasks.getTask(1));
    expect(t!.title, 'Renew passport');
    await tester.runAsync(() => services.db.close());
  });

  testWidgets('opens the editor and edits priority', (tester) async {
    await boot(tester);
    await tester.runAsync(
      () => services.tasks.createTask(
        TaskDraft(title: 'Call the plumber', dueDate: LocalDate(2026, 10, 4), description: 'Ask about the **boiler**'),
      ),
    );
    await settle(tester);
    await tester.tap(find.text('Call the plumber'));
    await settle(tester);
    expect(find.text('Description'), findsOneWidget);
    expect(find.text('Ask about the '), findsNothing); // rendered as rich text
    await tester.tap(find.text('Normal'));
    await settle(tester);
    await tester.tap(find.text('Urgent').last);
    await settle(tester);
    final t = await tester.runAsync(() => services.tasks.getTask(1));
    expect(t!.priority, TaskPriority.urgent);
    await tester.runAsync(() => services.db.close());
  });

  testWidgets('search finds tasks by text', (tester) async {
    await boot(tester);
    await tester.runAsync(
      () => services.tasks.createTask(TaskDraft(title: 'Research insurance', type: TaskType.ongoing)),
    );
    await tester.runAsync(() => services.tasks.createTask(TaskDraft(title: 'Learn Spanish')));
    await tester.tap(find.text('Tasks').first);
    await settle(tester);
    await tester.enterText(find.byType(SearchBar), 'insur');
    await settle(tester, rounds: 6);
    expect(find.text('Research insurance'), findsOneWidget);
    expect(find.text('Learn Spanish'), findsNothing);
    await tester.runAsync(() => services.db.close());
  });

  testWidgets('experiments tab: create an experiment, see its MLflow runs, review one, add a task', (tester) async {
    await boot(tester);
    await tester.tap(find.text('Experiments').first);
    await settle(tester);
    await tester.tap(find.byTooltip('New experiment'));
    await settle(tester);
    expect(find.text('Set the MLflow server in Settings to follow runs'), findsOneWidget);
    await tester.enterText(find.widgetWithText(TextField, 'Name'), 'LR sweep');
    await tester.tap(find.text('Save'));
    await settle(tester, rounds: 6);
    expect(find.text('LR sweep'), findsWidgets, reason: 'the experiment page is open');

    // What a synchronisation with the server brings in.
    const runId = '0a1b2c3d4e5f60718293a4b5c6d7e8f9';
    await tester.runAsync(() => services.experiments.update(1, setMlflow: true, mlflowExperimentId: '12'));
    await settle(tester);
    await tester.runAsync(
      () => services.experiments.applyRemoteRuns(1, [
        const RemoteRun(runId: runId, name: 'lr=3e-4', status: RunStatus.running, metrics: {'val_loss': 0.4213}),
      ]),
    );
    await settle(tester, rounds: 6);
    expect(find.text('lr=3e-4'), findsOneWidget);
    expect(find.textContaining('val_loss 0.4213', findRichText: true), findsOneWidget);
    final run = (await tester.runAsync(() => services.experiments.getAllRuns()))!.single;

    // New task for the run, from its row.
    await tester.tap(find.byTooltip('New task for this run'));
    await settle(tester);
    expect(find.text('LR sweep › lr=3e-4'), findsOneWidget);
    await tester.enterText(find.widgetWithText(TextField, 'What needs to be done?'), 'Compare val loss');
    await tester.tap(find.text('Add'));
    await settle(tester, rounds: 6);
    final task = await tester.runAsync(() => services.tasks.getTask(1));
    expect(task!.experimentId, run.experimentId);
    expect(task.runId, run.id);
    expect(find.text('Compare val loss'), findsOneWidget);

    // The run finishes on the server: it shows up as "to review" in the tab.
    await tester.runAsync(
      () => services.experiments.applyRemoteRuns(1, [
        const RemoteRun(runId: runId, name: 'lr=3e-4', status: RunStatus.finished),
      ]),
    );
    await tester.pageBack();
    await settle(tester, rounds: 6);
    expect(find.text('RUNS TO REVIEW'), findsOneWidget);
    expect(find.text('TO ANALYSE'), findsOneWidget);
    await tester.tap(find.byTooltip('Mark as reviewed'));
    await settle(tester, rounds: 6);
    expect(find.text('RUNS TO REVIEW'), findsNothing);
    await tester.runAsync(() => services.db.close());
  });

  testWidgets('density setting shrinks agenda rows', (tester) async {
    await boot(tester);
    await tester.runAsync(
      () => services.tasks.createTask(TaskDraft(title: 'Call the bank', dueDate: LocalDate(2026, 10, 4))),
    );
    final heights = <int, double>{};
    for (final d in [0, 1, 2]) {
      services.settings.uiDensity = d;
      await settle(tester);
      heights[d] = tester.getSize(find.byType(TaskTile)).height;
    }
    expect(heights[1]!, lessThan(heights[0]!));
    expect(heights[2]!, lessThan(heights[1]!));
    expect(heights[2]!, lessThanOrEqualTo(32), reason: 'one line per task');
    await tester.runAsync(() => services.db.close());
  });
}

/// Lets real async database work (on the test's real event loop) complete
/// between frames.
Future<void> settle(WidgetTester tester, {int rounds = 4}) async {
  for (var i = 0; i < rounds; i++) {
    await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 40)));
    await tester.pump(const Duration(milliseconds: 200));
  }
}

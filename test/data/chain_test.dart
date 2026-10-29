import 'package:overdue/src/core/local_date.dart';
import 'package:overdue/src/data/agenda_service.dart';
import 'package:overdue/src/data/task_repository.dart';
import 'package:overdue/src/domain/agenda.dart';
import 'package:overdue/src/domain/enums.dart';
import 'package:overdue/src/domain/models.dart';
import 'package:overdue/src/domain/recurrence.dart';
import 'package:overdue/src/domain/task_chains.dart';
import 'package:flutter_test/flutter_test.dart';

import '../helpers.dart';

/// Chained tasks: B starts after A (dropping A onto B).
void main() {
  late TestEnv env;
  setUp(() => env = TestEnv(now: DateTime(2026, 10, 4, 10)));
  tearDown(() => env.dispose());

  Future<int> add(String title, {LocalDate? due, TaskType type = TaskType.oneTime, RecurrenceRule? rule}) =>
      env.tasks.createTask(TaskDraft(title: title, dueDate: due, type: type, recurrence: rule));
  Future<Task> get(int id) async => (await env.tasks.getTask(id))!;

  Future<Agenda> agenda() => AgendaService(env.tasks).watch(today: env.today, upcomingDays: 1).first;

  List<String> titles(Agenda a) => a.sections.expand((s) => s.entries).map((e) => e.task.title).toList();

  test('chaining blocks the task until its predecessor is completed, then starts it today', () async {
    final a = await add('Write report', due: env.today);
    final b = await add('Send report'); // Backlog.
    await env.tasks.chainAfter(b, a);
    expect((await get(b)).afterTaskId, a);
    expect((await get(b)).status, TaskStatus.blocked);

    await env.tasks.setStatus(a, TaskStatus.completed);
    final started = await get(b);
    expect(started.status, TaskStatus.inProgress);
    expect(started.dueDate, env.today);
  });

  test('a successor keeps a future date when started', () async {
    final a = await add('A', due: env.today);
    final b = await add('B', due: env.today.addDays(5));
    await env.tasks.chainAfter(b, a);
    await env.tasks.updateTask(a, TaskDraft(title: 'A', dueDate: env.today, status: TaskStatus.completed));
    final started = await get(b);
    expect(started.status, TaskStatus.inProgress);
    expect(started.dueDate, env.today.addDays(5));
  });

  test('a chain starts one link at a time', () async {
    final a = await add('A', due: env.today);
    final b = await add('B');
    final c = await add('C');
    await env.tasks.chainAfter(b, a);
    await env.tasks.chainAfter(c, b);
    await env.tasks.setStatus(a, TaskStatus.completed);
    expect((await get(b)).status, TaskStatus.inProgress);
    expect((await get(c)).status, TaskStatus.blocked);
    await env.tasks.setStatus(b, TaskStatus.completed);
    expect((await get(c)).status, TaskStatus.inProgress);
  });

  test('cycles, self links and recurring tasks are refused', () async {
    final a = await add('A');
    final b = await add('B');
    final c = await add('C');
    final r = await add('R', type: TaskType.recurring, rule: RecurrenceRule.daily(env.today));
    await env.tasks.chainAfter(b, a);
    await env.tasks.chainAfter(c, b);
    expect(() => env.tasks.chainAfter(a, c), throwsA(isA<ChainException>()));
    expect(() => env.tasks.chainAfter(a, b), throwsA(isA<ChainException>()));
    expect(() => env.tasks.chainAfter(a, a), throwsA(isA<ChainException>()));
    expect(() => env.tasks.chainAfter(r, a), throwsA(isA<ChainException>()));
    expect(() => env.tasks.chainAfter(a, r), throwsA(isA<ChainException>()));
  });

  test('a task cannot be chained with its own subtask', () async {
    final a = await add('A');
    final sub = await env.tasks.addSubtask(a, 'Sub');
    expect(() => env.tasks.chainAfter(sub, a), throwsA(isA<ChainException>()));
    expect(() => env.tasks.chainAfter(a, sub), throwsA(isA<ChainException>()));
  });

  test('unchaining and deleting the predecessor release a blocked task', () async {
    final a = await add('A');
    final b = await add('B');
    final c = await add('C');
    await env.tasks.chainAfter(b, a);
    await env.tasks.chainAfter(c, a);
    await env.tasks.unchain(b);
    expect((await get(b)).afterTaskId, isNull);
    expect((await get(b)).status, TaskStatus.notStarted);

    await env.tasks.deleteTask(a);
    expect((await get(c)).afterTaskId, isNull);
    expect((await get(c)).status, TaskStatus.notStarted);
  });

  test('agenda folds waiting tasks under their predecessor', () async {
    final a = await add('A', due: env.today);
    final b = await add('B', due: env.today);
    final c = await add('C', due: env.today.addDays(1));
    await add('D', due: env.today);
    await env.tasks.chainAfter(b, a);
    await env.tasks.chainAfter(c, b);

    var ag = await agenda();
    expect(titles(ag), unorderedEquals(['A', 'D']));
    final entry = ag.sections.expand((s) => s.entries).firstWhere((e) => e.task.id == a);
    expect([for (final l in entry.chain) (l.item.task.title, l.depth)], [('B', 1), ('C', 2)]);
    expect(entry.chain.first.item.isWaitingInChain, isTrue);
    expect(entry.chain.first.item.afterTitle, 'A');

    await env.tasks.setStatus(a, TaskStatus.completed);
    ag = await agenda();
    // A stays (done today); B is on its own line, C now folded under B.
    expect(titles(ag), unorderedEquals(['A', 'B', 'D']));
    final bEntry = ag.sections.expand((s) => s.entries).firstWhere((e) => e.task.id == b);
    expect(bEntry.chain.map((l) => l.item.task.title), ['C']);
  });

  test('fold keeps waiting tasks whose predecessor is not in the list', () async {
    final a = await add('A');
    final b = await add('B');
    final other = await add('Other');
    await env.tasks.chainAfter(b, a);
    final waiting = await env.tasks.watchWaitingInChain().first;
    final chains = TaskChains(waiting);
    final items = waiting + [TaskListItem(task: (await get(other)))];
    expect(chains.fold(items, (i) => i.task.id).map((r) => r.$1.task.title), ['B', 'Other']);
    final withA = [TaskListItem(task: await get(a)), ...items];
    expect(chains.fold(withA, (i) => i.task.id).map((r) => r.$1.task.title), ['A', 'Other']);
  });
}

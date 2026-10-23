import 'package:flutter_test/flutter_test.dart';
import 'package:overdue/src/domain/enums.dart';
import 'package:overdue/src/domain/experiments.dart';
import 'package:overdue/src/domain/models.dart';
import 'package:overdue/src/domain/task_query.dart';

import '../helpers.dart';

RemoteRun run(String id, RunStatus status, {String name = '', Map<String, double> metrics = const {}}) =>
    RemoteRun(runId: id * 32, name: name, status: status, metrics: metrics);

void main() {
  late TestEnv env;
  setUp(() => env = TestEnv());
  tearDown(() => env.dispose());

  test('runs from MLflow are added, then updated; local notes and reviews are kept', () async {
    final exp = await env.experiments.create(' LR sweep ', mlflowExperimentId: '12');
    expect((await env.experiments.getExperiment(exp))!.name, 'LR sweep');

    expect(await env.experiments.applyRemoteRuns(exp, [run('a', RunStatus.running, name: 'lr=1e-3')]), 1);
    var a = (await env.experiments.getRuns(exp)).single;
    expect(a.label, 'lr=1e-3');
    expect(a.status, RunStatus.running);
    expect((await env.experiments.getExperiment(exp))!.status, ExperimentStatus.running, reason: 'a run started');
    expect((await env.experiments.getExperiment(exp))!.syncedAt, isNotNull);

    await env.experiments.setRunNotes(a.id, 'diverges after warmup');
    expect(
      await env.experiments.applyRemoteRuns(exp, [
        run('a', RunStatus.finished, name: 'lr=1e-3', metrics: {'loss': 0.3}),
      ]),
      1,
    );
    a = (await env.experiments.getRuns(exp)).single;
    expect(a.status, RunStatus.finished);
    expect(a.metrics, {'loss': 0.3});
    expect(a.notes, 'diverges after warmup');
    expect((await env.experiments.getExperiment(exp))!.status, ExperimentStatus.analysing, reason: 'last run ended');

    // Nothing changed on the server: nothing written.
    expect(
      await env.experiments.applyRemoteRuns(exp, [
        run('a', RunStatus.finished, name: 'lr=1e-3', metrics: {'loss': 0.3}),
      ]),
      0,
    );
  });

  test('runs to review, reviewed mark, and a run restarting', () async {
    final exp = await env.experiments.create('Ablation', mlflowExperimentId: '3');
    await env.experiments.applyRemoteRuns(exp, [
      run('a', RunStatus.finished, name: 'a'),
      run('b', RunStatus.running, name: 'b'),
    ]);
    var review = await env.experiments.watchRunsToReview().first;
    expect(review.map((r) => r.run.name), ['a']);
    expect(review.single.experimentName, 'Ablation');
    expect(review.single.mlflowExperimentId, '3');

    await env.experiments.applyRemoteRuns(exp, [
      run('a', RunStatus.finished, name: 'a'),
      run('b', RunStatus.failed, name: 'b'),
    ]);
    expect((await env.experiments.getExperiment(exp))!.status, ExperimentStatus.analysing);
    final a = (await env.experiments.getRuns(exp)).firstWhere((r) => r.name == 'a');
    await env.experiments.setReviewed(a.id, true);
    review = await env.experiments.watchRunsToReview().first;
    expect(review.map((r) => r.run.name), ['b']);

    // Restarted on the server: no longer reviewed.
    await env.experiments.applyRemoteRuns(exp, [run('a', RunStatus.running, name: 'a')]);
    expect((await env.experiments.getRun(a.id))!.reviewed, isFalse);
    expect(await env.experiments.getRuns(exp), hasLength(2), reason: 'runs missing from the answer are kept');
  });

  test('a manual status is not overridden by an unchanged sync', () async {
    final exp = await env.experiments.create('E', mlflowExperimentId: '1');
    await env.experiments.applyRemoteRuns(exp, [run('a', RunStatus.finished)]);
    await env.experiments.update(exp, status: ExperimentStatus.running);
    await env.experiments.applyRemoteRuns(exp, [run('a', RunStatus.finished)]);
    expect((await env.experiments.getExperiment(exp))!.status, ExperimentStatus.running);
  });

  test('linking another MLflow experiment drops the old runs; only active linked experiments sync', () async {
    final exp = await env.experiments.create('E', mlflowExperimentId: '1');
    await env.experiments.applyRemoteRuns(exp, [run('a', RunStatus.running)]);
    await env.experiments.update(exp, setMlflow: true, mlflowExperimentId: '1');
    expect(await env.experiments.getRuns(exp), hasLength(1), reason: 'same experiment');
    await env.experiments.update(exp, setMlflow: true, mlflowExperimentId: '2');
    expect(await env.experiments.getRuns(exp), isEmpty);
    expect((await env.experiments.getExperiment(exp))!.mlflowExperimentId, '2');

    await env.experiments.create('Not linked');
    final done = await env.experiments.create('Done', mlflowExperimentId: '3');
    await env.experiments.update(done, status: ExperimentStatus.done);
    expect((await env.experiments.linkedExperiments()).map((e) => e.id), [exp]);
  });

  test('tasks link to experiments and runs, and show it in lists', () async {
    final exp = await env.experiments.create('Distillation', mlflowExperimentId: '7');
    await env.experiments.applyRemoteRuns(exp, [run('t', RunStatus.running, name: 'teacher-L')]);
    final r = (await env.experiments.getRuns(exp)).single.id;
    final t1 = await env.tasks.createTask(TaskDraft(title: 'Check loss curves', experimentId: exp, runId: r));
    final t2 = await env.tasks.createTask(TaskDraft(title: 'Write up'));
    await env.experiments.linkTask(t2, experimentId: exp);

    final linked = await env.tasks.watchExperimentTasks(exp).first;
    expect(linked.map((i) => i.task.title), containsAll(['Check loss curves', 'Write up']));
    final item = linked.firstWhere((i) => i.task.id == t1);
    expect(item.experimentName, 'Distillation');
    expect(item.runName, 'teacher-L');

    final all = await env.tasks.watchQuery(const TaskQuery()).first;
    expect(all.firstWhere((i) => i.task.id == t2).experimentName, 'Distillation');

    final summary = (await env.experiments.watchSummaries().first).single;
    expect(summary.runCount, 1);
    expect(summary.runsRunning, 1);
    expect(summary.openTasks, 2);
    expect(await env.experiments.watchOpenTasksPerRun(exp).first, {r: 1});

    await env.tasks.setStatus(t2, TaskStatus.completed);
    expect((await env.experiments.watchSummaries().first).single.openTasks, 1);
  });

  test('linking to a run implies its experiment; unlinking clears both', () async {
    final e1 = await env.experiments.create('One');
    final e2 = await env.experiments.create('Two', mlflowExperimentId: '2');
    await env.experiments.applyRemoteRuns(e2, [run('r', RunStatus.running)]);
    final r2 = (await env.experiments.getRuns(e2)).single.id;
    final t = await env.tasks.createTask(TaskDraft(title: 'x'));

    await env.experiments.linkTask(t, experimentId: e1, runId: r2);
    var task = (await env.tasks.getTask(t))!;
    expect(task.experimentId, e2);
    expect(task.runId, r2);

    await env.experiments.unlinkTask(t);
    task = (await env.tasks.getTask(t))!;
    expect(task.experimentId, isNull);
    expect(task.runId, isNull);
  });

  test('deleting an experiment (or relinking it) keeps the tasks', () async {
    final exp = await env.experiments.create('Throwaway', mlflowExperimentId: '1');
    await env.experiments.applyRemoteRuns(exp, [run('a', RunStatus.running)]);
    final r = (await env.experiments.getRuns(exp)).single.id;
    final t = await env.tasks.createTask(TaskDraft(title: 'keep me', experimentId: exp, runId: r));

    await env.experiments.update(exp, setMlflow: true, mlflowExperimentId: '9');
    var task = (await env.tasks.getTask(t))!;
    expect(task.runId, isNull);
    expect(task.experimentId, exp);

    await env.experiments.delete(exp);
    task = (await env.tasks.getTask(t))!;
    expect(task.experimentId, isNull);
  });

  test('editing a task keeps its experiment link', () async {
    final exp = await env.experiments.create('E');
    final t = await env.tasks.createTask(TaskDraft(title: 'a', experimentId: exp));
    final task = (await env.tasks.getTask(t))!;
    await env.tasks.updateTask(t, TaskDraft.fromTask(task, const [])..title = 'b');
    expect((await env.tasks.getTask(t))!.experimentId, exp);
  });
}

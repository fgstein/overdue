import 'package:flutter_test/flutter_test.dart';
import 'package:overdue/src/domain/enums.dart';
import 'package:overdue/src/domain/experiments.dart';
import 'package:overdue/src/domain/models.dart';
import 'package:overdue/src/domain/task_query.dart';

import '../helpers.dart';

void main() {
  late TestEnv env;
  setUp(() => env = TestEnv());
  tearDown(() => env.dispose());

  const runId = '0a1b2c3d4e5f60718293a4b5c6d7e8f9';

  test('create an experiment and add runs; bare run ids get a URL', () async {
    final exp = await env.experiments.create(' LR sweep ', mlflowUrl: 'http://localhost:5000/#/experiments/12');
    final e = (await env.experiments.getExperiment(exp))!;
    expect(e.name, 'LR sweep');
    expect(e.status, ExperimentStatus.planned);

    final r = await env.experiments.addRun(exp, mlflowRunId: runId);
    final run = (await env.experiments.getRun(r))!;
    expect(run.url, 'http://localhost:5000/#/experiments/12/runs/$runId');
    expect(run.status, RunStatus.running);
    // Launching a run starts a planned experiment.
    expect((await env.experiments.getExperiment(exp))!.status, ExperimentStatus.running);
  });

  test('runs to review, reviewed mark, and experiment moving to "To analyse"', () async {
    final exp = await env.experiments.create('Ablation');
    final a = await env.experiments.addRun(exp, name: 'a');
    final b = await env.experiments.addRun(exp, name: 'b');
    expect(await env.experiments.watchRunsToReview().first, isEmpty);

    await env.experiments.setRunStatus(a, RunStatus.finished);
    expect((await env.experiments.getExperiment(exp))!.status, ExperimentStatus.running, reason: 'b still runs');
    await env.experiments.setRunStatus(b, RunStatus.failed);
    expect((await env.experiments.getExperiment(exp))!.status, ExperimentStatus.analysing);

    var review = await env.experiments.watchRunsToReview().first;
    expect(review.map((r) => r.run.name), ['a', 'b']);
    expect(review.first.experimentName, 'Ablation');

    await env.experiments.setReviewed(a, true);
    review = await env.experiments.watchRunsToReview().first;
    expect(review.map((r) => r.run.name), ['b']);

    // Relaunching a reviewed run clears the mark.
    await env.experiments.setRunStatus(a, RunStatus.running);
    expect((await env.experiments.getRun(a))!.reviewed, isFalse);
  });

  test('tasks link to experiments and runs, and show it in lists', () async {
    final exp = await env.experiments.create('Distillation');
    final run = await env.experiments.addRun(exp, name: 'teacher-L');
    final t1 = await env.tasks.createTask(TaskDraft(title: 'Check loss curves', experimentId: exp, runId: run));
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
    expect(await env.experiments.watchOpenTasksPerRun(exp).first, {run: 1});

    await env.tasks.setStatus(t2, TaskStatus.completed);
    expect((await env.experiments.watchSummaries().first).single.openTasks, 1);
  });

  test('linking to a run implies its experiment; unlinking clears both', () async {
    final e1 = await env.experiments.create('One');
    final e2 = await env.experiments.create('Two');
    final r2 = await env.experiments.addRun(e2, name: 'r');
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

  test('deleting a run or an experiment keeps the tasks', () async {
    final exp = await env.experiments.create('Throwaway');
    final run = await env.experiments.addRun(exp);
    final t = await env.tasks.createTask(TaskDraft(title: 'keep me', experimentId: exp, runId: run));

    await env.experiments.deleteRun(run);
    var task = (await env.tasks.getTask(t))!;
    expect(task.runId, isNull);
    expect(task.experimentId, exp);

    await env.experiments.delete(exp);
    task = (await env.tasks.getTask(t))!;
    expect(task.experimentId, isNull);
    expect(await env.experiments.getAllRuns(), isEmpty);
  });

  test('editing a task keeps its experiment link', () async {
    final exp = await env.experiments.create('E');
    final t = await env.tasks.createTask(TaskDraft(title: 'a', experimentId: exp));
    final task = (await env.tasks.getTask(t))!;
    await env.tasks.updateTask(t, TaskDraft.fromTask(task, const [])..title = 'b');
    expect((await env.tasks.getTask(t))!.experimentId, exp);
  });
}

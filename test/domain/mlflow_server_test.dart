import 'package:flutter_test/flutter_test.dart';
import 'package:overdue/src/domain/experiments.dart';

void main() {
  const runId = '0a1b2c3d4e5f60718293a4b5c6d7e8f9';

  test('server root from what the user types or pastes', () {
    expect(MlflowServer.normalize('http://localhost:5000'), 'http://localhost:5000');
    expect(MlflowServer.normalize(' localhost:5000/ '), 'http://localhost:5000');
    expect(MlflowServer.normalize('http://localhost:5000/#/experiments/12/runs/$runId'), 'http://localhost:5000');
    expect(MlflowServer.normalize('https://ml.example.org/mlflow/#/experiments/7'), 'https://ml.example.org/mlflow');
    expect(
      MlflowServer.normalize('https://adb-1.azuredatabricks.net/ml/experiments/42'),
      'https://adb-1.azuredatabricks.net',
    );
    expect(MlflowServer.normalize('http://u:p@host:5000/'), 'http://u:p@host:5000');
    expect(MlflowServer.normalize(''), isNull);
    expect(MlflowServer.normalize(null), isNull);
    expect(MlflowServer.normalize('ftp://host'), isNull);
  });

  test('UI links (without credentials)', () {
    expect(MlflowServer.experimentUrl('http://localhost:5000', '12'), 'http://localhost:5000/#/experiments/12');
    expect(MlflowServer.runUrl('http://u:p@host:5000', '12', runId), 'http://host:5000/#/experiments/12/runs/$runId');
  });

  test('run label and stored metrics/params', () {
    final now = DateTime.utc(2026);
    expect(ExperimentRun(id: 1, experimentId: 1, mlflowRunId: runId, createdAt: now, updatedAt: now).label, '0a1b2c3d');
    expect(
      ExperimentRun(id: 1, experimentId: 1, mlflowRunId: runId, name: 'seed 2', createdAt: now, updatedAt: now).label,
      'seed 2',
    );
    expect(ExperimentRun.decodeMetrics('{"loss": 0.5, "step": 3}'), {'loss': 0.5, 'step': 3.0});
    expect(ExperimentRun.decodeParams('{"lr": "3e-4"}'), {'lr': '3e-4'});
    expect(ExperimentRun.decodeMetrics('not json'), isEmpty);
  });

  test('MLflow run statuses', () {
    expect(RunStatus.fromMlflow('RUNNING'), RunStatus.running);
    expect(RunStatus.fromMlflow('FINISHED'), RunStatus.finished);
    expect(RunStatus.fromMlflow('FAILED'), RunStatus.failed);
    expect(RunStatus.fromMlflow('KILLED'), RunStatus.killed);
    expect(RunStatus.fromMlflow('SCHEDULED'), RunStatus.scheduled);
    expect(RunStatus.fromMlflow(null), RunStatus.scheduled);
  });
}

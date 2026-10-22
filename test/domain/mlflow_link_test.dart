import 'package:flutter_test/flutter_test.dart';
import 'package:overdue/src/domain/experiments.dart';

void main() {
  const runId = '0a1b2c3d4e5f60718293a4b5c6d7e8f9';

  test('MLflow UI run URL', () {
    final l = MlflowLink.parse('http://localhost:5000/#/experiments/12/runs/$runId')!;
    expect(l.baseUrl, 'http://localhost:5000');
    expect(l.experimentId, '12');
    expect(l.runId, runId);
  });

  test('run URL with a tab and a query, behind a path prefix', () {
    final l = MlflowLink.parse('https://ml.example.org/mlflow/#/experiments/7/runs/$runId/model-metrics?x=1')!;
    expect(l.baseUrl, 'https://ml.example.org/mlflow');
    expect(l.experimentId, '7');
    expect(l.runId, runId);
  });

  test('experiment URL without a run', () {
    final l = MlflowLink.parse('http://10.0.0.5:5000/#/experiments/3?searchFilter=')!;
    expect(l.baseUrl, 'http://10.0.0.5:5000');
    expect(l.experimentId, '3');
    expect(l.runId, isNull);
  });

  test('Databricks URL', () {
    final l = MlflowLink.parse('https://adb-1.azuredatabricks.net/ml/experiments/4242/runs/$runId')!;
    expect(l.baseUrl, 'https://adb-1.azuredatabricks.net');
    expect(l.experimentId, '4242');
    expect(l.runId, runId);
  });

  test('bare run id (any case, surrounding spaces)', () {
    final l = MlflowLink.parse('  ${runId.toUpperCase()} ')!;
    expect(l.runId, runId);
    expect(l.baseUrl, isNull);
  });

  test('not a link', () {
    expect(MlflowLink.parse(null), isNull);
    expect(MlflowLink.parse(''), isNull);
    expect(MlflowLink.parse('lr sweep'), isNull);
    expect(MlflowLink.parse('abc123'), isNull);
  });

  test('run URL derived from the experiment page', () {
    expect(
      MlflowLink.runUrl('http://localhost:5000/#/experiments/12', runId),
      'http://localhost:5000/#/experiments/12/runs/$runId',
    );
    expect(MlflowLink.runUrl(null, runId), isNull);
    expect(MlflowLink.runUrl('http://localhost:5000/', runId), isNull);
  });

  test('short id and run label', () {
    expect(MlflowLink.shortId(runId), '0a1b2c3d');
    final now = DateTime.utc(2026);
    expect(
      ExperimentRun(id: 1, experimentId: 1, name: '', mlflowRunId: runId, createdAt: now, updatedAt: now).label,
      '0a1b2c3d',
    );
    expect(ExperimentRun(id: 1, experimentId: 1, name: 'seed 2', createdAt: now, updatedAt: now).label, 'seed 2');
  });
}

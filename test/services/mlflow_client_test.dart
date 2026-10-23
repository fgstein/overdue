import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:overdue/src/domain/experiments.dart';
import 'package:overdue/src/services/mlflow/mlflow_client.dart';

/// A minimal MLflow REST API on localhost.
class FakeMlflow {
  late HttpServer server;
  final requests = <(String path, Map<String, dynamic> body, String? auth)>[];
  int status = 200;
  String? rawRuns;

  String get url => 'http://127.0.0.1:${server.port}';

  Future<void> start() async {
    server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    server.listen((req) async {
      final body = jsonDecode(await utf8.decoder.bind(req).join()) as Map<String, dynamic>;
      requests.add((req.uri.path, body, req.headers.value(HttpHeaders.authorizationHeader)));
      req.response.statusCode = status;
      if (req.uri.path.endsWith('experiments/search')) {
        req.response.write(
          jsonEncode(
            body['page_token'] == null
                ? {
                    'experiments': [
                      {'experiment_id': '12', 'name': 'lr-sweep'},
                    ],
                    'next_page_token': 'p2',
                  }
                : {
                    'experiments': [
                      {'experiment_id': '3', 'name': 'Ablation'},
                    ],
                  },
          ),
        );
      } else if (req.uri.path.endsWith('runs/search')) {
        req.response.write(
          rawRuns ??
              jsonEncode({
                'runs': [
                  {
                    'info': {
                      'run_id': 'a' * 32,
                      'run_name': 'lr=3e-4',
                      'status': 'FINISHED',
                      'start_time': 1761120000000,
                      'end_time': 1761123600000,
                    },
                    'data': {
                      'metrics': [
                        {'key': 'val_loss', 'value': 0.42, 'step': 10},
                      ],
                      'params': [
                        {'key': 'lr', 'value': '3e-4'},
                      ],
                    },
                  },
                ],
              }),
        );
      } else {
        req.response.statusCode = 404;
      }
      await req.response.close();
    });
  }
}

void main() {
  late FakeMlflow fake;
  setUp(() async => (fake = FakeMlflow()).start());
  tearDown(() => fake.server.close(force: true));

  test('lists experiments across pages, sorted by name', () async {
    final list = await MlflowClient(fake.url).experiments();
    expect(list.map((e) => (e.id, e.name)), [('3', 'Ablation'), ('12', 'lr-sweep')]);
    expect(fake.requests.first.$1, '/api/2.0/mlflow/experiments/search');
    expect(fake.requests.last.$2['page_token'], 'p2');
  });

  test('reads runs with status, times, metrics and params', () async {
    final runs = await MlflowClient(fake.url).runs('12');
    final r = runs.single;
    expect(r.runId, 'a' * 32);
    expect(r.name, 'lr=3e-4');
    expect(r.status, RunStatus.finished);
    expect(r.startedAt, DateTime.fromMillisecondsSinceEpoch(1761120000000, isUtc: true));
    expect(r.endedAt!.difference(r.startedAt!), const Duration(hours: 1));
    expect(r.metrics, {'val_loss': 0.42});
    expect(r.params, {'lr': '3e-4'});
    expect(fake.requests.single.$2['experiment_ids'], ['12']);
  });

  test('NaN metrics (written as bare tokens by MLflow) are skipped', () async {
    fake.rawRuns =
        '{"runs": [{"info": {"run_id": "${'b' * 32}", "status": "RUNNING", "end_time": null}, '
        '"data": {"metrics": [{"key": "loss", "value": NaN}, {"key": "acc", "value": 0.9}], '
        '"tags": [{"key": "mlflow.runName", "value": "old-style"}]}}]}';
    final r = (await MlflowClient(fake.url).runs('12')).single;
    expect(r.metrics, {'acc': 0.9});
    expect(r.name, 'old-style');
    expect(r.status, RunStatus.running);
    expect(r.endedAt, isNull);
  });

  test('sends a bearer token, or basic auth from the URL', () async {
    await MlflowClient(fake.url, token: 'dapi123').experiments();
    expect(fake.requests.first.$3, 'Bearer dapi123');
    fake.requests.clear();
    await MlflowClient(fake.url.replaceFirst('http://', 'http://alice:s3cret@')).runs('12');
    expect(fake.requests.single.$3, 'Basic ${base64Encode(utf8.encode('alice:s3cret'))}');
  });

  test('errors are explained', () async {
    fake.status = 401;
    await expectLater(MlflowClient(fake.url).runs('12'), throwsA(isA<MlflowException>()));
    final port = fake.server.port;
    await fake.server.close(force: true);
    await expectLater(
      MlflowClient('http://127.0.0.1:$port', timeout: const Duration(seconds: 2)).runs('12'),
      throwsA(isA<MlflowException>().having((e) => e.message, 'message', contains('Cannot reach'))),
    );
  });
}

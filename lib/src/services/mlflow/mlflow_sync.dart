import 'dart:async';

import 'package:flutter/foundation.dart';

import '../../data/experiment_repository.dart';
import '../../data/settings_repository.dart';
import '../../domain/experiments.dart';
import 'mlflow_client.dart';

typedef MlflowClientFactory = MlflowClient Function(String server, String? token);

/// Keeps the runs of linked experiments in step with the MLflow server:
/// periodically (main window only) and on demand.
class MlflowSync extends ChangeNotifier {
  MlflowSync({required this.experiments, required this.settings, MlflowClientFactory? clientFactory})
    : _clientFactory = clientFactory ?? ((server, token) => MlflowClient(server, token: token));

  final ExperimentRepository experiments;
  final AppSettings settings;
  final MlflowClientFactory _clientFactory;

  Timer? _timer;
  int? _timerMinutes;
  Future<void>? _running;

  /// Error of the last synchronisation (null when it succeeded).
  String? lastError;
  DateTime? lastSync;
  bool get busy => _running != null;

  /// Normalised server root, or null when none (or an invalid one) is set.
  String? get server => MlflowServer.normalize(settings.mlflowServer);
  bool get configured => server != null;

  MlflowClient _client() {
    final s = server;
    if (s == null) throw const MlflowException('Set the MLflow server in Settings first');
    final token = settings.mlflowToken.trim();
    return _clientFactory(s, token.isEmpty ? null : token);
  }

  String? experimentUrl(Experiment e) {
    final s = server, id = e.mlflowExperimentId;
    return s == null || id == null ? null : MlflowServer.experimentUrl(s, id);
  }

  String? runUrl(Experiment e, ExperimentRun r) {
    final s = server, id = e.mlflowExperimentId;
    return s == null || id == null ? null : MlflowServer.runUrl(s, id, r.mlflowRunId);
  }

  /// Experiments of the server (to link one). Throws [MlflowException].
  Future<List<RemoteExperiment>> listExperiments() => _client().experiments();

  /// Reads the runs of one experiment. Throws [MlflowException].
  Future<int> syncExperiment(int id) async {
    final e = await experiments.getExperiment(id);
    final mlflowId = e?.mlflowExperimentId;
    if (mlflowId == null) return 0;
    final runs = await _client().runs(mlflowId);
    return experiments.applyRemoteRuns(id, runs);
  }

  /// Synchronises every active linked experiment; errors are kept in
  /// [lastError] (not thrown). Concurrent calls share one run.
  Future<void> syncAll() {
    if (!configured) return Future.value();
    return _running ??= _syncAll().whenComplete(() {
      _running = null;
      notifyListeners();
    });
  }

  Future<void> _syncAll() async {
    notifyListeners();
    try {
      final client = _client();
      for (final e in await experiments.linkedExperiments()) {
        await experiments.applyRemoteRuns(e.id, await client.runs(e.mlflowExperimentId!));
      }
      lastError = null;
      lastSync = DateTime.now();
    } on MlflowException catch (e) {
      lastError = e.message;
    } catch (e) {
      lastError = '$e';
      debugPrint('MLflow synchronisation failed: $e');
    }
  }

  /// Starts the periodic refresh (follows the settings).
  void start() {
    settings.addListener(_reschedule);
    _reschedule();
    unawaited(syncAll());
  }

  void _reschedule() {
    final minutes = configured ? settings.mlflowRefreshMinutes : 0;
    if (minutes == _timerMinutes) return;
    _timerMinutes = minutes;
    _timer?.cancel();
    _timer = minutes <= 0 ? null : Timer.periodic(Duration(minutes: minutes), (_) => unawaited(syncAll()));
  }

  @override
  void dispose() {
    settings.removeListener(_reschedule);
    _timer?.cancel();
    super.dispose();
  }
}

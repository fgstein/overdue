/// Experiments and their runs, mirrored from an MLflow tracking server.
///
/// An experiment is linked to an MLflow experiment; its runs (name, status,
/// times, metrics, params) are read from the server, notes and the
/// "reviewed" mark stay local. The integer [code] values are persisted and
/// must never be renumbered.
library;

import 'dart:convert';

enum ExperimentStatus {
  idea(0, 'Idea'),
  planned(1, 'Planned'),
  running(2, 'Running'),
  analysing(3, 'To analyse'),
  done(4, 'Done'),
  abandoned(5, 'Abandoned');

  const ExperimentStatus(this.code, this.label);
  final int code;
  final String label;

  bool get isActive => this != done && this != abandoned;

  /// Order of the sections in the Experiments tab (most pressing first).
  int get boardOrder => switch (this) {
    analysing => 0,
    running => 1,
    planned => 2,
    idea => 3,
    done => 4,
    abandoned => 5,
  };

  static ExperimentStatus fromCode(int code) => values.firstWhere((s) => s.code == code, orElse: () => idea);
}

/// Mirrors MLflow's run statuses (SCHEDULED, RUNNING, FINISHED, FAILED, KILLED).
enum RunStatus {
  scheduled(0, 'Scheduled'),
  running(1, 'Running'),
  finished(2, 'Finished'),
  failed(3, 'Failed'),
  killed(4, 'Killed');

  const RunStatus(this.code, this.label);
  final int code;
  final String label;

  /// The run is over: its results can be reviewed.
  bool get isTerminal => this == finished || this == failed || this == killed;

  static RunStatus fromCode(int code) => values.firstWhere((s) => s.code == code, orElse: () => scheduled);

  /// From MLflow's `RunStatus` name (`RUNNING`, `FINISHED`…).
  static RunStatus fromMlflow(String? name) =>
      values.firstWhere((s) => s.name.toUpperCase() == name, orElse: () => scheduled);

  static const List<int> terminalCodes = [2, 3, 4];
}

class Experiment {
  const Experiment({
    required this.id,
    required this.name,
    this.projectId,
    this.status = ExperimentStatus.idea,
    this.description = '',
    this.conclusion = '',
    this.mlflowExperimentId,
    this.syncedAt,
    required this.createdAt,
    required this.updatedAt,
  });
  final int id;
  final String name;
  final int? projectId;
  final ExperimentStatus status;

  /// Markdown: hypothesis, set-up, parameters to try…
  final String description;

  /// Markdown: what was learned.
  final String conclusion;

  /// MLflow experiment whose runs are synchronised (null = not linked yet).
  final String? mlflowExperimentId;

  /// Last successful synchronisation.
  final DateTime? syncedAt;
  final DateTime createdAt;
  final DateTime updatedAt;
}

class ExperimentRun {
  const ExperimentRun({
    required this.id,
    required this.experimentId,
    required this.mlflowRunId,
    this.name = '',
    this.status = RunStatus.scheduled,
    this.startedAt,
    this.endedAt,
    this.metrics = const {},
    this.params = const {},
    this.notes = '',
    this.reviewedAt,
    required this.createdAt,
    required this.updatedAt,
  });
  final int id;
  final int experimentId;

  /// MLflow run id (32 hex characters).
  final String mlflowRunId;
  final String name;
  final RunStatus status;
  final DateTime? startedAt;
  final DateTime? endedAt;

  /// Latest value of each metric, and the run's params (from MLflow).
  final Map<String, double> metrics;
  final Map<String, String> params;

  /// Markdown, local: observations, what to do next.
  final String notes;

  /// When the results were reviewed; null = not reviewed yet.
  final DateTime? reviewedAt;
  final DateTime createdAt;
  final DateTime updatedAt;

  bool get reviewed => reviewedAt != null;

  /// Over and not reviewed yet.
  bool get toReview => status.isTerminal && !reviewed;

  /// "name" or the short run id when the run has no name.
  String get label => name.isNotEmpty ? name : MlflowServer.shortId(mlflowRunId);

  static Map<String, double> decodeMetrics(String json) => _decode(json, (v) => (v as num).toDouble());
  static Map<String, String> decodeParams(String json) => _decode(json, (v) => '$v');

  static Map<String, T> _decode<T>(String json, T Function(Object v) f) {
    try {
      final m = jsonDecode(json);
      if (m is! Map) return const {};
      return {
        for (final e in m.entries)
          if (e.value != null) '${e.key}': f(e.value as Object),
      };
    } catch (_) {
      return const {}; // Corrupt JSON: show nothing rather than crash.
    }
  }
}

/// An experiment as listed by the MLflow server.
class RemoteExperiment {
  const RemoteExperiment({required this.id, required this.name});
  final String id;
  final String name;
}

/// A run as returned by the MLflow server.
class RemoteRun {
  const RemoteRun({
    required this.runId,
    this.name = '',
    this.status = RunStatus.scheduled,
    this.startedAt,
    this.endedAt,
    this.metrics = const {},
    this.params = const {},
  });
  final String runId;
  final String name;
  final RunStatus status;
  final DateTime? startedAt;
  final DateTime? endedAt;
  final Map<String, double> metrics;
  final Map<String, String> params;
}

/// Row of the Experiments tab.
class ExperimentSummary {
  const ExperimentSummary({
    required this.experiment,
    this.projectName,
    this.projectColor,
    this.runCount = 0,
    this.runsRunning = 0,
    this.runsToReview = 0,
    this.openTasks = 0,
  });
  final Experiment experiment;
  final String? projectName;
  final int? projectColor;
  final int runCount;
  final int runsRunning;
  final int runsToReview;
  final int openTasks;
}

/// A run with its experiment's name (e.g. in "Runs to review").
class RunWithExperiment {
  const RunWithExperiment(this.run, this.experimentName, {this.mlflowExperimentId});
  final ExperimentRun run;
  final String experimentName;
  final String? mlflowExperimentId;
}

/// URLs of an MLflow tracking server's UI.
abstract final class MlflowServer {
  /// Server root from what the user typed or pasted: adds `http://` when no
  /// scheme is given and drops any UI path (`/#/experiments/12/…`).
  /// Null when it is not an http(s) URL.
  static String? normalize(String? input) {
    var s = input?.trim() ?? '';
    if (s.isEmpty) return null;
    if (!s.contains('://')) s = 'http://$s';
    final uri = Uri.tryParse(s);
    if (uri == null || (uri.scheme != 'http' && uri.scheme != 'https') || uri.host.isEmpty) return null;
    final cut = s.indexOf(RegExp(r'/?#|/ml/experiments(/|$)|/experiments(/|$)|\?'), uri.scheme.length + 3);
    var base = cut < 0 ? s : s.substring(0, cut);
    while (base.endsWith('/')) {
      base = base.substring(0, base.length - 1);
    }
    return base;
  }

  static String experimentUrl(String server, String experimentId) => '${_ui(server)}/#/experiments/$experimentId';

  static String runUrl(String server, String experimentId, String runId) =>
      '${_ui(server)}/#/experiments/$experimentId/runs/$runId';

  /// Credentials given as `http://user:password@host` are for the API only;
  /// the browser asks for them itself.
  static String _ui(String server) {
    final uri = Uri.parse(server);
    return uri.userInfo.isEmpty ? server : uri.replace(userInfo: '').toString();
  }

  /// First 8 characters of a run id, as MLflow shows them.
  static String shortId(String runId) => runId.length > 8 ? runId.substring(0, 8) : runId;
}

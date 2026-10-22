/// Experiments (e.g. ML experiments tracked in MLflow) and their runs.
///
/// Overdue never talks to an MLflow server: an experiment or run only keeps a
/// reference (ids and the URL of its MLflow page, opened in the browser).
/// The integer [code] values are persisted and must never be renumbered.
library;

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
    this.mlflowUrl,
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

  /// Page of the experiment in the MLflow UI.
  final String? mlflowUrl;
  final DateTime createdAt;
  final DateTime updatedAt;

  MlflowLink? get link => MlflowLink.parse(mlflowUrl);
}

class ExperimentRun {
  const ExperimentRun({
    required this.id,
    required this.experimentId,
    required this.name,
    this.mlflowRunId,
    this.url,
    this.status = RunStatus.scheduled,
    this.notes = '',
    this.reviewedAt,
    required this.createdAt,
    required this.updatedAt,
  });
  final int id;
  final int experimentId;
  final String name;

  /// MLflow run id (32 hex characters).
  final String? mlflowRunId;

  /// Page of the run in the MLflow UI.
  final String? url;
  final RunStatus status;

  /// Markdown: parameters, observations, results.
  final String notes;

  /// When the results were reviewed; null = not reviewed yet.
  final DateTime? reviewedAt;
  final DateTime createdAt;
  final DateTime updatedAt;

  bool get reviewed => reviewedAt != null;

  /// Over and not reviewed yet.
  bool get toReview => status.isTerminal && !reviewed;

  /// "name" or the short run id when the run has no name.
  String get label => name.isNotEmpty ? name : (mlflowRunId == null ? 'Run $id' : MlflowLink.shortId(mlflowRunId!));
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
  const RunWithExperiment(this.run, this.experimentName);
  final ExperimentRun run;
  final String experimentName;
}

/// What can be extracted from an MLflow URL (or a bare run id), offline.
///
/// Understands the MLflow UI (`http://host:5000/#/experiments/12/runs/<id>`,
/// with any trailing tab such as `/model-metrics`) and Databricks
/// (`https://…/ml/experiments/12/runs/<id>`, `…#mlflow/experiments/12/runs/<id>`).
class MlflowLink {
  const MlflowLink({this.baseUrl, this.experimentId, this.runId});

  /// Tracking server UI root, e.g. `http://localhost:5000`.
  final String? baseUrl;
  final String? experimentId;
  final String? runId;

  static final _runId = RegExp(r'^[0-9a-f]{32}$');
  static final _path = RegExp(r'experiments/([^/?#&\s]+)(?:/runs/([0-9A-Za-z_-]+))?');

  static bool isRunId(String s) => _runId.hasMatch(s);

  /// First 8 characters of a run id, as MLflow shows them.
  static String shortId(String runId) => runId.length > 8 ? runId.substring(0, 8) : runId;

  /// Null when [input] is neither an MLflow URL nor a run id.
  static MlflowLink? parse(String? input) {
    final s = input?.trim() ?? '';
    if (s.isEmpty) return null;
    if (isRunId(s.toLowerCase())) return MlflowLink(runId: s.toLowerCase());
    final uri = Uri.tryParse(s);
    if (uri == null || !uri.hasScheme || !uri.scheme.startsWith('http') || uri.host.isEmpty) return null;
    final m = _path.firstMatch(s);
    final cut = s.indexOf(RegExp(r'/?#|/ml/experiments/|/experiments/'));
    final base = cut < 0 ? '${uri.origin}${uri.path}' : s.substring(0, cut);
    return MlflowLink(
      baseUrl: base.endsWith('/') ? base.substring(0, base.length - 1) : base,
      experimentId: m?.group(1),
      runId: m?.group(2),
    );
  }

  /// URL of [runId]'s page in the experiment whose page is [experimentUrl]
  /// (MLflow UI layout), or null when it cannot be derived.
  static String? runUrl(String? experimentUrl, String runId) {
    final e = parse(experimentUrl);
    if (e?.baseUrl == null || e?.experimentId == null) return null;
    return '${e!.baseUrl}/#/experiments/${e.experimentId}/runs/$runId';
  }
}

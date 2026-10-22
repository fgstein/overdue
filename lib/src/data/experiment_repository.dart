import 'package:drift/drift.dart';

import '../core/local_date.dart';
import '../domain/experiments.dart';
import 'database.dart';
import 'mappers.dart';

/// Experiments, their runs and the links between tasks and them.
class ExperimentRepository {
  ExperimentRepository(this.db, {Clock clock = const SystemClock()}) : _clock = clock;

  final AppDatabase db;
  final Clock _clock;
  int get _now => _clock.now().toUtc().millisecondsSinceEpoch;

  static const _terminalRuns = '(2,3,4)';
  static const _closedTasks = '(2,6)';

  // ---------------------------------------------------------------------------
  // Reads
  // ---------------------------------------------------------------------------

  /// Every experiment with its project and counters, most recently updated first.
  Stream<List<ExperimentSummary>> watchSummaries() => db
      .customSelect(
        '''
        SELECT e.*, p.name AS p_name, p.color AS p_color,
          (SELECT COUNT(*) FROM experiment_runs r WHERE r.experiment_id = e.id) AS run_count,
          (SELECT COUNT(*) FROM experiment_runs r WHERE r.experiment_id = e.id AND r.status = 1) AS run_running,
          (SELECT COUNT(*) FROM experiment_runs r WHERE r.experiment_id = e.id
             AND r.status IN $_terminalRuns AND r.reviewed_at IS NULL) AS run_review,
          (SELECT COUNT(*) FROM tasks t WHERE t.experiment_id = e.id AND t.status NOT IN $_closedTasks) AS open_tasks
        FROM experiments e LEFT JOIN projects p ON p.id = e.project_id
        ORDER BY e.updated_at DESC, e.id DESC''',
        readsFrom: {db.experiments, db.experimentRuns, db.projects, db.tasks},
      )
      .watch()
      .map(
        (rows) => [
          for (final r in rows)
            ExperimentSummary(
              experiment: db.experiments.map(r.data).toDomain(),
              projectName: r.readNullable<String>('p_name'),
              projectColor: r.readNullable<int>('p_color'),
              runCount: r.read<int>('run_count'),
              runsRunning: r.read<int>('run_running'),
              runsToReview: r.read<int>('run_review'),
              openTasks: r.read<int>('open_tasks'),
            ),
        ],
      );

  Stream<List<Experiment>> watchAll() =>
      (db.select(db.experiments)..orderBy([(e) => OrderingTerm.desc(e.updatedAt), (e) => OrderingTerm.desc(e.id)]))
          .watch()
          .map((rows) => rows.map((r) => r.toDomain()).toList());

  Stream<Experiment?> watchExperiment(int id) =>
      (db.select(db.experiments)..where((e) => e.id.equals(id))).watchSingleOrNull().map((r) => r?.toDomain());

  Future<Experiment?> getExperiment(int id) =>
      (db.select(db.experiments)..where((e) => e.id.equals(id))).getSingleOrNull().then((r) => r?.toDomain());

  /// Runs of an experiment, newest first.
  Stream<List<ExperimentRun>> watchRuns(int experimentId) =>
      (db.select(db.experimentRuns)
            ..where((r) => r.experimentId.equals(experimentId))
            ..orderBy([(r) => OrderingTerm.desc(r.createdAt), (r) => OrderingTerm.desc(r.id)]))
          .watch()
          .map((rows) => rows.map((r) => r.toDomain()).toList());

  Future<List<ExperimentRun>> getRuns(int experimentId) => watchRuns(experimentId).first;

  /// Every run, newest first (pickers).
  Future<List<ExperimentRun>> getAllRuns() async =>
      (await (db.select(
            db.experimentRuns,
          )..orderBy([(r) => OrderingTerm.desc(r.createdAt), (r) => OrderingTerm.desc(r.id)])).get())
          .map((r) => r.toDomain())
          .toList();

  Future<ExperimentRun?> getRun(int id) =>
      (db.select(db.experimentRuns)..where((r) => r.id.equals(id))).getSingleOrNull().then((r) => r?.toDomain());

  /// Finished, failed or killed runs whose results were not reviewed yet,
  /// oldest first.
  Stream<List<RunWithExperiment>> watchRunsToReview() => db
      .customSelect(
        'SELECT r.*, e.name AS e_name FROM experiment_runs r JOIN experiments e ON e.id = r.experiment_id '
        'WHERE r.status IN $_terminalRuns AND r.reviewed_at IS NULL ORDER BY r.updated_at, r.id',
        readsFrom: {db.experimentRuns, db.experiments},
      )
      .watch()
      .map(
        (rows) => [
          for (final r in rows) RunWithExperiment(db.experimentRuns.map(r.data).toDomain(), r.read<String>('e_name')),
        ],
      );

  /// Open tasks per run of an experiment (run id -> count).
  Stream<Map<int, int>> watchOpenTasksPerRun(int experimentId) => db
      .customSelect(
        'SELECT run_id, COUNT(*) AS n FROM tasks WHERE experiment_id = ? AND run_id IS NOT NULL '
        'AND status NOT IN $_closedTasks GROUP BY run_id',
        variables: [Variable.withInt(experimentId)],
        readsFrom: {db.tasks},
      )
      .watch()
      .map((rows) => {for (final r in rows) r.read<int>('run_id'): r.read<int>('n')});

  // ---------------------------------------------------------------------------
  // Experiments
  // ---------------------------------------------------------------------------

  Future<int> create(
    String name, {
    int? projectId,
    ExperimentStatus status = ExperimentStatus.planned,
    String description = '',
    String? mlflowUrl,
  }) {
    final now = _now;
    return db
        .into(db.experiments)
        .insert(
          ExperimentsCompanion.insert(
            name: name.trim(),
            projectId: Value(projectId),
            status: Value(status.code),
            description: Value(description),
            mlflowUrl: Value(_blankToNull(mlflowUrl)),
            createdAt: now,
            updatedAt: now,
          ),
        );
  }

  /// Updates the given fields; [projectId] and [mlflowUrl] are only changed
  /// when [setProject] / [setUrl] are true (so they can be cleared).
  Future<void> update(
    int id, {
    String? name,
    ExperimentStatus? status,
    String? description,
    String? conclusion,
    bool setProject = false,
    int? projectId,
    bool setUrl = false,
    String? mlflowUrl,
  }) => (db.update(db.experiments)..where((e) => e.id.equals(id))).write(
    ExperimentsCompanion(
      name: name == null ? const Value.absent() : Value(name.trim()),
      status: status == null ? const Value.absent() : Value(status.code),
      description: description == null ? const Value.absent() : Value(description),
      conclusion: conclusion == null ? const Value.absent() : Value(conclusion),
      projectId: setProject ? Value(projectId) : const Value.absent(),
      mlflowUrl: setUrl ? Value(_blankToNull(mlflowUrl)) : const Value.absent(),
      updatedAt: Value(_now),
    ),
  );

  /// Deletes an experiment and its runs. Linked tasks are kept, unlinked.
  Future<void> delete(int id) => (db.delete(db.experiments)..where((e) => e.id.equals(id))).go();

  // ---------------------------------------------------------------------------
  // Runs
  // ---------------------------------------------------------------------------

  /// Adds a run. Without [url], the URL is derived from the experiment's
  /// MLflow page when [mlflowRunId] is known.
  Future<int> addRun(
    int experimentId, {
    String name = '',
    String? mlflowRunId,
    String? url,
    RunStatus status = RunStatus.running,
    String notes = '',
  }) => db.transaction(() async {
    final now = _now;
    final runId = _blankToNull(mlflowRunId);
    var link = _blankToNull(url);
    if (link == null && runId != null) {
      link = MlflowLink.runUrl((await getExperiment(experimentId))?.mlflowUrl, runId);
    }
    final id = await db
        .into(db.experimentRuns)
        .insert(
          ExperimentRunsCompanion.insert(
            experimentId: experimentId,
            name: Value(name.trim()),
            mlflowRunId: Value(runId),
            url: Value(link),
            status: Value(status.code),
            notes: Value(notes),
            createdAt: now,
            updatedAt: now,
          ),
        );
    await _touch(experimentId, now);
    // Launching a run starts a planned experiment.
    if (status == RunStatus.running) {
      await db.customUpdate(
        'UPDATE experiments SET status = ? WHERE id = ? AND status IN (?, ?)',
        variables: [
          Variable.withInt(ExperimentStatus.running.code),
          Variable.withInt(experimentId),
          Variable.withInt(ExperimentStatus.idea.code),
          Variable.withInt(ExperimentStatus.planned.code),
        ],
        updates: {db.experiments},
      );
    }
    return id;
  });

  Future<void> updateRun(
    int id, {
    String? name,
    bool setRunId = false,
    String? mlflowRunId,
    bool setUrl = false,
    String? url,
    String? notes,
  }) => db.transaction(() async {
    final now = _now;
    await (db.update(db.experimentRuns)..where((r) => r.id.equals(id))).write(
      ExperimentRunsCompanion(
        name: name == null ? const Value.absent() : Value(name.trim()),
        mlflowRunId: setRunId ? Value(_blankToNull(mlflowRunId)) : const Value.absent(),
        url: setUrl ? Value(_blankToNull(url)) : const Value.absent(),
        notes: notes == null ? const Value.absent() : Value(notes),
        updatedAt: Value(now),
      ),
    );
    await _touchRunExperiment(id, now);
  });

  /// Changes a run's status. A run that is no longer over loses its
  /// "reviewed" mark; when the last running run of a running experiment
  /// ends, the experiment moves to "To analyse".
  Future<void> setRunStatus(int id, RunStatus status) => db.transaction(() async {
    final now = _now;
    await (db.update(db.experimentRuns)..where((r) => r.id.equals(id))).write(
      ExperimentRunsCompanion(
        status: Value(status.code),
        reviewedAt: status.isTerminal ? const Value.absent() : const Value(null),
        updatedAt: Value(now),
      ),
    );
    final run = await getRun(id);
    if (run == null) return;
    await _touch(run.experimentId, now);
    final exp = await getExperiment(run.experimentId);
    if (exp == null) return;
    final runs = await getRuns(run.experimentId);
    final anyActive = runs.any((r) => !r.status.isTerminal);
    if (status.isTerminal && !anyActive && exp.status == ExperimentStatus.running) {
      await update(exp.id, status: ExperimentStatus.analysing);
    } else if (status == RunStatus.running &&
        (exp.status == ExperimentStatus.idea || exp.status == ExperimentStatus.planned)) {
      await update(exp.id, status: ExperimentStatus.running);
    }
  });

  /// Marks a run's results as reviewed (or not).
  Future<void> setReviewed(int id, bool reviewed) => db.transaction(() async {
    final now = _now;
    await (db.update(db.experimentRuns)..where((r) => r.id.equals(id))).write(
      ExperimentRunsCompanion(reviewedAt: Value(reviewed ? now : null), updatedAt: Value(now)),
    );
    await _touchRunExperiment(id, now);
  });

  /// Deletes a run. Linked tasks stay linked to its experiment.
  Future<void> deleteRun(int id) => (db.delete(db.experimentRuns)..where((r) => r.id.equals(id))).go();

  // ---------------------------------------------------------------------------
  // Task links
  // ---------------------------------------------------------------------------

  /// Links a task to an experiment (and optionally one of its runs); both
  /// null unlinks it. A run implies its own experiment.
  Future<void> linkTask(int taskId, {int? experimentId, int? runId}) => db.transaction(() async {
    var exp = experimentId;
    if (runId != null) exp = (await getRun(runId))?.experimentId ?? exp;
    await (db.update(db.tasks)..where((t) => t.id.equals(taskId))).write(
      TasksCompanion(experimentId: Value(exp), runId: Value(exp == null ? null : runId), updatedAt: Value(_now)),
    );
  });

  Future<void> unlinkTask(int taskId) => linkTask(taskId);

  // ---------------------------------------------------------------------------

  Future<void> _touch(int experimentId, int now) => (db.update(
    db.experiments,
  )..where((e) => e.id.equals(experimentId))).write(ExperimentsCompanion(updatedAt: Value(now)));

  Future<void> _touchRunExperiment(int runId, int now) async {
    final run = await getRun(runId);
    if (run != null) await _touch(run.experimentId, now);
  }

  static String? _blankToNull(String? s) {
    final t = s?.trim();
    return t == null || t.isEmpty ? null : t;
  }
}

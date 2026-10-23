import 'dart:convert';

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

  /// Runs of an experiment, most recently started first.
  Stream<List<ExperimentRun>> watchRuns(int experimentId) =>
      (db.select(db.experimentRuns)
            ..where((r) => r.experimentId.equals(experimentId))
            ..orderBy([
              (r) => OrderingTerm(expression: r.startedAt, mode: OrderingMode.desc, nulls: NullsOrder.first),
              (r) => OrderingTerm.desc(r.id),
            ]))
          .watch()
          .map((rows) => rows.map((r) => r.toDomain()).toList());

  /// Plain read (not `watchRuns(…).first`, which would wait for the
  /// transaction it is called from).
  Future<List<ExperimentRun>> getRuns(int experimentId) async => (await (db.select(
    db.experimentRuns,
  )..where((r) => r.experimentId.equals(experimentId))).get()).map((r) => r.toDomain()).toList();

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
        'SELECT r.*, e.name AS e_name, e.mlflow_experiment_id AS e_mlflow FROM experiment_runs r JOIN experiments e ON e.id = r.experiment_id '
        'WHERE r.status IN $_terminalRuns AND r.reviewed_at IS NULL ORDER BY r.ended_at, r.id',
        readsFrom: {db.experimentRuns, db.experiments},
      )
      .watch()
      .map(
        (rows) => [
          for (final r in rows)
            RunWithExperiment(
              db.experimentRuns.map(r.data).toDomain(),
              r.read<String>('e_name'),
              mlflowExperimentId: r.readNullable<String>('e_mlflow'),
            ),
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
    String? mlflowExperimentId,
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
            mlflowExperimentId: Value(_blankToNull(mlflowExperimentId)),
            createdAt: now,
            updatedAt: now,
          ),
        );
  }

  /// Updates the given fields; [projectId] and [mlflowExperimentId] are only
  /// changed when [setProject] / [setMlflow] are true (so they can be
  /// cleared). Linking another MLflow experiment drops the runs synchronised
  /// from the previous one.
  Future<void> update(
    int id, {
    String? name,
    ExperimentStatus? status,
    String? description,
    String? conclusion,
    bool setProject = false,
    int? projectId,
    bool setMlflow = false,
    String? mlflowExperimentId,
  }) => db.transaction(() async {
    final mlflowId = _blankToNull(mlflowExperimentId);
    final old = setMlflow ? await getExperiment(id) : null;
    final relinked = old != null && old.mlflowExperimentId != mlflowId;
    if (relinked) await (db.delete(db.experimentRuns)..where((r) => r.experimentId.equals(id))).go();
    await (db.update(db.experiments)..where((e) => e.id.equals(id))).write(
      ExperimentsCompanion(
        name: name == null ? const Value.absent() : Value(name.trim()),
        status: status == null ? const Value.absent() : Value(status.code),
        description: description == null ? const Value.absent() : Value(description),
        conclusion: conclusion == null ? const Value.absent() : Value(conclusion),
        projectId: setProject ? Value(projectId) : const Value.absent(),
        mlflowExperimentId: relinked ? Value(mlflowId) : const Value.absent(),
        syncedAt: relinked ? const Value(null) : const Value.absent(),
        updatedAt: Value(_now),
      ),
    );
  });

  /// Deletes an experiment and its runs. Linked tasks are kept, unlinked.
  Future<void> delete(int id) => (db.delete(db.experiments)..where((e) => e.id.equals(id))).go();

  // ---------------------------------------------------------------------------
  // Runs (synchronised from MLflow)
  // ---------------------------------------------------------------------------

  /// Experiments to synchronise: linked to MLflow and not done/abandoned
  /// (all linked ones when [includeClosed]).
  Future<List<Experiment>> linkedExperiments({bool includeClosed = false}) async =>
      (await (db.select(db.experiments)..where((e) => e.mlflowExperimentId.isNotNull())).get())
          .map((r) => r.toDomain())
          .where((e) => includeClosed || e.status.isActive)
          .toList();

  /// Applies the runs read from MLflow: new runs are added, known ones
  /// updated (name, status, times, metrics, params); local notes and the
  /// reviewed mark are kept, except that a run running again is no longer
  /// "reviewed". Runs no longer on the server are kept.
  ///
  /// The experiment follows its runs: a run starting moves an idea/planned
  /// experiment to "Running"; the last run ending moves a running one to
  /// "To analyse" (also when a newly linked experiment's runs are all over).
  /// Returns the number of runs added or changed.
  Future<int> applyRemoteRuns(int experimentId, List<RemoteRun> remote) => db.transaction(() async {
    final now = _now;
    final local = {for (final r in await getRuns(experimentId)) r.mlflowRunId: r};
    var changed = 0;
    var started = false, ended = false;
    for (final r in remote) {
      final old = local[r.runId];
      final metrics = jsonEncode(r.metrics);
      final params = jsonEncode(r.params);
      final startedAt = r.startedAt?.toUtc().millisecondsSinceEpoch;
      final endedAt = r.endedAt?.toUtc().millisecondsSinceEpoch;
      if (old == null) {
        await db
            .into(db.experimentRuns)
            .insert(
              ExperimentRunsCompanion.insert(
                experimentId: experimentId,
                mlflowRunId: r.runId,
                name: Value(r.name),
                status: Value(r.status.code),
                startedAt: Value(startedAt),
                endedAt: Value(endedAt),
                metrics: Value(metrics),
                params: Value(params),
                createdAt: now,
                updatedAt: now,
              ),
            );
        changed++;
        if (r.status.isTerminal) {
          ended = true;
        } else {
          started = true;
        }
        continue;
      }
      final same =
          old.name == r.name &&
          old.status == r.status &&
          old.startedAt?.millisecondsSinceEpoch == startedAt &&
          old.endedAt?.millisecondsSinceEpoch == endedAt &&
          jsonEncode(old.metrics) == metrics &&
          jsonEncode(old.params) == params;
      if (same) continue;
      await (db.update(db.experimentRuns)..where((x) => x.id.equals(old.id))).write(
        ExperimentRunsCompanion(
          name: Value(r.name),
          status: Value(r.status.code),
          startedAt: Value(startedAt),
          endedAt: Value(endedAt),
          metrics: Value(metrics),
          params: Value(params),
          reviewedAt: r.status.isTerminal ? const Value.absent() : const Value(null),
          updatedAt: Value(now),
        ),
      );
      changed++;
      if (old.status.isTerminal && !r.status.isTerminal) started = true;
      if (!old.status.isTerminal && r.status.isTerminal) ended = true;
    }

    final exp = (await getExperiment(experimentId))!;
    final anyActive = (await getRuns(experimentId)).any((r) => !r.status.isTerminal);
    ExperimentStatus? next;
    if (started && (exp.status == ExperimentStatus.idea || exp.status == ExperimentStatus.planned)) {
      next = ExperimentStatus.running;
    } else if (ended &&
        !anyActive &&
        (exp.status == ExperimentStatus.running ||
            exp.status == ExperimentStatus.idea ||
            exp.status == ExperimentStatus.planned)) {
      next = ExperimentStatus.analysing;
    }
    await (db.update(db.experiments)..where((e) => e.id.equals(experimentId))).write(
      ExperimentsCompanion(
        syncedAt: Value(now),
        status: next == null ? const Value.absent() : Value(next.code),
        updatedAt: changed > 0 || next != null ? Value(now) : const Value.absent(),
      ),
    );
    return changed;
  });

  /// Local notes on a run (kept across synchronisations).
  Future<void> setRunNotes(int id, String notes) =>
      (db.update(db.experimentRuns)..where((r) => r.id.equals(id))).write(ExperimentRunsCompanion(notes: Value(notes)));

  /// Marks a run's results as reviewed (or not).
  Future<void> setReviewed(int id, bool reviewed) => db.transaction(() async {
    final now = _now;
    await (db.update(db.experimentRuns)..where((r) => r.id.equals(id))).write(
      ExperimentRunsCompanion(reviewedAt: Value(reviewed ? now : null), updatedAt: Value(now)),
    );
    final run = await getRun(id);
    if (run != null) await _touch(run.experimentId, now);
  });

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

  static String? _blankToNull(String? s) {
    final t = s?.trim();
    return t == null || t.isEmpty ? null : t;
  }
}

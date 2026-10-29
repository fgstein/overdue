import 'models.dart';

/// Chained tasks ("B starts after A") waiting for their predecessor, indexed
/// so any list can fold them under the task they wait for.
///
/// Built from the open tasks whose predecessor is not finished yet
/// ([TaskListItem.isWaitingInChain]).
class TaskChains {
  TaskChains(Iterable<TaskListItem> waiting) {
    for (final w in waiting) {
      final after = w.task.afterTaskId;
      if (after != null && w.isWaitingInChain) _next.putIfAbsent(after, () => []).add(w);
    }
    for (final list in _next.values) {
      list.sort((a, b) => a.task.id.compareTo(b.task.id));
    }
  }

  static final empty = TaskChains(const []);

  final _next = <int, List<TaskListItem>>{};

  bool get isEmpty => _next.isEmpty;

  /// Every task waiting (directly or further down the chain) for [taskId],
  /// depth first: B, then what waits for B, then C…
  List<ChainLink> followers(int taskId) {
    if (!_next.containsKey(taskId)) return const [];
    final out = <ChainLink>[];
    final seen = <int>{taskId};
    void walk(int id, int depth) {
      for (final n in _next[id] ?? const <TaskListItem>[]) {
        if (!seen.add(n.task.id)) continue; // Defensive: cycles are refused when chaining.
        out.add(ChainLink(n, depth));
        walk(n.task.id, depth + 1);
      }
    }

    walk(taskId, 1);
    return out;
  }

  /// Folds a list: entries that are chained under another entry of the same
  /// list disappear from it and come back as that entry's followers.
  /// Waiting tasks whose predecessor is not in the list stay where they are.
  List<(T, List<ChainLink>)> fold<T>(List<T> entries, int Function(T) taskIdOf) {
    if (_next.isEmpty) return [for (final e in entries) (e, const <ChainLink>[])];
    final ids = {for (final e in entries) taskIdOf(e)};
    final hosted = <int>{};
    final byEntry = <int, List<ChainLink>>{};
    for (final id in ids) {
      final f = followers(id);
      if (f.isEmpty) continue;
      byEntry[id] = f;
      hosted.addAll(f.map((l) => l.item.task.id));
    }
    return [
      for (final e in entries)
        if (!hosted.contains(taskIdOf(e))) (e, byEntry[taskIdOf(e)] ?? const <ChainLink>[]),
    ];
  }
}

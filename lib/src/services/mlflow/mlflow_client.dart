import 'dart:async';
import 'dart:convert';
import 'dart:io';

import '../../domain/experiments.dart';

class MlflowException implements Exception {
  const MlflowException(this.message);
  final String message;
  @override
  String toString() => message;
}

/// Read-only client for an MLflow tracking server's REST API.
///
/// This is the only code in Overdue that uses the network
/// (`test/privacy_test.dart` enforces it). It only ever contacts the server
/// configured by the user, and only reads (experiments and runs).
///
/// Credentials: a token (sent as `Authorization: Bearer`, e.g. Databricks),
/// or `http://user:password@host` for MLflow's basic authentication.
class MlflowClient {
  MlflowClient(String server, {this.token, this.timeout = const Duration(seconds: 20)}) : _base = Uri.parse(server);

  final Uri _base;
  final String? token;
  final Duration timeout;

  static const _pageSize = 1000;

  /// Upper bound on the runs read per experiment.
  static const maxRuns = 5000;

  /// Active experiments, by name.
  Future<List<RemoteExperiment>> experiments() async {
    final out = <RemoteExperiment>[];
    String? page;
    do {
      final json = await _post('experiments/search', {
        'max_results': _pageSize,
        'view_type': 'ACTIVE_ONLY',
        'page_token': ?page,
      });
      for (final e in (json['experiments'] as List?) ?? const []) {
        final m = e as Map<String, dynamic>;
        out.add(RemoteExperiment(id: '${m['experiment_id']}', name: '${m['name'] ?? ''}'));
      }
      page = json['next_page_token'] as String?;
    } while (page != null && page.isNotEmpty);
    out.sort((a, b) => a.name.toLowerCase().compareTo(b.name.toLowerCase()));
    return out;
  }

  /// Active runs of an experiment, most recent first.
  Future<List<RemoteRun>> runs(String experimentId) async {
    final out = <RemoteRun>[];
    String? page;
    do {
      final json = await _post('runs/search', {
        'experiment_ids': [experimentId],
        'max_results': _pageSize,
        'run_view_type': 'ACTIVE_ONLY',
        'order_by': ['attributes.start_time DESC'],
        'page_token': ?page,
      });
      for (final r in (json['runs'] as List?) ?? const []) {
        out.add(parseRun(r as Map<String, dynamic>));
      }
      page = json['next_page_token'] as String?;
    } while (page != null && page.isNotEmpty && out.length < maxRuns);
    return out;
  }

  /// A run object of the REST API (`{info: {...}, data: {metrics, params, tags}}`).
  static RemoteRun parseRun(Map<String, dynamic> json) {
    final info = (json['info'] as Map?)?.cast<String, dynamic>() ?? const {};
    final data = (json['data'] as Map?)?.cast<String, dynamic>() ?? const {};
    Map<String, Object?> pairs(String key) => {
      for (final p in (data[key] as List?) ?? const []) '${(p as Map)['key']}': p['value'],
    };
    DateTime? time(Object? ms) {
      final v = ms is num ? ms.toInt() : int.tryParse('${ms ?? ''}');
      return v == null || v <= 0 ? null : DateTime.fromMillisecondsSinceEpoch(v, isUtc: true);
    }

    final tags = pairs('tags');
    return RemoteRun(
      runId: '${info['run_id'] ?? info['run_uuid']}',
      name: '${info['run_name'] ?? tags['mlflow.runName'] ?? ''}',
      status: RunStatus.fromMlflow(info['status'] as String?),
      startedAt: time(info['start_time']),
      endedAt: time(info['end_time']),
      metrics: {
        for (final e in pairs('metrics').entries)
          if (e.value is num && (e.value! as num).isFinite) e.key: (e.value! as num).toDouble(),
      },
      params: {for (final e in pairs('params').entries) e.key: '${e.value ?? ''}'},
    );
  }

  Future<Map<String, dynamic>> _post(String endpoint, Map<String, Object?> body) async {
    final path = _base.path.endsWith('/') ? _base.path : '${_base.path}/';
    final uri = _base.replace(path: '${path}api/2.0/mlflow/$endpoint', userInfo: '');
    final client = HttpClient()..connectionTimeout = timeout;
    try {
      final req = await client.postUrl(uri).timeout(timeout);
      req.headers.contentType = ContentType.json;
      if (token != null && token!.isNotEmpty) {
        req.headers.set(HttpHeaders.authorizationHeader, 'Bearer $token');
      } else if (_base.userInfo.isNotEmpty) {
        final basic = base64Encode(utf8.encode(Uri.decodeComponent(_base.userInfo)));
        req.headers.set(HttpHeaders.authorizationHeader, 'Basic $basic');
      }
      // An explicit length: recent MLflow servers read a chunked body as empty.
      final bytes = utf8.encode(jsonEncode(body));
      req.contentLength = bytes.length;
      req.add(bytes);
      final res = await req.close().timeout(timeout);
      final text = await res.transform(utf8.decoder).join().timeout(timeout);
      if (res.statusCode == 401 || res.statusCode == 403) {
        throw const MlflowException('The MLflow server refused the credentials (check the token or user:password)');
      }
      if (res.statusCode == 404) {
        throw MlflowException('No MLflow API at ${_base.replace(userInfo: '')} (404)');
      }
      if (res.statusCode != 200) {
        throw MlflowException('MLflow server error ${res.statusCode}: ${_shorten(text)}');
      }
      return decode(text);
    } on MlflowException {
      rethrow;
    } on TimeoutException {
      throw MlflowException('The MLflow server did not answer within ${timeout.inSeconds} s');
    } on SocketException catch (e) {
      throw MlflowException('Cannot reach the MLflow server: ${e.osError?.message ?? e.message}');
    } on HandshakeException catch (e) {
      throw MlflowException('TLS error with the MLflow server: ${e.message}');
    } on HttpException catch (e) {
      throw MlflowException('MLflow request failed: ${e.message}');
    } finally {
      client.close(force: true);
    }
  }

  /// Decodes a response. MLflow (Python's json) writes NaN / Infinity
  /// metric values as bare tokens, which are not valid JSON.
  static Map<String, dynamic> decode(String text) {
    try {
      final cleaned = text.replaceAllMapped(RegExp(r'([:\[,]\s*)(-?Infinity|NaN)(?=\s*[,}\]])'), (m) => '${m[1]}null');
      final json = jsonDecode(cleaned);
      if (json is Map<String, dynamic>) return json;
    } on FormatException {
      // Fall through.
    }
    throw MlflowException('Unexpected answer from the MLflow server: ${_shorten(text)}');
  }

  static String _shorten(String s) => s.length > 200 ? '${s.substring(0, 200)}…' : s;
}

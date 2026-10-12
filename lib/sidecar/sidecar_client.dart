/// Client for the Python sidecar process (NDJSON over stdin/stdout).
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

class SidecarException implements Exception {
  final String message;
  final String hint;
  const SidecarException(this.message, this.hint);

  @override
  String toString() => message;
}

class SidecarProgress {
  final int id;
  final String stage;
  final int done;
  final int total;
  final double percent;
  const SidecarProgress(
    this.id,
    this.stage,
    this.done,
    this.total,
    this.percent,
  );
}

class SidecarInfo {
  final String pythonVersion;
  final List<String> providers;
  final String pythonExe;

  /// Persisted provider probe state from the sidecar
  /// ({"last_good": ..., "failed": [...]}).
  final Map<String, dynamic> providerState;

  const SidecarInfo(
    this.pythonVersion,
    this.providers,
    this.pythonExe,
    this.providerState,
  );
}

class SidecarClient {
  Process? _process;
  bool _ready = false;
  Future<SidecarInfo>? _starting;
  int _nextId = 1;
  final Map<int, Completer<Map<String, dynamic>>> _pending = {};
  final StreamController<SidecarProgress> _progress =
      StreamController<SidecarProgress>.broadcast();
  final StreamController<Map<String, dynamic>> _events =
      StreamController<Map<String, dynamic>>.broadcast();

  /// Recent stderr lines from the sidecar (diagnostics console).
  final List<String> logLines = [];

  SidecarInfo? info;

  Stream<SidecarProgress> get progressStream => _progress.stream;
  Stream<Map<String, dynamic>> get eventsStream => _events.stream;

  /// True only after the `hello` handshake succeeded.
  bool get running => _ready && _process != null;

  // -------------------------------------------------------------------------
  // Lifecycle
  // -------------------------------------------------------------------------

  Future<SidecarInfo> start() async {
    if (_ready && _process != null) return info!;
    final inFlight = _starting;
    if (inFlight != null) return inFlight;
    final fut = _startInner();
    _starting = fut;
    try {
      return await fut;
    } finally {
      _starting = null;
    }
  }

  Future<SidecarInfo> _startInner() async {
    // Kill any stale process left over from a failed handshake.
    final old = _process;
    if (old != null) {
      try {
        old.kill();
      } catch (_) {}
      _process = null;
    }
    _ready = false;
    final python = await locatePython();
    final script = await locateScript();
    final env = Map<String, String>.from(Platform.environment);
    env['PYTHONUNBUFFERED'] = '1';

    final proc = await Process.start(python, [script], environment: env);
    _process = proc;
    proc.stdout
        .transform(utf8.decoder)
        .transform(const LineSplitter())
        .listen(_onLine, onError: (_) {});
    proc.stderr.transform(utf8.decoder).transform(const LineSplitter()).listen((
      line,
    ) {
      logLines.add(line);
      if (logLines.length > 300) logLines.removeAt(0);
    }, onError: (_) {});
    unawaited(
      proc.exitCode.then((code) {
        _onExit(code);
      }),
    );

    Map<String, dynamic> res;
    try {
      res = await request('hello', {}, timeout: const Duration(seconds: 45));
    } catch (e) {
      // Handshake failed: make sure a retry starts from a clean state.
      try {
        proc.kill();
      } catch (_) {}
      _process = null;
      _ready = false;
      rethrow;
    }
    info = SidecarInfo(
      res['python'] as String? ?? 'unknown',
      (res['providers'] as List? ?? const []).cast<String>(),
      python,
      (res['provider_state'] as Map?)?.cast<String, dynamic>() ?? const {},
    );
    _ready = true;
    return info!;
  }

  Future<void> shutdown() async {
    final proc = _process;
    if (proc == null) return;
    try {
      proc.stdin.writeln(jsonEncode({'id': 0, 'type': 'stop'}));
      await proc.stdin.close();
    } catch (_) {}
    proc.kill();
    await Future.any([
      proc.exitCode.timeout(const Duration(seconds: 2), onTimeout: () => -1),
    ]);
    _process = null;
  }

  /// Hard-stop: send `stop`, then kill the process after [grace].
  Future<void> cancel({Duration grace = const Duration(seconds: 8)}) async {
    final proc = _process;
    if (proc == null) return;
    try {
      proc.stdin.writeln(jsonEncode({'id': 0, 'type': 'stop'}));
    } catch (_) {}
    await Future<void>.delayed(grace);
    if (_pending.isNotEmpty) {
      proc.kill();
    }
  }

  void _onExit(int code) {
    _process = null;
    _ready = false;
    final err = SidecarException(
      'Python sidecar exited unexpectedly (code $code).',
      'Check the diagnostics log. Restart the app and retry.',
    );
    for (final c in _pending.values) {
      if (!c.isCompleted) c.completeError(err);
    }
    _pending.clear();
  }

  void _onLine(String line) {
    Map<String, dynamic>? obj;
    try {
      obj = jsonDecode(line) as Map<String, dynamic>;
    } catch (_) {
      return;
    }
    final id = (obj['id'] as num?)?.toInt();
    final ok = obj['ok'];
    if (id != null && ok != null) {
      final c = _pending.remove(id);
      if (c == null || c.isCompleted) return;
      if (ok == true) {
        c.complete(obj['result'] as Map<String, dynamic>? ?? {});
      } else {
        final err = obj['error'] as Map<String, dynamic>? ?? const {};
        c.completeError(
          SidecarException(
            err['message'] as String? ?? 'Sidecar error',
            err['hint'] as String? ?? '',
          ),
        );
      }
      return;
    }
    final event = obj['event'];
    if (event == 'progress') {
      final d = obj['data'] as Map<String, dynamic>? ?? const {};
      _progress.add(
        SidecarProgress(
          id ?? 0,
          d['stage'] as String? ?? '',
          (d['done'] as num?)?.toInt() ?? 0,
          (d['total'] as num?)?.toInt() ?? 0,
          (d['percent'] as num?)?.toDouble() ?? 0,
        ),
      );
    } else if (event != null) {
      _events.add({'id': id, 'event': event, 'data': obj['data']});
    }
  }

  // -------------------------------------------------------------------------
  // Requests
  // -------------------------------------------------------------------------

  Future<Map<String, dynamic>> request(
    String type,
    Map<String, dynamic> payload, {
    Duration timeout = const Duration(minutes: 10),
  }) {
    final proc = _process;
    if (proc == null) {
      return Future.error(
        SidecarException(
          'Python sidecar is not running.',
          'Restart the app to relaunch it.',
        ),
      );
    }
    final id = _nextId++;
    final c = Completer<Map<String, dynamic>>();
    _pending[id] = c;
    _send({'id': id, 'type': type, ...payload});
    final fut = c.future.timeout(timeout);
    fut.whenComplete(() {
      _pending.remove(id);
    });
    return fut;
  }

  /// Run separation with progress/meta callbacks and cooperative cancel.
  Future<Map<String, dynamic>> runSeparate(
    Map<String, dynamic> payload, {
    void Function(SidecarProgress)? onProgress,
    void Function(Map<String, dynamic>)? onMeta,
    Future<bool> Function()? shouldCancel,
  }) {
    final proc = _process;
    if (proc == null) {
      return Future.error(
        SidecarException(
          'Python sidecar is not running.',
          'Restart the app to relaunch it.',
        ),
      );
    }
    final id = _nextId++;
    final subProgress = _progress.stream
        .where((p) => p.id == id)
        .listen(onProgress ?? (_) {});
    final subEvents = _events.stream
        .where((e) => e['id'] == id)
        .listen(onMeta ?? (_) {});

    Timer? cancelTimer;
    if (shouldCancel != null) {
      cancelTimer = Timer.periodic(const Duration(milliseconds: 400), (
        t,
      ) async {
        final cancelled = await shouldCancel();
        if (cancelled) {
          try {
            proc.stdin.writeln(jsonEncode({'id': 0, 'type': 'stop'}));
          } catch (_) {}
          t.cancel();
        }
      });
    }

    final c = Completer<Map<String, dynamic>>();
    _pending[id] = c;
    _send({'id': id, 'type': 'separate', ...payload});

    return c.future.timeout(const Duration(hours: 12)).whenComplete(() {
      subProgress.cancel();
      subEvents.cancel();
      cancelTimer?.cancel();
    });
  }

  void _send(Map<String, dynamic> obj) {
    try {
      _process?.stdin.writeln(jsonEncode(obj));
    } catch (_) {}
  }

  // -------------------------------------------------------------------------
  // Environment discovery
  // -------------------------------------------------------------------------

  Future<String> locatePython() async {
    const probeTimeout = Duration(seconds: 4);
    final candidates = ['python', 'python3'];
    for (final exe in candidates) {
      final version = await _pythonVersion(exe, probeTimeout);
      if (version != null) return exe;
    }
    try {
      final r = await Process.run('py', [
        '-3',
        '--version',
      ]).timeout(probeTimeout);
      final text = '${r.stdout}${r.stderr}';
      final m = RegExp(r'Python (\d+)\.(\d+)').firstMatch(text);
      if (r.exitCode == 0 && m != null) {
        final minor = int.parse(m.group(2)!);
        if (minor >= 10 && minor <= 12) return 'py';
      }
    } catch (_) {}
    // Fallback: common per-user install locations (e.g. winget --scope user).
    final localAppData = Platform.environment['LOCALAPPDATA'];
    if (localAppData != null && localAppData.isNotEmpty) {
      for (final ver in ['Python311', 'Python312', 'Python310']) {
        final exe = '$localAppData\\Programs\\Python\\$ver\\python.exe';
        if (!File(exe).existsSync()) continue;
        final v = await _pythonVersion(exe, probeTimeout);
        if (v != null) return exe;
      }
    }
    throw SidecarException(
      'Python 3.10-3.12 was not found on this machine.',
      'Install Python 3.11, then run: pip install -r sidecar/requirements.txt',
    );
  }

  Future<String?> _pythonVersion(String exe, Duration timeout) async {
    try {
      final r = await Process.run(exe, ['--version']).timeout(timeout);
      final text = '${r.stdout}${r.stderr}';
      final m = RegExp(r'Python (\d+)\.(\d+)').firstMatch(text);
      if (r.exitCode == 0 && m != null) {
        final minor = int.parse(m.group(2)!);
        if (minor >= 10 && minor <= 12) return text.trim();
      }
    } catch (_) {}
    return null;
  }

  Future<String> locateScript() async {
    final exeDir = File(Platform.resolvedExecutable).parent.path;
    // Env override first (advanced users / custom installs).
    final override = Platform.environment['BAKUSHI_SIDECAR'];
    if (override != null && override.isNotEmpty) {
      final f = File(override);
      if (f.existsSync()) return f.absolute.path;
    }
    final candidates = <String>[
      'sidecar/bakushi_sidecar.py',
      '$exeDir/sidecar/bakushi_sidecar.py',
      '$exeDir/bakushi_sidecar.py',
    ];
    // Walk UP from the executable (e.g. build\windows\x64\runner\Release)
    // so a release exe launched from any working directory still finds the
    // project's sidecar/ folder.
    var dir = exeDir;
    for (var i = 0; i < 6; i++) {
      candidates.add('$dir/sidecar/bakushi_sidecar.py');
      final parent = File(dir).parent.path;
      if (parent == dir) break;
      dir = parent;
    }
    for (final c in candidates) {
      final f = File(c);
      if (f.existsSync()) return f.absolute.path;
    }
    throw SidecarException(
      'Python sidecar script not found (sidecar/bakushi_sidecar.py).',
      'Reinstall the app or restore the sidecar folder.',
    );
  }
}

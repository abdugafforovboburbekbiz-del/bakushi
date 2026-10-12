/// Collapsible diagnostics panel: engine status + retry, app log,
/// sidecar stderr and a Copy log action. Shown at the bottom of the
/// home column so users can actually see what failed.
library;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../state/app_state.dart';
import '../../theme/app_theme.dart';

class DiagnosticsPanel extends StatelessWidget {
  final AppState state;
  const DiagnosticsPanel({super.key, required this.state});

  static String _fmtTime(DateTime t) {
    String two(int v) => v.toString().padLeft(2, '0');
    return '${two(t.hour)}:${two(t.minute)}:${two(t.second)}';
  }

  String _appLogText(AppState s) {
    final buf = StringBuffer();
    for (final l in s.logs.take(200)) {
      buf.writeln(
        '${_fmtTime(l.time)} '
        '${l.isError ? '[error] ' : ''}${l.message}',
      );
    }
    return buf.toString();
  }

  Future<void> _copyAll(AppState s) async {
    final buf = StringBuffer('=== Bakushi app log (newest first) ===\n');
    buf.writeln(_appLogText(s));
    buf.writeln('\n=== Sidecar (Python) stderr ===');
    // Most recent line last, like a terminal.
    for (final line in s.sidecarLogLines.reversed) {
      buf.writeln(line);
    }
    await Clipboard.setData(ClipboardData(text: buf.toString()));
    s.showToast('App + sidecar logs copied to the clipboard.');
  }

  @override
  Widget build(BuildContext context) {
    final s = state;
    return ListenableBuilder(
      listenable: s,
      builder: (context, _) {
        final appLines = s.logs.take(200).toList();
        final sidecarLines = s.sidecarLogLines;
        return Container(
          decoration: BoxDecoration(
            color: Colors.white.withValues(alpha: 0.02),
            borderRadius: BorderRadius.circular(12),
            border: Border.all(color: BakushiTokens.border),
          ),
          child: ExpansionTile(
            shape: const Border(),
            collapsedShape: const Border(),
            leading: const Icon(Icons.bug_report, size: 18),
            title: const Text(
              'Diagnostics',
              style: TextStyle(fontSize: 13, fontWeight: FontWeight.w700),
            ),
            subtitle: Text(
              s.engineOk
                  ? 'Engine OK · ${s.logs.length} log lines'
                  : 'Engine problem · ${s.logs.length} log lines',
              style: TextStyle(
                fontSize: 11,
                color: Colors.white.withValues(alpha: 0.5),
              ),
            ),
            childrenPadding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
            children: [
              // (a) Engine status + retry.
              Container(
                padding: const EdgeInsets.symmetric(
                  horizontal: 10,
                  vertical: 6,
                ),
                decoration: BoxDecoration(
                  color: Colors.white.withValues(alpha: 0.03),
                  borderRadius: BorderRadius.circular(8),
                ),
                child: Row(
                  children: [
                    Icon(
                      s.engineOk ? Icons.check_circle : Icons.error_outline,
                      size: 15,
                      color: s.engineOk
                          ? StemColors.bass
                          : BakushiTokens.danger,
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text(
                        s.engineOk
                            ? 'Audio engine: OK'
                            : 'Audio engine: ${s.engineError ?? 'failed'}',
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(fontSize: 12),
                      ),
                    ),
                    TextButton.icon(
                      onPressed: s.busy ? null : s.retryEngineInit,
                      icon: const Icon(Icons.refresh, size: 15),
                      label: const Text('Retry audio engine'),
                      style: TextButton.styleFrom(
                        textStyle: const TextStyle(fontSize: 12),
                        visualDensity: VisualDensity.compact,
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 10),
              // (b) App log (newest ~200, reverse-chronological).
              _logHeader('App log (newest ${appLines.length})'),
              const SizedBox(height: 4),
              _logBox(
                appLines.isEmpty
                    ? 'No app log lines yet.'
                    : appLines
                          .map(
                            (l) =>
                                '${_fmtTime(l.time)} '
                                '${l.isError ? '[error] ' : ''}${l.message}',
                          )
                          .join('\n'),
              ),
              const SizedBox(height: 8),
              // (c) Sidecar stderr (capped 300 by the client).
              _logHeader('Sidecar (Python) log (${sidecarLines.length})'),
              const SizedBox(height: 4),
              _logBox(
                sidecarLines.isEmpty
                    ? 'No sidecar log lines yet.'
                    : sidecarLines.reversed.join('\n'),
              ),
              const SizedBox(height: 10),
              // (d) Copy log.
              Row(
                mainAxisAlignment: MainAxisAlignment.end,
                children: [
                  OutlinedButton.icon(
                    onPressed: () => _copyAll(s),
                    icon: const Icon(Icons.copy, size: 15),
                    label: const Text('Copy log'),
                    style: OutlinedButton.styleFrom(
                      textStyle: const TextStyle(fontSize: 12),
                      visualDensity: VisualDensity.compact,
                    ),
                  ),
                ],
              ),
            ],
          ),
        );
      },
    );
  }

  Widget _logHeader(String text) {
    return Text(
      text,
      style: TextStyle(
        fontSize: 11,
        fontWeight: FontWeight.w700,
        color: Colors.white.withValues(alpha: 0.55),
      ),
    );
  }

  Widget _logBox(String text) {
    return Container(
      width: double.infinity,
      height: 130,
      padding: const EdgeInsets.all(8),
      decoration: BoxDecoration(
        color: Colors.black.withValues(alpha: 0.4),
        borderRadius: BorderRadius.circular(8),
      ),
      child: SingleChildScrollView(
        child: Text(
          text,
          style: const TextStyle(
            fontSize: 11,
            height: 1.4,
            fontFamily: 'Consolas',
          ),
        ),
      ),
    );
  }
}

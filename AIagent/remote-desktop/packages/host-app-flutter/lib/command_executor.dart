import 'dart:convert';
import 'dart:io';

class CommandExecutor {
  static const _timeoutSeconds = 15;

  Future<Map<String, dynamic>> execute(
    String command,
    String commandType,
  ) async {
    try {
      final result = await _runCommand(command, commandType).timeout(
        const Duration(seconds: _timeoutSeconds),
        onTimeout: () => ProcessResult(
          -1,
          -1,
          '',
          'timeout: 명령 실행 시간 초과 (${_timeoutSeconds}s)',
        ),
      );

      final exitCode = result.exitCode;
      final stdout = _decodeOutput(result.stdout);
      final stderr = _decodeOutput(result.stderr);

      return {
        'success': exitCode == 0,
        'output': stdout,
        'error': stderr,
      };
    } catch (e) {
      return {
        'success': false,
        'output': '',
        'error': e.toString(),
      };
    }
  }

  Future<ProcessResult> _runCommand(
    String command,
    String commandType,
  ) async {
    switch (commandType) {
      case 'powershell':
        if (Platform.isWindows) {
          final wrappedCmd = '[Console]::OutputEncoding = [System.Text.Encoding]::UTF8; $command';
          final encoded = _encodeForPowerShell(wrappedCmd);
          return Process.run(
            'powershell',
            ['-NoProfile', '-NonInteractive', '-EncodedCommand', encoded],
            runInShell: true,
            stdoutEncoding: null,
            stderrEncoding: null,
          );
        }
        return Process.run('sh', ['-c', command], runInShell: true, stdoutEncoding: null, stderrEncoding: null);

      case 'shell':
        final parts = command.split(' ');
        return Process.run(
          parts.first,
          parts.skip(1).toList(),
          runInShell: true,
          stdoutEncoding: null,
          stderrEncoding: null,
        );

      case 'cmd':
      default:
        if (Platform.isWindows) {
          return Process.run(
            'cmd',
            ['/c', 'chcp 65001 >nul 2>&1 & $command'],
            runInShell: true,
            stdoutEncoding: null,
            stderrEncoding: null,
          );
        }
        return Process.run('sh', ['-c', command], runInShell: true, stdoutEncoding: null, stderrEncoding: null);
    }
  }

  // PowerShell -EncodedCommand 용 UTF-16LE base64 변환
  String _encodeForPowerShell(String command) {
    final utf16le = <int>[];
    for (final codeUnit in command.codeUnits) {
      utf16le.add(codeUnit & 0xFF);
      utf16le.add((codeUnit >> 8) & 0xFF);
    }
    return base64Encode(utf16le);
  }

  String _decodeOutput(dynamic output) {
    if (output == null) return '';
    if (output is String) return output.trim();
    if (output is List<int>) {
      try {
        return utf8.decode(output, allowMalformed: true).trim();
      } catch (_) {
        return output.toString().trim();
      }
    }
    return output.toString().trim();
  }
}

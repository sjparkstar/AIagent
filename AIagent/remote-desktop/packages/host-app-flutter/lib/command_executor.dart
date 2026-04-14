import 'dart:convert';
import 'dart:io';

class CommandExecutor {
  static const _timeoutSeconds = 15;
  static const _maxCommandLength = 2000;
  static final List<RegExp> _dangerousPatterns = [
    RegExp(r'\brm\s+-rf\b', caseSensitive: false),
    RegExp(r'\bremove-item\b[\s\S]*-recurse', caseSensitive: false),
    RegExp(r'\bdel\b[\s\S]*/[pqsf]', caseSensitive: false),
    RegExp(r'\berase\b', caseSensitive: false),
    RegExp(r'\brd\b[\s\S]*/s\b', caseSensitive: false),
    RegExp(r'\brmdir\b[\s\S]*/s\b', caseSensitive: false),
    RegExp(r'\bformat\b', caseSensitive: false),
    RegExp(r'\bdiskpart\b', caseSensitive: false),
    RegExp(r'\bshutdown\b', caseSensitive: false),
    RegExp(r'\brestart-computer\b', caseSensitive: false),
    RegExp(r'\bstop-computer\b', caseSensitive: false),
    RegExp(r'\breg\b[\s\S]*\bdelete\b', caseSensitive: false),
    RegExp(r'\bsc\b[\s\S]*\bdelete\b', caseSensitive: false),
    RegExp(r'\bvssadmin\b[\s\S]*\bdelete\b', caseSensitive: false),
    RegExp(r'\bwbadmin\b[\s\S]*\bdelete\b', caseSensitive: false),
    RegExp(r'\bcipher\b[\s\S]*/w\b', caseSensitive: false),
    RegExp(r'\bmkfs\b', caseSensitive: false),
    RegExp(r'\bdd\b[\s\S]*if=', caseSensitive: false),
  ];

  Future<Map<String, dynamic>> execute(
    String command,
    String commandType,
  ) async {
    final validationError = _validateCommand(command, commandType);
    if (validationError != null) {
      return {
        'success': false,
        'output': '',
        'error': validationError,
      };
    }

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

  String? _validateCommand(String command, String commandType) {
    final trimmed = command.trim();
    if (trimmed.isEmpty) return 'Command is empty';
    if (trimmed.length > _maxCommandLength) {
      return 'Command exceeds $_maxCommandLength characters';
    }
    if (!const {'cmd', 'powershell', 'shell'}.contains(commandType)) {
      return 'Unsupported commandType: $commandType';
    }
    if (Platform.isWindows && commandType == 'shell' && RegExp(r'[;&><]').hasMatch(trimmed)) {
      return 'Shell commands with chained operators are blocked on Windows';
    }
    for (final pattern in _dangerousPatterns) {
      if (pattern.hasMatch(trimmed)) {
        return 'Blocked potentially destructive command';
      }
    }
    return null;
  }

  Future<ProcessResult> _runCommand(
    String command,
    String commandType,
  ) async {
    switch (commandType) {
      case 'powershell':
        if (Platform.isWindows) {
          final wrappedCmd =
              '[Console]::OutputEncoding = [System.Text.Encoding]::UTF8; $command';
          final encoded = _encodeForPowerShell(wrappedCmd);
          return Process.run(
            'powershell',
            ['-NoProfile', '-NonInteractive', '-EncodedCommand', encoded],
            runInShell: true,
            stdoutEncoding: null,
            stderrEncoding: null,
          );
        }
        return Process.run(
          'sh',
          ['-c', command],
          runInShell: true,
          stdoutEncoding: null,
          stderrEncoding: null,
        );

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
        return Process.run(
          'sh',
          ['-c', command],
          runInShell: true,
          stdoutEncoding: null,
          stderrEncoding: null,
        );
    }
  }

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

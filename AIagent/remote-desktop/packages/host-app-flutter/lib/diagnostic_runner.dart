// 호스트 측 Diagnostic Runner + Playbook Runner
// PLAN.md 섹션 4 (모듈 구조): Diagnostic Runner, Playbook Runner, Verifier
// 승인된 범위 내에서 진단/복구를 수행하고 결과를 구조화하여 반환

import 'dart:async';
import 'dart:io';
import 'package:flutter/foundation.dart';

// 진단 단계 정의
class DiagnosticStep {
  final String name;
  final String command;
  final String commandType; // cmd | powershell | shell
  const DiagnosticStep({
    required this.name,
    required this.command,
    required this.commandType,
  });
}

// 단계 실행 결과
class StepResult {
  final String stepName;
  final String status; // success | failed | skipped
  final String output;
  final int durationMs;
  final String? error;
  const StepResult({
    required this.stepName,
    required this.status,
    required this.output,
    required this.durationMs,
    this.error,
  });

  Map<String, dynamic> toJson() => {
        'stepName': stepName,
        'status': status,
        'output': output.length > 4000 ? '${output.substring(0, 4000)}...' : output,
        'durationMs': durationMs,
        if (error != null) 'error': error,
      };
}

// 원인 후보 구조
class RootCauseCandidate {
  final String cause;
  final double confidence; // 0.0 ~ 1.0
  final String evidence;
  const RootCauseCandidate({
    required this.cause,
    required this.confidence,
    required this.evidence,
  });
  Map<String, dynamic> toJson() => {
        'cause': cause,
        'confidence': confidence,
        'evidence': evidence,
      };
}

// 진단 결과
class DiagnosticResult {
  final bool success;
  final List<RootCauseCandidate> rootCauseCandidates;
  final List<Map<String, String>> recommendedActions; // [{playbookId, title, riskLevel}]
  final List<StepResult> stepResults;
  const DiagnosticResult({
    required this.success,
    required this.rootCauseCandidates,
    required this.recommendedActions,
    required this.stepResults,
  });
}

class DiagnosticRunner {
  // 차단할 위험 명령 패턴 (파괴적/시스템 변경/권한 상승)
  // 뷰어가 전달한 명령이 서버 검증을 통과했더라도, 호스트에서 한 번 더 방어
  static final _denyPatterns = <RegExp>[
    RegExp(r'\brm\s+-rf\s+/', caseSensitive: false),
    RegExp(r'\bformat\s+[a-z]:', caseSensitive: false),
    RegExp(r'\bdel\s+/[sqf]', caseSensitive: false),
    RegExp(r'\brmdir\s+/s', caseSensitive: false),
    RegExp(r'\breg\s+delete\b', caseSensitive: false),
    RegExp(r'\bnet\s+user\s+\S+\s+\S+\s+/add', caseSensitive: false),
    RegExp(r'\bnet\s+localgroup\s+administrators', caseSensitive: false),
    RegExp(r'\bshutdown\b', caseSensitive: false),
    RegExp(r'\bdiskpart\b', caseSensitive: false),
    RegExp(r'\bcipher\s+/w', caseSensitive: false),
    RegExp(r'Remove-Item.*-Recurse.*-Force.*C:\\', caseSensitive: false),
    RegExp(r'Invoke-Expression', caseSensitive: false), // iex
    RegExp(r'\biex\b', caseSensitive: false),
    RegExp(r'DownloadString|WebClient', caseSensitive: false),
    // 체이닝: 단일 명령만 허용 (세미콜론/파이프/앰퍼샌드 금지)
    // 다만 파이프는 findstr 등에 정당하게 쓰이므로 허용하고, ;와 &&만 차단
    RegExp(r';\s*\w'), // 세미콜론 체이닝
    RegExp(r'&&'),     // AND 체이닝
    RegExp(r'\|\|'),   // OR 체이닝
  ];

  // 명령이 denylist에 걸리면 실행 거부
  bool _isDenied(String command) {
    for (final pattern in _denyPatterns) {
      if (pattern.hasMatch(command)) return true;
    }
    return false;
  }

  // 단일 명령 실행 헬퍼 (타임아웃 10초)
  Future<StepResult> _runCommand(
    String name,
    String command,
    String commandType, {
    Duration timeout = const Duration(seconds: 10),
  }) async {
    // 위험 명령 차단 (서버 검증 + 호스트 이중 방어)
    if (_isDenied(command)) {
      debugPrint('[diagnostic] 차단됨: $command');
      return StepResult(
        stepName: name,
        status: 'failed',
        output: '',
        durationMs: 0,
        error: '차단된 명령 패턴 감지 — 허용되지 않은 시스템 변경 명령',
      );
    }

    final start = DateTime.now();
    try {
      final ProcessResult r;
      if (Platform.isWindows && commandType == 'powershell') {
        r = await Process.run(
          'powershell',
          ['-NoProfile', '-Command', command],
          runInShell: false,
        ).timeout(timeout);
      } else if (Platform.isWindows) {
        r = await Process.run('cmd', ['/c', command], runInShell: false).timeout(timeout);
      } else {
        r = await Process.run('/bin/sh', ['-c', command]).timeout(timeout);
      }
      final duration = DateTime.now().difference(start).inMilliseconds;
      final output = '${r.stdout}${r.stderr}'.trim();
      return StepResult(
        stepName: name,
        status: r.exitCode == 0 ? 'success' : 'failed',
        output: output,
        durationMs: duration,
        error: r.exitCode != 0 ? 'exitCode=${r.exitCode}' : null,
      );
    } catch (e) {
      return StepResult(
        stepName: name,
        status: 'failed',
        output: '',
        durationMs: DateTime.now().difference(start).inMilliseconds,
        error: e.toString(),
      );
    }
  }

  /// 진단 스텝 순차 실행 + 원인 후보 추론
  Future<DiagnosticResult> runDiagnostic({
    required List<DiagnosticStep> steps,
    void Function(String stepName, int progress)? onProgress,
  }) async {
    final results = <StepResult>[];
    for (int i = 0; i < steps.length; i++) {
      final step = steps[i];
      onProgress?.call(step.name, ((i / steps.length) * 100).round());
      final r = await _runCommand(step.name, step.command, step.commandType);
      results.add(r);
      debugPrint('[diagnostic] ${r.stepName}: ${r.status}');
    }
    onProgress?.call('완료', 100);

    // 간단한 원인 추론: 실패 스텝 기반
    final failures = results.where((r) => r.status == 'failed').toList();
    final candidates = <RootCauseCandidate>[];
    if (failures.isNotEmpty) {
      for (final f in failures) {
        candidates.add(RootCauseCandidate(
          cause: '${f.stepName} 실패',
          confidence: 0.7,
          evidence: f.error ?? f.output,
        ));
      }
    } else {
      candidates.add(const RootCauseCandidate(
        cause: '특이사항 없음 — 모든 진단 스텝 정상',
        confidence: 0.9,
        evidence: '모든 체크 통과',
      ));
    }

    return DiagnosticResult(
      success: true,
      rootCauseCandidates: candidates,
      recommendedActions: [], // Phase D에서 카테고리별 매핑
      stepResults: results,
    );
  }

  // ─── Playbook Runner (pre-check → actions → post-check → rollback) ─────
  Future<Map<String, dynamic>> runPlaybook({
    required String title,
    List<Map<String, dynamic>>? preconditions,
    required List<Map<String, dynamic>> actions,
    List<Map<String, dynamic>>? successCriteria,
    List<Map<String, dynamic>>? rollbackSteps,
    void Function(String stepName, int progress)? onProgress,
  }) async {
    final stepResults = <StepResult>[];
    bool rolledBack = false;

    // 1. Preconditions (모두 통과해야 진행)
    if (preconditions != null && preconditions.isNotEmpty) {
      for (int i = 0; i < preconditions.length; i++) {
        final p = preconditions[i];
        onProgress?.call('사전조건: ${p['name']}', ((i / preconditions.length) * 30).round());
        final r = await _runCommand(
          'precheck:${p['name']}',
          p['command']?.toString() ?? '',
          p['commandType']?.toString() ?? 'cmd',
        );
        final expected = p['expected']?.toString() ?? '';
        final pass = expected.isEmpty ? r.status == 'success' : r.output.contains(expected);
        stepResults.add(StepResult(
          stepName: 'precheck:${p['name']}',
          status: pass ? 'success' : 'failed',
          output: r.output,
          durationMs: r.durationMs,
          error: pass ? null : '사전조건 미충족',
        ));
        if (!pass) {
          return {
            'success': false,
            'stepResults': stepResults.map((r) => r.toJson()).toList(),
            'rolledBack': false,
            'abortReason': '사전조건 실패: ${p['name']}',
          };
        }
      }
    }

    // 2. Actions (실패 시 rollback)
    for (int i = 0; i < actions.length; i++) {
      final a = actions[i];
      onProgress?.call('실행: ${a['name']}', 30 + ((i / actions.length) * 50).round());
      final r = await _runCommand(
        a['name']?.toString() ?? 'action_$i',
        a['command']?.toString() ?? '',
        a['commandType']?.toString() ?? 'cmd',
      );
      stepResults.add(r);
      if (r.status == 'failed') {
        // Rollback 시도
        if (rollbackSteps != null && rollbackSteps.isNotEmpty) {
          debugPrint('[playbook] 액션 실패 → rollback 실행');
          for (final rb in rollbackSteps) {
            final rbResult = await _runCommand(
              'rollback:${rb['name']}',
              rb['command']?.toString() ?? '',
              rb['commandType']?.toString() ?? 'cmd',
            );
            stepResults.add(rbResult);
          }
          rolledBack = true;
        }
        return {
          'success': false,
          'stepResults': stepResults.map((r) => r.toJson()).toList(),
          'rolledBack': rolledBack,
        };
      }
    }

    // 3. Success criteria (post-check)
    final criteriaResults = <Map<String, dynamic>>[];
    bool allPassed = true;
    if (successCriteria != null && successCriteria.isNotEmpty) {
      for (int i = 0; i < successCriteria.length; i++) {
        final c = successCriteria[i];
        onProgress?.call('검증: ${c['name']}', 80 + ((i / successCriteria.length) * 20).round());
        final r = await _runCommand(
          'verify:${c['name']}',
          c['command']?.toString() ?? '',
          c['commandType']?.toString() ?? 'cmd',
        );
        final expected = c['expected']?.toString() ?? '';
        final passed = expected.isEmpty ? r.status == 'success' : r.output.contains(expected);
        criteriaResults.add({
          'name': c['name'],
          'passed': passed,
          'actual': r.output.length > 200 ? '${r.output.substring(0, 200)}...' : r.output,
        });
        if (!passed) allPassed = false;
      }
    }

    onProgress?.call('완료', 100);
    return {
      'success': allPassed,
      'stepResults': stepResults.map((r) => r.toJson()).toList(),
      'verification': {'success': allPassed, 'criteria': criteriaResults},
      'rolledBack': false,
    };
  }
}

// 호스트 Detector 모듈
// 시스템 상태를 주기적으로 체크하여 이상 징후 감지 → issue.detected 이벤트 발행
// PLAN.md 4.2 Detector 설계 기반

import 'package:flutter/foundation.dart';

// 감지된 이슈 객체
class DetectedIssue {
  final String fingerprint; // 중복 방지용 식별자 (category + rule_key)
  final String category;
  final String severity; // critical | warning | info
  final String summary;
  final String? detail;
  final Map<String, dynamic>? metadata;

  const DetectedIssue({
    required this.fingerprint,
    required this.category,
    required this.severity,
    required this.summary,
    this.detail,
    this.metadata,
  });
}

class IssueDetector {
  // fingerprint → 마지막 알림 시각 (쿨다운)
  final Map<String, DateTime> _lastNotified = {};
  // CPU/메모리 과부하 연속 카운트 (3분 지속 감지용 — 5초 간격 36회)
  final List<double> _cpuHistory = [];
  static const _cpuHistoryMax = 36;
  // 동일 이슈 재알림 쿨다운
  static const _cooldown = Duration(minutes: 5);

  /// diagnostics(SystemDiagnostics 원본 Map)를 분석하여 이슈 감지
  /// 반환: 새로 감지된 이슈 리스트 (쿨다운 내 중복은 제외)
  List<DetectedIssue> analyze(Map<String, dynamic> diag) {
    final issues = <DetectedIssue>[];
    final sys = diag['system'] as Map<String, dynamic>?;
    if (sys == null) return issues;

    // 1. CPU 과부하
    final cpuUsage = (sys['cpuUsage'] as num?)?.toDouble() ?? 0;
    _cpuHistory.add(cpuUsage);
    if (_cpuHistory.length > _cpuHistoryMax) {
      _cpuHistory.removeRange(0, _cpuHistory.length - _cpuHistoryMax);
    }
    if (cpuUsage >= 95) {
      final sustained =
          _cpuHistory.length >= _cpuHistoryMax && _cpuHistory.every((v) => v >= 90);
      issues.add(DetectedIssue(
        fingerprint: sustained ? 'cpu.sustained' : 'cpu.spike',
        category: 'system',
        severity: sustained ? 'critical' : 'warning',
        summary: sustained ? 'CPU 3분 이상 과부하 지속' : 'CPU 과부하',
        detail: 'CPU ${cpuUsage.toInt()}% 사용 중',
        metadata: {'cpuUsage': cpuUsage, 'sustained': sustained},
      ));
    }

    // 2. 메모리 부족
    final memUsage = (sys['memUsage'] as num?)?.toInt() ?? 0;
    final memUsed = (sys['memUsed'] as num?)?.toInt() ?? 0;
    final memTotal = (sys['memTotal'] as num?)?.toInt() ?? 0;
    if (memUsage >= 95) {
      issues.add(DetectedIssue(
        fingerprint: 'mem.critical',
        category: 'system',
        severity: 'critical',
        summary: '메모리 부족',
        detail: '메모리 $memUsed/${memTotal}MB ($memUsage%)',
        metadata: {'memUsage': memUsage, 'memUsed': memUsed, 'memTotal': memTotal},
      ));
    } else if (memUsage >= 85) {
      issues.add(DetectedIssue(
        fingerprint: 'mem.warning',
        category: 'system',
        severity: 'warning',
        summary: '메모리 사용률 높음',
        detail: '메모리 $memUsage%',
        metadata: {'memUsage': memUsage},
      ));
    }

    // 3. 디스크 부족
    final disks = (sys['disks'] as List?) ?? [];
    for (final disk in disks) {
      final d = disk as Map<String, dynamic>;
      final usage = (d['usage'] as num?)?.toInt() ?? 0;
      final drive = d['drive']?.toString() ?? '?';
      if (usage >= 95) {
        issues.add(DetectedIssue(
          fingerprint: 'disk.critical.$drive',
          category: 'cleanup',
          severity: 'critical',
          summary: '디스크 부족 ($drive)',
          detail: '사용률 $usage%',
          metadata: {'drive': drive, 'usage': usage},
        ));
      } else if (usage >= 90) {
        issues.add(DetectedIssue(
          fingerprint: 'disk.warning.$drive',
          category: 'cleanup',
          severity: 'warning',
          summary: '디스크 사용률 높음 ($drive)',
          detail: '사용률 $usage%',
          metadata: {'drive': drive, 'usage': usage},
        ));
      }
    }

    // 4. 배터리 부족 (랩탑)
    final battery = sys['battery'] as Map<String, dynamic>?;
    if (battery != null && battery['hasBattery'] == true) {
      final percent = (battery['percent'] as num?)?.toInt() ?? 100;
      final charging = battery['charging'] == true;
      if (percent <= 10 && !charging) {
        issues.add(DetectedIssue(
          fingerprint: 'battery.critical',
          category: 'system',
          severity: 'critical',
          summary: '배터리 부족',
          detail: '배터리 $percent% (충전 안 됨)',
          metadata: {'percent': percent, 'charging': charging},
        ));
      }
    }

    // 5. 인터넷 연결 불가
    final net = diag['network'] as Map<String, dynamic>?;
    if (net != null) {
      final internetConnected = net['internetConnected'] == true;
      if (!internetConnected) {
        final hasDns = ((net['dns'] as List?) ?? []).isNotEmpty;
        final hasGateway = (net['gateway']?.toString() ?? '').isNotEmpty;
        String fingerprint;
        String summary;
        if (!hasGateway) {
          fingerprint = 'net.no_gateway';
          summary = '네트워크 연결 끊김';
        } else if (!hasDns) {
          fingerprint = 'net.no_dns';
          summary = 'DNS 오류 의심';
        } else {
          fingerprint = 'net.no_internet';
          summary = '인터넷 접속 불가';
        }
        issues.add(DetectedIssue(
          fingerprint: fingerprint,
          category: 'network',
          severity: 'critical',
          summary: summary,
          detail: '게이트웨이: ${hasGateway ? "OK" : "없음"}, DNS: ${hasDns ? "OK" : "없음"}',
          metadata: {'hasGateway': hasGateway, 'hasDns': hasDns},
        ));
      }
    }

    // 쿨다운 적용 — 최근 5분 이내 동일 fingerprint는 제외
    final now = DateTime.now();
    final filtered = <DetectedIssue>[];
    for (final issue in issues) {
      final last = _lastNotified[issue.fingerprint];
      if (last == null || now.difference(last) >= _cooldown) {
        _lastNotified[issue.fingerprint] = now;
        filtered.add(issue);
        debugPrint('[detector] 이슈 감지: ${issue.fingerprint} (${issue.severity})');
      }
    }
    return filtered;
  }

  /// 상태 초기화 (재연결 시 호출)
  void reset() {
    _lastNotified.clear();
    _cpuHistory.clear();
  }
}

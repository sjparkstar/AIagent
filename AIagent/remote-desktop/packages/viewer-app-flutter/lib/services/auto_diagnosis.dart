/// 호스트 시스템 진단 데이터를 분석하여 이상 징후를 감지하는 자동 진단 엔진
/// 웹 뷰어의 auto-diagnosis.ts와 동일한 로직
library;

enum Severity { critical, warning, info, ok }

class DiagnosisResult {
  final String category;
  final String title;
  final String detail;
  final Severity severity;

  const DiagnosisResult({
    required this.category,
    required this.title,
    required this.detail,
    required this.severity,
  });
}

class AutoDiagnosis {
  final List<double> _cpuHistory = [];

  List<DiagnosisResult> run(Map<String, dynamic> diag) {
    final results = <DiagnosisResult>[];
    final s = diag['system'] as Map<String, dynamic>?;
    if (s == null) return results;

    final n = (diag['network'] as Map<String, dynamic>?) ??
        {
          'interfaces': [],
          'gateway': '',
          'dns': [],
          'internetConnected': false,
          'wifi': null,
          'vpnConnected': false,
        };
    final p = (diag['processes'] as Map<String, dynamic>?) ??
        {
          'topCpu': [],
          'services': [],
        };

    // 1. CPU 과부하
    final cpuUsage = (s['cpuUsage'] as num?)?.toDouble() ?? 0;
    _cpuHistory.add(cpuUsage);
    if (_cpuHistory.length > 36) {
      _cpuHistory.removeRange(0, _cpuHistory.length - 36);
    }

    if (cpuUsage >= 95) {
      final topCpuList = (p['topCpu'] as List?) ?? [];
      final topProc =
          topCpuList.isNotEmpty ? topCpuList[0] as Map<String, dynamic> : null;
      final sustained =
          _cpuHistory.length >= 36 && _cpuHistory.every((v) => v >= 90);
      results.add(DiagnosisResult(
        category: '시스템',
        title: 'CPU 과부하',
        detail: sustained
            ? 'CPU ${cpuUsage.toInt()}%가 3분 이상 지속 중. ${topProc != null ? "상위 프로세스: ${topProc['name']} (${topProc['cpu']}%)" : ""} → 해당 프로세스 이상징후 의심'
            : 'CPU ${cpuUsage.toInt()}%. ${topProc != null ? "상위: ${topProc['name']} (${topProc['cpu']}%)" : ""}',
        severity: sustained ? Severity.critical : Severity.warning,
      ));
    } else if (cpuUsage >= 80) {
      results.add(DiagnosisResult(
        category: '시스템',
        title: 'CPU 사용률 높음',
        detail: 'CPU ${cpuUsage.toInt()}%. 모니터링 필요.',
        severity: Severity.warning,
      ));
    }

    // 2. 메모리 부족
    final memUsage = (s['memUsage'] as num?)?.toInt() ?? 0;
    final memUsed = (s['memUsed'] as num?)?.toInt() ?? 0;
    final memTotal = (s['memTotal'] as num?)?.toInt() ?? 0;
    if (memUsage >= 95) {
      results.add(DiagnosisResult(
        category: '시스템',
        title: '메모리 부족',
        detail:
            '메모리 ${memUsed}MB / ${memTotal}MB ($memUsage%) → 앱 응답 지연/크래시 가능',
        severity: Severity.critical,
      ));
    } else if (memUsage >= 85) {
      results.add(DiagnosisResult(
        category: '시스템',
        title: '메모리 사용률 높음',
        detail: '메모리 $memUsage%. 불필요한 프로세스 종료 권장.',
        severity: Severity.warning,
      ));
    }

    // 3. 디스크 부족
    final disks = (s['disks'] as List?) ?? [];
    for (final disk in disks) {
      final d = disk as Map<String, dynamic>;
      final usage = (d['usage'] as num?)?.toInt() ?? 0;
      final drive = d['drive'] ?? '';
      final used = d['used'] ?? 0;
      final total = d['total'] ?? 0;
      if (usage >= 95) {
        results.add(DiagnosisResult(
          category: '시스템',
          title: '디스크 부족 ($drive)',
          detail: '$drive $used/${total}GB ($usage%) → 임시 파일 정리 또는 용량 확보 필요',
          severity: Severity.critical,
        ));
      } else if (usage >= 85) {
        results.add(DiagnosisResult(
          category: '시스템',
          title: '디스크 사용률 높음 ($drive)',
          detail: '$drive $usage%.',
          severity: Severity.warning,
        ));
      }
    }

    // 4. 배터리
    final battery = s['battery'] as Map<String, dynamic>?;
    if (battery != null && battery['hasBattery'] == true) {
      final percent = (battery['percent'] as num?)?.toInt() ?? 100;
      final charging = battery['charging'] == true;
      if (percent <= 10 && !charging) {
        results.add(DiagnosisResult(
          category: '시스템',
          title: '배터리 부족',
          detail: '배터리 $percent% (충전 안 됨) → 원격 세션 중 전원 꺼질 수 있음',
          severity: Severity.critical,
        ));
      } else if (percent <= 20 && !charging) {
        results.add(DiagnosisResult(
          category: '시스템',
          title: '배터리 낮음',
          detail: '배터리 $percent%. 충전기 연결 권장.',
          severity: Severity.warning,
        ));
      }
    }

    // 5. 인터넷 연결
    final internetConnected = n['internetConnected'] == true;
    if (!internetConnected) {
      final hasDns = ((n['dns'] as List?) ?? []).isNotEmpty;
      final hasGateway = (n['gateway']?.toString() ?? '').isNotEmpty;
      if (!hasGateway) {
        results.add(const DiagnosisResult(
          category: '네트워크',
          title: '인터넷 불가',
          detail: '게이트웨이 없음 → 네트워크 케이블/WiFi 연결 확인 필요',
          severity: Severity.critical,
        ));
      } else if (!hasDns) {
        results.add(const DiagnosisResult(
          category: '네트워크',
          title: 'DNS 오류 의심',
          detail: '게이트웨이 정상, DNS 서버 없음 → DNS 설정 확인 필요',
          severity: Severity.critical,
        ));
      } else {
        results.add(const DiagnosisResult(
          category: '네트워크',
          title: '인터넷 불가',
          detail: '게이트웨이/DNS 정상이나 외부 통신 실패 → 방화벽/프록시 차단 의심',
          severity: Severity.critical,
        ));
      }
    }

    // 6. WiFi 신호 약함
    final wifi = n['wifi'] as Map<String, dynamic>?;
    if (wifi != null) {
      final signal = (wifi['signal'] as num?)?.toInt() ?? 100;
      if (signal < 30) {
        results.add(DiagnosisResult(
          category: '네트워크',
          title: 'WiFi 신호 약함',
          detail: '${wifi['ssid']} ($signal%) → 원격 화면 끊김/지연 발생 가능',
          severity: Severity.warning,
        ));
      }
    }

    // 7. 프로세스 CPU 과점유
    final topCpuList = (p['topCpu'] as List?) ?? [];
    for (final proc in topCpuList.take(3)) {
      final pr = proc as Map<String, dynamic>;
      final cpu = (pr['cpu'] as num?)?.toInt() ?? 0;
      if (cpu >= 50) {
        results.add(DiagnosisResult(
          category: '프로세스',
          title: '${pr['name']} CPU 과점유',
          detail:
              '${pr['name']} (PID ${pr['pid']}) — CPU $cpu%, 메모리 ${pr['mem']}MB → 프로세스 이상 또는 무한루프 의심',
          severity: cpu >= 80 ? Severity.critical : Severity.warning,
        ));
      }
    }

    // 8. 메모리 과점유 프로세스
    for (final proc in topCpuList) {
      final pr = proc as Map<String, dynamic>;
      final mem = (pr['mem'] as num?)?.toInt() ?? 0;
      if (mem >= 2048) {
        results.add(DiagnosisResult(
          category: '프로세스',
          title: '${pr['name']} 메모리 과점유',
          detail: '${pr['name']} — ${mem}MB 사용 → 메모리 누수 가능',
          severity: mem >= 4096 ? Severity.warning : Severity.info,
        ));
        break;
      }
    }

    // 9. 모니터 구성
    final userEnv =
        (diag['userEnv'] as Map<String, dynamic>?) ?? {'monitors': []};
    final monitors = (userEnv['monitors'] as List?) ?? [];
    if (monitors.isEmpty) {
      results.add(const DiagnosisResult(
        category: '환경',
        title: '모니터 감지 불가',
        detail: '디스플레이를 감지할 수 없음 → 화면 캡처 권한/드라이버 확인',
        severity: Severity.warning,
      ));
    }

    // 모든 항목 정상일 때
    if (results.isEmpty) {
      results.add(const DiagnosisResult(
        category: '종합',
        title: '시스템 정상',
        detail: '모든 진단 항목이 정상 범위입니다.',
        severity: Severity.ok,
      ));
    }

    return results;
  }

  void reset() {
    _cpuHistory.clear();
  }
}

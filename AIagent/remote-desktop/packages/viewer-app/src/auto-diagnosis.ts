import type { SystemDiagnostics } from "@remote-desktop/shared";

export type Severity = "critical" | "warning" | "info" | "ok";

export interface DiagnosisResult {
  category: string;
  title: string;
  detail: string;
  severity: Severity;
}

let cpuHistory: number[] = [];

export function runDiagnosis(diag: SystemDiagnostics): DiagnosisResult[] {
  const results: DiagnosisResult[] = [];
  if (!diag?.system) return results;
  const s = diag.system;
  const n = diag.network ?? { interfaces: [], gateway: "", dns: [], internetConnected: false, wifi: null, vpnConnected: false };
  const p = diag.processes ?? { topCpu: [], services: [] };

  // ── 1. CPU 과부하 ─────────────────────────────────
  cpuHistory.push(s.cpuUsage);
  if (cpuHistory.length > 36) cpuHistory = cpuHistory.slice(-36); // 5초 × 36 = 3분

  if (s.cpuUsage >= 95) {
    const topProc = p.topCpu[0];
    const sustained = cpuHistory.length >= 36 && cpuHistory.every((v) => v >= 90);
    results.push({
      category: "시스템",
      title: "CPU 과부하",
      detail: sustained
        ? `CPU ${s.cpuUsage}%가 3분 이상 지속 중. ${topProc ? `상위 프로세스: ${topProc.name} (${topProc.cpu}%)` : ""} → 해당 프로세스 이상징후 의심`
        : `CPU ${s.cpuUsage}%. ${topProc ? `상위: ${topProc.name} (${topProc.cpu}%)` : ""}`,
      severity: sustained ? "critical" : "warning",
    });
  } else if (s.cpuUsage >= 80) {
    results.push({
      category: "시스템",
      title: "CPU 사용률 높음",
      detail: `CPU ${s.cpuUsage}%. 모니터링 필요.`,
      severity: "warning",
    });
  }

  // ── 2. 메모리 부족 ────────────────────────────────
  if (s.memUsage >= 95) {
    results.push({
      category: "시스템",
      title: "메모리 부족",
      detail: `메모리 ${s.memUsed}MB / ${s.memTotal}MB (${s.memUsage}%) → 앱 응답 지연/크래시 가능`,
      severity: "critical",
    });
  } else if (s.memUsage >= 85) {
    results.push({
      category: "시스템",
      title: "메모리 사용률 높음",
      detail: `메모리 ${s.memUsage}%. 불필요한 프로세스 종료 권장.`,
      severity: "warning",
    });
  }

  // ── 3. 디스크 부족 ────────────────────────────────
  for (const disk of s.disks) {
    if (disk.usage >= 95) {
      results.push({
        category: "시스템",
        title: `디스크 부족 (${disk.drive})`,
        detail: `${disk.drive} ${disk.used}/${disk.total}GB (${disk.usage}%) → 임시 파일 정리 또는 용량 확보 필요`,
        severity: "critical",
      });
    } else if (disk.usage >= 85) {
      results.push({
        category: "시스템",
        title: `디스크 사용률 높음 (${disk.drive})`,
        detail: `${disk.drive} ${disk.usage}%.`,
        severity: "warning",
      });
    }
  }

  // ── 4. 배터리 ─────────────────────────────────────
  if (s.battery && s.battery.hasBattery && s.battery.percent <= 10 && !s.battery.charging) {
    results.push({
      category: "시스템",
      title: "배터리 부족",
      detail: `배터리 ${s.battery.percent}% (충전 안 됨) → 원격 세션 중 전원 꺼질 수 있음`,
      severity: "critical",
    });
  } else if (s.battery && s.battery.hasBattery && s.battery.percent <= 20 && !s.battery.charging) {
    results.push({
      category: "시스템",
      title: "배터리 낮음",
      detail: `배터리 ${s.battery.percent}%. 충전기 연결 권장.`,
      severity: "warning",
    });
  }

  // ── 5. 인터넷 연결 ────────────────────────────────
  if (!n.internetConnected) {
    const hasDns = n.dns.length > 0;
    const hasGateway = !!n.gateway;
    if (!hasGateway) {
      results.push({
        category: "네트워크",
        title: "인터넷 불가",
        detail: "게이트웨이 없음 → 네트워크 케이블/WiFi 연결 확인 필요",
        severity: "critical",
      });
    } else if (!hasDns) {
      results.push({
        category: "네트워크",
        title: "DNS 오류 의심",
        detail: "게이트웨이 정상, DNS 서버 없음 → DNS 설정 확인 필요",
        severity: "critical",
      });
    } else {
      results.push({
        category: "네트워크",
        title: "인터넷 불가",
        detail: "게이트웨이/DNS 정상이나 외부 통신 실패 → 방화벽/프록시 차단 의심",
        severity: "critical",
      });
    }
  }

  // ── 6. WiFi 신호 약함 ─────────────────────────────
  if (n.wifi && n.wifi.signal < 30) {
    results.push({
      category: "네트워크",
      title: "WiFi 신호 약함",
      detail: `${n.wifi.ssid} (${n.wifi.signal}%) → 원격 화면 끊김/지연 발생 가능`,
      severity: "warning",
    });
  }

  // ── 7. 방화벽 비활성 ──────────────────────────────
  if (diag.security.firewallEnabled === false && diag.security.defenderEnabled === false) {
    // 보안 정보가 수집된 경우에만 (값이 false이고 수집 안 된 게 아닌지)
    // security 필드가 모두 false이면 수집 안 됐을 가능성 → 건너뜀
  }

  // ── 8. 프로세스 CPU 과점유 ────────────────────────
  for (const proc of p.topCpu.slice(0, 3)) {
    if (proc.cpu >= 50) {
      results.push({
        category: "프로세스",
        title: `${proc.name} CPU 과점유`,
        detail: `${proc.name} (PID ${proc.pid}) — CPU ${proc.cpu}%, 메모리 ${proc.mem}MB → 프로세스 이상 또는 무한루프 의심`,
        severity: proc.cpu >= 80 ? "critical" : "warning",
      });
    }
  }

  // ── 9. 메모리 과점유 프로세스 ─────────────────────
  for (const proc of p.topCpu) {
    if (proc.mem >= 2048) {
      results.push({
        category: "프로세스",
        title: `${proc.name} 메모리 과점유`,
        detail: `${proc.name} — ${proc.mem}MB 사용 → 메모리 누수 가능`,
        severity: proc.mem >= 4096 ? "warning" : "info",
      });
      break; // 최상위 1개만
    }
  }

  // ── 10. 모니터 구성 ───────────────────────────────
  if (diag.userEnv.monitors.length === 0) {
    results.push({
      category: "환경",
      title: "모니터 감지 불가",
      detail: "디스플레이를 감지할 수 없음 → 화면 캡처 권한/드라이버 확인",
      severity: "warning",
    });
  }

  // ── 모든 항목 정상일 때 ───────────────────────────
  if (results.length === 0) {
    results.push({
      category: "종합",
      title: "시스템 정상",
      detail: "모든 진단 항목이 정상 범위입니다.",
      severity: "ok",
    });
  }

  return results;
}

export function resetDiagnosis(): void {
  cpuHistory = [];
}

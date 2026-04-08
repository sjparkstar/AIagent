import type { SystemDiagnostics } from "@remote-desktop/shared";
import { screen } from "electron";

const os = require("os") as typeof import("os");
const { exec } = require("child_process") as typeof import("child_process");

const PLATFORM = os.platform(); // "win32" | "darwin" | "linux"

let prevCpuTimes: { idle: number; total: number } | null = null;

function getCpuUsage(): number {
  const cpus = os.cpus();
  let idle = 0;
  let total = 0;
  for (const cpu of cpus) {
    idle += cpu.times.idle;
    total += cpu.times.user + cpu.times.nice + cpu.times.sys + cpu.times.irq + cpu.times.idle;
  }
  if (!prevCpuTimes) {
    prevCpuTimes = { idle, total };
    return 0;
  }
  const idleDiff = idle - prevCpuTimes.idle;
  const totalDiff = total - prevCpuTimes.total;
  prevCpuTimes = { idle, total };
  return totalDiff > 0 ? Math.round((1 - idleDiff / totalDiff) * 100) : 0;
}

function runCmd(command: string, timeoutMs = 2000): Promise<string> {
  return new Promise((resolve) => {
    exec(command, { encoding: "utf8", timeout: timeoutMs, windowsHide: true }, (err, stdout) => {
      resolve(err ? "" : (stdout ?? "").trim());
    });
  });
}

function collectSystem(): SystemDiagnostics["system"] {
  const totalMem = os.totalmem();
  const freeMem = os.freemem();
  const memUsed = Math.round((totalMem - freeMem) / 1024 / 1024);
  const memTotal = Math.round(totalMem / 1024 / 1024);
  const uptimeSec = Math.round(os.uptime());
  const bootTime = new Date(Date.now() - uptimeSec * 1000).toISOString();

  return {
    os: `${os.type()} ${os.arch()}`,
    version: os.release(),
    build: os.release().split(".").pop() ?? "",
    pcName: os.hostname(),
    userName: os.userInfo().username,
    bootTime,
    uptime: uptimeSec,
    cpuModel: os.cpus()[0]?.model ?? "Unknown",
    cpuUsage: getCpuUsage(),
    cpuCores: os.cpus().length,
    memTotal,
    memUsed,
    memUsage: memTotal > 0 ? Math.round((memUsed / memTotal) * 100) : 0,
    disks: [],
    battery: null,
    isAdmin: false,
  };
}

// ── 디스크 ──────────────────────────────────────────────

async function collectDisks(): Promise<SystemDiagnostics["system"]["disks"]> {
  try {
    if (PLATFORM === "win32") {
      const raw = await runCmd('wmic logicaldisk where "DriveType=3" get DeviceID,Size,FreeSpace /format:csv');
      const lines = raw.split("\n").filter((l) => l.includes(",") && !l.startsWith("Node"));
      return lines.map((line) => {
        const parts = line.trim().split(",");
        const free = Math.round(Number(parts[2] ?? 0) / 1073741824);
        const total = Math.round(Number(parts[3] ?? 0) / 1073741824);
        return { drive: parts[1] ?? "", total, used: total - free, usage: total > 0 ? Math.round(((total - free) / total) * 100) : 0 };
      }).filter((d) => d.total > 0);
    }
    if (PLATFORM === "darwin" || PLATFORM === "linux") {
      const raw = await runCmd("df -k --output=source,size,used,pcent,target 2>/dev/null || df -k");
      const lines = raw.split("\n").slice(1).filter((l) => l.startsWith("/"));
      return lines.map((line) => {
        const parts = line.trim().split(/\s+/);
        const total = Math.round(Number(parts[1] ?? 0) / 1048576);
        const used = Math.round(Number(parts[2] ?? 0) / 1048576);
        return { drive: parts[parts.length - 1] ?? parts[0] ?? "", total, used, usage: total > 0 ? Math.round((used / total) * 100) : 0 };
      }).filter((d) => d.total > 0);
    }
  } catch {}
  return [];
}

// ── 배터리 ──────────────────────────────────────────────

async function collectBattery(): Promise<SystemDiagnostics["system"]["battery"]> {
  try {
    if (PLATFORM === "win32") {
      const raw = await runCmd("wmic path Win32_Battery get EstimatedChargeRemaining,BatteryStatus /format:csv");
      const lines = raw.split("\n").filter((l) => l.includes(",") && !l.startsWith("Node"));
      if (lines.length === 0) return null;
      const parts = lines[0].trim().split(",");
      return { hasBattery: true, percent: parseInt(parts[2] ?? "0", 10), charging: parts[1] === "2" };
    }
    if (PLATFORM === "darwin") {
      const raw = await runCmd("pmset -g batt");
      const pctMatch = raw.match(/(\d+)%/);
      const charging = raw.includes("AC Power") || raw.includes("charging");
      if (pctMatch) return { hasBattery: true, percent: parseInt(pctMatch[1], 10), charging };
    }
    if (PLATFORM === "linux") {
      const raw = await runCmd("cat /sys/class/power_supply/BAT0/capacity 2>/dev/null");
      const statusRaw = await runCmd("cat /sys/class/power_supply/BAT0/status 2>/dev/null");
      if (raw) return { hasBattery: true, percent: parseInt(raw, 10), charging: statusRaw.toLowerCase() === "charging" };
    }
  } catch {}
  return null;
}

// ── 네트워크 ────────────────────────────────────────────

function collectNetworkBasic(): SystemDiagnostics["network"] {
  const rawInterfaces = os.networkInterfaces();
  const interfaces: SystemDiagnostics["network"]["interfaces"] = [];
  for (const [name, addrs] of Object.entries(rawInterfaces)) {
    if (!addrs) continue;
    for (const addr of addrs) {
      if (addr.family === "IPv4" && !addr.internal) {
        interfaces.push({
          name,
          ip: addr.address,
          mac: addr.mac,
          type: name.toLowerCase().includes("wi") || name.toLowerCase().includes("wlan") ? "wifi" : "ethernet",
        });
      }
    }
  }
  return { interfaces, gateway: "", dns: [], internetConnected: false, wifi: null, vpnConnected: false };
}

async function enrichNetwork(net: SystemDiagnostics["network"]): Promise<void> {
  // Gateway + DNS
  try {
    if (PLATFORM === "win32") {
      const raw = await runCmd("ipconfig /all");
      const gwMatch = raw.match(/Default Gateway[\s.]*:\s*([\d.]+)/);
      if (gwMatch) net.gateway = gwMatch[1];
      const dnsMatches = raw.matchAll(/DNS Servers[\s.]*:\s*([\d.]+)/g);
      for (const m of dnsMatches) net.dns.push(m[1]);
    } else {
      const gw = await runCmd("ip route 2>/dev/null | grep default | awk '{print $3}' || route -n get default 2>/dev/null | grep gateway | awk '{print $2}'");
      if (gw) net.gateway = gw.split("\n")[0];
      const dns = await runCmd("cat /etc/resolv.conf 2>/dev/null | grep nameserver | awk '{print $2}'");
      if (dns) net.dns = dns.split("\n").filter(Boolean);
    }
  } catch {}

  // Internet check
  try {
    const pingCmd = PLATFORM === "win32" ? "ping -n 1 -w 1000 8.8.8.8" : "ping -c 1 -W 1 8.8.8.8";
    const raw = await runCmd(pingCmd);
    net.internetConnected = raw.includes("TTL=") || raw.includes("ttl=") || raw.includes("time=");
  } catch {}

  // WiFi
  try {
    if (PLATFORM === "win32") {
      const raw = await runCmd("netsh wlan show interfaces");
      const ssidMatch = raw.match(/SSID\s*:\s*(.+)/);
      const signalMatch = raw.match(/Signal\s*:\s*(\d+)%/) || raw.match(/신호\s*:\s*(\d+)%/);
      if (ssidMatch) net.wifi = { ssid: ssidMatch[1].trim(), signal: signalMatch ? parseInt(signalMatch[1], 10) : 0 };
    } else if (PLATFORM === "darwin") {
      const raw = await runCmd("/System/Library/PrivateFrameworks/Apple80211.framework/Versions/Current/Resources/airport -I 2>/dev/null");
      const ssidMatch = raw.match(/\bSSID:\s*(.+)/);
      const rssiMatch = raw.match(/agrCtlRSSI:\s*(-?\d+)/);
      if (ssidMatch) net.wifi = { ssid: ssidMatch[1].trim(), signal: rssiMatch ? Math.min(100, Math.max(0, 100 + parseInt(rssiMatch[1], 10))) : 0 };
    } else {
      const raw = await runCmd("iwgetid -r 2>/dev/null");
      if (raw) {
        const signal = await runCmd("cat /proc/net/wireless 2>/dev/null | tail -1 | awk '{print $3}' | tr -d '.'");
        net.wifi = { ssid: raw, signal: signal ? Math.round(parseInt(signal, 10) * 100 / 70) : 0 };
      }
    }
  } catch {}
}

// ── 프로세스 ────────────────────────────────────────────

interface WmicProcSample {
  name: string;
  pid: number;
  cpuTime: number; // KernelModeTime + UserModeTime (100ns units)
  mem: number;     // MB
}

function parseWmicProcesses(raw: string): WmicProcSample[] {
  // wmic csv: Node,KernelModeTime,Name,ProcessId,UserModeTime,WorkingSetSize
  const lines = raw.split("\n").filter((l) => l.includes(",") && !l.startsWith("Node"));
  return lines.map((line) => {
    const parts = line.trim().split(",");
    const kernel = Number(parts[1] ?? 0);
    const user = Number(parts[4] ?? 0);
    return {
      name: parts[2] ?? "",
      pid: parseInt(parts[3] ?? "0", 10),
      cpuTime: kernel + user,
      mem: Math.round(Number(parts[5] ?? 0) / 1048576),
    };
  }).filter((p) => p.name && p.pid > 0);
}

function delay(ms: number): Promise<void> {
  return new Promise((resolve) => setTimeout(resolve, ms));
}

async function collectTopProcesses(): Promise<SystemDiagnostics["processes"]["topCpu"]> {
  try {
    if (PLATFORM === "win32") {
      const CMD = "wmic process get KernelModeTime,Name,ProcessId,UserModeTime,WorkingSetSize /format:csv";
      const raw1 = await runCmd(CMD, 3000);
      const sample1 = parseWmicProcesses(raw1);

      await delay(1000);

      const raw2 = await runCmd(CMD, 3000);
      const sample2 = parseWmicProcesses(raw2);

      const cpuCount = os.cpus().length || 1;
      // 1초 = 10,000,000 (100ns units)
      const intervalUnits = 10_000_000;

      const map1 = new Map(sample1.map((p) => [p.pid, p]));
      const results = sample2
        .filter((p2) => map1.has(p2.pid))
        .map((p2) => {
          const p1 = map1.get(p2.pid)!;
          const diff = p2.cpuTime - p1.cpuTime;
          const cpuPct = Math.round((diff / (intervalUnits * cpuCount)) * 100 * 10) / 10;
          return { name: p2.name, pid: p2.pid, cpu: Math.max(0, cpuPct), mem: p2.mem };
        });

      results.sort((a, b) => b.cpu - a.cpu);
      return results.slice(0, 10);
    }
    // macOS / Linux: ps (already shows CPU%)
    const raw = await runCmd("ps aux --sort=-%cpu 2>/dev/null | head -6 || ps aux -r 2>/dev/null | head -6");
    const lines = raw.split("\n").slice(1).filter(Boolean);
    return lines.map((line) => {
      const parts = line.trim().split(/\s+/);
      return { name: parts[10] ?? parts[parts.length - 1] ?? "", pid: parseInt(parts[1] ?? "0", 10), cpu: parseFloat(parts[2] ?? "0"), mem: Math.round(parseFloat(parts[5] ?? "0") / 1024) };
    }).slice(0, 10);
  } catch {}
  return [];
}

// ── 사용자 환경 ─────────────────────────────────────────

function collectUserEnv(): SystemDiagnostics["userEnv"] {
  const displays = screen.getAllDisplays();
  return {
    monitors: displays.map((d) => ({ width: d.size.width, height: d.size.height, scaleFactor: d.scaleFactor })),
    defaultBrowser: "",
    printers: [],
  };
}

// ── 메인 수집 ───────────────────────────────────────────

export async function collectDiagnostics(): Promise<SystemDiagnostics> {
  const system = collectSystem();
  const network = collectNetworkBasic();
  const userEnv = collectUserEnv();

  const [disks, battery, topCpu] = await Promise.all([
    collectDisks(),
    collectBattery(),
    collectTopProcesses(),
  ]);
  system.disks = disks;
  system.battery = battery;

  await enrichNetwork(network);

  return {
    system,
    processes: { topCpu, services: [] },
    network,
    security: { firewallEnabled: false, defenderEnabled: false, uacEnabled: false, antivirusProducts: [] },
    userEnv,
    recentEvents: [],
  };
}

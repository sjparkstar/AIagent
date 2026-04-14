import 'dart:convert';
import 'dart:io';
import 'package:flutter/foundation.dart';

class SystemDiagnostics {
  Future<Map<String, dynamic>> collect() async {
    // 프로세스 수집 제거 — wmic 2회 호출 + 1초 딜레이가 성능 병목
    final results = await Future.wait([
      _collectSystem(),
      _collectNetwork(),
    ]);
    return {
      'system': results[0],
      'processes': <dynamic>[],
      'network': results[1],
      'security': <String, dynamic>{},
      'userEnv': {'monitors': <dynamic>[], 'defaultBrowser': '', 'printers': <dynamic>[]},
      'recentEvents': <dynamic>[],
    };
  }

  Future<Map<String, dynamic>> collectBasic() async {
    if (Platform.isMacOS) return _collectBasicMacOS();

    final mem = await _runWmic('OS get TotalVisibleMemorySize,FreePhysicalMemory /format:csv');
    final cpu = await _runWmic('cpu get LoadPercentage /format:csv');

    int totalMB = 0, freeMB = 0, cpuUsage = 0;
    if (mem.isNotEmpty) {
      final p = mem.first.split(',');
      if (p.length >= 3) {
        freeMB = (int.tryParse(p[1].trim()) ?? 0) ~/ 1024;
        totalMB = (int.tryParse(p[2].trim()) ?? 0) ~/ 1024;
      }
    }
    if (cpu.isNotEmpty) {
      final p = cpu.first.split(',');
      if (p.length >= 2) cpuUsage = int.tryParse(p[1].trim()) ?? 0;
    }

    final uptime = await _getUptime();

    return {
      'hostname': Platform.localHostname,
      'os': Platform.operatingSystem,
      'osVersion': Platform.operatingSystemVersion,
      'cpuCount': Platform.numberOfProcessors,
      'cpuUsage': cpuUsage,
      'totalMemoryMB': totalMB,
      'freeMemoryMB': freeMB,
      'uptime': uptime,
    };
  }

  // ─── macOS 기본 진단 ────────────────────────────────────────────────────────

  Future<Map<String, dynamic>> _collectBasicMacOS() async {
    int totalMB = 0, freeMB = 0, cpuUsage = 0;

    try {
      final r = await Process.run('sysctl', ['-n', 'hw.memsize'])
          .timeout(const Duration(seconds: 3));
      final bytes = int.tryParse(r.stdout.toString().trim()) ?? 0;
      totalMB = bytes ~/ (1024 * 1024);
    } catch (_) {}

    try {
      final r = await Process.run('vm_stat', []).timeout(const Duration(seconds: 3));
      final out = r.stdout.toString();
      int pageSize = 4096;
      final psMatch = RegExp(r'page size of (\d+) bytes').firstMatch(out);
      if (psMatch != null) pageSize = int.tryParse(psMatch.group(1)!) ?? 4096;

      int freePages = 0;
      final freeMatch = RegExp(r'Pages free:\s+(\d+)').firstMatch(out);
      if (freeMatch != null) freePages = int.tryParse(freeMatch.group(1)!) ?? 0;
      final inactiveMatch = RegExp(r'Pages inactive:\s+(\d+)').firstMatch(out);
      if (inactiveMatch != null) freePages += int.tryParse(inactiveMatch.group(1)!) ?? 0;
      freeMB = (freePages * pageSize) ~/ (1024 * 1024);
    } catch (_) {}

    try {
      final r = await Process.run('sh', ['-c', "top -l 1 -n 0 | grep 'CPU usage'"])
          .timeout(const Duration(seconds: 5));
      final out = r.stdout.toString();
      final match = RegExp(r'([\d.]+)%\s+user').firstMatch(out);
      if (match != null) cpuUsage = double.tryParse(match.group(1)!)?.toInt() ?? 0;
    } catch (_) {}

    final uptime = await _getUptimeMacOS();

    return {
      'hostname': Platform.localHostname,
      'os': Platform.operatingSystem,
      'osVersion': Platform.operatingSystemVersion,
      'cpuCount': Platform.numberOfProcessors,
      'cpuUsage': cpuUsage,
      'totalMemoryMB': totalMB,
      'freeMemoryMB': freeMB,
      'uptime': uptime,
    };
  }

  Future<int> _getUptimeMacOS() async {
    try {
      final r = await Process.run('sysctl', ['-n', 'kern.boottime'])
          .timeout(const Duration(seconds: 3));
      final out = r.stdout.toString();
      final match = RegExp(r'sec\s*=\s*(\d+)').firstMatch(out);
      if (match != null) {
        final bootSec = int.tryParse(match.group(1)!) ?? 0;
        final now = DateTime.now().millisecondsSinceEpoch ~/ 1000;
        return now - bootSec;
      }
    } catch (_) {}
    return 0;
  }

  // ─── Windows 공통 ──────────────────────────────────────────────────────────

  Future<Map<String, dynamic>> _collectSystem() async {
    final basic = await collectBasic();
    final disks = Platform.isMacOS ? await _getDiskInfoMacOS() : await _getDiskInfo();
    final battery = Platform.isMacOS ? await _getBatteryMacOS() : await _getBattery();
    return {...basic, 'disks': disks, 'battery': battery};
  }

  Future<int> _getUptime() async {
    try {
      final r = await Process.run('net', ['statistics', 'workstation'], runInShell: true)
          .timeout(const Duration(seconds: 3));
      final out = r.stdout.toString();
      final match = RegExp(r'(\d{4}/\d{2}/\d{2})\s+(\d+:\d+:\d+)').firstMatch(out) ??
          RegExp(r'(\d{2}/\d{2}/\d{4})\s+(\d+:\d+:\d+)\s*(AM|PM)?').firstMatch(out);
      if (match != null) {
        final bootStr = '${match.group(1)} ${match.group(2)} ${match.group(3) ?? ''}'.trim();
        for (final fmt in [
          RegExp(r'(\d{4})/(\d{2})/(\d{2})\s+(\d+):(\d+):(\d+)'),
          RegExp(r'(\d{2})/(\d{2})/(\d{4})\s+(\d+):(\d+):(\d+)\s*(AM|PM)?'),
        ]) {
          final m = fmt.firstMatch(bootStr);
          if (m != null) {
            final now = DateTime.now();
            DateTime boot;
            if (m.groupCount >= 7) {
              var h = int.parse(m.group(4)!);
              if (m.group(7) == 'PM' && h < 12) h += 12;
              if (m.group(7) == 'AM' && h == 12) h = 0;
              boot = DateTime(int.parse(m.group(3)!), int.parse(m.group(1)!), int.parse(m.group(2)!), h, int.parse(m.group(5)!), int.parse(m.group(6)!));
            } else {
              boot = DateTime(int.parse(m.group(1)!), int.parse(m.group(2)!), int.parse(m.group(3)!), int.parse(m.group(4)!), int.parse(m.group(5)!), int.parse(m.group(6)!));
            }
            return now.difference(boot).inSeconds;
          }
        }
      }
    } catch (_) {}
    return 0;
  }

  Future<Map<String, dynamic>?> _getBattery() async {
    try {
      final lines = await _runWmic('path Win32_Battery get EstimatedChargeRemaining,BatteryStatus /format:csv');
      if (lines.isEmpty) return null;
      final p = lines.first.split(',');
      if (p.length >= 3) {
        return {
          'hasBattery': true,
          'percent': int.tryParse(p[2].trim()) ?? 0,
          'charging': p[1].trim() == '2',
        };
      }
    } catch (_) {}
    return null;
  }

  Future<Map<String, dynamic>?> _getBatteryMacOS() async {
    try {
      final r = await Process.run('pmset', ['-g', 'batt']).timeout(const Duration(seconds: 3));
      final out = r.stdout.toString();
      if (!out.contains('InternalBattery')) return null;
      final percentMatch = RegExp(r'(\d+)%').firstMatch(out);
      final charging = out.contains('charging') || out.contains('AC attached');
      return {
        'hasBattery': true,
        'percent': int.tryParse(percentMatch?.group(1) ?? '0') ?? 0,
        'charging': charging,
      };
    } catch (_) {}
    return null;
  }

  Future<List<Map<String, dynamic>>> _getDiskInfo() async {
    try {
      final lines = await _runWmic('logicaldisk where "DriveType=3" get DeviceID,Size,FreeSpace /format:csv');
      return lines.map((line) {
        final p = line.split(',');
        if (p.length >= 4) {
          final free = int.tryParse(p[2].trim()) ?? 0;
          final total = int.tryParse(p[3].trim()) ?? 0;
          return {'id': p[1].trim(), 'totalGB': (total / 1073741824).round(), 'freeGB': (free / 1073741824).round()};
        }
        return <String, dynamic>{};
      }).where((d) => d.isNotEmpty).toList();
    } catch (_) { return []; }
  }

  Future<List<Map<String, dynamic>>> _getDiskInfoMacOS() async {
    try {
      final r = await Process.run('df', ['-k']).timeout(const Duration(seconds: 3));
      final lines = r.stdout.toString().split('\n').skip(1);
      final disks = <Map<String, dynamic>>[];
      for (final line in lines) {
        final parts = line.trim().split(RegExp(r'\s+'));
        if (parts.length < 6) continue;
        final mountPoint = parts[5];
        if (!mountPoint.startsWith('/') || mountPoint.contains('/private') || mountPoint.contains('/dev')) continue;
        final total = (int.tryParse(parts[1]) ?? 0) * 1024;
        final used = (int.tryParse(parts[2]) ?? 0) * 1024;
        final free = (int.tryParse(parts[3]) ?? 0) * 1024;
        if (total == 0) continue;
        disks.add({
          'id': mountPoint,
          'totalGB': (total / 1073741824).round(),
          'freeGB': (free / 1073741824).round(),
          'usedGB': (used / 1073741824).round(),
        });
      }
      return disks;
    } catch (_) { return []; }
  }

  Future<List<Map<String, dynamic>>> _collectProcesses() async {
    if (Platform.isMacOS) return _collectProcessesMacOS();

    try {
      final lines1 = await _runWmic('process get Name,ProcessId,KernelModeTime,UserModeTime,WorkingSetSize /format:csv');
      await Future<void>.delayed(const Duration(seconds: 1));
      final lines2 = await _runWmic('process get Name,ProcessId,KernelModeTime,UserModeTime,WorkingSetSize /format:csv');

      final map1 = <int, int>{};
      for (final l in lines1) {
        final p = l.split(',');
        if (p.length >= 6) {
          final pid = int.tryParse(p[3].trim()) ?? 0;
          final k = int.tryParse(p[2].trim()) ?? 0;
          final u = int.tryParse(p[4].trim()) ?? 0;
          map1[pid] = k + u;
        }
      }

      final cpuCount = Platform.numberOfProcessors;
      final procs = <Map<String, dynamic>>[];
      for (final l in lines2) {
        final p = l.split(',');
        if (p.length >= 6) {
          final name = p[1].trim();
          final pid = int.tryParse(p[3].trim()) ?? 0;
          final k = int.tryParse(p[2].trim()) ?? 0;
          final u = int.tryParse(p[4].trim()) ?? 0;
          final wss = int.tryParse(p[5].trim()) ?? 0;
          final prev = map1[pid];
          double cpuPct = 0;
          if (prev != null) {
            final diff = (k + u) - prev;
            cpuPct = (diff / (10000000 * cpuCount) * 100);
            if (cpuPct < 0) cpuPct = 0;
          }
          if (name.isNotEmpty && pid > 0) {
            procs.add({'name': name, 'pid': pid, 'cpu': (cpuPct * 10).round() / 10, 'memoryMB': (wss / 1048576).round()});
          }
        }
      }
      procs.sort((a, b) => ((b['cpu'] as num)).compareTo(a['cpu'] as num));
      return procs.take(10).toList();
    } catch (e) {
      debugPrint('[diag] 프로세스 수집 실패: $e');
      return [];
    }
  }

  Future<List<Map<String, dynamic>>> _collectProcessesMacOS() async {
    try {
      final r = await Process.run('sh', ['-c', 'ps aux -r | head -11'])
          .timeout(const Duration(seconds: 5));
      final lines = r.stdout.toString().split('\n').skip(1);
      final procs = <Map<String, dynamic>>[];
      for (final line in lines) {
        final parts = line.trim().split(RegExp(r'\s+'));
        if (parts.length < 11) continue;
        final pid = int.tryParse(parts[1]) ?? 0;
        final cpu = double.tryParse(parts[2]) ?? 0.0;
        final memMB = (double.tryParse(parts[5]) ?? 0) / 1024;
        final name = parts.length > 10 ? parts[10].split('/').last : '';
        if (pid > 0 && name.isNotEmpty) {
          procs.add({'name': name, 'pid': pid, 'cpu': cpu, 'memoryMB': memMB.round()});
        }
      }
      return procs.take(10).toList();
    } catch (e) {
      debugPrint('[diag] macOS 프로세스 수집 실패: $e');
      return [];
    }
  }

  Future<Map<String, dynamic>> _collectNetwork() async {
    if (Platform.isMacOS) return _collectNetworkMacOS();

    final interfaces = <Map<String, dynamic>>[];
    bool internetAvailable = false;
    String gateway = '';
    List<String> dns = [];
    Map<String, dynamic>? wifi;

    try {
      final ni = await NetworkInterface.list(includeLoopback: false, type: InternetAddressType.IPv4);
      for (final n in ni) {
        interfaces.add({'name': n.name, 'addresses': n.addresses.map((a) => a.address).toList()});
      }
    } catch (_) {}

    try {
      final r = await Process.run('chcp', ['65001', '>nul', '2>&1', '&', 'ipconfig', '/all'], runInShell: true)
          .timeout(const Duration(seconds: 3));
      final out = r.stdout.toString();
      final gwMatch = RegExp(r'Default Gateway[\s.]*:\s*([\d.]+)').firstMatch(out) ??
          RegExp(r'기본 게이트웨이[\s.]*:\s*([\d.]+)').firstMatch(out);
      if (gwMatch != null) gateway = gwMatch.group(1)!;
      final dnsMatches = RegExp(r'DNS Servers[\s.]*:\s*([\d.]+)').allMatches(out).toList();
      if (dnsMatches.isEmpty) {
        dns = RegExp(r'DNS 서버[\s.]*:\s*([\d.]+)').allMatches(out).map((m) => m.group(1)!).toList();
      } else {
        dns = dnsMatches.map((m) => m.group(1)!).toList();
      }
    } catch (_) {}

    try {
      final r = await Process.run('ping', ['-n', '1', '-w', '1000', '8.8.8.8'], runInShell: true)
          .timeout(const Duration(seconds: 3));
      internetAvailable = r.stdout.toString().contains('TTL=') || r.stdout.toString().contains('ttl=');
    } catch (_) {}

    try {
      final r = await Process.run('netsh', ['wlan', 'show', 'interfaces'], runInShell: true)
          .timeout(const Duration(seconds: 3));
      final out = r.stdout.toString();
      final ssid = RegExp(r'SSID\s*:\s*(.+)').firstMatch(out);
      final signal = RegExp(r'(?:Signal|신호)\s*:\s*(\d+)%').firstMatch(out);
      if (ssid != null) {
        wifi = {'ssid': ssid.group(1)!.trim(), 'signal': signal != null ? int.parse(signal.group(1)!) : 0};
      }
    } catch (_) {}

    return {
      'interfaces': interfaces,
      'gateway': gateway,
      'dns': dns,
      'internetAvailable': internetAvailable,
      'wifi': wifi,
    };
  }

  Future<Map<String, dynamic>> _collectNetworkMacOS() async {
    final interfaces = <Map<String, dynamic>>[];
    bool internetAvailable = false;
    String gateway = '';
    List<String> dns = [];
    Map<String, dynamic>? wifi;

    try {
      final ni = await NetworkInterface.list(includeLoopback: false, type: InternetAddressType.IPv4);
      for (final n in ni) {
        interfaces.add({'name': n.name, 'addresses': n.addresses.map((a) => a.address).toList()});
      }
    } catch (_) {}

    try {
      final r = await Process.run('sh', ['-c', "route -n get default 2>/dev/null | grep gateway"])
          .timeout(const Duration(seconds: 3));
      final match = RegExp(r'gateway:\s*([\d.]+)').firstMatch(r.stdout.toString());
      if (match != null) gateway = match.group(1)!;
    } catch (_) {}

    try {
      final r = await Process.run('sh', ['-c', "cat /etc/resolv.conf | grep nameserver"])
          .timeout(const Duration(seconds: 3));
      dns = RegExp(r'nameserver\s+([\d.]+)').allMatches(r.stdout.toString()).map((m) => m.group(1)!).toList();
    } catch (_) {}

    try {
      final r = await Process.run('ping', ['-c', '1', '-W', '1000', '8.8.8.8'])
          .timeout(const Duration(seconds: 3));
      internetAvailable = r.stdout.toString().contains('ttl=') || r.stdout.toString().contains('TTL=');
    } catch (_) {}

    try {
      const airportPath = '/System/Library/PrivateFrameworks/Apple80211.framework/Versions/Current/Resources/airport';
      final r = await Process.run(airportPath, ['-I']).timeout(const Duration(seconds: 3));
      final out = r.stdout.toString();
      final ssidMatch = RegExp(r'\bSSID:\s*(.+)').firstMatch(out);
      final agrnMatch = RegExp(r'agrCtlRSSI:\s*(-?\d+)').firstMatch(out);
      if (ssidMatch != null) {
        final rssi = int.tryParse(agrnMatch?.group(1) ?? '-100') ?? -100;
        final signal = ((rssi + 100) * 2).clamp(0, 100);
        wifi = {'ssid': ssidMatch.group(1)!.trim(), 'signal': signal};
      }
    } catch (_) {}

    return {
      'interfaces': interfaces,
      'gateway': gateway,
      'dns': dns,
      'internetAvailable': internetAvailable,
      'wifi': wifi,
    };
  }

  Future<List<String>> _runWmic(String args) async {
    try {
      final parts = args.split(' ');
      // chcp 65001로 UTF-8 출력 강제 후 wmic 실행
      final r = await Process.run(
        'cmd', ['/c', 'chcp 65001 >nul 2>&1 & wmic ${parts.join(' ')}'],
        runInShell: true,
        stdoutEncoding: null,
        stderrEncoding: null,
      ).timeout(const Duration(seconds: 5));

      String out;
      if (r.stdout is List<int>) {
        out = utf8.decode(r.stdout as List<int>, allowMalformed: true);
      } else {
        out = r.stdout.toString();
      }

      return out.split('\n')
          .map((l) => l.replaceAll('\r', '').trim())
          .where((l) => l.isNotEmpty && !l.startsWith('Node'))
          .toList();
    } catch (_) { return []; }
  }
}

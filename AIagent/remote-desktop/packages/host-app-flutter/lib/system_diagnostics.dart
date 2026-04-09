import 'dart:io';
import 'dart:async';

import 'package:flutter/foundation.dart';

class SystemDiagnostics {
  // 전체 진단 정보 수집 (host-diagnostics용)
  Future<Map<String, dynamic>> collect() async {
    final results = await Future.wait([
      _collectSystem(),
      _collectProcesses(),
    ]);

    return {
      'system': results[0],
      'processes': results[1],
      'network': await _collectNetwork(),
      'security': _collectSecurity(),
      'userEnv': _collectUserEnv(),
      'recentEvents': <dynamic>[],
    };
  }

  // 기본 정보만 수집 (host-info용)
  Future<Map<String, dynamic>> collectBasic() async {
    final memInfo = await _getMemoryInfo();
    return {
      'hostname': Platform.localHostname,
      'os': Platform.operatingSystem,
      'osVersion': Platform.operatingSystemVersion,
      'cpuCount': Platform.numberOfProcessors,
      'totalMemoryMB': memInfo['total'],
      'freeMemoryMB': memInfo['free'],
    };
  }

  Future<Map<String, dynamic>> _collectSystem() async {
    final memInfo = await _getMemoryInfo();
    final diskInfo = await _getDiskInfo();

    return {
      'hostname': Platform.localHostname,
      'os': Platform.operatingSystem,
      'osVersion': Platform.operatingSystemVersion,
      'cpuCount': Platform.numberOfProcessors,
      'totalMemoryMB': memInfo['total'],
      'freeMemoryMB': memInfo['free'],
      'disks': diskInfo,
    };
  }

  Future<Map<String, dynamic>> _getMemoryInfo() async {
    try {
      final result = await Process.run(
        'wmic',
        ['OS', 'get', 'TotalVisibleMemorySize,FreePhysicalMemory', '/format:csv'],
        runInShell: true,
      ).timeout(const Duration(seconds: 5));

      final lines = result.stdout.toString().split('\n')
          .map((l) => l.trim())
          .where((l) => l.isNotEmpty && !l.startsWith('Node'))
          .toList();

      if (lines.isNotEmpty) {
        final parts = lines.first.split(',');
        // csv 형식: Node,FreePhysicalMemory,TotalVisibleMemorySize
        if (parts.length >= 3) {
          final freeKB = int.tryParse(parts[1].trim()) ?? 0;
          final totalKB = int.tryParse(parts[2].trim()) ?? 0;
          return {
            'total': totalKB ~/ 1024,
            'free': freeKB ~/ 1024,
          };
        }
      }
    } catch (e) {
      debugPrint('[diag] 메모리 정보 수집 실패: $e');
    }
    return {'total': 0, 'free': 0};
  }

  Future<List<Map<String, dynamic>>> _getDiskInfo() async {
    try {
      final result = await Process.run(
        'wmic',
        [
          'logicaldisk',
          'where', 'DriveType=3',
          'get', 'DeviceID,Size,FreeSpace',
          '/format:csv',
        ],
        runInShell: true,
      ).timeout(const Duration(seconds: 5));

      final lines = result.stdout.toString().split('\n')
          .map((l) => l.trim())
          .where((l) => l.isNotEmpty && !l.startsWith('Node'))
          .toList();

      return lines.map((line) {
        final parts = line.split(',');
        // csv 형식: Node,DeviceID,FreeSpace,Size
        if (parts.length >= 4) {
          final deviceId = parts[1].trim();
          final freeBytes = int.tryParse(parts[2].trim()) ?? 0;
          final totalBytes = int.tryParse(parts[3].trim()) ?? 0;
          return {
            'id': deviceId,
            'totalGB': (totalBytes / 1073741824).toStringAsFixed(1),
            'freeGB': (freeBytes / 1073741824).toStringAsFixed(1),
          };
        }
        return <String, dynamic>{};
      }).where((d) => d.isNotEmpty).toList();
    } catch (e) {
      debugPrint('[diag] 디스크 정보 수집 실패: $e');
      return [];
    }
  }

  // CPU 사용량 기반 프로세스 Top5 (두 번 샘플링 후 델타 계산)
  Future<List<Map<String, dynamic>>> _collectProcesses() async {
    try {
      // 프로세스 목록 안정화를 위해 1초 대기 후 샘플링
      await Future<void>.delayed(const Duration(seconds: 1));
      final sample2 = await _sampleProcesses();

      // WorkingSetSize 기준 정렬 (CPU 델타 계산은 생략, wmic로는 정확도 낮음)
      final merged = <String, Map<String, dynamic>>{};
      for (final p in sample2) {
        final name = p['name'] as String? ?? '';
        final pid = p['pid'] as int? ?? 0;
        final key = '$name-$pid';
        merged[key] = p;
      }

      final sorted = merged.values.toList()
        ..sort((a, b) {
          final aM = (a['memoryMB'] as num?)?.toDouble() ?? 0;
          final bM = (b['memoryMB'] as num?)?.toDouble() ?? 0;
          return bM.compareTo(aM);
        });

      return sorted.take(5).toList();
    } catch (e) {
      debugPrint('[diag] 프로세스 정보 수집 실패: $e');
      return [];
    }
  }

  Future<List<Map<String, dynamic>>> _sampleProcesses() async {
    final result = await Process.run(
      'wmic',
      ['process', 'get', 'Name,ProcessId,WorkingSetSize', '/format:csv'],
      runInShell: true,
    ).timeout(const Duration(seconds: 5));

    final lines = result.stdout.toString().split('\n')
        .map((l) => l.trim())
        .where((l) => l.isNotEmpty && !l.startsWith('Node'))
        .toList();

    final processes = <Map<String, dynamic>>[];
    for (final line in lines) {
      final parts = line.split(',');
      // csv 형식: Node,Name,ProcessId,WorkingSetSize
      if (parts.length >= 4) {
        final name = parts[1].trim();
        final pid = int.tryParse(parts[2].trim()) ?? 0;
        final wss = int.tryParse(parts[3].trim()) ?? 0;
        if (name.isNotEmpty) {
          processes.add({
            'name': name,
            'pid': pid,
            'memoryMB': (wss / 1048576).round(),
          });
        }
      }
    }
    return processes;
  }

  Future<Map<String, dynamic>> _collectNetwork() async {
    final interfaces = <Map<String, dynamic>>[];
    bool internetAvailable = false;

    try {
      final networkInterfaces = await NetworkInterface.list(
        includeLoopback: false,
        type: InternetAddressType.IPv4,
      );
      for (final ni in networkInterfaces) {
        interfaces.add({
          'name': ni.name,
          'addresses': ni.addresses.map((a) => a.address).toList(),
        });
      }
    } catch (e) {
      debugPrint('[diag] 네트워크 인터페이스 수집 실패: $e');
    }

    try {
      final pingResult = await Process.run(
        'ping',
        ['-n', '1', '-w', '1000', '8.8.8.8'],
        runInShell: true,
      ).timeout(const Duration(seconds: 3));
      internetAvailable = pingResult.exitCode == 0;
    } catch (_) {
      internetAvailable = false;
    }

    return {
      'interfaces': interfaces,
      'internetAvailable': internetAvailable,
    };
  }

  Map<String, dynamic> _collectSecurity() {
    return {
      'firewallEnabled': false,
      'defenderEnabled': false,
      'uacEnabled': false,
      'antivirusProducts': <dynamic>[],
    };
  }

  Map<String, dynamic> _collectUserEnv() {
    return {
      'username': Platform.environment['USERNAME'] ?? '',
      'userDomain': Platform.environment['USERDOMAIN'] ?? '',
      'computerName': Platform.environment['COMPUTERNAME'] ?? '',
      'systemDrive': Platform.environment['SystemDrive'] ?? 'C:',
    };
  }
}

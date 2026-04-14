// 자동진단/복구 이슈 관리 서비스
// 시그널링 WS에서 issue.notified를 수신하여 이슈 목록 관리
// REST API로 진단/복구 승인 요청

import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;

// 이슈 이벤트 모델
class IssueEvent {
  final String id;
  final String category;
  final String severity; // critical | warning | info
  final String summary;
  final String? detail;
  final DateTime detectedAt;
  String status; // detected, acknowledged, diagnosed, recovered, dismissed

  IssueEvent({
    required this.id,
    required this.category,
    required this.severity,
    required this.summary,
    this.detail,
    required this.detectedAt,
    this.status = 'detected',
  });

  factory IssueEvent.fromNotified(Map<String, dynamic> msg) {
    return IssueEvent(
      id: msg['issueId']?.toString() ?? '',
      category: msg['category']?.toString() ?? 'general',
      severity: msg['severity']?.toString() ?? 'warning',
      summary: msg['summary']?.toString() ?? '',
      detail: msg['detail']?.toString(),
      detectedAt: DateTime.tryParse(msg['detectedAt']?.toString() ?? '') ?? DateTime.now(),
    );
  }
}

// 승인 응답
class ApprovalResult {
  final String tokenId;
  final String expiresAt;
  final int scopeLevel;
  const ApprovalResult({
    required this.tokenId,
    required this.expiresAt,
    required this.scopeLevel,
  });
}

class IssueService {
  final String serverUrl; // http://host:8080
  final List<IssueEvent> _issues = [];

  // UI 갱신 콜백
  Function()? onIssuesChanged;

  IssueService({required this.serverUrl});

  List<IssueEvent> get issues => List.unmodifiable(_issues);
  List<IssueEvent> get activeIssues =>
      _issues.where((i) => i.status != 'closed' && i.status != 'dismissed').toList();

  /// 시그널링 WS의 issue.notified 메시지를 수신하여 이슈 추가
  void handleNotified(Map<String, dynamic> msg) {
    final issue = IssueEvent.fromNotified(msg);
    if (issue.id.isEmpty) return;
    // 동일 ID 이슈가 이미 있으면 업데이트
    final idx = _issues.indexWhere((e) => e.id == issue.id);
    if (idx >= 0) {
      _issues[idx] = issue;
    } else {
      _issues.insert(0, issue);
    }
    onIssuesChanged?.call();
    debugPrint('[issue] 수신: ${issue.id} (${issue.severity})');
  }

  /// 진단 승인 요청 (REST)
  Future<ApprovalResult?> approveDiagnostic({
    required String issueId,
    required String approverId,
    int scopeLevel = 1,
    String? sessionId,
  }) async {
    try {
      final resp = await http.post(
        Uri.parse('$serverUrl/api/diagnosis/approve'),
        headers: {'Content-Type': 'application/json'},
        body: jsonEncode({
          'issueId': issueId,
          'approvalType': 'diagnostic',
          'scopeLevel': scopeLevel,
          'approverId': approverId,
          'sessionId': sessionId,
        }),
      );
      if (resp.statusCode == 201) {
        final body = jsonDecode(resp.body) as Map<String, dynamic>;
        // 이슈 상태 갱신
        final idx = _issues.indexWhere((e) => e.id == issueId);
        if (idx >= 0) {
          _issues[idx].status = 'acknowledged';
          onIssuesChanged?.call();
        }
        return ApprovalResult(
          tokenId: body['tokenId']?.toString() ?? '',
          expiresAt: body['expiresAt']?.toString() ?? '',
          scopeLevel: (body['scopeLevel'] as num?)?.toInt() ?? 1,
        );
      }
      debugPrint('[issue] 진단 승인 실패: ${resp.statusCode} ${resp.body}');
    } catch (e) {
      debugPrint('[issue] 진단 승인 오류: $e');
    }
    return null;
  }

  /// 복구 승인 요청 (REST)
  Future<ApprovalResult?> approveRecovery({
    required String issueId,
    required String approverId,
    required int scopeLevel,
    List<String>? allowedActionIds,
    String? sessionId,
  }) async {
    try {
      final resp = await http.post(
        Uri.parse('$serverUrl/api/diagnosis/approve'),
        headers: {'Content-Type': 'application/json'},
        body: jsonEncode({
          'issueId': issueId,
          'approvalType': 'recovery',
          'scopeLevel': scopeLevel,
          'approverId': approverId,
          'allowedActionIds': allowedActionIds,
          'sessionId': sessionId,
        }),
      );
      if (resp.statusCode == 201) {
        final body = jsonDecode(resp.body) as Map<String, dynamic>;
        return ApprovalResult(
          tokenId: body['tokenId']?.toString() ?? '',
          expiresAt: body['expiresAt']?.toString() ?? '',
          scopeLevel: (body['scopeLevel'] as num?)?.toInt() ?? 1,
        );
      }
    } catch (e) {
      debugPrint('[issue] 복구 승인 오류: $e');
    }
    return null;
  }

  /// 이슈 무시 (상태 변경)
  void dismissIssue(String issueId) {
    final idx = _issues.indexWhere((e) => e.id == issueId);
    if (idx >= 0) {
      _issues[idx].status = 'dismissed';
      onIssuesChanged?.call();
    }
  }

  /// 이슈 목록 원격 조회 (세션 상세 등에서 사용)
  Future<List<IssueEvent>> loadIssues({String? sessionId}) async {
    try {
      final url = sessionId != null
          ? '$serverUrl/api/diagnosis/issues?sessionId=$sessionId'
          : '$serverUrl/api/diagnosis/issues';
      final resp = await http.get(Uri.parse(url));
      if (resp.statusCode == 200) {
        final rows = jsonDecode(resp.body) as List<dynamic>;
        return rows.map<IssueEvent>((r) {
          final m = r as Map<String, dynamic>;
          return IssueEvent(
            id: m['id']?.toString() ?? '',
            category: m['category']?.toString() ?? 'general',
            severity: m['severity']?.toString() ?? 'warning',
            summary: m['summary']?.toString() ?? '',
            detail: m['detail']?.toString(),
            detectedAt: DateTime.tryParse(m['detected_at']?.toString() ?? '') ?? DateTime.now(),
            status: m['status']?.toString() ?? 'detected',
          );
        }).toList();
      }
    } catch (e) {
      debugPrint('[issue] 이슈 조회 오류: $e');
    }
    return [];
  }

  /// 카테고리별 권장 플레이북 조회 (진단 결과 → 권장 복구)
  Future<List<Map<String, dynamic>>> loadPlaybooks({
    String? category,
    int maxLevel = 4,
  }) async {
    try {
      var url = '$serverUrl/api/diagnosis/playbooks?maxLevel=$maxLevel';
      if (category != null) url += '&category=$category';
      final resp = await http.get(Uri.parse(url));
      if (resp.statusCode == 200) {
        final rows = jsonDecode(resp.body) as List<dynamic>;
        return rows.cast<Map<String, dynamic>>();
      }
    } catch (e) {
      debugPrint('[issue] 플레이북 조회 오류: $e');
    }
    return [];
  }

  /// 감사 로그 조회
  Future<List<Map<String, dynamic>>> loadAuditLogs({String? sessionId, int limit = 100}) async {
    try {
      final url = sessionId != null
          ? '$serverUrl/api/diagnosis/audit?sessionId=$sessionId&limit=$limit'
          : '$serverUrl/api/diagnosis/audit?limit=$limit';
      final resp = await http.get(Uri.parse(url));
      if (resp.statusCode == 200) {
        final rows = jsonDecode(resp.body) as List<dynamic>;
        return rows.cast<Map<String, dynamic>>();
      }
    } catch (e) {
      debugPrint('[issue] 감사 로그 조회 오류: $e');
    }
    return [];
  }
}

import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:supabase_flutter/supabase_flutter.dart';

// 문서 검색 결과 한 건을 나타내는 모델
class SearchResult {
  final String content;
  final double similarity;

  const SearchResult({required this.content, required this.similarity});
}

// AI 어시스턴트 응답 모델 (source 필드 추가)
class AssistantResponse {
  final String answer;
  // "supabase" = 내부 문서 기반, "llm" = AI 생성 답변
  final String source;
  final List<SearchResult> sources;

  const AssistantResponse({
    required this.answer,
    required this.source,
    required this.sources,
  });
}

// 매크로 항목 모델 (Supabase macros 테이블과 대응)
class MacroItem {
  final String id;
  final String name;
  final String description;
  // 카테고리: network, process, cleanup, diagnostic, security, system, general
  final String category;
  // 명령 타입: cmd, powershell, shell
  final String commandType;
  final String command;
  // 지원 OS: all, win32, darwin, linux
  final String os;
  final bool requiresAdmin;
  final bool isDangerous;

  const MacroItem({
    required this.id,
    required this.name,
    required this.description,
    required this.category,
    required this.commandType,
    required this.command,
    required this.os,
    required this.requiresAdmin,
    required this.isDangerous,
  });

  // Supabase row 데이터에서 MacroItem 생성
  factory MacroItem.fromRow(Map<String, dynamic> row) {
    return MacroItem(
      id: row['id']?.toString() ?? '',
      name: row['name']?.toString() ?? '',
      description: row['description']?.toString() ?? '',
      category: row['category']?.toString() ?? 'general',
      commandType: row['command_type']?.toString() ?? 'cmd',
      command: row['command']?.toString() ?? '',
      os: row['os']?.toString() ?? 'all',
      requiresAdmin: row['requires_admin'] as bool? ?? false,
      isDangerous: row['is_dangerous'] as bool? ?? false,
    );
  }
}

// 플레이북 단계 모델
class PlaybookStep {
  final String name;
  final String command;
  final String commandType;
  // 성공 확인: output에 이 문자열이 포함되어 있으면 성공으로 판정
  final String? validateContains;

  const PlaybookStep({
    required this.name,
    required this.command,
    required this.commandType,
    this.validateContains,
  });

  // JSONB steps 배열 원소에서 PlaybookStep 생성
  factory PlaybookStep.fromMap(Map<String, dynamic> map) {
    return PlaybookStep(
      name: map['name']?.toString() ?? '',
      command: map['command']?.toString() ?? '',
      commandType: map['command_type']?.toString() ?? 'cmd',
      validateContains: map['validate_contains']?.toString(),
    );
  }
}

// 플레이북 항목 모델 (Supabase playbooks 테이블과 대응)
class PlaybookItem {
  final String id;
  final String name;
  final String description;
  final List<PlaybookStep> steps;

  const PlaybookItem({
    required this.id,
    required this.name,
    required this.description,
    required this.steps,
  });

  // Supabase row 데이터에서 PlaybookItem 생성
  factory PlaybookItem.fromRow(Map<String, dynamic> row) {
    final rawSteps = row['steps'] as List<dynamic>? ?? [];
    final steps = rawSteps
        .map((s) => PlaybookStep.fromMap(s as Map<String, dynamic>))
        .toList();
    return PlaybookItem(
      id: row['id']?.toString() ?? '',
      name: row['name']?.toString() ?? '',
      description: row['description']?.toString() ?? '',
      steps: steps,
    );
  }
}

class AssistantService {
  final String serverUrl;

  AssistantService({required this.serverUrl});

  SupabaseClient get _client => Supabase.instance.client;

  // 문서 검색 (Supabase documents 테이블 — Electron 뷰어와 동일)
  Future<List<SearchResult>> searchDocuments(String query) async {
    try {
      // 검색어를 공백 기준으로 분리하여 각 단어를 OR 검색
      final words = query.split(RegExp(r'\s+')).where((w) => w.isNotEmpty);
      if (words.isEmpty) return [];
      final orFilter = words.map((w) => 'title.ilike.%$w%').join(',');

      final rows = await _client
          .from('documents')
          .select('id, title, content, category, url')
          .or(orFilter)
          .limit(5);

      return rows
          .where((row) => row['title'] != null && row['content'] != null)
          .map<SearchResult>((row) {
        return SearchResult(
          content: row['content']?.toString() ?? '',
          similarity: 1.0,
        );
      }).toList();
    } catch (e) {
      debugPrint('[assistant] 문서 검색 실패: $e');
      return [];
    }
  }

  // AI 어시스턴트에 질문 전송 (/api/assistant-chat 엔드포인트 → Kimi LLM)
  Future<AssistantResponse> askAssistant(
    String query, {
    String? context,
  }) async {
    final sources = await searchDocuments(query);

    // 문서 검색 결과가 있으면 context로 전달, 없으면 null (서버가 LLM 모드 사용)
    final contextText = sources.isNotEmpty
        ? sources.map((s) => s.content).join('\n\n')
        : null;

    final apiUrl = '$serverUrl/api/assistant-chat';
    debugPrint('[assistant] API 요청: $apiUrl query="$query"');

    try {
      final uri = Uri.parse(apiUrl);
      final body = <String, dynamic>{'query': query};
      if (contextText != null) body['context'] = contextText;

      final response = await http
          .post(
            uri,
            headers: {'Content-Type': 'application/json'},
            body: jsonEncode(body),
          )
          .timeout(const Duration(seconds: 30));

      debugPrint('[assistant] 응답: ${response.statusCode}');

      if (response.statusCode == 200) {
        final data = jsonDecode(response.body) as Map<String, dynamic>;
        return AssistantResponse(
          answer: data['answer']?.toString() ?? '응답을 받지 못했습니다.',
          source: data['source']?.toString() ?? 'llm',
          sources: sources,
        );
      } else {
        debugPrint('[assistant] 서버 오류 ${response.statusCode}: ${response.body}');
        return AssistantResponse(
          answer: '서버 오류 (${response.statusCode}): ${response.body.length > 200 ? response.body.substring(0, 200) : response.body}',
          source: 'llm',
          sources: sources,
        );
      }
    } catch (e) {
      debugPrint('[assistant] API 호출 실패: $e');
      return AssistantResponse(
        answer: 'AI 서버 연결 실패: $e\n\n서버 URL: $apiUrl',
        source: 'llm',
        sources: sources,
      );
    }
  }

  // Supabase에서 활성화된 매크로 목록 조회 (sort_order 정렬)
  Future<List<MacroItem>> fetchMacros() async {
    try {
      final rows = await _client
          .from('macros')
          .select()
          .eq('enabled', true)
          .order('sort_order', ascending: true);

      return rows.map<MacroItem>((row) => MacroItem.fromRow(row)).toList();
    } catch (e) {
      debugPrint('[assistant] 매크로 목록 조회 실패: $e');
      return [];
    }
  }

  // 전체 매크로 목록 (대시보드 관리용, enabled 무관)
  Future<List<MacroItem>> fetchAllMacros() async {
    try {
      final rows = await _client
          .from('macros')
          .select()
          .order('sort_order', ascending: true);
      return rows.map<MacroItem>((row) => MacroItem.fromRow(row)).toList();
    } catch (e) {
      debugPrint('[assistant] 매크로 전체 조회 실패: $e');
      return [];
    }
  }

  // 매크로 생성
  Future<MacroItem?> createMacro(Map<String, dynamic> data) async {
    try {
      final row = await _client.from('macros').insert(data).select().single();
      return MacroItem.fromRow(row);
    } catch (e) {
      debugPrint('[assistant] 매크로 생성 실패: $e');
      return null;
    }
  }

  // 매크로 수정
  Future<bool> updateMacro(String id, Map<String, dynamic> data) async {
    try {
      data['updated_at'] = DateTime.now().toIso8601String();
      await _client.from('macros').update(data).eq('id', id);
      return true;
    } catch (e) {
      debugPrint('[assistant] 매크로 수정 실패: $e');
      return false;
    }
  }

  // 매크로 삭제
  Future<bool> deleteMacro(String id) async {
    try {
      await _client.from('macros').delete().eq('id', id);
      return true;
    } catch (e) {
      debugPrint('[assistant] 매크로 삭제 실패: $e');
      return false;
    }
  }

  // Supabase에서 활성화된 플레이북 목록 조회 (sort_order 정렬)
  Future<List<PlaybookItem>> fetchPlaybooks() async {
    try {
      final rows = await _client
          .from('playbooks')
          .select()
          .eq('enabled', true)
          .order('sort_order', ascending: true);

      return rows.map<PlaybookItem>((row) => PlaybookItem.fromRow(row)).toList();
    } catch (e) {
      debugPrint('[assistant] 플레이북 목록 조회 실패: $e');
      return [];
    }
  }

  // 전체 플레이북 목록 (대시보드 관리용)
  Future<List<PlaybookItem>> fetchAllPlaybooks() async {
    try {
      final rows = await _client
          .from('playbooks')
          .select()
          .order('sort_order', ascending: true);
      return rows.map<PlaybookItem>((row) => PlaybookItem.fromRow(row)).toList();
    } catch (e) {
      debugPrint('[assistant] 플레이북 전체 조회 실패: $e');
      return [];
    }
  }

  // 플레이북 생성
  Future<PlaybookItem?> createPlaybook(Map<String, dynamic> data) async {
    try {
      final row = await _client.from('playbooks').insert(data).select().single();
      return PlaybookItem.fromRow(row);
    } catch (e) {
      debugPrint('[assistant] 플레이북 생성 실패: $e');
      return null;
    }
  }

  // 플레이북 수정
  Future<bool> updatePlaybook(String id, Map<String, dynamic> data) async {
    try {
      data['updated_at'] = DateTime.now().toIso8601String();
      await _client.from('playbooks').update(data).eq('id', id);
      return true;
    } catch (e) {
      debugPrint('[assistant] 플레이북 수정 실패: $e');
      return false;
    }
  }

  // 플레이북 삭제
  Future<bool> deletePlaybook(String id) async {
    try {
      await _client.from('playbooks').delete().eq('id', id);
      return true;
    } catch (e) {
      debugPrint('[assistant] 플레이북 삭제 실패: $e');
      return false;
    }
  }
}

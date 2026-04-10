import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:supabase_flutter/supabase_flutter.dart';

class SearchResult {
  final String content;
  final double similarity;

  const SearchResult({required this.content, required this.similarity});
}

class AssistantResponse {
  final String answer;
  final List<SearchResult> sources;

  const AssistantResponse({required this.answer, required this.sources});
}

class AssistantService {
  final String serverUrl;

  AssistantService({required this.serverUrl});

  SupabaseClient get _client => Supabase.instance.client;

  Future<List<SearchResult>> searchDocuments(String query) async {
    try {
      final rows = await _client
          .from('document_chunks')
          .select('content, metadata')
          .ilike('content', '%$query%')
          .limit(5);

      return rows.map<SearchResult>((row) {
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

  Future<AssistantResponse> askAssistant(
    String query, {
    String? context,
  }) async {
    final sources = await searchDocuments(query);

    try {
      final contextText = sources.isNotEmpty
          ? sources.map((s) => s.content).join('\n\n')
          : context ?? '';

      final uri = Uri.parse('$serverUrl/api/assistant');
      final response = await http
          .post(
            uri,
            headers: {'Content-Type': 'application/json'},
            body: jsonEncode({'query': query, 'context': contextText}),
          )
          .timeout(const Duration(seconds: 30));

      if (response.statusCode == 200) {
        final data = jsonDecode(response.body) as Map<String, dynamic>;
        return AssistantResponse(
          answer: data['answer']?.toString() ?? '응답을 받지 못했습니다.',
          sources: sources,
        );
      }
    } catch (e) {
      debugPrint('[assistant] LLM API 호출 실패: $e');
    }

    if (sources.isNotEmpty) {
      return AssistantResponse(
        answer: sources.map((s) => s.content).join('\n\n'),
        sources: sources,
      );
    }

    return const AssistantResponse(
      answer: '관련 문서를 찾지 못했습니다.',
      sources: [],
    );
  }
}

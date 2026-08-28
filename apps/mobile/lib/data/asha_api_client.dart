import 'dart:convert';
import 'dart:io';

import 'package:fingerspeak_mobile/models/asha_message.dart';
import 'package:http/http.dart' as http;

class AshaUnavailableException implements Exception {
  const AshaUnavailableException(this.message);

  final String message;

  @override
  String toString() => message;
}

class AshaApiClient {
  AshaApiClient({
    required Uri baseUri,
    http.Client? client,
    this.bearerTokenProvider,
    this.geminiApiKeyProvider,
    this.geminiModel = 'gemini-2.0-flash',
  })  : _baseUri = baseUri,
        _client = client ?? http.Client();

  final Uri _baseUri;
  final http.Client _client;
  final Future<String?> Function()? bearerTokenProvider;
  final Future<String?> Function()? geminiApiKeyProvider;
  final String geminiModel;

  Future<AshaReply> chat({
    required String message,
    required String locale,
    String? previousResponseId,
    String? preferredName,
    String careMode = 'continuous',
  }) async {
    // 1. If a direct Gemini API key is configured, use Gemini Generative Language API
    final geminiKey = await geminiApiKeyProvider?.call();
    if (geminiKey != null && geminiKey.trim().isNotEmpty) {
      try {
        return await _chatWithGemini(
          apiKey: geminiKey.trim(),
          message: message,
          locale: locale,
          preferredName: preferredName,
          careMode: careMode,
        );
      } catch (e) {
        // If direct Gemini fails or encounters network issues, proceed to backend attempt
      }
    }

    // 2. Standard backend chat endpoint
    final token = await bearerTokenProvider?.call();
    final headers = <String, String>{
      HttpHeaders.acceptHeader: 'application/json',
      HttpHeaders.contentTypeHeader: 'application/json',
      if (token != null && token.isNotEmpty)
        HttpHeaders.authorizationHeader: 'Bearer $token',
    };
    final body = <String, Object?>{
      'message': message.trim(),
      'locale': locale,
      if (previousResponseId != null)
        'previous_response_id': previousResponseId,
      'patient_context': <String, Object?>{
        if (preferredName != null && preferredName.trim().isNotEmpty)
          'preferred_name': preferredName.trim(),
        'care_mode': careMode,
        'current_activity': 'Using the FingerSpeak patient app',
        'trusted_contact_available': true,
      },
    };

    try {
      final normalizedBase = _baseUri.path.endsWith('/')
          ? _baseUri
          : _baseUri.replace(path: '${_baseUri.path}/');
      final response = await _client
          .post(
            normalizedBase.resolve('asha/chat'),
            headers: headers,
            body: jsonEncode(body),
          )
          .timeout(const Duration(seconds: 20));
      if (response.statusCode < 200 || response.statusCode >= 300) {
        throw AshaUnavailableException(
          'Asha backend returned ${response.statusCode}.',
        );
      }
      final payload = jsonDecode(response.body) as Map<String, Object?>;
      return AshaReply(
        text: payload['reply']! as String,
        mode: payload['mode']! as String,
        urgent: payload['urgent']! as bool,
        previousResponseId: payload['previous_response_id'] as String?,
      );
    } on AshaUnavailableException {
      rethrow;
    } on Object catch (error) {
      throw AshaUnavailableException('Asha backend is unreachable: $error');
    }
  }

  Future<AshaReply> _chatWithGemini({
    required String apiKey,
    required String message,
    required String locale,
    String? preferredName,
    String careMode = 'continuous',
  }) async {
    final url = Uri.parse(
      'https://generativelanguage.googleapis.com/v1beta/models/$geminiModel:generateContent?key=$apiKey',
    );

    final systemInstruction =
        'You are Asha, a calm, compassionate, and supportive assistive communication companion. '
        'Keep replies concise (1-2 short sentences), reassuring, and natural when spoken aloud. '
        'The patient controls every action. Do not diagnose or prescribe. If immediate medical danger '
        'is described, advise using the app\'s confirmed caregiver or emergency pathway. '
        'Reply in the requested locale ($locale) when appropriate.';

    final userPrompt = [
      if (preferredName != null && preferredName.isNotEmpty) 'Patient name: $preferredName',
      'Care mode: $careMode',
      'Message: $message',
    ].join('\n');

    final payload = {
      'system_instruction': {
        'parts': [
          {'text': systemInstruction}
        ]
      },
      'contents': [
        {
          'role': 'user',
          'parts': [
            {'text': userPrompt}
          ]
        }
      ],
      'generationConfig': {
        'temperature': 0.7,
        'maxOutputTokens': 250,
      }
    };

    final response = await _client
        .post(
          url,
          headers: {HttpHeaders.contentTypeHeader: 'application/json'},
          body: jsonEncode(payload),
        )
        .timeout(const Duration(seconds: 15));

    if (response.statusCode < 200 || response.statusCode >= 300) {
      throw AshaUnavailableException(
        'Gemini API returned ${response.statusCode}: ${response.body}',
      );
    }

    final data = jsonDecode(response.body) as Map<String, dynamic>;
    final candidates = data['candidates'] as List<dynamic>?;
    if (candidates == null || candidates.isEmpty) {
      throw const AshaUnavailableException('Gemini returned empty candidate list');
    }

    final content = candidates.first['content'] as Map<String, dynamic>?;
    final parts = content?['parts'] as List<dynamic>?;
    final text = parts?.first?['text'] as String?;

    if (text == null || text.trim().isEmpty) {
      throw const AshaUnavailableException('Gemini response text is empty');
    }

    return AshaReply(
      text: text.trim(),
      mode: 'gemini-free-api',
      urgent: false,
    );
  }

  void close() => _client.close();
}

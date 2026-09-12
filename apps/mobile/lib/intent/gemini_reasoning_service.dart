// gemini_reasoning_service.dart
// Optional Phase 4 reasoning layer. Receives only the structured event payload
// from IntentPipeline.eventPayload (never frames, landmarks or features) and
// always has a deterministic offline fallback, so it is never on the execution
// path of a command or alert.

import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as http;

const _kForbiddenKeys = {'frame', 'frames', 'image', 'images', 'landmarks', 'features', 'sequence', 'pixels'};

const _kSystemPrompt =
    'You are Asha, a calm caregiver assistant for a paralysed patient. You receive only '
    'structured events produced by an on-device intent recognition system. You never see '
    'video. Do not diagnose. Summarise what happened, say what the patient most likely '
    'needs, and suggest one concrete caregiver action. Keep answers under 80 words.';

class ReasoningResult {
  const ReasoningResult(this.text, {required this.usedGemini});
  final String text;
  final bool usedGemini;
}

String offlineSummary(String task, Map<String, Object?> payload) {
  final state = (payload['patient_state'] as String?) ?? 'idle';
  final gesture = payload['gesture'] as String?;
  final confidence = payload['confidence'];
  final history = (payload['patient_history'] as String?) ?? '';
  final conf = confidence is num ? ' (confidence ${(confidence * 100).round()}%)' : '';
  String pretty(String? v) => (v ?? 'unknown').replaceAll('_', ' ');
  if (task == 'long_term_patterns') {
    final events = (payload['recent_events'] as List?) ?? const [];
    var executed = 0;
    var alerts = 0;
    for (final e in events) {
      final decision = ((e as Map)['verdict'] as Map?)?['decision'];
      if (decision == 'execute') executed++;
      if (decision == 'alert') alerts++;
    }
    return 'In the last ${events.length} decisions the patient completed $executed commands and '
            '$alerts abnormal-movement alerts were raised. $history'
        .trim();
  }
  if (state.startsWith('possible_abnormal') || state.startsWith('possible_seizure') || state.startsWith('possible_spasm')) {
    return 'Possible involuntary movement was detected. Commands are paused. Please check on the patient now.';
  }
  if (state == 'awaiting_confirmation') {
    return "The patient may have signalled '${pretty(gesture)}'$conf. Asha is asking them to confirm.";
  }
  if (state.startsWith('command_')) {
    return "The patient signalled '${pretty(gesture)}'$conf. $history".trim();
  }
  if (state.contains('help')) {
    return "The patient appears to be asking for help via '${pretty(gesture)}'$conf. Please respond now. $history".trim();
  }
  if (gesture != null && state != 'idle') {
    return "The patient signalled '${pretty(gesture)}'$conf (${pretty(state)}). $history".trim();
  }
  return 'No new patient request. Monitoring continues offline.';
}

Set<String> _allKeys(Object? value) {
  final keys = <String>{};
  if (value is Map) {
    for (final e in value.entries) {
      keys.add(e.key.toString().toLowerCase());
      keys.addAll(_allKeys(e.value));
    }
  } else if (value is List) {
    for (final item in value) {
      keys.addAll(_allKeys(item));
    }
  }
  return keys;
}

class GeminiReasoningService {
  GeminiReasoningService({
    required this.apiKeyProvider,
    this.model = 'gemini-2.5-flash',
    this.timeout = const Duration(seconds: 12),
    http.Client? client,
  }) : _client = client ?? http.Client();

  final Future<String?> Function() apiKeyProvider;
  final String model;
  final Duration timeout;
  final http.Client _client;
  String? lastError;

  Future<ReasoningResult> reason(
    String task,
    Map<String, Object?> payload, {
    String? caregiverQuestion,
  }) async {
    final bad = _allKeys(payload).intersection(_kForbiddenKeys);
    if (bad.isNotEmpty) {
      throw ArgumentError('raw sensor data must not be sent to the reasoning layer: $bad');
    }
    final key = (await apiKeyProvider())?.trim();
    if (key == null || key.isEmpty) {
      return ReasoningResult(offlineSummary(task, payload), usedGemini: false);
    }
    try {
      final text = await _call(task, payload, key, caregiverQuestion).timeout(timeout);
      return ReasoningResult(text, usedGemini: true);
    } on Object catch (error) {
      lastError = '$error';
      return ReasoningResult(offlineSummary(task, payload), usedGemini: false);
    }
  }

  Future<String> _call(String task, Map<String, Object?> payload, String key, String? question) async {
    const instructions = {
      'summarize': 'Summarise the latest patient event for the care log.',
      'caregiver_message': 'Write a short message to the caregiver about what the patient needs.',
      'patient_reply': 'Write a gentle one-sentence reply to say to the patient.',
      'long_term_patterns': 'Describe patterns over the recent events and anything the care team should review.',
    };
    final parts = <Map<String, String>>[
      {'text': instructions[task] ?? 'Summarise the event.'},
      {'text': 'Structured event JSON:\n${const JsonEncoder.withIndent('  ').convert(payload)}'},
      if (question != null && question.isNotEmpty) {'text': 'Caregiver question: $question'},
    ];
    final uri = Uri.parse('https://generativelanguage.googleapis.com/v1beta/models/$model:generateContent');
    final response = await _client.post(
      uri,
      headers: {'Content-Type': 'application/json', 'x-goog-api-key': key},
      body: jsonEncode({
        'system_instruction': {
          'parts': [
            {'text': _kSystemPrompt}
          ]
        },
        'contents': [
          {'role': 'user', 'parts': parts}
        ],
        'generationConfig': {'temperature': 0.3, 'maxOutputTokens': 256},
      }),
    );
    if (response.statusCode < 200 || response.statusCode >= 300) {
      throw http.ClientException('Gemini HTTP ${response.statusCode}');
    }
    final decoded = jsonDecode(response.body) as Map<String, dynamic>;
    final candidates = (decoded['candidates'] as List?) ?? const [];
    if (candidates.isEmpty) throw const FormatException('Gemini returned no candidates');
    final content = (candidates.first as Map)['content'] as Map?;
    final textParts = ((content?['parts'] as List?) ?? const [])
        .map((p) => ((p as Map)['text'] as String?) ?? '')
        .join(' ')
        .trim();
    if (textParts.isEmpty) throw const FormatException('Gemini returned an empty answer');
    return textParts;
  }

  void dispose() => _client.close();
}

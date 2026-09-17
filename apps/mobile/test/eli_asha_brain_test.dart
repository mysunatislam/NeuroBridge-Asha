import 'dart:convert';

import 'package:fingerspeak_mobile/data/asha_api_client.dart';
import 'package:fingerspeak_mobile/data/asha_offline_agent.dart';
import 'package:fingerspeak_mobile/models/asha_message.dart';
import 'package:fingerspeak_mobile/models/user_role.dart';
import 'package:fingerspeak_mobile/services/companion_controller.dart';
import 'package:fingerspeak_mobile/services/voice_service.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

class MockVoiceService implements PatientVoiceService {
  final List<String> spokenTexts = [];

  @override
  Future<void> speakAsha(String text, {bool force = false}) async {
    spokenTexts.add(text);
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

void main() {
  group('Eli-Asha Cognitive Brain & Empathetic Gesture Core', () {
    test('AshaOfflineAgent responds with empathy to somatic gesture triggers', () {
      final agent = AshaOfflineAgent();

      // Test affirmative gesture
      final replyYes = agent.process(
        message: 'Yes',
        locale: 'en-US',
        role: UserRole.patient,
        gestureModality: 'hand_gesture',
        physicalEffortObserved: true,
      );
      expect(replyYes.text, contains('Understood clearly'));
      expect(replyYes.text, contains('Take your time'));

      // Test negative gesture
      final replyNo = agent.process(
        message: 'No',
        locale: 'en-US',
        role: UserRole.patient,
        gestureModality: 'eye_blink',
        physicalEffortObserved: true,
      );
      expect(replyNo.text, contains('I hear you'));
      expect(replyNo.text, contains('Rest comfortably'));

      // Test generic somatic micro-gesture
      final replyGesture = agent.process(
        message: 'Check screen',
        locale: 'en-US',
        role: UserRole.patient,
        gestureModality: 'brow_twitch',
        physicalEffortObserved: true,
      );
      expect(replyGesture.text, contains('wheelchair companion screen'));
    });

    test('AshaApiClient Gemini payload builds alternating multi-turn history with 1200 token budget', () async {
      late Map<String, dynamic> capturedPayload;

      final mockClient = MockClient((request) async {
        if (request.url.path.contains('generateContent')) {
          capturedPayload = jsonDecode(request.body) as Map<String, dynamic>;
          return http.Response(
            jsonEncode({
              'candidates': [
                {
                  'content': {
                    'parts': [
                      {
                        'text':
                            'Spasticity occurs after a stroke because damage to the corticospinal tract '
                            'removes inhibitory control over spinal reflex arcs (WHY). '
                            'Here are three gentle range-of-motion stretches to relieve tension (HOW).'
                      }
                    ]
                  }
                }
              ]
            }),
            200,
          );
        }
        return http.Response('Not Found', 404);
      });

      final apiClient = AshaApiClient(
        baseUri: Uri.parse('http://localhost:8000'),
        client: mockClient,
        aiProviderProvider: () async => 'gemini',
        geminiApiKeyProvider: () async => 'test-gemini-key',
      );

      final history = [
        AshaMessage(
          role: AshaMessageRole.asha,
          text: 'Asha is here. If you need anything, I am listening.',
          sentAt: DateTime.now().subtract(const Duration(minutes: 5)),
        ),
        AshaMessage(
          role: AshaMessageRole.patient,
          text: 'Why does my right arm feel stiff after the stroke?',
          sentAt: DateTime.now().subtract(const Duration(minutes: 4)),
        ),
        AshaMessage(
          role: AshaMessageRole.asha,
          text: 'This stiffness is called spasticity resulting from upper motor neuron changes.',
          sentAt: DateTime.now().subtract(const Duration(minutes: 3)),
        ),
      ];

      final reply = await apiClient.chat(
        message: 'What exercises can I do right now for it?',
        locale: 'en-US',
        history: history,
        preferredName: 'Rahim',
        gestureModality: 'hand_gesture',
        gestureConfidence: 0.94,
        physicalEffortObserved: true,
      );

      expect(reply.isOnline, isTrue);
      expect(reply.text, contains('Spasticity occurs'));

      // Verify Gemini payload structure
      expect(capturedPayload.containsKey('system_instruction'), isTrue);
      final systemText = ((capturedPayload['system_instruction']
              as Map<String, dynamic>)['parts'] as List)[0]['text'] as String;

      // Verify Eli Cognitive Architecture (WHAT, WHY, HOW) in system prompt
      expect(systemText, contains('WHAT, WHY, HOW'));
      expect(systemText, contains('EMPATHETIC GESTURE & SOMATIC INTERACTION'));
      expect(systemText, contains('SOMATIC EFFORT DETECTED'));

      // Verify generationConfig has 1200 maxOutputTokens (not 250)
      final genConfig = capturedPayload['generationConfig'] as Map<String, dynamic>;
      expect(genConfig['maxOutputTokens'], 1200);

      // Verify contents start with 'user' and alternates
      final contents = capturedPayload['contents'] as List;
      expect(contents.isNotEmpty, isTrue);
      expect(contents.first['role'], 'user');
      expect(contents.last['role'], 'user');
    });

    test('CompanionController records gesture modality and notifies with empathy', () async {
      final mockVoice = MockVoiceService();
      final agent = AshaOfflineAgent();

      final mockClient = MockClient((request) async => http.Response('Error', 500));

      final apiClient = AshaApiClient(
        baseUri: Uri.parse('http://localhost:8000'),
        client: mockClient,
        aiProviderProvider: () async => 'offline',
        offlineAgent: agent,
      );

      final controller = CompanionController(
        api: apiClient,
        voice: mockVoice,
        locale: 'en-US',
        offlineAgent: agent,
      );

      await controller.notifyGestureFired(
        'Water',
        modality: 'hand_gesture',
        confidence: 0.95,
        preferredName: 'Rahim',
      );

      expect(controller.messages.length, 2);
      final patientMsg = controller.messages[0];
      final ashaMsg = controller.messages[1];

      expect(patientMsg.role, AshaMessageRole.patient);
      expect(patientMsg.text, 'Water');
      expect(patientMsg.gestureModality, 'hand_gesture');
      expect(patientMsg.physicalEffortObserved, isTrue);

      expect(ashaMsg.role, AshaMessageRole.asha);
      expect(ashaMsg.gestureModality, 'hand_gesture');
      expect(ashaMsg.physicalEffortObserved, isTrue);
      expect(ashaMsg.text.toLowerCase(), contains('water'));
    });
  });
}

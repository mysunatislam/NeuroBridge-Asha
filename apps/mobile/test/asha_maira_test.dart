import 'dart:convert';
import 'package:fingerspeak_mobile/data/asha_api_client.dart';
import 'package:fingerspeak_mobile/models/asha_message.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

void main() {
  group('AshaApiClient - Maira AI Integration', () {
    test('successfully queries Maira AI and parses reply with references', () async {
      final mockClient = MockClient((request) async {
        expect(request.url.toString(), 'https://api.recommender.gigalogy.com/v1/maira/ask');
        expect(request.headers['project-key'], AshaApiClient.defaultMairaProjectKey);
        expect(request.headers['api-key'], AshaApiClient.defaultMairaApiKey);
        expect(request.headers['content-type'], 'application/json');

        final body = jsonDecode(request.body) as Map<String, dynamic>;
        expect(body['query'], 'How do I cope with hand weakness in ALS?');
        expect(body['conversation_type'], 'chat');

        return http.Response(
          jsonEncode({
            'code': 200,
            'message': 'success',
            'detail': {
              'response': 'Conserve energy with assistive tools and take frequent rest intervals.',
              'session_id': 'sess-123',
              'conversation_id': 'conv-456',
              'references': [
                {
                  'section_id': 'als-hand-care',
                  'similarity_score': '94.5',
                  'content': 'Occupational therapy hand splints reduce tendon strain in ALS.',
                }
              ]
            }
          }),
          200,
          headers: {'content-type': 'application/json'},
        );
      });

      final client = AshaApiClient(
        baseUri: Uri.parse('http://localhost:8000/v1'),
        client: mockClient,
        aiProviderProvider: () async => 'maira',
      );

      final reply = await client.chat(
        message: 'How do I cope with hand weakness in ALS?',
        locale: 'en-US',
      );

      expect(reply.mode, 'maira-specialist');
      expect(reply.isOnline, isTrue);
      expect(reply.isAgentMode, isTrue);
      expect(reply.text, contains('Conserve energy'));
      expect(reply.citations.length, 1);
      expect(reply.citations.first.title, contains('94.5%'));
      expect(reply.citations.first.sourceId, 'als-hand-care');
    });

    test('seamlessly falls back to Offline RAG when Maira returns HTTP 500', () async {
      final mockClient = MockClient((request) async {
        return http.Response('Internal Server Error', 500);
      });

      final client = AshaApiClient(
        baseUri: Uri.parse('http://localhost:8000/v1'),
        client: mockClient,
        aiProviderProvider: () async => 'maira',
      );

      final reply = await client.chat(
        message: 'I need water please',
        locale: 'en-US',
      );

      // Gracefully falls back to offline agent with clinical safety protocol
      expect(reply.mode, contains('offline'));
      expect(reply.text.isNotEmpty, isTrue);
      expect(reply.verification?.safetyPassed, isTrue);
    });

    test('testConnection returns success on 200 response from Maira', () async {
      final mockClient = MockClient((request) async {
        return http.Response(
          jsonEncode({
            'code': 200,
            'detail': {'response': 'pong'}
          }),
          200,
        );
      });

      final client = AshaApiClient(
        baseUri: Uri.parse('http://localhost:8000/v1'),
        client: mockClient,
        aiProviderProvider: () async => 'maira',
      );

      final result = await client.testConnection();
      expect(result['success'], isTrue);
      expect(result['provider'], 'maira');
      expect(result['model'], contains('Maira'));
    });
  });
}

import 'package:fingerspeak_mobile/data/asha_local_knowledge.dart';
import 'package:fingerspeak_mobile/data/asha_offline_agent.dart';
import 'package:fingerspeak_mobile/models/user_role.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('AshaLocalKnowledgeRetriever', () {
    late AshaLocalKnowledgeRetriever retriever;

    setUp(() {
      retriever = AshaLocalKnowledgeRetriever();
    });

    test('retrieves ALS/MND fatigue protocol for ALS query', () {
      final results = retriever.retrieve('What is the guidance for fatigue and dwell time in ALS?');
      expect(results, isNotEmpty);
      expect(results.first.documentId, 'als-mnd-01');
      expect(results.first.category, AshaKnowledgeCategory.alsMnd);
      expect(results.first.snippet.toLowerCase(), anyOf(contains('fatigue'), contains('motor neuron'), contains('als')));
    });

    test('retrieves seizure first aid protocol for convulsion query', () {
      final results = retriever.retrieve('My patient is shaking and having a convulsion');
      expect(results, isNotEmpty);
      expect(results.first.documentId, 'seizure-triage-01');
      expect(results.first.category, AshaKnowledgeCategory.seizureFirstAid);
    });

    test('retrieves autonomic dysreflexia protocol for SCI hypertension', () {
      final results = retriever.retrieve('Severe pounding headache and sudden high blood pressure');
      expect(results, isNotEmpty);
      expect(results.first.documentId, 'sci-dysreflexia-01');
      expect(results.first.snippet.toLowerCase(), anyOf(contains('headache'), contains('blood pressure'), contains('dysreflexia')));
    });

    test('retrieves dysphagia hydration protocol for swallowing and water', () {
      final results = retriever.retrieve('How to safely drink water without choking and aspiration?');
      expect(results, isNotEmpty);
      expect(results.first.documentId, 'care-dysphagia-01');
      expect(results.first.category, AshaKnowledgeCategory.careRoutine);
    });

    test('supports Bengali synonym query expansion for জল (water)', () {
      final results = retriever.retrieve('জল খেতে চাই');
      expect(results, isNotEmpty);
      final docIds = results.map((r) => r.documentId).toList();
      expect(docIds.contains('care-dysphagia-01') || docIds.contains('bilingual-bengali-01'), isTrue);
    });

    test('returns empty for unrelated noise query', () {
      final results = retriever.retrieve('xyz abc 123456');
      expect(results, isEmpty);
    });
  });

  group('AshaOfflineAgent', () {
    late AshaOfflineAgent agent;

    setUp(() {
      agent = AshaOfflineAgent();
    });

    test('decomposes water request into routine action and safe drinking reminder', () {
      final reply = agent.process(
        message: 'I am thirsty and need water',
        locale: 'en-US',
        preferredName: 'Rahim',
        role: UserRole.patient,
      );

      expect(reply.mode, 'offline-rag-agent');
      expect(reply.urgent, isFalse);
      expect(reply.text, contains('Rahim'));
      expect(reply.text.toLowerCase(), anyOf(contains('water'), contains('swallowing'), contains('hydration')));
      expect(reply.actionsExecuted.any((a) => a.toolName == 'manage_care_routine'), isTrue);
      expect(reply.verification?.isVerified, isTrue);
      expect(reply.verification?.safetyPassed, isTrue);
      expect(reply.verification?.goalFulfilled, isTrue);
    });

    test('handles acute seizure with urgent flag and clinical citation', () {
      final reply = agent.process(
        message: 'Patient is having a violent seizure',
        locale: 'en-US',
        role: UserRole.caregiver,
      );

      expect(reply.mode, 'offline-rag-agent');
      expect(reply.urgent, isTrue);
      expect(reply.text, contains('SEIZURE FIRST AID'));
      expect(reply.text, contains('recovery position'));
      expect(reply.citations.any((c) => c.title.toLowerCase().contains('seizure')), isTrue);
      expect(reply.quickActions.any((q) => q.actionKey == 'call_ambulance'), isTrue);
      expect(reply.verification?.isVerified, isTrue);
    });

    test('handles autonomic dysreflexia symptoms with upright posture reminder', () {
      final reply = agent.process(
        message: 'Severe pounding headache and suspect autonomic dysreflexia',
        locale: 'en-US',
        role: UserRole.patient,
      );

      expect(reply.urgent, isTrue);
      expect(reply.text, contains('AUTONOMIC DYSREFLEXIA'));
      expect(reply.text.toLowerCase(), contains('upright'));
      expect(reply.actionsExecuted.any((a) => a.toolName == 'trigger_caregiver_alert'), isTrue);
    });

    test('handles wheelchair companion screen caption request', () {
      final reply = agent.process(
        message: 'Write "Please give me medicine" on my wheelchair screen display',
        locale: 'en-US',
        role: UserRole.patient,
      );

      expect(reply.actionsExecuted.any((a) => a.toolName == 'send_wheelchair_caption'), isTrue);
      expect(reply.text.toLowerCase(), anyOf(contains('screen'), contains('display')));
    });

    test('handles caregiver alert call request', () {
      final reply = agent.process(
        message: 'Please call my nurse right away',
        locale: 'en-US',
        role: UserRole.patient,
      );

      expect(reply.actionsExecuted.any((a) => a.toolName == 'trigger_caregiver_alert'), isTrue);
      expect(reply.text.toLowerCase(), anyOf(contains('notified your caregiver'), contains('help is on the way')));
    });
  });
}

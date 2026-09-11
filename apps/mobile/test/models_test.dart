import 'package:fingerspeak_mobile/core/app_config.dart';
import 'package:fingerspeak_mobile/data/asha_api_client.dart';
import 'package:fingerspeak_mobile/data/cloud_api_client.dart';
import 'package:fingerspeak_mobile/data/pi_device_client.dart';
import 'package:fingerspeak_mobile/models/care_routine_settings.dart';
import 'package:fingerspeak_mobile/models/patient_access_method.dart';
import 'package:fingerspeak_mobile/models/patient_signal.dart';
import 'package:fingerspeak_mobile/models/user_role.dart';
import 'package:fingerspeak_mobile/services/calibration_service.dart';
import 'package:fingerspeak_mobile/services/caregiver_notification_service.dart';
import 'package:fingerspeak_mobile/services/companion_controller.dart';
import 'package:fingerspeak_mobile/services/session_metrics_service.dart';
import 'package:fingerspeak_mobile/services/voice_service.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues({});
  });

  test(
      'calibrated phrase survives local JSON serialization with sensitivity and dwell',
      () {
    const phrase = CalibratedPhrase(
      signal: PatientSignalKind.eyeTremor,
      key: 'eyeTremor',
      phrase: 'I feel eye spasms',
      minimumConfidence: 0.81,
      dwell: Duration(milliseconds: 200),
      sensitivity: 0.85,
    );

    final restored = CalibratedPhrase.fromJson(phrase.toJson());

    expect(restored.signal, PatientSignalKind.eyeTremor);
    expect(restored.key, 'eyeTremor');
    expect(restored.phrase, 'I feel eye spasms');
    expect(restored.minimumConfidence, 0.81);
    expect(restored.dwell, const Duration(milliseconds: 200));
    expect(restored.sensitivity, 0.85);
  });

  test('user role repository persists patient and caregiver roles', () async {
    final prefs = await SharedPreferences.getInstance();
    final repo = UserRoleRepository(prefs);

    expect(repo.load(), isNull);

    await repo.save(UserRole.patient);
    expect(repo.load(), UserRole.patient);

    await repo.save(UserRole.caregiver);
    expect(repo.load(), UserRole.caregiver);

    await repo.clear();
    expect(repo.load(), isNull);
  });

  test('patient access method persists and can be changed or cleared',
      () async {
    final prefs = await SharedPreferences.getInstance();
    final repo = PatientAccessMethodRepository(prefs);

    expect(repo.load(), isNull);

    await repo.save(PatientAccessMethod.handGestures);
    expect(repo.load(), PatientAccessMethod.handGestures);

    await repo.save(PatientAccessMethod.faceEyesAndHead);
    expect(repo.load(), PatientAccessMethod.faceEyesAndHead);

    await repo.clear();
    expect(repo.load(), isNull);
  });

  test('caregiver notification service records alerts and emits events',
      () async {
    final prefs = await SharedPreferences.getInstance();
    final service = CaregiverNotificationService(prefs);
    await service.initialize();

    CaregiverAlert? emitted;
    final sub = service.alerts.listen((a) => emitted = a);

    await service.notifyPatientSpoken('I would like water',
        signalKind: PatientSignalKind.mouthOpen);

    expect(emitted, isNotNull);
    expect(emitted?.title, 'Patient Spoke');
    expect(emitted?.message, 'I would like water');
    expect(emitted?.signalKind, PatientSignalKind.mouthOpen);
    expect(service.recentAlerts.length, 1);

    await service.notifyEmergency('Seizure Alert', 'Tremor detected',
        signalKind: PatientSignalKind.seizureAlert);
    expect(service.recentAlerts.length, 2);
    expect(service.recentAlerts.first.urgency, AlertUrgency.emergency);

    await sub.cancel();
    await service.dispose();
  });

  test('saved caregiver audio only matches its exact phrase snapshot', () {
    const recording = SavedPhraseRecording(
      path: 'private/caregiver-blink.m4a',
      phraseSnapshot: 'I need some water',
    );

    expect(recording.matches('I need some water'), isTrue);
    expect(recording.matches('  I need some water  '), isTrue);
    expect(recording.matches('I need help'), isFalse);
    expect(recording.matches('I need some water.'), isFalse);
  });

  test('configuration validates API and Pi transports with emergency phones',
      () {
    const config = AppConfig(
      apiBaseUrl: 'https://api.example.test/v1',
      piWebSocketUrl: 'wss://pi.example.test/v1/device/ws',
      piDeviceId: 'fingerspeak-pi',
      locale: 'en-US',
      caregiverPhone: '+8801000000000',
      patientPhone: '+8801000000001',
      doctorPhone: '+8801000000002',
      ambulancePhone: '911',
    );

    expect(config.apiUri.scheme, 'https');
    expect(config.piUri.scheme, 'wss');
    expect(config.doctorPhone, '+8801000000002');
    expect(config.ambulancePhone, '911');
  });

  test('configuration rejects a non-WebSocket Pi URL', () {
    const config = AppConfig(
      apiBaseUrl: 'https://api.example.test/v1',
      piWebSocketUrl: 'https://pi.example.test/v1/device/ws',
      piDeviceId: 'fingerspeak-pi',
      locale: 'en-US',
      caregiverPhone: '',
      patientPhone: '',
    );

    expect(() => config.piUri, throwsFormatException);
  });

  test('Asha client preserves the /v1 backend prefix', () async {
    final client = AshaApiClient(
      baseUri: Uri.parse('https://api.example.test/v1'),
      client: MockClient((request) async {
        expect(request.url.path, '/v1/asha/chat');
        return http.Response(
          '{"reply":"I am here.","mode":"llm","urgent":false,'
          '"previous_response_id":null,"citations":[]}',
          200,
          headers: const {'content-type': 'application/json'},
        );
      }),
    );

    final reply = await client.chat(message: 'Hello', locale: 'en-US');

    expect(reply.text, 'I am here.');
    expect(reply.isOnline, isTrue);
    client.close();
  });

  test(
      'companion controller handles acute seizure protocol in offline fallback',
      () async {
    final client = AshaApiClient(
      baseUri: Uri.parse('https://api.unreachable.test/v1'),
      client: MockClient(
          (_) async => throw const AshaUnavailableException('offline')),
    );
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool('voice.auto_speak', false);
    final voice = PatientVoiceService(
      preferenceRepository: VoicePreferenceRepository(prefs),
      recordings: RecordedPhraseRepository(prefs),
    );
    final companion = CompanionController(
      api: client,
      voice: voice,
      locale: 'en-US',
    );

    await companion.send('Patient is having a seizure',
        role: UserRole.caregiver);

    expect(companion.messages.length, 2);
    expect(companion.messages.last.text, contains('SEIZURE FIRST AID:'));
    expect(
        companion.messages.last.text, contains('Do NOT restrain the patient'));
    companion.dispose();
  });

  test('Pi messages follow the versioned edge envelope', () {
    final envelope = PiMessageFactory.envelope(
      deviceId: 'fingerspeak-pi',
      sequence: 7,
      type: 'caption.set',
      payload: const {'text': 'I need water', 'language': 'en-US'},
      messageId: 'a90552bb-96c0-42e8-90fb-96db24092c60',
      sentAt: DateTime.utc(2026, 8, 22, 12),
    );

    expect(envelope['version'], 1);
    expect(envelope['device_id'], 'fingerspeak-pi');
    expect(envelope['sequence'], 7);
    expect(envelope['type'], 'caption.set');
    expect(envelope['sent_at'], '2026-08-22T12:00:00.000Z');
  });

  test('authenticated Pi intent maps expanded signal types', () {
    final now = DateTime.utc(2026, 8, 22, 12);
    final parser = PatientIntentEnvelopeParser(
      deviceId: 'fingerspeak-pi',
      now: () => now,
    );
    final envelope = _intentEnvelope(
      sequence: 1,
      messageId: '00000000-0000-4000-8000-000000000001',
      intent: 'lip_tremor',
      confidence: 0.93,
      detectedAt: now.subtract(const Duration(seconds: 1)),
      sentAt: now,
    );

    final signal = parser.tryParse(envelope, authenticated: true);

    expect(signal?.kind, PatientSignalKind.lipTremor);
    expect(signal?.confidence, 0.93);
    expect(
      signal?.sourceLabel,
      'pi.patient.intent:00000000-0000-4000-8000-000000000001',
    );
  });

  test('Pi intent parser rejects replay and enforces per-socket sequence', () {
    final now = DateTime.utc(2026, 8, 22, 12);
    final parser = PatientIntentEnvelopeParser(
      deviceId: 'fingerspeak-pi',
      now: () => now,
    );
    final first = _intentEnvelope(
      sequence: 1,
      messageId: '00000000-0000-4000-8000-000000000001',
      intent: 'blink',
      confidence: 0.8,
      detectedAt: now,
      sentAt: now,
    );
    expect(parser.tryParse(first, authenticated: true), isNotNull);

    final repeatedId = _intentEnvelope(
      sequence: 2,
      messageId: '00000000-0000-4000-8000-000000000001',
      intent: 'blink',
      confidence: 0.8,
      detectedAt: now,
      sentAt: now,
    );
    expect(parser.tryParse(repeatedId, authenticated: true), isNull);
    final repeatedSequence = _intentEnvelope(
      sequence: 1,
      messageId: '00000000-0000-4000-8000-000000000002',
      intent: 'blink',
      confidence: 0.8,
      detectedAt: now,
      sentAt: now,
    );
    expect(parser.tryParse(repeatedSequence, authenticated: true), isNull);
    final gap = _intentEnvelope(
      sequence: 4,
      messageId: '00000000-0000-4000-8000-000000000004',
      intent: 'mouth_open',
      confidence: 0.85,
      detectedAt: now,
      sentAt: now,
    );
    expect(parser.tryParse(gap, authenticated: true)?.kind,
        PatientSignalKind.mouthOpen);

    parser.reset();
    expect(parser.tryParse(first, authenticated: true), isNotNull);
  });

  test('Pi intent parser rejects stale, wrong-device, and extra data', () {
    final now = DateTime.utc(2026, 8, 22, 12);
    final parser = PatientIntentEnvelopeParser(
      deviceId: 'fingerspeak-pi',
      now: () => now,
    );
    final stale = _intentEnvelope(
      sequence: 1,
      messageId: '00000000-0000-4000-8000-000000000001',
      intent: 'eyebrows_up',
      confidence: 0.9,
      detectedAt: now.subtract(const Duration(seconds: 16)),
      sentAt: now,
    );
    expect(parser.tryParse(stale, authenticated: true), isNull);

    final wrongDevice = _intentEnvelope(
      sequence: 1,
      messageId: '00000000-0000-4000-8000-000000000002',
      intent: 'blink',
      confidence: 0.9,
      detectedAt: now,
      sentAt: now,
      deviceId: 'another-pi',
    );
    expect(parser.tryParse(wrongDevice, authenticated: true), isNull);

    final extraPayload = _intentEnvelope(
      sequence: 1,
      messageId: '00000000-0000-4000-8000-000000000003',
      intent: 'blink',
      confidence: 0.9,
      detectedAt: now,
      sentAt: now,
    );
    (extraPayload['payload']! as Map<String, Object?>)['phrase'] =
        'Untrusted words';
    expect(parser.tryParse(extraPayload, authenticated: true), isNull);

    final extraEnvelope = _intentEnvelope(
      sequence: 1,
      messageId: '00000000-0000-4000-8000-000000000004',
      intent: 'blink',
      confidence: 0.9,
      detectedAt: now,
      sentAt: now,
    )..['frame'] = 'not accepted';
    expect(parser.tryParse(extraEnvelope, authenticated: true), isNull);
  });

  test('emergency edge phrase needs two distinct events within ten seconds',
      () {
    var now = DateTime.utc(2026, 8, 22, 12);
    final gate = EdgeRiskConfirmationGate(now: () => now);
    const phrase = CalibratedPhrase(
      signal: PatientSignalKind.blink,
      key: 'emergency-blink',
      phrase: 'Emergency, call 999',
    );
    PatientSignal event(String id) => PatientSignal(
          kind: PatientSignalKind.blink,
          confidence: 0.95,
          observedAt: now,
          sourceLabel: id,
        );

    expect(gate.permits(phrase, event('event-1')), isFalse);
    expect(gate.permits(phrase, event('event-1')), isFalse);
    now = now.add(const Duration(seconds: 5));
    expect(gate.permits(phrase, event('event-2')), isTrue);

    expect(gate.permits(phrase, event('event-3')), isFalse);
    now = now.add(const Duration(seconds: 11));
    expect(gate.permits(phrase, event('event-4')), isFalse);
    gate.clear();
    expect(gate.permits(phrase, event('event-5')), isFalse);
  });

  test('VoicePreferences supports pitch, volume, and playback preference',
      () async {
    final prefs = await SharedPreferences.getInstance();
    final repo = VoicePreferenceRepository(prefs);

    final initial = repo.load();
    expect(initial.pitch, 1.00);
    expect(initial.speechRate, 0.50);
    expect(initial.ttsVoiceName, 'Samantha');
    expect(initial.volume, 1.0);
    expect(
        initial.playbackPreference, PlaybackPreference.caregiverRecordingFirst);

    final modified = initial.copyWith(
      pitch: 1.45,
      volume: 0.80,
      playbackPreference: PlaybackPreference.systemVoiceOnly,
    );
    await repo.save(modified);

    final restored = repo.load();
    expect(restored.pitch, 1.45);
    expect(restored.volume, 0.80);
    expect(restored.playbackPreference, PlaybackPreference.systemVoiceOnly);
  });

  test(
      'CareRoutineSettings serializes and deserializes hydration and check-ins',
      () {
    const settings = CareRoutineSettings(
      hydration: RoutineDefinition(
        enabled: true,
        intervalMinutes: 90,
        activeFrom: '09:00',
        activeUntil: '19:00',
      ),
      hydrationMessage: 'Take a sip of water.',
      checkIns: RoutineDefinition(
        enabled: true,
        intervalMinutes: 45,
        activeFrom: '09:00',
        activeUntil: '20:00',
      ),
      checkInMessages: ['Are you comfortable?', 'Asha is right here.'],
    );

    final jsonStr = settings.serialize();
    final restored = CareRoutineSettings.deserialize(jsonStr);

    expect(restored.hydration.enabled, isTrue);
    expect(restored.hydration.intervalMinutes, 90);
    expect(restored.hydration.activeFrom, '09:00');
    expect(restored.hydration.activeUntil, '19:00');
    expect(restored.hydrationMessage, 'Take a sip of water.');
    expect(restored.checkIns.enabled, isTrue);
    expect(restored.checkIns.intervalMinutes, 45);
    expect(restored.checkInMessages.length, 2);
    expect(restored.checkInMessages.first, 'Are you comfortable?');
  });

  test('SessionMetricsService records metrics and resets counters', () {
    final metrics = SessionMetricsService();
    expect(metrics.phrasesSpoken, 0);
    expect(metrics.falseActivations, 0);
    expect(metrics.missedGestures, 0);

    metrics.recordPhraseSpoken();
    metrics.recordPhraseSpoken();
    metrics.markFalseActivation();
    metrics.markMissedGesture();

    expect(metrics.phrasesSpoken, 2);
    expect(metrics.falseActivations, 1);
    expect(metrics.missedGestures, 1);

    metrics.reset();
    expect(metrics.phrasesSpoken, 0);
    expect(metrics.falseActivations, 0);
    expect(metrics.missedGestures, 0);
  });

  test('CalibratedPhraseRepository exports and imports valid profile JSON',
      () async {
    final prefs = await SharedPreferences.getInstance();
    final repo = CalibratedPhraseRepository(prefs);

    await repo.save(const CalibratedPhrase(
      signal: PatientSignalKind.smile,
      key: 'custom_smile',
      phrase: 'I am happy today',
      sensitivity: 0.90,
    ));

    final exportedJson =
        repo.exportProfileJson(profileName: 'Test Patient Profile');
    expect(exportedJson.contains('fingerspeak-v1'), isTrue);
    expect(exportedJson.contains('I am happy today'), isTrue);

    await repo.resetToDefaults();
    expect(repo.load().any((p) => p.key == 'custom_smile'), isFalse);

    final importedCount = await repo.importProfileJson(exportedJson);
    expect(importedCount, greaterThan(0));
    expect(repo.load().any((p) => p.phrase == 'I am happy today'), isTrue);
  });

  test('CloudAlert and RemoteDevice parse correctly from JSON', () {
    final alert = CloudAlert.fromJson({
      'id': 'alert-123',
      'profile_id': 'profile-abc',
      'session_id': 'sess-xyz',
      'source_event_id': 'evt-1',
      'severity': 'emergency',
      'message': 'Patient needs urgent suctioning',
      'status': 'pending',
      'created_at': '2026-08-22T12:00:00Z',
    });

    expect(alert.id, 'alert-123');
    expect(alert.severity, 'emergency');
    expect(alert.status, 'pending');

    final device = RemoteDevice.fromJson({
      'id': 'pi-device-01',
      'profile_id': 'profile-abc',
      'name': 'Wheelchair Pi 4',
      'enabled': true,
      'online': true,
      'last_state': {
        'sequence': 42,
        'observed_at': '2026-08-22T12:00:00Z',
        'last_seen_at': '2026-08-22T12:00:00Z',
        'pi_battery_percent': 85.0,
        'wheelchair_battery_percent': 92.0,
        'wheelchair_status': 'idle',
        'camera_status': 'active',
        'display_status': 'active',
        'transport': 'wifi',
      },
    });

    expect(device.id, 'pi-device-01');
    expect(device.online, isTrue);
    expect(device.lastState?.piBatteryPercent, 85.0);
    expect(device.lastState?.wheelchairBatteryPercent, 92.0);
  });
}

Map<String, Object?> _intentEnvelope({
  required int sequence,
  required String messageId,
  required String intent,
  required double confidence,
  required DateTime detectedAt,
  required DateTime sentAt,
  String deviceId = 'fingerspeak-pi',
}) {
  return PiMessageFactory.envelope(
    deviceId: deviceId,
    sequence: sequence,
    type: 'patient.intent',
    payload: <String, Object?>{
      'intent': intent,
      'confidence': confidence,
      'detected_at': detectedAt.toUtc().toIso8601String(),
    },
    messageId: messageId,
    sentAt: sentAt,
  );
}

import 'package:fingerspeak_mobile/data/pi_device_client.dart';
import 'package:fingerspeak_mobile/models/patient_signal.dart';
import 'package:fingerspeak_mobile/services/calibration_service.dart';
import 'package:fingerspeak_mobile/services/patient_signal_monitor.dart';
import 'package:fingerspeak_mobile/services/voice_service.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues({});
  });

  test('saving a new mapping replaces the old mapping for that signal',
      () async {
    final preferences = await SharedPreferences.getInstance();
    final repository = CalibratedPhraseRepository(preferences);

    await repository.save(const CalibratedPhrase(
      signal: PatientSignalKind.blink,
      key: 'patient_custom_blink',
      phrase: 'Please move my pillow',
      minimumConfidence: 0.70,
    ));

    final blinkMappings = repository
        .load()
        .where((phrase) => phrase.signal == PatientSignalKind.blink)
        .toList();
    expect(blinkMappings, hasLength(1));
    expect(blinkMappings.single.key, 'patient_custom_blink');
    expect(blinkMappings.single.phrase, 'Please move my pillow');
  });

  test('neutral face baseline survives repository recreation', () async {
    final preferences = await SharedPreferences.getInstance();
    final repository = NeutralFaceBaselineRepository(preferences);
    const baseline = NeutralFaceBaseline(
      eyebrowDistance: 0.112,
      mouthDistance: 0.031,
      leftEyeOpenness: 0.78,
      rightEyeOpenness: 0.81,
      smileProbability: 0.12,
      headYaw: -4.5,
      headPitch: 3.25,
    );

    await repository.save(baseline);
    final restored = NeutralFaceBaselineRepository(preferences).load();

    expect(restored, isNotNull);
    expect(restored!.eyebrowDistance, closeTo(0.112, 0.0001));
    expect(restored.mouthDistance, closeTo(0.031, 0.0001));
    expect(restored.leftEyeOpenness, closeTo(0.78, 0.0001));
    expect(restored.rightEyeOpenness, closeTo(0.81, 0.0001));
    expect(restored.smileProbability, closeTo(0.12, 0.0001));
    expect(restored.headYaw, closeTo(-4.5, 0.0001));
    expect(restored.headPitch, closeTo(3.25, 0.0001));
  });

  test('calibration suppresses speech and active duration satisfies dwell',
      () async {
    final preferences = await SharedPreferences.getInstance();
    final repository = CalibratedPhraseRepository(preferences);
    await repository.save(const CalibratedPhrase(
      signal: PatientSignalKind.blink,
      key: 'held_blink',
      phrase: 'I need help',
      minimumConfidence: 0.75,
      dwell: Duration(milliseconds: 500),
    ));
    final voice = PatientVoiceService(
      preferenceRepository: VoicePreferenceRepository(preferences),
      recordings: RecordedPhraseRepository(preferences),
    );
    final pi = PiDeviceClient(
      endpoint: Uri.parse('ws://127.0.0.1:8765/v1/device/ws'),
      deviceId: 'test-pi',
    );
    final controller = RecognitionTriggerController(
      repository: repository,
      voice: voice,
      pi: pi,
      locale: 'en-US',
    );
    addTearDown(() async {
      await controller.dispose();
      await voice.dispose();
      await pi.dispose();
    });

    final spoken = <CalibratedPhrase>[];
    final subscription = controller.spokenPhrases.listen(spoken.add);
    addTearDown(subscription.cancel);
    controller.beginCalibrationSession();
    await controller.ingest(PatientSignal(
      kind: PatientSignalKind.blink,
      confidence: 0.90,
      observedAt: DateTime.utc(2026, 8, 24, 12),
      metadata: const {'active_duration_ms': 650},
    ));
    expect(controller.isCalibrationSuppressed, isTrue);
    expect(spoken, isEmpty);

    controller.endCalibrationSession();
    await controller.ingest(PatientSignal(
      kind: PatientSignalKind.blink,
      confidence: 0.90,
      observedAt: DateTime.utc(2026, 8, 24, 12, 0, 3),
      metadata: const {'active_duration_ms': 650},
    ));
    await Future<void>.delayed(Duration.zero);
    expect(spoken.single.key, 'held_blink');
  });

  test('cooldown is independent for each signal kind', () {
    final gate = SignalCooldownGate();
    final now = DateTime.utc(2026, 8, 24, 12);
    const cooldown = Duration(milliseconds: 750);

    expect(gate.permits(PatientSignalKind.eyeLookLeft, now, cooldown), isTrue);
    expect(gate.permits(PatientSignalKind.headLeft, now, cooldown), isTrue);
    expect(
      gate.permits(
        PatientSignalKind.eyeLookLeft,
        now.add(const Duration(milliseconds: 100)),
        cooldown,
      ),
      isFalse,
    );
    expect(
      gate.permits(
        PatientSignalKind.eyeLookLeft,
        now.add(cooldown),
        cooldown,
      ),
      isTrue,
    );
  });
}

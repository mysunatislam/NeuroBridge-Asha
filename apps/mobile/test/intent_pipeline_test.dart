// On-device pipeline pieces that have no Python counterpart to compare with:
// observation resampling, the calibration session, the verification flow and
// the service wiring (verified commands become PatientSignals; abnormal
// movement never does).

import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;

import 'package:fingerspeak_mobile/intent/frame_builder.dart';
import 'package:fingerspeak_mobile/intent/intent_pipeline.dart';
import 'package:fingerspeak_mobile/intent/intent_recognition_service.dart';
import 'package:fingerspeak_mobile/intent/intent_runtimes.dart';
import 'package:fingerspeak_mobile/intent/intent_schema.dart';
import 'package:fingerspeak_mobile/intent/patient_calibration_service.dart';
import 'package:fingerspeak_mobile/intent/patient_profile.dart';
import 'package:fingerspeak_mobile/intent/verification_engine.dart';
import 'package:fingerspeak_mobile/intent/window_features.dart';
import 'package:fingerspeak_mobile/models/patient_signal.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

Future<IntentModelBundle> _bundleFromAssets() async {
  const dir = 'assets/models/intent_bundle_v1';
  final manifest = jsonDecode(File('$dir/manifest.json').readAsStringSync()) as Map<String, dynamic>;
  return IntentModelBundle.fromJson(
    manifest: manifest,
    loadFile: (name) async => jsonDecode(File('$dir/$name').readAsStringSync()) as Map<String, dynamic>,
  );
}

IntentObservation _observation(DateTime at, {double eyeOpen = 0.9, double mouth = 0.08, double yaw = 0}) =>
    IntentObservation(
      observedAt: at,
      faceDetected: true,
      leftEyeOpen: eyeOpen,
      rightEyeOpen: eyeOpen,
      mouthDistance: mouth,
      smileProbability: 0.05,
      eyebrowDistance: 0.18,
      headYaw: yaw,
      headPitch: 0,
      headRoll: 0,
      faceCenterX: 0.5,
      faceCenterY: 0.45,
      faceScale: 0.2,
      contourMotionEnergy: 0.002,
    );

/// Synthetic frames at 20 Hz: rest with a value generator per channel.
List<IntentFrame> _frames(double seconds, double Function(int index, double t) ear,
    {double Function(double t)? mouth, double Function(double t)? yaw, int seed = 1}) {
  final rng = math.Random(seed);
  final n = (seconds * kFrameRateHz).round();
  return List.generate(n, (i) {
    final t = i / kFrameRateHz;
    final v = List<double>.filled(kFrameFeatureCount, 0.0);
    final e = ear(i, t);
    v[F.earLeft] = e;
    v[F.earRight] = e;
    v[F.earMean] = e;
    v[F.mouthOpenRatio] = 0.08 + (mouth?.call(t) ?? 0) + rng.nextDouble() * 0.004;
    v[F.smileRatio] = 0.02;
    v[F.browRaise] = 0.42 + rng.nextDouble() * 0.004;
    v[F.headYaw] = (yaw?.call(t) ?? 0) + rng.nextDouble() * 0.3;
    v[F.headPitch] = rng.nextDouble() * 0.3;
    v[F.faceCx] = 0.5;
    v[F.faceCy] = 0.45;
    v[F.faceScale] = 0.18;
    v[F.elbowAngle] = 150;
    v[F.flowMagMean] = 0.02;
    v[F.flowMagStd] = 0.01;
    v[F.flowDirConsistency] = 0.2;
    return IntentFrame(t, v);
  });
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('frame builder resamples irregular observations onto the 20 Hz grid', () {
    final builder = IntentFrameBuilder();
    final start = DateTime(2026, 1, 1, 12);
    var frames = builder.add(_observation(start));
    expect(frames.length, 1);
    frames = builder.add(_observation(start.add(const Duration(milliseconds: 130)), mouth: 0.21));
    // 130 ms covers grid ticks at 50 and 100 ms.
    expect(frames.length, 2);
    expect(frames.first.tSeconds, closeTo(0.05, 1e-9));
    expect(frames.first.values[F.mouthOpenRatio], greaterThan(0.08));
    expect(frames.first.values[F.mouthOpenRatio], lessThan(0.21));
    expect(frames.first.values[F.earMean], closeTo(0.27, 1e-9));
    final lost = builder.add(IntentObservation(observedAt: start.add(const Duration(seconds: 1)), faceDetected: false));
    expect(lost, isEmpty);
  });

  test('calibration session builds a profile from five phases and rejects short ones', () {
    final session = PatientCalibrationSession(patientId: 'unit', phaseSeconds: 12);
    final rng = math.Random(3);
    double blinkEar(int i, double t) {
      // spontaneous blinks every ~3 s lasting 150 ms
      final phase = t % 3.1;
      return phase < 0.15 ? 0.05 : 0.30 + rng.nextDouble() * 0.01;
    }

    session.addFrame(CalibrationPhase.restState, _frames(1, blinkEar).first);
    expect(() => session.buildProfile(), throwsA(isA<CalibrationException>()));
    for (final phase in CalibrationPhase.all) {
      session.clearPhase(phase);
      final frames = phase == CalibrationPhase.intentionalGestures
          ? _frames(12, blinkEar, mouth: (t) => (t % 4) < 1.5 ? 0.25 : 0.0, yaw: (t) => (t % 6) > 4 ? 18 : 0)
          : phase == CalibrationPhase.randomMovement
              ? _frames(12, blinkEar, yaw: (t) => 8 * math.sin(2 * math.pi * 0.4 * t))
              : _frames(12, blinkEar);
      for (final frame in frames) {
        session.addFrame(phase, frame);
      }
    }
    expect(session.missingPhases, isEmpty);
    final profile = session.buildProfile();
    expect(profile.isCalibrated, isTrue);
    expect(profile.blink['rate_per_min'], greaterThan(10));
    expect(profile.blink['mean_duration_ms'], inInclusiveRange(100, 260));
    expect(profile.prototypes.keys, containsAll(CalibrationPhase.all));
    expect(profile.prototypeWeight, inInclusiveRange(0.2, 0.8));
    final json = profile.toJsonString();
    final restored = PatientProfile.parse(json);
    expect(restored.normalizerMean, profile.normalizerMean);
    expect(session.exportRecordingsJson(), contains('neurobridge-calibration-recording-v1'));
  });

  test('verification engine: execute, confirm-by-gesture, expire, abnormal veto', () {
    final engine = ConfidenceVerificationEngine(confirmationWindowSeconds: 5);
    IntentEvidence ev({
      String command = CommandClass.tripleBlink,
      double pCommand = 0.95,
      double pIntentional = 0.9,
      String intentLabel = IntentClass.intentional,
      double pPrototype = 0.7,
      double pAbnormal = 0.05,
      String abnormal = AbnormalClass.normalVoluntary,
      double t = 1,
    }) =>
        IntentEvidence(
          command: command,
          pCommand: pCommand,
          pIntentional: pIntentional,
          intentLabel: intentLabel,
          pPrototype: pPrototype,
          pAbnormal: pAbnormal,
          abnormalLabel: abnormal,
          tSeconds: t,
        );
    expect(engine.evaluate(ev()).decision, VerificationDecision.execute);
    expect(engine.evaluate(ev(t: 2)).decision, VerificationDecision.ignore, reason: 'cooldown');
    final asked = engine.evaluate(ev(command: CommandClass.mouthOpenHold, pCommand: 0.8, pIntentional: 0.7, pPrototype: 0.5, t: 10));
    expect(asked.decision, VerificationDecision.confirm);
    expect(asked.prompt, startsWith('Did you mean'));
    final confirmed = engine.evaluate(ev(command: CommandClass.doubleBlink, pCommand: 0.85, pIntentional: 0.7, pPrototype: 0.5, t: 12));
    expect(confirmed.decision, VerificationDecision.execute);
    expect(confirmed.command, CommandClass.mouthOpenHold);
    engine.evaluate(ev(command: CommandClass.browRaiseHold, pCommand: 0.8, pIntentional: 0.7, pPrototype: 0.5, t: 20));
    final expired = engine.evaluate(ev(command: CommandClass.nonCommand, t: 30));
    expect(expired.decision, VerificationDecision.cancel);
    final alert = engine.evaluate(ev(pAbnormal: 0.9, abnormal: AbnormalClass.possibleSeizureLike, t: 40));
    expect(alert.decision, VerificationDecision.alert);
    expect(engine.evaluate(ev(pAbnormal: 0.9, abnormal: AbnormalClass.possibleSeizureLike, t: 41)).decision, VerificationDecision.ignore);
  });

  test('shipped bundle loads and the pipeline never executes on rest or abnormal movement', () async {
    final bundle = await _bundleFromAssets();
    expect(bundle.manifest['schema_version'], kBundleSchemaVersion);
    final pipeline = IntentPipeline(bundle: bundle, profile: PatientProfile.populationDefault());
    final rng = math.Random(9);
    double restEar(int i, double t) => (t % 3.3) < 0.15 ? 0.05 : 0.30 + rng.nextDouble() * 0.01;
    final restVerdicts = <Verdict>[];
    for (final frame in _frames(6, restEar)) {
      final v = pipeline.push(frame);
      if (v != null) restVerdicts.add(v);
    }
    expect(restVerdicts.where((v) => v.decision == VerificationDecision.execute), isEmpty);

    pipeline.reset();
    // Seizure-like: sustained 4 Hz high-amplitude head oscillation.
    final seizureVerdicts = <Verdict>[];
    for (final frame in _frames(6, restEar, yaw: (t) => 12 * math.sin(2 * math.pi * 4 * t))) {
      final values = List<double>.from(frame.values);
      values[F.headAngularSpeed] = 12 * 2 * math.pi * 4 * math.cos(2 * math.pi * 4 * frame.tSeconds).abs();
      values[F.flowMagMean] = 0.25;
      values[F.flowMagStd] = 0.1;
      values[F.flowHfRatio] = 0.7;
      final v = pipeline.push(IntentFrame(frame.tSeconds, values));
      if (v != null) seizureVerdicts.add(v);
    }
    expect(seizureVerdicts.where((v) => v.decision == VerificationDecision.execute), isEmpty);
    expect(seizureVerdicts.any((v) => v.decision == VerificationDecision.alert), isTrue);
  });

  test('recognition service maps verified commands to PatientSignals and stores the profile', () async {
    SharedPreferences.setMockInitialValues({});
    final prefs = await SharedPreferences.getInstance();
    final executed = <PatientSignal>[];
    final alerts = <String>[];
    final prompts = <String>[];
    final service = IntentRecognitionService(
      observations: const Stream.empty(),
      profileRepository: PatientProfileRepository(prefs),
      bundleLoader: _bundleFromAssets,
      onExecute: (signal, _) => executed.add(signal),
      onConfirmationPrompt: (_, prompt, __) => prompts.add(prompt),
      onAlert: (label, _) => alerts.add(label),
    );
    await service.start();
    expect(service.isReady, isTrue);
    expect(service.isCalibrated, isFalse);
    // Feed a seizure-like clip through the debug hook: alert, never execute.
    final rng = math.Random(4);
    double restEar(int i, double t) => 0.30 + rng.nextDouble() * 0.01;
    service.debugPushFrames(_frames(6, restEar, yaw: (t) => 12 * math.sin(2 * math.pi * 4 * t)).map((frame) {
      final values = List<double>.from(frame.values);
      values[F.headAngularSpeed] = 300 * math.cos(2 * math.pi * 4 * frame.tSeconds).abs();
      values[F.flowMagMean] = 0.25;
      values[F.flowHfRatio] = 0.7;
      return IntentFrame(frame.tSeconds, values);
    }));
    expect(executed, isEmpty);
    expect(alerts, isNotEmpty);
    // Profile round trip through the repository.
    service.beginCalibration('p-test');
    await service.importProfileJson(PatientProfile.populationDefault().toJsonString());
    expect(prefs.getString(PatientProfileRepository.key), isNotNull);
    await service.resetProfile();
    expect(prefs.getString(PatientProfileRepository.key), isNull);
    service.dispose();
  });
}

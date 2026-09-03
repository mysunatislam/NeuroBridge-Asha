import 'dart:math' as math;

import 'package:fingerspeak_mobile/models/patient_signal.dart';
import 'package:fingerspeak_mobile/services/calibration_service.dart';

class FaceCalibrationCollector {
  FaceCalibrationCollector({
    this.minimumSamples = 24,
    this.minimumObservation = const Duration(seconds: 2),
  });

  final int minimumSamples;
  final Duration minimumObservation;
  final Set<int> _observations = <int>{};
  final List<_FaceCalibrationSample> _samples = <_FaceCalibrationSample>[];

  int get sampleCount => _samples.length;
  bool get isReady =>
      sampleCount >= minimumSamples &&
      observationDuration >= minimumObservation;
  Duration get observationDuration => _samples.length < 2
      ? Duration.zero
      : _samples.last.observedAt.difference(_samples.first.observedAt);
  String? validationMessage;

  bool add(MonitorStatus status) {
    final observedAt = status.observedAt;
    final leftEye = status.leftEyeOpen;
    final rightEye = status.rightEyeOpen;
    final eyebrow = status.eyebrowDistance;
    final mouth = status.mouthDistance;
    if (status.lifecycle != MonitorLifecycle.active ||
        !status.faceDetected ||
        observedAt == null ||
        leftEye == null ||
        rightEye == null ||
        eyebrow == null ||
        mouth == null ||
        !leftEye.isFinite ||
        !rightEye.isFinite ||
        !eyebrow.isFinite ||
        !mouth.isFinite) {
      return false;
    }
    final observationKey = observedAt.microsecondsSinceEpoch;
    if (_samples.isNotEmpty && !observedAt.isAfter(_samples.last.observedAt)) {
      return false;
    }
    if (!_observations.add(observationKey)) return false;
    _samples.add(_FaceCalibrationSample(
      observedAt: observedAt,
      leftEye: leftEye,
      rightEye: rightEye,
      eyebrow: eyebrow,
      mouth: mouth,
      smile: status.smileProbability,
      yaw: status.headYaw,
      pitch: status.headPitch,
    ));
    return true;
  }

  NeutralFaceBaseline? build() {
    validationMessage = null;
    if (sampleCount < minimumSamples) {
      validationMessage =
          'Only $sampleCount fresh face frames were usable; $minimumSamples are required.';
      return null;
    }
    if (observationDuration < minimumObservation) {
      validationMessage =
          'Capture was too brief. Hold a relaxed expression for at least ${minimumObservation.inMilliseconds / 1000} seconds and retry.';
      return null;
    }

    final leftEyes = _samples.map((sample) => sample.leftEye).toList();
    final rightEyes = _samples.map((sample) => sample.rightEye).toList();
    final eyebrows = _samples.map((sample) => sample.eyebrow).toList();
    final mouths = _samples.map((sample) => sample.mouth).toList();
    final yaws = _samples
        .map((sample) => sample.yaw)
        .whereType<double>()
        .where((value) => value.isFinite)
        .toList();
    final pitches = _samples
        .map((sample) => sample.pitch)
        .whereType<double>()
        .where((value) => value.isFinite)
        .toList();

    if (_centralRange(leftEyes) > 0.42 || _centralRange(rightEyes) > 0.42) {
      validationMessage =
          'Eyes changed too much during the neutral capture. Relax, keep eyes naturally open, and retry.';
      return null;
    }
    if (yaws.length >= minimumSamples ~/ 2 && _centralRange(yaws) > 16) {
      validationMessage =
          'Head movement was too large during capture. Keep facing the camera and retry.';
      return null;
    }
    if (pitches.length >= minimumSamples ~/ 2 && _centralRange(pitches) > 14) {
      validationMessage =
          'Head movement was too large during capture. Keep facing the camera and retry.';
      return null;
    }

    final smiles = _samples
        .map((sample) => sample.smile)
        .whereType<double>()
        .where((value) => value.isFinite)
        .toList();
    if (_centralRange(eyebrows) >
        math.max(0.038, _robustMean(eyebrows) * 0.45)) {
      validationMessage =
          'Eyebrows moved during the neutral capture. Relax your brow and retry.';
      return null;
    }
    if (_centralRange(mouths) > math.max(0.048, _robustMean(mouths) * 0.65)) {
      validationMessage =
          'Mouth movement changed during the neutral capture. Relax your lips without speaking and retry.';
      return null;
    }
    if (smiles.length >= minimumSamples ~/ 2 &&
        (_centralRange(smiles) > 0.30 || _robustMean(smiles) > 0.35)) {
      validationMessage =
          'A smile was measured during the neutral capture. Relax your smile and retry.';
      return null;
    }
    return NeutralFaceBaseline(
      eyebrowDistance: _robustMean(eyebrows).clamp(0.01, 0.50),
      mouthDistance: _robustMean(mouths).clamp(0.005, 0.50),
      leftEyeOpenness: _robustMean(leftEyes).clamp(0.05, 1),
      rightEyeOpenness: _robustMean(rightEyes).clamp(0.05, 1),
      smileProbability: smiles.length < minimumSamples ~/ 2
          ? NeutralFaceBaseline.standard.smileProbability
          : _robustMean(smiles).clamp(0, 1),
      headYaw: yaws.length < minimumSamples ~/ 2
          ? NeutralFaceBaseline.standard.headYaw
          : _robustMean(yaws).clamp(-60, 60),
      headPitch: pitches.length < minimumSamples ~/ 2
          ? NeutralFaceBaseline.standard.headPitch
          : _robustMean(pitches).clamp(-60, 60),
    );
  }

  double _robustMean(List<double> values) {
    final sorted = List<double>.of(values)..sort();
    final trim = sorted.length >= 20 ? math.max(1, sorted.length ~/ 10) : 0;
    final kept = sorted.sublist(trim, sorted.length - trim);
    return kept.reduce((a, b) => a + b) / kept.length;
  }

  double _centralRange(List<double> values) {
    final sorted = List<double>.of(values)..sort();
    final low = sorted[(sorted.length * 0.10).floor()];
    final high =
        sorted[math.min(sorted.length - 1, (sorted.length * 0.90).floor())];
    return high - low;
  }
}

class _FaceCalibrationSample {
  const _FaceCalibrationSample({
    required this.observedAt,
    required this.leftEye,
    required this.rightEye,
    required this.eyebrow,
    required this.mouth,
    required this.smile,
    required this.yaw,
    required this.pitch,
  });

  final DateTime observedAt;
  final double leftEye;
  final double rightEye;
  final double eyebrow;
  final double mouth;
  final double? smile;
  final double? yaw;
  final double? pitch;
}

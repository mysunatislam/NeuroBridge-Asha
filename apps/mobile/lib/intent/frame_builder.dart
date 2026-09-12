// frame_builder.dart
// Turns irregular on-device face/hand observations (ML Kit face detector, the
// MediaPipe hand studio) into schema-ordered IntentFrames on the 20 Hz grid.
//
// ML Kit exposes eye-open *probabilities* and box-relative distances rather
// than MediaPipe mesh ratios, so channels are mapped onto the units the Python
// trainer uses (documented per channel below). The patient profile normaliser
// and prototypes then adapt the remaining offsets per patient.

import 'dart:math' as math;

import 'intent_schema.dart';
import 'window_features.dart';

/// One camera observation. Any field may be null when the detector could not
/// measure it; the builder carries the previous value forward for that channel.
class IntentObservation {
  const IntentObservation({
    required this.observedAt,
    required this.faceDetected,
    this.leftEyeOpen,
    this.rightEyeOpen,
    this.mouthDistance,
    this.smileProbability,
    this.eyebrowDistance,
    this.headYaw,
    this.headPitch,
    this.headRoll,
    this.faceCenterX,
    this.faceCenterY,
    this.faceScale,
    this.lipMotion,
    this.contourMotionEnergy,
    this.contourDirectionConsistency,
    this.mouthAsymmetry,
    this.handPresent = false,
    this.wristX,
    this.wristY,
    this.elbowAngle,
  });

  final DateTime observedAt;
  final bool faceDetected;
  final double? leftEyeOpen; // 0..1 probability
  final double? rightEyeOpen;
  final double? mouthDistance; // lip gap / face height
  final double? smileProbability; // 0..1
  final double? eyebrowDistance; // brow-eye gap / face height
  final double? headYaw; // degrees
  final double? headPitch;
  final double? headRoll;
  final double? faceCenterX; // 0..1 of frame width
  final double? faceCenterY;
  final double? faceScale; // face width / frame width
  final double? lipMotion; // mean lip contour displacement / face height
  final double? contourMotionEnergy; // mean contour displacement / face height
  final double? contourDirectionConsistency; // 0..1
  final double? mouthAsymmetry; // |left rise - right rise| / face height
  final bool handPresent;
  final double? wristX; // 0..1
  final double? wristY;
  final double? elbowAngle; // degrees
}

/// Online resampler + derived-channel calculator.
class IntentFrameBuilder {
  IntentFrameBuilder({this.rateHz = kFrameRateHz, DateTime? epoch})
      : _epoch = epoch;

  final double rateHz;
  DateTime? _epoch;
  List<double>? _previousRaw;
  double? _previousRawT;
  double _nextGridT = 0.0;
  final List<double> _last = List<double>.filled(kFrameFeatureCount, 0.0);
  final List<double> _flowSeries = [];
  double? _prevYaw;
  double? _prevPitch;
  double? _prevRoll;
  double? _prevPoseT;
  double? _prevWristX;
  double? _prevWristY;
  double? _prevWristT;
  double _prevHandSpeed = 0.0;

  /// Seconds since the first observation.
  double secondsFor(DateTime at) {
    _epoch ??= at;
    return at.difference(_epoch!).inMicroseconds / 1e6;
  }

  void reset() {
    _epoch = null;
    _previousRaw = null;
    _previousRawT = null;
    _nextGridT = 0.0;
    _flowSeries.clear();
    _prevYaw = _prevPitch = _prevRoll = _prevPoseT = null;
    _prevWristX = _prevWristY = _prevWristT = null;
    _prevHandSpeed = 0.0;
    for (var i = 0; i < _last.length; i++) {
      _last[i] = 0.0;
    }
  }

  /// Convert an observation into zero or more grid-aligned frames.
  List<IntentFrame> add(IntentObservation o) {
    if (!o.faceDetected) {
      // Face lost: the window restarts when the face returns.
      _previousRaw = null;
      _previousRawT = null;
      return const [];
    }
    final t = secondsFor(o.observedAt);
    final raw = _rawChannels(o, t);
    final frames = <IntentFrame>[];
    if (_previousRaw == null || _previousRawT == null || t < _previousRawT!) {
      _nextGridT = t;
    }
    final prev = _previousRaw;
    final prevT = _previousRawT;
    while (_nextGridT <= t + 1e-9) {
      List<double> values;
      if (prev == null || prevT == null || t - prevT <= 1e-9) {
        values = List<double>.from(raw);
      } else {
        final alpha = ((_nextGridT - prevT) / (t - prevT)).clamp(0.0, 1.0);
        values = List<double>.generate(
            kFrameFeatureCount, (c) => prev[c] + (raw[c] - prev[c]) * alpha);
      }
      frames.add(IntentFrame(_nextGridT, values));
      _nextGridT += 1.0 / rateHz;
    }
    _previousRaw = raw;
    _previousRawT = t;
    return frames;
  }

  List<double> _rawChannels(IntentObservation o, double t) {
    final v = List<double>.from(_last);
    double keep(int channel, double? value) =>
        value != null && value.isFinite ? value : _last[channel];

    // Eyes: ML Kit open-probability -> EAR-like ratio (0.30 when fully open).
    v[F.earLeft] = keep(F.earLeft, o.leftEyeOpen == null ? null : o.leftEyeOpen! * 0.30);
    v[F.earRight] = keep(F.earRight, o.rightEyeOpen == null ? null : o.rightEyeOpen! * 0.30);
    v[F.earMean] = (v[F.earLeft] + v[F.earRight]) / 2.0;
    // Mouth: box-relative lip gap is on the same order as the mesh ratio.
    v[F.mouthOpenRatio] = keep(F.mouthOpenRatio, o.mouthDistance);
    v[F.smileRatio] = keep(F.smileRatio, o.smileProbability == null ? null : o.smileProbability! * 0.20);
    v[F.mouthAsymmetry] = keep(F.mouthAsymmetry, o.mouthAsymmetry ?? 0.0);
    v[F.lipMotion] = keep(F.lipMotion, o.lipMotion ?? 0.0);
    // Brows: ML Kit brow-eye gap (~0.18 at rest) -> mesh brow-raise (~0.42 at rest).
    v[F.browRaise] = keep(F.browRaise, o.eyebrowDistance == null ? null : o.eyebrowDistance! * (0.42 / 0.18));
    v[F.headYaw] = keep(F.headYaw, o.headYaw);
    v[F.headPitch] = keep(F.headPitch, o.headPitch);
    v[F.headRoll] = keep(F.headRoll, o.headRoll ?? 0.0);
    if (_prevPoseT != null && t > _prevPoseT!) {
      final dt = t - _prevPoseT!;
      final dy = v[F.headYaw] - (_prevYaw ?? v[F.headYaw]);
      final dp = v[F.headPitch] - (_prevPitch ?? v[F.headPitch]);
      final dr = v[F.headRoll] - (_prevRoll ?? v[F.headRoll]);
      v[F.headAngularSpeed] = math.sqrt(dy * dy + dp * dp + dr * dr) / dt;
    } else {
      v[F.headAngularSpeed] = 0.0;
    }
    _prevYaw = v[F.headYaw];
    _prevPitch = v[F.headPitch];
    _prevRoll = v[F.headRoll];
    _prevPoseT = t;
    v[F.faceCx] = keep(F.faceCx, o.faceCenterX ?? 0.5);
    v[F.faceCy] = keep(F.faceCy, o.faceCenterY ?? 0.45);
    v[F.faceScale] = keep(F.faceScale, o.faceScale ?? 0.18);

    // Hands (optional; from the MediaPipe studio or pose).
    if (o.handPresent && o.wristX != null && o.wristY != null) {
      v[F.handPresent] = 1.0;
      v[F.wristX] = o.wristX!;
      v[F.wristY] = o.wristY!;
      var speed = 0.0;
      var accel = 0.0;
      var direction = 0.0;
      if (_prevWristT != null && t > _prevWristT!) {
        final dt = t - _prevWristT!;
        final dx = o.wristX! - _prevWristX!;
        final dy = o.wristY! - _prevWristY!;
        speed = math.sqrt(dx * dx + dy * dy) / dt;
        direction = speed > 1e-6 ? math.atan2(dy, dx) : 0.0;
        accel = (speed - _prevHandSpeed) / dt;
      }
      _prevWristX = o.wristX;
      _prevWristY = o.wristY;
      _prevWristT = t;
      _prevHandSpeed = speed;
      v[F.handSpeed] = speed;
      v[F.handAccel] = accel;
      v[F.handDirection] = direction;
      v[F.elbowAngle] = o.elbowAngle ?? 150.0;
      v[F.shoulderMotion] = 0.0;
    } else {
      _prevWristT = null;
      _prevHandSpeed = 0.0;
      v[F.handPresent] = 0.0;
      v[F.wristX] = 0.0;
      v[F.wristY] = 0.0;
      v[F.handSpeed] = 0.0;
      v[F.handAccel] = 0.0;
      v[F.handDirection] = 0.0;
      v[F.elbowAngle] = o.elbowAngle ?? 150.0;
      v[F.shoulderMotion] = 0.0;
    }

    // Motion energy proxy from contour displacement (no pixel access).
    final energy = o.contourMotionEnergy ?? _last[F.flowMagMean];
    v[F.flowMagMean] = energy;
    v[F.flowMagStd] = energy * 0.5;
    v[F.flowDirConsistency] = keep(F.flowDirConsistency, o.contourDirectionConsistency ?? 0.3);
    _flowSeries.add(energy);
    while (_flowSeries.length > (rateHz * 2).round()) {
      _flowSeries.removeAt(0);
    }
    final freq = _flowSeries.length >= 8
        ? dominantFrequency(_flowSeries, rateHz)
        : (dominantHz: 0.0, rhythmicity: 0.0);
    v[F.flowDominantHz] = freq.dominantHz;
    v[F.flowHfRatio] = _highFrequencyRatio(_flowSeries, rateHz);

    for (var i = 0; i < v.length; i++) {
      if (!v[i].isFinite) v[i] = 0.0;
      _last[i] = v[i];
    }
    return v;
  }

  static double _highFrequencyRatio(List<double> series, double rateHz,
      {double cutoffHz = 3.0}) {
    final n = series.length;
    if (n < 8) return 0.0;
    final mean = series.reduce((a, b) => a + b) / n;
    var total = 0.0;
    var high = 0.0;
    for (var k = 1; k <= n ~/ 2; k++) {
      var re = 0.0;
      var im = 0.0;
      for (var i = 0; i < n; i++) {
        final angle = -2 * math.pi * k * i / n;
        re += (series[i] - mean) * math.cos(angle);
        im += (series[i] - mean) * math.sin(angle);
      }
      final power = re * re + im * im;
      total += power;
      if (k * rateHz / n >= cutoffHz) high += power;
    }
    return total <= 1e-12 ? 0.0 : high / total;
  }
}

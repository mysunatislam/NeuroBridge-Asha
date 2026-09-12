// patient_calibration_service.dart
// On-device port of CalibrationSession.build_profile(): five 30-second phases
// of IntentFrames -> PatientProfile. Recordings can be exported as JSON so the
// Python trainer can retrain the bootstrap models on real patient data.

import 'dart:convert';
import 'dart:math' as math;

import 'intent_schema.dart';
import 'patient_profile.dart';
import 'window_features.dart';

class CalibrationException implements Exception {
  CalibrationException(this.message);
  final String message;
  @override
  String toString() => 'CalibrationException: $message';
}

class PhaseRecording {
  PhaseRecording(this.phase);
  final String phase;
  final List<IntentFrame> frames = [];

  double get seconds =>
      frames.length < 2 ? 0.0 : frames.last.tSeconds - frames.first.tSeconds;

  Map<String, Object?> toJson() => {
        'phase': phase,
        'timestamps': frames.map((f) => f.tSeconds).toList(),
        'values': frames.map((f) => f.values).toList(),
      };
}

const List<String> _rangeChannels = [
  'ear_mean',
  'mouth_open_ratio',
  'smile_ratio',
  'brow_raise',
  'head_yaw',
  'head_pitch',
  'head_roll',
  'head_angular_speed',
  'hand_speed',
  'flow_mag_mean',
];

class PatientCalibrationSession {
  PatientCalibrationSession({
    required this.patientId,
    this.phaseSeconds = CalibrationPhase.seconds,
    this.minimumSeconds = 10.0,
  }) : recordings = {for (final p in CalibrationPhase.all) p: PhaseRecording(p)};

  final String patientId;
  final double phaseSeconds;
  final double minimumSeconds;
  final Map<String, PhaseRecording> recordings;

  void addFrame(String phase, IntentFrame frame) {
    final recording = recordings[phase];
    if (recording == null) throw CalibrationException('unknown phase $phase');
    recording.frames.add(frame);
  }

  void clearPhase(String phase) => recordings[phase]?.frames.clear();

  double progress(String phase) =>
      math.min(1.0, (recordings[phase]?.seconds ?? 0.0) / phaseSeconds);

  List<String> get missingPhases => [
        for (final e in recordings.entries)
          if (e.value.seconds < minimumSeconds) e.key,
      ];

  String exportRecordingsJson() => jsonEncode({
        'schema_version': 'neurobridge-calibration-recording-v1',
        'feature_schema': kFrameSchemaVersion,
        'patient_id': patientId,
        'rate_hz': kFrameRateHz,
        'phases': recordings.values.map((r) => r.toJson()).toList(),
      });

  PatientProfile buildProfile() {
    final missing = missingPhases;
    if (missing.isNotEmpty) {
      throw CalibrationException('calibration phases too short: ${missing.join(', ')}');
    }
    final blinking = recordings[CalibrationPhase.normalBlinking]!;
    final rest = recordings[CalibrationPhase.restState]!;
    final facial = recordings[CalibrationPhase.normalFacialMovement]!;
    final intentional = recordings[CalibrationPhase.intentionalGestures]!;
    final random = recordings[CalibrationPhase.randomMovement]!;

    // Blink pattern.
    final earAll = [
      for (final f in blinking.frames) f.values[F.earMean],
      for (final f in rest.frames) f.values[F.earMean],
    ];
    final openEar = percentile(earAll, 85);
    final events = detectBlinks(
      blinking.frames.map((f) => f.tSeconds).toList(),
      blinking.frames.map((f) => f.values[F.earMean]).toList(),
      openEar: openEar,
    );
    final stats = blinkStatistics(events, blinking.seconds);
    final blink = <String, double>{
      'open_ear': openEar,
      'rate_per_min': stats.rateHz * 60.0,
      'mean_duration_ms': stats.meanDurationMs,
      'sd_duration_ms': stats.sdDurationMs,
      'mean_interval_s': stats.meanIntervalS,
      'interval_cv': stats.intervalCv,
      'closure_depth_mean': stats.meanDepth,
      'closing_velocity_mean': stats.meanVelocity,
      'count': stats.count,
    };

    // Movement range over all phases.
    final all = [for (final r in recordings.values) ...r.frames];
    final movementRange = <String, List<double>>{};
    for (final name in _rangeChannels) {
      final c = kFrameFeatures.indexOf(name);
      final column = all.map((f) => f.values[c]).toList();
      final lo = percentile(column, 2);
      final hi = percentile(column, 98);
      final pad = 0.05 * math.max(hi - lo, 1e-6);
      movementRange[name] = [lo - pad, hi + pad];
    }

    final restMean = _mean(rest.frames);
    final restStd = _std(rest.frames, restMean, floor: 1e-6);
    final baseline = <String, Object?>{
      'per_channel_mean': restMean,
      'per_channel_std': restStd,
      'motion_energy_rest': _channelMean(rest.frames, F.flowMagMean),
      'motion_energy_facial': _channelMean(facial.frames, F.flowMagMean),
      'motion_energy_random': _channelMean(random.frames, F.flowMagMean),
      'channel_names': kFrameFeatures,
    };

    final names = windowFeatureNames();
    final restWindows = _windows(rest, openEar);
    final randomWindows = _windows(random, openEar);
    final involuntary = <String, double>{
      'hf_ratio_rest': _channelMean(rest.frames, F.flowHfRatio),
      'hf_ratio_random': _channelMean(random.frames, F.flowHfRatio),
      'head_rhythmicity_rest': _columnMean(restWindows, names.indexOf('head_rhythmicity')),
      'face_jerk_rest': _columnMean(restWindows, names.indexOf('face_jerk_rms')),
      'face_jerk_random': _columnMean(randomWindows, names.indexOf('face_jerk_rms')),
    };

    final allMean = _mean(all);
    final allStd = _std(all, allMean, floor: 1e-3);

    final prototypes = <String, PhasePrototype>{};
    for (final e in recordings.entries) {
      final windows = _windows(e.value, openEar);
      if (windows.isEmpty) continue;
      final mean = _rowsMean(windows);
      prototypes[e.key] = PhasePrototype(
        mean: mean,
        std: _rowsStd(windows, mean, floor: 1e-3),
        count: windows.length.toDouble(),
      );
    }

    final intentionalWindows = _windows(intentional, openEar);
    final negative = [...randomWindows, ...restWindows];
    final separability = _separability(
        intentionalWindows, negative.isEmpty ? intentionalWindows : negative);
    final gestureThresholds = <String, Object?>{
      'intent_ignore_below': kIgnoreBelow,
      'intent_execute_at': kExecuteAt,
      'prototype_weight': (0.2 + 0.6 * separability).clamp(0.2, 0.8),
      'separability': separability,
      'per_command': {
        for (final c in CommandClass.all)
          if (c != CommandClass.nonCommand) c: kExecuteAt,
      },
      'confirmation_window_s': 8.0,
    };

    return PatientProfile(
      patientId: patientId,
      createdAt: DateTime.now().toUtc().toIso8601String(),
      phases: {
        for (final e in recordings.entries)
          e.key: {'seconds': e.value.seconds, 'frames': e.value.frames.length.toDouble()},
      },
      blink: blink,
      movementRange: movementRange,
      baselineFacialActivity: baseline,
      involuntaryProfile: involuntary,
      gestureThresholds: gestureThresholds,
      normalizerMean: allMean,
      normalizerStd: allStd,
      prototypes: prototypes,
      commandMap: Map<String, String>.from(kDefaultCommandSignals),
      notes: 'Baseline measured from the patient\'s own recordings; not a diagnosis.',
    );
  }

  static List<List<double>> _windows(PhaseRecording rec, double openEar) {
    final frames = rec.frames;
    const hop = kWindowFrames ~/ 2;
    if (frames.length < kWindowFrames) {
      if (frames.length < 4) return const [];
      return [windowFeatures(frames, openEar: openEar)];
    }
    final rows = <List<double>>[];
    for (var start = 0; start + kWindowFrames <= frames.length; start += math.max(1, hop)) {
      rows.add(windowFeatures(frames.sublist(start, start + kWindowFrames), openEar: openEar));
    }
    return rows;
  }

  static List<double> _mean(List<IntentFrame> frames) {
    final out = List<double>.filled(kFrameFeatureCount, 0.0);
    if (frames.isEmpty) return out;
    for (final f in frames) {
      for (var c = 0; c < kFrameFeatureCount; c++) {
        out[c] += f.values[c];
      }
    }
    for (var c = 0; c < kFrameFeatureCount; c++) {
      out[c] /= frames.length;
    }
    return out;
  }

  static List<double> _std(List<IntentFrame> frames, List<double> mean, {required double floor}) {
    final out = List<double>.filled(kFrameFeatureCount, floor);
    if (frames.isEmpty) return out;
    for (var c = 0; c < kFrameFeatureCount; c++) {
      var s = 0.0;
      for (final f in frames) {
        final d = f.values[c] - mean[c];
        s += d * d;
      }
      out[c] = math.max(math.sqrt(s / frames.length), floor);
    }
    return out;
  }

  static double _channelMean(List<IntentFrame> frames, int channel) =>
      frames.isEmpty ? 0.0 : frames.map((f) => f.values[channel]).reduce((a, b) => a + b) / frames.length;

  static double _columnMean(List<List<double>> rows, int column) =>
      rows.isEmpty ? 0.0 : rows.map((r) => r[column]).reduce((a, b) => a + b) / rows.length;

  static List<double> _rowsMean(List<List<double>> rows) {
    final width = rows.first.length;
    final out = List<double>.filled(width, 0.0);
    for (final r in rows) {
      for (var i = 0; i < width; i++) {
        out[i] += r[i];
      }
    }
    for (var i = 0; i < width; i++) {
      out[i] /= rows.length;
    }
    return out;
  }

  static List<double> _rowsStd(List<List<double>> rows, List<double> mean, {required double floor}) {
    final width = rows.first.length;
    final out = List<double>.filled(width, floor);
    for (var i = 0; i < width; i++) {
      var s = 0.0;
      for (final r in rows) {
        final d = r[i] - mean[i];
        s += d * d;
      }
      out[i] = math.max(math.sqrt(s / rows.length), floor);
    }
    return out;
  }

  static double _separability(List<List<double>> positive, List<List<double>> negative) {
    if (positive.isEmpty || negative.isEmpty) return 0.0;
    final pooled = [...positive, ...negative];
    final pooledMean = _rowsMean(pooled);
    final pooledStd = _rowsStd(pooled, pooledMean, floor: 1e-6);
    final pm = _rowsMean(positive);
    final nm = _rowsMean(negative);
    var distance = 0.0;
    for (var i = 0; i < pm.length; i++) {
      distance += (pm[i] - nm[i]).abs() / pooledStd[i];
    }
    distance /= pm.length;
    return 1.0 - math.exp(-distance);
  }
}

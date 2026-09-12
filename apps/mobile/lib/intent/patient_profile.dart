// patient_profile.dart
// patient_profile.json (schema neurobridge-patient-profile-v1) as used by the
// on-device pipeline. Mirrors services/intent/.../calibration.py.

import 'dart:convert';
import 'dart:math' as math;

import 'package:shared_preferences/shared_preferences.dart';

import 'intent_schema.dart';

class PhasePrototype {
  const PhasePrototype({required this.mean, required this.std, required this.count});
  final List<double> mean;
  final List<double> std;
  final double count;

  Map<String, Object> toJson() => {'mean': mean, 'std': std, 'count': [count]};

  factory PhasePrototype.fromJson(Map<String, dynamic> json) => PhasePrototype(
        mean: _doubles(json['mean']),
        std: _doubles(json['std']),
        count: (json['count'] is List && (json['count'] as List).isNotEmpty)
            ? ((json['count'] as List).first as num).toDouble()
            : 0.0,
      );
}

List<double> _doubles(Object? raw) =>
    (raw as List).map((v) => (v as num).toDouble()).toList(growable: false);

class PatientProfile {
  PatientProfile({
    required this.patientId,
    required this.createdAt,
    required this.phases,
    required this.blink,
    required this.movementRange,
    required this.baselineFacialActivity,
    required this.involuntaryProfile,
    required this.gestureThresholds,
    required this.normalizerMean,
    required this.normalizerStd,
    required this.prototypes,
    required this.commandMap,
    this.notes = '',
  }) {
    if (normalizerMean.length != kFrameFeatureCount ||
        normalizerStd.length != kFrameFeatureCount) {
      throw const FormatException('normalizer length does not match schema');
    }
  }

  final String patientId;
  final String createdAt;
  final Map<String, Map<String, double>> phases;
  final Map<String, double> blink;
  final Map<String, List<double>> movementRange;
  final Map<String, Object?> baselineFacialActivity;
  final Map<String, double> involuntaryProfile;
  final Map<String, Object?> gestureThresholds;
  final List<double> normalizerMean;
  final List<double> normalizerStd;
  final Map<String, PhasePrototype> prototypes;
  final Map<String, String> commandMap;
  final String notes;

  bool get isCalibrated => patientId != 'population-default';

  double get openEar => blink['open_ear'] ?? 0.30;
  double get ignoreBelow =>
      (gestureThresholds['intent_ignore_below'] as num?)?.toDouble() ?? kIgnoreBelow;
  double get executeAt =>
      (gestureThresholds['intent_execute_at'] as num?)?.toDouble() ?? kExecuteAt;
  double get prototypeWeight =>
      (gestureThresholds['prototype_weight'] as num?)?.toDouble() ?? 0.4;
  double get confirmationWindowSeconds =>
      (gestureThresholds['confirmation_window_s'] as num?)?.toDouble() ?? 8.0;
  double get restHfRatio => involuntaryProfile['hf_ratio_rest'] ?? 0.2;
  double get restRhythmicity => involuntaryProfile['head_rhythmicity_rest'] ?? 0.2;

  List<List<double>> normalize(List<List<double>> sequence) => [
        for (final row in sequence)
          [
            for (var c = 0; c < kFrameFeatureCount; c++)
              (row[c] - normalizerMean[c]) / normalizerStd[c],
          ],
      ];

  Map<String, double> prototypeScores(List<double> windowVector) {
    final scores = <String, double>{};
    prototypes.forEach((name, proto) {
      if (proto.mean.length != windowVector.length) return;
      var sum = 0.0;
      for (var i = 0; i < windowVector.length; i++) {
        final z = (windowVector[i] - proto.mean[i]) / proto.std[i];
        sum += z * z;
      }
      final distance = math.sqrt(sum / windowVector.length);
      scores[name] = 1.0 / (1.0 + distance);
    });
    return scores;
  }

  double intentionalPrototypeProbability(List<double> windowVector) {
    final scores = prototypeScores(windowVector);
    if (scores.isEmpty) return 0.5;
    final intentional = scores[CalibrationPhase.intentionalGestures] ?? 0.0;
    var others = 0.0;
    scores.forEach((name, value) {
      if (name != CalibrationPhase.intentionalGestures && value > others) {
        others = value;
      }
    });
    final denominator = intentional + others;
    return denominator > 0 ? intentional / denominator : 0.5;
  }

  Map<String, Object?> toJson() => {
        'schema_version': kProfileSchemaVersion,
        'feature_schema': kFrameSchemaVersion,
        'patient_id': patientId,
        'created_at': createdAt,
        'phases': phases,
        'blink': blink,
        'movement_range': movementRange,
        'baseline_facial_activity': baselineFacialActivity,
        'involuntary_profile': involuntaryProfile,
        'gesture_thresholds': gestureThresholds,
        'normalizer': {'mean': normalizerMean, 'std': normalizerStd},
        'prototypes': prototypes.map((k, v) => MapEntry(k, v.toJson())),
        'command_map': commandMap,
        'notes': notes,
      };

  String toJsonString() => const JsonEncoder.withIndent('  ').convert(toJson());

  factory PatientProfile.fromJson(Map<String, dynamic> json) {
    if (json['schema_version'] != kProfileSchemaVersion) {
      throw const FormatException('unsupported patient profile schema');
    }
    final normalizer = json['normalizer'] as Map<String, dynamic>;
    Map<String, double> doubleMap(Object? raw) => {
          for (final e in ((raw as Map?) ?? {}).entries)
            e.key as String: (e.value as num).toDouble(),
        };
    return PatientProfile(
      patientId: json['patient_id'] as String,
      createdAt: json['created_at'] as String,
      phases: {
        for (final e in ((json['phases'] as Map?) ?? {}).entries)
          e.key as String: doubleMap(e.value),
      },
      blink: doubleMap(json['blink']),
      movementRange: {
        for (final e in ((json['movement_range'] as Map?) ?? {}).entries)
          e.key as String: _doubles(e.value),
      },
      baselineFacialActivity:
          Map<String, Object?>.from((json['baseline_facial_activity'] as Map?) ?? {}),
      involuntaryProfile: doubleMap(json['involuntary_profile']),
      gestureThresholds:
          Map<String, Object?>.from((json['gesture_thresholds'] as Map?) ?? {}),
      normalizerMean: _doubles(normalizer['mean']),
      normalizerStd: _doubles(normalizer['std']),
      prototypes: {
        for (final e in ((json['prototypes'] as Map?) ?? {}).entries)
          e.key as String:
              PhasePrototype.fromJson(Map<String, dynamic>.from(e.value as Map)),
      },
      commandMap: {
        for (final e in ((json['command_map'] as Map?) ?? {}).entries)
          e.key as String: e.value as String,
      },
      notes: (json['notes'] as String?) ?? '',
    );
  }

  static PatientProfile parse(String text) =>
      PatientProfile.fromJson(jsonDecode(text) as Map<String, dynamic>);

  /// Population defaults used before the patient has been calibrated.
  /// Normalisers are broad so nothing saturates; prototypes are empty, which
  /// makes the prototype probability neutral (0.5).
  factory PatientProfile.populationDefault() {
    final mean = List<double>.filled(kFrameFeatureCount, 0.0);
    final std = List<double>.filled(kFrameFeatureCount, 1.0);
    mean[F.earLeft] = 0.30;
    mean[F.earRight] = 0.30;
    mean[F.earMean] = 0.30;
    mean[F.mouthOpenRatio] = 0.10;
    mean[F.smileRatio] = 0.03;
    mean[F.browRaise] = 0.42;
    mean[F.faceCx] = 0.5;
    mean[F.faceCy] = 0.45;
    mean[F.faceScale] = 0.18;
    mean[F.elbowAngle] = 150;
    std[F.earLeft] = 0.08;
    std[F.earRight] = 0.08;
    std[F.earMean] = 0.08;
    std[F.mouthOpenRatio] = 0.08;
    std[F.smileRatio] = 0.05;
    std[F.mouthAsymmetry] = 0.02;
    std[F.lipMotion] = 0.01;
    std[F.browRaise] = 0.04;
    std[F.headYaw] = 8;
    std[F.headPitch] = 6;
    std[F.headRoll] = 4;
    std[F.headAngularSpeed] = 40;
    std[F.faceCx] = 0.02;
    std[F.faceCy] = 0.02;
    std[F.faceScale] = 0.02;
    std[F.handPresent] = 0.5;
    std[F.wristX] = 0.2;
    std[F.wristY] = 0.2;
    std[F.handSpeed] = 0.5;
    std[F.handAccel] = 4;
    std[F.handDirection] = 1.5;
    std[F.elbowAngle] = 30;
    std[F.shoulderMotion] = 0.01;
    std[F.flowMagMean] = 0.1;
    std[F.flowMagStd] = 0.05;
    std[F.flowDirConsistency] = 0.3;
    std[F.flowDominantHz] = 3;
    std[F.flowHfRatio] = 0.3;
    return PatientProfile(
      patientId: 'population-default',
      createdAt: DateTime.now().toUtc().toIso8601String(),
      phases: const {},
      blink: const {'open_ear': 0.30, 'rate_per_min': 17.0, 'mean_duration_ms': 180.0},
      movementRange: const {},
      baselineFacialActivity: const {},
      involuntaryProfile: const {'hf_ratio_rest': 0.2, 'head_rhythmicity_rest': 0.2},
      gestureThresholds: const {
        'intent_ignore_below': kIgnoreBelow,
        'intent_execute_at': kExecuteAt,
        'prototype_weight': 0.0,
        'confirmation_window_s': 8.0,
      },
      normalizerMean: mean,
      normalizerStd: std,
      prototypes: const {},
      commandMap: Map<String, String>.from(kDefaultCommandSignals),
      notes: 'Population default profile; run patient calibration to personalise.',
    );
  }
}

/// Persists the active profile in SharedPreferences (works on web too).
class PatientProfileRepository {
  PatientProfileRepository(this._preferences);

  static const key = 'intent.patient_profile';
  final SharedPreferences _preferences;

  PatientProfile? load() {
    final raw = _preferences.getString(key);
    if (raw == null || raw.isEmpty) return null;
    try {
      return PatientProfile.parse(raw);
    } on Object {
      return null;
    }
  }

  Future<void> save(PatientProfile profile) =>
      _preferences.setString(key, jsonEncode(profile.toJson()));

  Future<void> clear() => _preferences.remove(key);
}

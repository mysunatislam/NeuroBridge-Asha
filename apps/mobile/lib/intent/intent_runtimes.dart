// intent_runtimes.dart
// Phase 1 (intent) and Phase 3 (abnormal movement) runtimes over the exported
// forests, plus the bundle loader. Ports of IntentRuntime / AbnormalRuntime in
// the Python package.

import 'dart:convert';
import 'dart:math' as math;

import 'package:flutter/services.dart' show AssetBundle, rootBundle;

import 'intent_schema.dart';
import 'temporal_cnn.dart';
import 'tree_ensemble.dart';

class IntentPrediction {
  const IntentPrediction({
    required this.label,
    required this.pIntentional,
    required this.margin,
    required this.inDistribution,
    required this.oodRatio,
  });
  final String label;
  final double pIntentional;
  final double margin;
  final bool inDistribution;
  final double oodRatio;
  double get pAccidental => 1.0 - pIntentional;

  Map<String, Object?> toJson() => {
        'label': label,
        'p_intentional': pIntentional,
        'margin': margin,
        'in_distribution': inDistribution,
        'ood_ratio': oodRatio,
      };
}

class IntentRuntime {
  IntentRuntime._(this.forest, this.minMargin, this._mean, this._std, this._centroid, this._threshold);

  final TreeEnsembleRuntime forest;
  final double minMargin;
  final List<double> _mean;
  final List<double> _std;
  final List<double> _centroid;
  final double _threshold;

  factory IntentRuntime.fromJson(Map<String, dynamic> spec) {
    final forestSpec = spec['forest'];
    if (forestSpec is! Map<String, dynamic>) {
      throw const FormatException('intent runtime needs a forest export');
    }
    final ood = spec['ood'] as Map<String, dynamic>;
    return IntentRuntime._(
      TreeEnsembleRuntime.fromJson(forestSpec),
      (spec['min_margin'] as num).toDouble(),
      _doubles(ood['mean']),
      _doubles(ood['std']),
      _doubles(ood['centroid']),
      (ood['threshold'] as num).toDouble(),
    );
  }

  IntentPrediction predict(List<double> features) {
    final proba = forest.predictProba(features);
    final pInt = proba[forest.classes.indexOf(IntentClass.intentional)];
    var sum = 0.0;
    for (var i = 0; i < features.length; i++) {
      final z = (features[i] - _mean[i]) / _std[i] - _centroid[i];
      sum += z * z;
    }
    final distance = math.sqrt(sum);
    final ratio = _threshold > 0 ? distance / _threshold : 0.0;
    final margin = (2.0 * pInt - 1.0).abs();
    final String label;
    if (ratio > 1.0 || margin < minMargin) {
      label = IntentClass.unknown;
    } else {
      label = pInt >= 0.5 ? IntentClass.intentional : IntentClass.accidental;
    }
    return IntentPrediction(
      label: label,
      pIntentional: pInt,
      margin: margin,
      inDistribution: ratio <= 1.0,
      oodRatio: ratio,
    );
  }
}

class AbnormalPrediction {
  const AbnormalPrediction({required this.label, required this.probabilities, this.ruleTriggered});
  final String label;
  final Map<String, double> probabilities;
  final String? ruleTriggered;
  double get pAbnormal => 1.0 - (probabilities[AbnormalClass.normalVoluntary] ?? 0.0);

  Map<String, Object?> toJson() =>
      {'label': label, 'probabilities': probabilities, 'rule_triggered': ruleTriggered};
}

/// Window-feature indexes used by the rule floor (computed once).
class _W {
  _W() {
    final names = windowFeatureNames();
    headDominantHz = names.indexOf('head_dominant_hz');
    headRhythmicity = names.indexOf('head_rhythmicity');
    sustainedSeconds = names.indexOf('sustained_seconds');
    headYawRange = names.indexOf('head_yaw_range');
    flowHfRatioMean = names.indexOf('flow_hf_ratio_mean');
    flowMagMeanMean = names.indexOf('flow_mag_mean_mean');
    faceJerkRms = names.indexOf('face_jerk_rms');
    holdFraction = names.indexOf('hold_fraction');
    peakAmplitude = names.indexOf('peak_amplitude');
    onsetCount = names.indexOf('onset_count');
    headAngularSpeedMax = names.indexOf('head_angular_speed_max');
  }
  late final int headDominantHz;
  late final int headRhythmicity;
  late final int sustainedSeconds;
  late final int headYawRange;
  late final int flowHfRatioMean;
  late final int flowMagMeanMean;
  late final int faceJerkRms;
  late final int holdFraction;
  late final int peakAmplitude;
  late final int onsetCount;
  late final int headAngularSpeedMax;
}

final _W _w = _W();

/// Physics-based minimum probabilities (port of abnormal.rule_floor).
({String? rule, Map<String, double> floors}) ruleFloor(List<double> x,
    {double restHfRatio = 0.2, double restRhythmicity = 0.2}) {
  final floors = {for (final name in AbnormalClass.all) name: 0.0};
  String? rule;
  final headHz = x[_w.headDominantHz];
  final rhythm = x[_w.headRhythmicity];
  final sustained = x[_w.sustainedSeconds];
  final yawRange = x[_w.headYawRange];
  final flowHf = x[_w.flowHfRatioMean];
  final flowMean = x[_w.flowMagMeanMean];
  final jerk = x[_w.faceJerkRms];
  final hold = x[_w.holdFraction];
  final peak = x[_w.peakAmplitude];
  if (headHz >= 2.5 &&
      headHz <= 6.5 &&
      rhythm > math.max(0.45, restRhythmicity + 0.25) &&
      sustained >= 1.5 &&
      yawRange >= 8.0) {
    floors[AbnormalClass.possibleSeizureLike] = 0.85;
    rule = 'sustained_rhythmic_high_amplitude';
  } else if (flowHf > math.max(0.55, restHfRatio + 0.3) && yawRange < 6.0 && flowMean > 0.03) {
    floors[AbnormalClass.involuntary] = 0.6;
    rule = 'high_frequency_low_amplitude';
  } else if (jerk > 0.0 &&
      peak > 0.0 &&
      hold < 0.15 &&
      x[_w.onsetCount] <= 2 &&
      yawRange >= 12.0 &&
      x[_w.headAngularSpeedMax] >= 120.0) {
    floors[AbnormalClass.possibleSpasm] = 0.6;
    rule = 'high_jerk_no_hold';
  }
  return (rule: rule, floors: floors);
}

class AbnormalRuntime {
  AbnormalRuntime._(this.forest, this.restHfRatio, this.restRhythmicity);

  final TreeEnsembleRuntime forest;
  double restHfRatio;
  double restRhythmicity;

  factory AbnormalRuntime.fromJson(Map<String, dynamic> spec) {
    final floor = (spec['rule_floor'] as Map<String, dynamic>?) ?? const {};
    return AbnormalRuntime._(
      TreeEnsembleRuntime.fromJson(spec['forest'] as Map<String, dynamic>),
      (floor['rest_hf_ratio'] as num?)?.toDouble() ?? 0.2,
      (floor['rest_rhythmicity'] as num?)?.toDouble() ?? 0.2,
    );
  }

  AbnormalPrediction predict(List<double> features) {
    final proba = forest.predictProba(features);
    final probabilities = <String, double>{
      for (var i = 0; i < forest.classes.length; i++) forest.classes[i]: proba[i],
    };
    final floor = ruleFloor(features, restHfRatio: restHfRatio, restRhythmicity: restRhythmicity);
    final merged = <String, double>{
      for (final name in AbnormalClass.all)
        name: math.max(probabilities[name] ?? 0.0, floor.floors[name] ?? 0.0),
    };
    var total = merged.values.fold<double>(0, (a, b) => a + b);
    if (total == 0) total = 1.0;
    merged.updateAll((_, v) => v / total);
    var best = AbnormalClass.normalVoluntary;
    merged.forEach((name, value) {
      if (value > merged[best]!) best = name;
    });
    return AbnormalPrediction(label: best, probabilities: merged, ruleTriggered: floor.rule);
  }
}

List<double> _doubles(Object? raw) =>
    (raw as List).map((v) => (v as num).toDouble()).toList(growable: false);

/// The exported model bundle shipped as Flutter assets.
class IntentModelBundle {
  IntentModelBundle({
    required this.manifest,
    required this.intent,
    required this.temporal,
    required this.abnormal,
  });

  final Map<String, dynamic> manifest;
  final IntentRuntime intent;
  final TemporalCnnRuntime temporal;
  final AbnormalRuntime abnormal;

  static const defaultAssetDir = 'assets/models/intent_bundle_v1';

  static Future<IntentModelBundle> loadFromAssets({
    String directory = defaultAssetDir,
    AssetBundle? bundle,
  }) async {
    final assets = bundle ?? rootBundle;
    final manifest =
        jsonDecode(await assets.loadString('$directory/manifest.json')) as Map<String, dynamic>;
    return fromJson(
      manifest: manifest,
      loadFile: (name) async =>
          jsonDecode(await assets.loadString('$directory/$name')) as Map<String, dynamic>,
    );
  }

  static Future<IntentModelBundle> fromJson({
    required Map<String, dynamic> manifest,
    required Future<Map<String, dynamic>> Function(String name) loadFile,
  }) async {
    if (manifest['schema_version'] != kBundleSchemaVersion) {
      throw const FormatException('unsupported model bundle schema');
    }
    final frameFeatures = (manifest['frame_features'] as List).cast<String>();
    if (frameFeatures.length != kFrameFeatures.length ||
        !_sameList(frameFeatures, kFrameFeatures)) {
      throw const FormatException('bundle frame schema differs from the app schema');
    }
    final files = manifest['files'] as Map<String, dynamic>;
    return IntentModelBundle(
      manifest: manifest,
      intent: IntentRuntime.fromJson(await loadFile(files['intent_json'] as String)),
      temporal: TemporalCnnRuntime.fromJson(await loadFile(files['temporal_json'] as String)),
      abnormal: AbnormalRuntime.fromJson(await loadFile(files['abnormal_json'] as String)),
    );
  }

  static bool _sameList(List<String> a, List<String> b) {
    for (var i = 0; i < a.length; i++) {
      if (a[i] != b[i]) return false;
    }
    return true;
  }
}

// Cross-language parity: the Dart runtime must reproduce the Python reference
// implementation. Fixtures come from services/intent/tools/export_dart_fixtures.py.

import 'dart:convert';
import 'dart:io';

import 'package:fingerspeak_mobile/intent/intent_runtimes.dart';
import 'package:fingerspeak_mobile/intent/intent_schema.dart';
import 'package:fingerspeak_mobile/intent/temporal_cnn.dart';
import 'package:fingerspeak_mobile/intent/verification_engine.dart';
import 'package:fingerspeak_mobile/intent/window_features.dart';
import 'package:flutter_test/flutter_test.dart';

Map<String, dynamic> _fixture() {
  final file = File('test/fixtures/intent_parity.json');
  return jsonDecode(file.readAsStringSync()) as Map<String, dynamic>;
}

List<double> _doubles(Object? raw) => (raw as List).map((v) => (v as num).toDouble()).toList();

void main() {
  final fixture = _fixture();

  test('window features match the Python reference within 1e-6', () {
    for (final raw in fixture['window_cases'] as List) {
      final c = raw as Map<String, dynamic>;
      final timestamps = _doubles(c['timestamps']);
      final frames = (c['frames'] as List).asMap().entries.map((e) => IntentFrame(timestamps[e.key], _doubles(e.value))).toList();
      final openEar = (c['open_ear'] as num?)?.toDouble();
      final actual = windowFeatures(frames, openEar: openEar);
      final expected = _doubles(c['expected']);
      expect(actual.length, expected.length, reason: c['name'] as String);
      final names = windowFeatureNames();
      for (var i = 0; i < expected.length; i++) {
        final tolerance = 1e-6 * (1 + expected[i].abs());
        expect(actual[i], closeTo(expected[i], tolerance), reason: '${c['name']} / ${names[i]}');
      }
    }
  });

  test('forest, OOD gate and rule floor match the Python runtimes', () {
    final intent = IntentRuntime.fromJson(fixture['intent_spec'] as Map<String, dynamic>);
    final abnormal = AbnormalRuntime.fromJson(fixture['abnormal_spec'] as Map<String, dynamic>);
    for (final raw in fixture['forest_cases'] as List) {
      final c = raw as Map<String, dynamic>;
      final features = _doubles(c['features']);
      final expectedIntent = c['intent'] as Map<String, dynamic>;
      final prediction = intent.predict(features);
      expect(prediction.label, expectedIntent['label']);
      expect(prediction.pIntentional, closeTo((expectedIntent['p_intentional'] as num).toDouble(), 1e-9));
      expect(prediction.oodRatio, closeTo((expectedIntent['ood_ratio'] as num).toDouble(), 1e-9));
      final expectedAbnormal = c['abnormal'] as Map<String, dynamic>;
      final ab = abnormal.predict(features);
      expect(ab.label, expectedAbnormal['label']);
      expect(ab.ruleTriggered, expectedAbnormal['rule_triggered']);
      final probabilities = expectedAbnormal['probabilities'] as Map<String, dynamic>;
      for (final name in AbnormalClass.all) {
        expect(ab.probabilities[name], closeTo((probabilities[name] as num).toDouble(), 1e-9), reason: name);
      }
    }
  });

  test('temporal CNN evaluator matches the NumPy reference', () {
    final runtime = TemporalCnnRuntime.fromJson(fixture['temporal_spec'] as Map<String, dynamic>);
    expect(runtime.classes, CommandClass.all);
    for (final raw in fixture['temporal_cases'] as List) {
      final c = raw as Map<String, dynamic>;
      final sequence = (c['sequence'] as List).map(_doubles).toList();
      final actual = runtime.predictProba(sequence);
      final expected = _doubles(c['expected']);
      for (var i = 0; i < expected.length; i++) {
        expect(actual[i], closeTo(expected[i], 1e-9));
      }
    }
  });

  test('confidence fusion matches Python', () {
    for (final raw in fixture['fusion_cases'] as List) {
      final c = raw as Map<String, dynamic>;
      final actual = fuseConfidence(
        pCommand: (c['p_command'] as num).toDouble(),
        pIntentional: (c['p_intentional'] as num).toDouble(),
        intentLabel: c['intent_label'] as String,
        pPrototype: (c['p_prototype'] as num).toDouble(),
        pAbnormal: (c['p_abnormal'] as num).toDouble(),
        prototypeWeight: (c['prototype_weight'] as num).toDouble(),
      );
      expect(actual, closeTo((c['expected'] as num).toDouble(), 1e-9));
    }
  });
}

import 'dart:math';

import 'utils.dart';

double? mean(Iterable<num> values) {
  final list = values.map((value) => value.toDouble()).where((value) => value.isFinite).toList();
  if (list.isEmpty) return null;
  return list.reduce((a, b) => a + b) / list.length;
}

double? percentile(Iterable<num> values, double quantile) {
  final list = values.map((value) => value.toDouble()).where((value) => value.isFinite).toList()..sort();
  if (list.isEmpty) return null;
  if (list.length == 1) return list.first;
  final position = clampDouble(quantile, 0, 1) * (list.length - 1);
  final lower = position.floor();
  final upper = position.ceil();
  if (lower == upper) return list[lower];
  final weight = position - lower;
  return list[lower] * (1 - weight) + list[upper] * weight;
}

Map<String, dynamic> distribution(Iterable<num> values) {
  final list = values.map((value) => value.toDouble()).where((value) => value.isFinite).toList();
  return <String, dynamic>{
    'count': list.length,
    'mean': mean(list),
    'median': percentile(list, 0.5),
    'p5': percentile(list, 0.05),
    'p95': percentile(list, 0.95),
    'min': list.isEmpty ? null : list.reduce(min),
    'max': list.isEmpty ? null : list.reduce(max),
  };
}

Map<String, dynamic> wilsonInterval(int successes, int total, {double z = 1.959963984540054}) {
  if (total <= 0) return <String, dynamic>{'lower': null, 'upper': null, 'method': 'Wilson 95%'};
  final n = total.toDouble();
  final p = successes / n;
  final z2 = z * z;
  final denominator = 1 + z2 / n;
  final center = (p + z2 / (2 * n)) / denominator;
  final margin = z * sqrt((p * (1 - p) / n) + (z2 / (4 * n * n))) / denominator;
  return <String, dynamic>{
    'lower': max(0.0, center - margin),
    'upper': min(1.0, center + margin),
    'method': 'Wilson 95%',
  };
}

Map<String, dynamic> pairedDifferenceInterval(List<double> differences) {
  if (differences.isEmpty) {
    return <String, dynamic>{'lower': null, 'upper': null, 'method': 'paired normal 95%'};
  }
  final estimate = mean(differences)!;
  if (differences.length == 1) {
    return <String, dynamic>{'lower': null, 'upper': null, 'method': 'paired normal 95% (n<2)'};
  }
  final variance = differences
          .map((value) => pow(value - estimate, 2).toDouble())
          .reduce((a, b) => a + b) /
      (differences.length - 1);
  final margin = 1.959963984540054 * sqrt(variance / differences.length);
  return <String, dynamic>{
    'lower': max(-1.0, estimate - margin),
    'upper': min(1.0, estimate + margin),
    'method': 'paired normal 95%',
  };
}

Map<String, dynamic> unpairedDifferenceInterval(int baseCorrect, int baseN, int calibratedCorrect, int calibratedN) {
  if (baseN <= 0 || calibratedN <= 0) {
    return <String, dynamic>{'lower': null, 'upper': null, 'method': 'Newcombe-Wilson 95%'};
  }
  final p0 = baseCorrect / baseN;
  final p1 = calibratedCorrect / calibratedN;
  final delta = p1 - p0;
  final baseInterval = wilsonInterval(baseCorrect, baseN);
  final calibratedInterval = wilsonInterval(calibratedCorrect, calibratedN);
  final baseLower = baseInterval['lower'] as double;
  final baseUpper = baseInterval['upper'] as double;
  final calibratedLower = calibratedInterval['lower'] as double;
  final calibratedUpper = calibratedInterval['upper'] as double;
  // Newcombe's score-based interval for the difference between two
  // independent proportions. It behaves much better than a Wald interval at
  // small n and near 0%/100%, both common in gesture-validation pilots.
  final lowerMargin = sqrt(pow(p1 - calibratedLower, 2) + pow(baseUpper - p0, 2));
  final upperMargin = sqrt(pow(calibratedUpper - p1, 2) + pow(p0 - baseLower, 2));
  return <String, dynamic>{
    'lower': max(-1.0, delta - lowerMargin),
    'upper': min(1.0, delta + upperMargin),
    'method': 'Newcombe-Wilson 95%',
  };
}

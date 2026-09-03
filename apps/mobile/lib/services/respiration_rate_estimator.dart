import 'dart:math' as math;

import 'package:flutter/foundation.dart';

/// A camera-motion estimate of respiratory rate.
///
/// This deliberately returns no value until a sufficiently long, periodic
/// signal is present. It must not be presented as a clinical vital sign.
@immutable
class RespirationEstimate {
  const RespirationEstimate({
    required this.breathsPerMinute,
    required this.confidence,
    required this.observationDuration,
  });

  final double breathsPerMinute;
  final double confidence;
  final Duration observationDuration;
}

class RespirationRateEstimator {
  RespirationRateEstimator({
    this.window = const Duration(seconds: 30),
    this.minimumObservation = const Duration(seconds: 12),
    this.minimumSamples = 48,
    this.minimumSignalRms = 0.00020,
    this.minimumPeriodicFit = 0.22,
  });

  final Duration window;
  final Duration minimumObservation;
  final int minimumSamples;
  final double minimumSignalRms;
  final double minimumPeriodicFit;

  final List<_RespirationSample> _samples = <_RespirationSample>[];
  double? _smoothedRate;
  DateTime? _lastEvaluatedAt;
  RespirationEstimate? _cachedEstimate;

  RespirationEstimate? addSample({
    required DateTime observedAt,
    required double verticalPosition,
  }) {
    if (!verticalPosition.isFinite) return null;
    if (_samples.isNotEmpty) {
      final gap = observedAt.difference(_samples.last.observedAt);
      if (gap <= Duration.zero) return currentEstimate;
      if (gap > const Duration(seconds: 2)) clear();
      if (_samples.isNotEmpty && gap < const Duration(milliseconds: 70)) {
        return currentEstimate;
      }
    }

    _samples.add(_RespirationSample(observedAt, verticalPosition));
    final cutoff = observedAt.subtract(window);
    _samples.removeWhere((sample) => sample.observedAt.isBefore(cutoff));
    return _calculate();
  }

  RespirationEstimate? get currentEstimate => _calculate();

  void clear() {
    _samples.clear();
    _smoothedRate = null;
    _lastEvaluatedAt = null;
    _cachedEstimate = null;
  }

  RespirationEstimate? _calculate() {
    if (_samples.isEmpty) return null;
    final latest = _samples.last.observedAt;
    if (_lastEvaluatedAt == latest) return _cachedEstimate;
    _lastEvaluatedAt = latest;
    _cachedEstimate = _calculateCurrentSamples();
    return _cachedEstimate;
  }

  RespirationEstimate? _calculateCurrentSamples() {
    if (_samples.length < minimumSamples) return null;
    final first = _samples.first.observedAt;
    final duration = _samples.last.observedAt.difference(first);
    if (duration < minimumObservation) return null;

    final times = _samples
        .map((sample) =>
            sample.observedAt.difference(first).inMicroseconds / 1000000.0)
        .toList(growable: false);
    final values =
        _samples.map((sample) => sample.value).toList(growable: false);
    final count = values.length;
    final meanTime = times.reduce((a, b) => a + b) / count;
    final meanValue = values.reduce((a, b) => a + b) / count;
    var covariance = 0.0;
    var timeVariance = 0.0;
    for (var index = 0; index < count; index++) {
      final centeredTime = times[index] - meanTime;
      covariance += centeredTime * (values[index] - meanValue);
      timeVariance += centeredTime * centeredTime;
    }
    final slope = timeVariance == 0 ? 0.0 : covariance / timeVariance;
    final residuals = List<double>.generate(
      count,
      (index) =>
          values[index] - (meanValue + slope * (times[index] - meanTime)),
      growable: false,
    );
    final totalEnergy =
        residuals.fold<double>(0, (sum, value) => sum + value * value);
    final rms = math.sqrt(totalEnergy / count);
    if (!rms.isFinite || rms < minimumSignalRms) {
      _smoothedRate = null;
      return null;
    }

    var bestRate = 0.0;
    var bestFit = 0.0;
    // Search beyond the displayed range so an out-of-range peak is rejected,
    // not accidentally clipped to the nearest reportable boundary.
    for (var rate = 3.0; rate <= 60.0; rate += 0.25) {
      final angularFrequency = 2 * math.pi * (rate / 60);
      var sineProjection = 0.0;
      var cosineProjection = 0.0;
      var sineEnergy = 0.0;
      var cosineEnergy = 0.0;
      var crossEnergy = 0.0;
      for (var index = 0; index < count; index++) {
        final phase = angularFrequency * times[index];
        final sine = math.sin(phase);
        final cosine = math.cos(phase);
        sineProjection += residuals[index] * sine;
        cosineProjection += residuals[index] * cosine;
        sineEnergy += sine * sine;
        cosineEnergy += cosine * cosine;
        crossEnergy += sine * cosine;
      }
      final determinant = sineEnergy * cosineEnergy - crossEnergy * crossEnergy;
      if (determinant <= 0.000001) continue;
      // Solve both sinusoidal coefficients together; irregular timestamps
      // mean the sine/cosine basis vectors are not necessarily orthogonal.
      final sineCoefficient =
          (sineProjection * cosineEnergy - cosineProjection * crossEnergy) /
              determinant;
      final cosineCoefficient =
          (cosineProjection * sineEnergy - sineProjection * crossEnergy) /
              determinant;
      final fittedEnergy =
          sineCoefficient * sineProjection + cosineCoefficient * cosineProjection;
      final fit = (fittedEnergy / totalEnergy).clamp(0.0, 1.0);
      if (fit > bestFit) {
        bestFit = fit;
        bestRate = rate;
      }
    }

    // Use the lower whole-rate bin for readiness. A 6/min trace can briefly
    // fit at 6.25/min; that must not unlock a rate before a 20-second window.
    final readinessRate = bestRate.floorToDouble();
    final observedCycles = duration.inMicroseconds /
        Duration.microsecondsPerSecond *
        readinessRate /
        60;
    if (bestFit < minimumPeriodicFit ||
        bestRate < 6 ||
        bestRate > 40 ||
        observedCycles < 2) {
      _smoothedRate = null;
      return null;
    }
    _smoothedRate = _smoothedRate == null
        ? bestRate
        : _smoothedRate! * 0.72 + bestRate * 0.28;
    return RespirationEstimate(
      breathsPerMinute: _smoothedRate!,
      confidence: ((bestFit - minimumPeriodicFit) /
              math.max(1 - minimumPeriodicFit, 0.01))
          .clamp(0.0, 1.0),
      observationDuration: duration,
    );
  }
}

@immutable
class _RespirationSample {
  const _RespirationSample(this.observedAt, this.value);

  final DateTime observedAt;
  final double value;
}

import 'dart:math' as math;

import 'package:fingerspeak_mobile/services/respiration_rate_estimator.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  RespirationEstimate? feedSine({
    required double breathsPerMinute,
    double amplitude = 0.0025,
    Duration duration = const Duration(seconds: 26),
  }) {
    final estimator = RespirationRateEstimator();
    final start = DateTime.utc(2026, 9, 2, 12);
    RespirationEstimate? result;
    const interval = Duration(milliseconds: 100);
    final samples = duration.inMilliseconds ~/ interval.inMilliseconds;
    for (var index = 0; index <= samples; index++) {
      final seconds = index * interval.inMilliseconds / 1000;
      final periodic =
          amplitude * math.sin(2 * math.pi * (breathsPerMinute / 60) * seconds);
      final slowDrift = seconds * 0.000015;
      final deterministicJitter =
          index % 7 == 0 ? 0.00008 : (index % 5 == 0 ? -0.00006 : 0);
      result = estimator.addSample(
        observedAt: start.add(interval * index),
        verticalPosition: 0.5 + periodic + slowDrift + deterministicJitter,
      );
    }
    return result;
  }

  for (final rate in <double>[12, 20, 28]) {
    test('estimates a $rate breaths/min periodic camera trace', () {
      final estimate = feedSine(breathsPerMinute: rate);
      expect(estimate, isNotNull);
      expect(estimate!.breathsPerMinute, closeTo(rate, 1.0));
      expect(estimate.confidence, greaterThan(0.45));
    });
  }

  for (final rate in <double>[4, 50]) {
    test('rejects a $rate breaths/min trace instead of clipping to a boundary',
        () {
      final estimate = feedSine(
        breathsPerMinute: rate,
        duration: const Duration(seconds: 45),
      );
      expect(estimate, isNull);
    });
  }

  test('a six breaths/min trace requires at least two observed cycles', () {
    final estimator = RespirationRateEstimator();
    final start = DateTime.utc(2026, 9, 3, 12);
    RespirationEstimate? estimate;
    for (var index = 0; index <= 300; index++) {
      final seconds = index / 10.0;
      estimate = estimator.addSample(
        observedAt: start.add(Duration(milliseconds: index * 100)),
        verticalPosition:
            0.5 + 0.0025 * math.sin(2 * math.pi * (6 / 60) * seconds),
      );
      if (index < 200) {
        expect(estimate, isNull,
            reason:
                'A six/min trace has not completed two cycles at ${seconds}s.');
      }
    }
    expect(estimate, isNotNull);
    expect(estimate!.breathsPerMinute, closeTo(6, 0.75));
    expect(estimate.observationDuration,
        greaterThanOrEqualTo(const Duration(seconds: 20)));
  });

  test('reports no rate before the quality window is complete', () {
    final estimate = feedSine(
      breathsPerMinute: 16,
      duration: const Duration(seconds: 8),
    );
    expect(estimate, isNull);
  });

  test('cached reads and rejected timestamps do not advance an estimate', () {
    final estimator = RespirationRateEstimator();
    final start = DateTime.utc(2026, 9, 2, 12);
    for (var index = 0; index <= 260; index++) {
      final seconds = index / 10.0;
      estimator.addSample(
        observedAt: start.add(Duration(milliseconds: index * 100)),
        verticalPosition:
            0.5 + 0.0025 * math.sin(2 * math.pi * (18 / 60) * seconds),
      );
    }
    final cached = estimator.currentEstimate;
    expect(cached, isNotNull);

    for (var index = 0; index < 20; index++) {
      expect(estimator.currentEstimate, same(cached));
    }
    for (final offset in <Duration>[
      const Duration(seconds: 25),
      const Duration(seconds: 26),
      const Duration(seconds: 26, milliseconds: 40),
    ]) {
      expect(
        estimator.addSample(
          observedAt: start.add(offset),
          verticalPosition: 0.9,
        ),
        same(cached),
      );
    }
    expect(cached!.observationDuration, const Duration(seconds: 26));
    expect(estimator.currentEstimate, same(cached));
  });

  test('clear removes cached rate and restarts the quality window', () {
    final estimator = RespirationRateEstimator();
    final start = DateTime.utc(2026, 9, 2, 12);
    for (var index = 0; index <= 260; index++) {
      final seconds = index / 10.0;
      estimator.addSample(
        observedAt: start.add(Duration(milliseconds: index * 100)),
        verticalPosition:
            0.5 + 0.0025 * math.sin(2 * math.pi * (12 / 60) * seconds),
      );
    }
    expect(estimator.currentEstimate, isNotNull);
    estimator.clear();
    expect(estimator.currentEstimate, isNull);

    final restartedAt = start.add(const Duration(minutes: 1));
    RespirationEstimate? estimate;
    for (var index = 0; index <= 260; index++) {
      final seconds = index / 10.0;
      estimate = estimator.addSample(
        observedAt: restartedAt.add(Duration(milliseconds: index * 100)),
        verticalPosition:
            0.5 + 0.0025 * math.sin(2 * math.pi * (28 / 60) * seconds),
      );
      if (index <= 80) expect(estimate, isNull);
    }
    expect(estimate, isNotNull);
    expect(estimate!.breathsPerMinute, closeTo(28, 1.0));
  });

  test('rejects flat camera noise instead of fabricating 16 bpm', () {
    final estimator = RespirationRateEstimator();
    final start = DateTime.utc(2026, 9, 2, 12);
    RespirationEstimate? estimate;
    for (var index = 0; index < 260; index++) {
      estimate = estimator.addSample(
        observedAt: start.add(Duration(milliseconds: index * 100)),
        verticalPosition: 0.5 + (index.isEven ? 0.00001 : -0.00001),
      );
    }
    expect(estimate, isNull);
  });

  test('a long frame gap resets the observation window', () {
    final estimator = RespirationRateEstimator();
    final start = DateTime.utc(2026, 9, 2, 12);
    for (var index = 0; index < 130; index++) {
      final seconds = index / 10;
      estimator.addSample(
        observedAt: start.add(Duration(milliseconds: index * 100)),
        verticalPosition:
            0.5 + 0.002 * math.sin(2 * math.pi * (18 / 60) * seconds),
      );
    }
    final afterGap = estimator.addSample(
      observedAt: start.add(const Duration(seconds: 20)),
      verticalPosition: 0.5,
    );
    expect(afterGap, isNull);
  });

  test('estimates a periodic trace with irregular camera timestamps', () {
    final estimator = RespirationRateEstimator();
    final start = DateTime.utc(2026, 9, 2, 12);
    const expectedRate = 18.5;
    const intervalsMs = <int>[83, 117, 94, 132, 76, 108, 91, 126];
    var elapsedMs = 0;
    var index = 0;
    RespirationEstimate? estimate;

    while (elapsedMs <= 26000) {
      final seconds = elapsedMs / 1000.0;
      final signal =
          0.0025 * math.sin(2 * math.pi * (expectedRate / 60) * seconds);
      final deterministicNoise =
          (index % 11 - 5) * 0.000012 + (index.isEven ? 0.000025 : -0.000025);
      estimate = estimator.addSample(
        observedAt: start.add(Duration(milliseconds: elapsedMs)),
        verticalPosition: 0.5 + signal + deterministicNoise,
      );
      elapsedMs += intervalsMs[index % intervalsMs.length];
      index++;
    }

    expect(estimate, isNotNull);
    expect(estimate!.breathsPerMinute, closeTo(expectedRate, 1.25));
    expect(estimate.confidence, greaterThan(0.35));
  });

  test('rejects high-amplitude non-periodic camera motion', () {
    final estimator = RespirationRateEstimator();
    final start = DateTime.utc(2026, 9, 2, 12);
    var state = 0x12345;
    RespirationEstimate? estimate;

    for (var index = 0; index <= 260; index++) {
      state = (1103515245 * state + 12345) & 0x7fffffff;
      final unitNoise = state / 0x7fffffff - 0.5;
      estimate = estimator.addSample(
        observedAt: start.add(Duration(milliseconds: index * 100)),
        verticalPosition: 0.5 + unitNoise * 0.006,
      );
    }

    expect(estimate, isNull);
  });

  test('an isolated face-position jump does not fabricate a rate', () {
    final estimator = RespirationRateEstimator();
    final start = DateTime.utc(2026, 9, 2, 12);
    RespirationEstimate? estimate;

    for (var index = 0; index <= 260; index++) {
      final jump = index == 125 ? 0.025 : 0.0;
      final sensorNoise = index.isEven ? 0.00003 : -0.00003;
      estimate = estimator.addSample(
        observedAt: start.add(Duration(milliseconds: index * 100)),
        verticalPosition: 0.5 + jump + sensorNoise,
      );
    }

    expect(estimate, isNull);
  });
}

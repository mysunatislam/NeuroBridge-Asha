import 'dart:math' as math;

import 'package:fingerspeak_mobile/models/patient_signal.dart';
import 'package:fingerspeak_mobile/services/patient_signal_monitor.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('face sensitivity changes the detector threshold monotonically', () {
    final lowSensitivity = sensitivityAdjustedThreshold(16, 0.40);
    final standardSensitivity = sensitivityAdjustedThreshold(16, 0.75);
    final highSensitivity = sensitivityAdjustedThreshold(16, 0.95);

    expect(lowSensitivity, greaterThan(standardSensitivity));
    expect(highSensitivity, lessThan(standardSensitivity));
    expect(standardSensitivity, closeTo(16, 0.25));
  });

  test('blink closure threshold decreases as sensitivity increases', () {
    final low = blinkClosureThreshold(0.40);
    final standard = blinkClosureThreshold(0.75);
    final high = blinkClosureThreshold(0.95);
    expect(low, greaterThan(standard));
    expect(standard, greaterThan(high));
    for (final threshold in [low, standard, high]) {
      expect(threshold, inInclusiveRange(0.35, 0.78));
    }
  });

  group('experimental contour motion consistency', () {
    final start = DateTime.utc(2026, 9, 3, 12);
    final timestamps = List<DateTime>.generate(
      81,
      (index) => start.add(Duration(milliseconds: index * 50)),
    );
    final regular = List<double>.generate(
      timestamps.length,
      (index) => 0.1 + 0.004 * math.sin(2 * math.pi * 1.5 * index * 0.05),
    );

    test('accepts regular 1.5 Hz contour movement', () {
      expect(isConsistentMicroMovement(regular, timestamps), isTrue);
    });

    test('rejects stationary data and gradual pose drift', () {
      expect(
        isConsistentMicroMovement(
            List.filled(timestamps.length, 0.1), timestamps),
        isFalse,
      );
      expect(
        isConsistentMicroMovement(
          List.generate(timestamps.length, (index) => 0.1 + index * 0.0001),
          timestamps,
        ),
        isFalse,
      );
    });

    test('rejects a short observation even with enough samples', () {
      expect(
        isConsistentMicroMovement(
            regular.sublist(0, 40), timestamps.sublist(0, 40)),
        isFalse,
      );
    });

    test('rejects a dropped-frame gap inside an otherwise regular trace', () {
      final withGap = List<DateTime>.generate(
        timestamps.length,
        (index) => timestamps[index].add(
          Duration(milliseconds: index >= 40 ? 600 : 0),
        ),
      );
      expect(isConsistentMicroMovement(regular, withGap), isFalse);
    });

    test('rejects duplicate and out-of-order observations', () {
      for (final offset in [Duration.zero, const Duration(milliseconds: -50)]) {
        final invalidTimes = List<DateTime>.of(timestamps);
        invalidTimes[40] = invalidTimes[39].add(offset);
        expect(isConsistentMicroMovement(regular, invalidTimes), isFalse);
      }
    });

    test('rejects uneven cycle timing rather than calling it repeated motion',
        () {
      const periods = <double>[0.4, 1.1, 0.4, 1.2, 0.4, 1.1];
      final irregularTimes = List<DateTime>.generate(
        93,
        (index) => start.add(Duration(milliseconds: index * 50)),
      );
      final irregular = List<double>.generate(irregularTimes.length, (index) {
        var withinCycle = index * 0.05;
        var periodIndex = 0;
        while (periodIndex < periods.length - 1 &&
            withinCycle >= periods[periodIndex]) {
          withinCycle -= periods[periodIndex];
          periodIndex++;
        }
        return 0.1 +
            0.004 * math.sin(2 * math.pi * withinCycle / periods[periodIndex]);
      });
      expect(isConsistentMicroMovement(irregular, irregularTimes), isFalse);
    });

    test('rejects nonfinite values and incomplete timestamp data', () {
      for (final invalid in [
        double.nan,
        double.infinity,
        double.negativeInfinity
      ]) {
        final invalidValues = List<double>.of(regular);
        invalidValues[40] = invalid;
        expect(isConsistentMicroMovement(invalidValues, timestamps), isFalse);
      }
      expect(
          isConsistentMicroMovement(regular, timestamps.sublist(1)), isFalse);
      expect(isConsistentMicroMovement([], []), isFalse);
    });
  });

  test('monitor exposes its latest status to screens opened later', () async {
    final monitor = NoOpPatientSignalMonitor();
    expect(monitor.currentStatus.lifecycle, MonitorLifecycle.stopped);
    await monitor.start();
    expect(monitor.currentStatus.lifecycle, MonitorLifecycle.active);
    expect(monitor.currentStatus.faceDetected, isTrue);
    await monitor.stop();
    expect(monitor.currentStatus.lifecycle, MonitorLifecycle.stopped);
    await monitor.dispose();
  });

  test('stability gate rejects spikes and confirms a held signal', () {
    final gate = SignalStabilityGate();
    final start = DateTime.utc(2026, 8, 25, 12);

    expect(
      gate.update(
        kind: PatientSignalKind.mouthOpen,
        score: 1,
        confidence: 0.9,
        observedAt: start,
        enterThreshold: 0.8,
        exitThreshold: 0.5,
        minimumHold: const Duration(milliseconds: 300),
      ),
      isNull,
    );
    expect(
      gate.update(
        kind: PatientSignalKind.mouthOpen,
        score: 0,
        confidence: 0,
        observedAt: start.add(const Duration(milliseconds: 200)),
        enterThreshold: 0.8,
        exitThreshold: 0.5,
        minimumHold: const Duration(milliseconds: 300),
      ),
      isNull,
    );

    final restarted = start.add(const Duration(seconds: 1));
    for (final milliseconds in [0, 100, 200]) {
      expect(
        gate.update(
          kind: PatientSignalKind.mouthOpen,
          score: 0.9,
          confidence: 0.85,
          observedAt: restarted.add(Duration(milliseconds: milliseconds)),
          enterThreshold: 0.8,
          exitThreshold: 0.5,
          minimumHold: const Duration(milliseconds: 300),
        ),
        isNull,
      );
    }
    final confirmed = gate.update(
      kind: PatientSignalKind.mouthOpen,
      score: 0.9,
      confidence: 0.85,
      observedAt: restarted.add(const Duration(milliseconds: 300)),
      enterThreshold: 0.8,
      exitThreshold: 0.5,
      minimumHold: const Duration(milliseconds: 300),
    );
    expect(confirmed, isNotNull);
    expect(confirmed!.activeDuration, const Duration(milliseconds: 300));
  });

  test('stability gate uses hysteresis and requires release before rearming',
      () {
    final gate = SignalStabilityGate();
    final start = DateTime.utc(2026, 8, 25, 12);

    StableSignalObservation? update(int milliseconds, double score) =>
        gate.update(
          kind: PatientSignalKind.smile,
          score: score,
          confidence: 0.9,
          observedAt: start.add(Duration(milliseconds: milliseconds)),
          enterThreshold: 0.8,
          exitThreshold: 0.5,
          minimumHold: const Duration(milliseconds: 200),
        );

    expect(update(0, 0.9), isNull);
    expect(update(100, 0.6), isNull);
    expect(update(200, 0.6), isNotNull);
    expect(update(2100, 0.9), isNull,
        reason: 'one hold must stop reporting after the bounded window');
    expect(update(2200, 0.1), isNull);
    expect(update(2400, 0.1), isNull);
    expect(update(2500, 0.9), isNull);
    expect(update(2700, 0.9), isNotNull);
  });

  test('oscillation analysis rejects drift and accepts alternating motion', () {
    final drift = analyzeOscillation(
      List<double>.generate(12, (index) => index * 0.001),
    );
    final tremor = analyzeOscillation(
      List<double>.generate(
        12,
        (index) => index.isEven ? -0.004 : 0.004,
      ),
    );

    expect(drift.detrendedRms, lessThan(0.0001));
    expect(drift.directionChanges, 0);
    expect(tremor.detrendedRms, greaterThan(0.0015));
    expect(tremor.peakToPeak, greaterThan(0.0045));
    expect(tremor.directionChanges, greaterThanOrEqualTo(3));
  });

  test('head motion smoothing separates pose jitter from rapid movement', () {
    final filter = HeadMotionFilter();
    final start = DateTime.utc(2026, 8, 25, 12);
    expect(filter.add(0, 0, start), isNull);
    final jitter = filter.add(
      1,
      -0.5,
      start.add(const Duration(milliseconds: 100)),
    );
    final rapid = filter.add(
      22,
      0,
      start.add(const Duration(milliseconds: 200)),
    );

    expect(jitter, isNotNull);
    expect(jitter!.velocityDegreesPerSecond, lessThan(20));
    expect(rapid, isNotNull);
    expect(rapid!.frameDisplacementDegrees, greaterThan(5.5));
    expect(rapid.velocityDegreesPerSecond, greaterThan(75));
  });

  test('head motion does not turn a dropped-frame gap into a rapid gesture',
      () {
    final filter = HeadMotionFilter();
    final start = DateTime.utc(2026, 9, 3, 12);
    expect(filter.add(0, 0, start), isNull);
    expect(
      filter.add(35, -20, start.add(const Duration(seconds: 1))),
      isNull,
      reason: 'A gap longer than the tracking window must reinitialize pose.',
    );
    final afterGap = filter.add(
      35.5,
      -20.2,
      start.add(const Duration(milliseconds: 1100)),
    );
    expect(afterGap, isNotNull);
    expect(afterGap!.velocityDegreesPerSecond, lessThan(10));
  });

  test('clearing temporal tracking requires a fresh hold before reporting', () {
    final gate = SignalStabilityGate();
    final start = DateTime.utc(2026, 9, 3, 12);
    StableSignalObservation? update(int milliseconds) => gate.update(
          kind: PatientSignalKind.eyebrowsUp,
          score: 1,
          confidence: 0.9,
          observedAt: start.add(Duration(milliseconds: milliseconds)),
          enterThreshold: 0.8,
          exitThreshold: 0.5,
          minimumHold: const Duration(milliseconds: 300),
        );

    expect(update(0), isNull);
    expect(update(300), isNotNull);
    gate.clear();
    expect(update(400), isNull);
    expect(update(600), isNull);
    final reacquired = update(700);
    expect(reacquired, isNotNull);
    expect(reacquired!.activeDuration, const Duration(milliseconds: 300));
  });
}

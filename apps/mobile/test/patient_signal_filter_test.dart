import 'package:fingerspeak_mobile/models/patient_signal.dart';
import 'package:fingerspeak_mobile/services/patient_signal_monitor.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
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
}

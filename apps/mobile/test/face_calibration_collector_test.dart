import 'package:fingerspeak_mobile/models/patient_signal.dart';
import 'package:fingerspeak_mobile/services/face_calibration_collector.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  MonitorStatus sample(
    int index, {
    DateTime? observedAt,
    double leftEye = 0.82,
    double rightEye = 0.80,
    double eyebrow = 0.10,
    double mouth = 0.045,
    double smile = 0.06,
    double yaw = 1.5,
    double pitch = -0.8,
  }) {
    return MonitorStatus(
      lifecycle: MonitorLifecycle.active,
      message: 'live',
      observedAt: observedAt ?? DateTime.utc(2026, 9, 2, 12, 0, 0, index * 20),
      faceDetected: true,
      leftEyeOpen: leftEye,
      rightEyeOpen: rightEye,
      eyebrowDistance: eyebrow,
      mouthDistance: mouth,
      smileProbability: smile,
      headYaw: yaw,
      headPitch: pitch,
    );
  }

  test('counts only unique live face observations', () {
    final collector = FaceCalibrationCollector(minimumSamples: 3);
    final first = sample(0);
    expect(collector.add(first), isTrue);
    expect(collector.add(first), isFalse);
    expect(
      collector.add(const MonitorStatus(
        lifecycle: MonitorLifecycle.active,
        message: 'missing frame timestamp',
        faceDetected: true,
        leftEyeOpen: 0.8,
        rightEyeOpen: 0.8,
        eyebrowDistance: 0.1,
        mouthDistance: 0.04,
      )),
      isFalse,
    );
    expect(collector.sampleCount, 1);
    expect(collector.build(), isNull);
  });

  test('uses robust fresh-frame values and produces a persistable baseline',
      () {
    final collector = FaceCalibrationCollector(minimumSamples: 24);
    for (var index = 0; index < 24; index++) {
      collector.add(sample(
        index,
        observedAt: DateTime.utc(2026, 9, 2, 12)
            .add(Duration(milliseconds: index * 100)),
        leftEye: index == 7 ? 0.98 : 0.82 + (index % 3 - 1) * 0.01,
        eyebrow: index == 9 ? 0.30 : 0.10 + (index % 2) * 0.002,
      ));
    }
    final baseline = collector.build();
    expect(baseline, isNotNull);
    expect(baseline!.leftEyeOpenness, closeTo(0.82, 0.02));
    expect(baseline.eyebrowDistance, closeTo(0.101, 0.01));
    expect(baseline.mouthDistance, closeTo(0.045, 0.005));
  });

  test('rejects a moving head instead of claiming calibration succeeded', () {
    final collector = FaceCalibrationCollector(minimumSamples: 24);
    for (var index = 0; index < 24; index++) {
      collector.add(sample(
        index,
        observedAt: DateTime.utc(2026, 9, 2, 12)
            .add(Duration(milliseconds: index * 100)),
        yaw: -18 + index * 1.6,
      ));
    }
    expect(collector.build(), isNull);
    expect(collector.validationMessage, contains('Head movement'));
  });

  test('rejects enough samples captured in too little time', () {
    final collector = FaceCalibrationCollector(
      minimumSamples: 24,
      minimumObservation: const Duration(seconds: 2),
    );
    final start = DateTime.utc(2026, 9, 2, 12);
    for (var index = 0; index < 24; index++) {
      collector.add(sample(
        index,
        observedAt: start.add(Duration(milliseconds: index * 20)),
      ));
    }

    expect(collector.sampleCount, 24);
    expect(collector.isReady, isFalse);
    expect(collector.build(), isNull);
    expect(collector.validationMessage, contains('too brief'));

    expect(
      collector
          .add(sample(24, observedAt: start.add(const Duration(seconds: 2)))),
      isTrue,
    );
    expect(collector.observationDuration, const Duration(seconds: 2));
    expect(collector.isReady, isTrue);
    expect(collector.build(), isNotNull);
    expect(collector.validationMessage, isNull);
  });

  test('old observations cannot inflate capture duration or frame count', () {
    final collector = FaceCalibrationCollector(minimumSamples: 3);
    final start = DateTime.utc(2026, 9, 2, 12);
    expect(collector.add(sample(0, observedAt: start)), isTrue);
    expect(
      collector
          .add(sample(1, observedAt: start.add(const Duration(seconds: 1)))),
      isTrue,
    );
    expect(
      collector.add(
          sample(2, observedAt: start.subtract(const Duration(seconds: 4)))),
      isFalse,
    );
    expect(
      collector.add(
          sample(3, observedAt: start.add(const Duration(milliseconds: 500)))),
      isFalse,
    );
    expect(collector.sampleCount, 2);
    expect(collector.observationDuration, const Duration(seconds: 1));
    expect(collector.isReady, isFalse);

    expect(
      collector
          .add(sample(4, observedAt: start.add(const Duration(seconds: 2)))),
      isTrue,
    );
    expect(collector.sampleCount, 3);
    expect(collector.isReady, isTrue);
    expect(collector.build(), isNotNull);
  });

  test('rejects smiling through a neutral-face capture', () {
    final collector = FaceCalibrationCollector(minimumSamples: 24);
    final start = DateTime.utc(2026, 9, 2, 12);
    for (var index = 0; index < 24; index++) {
      collector.add(sample(
        index,
        observedAt: start.add(Duration(milliseconds: index * 100)),
        smile: 0.78 + (index.isEven ? 0.04 : -0.04),
      ));
    }

    expect(collector.build(), isNull);
    expect(collector.validationMessage?.toLowerCase(), contains('smile'));
  });

  for (final expression in ['eyebrow', 'mouth']) {
    test('rejects $expression movement during neutral capture', () {
      final collector = FaceCalibrationCollector(minimumSamples: 24);
      final start = DateTime.utc(2026, 9, 2, 12);
      for (var index = 0; index < 24; index++) {
        final expressionActive = index >= 6 && index < 18;
        collector.add(sample(
          index,
          observedAt: start.add(Duration(milliseconds: index * 100)),
          eyebrow: expression == 'eyebrow' && expressionActive ? 0.16 : 0.09,
          mouth: expression == 'mouth' && expressionActive ? 0.13 : 0.035,
        ));
      }

      expect(collector.build(), isNull);
      expect(collector.validationMessage?.toLowerCase(), contains(expression));
    });
  }
}

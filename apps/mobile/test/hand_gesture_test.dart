import 'package:fingerspeak_mobile/services/hand_feature_extractor.dart';
import 'package:fingerspeak_mobile/services/hand_gesture_classifier.dart';
import 'package:fingerspeak_mobile/services/hand_gesture_service.dart';
import 'package:fingerspeak_mobile/services/hand_gesture_state_machine.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('Hand Feature Extractor (Port of fingerspeak.html math)', () {
    test('flattenLandmarks converts 21 3D landmarks into 63 floats', () {
      final landmarks = List.generate(
        21,
        (i) => HandLandmark(i.toDouble(), (i * 2).toDouble(), (i * 3).toDouble()),
      );
      final raw63 = flattenLandmarks(landmarks);
      expect(raw63.length, 63);
      expect(raw63[0], 0.0);
      expect(raw63[1], 0.0);
      expect(raw63[2], 0.0);
      expect(raw63[3], 1.0);
      expect(raw63[4], 2.0);
      expect(raw63[5], 3.0);
    });

    test('computeFullFeatures outputs 83 geometric features per frame', () {
      final raw63 = List<double>.filled(63, 0.0);
      raw63[5 * 3] = -0.03;
      raw63[5 * 3 + 1] = 0.08;
      raw63[9 * 3] = 0.0;
      raw63[9 * 3 + 1] = 0.1;
      raw63[17 * 3] = 0.03;
      raw63[17 * 3 + 1] = 0.07;

      final feat83 = computeFullFeatures(raw63);
      expect(feat83.length, 83);
      for (final v in feat83) {
        expect(v.isNaN, isFalse);
        expect(v.isInfinite, isFalse);
      }
    });

    test('addVelocity appends 15 velocity features to reach 98 features', () {
      final rawSeq = List.generate(
        seqLen,
        (i) => List.generate(83, (j) => (i + j).toDouble()),
      );
      final withVel = addVelocity(rawSeq);
      expect(withVel.length, seqLen);
      for (final frame in withVel) {
        expect(frame.length, 98);
      }
      expect(withVel[0].sublist(83), List.filled(15, 0.0));
      for (var k = 83; k < 98; k++) {
        expect(withVel[1][k], 1.0);
      }
    });

    test('buildModelInput converts 20 raw frames to 20x98 model input', () {
      final rawSeq = List.generate(
        seqLen,
        (i) => List.generate(63, (j) => (i * 0.01 + j * 0.001)),
      );
      final modelInput = buildModelInput(rawSeq);
      expect(modelInput.length, seqLen);
      for (final frame in modelInput) {
        expect(frame.length, 98);
      }
    });

    test('resampleSequence resamples timed frames to exactly 20 frames', () {
      final timed = List.generate(
        30,
        (i) => TimedFrame(i * 30, List.generate(63, (j) => j.toDouble())),
      );
      final resampled = resampleSequence(timed, count: 20, windowMs: 900);
      expect(resampled, isNotNull);
      expect(resampled!.length, 20);
      expect(resampled.first.length, 63);
    });

    test('augmentRaw generates varied sequences with the same length', () {
      final rawSeq = List.generate(
        seqLen,
        (i) => List.generate(63, (j) => (i * 0.02 + j * 0.01)),
      );
      final aug1 = augmentRaw(rawSeq);
      final aug2 = augmentRaw(rawSeq);
      expect(aug1.length, seqLen);
      expect(aug2.length, seqLen);
      var differ = false;
      for (var i = 0; i < seqLen; i++) {
        for (var j = 0; j < 63; j++) {
          if ((aug1[i][j] - aug2[i][j]).abs() > 1e-6) {
            differ = true;
            break;
          }
        }
      }
      expect(differ, isTrue);
    });
  });

  group('Hand Gesture Classifiers (DTW, Nearest-Prototype, OOD)', () {
    test('DTW distance between identical sequences is 0.0', () {
      final seq = List.generate(
        20,
        (i) => List.generate(98, (j) => (i * 0.1 + j * 0.05)),
      );
      final dist = dtwDistance(seq, seq);
      expect(dist, 0.0);
    });

    test('DTWClassifier classifies known gestures accurately', () {
      final dtw = DTWClassifier();
      final class0 = List.generate(
        4,
        (_) => List.generate(20, (i) => List.generate(98, (j) => 0.1 + i * 0.01)),
      );
      final class1 = List.generate(
        4,
        (_) => List.generate(20, (i) => List.generate(98, (j) => 0.8 + i * 0.01)),
      );

      dtw.train([class0, class1]);

      final q0 = List.generate(20, (i) => List.generate(98, (j) => 0.12 + i * 0.01));
      final probs0 = dtw.classify(q0);
      expect(probs0[0], greaterThan(probs0[1]));

      final q1 = List.generate(20, (i) => List.generate(98, (j) => 0.78 + i * 0.01));
      final probs1 = dtw.classify(q1);
      expect(probs1[1], greaterThan(probs1[0]));
    });

    test('NearestPrototypeClassifier classifies based on sequence mean & std', () {
      final proto = NearestPrototypeClassifier();
      final class0 = List.generate(
        4,
        (_) => List.generate(20, (i) => List.generate(98, (j) => 0.1)),
      );
      final class1 = List.generate(
        4,
        (_) => List.generate(20, (i) => List.generate(98, (j) => 0.9)),
      );

      proto.train([class0, class1]);

      final q0 = List.generate(20, (_) => List.generate(98, (_) => 0.15));
      final probs0 = proto.classify(q0);
      expect(probs0[0], greaterThan(probs0[1]));
    });

    test('OODGuard accepts in-distribution and rejects out-of-distribution queries', () {
      final ood = OODGuard();
      final class0 = List.generate(
        4,
        (_) => List.generate(20, (i) => List.generate(98, (j) => 0.2 + (j % 5) * 0.01)),
      );
      ood.build([class0]);

      final inDistSeq = List.generate(20, (i) => List.generate(98, (j) => 0.21 + (j % 5) * 0.01));
      expect(ood.isInDistribution(inDistSeq), isTrue);

      final outDistSeq = List.generate(20, (i) => List.generate(98, (_) => 50.0));
      expect(ood.isInDistribution(outDistSeq), isFalse);
    });
  });

  group('Intent State Machine (REST -> CANDIDATE -> WAIT_RELEASE)', () {
    test('State machine transitions cleanly and fires callback when dwell met', () {
      final fired = <String>[];
      final gestures = [
        HandGesture(id: 'rest', name: 'Rest', phrase: '', isRest: true),
        HandGesture(id: 'yes', name: 'Yes', phrase: 'Yes affirmative'),
      ];

      final sm = HandGestureStateMachine(
        gestures: gestures,
        onGestureFired: (g, conf) => fired.add(g.phrase),
        confidenceThreshold: 0.70,
      );

      expect(sm.currentState, GestureIntent.rest);

      // Feed Rest -> remains in rest
      sm.tick(const ClassifyResult(
        probs: [0.9, 0.1],
        maxIdx: 0,
        confidence: 0.9,
        inDistribution: true,
      ));
      expect(sm.currentState, GestureIntent.rest);
      expect(fired, isEmpty);

      // Feed 'Yes' (idx 1) -> enters CANDIDATE
      sm.tick(const ClassifyResult(
        probs: [0.1, 0.9],
        maxIdx: 1,
        confidence: 0.9,
        inDistribution: true,
      ));
      expect(sm.currentState, GestureIntent.candidate);
      expect(fired, isEmpty);
    });
  });

  group('HandGestureService Integration', () {
    test('Service trains and updates state cleanly', () async {
      final fired = <String>[];
      final svc = HandGestureService(
        onGestureFired: (g, conf) => fired.add(g.phrase),
      );
      svc.init();

      for (final g in svc.gestures) {
        if (!g.isRest) {
          for (var r = 0; r < 5; r++) {
            final rawSeq = List.generate(
              20,
              (i) => List.generate(63, (j) => (i * 0.01 + j * 0.005)),
            );
            g.samples.add(rawSeq);
          }
        }
      }

      final result = await svc.train();
      expect(result.success, isTrue);
      expect(svc.isTrained, isTrue);
    });
  });
}

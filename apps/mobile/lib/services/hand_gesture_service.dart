// hand_gesture_service.dart
// Orchestrates the full hand gesture pipeline:
//   Camera frame -> landmark extraction -> feature extraction
//   -> DTW/prototype classifier -> intent state machine -> phrase fired.

import 'hand_feature_extractor.dart';
import 'hand_gesture_classifier.dart';
import 'hand_gesture_state_machine.dart';

class TrainingResult {
  const TrainingResult({required this.success, required this.message});
  final bool success;
  final String message;
}

class HandGestureService {
  HandGestureService({
    required this.onGestureFired,
    this.confidenceThreshold = 0.75,
  });

  final GestureFiredCallback onGestureFired;
  final double confidenceThreshold;

  List<HandGesture> gestures = [
    HandGesture(id: 'rest', name: 'Rest', phrase: '', isRest: true),
    HandGesture(id: 'yes', name: 'Yes', phrase: 'Yes.'),
    HandGesture(id: 'no', name: 'No', phrase: 'No.'),
    HandGesture(id: 'h2o', name: 'Water', phrase: 'I need water, please.'),
    HandGesture(id: 'nrse', name: 'Nurse', phrase: 'Please call the nurse.'),
  ];

  // Public so HandCalibrationPage can access them directly.
  final HandGestureClassifier classifier = HandGestureClassifier();
  late HandGestureStateMachine stateMachine;
  final List<TimedFrame> liveBuffer = [];

  DateTime _lastInference = DateTime.fromMillisecondsSinceEpoch(0);
  static const _inferenceInterval = Duration(milliseconds: 120);

  bool get isTrained => classifier.isTrained;

  Map<String, double> lastProbs = {};
  GestureIntent get intentState => stateMachine.currentState;
  double get dwellProgress => stateMachine.dwellProgress;
  String? lastPredictedGesture;
  bool lastInDistribution = true;

  void init() {
    stateMachine = HandGestureStateMachine(
      gestures: gestures,
      onGestureFired: onGestureFired,
      confidenceThreshold: confidenceThreshold,
    );
  }

  // ── Live inference ─────────────────────────────────────────────────────────

  /// Feed one camera frame's hand landmarks into the pipeline.
  void onHandFrame(List<HandLandmark> landmarks, int nowMs) {
    final raw63 = flattenLandmarks(landmarks);
    liveBuffer.add(TimedFrame(nowMs, raw63));
    final cutoff = nowMs - liveBufferMaxMs;
    liveBuffer.removeWhere((f) => f.t < cutoff);

    final now = DateTime.now();
    if (now.difference(_lastInference) < _inferenceInterval) return;
    _lastInference = now;

    if (!classifier.isTrained) return;

    final rawSeq = resampleSequence(liveBuffer);
    if (rawSeq == null) return;

    final modelInput = buildModelInput(rawSeq);
    final result = classifier.classify(modelInput, gestures.length);

    lastProbs = {
      for (var i = 0; i < gestures.length; i++)
        gestures[i].id: i < result.probs.length ? result.probs[i] : 0.0,
    };
    lastInDistribution = result.inDistribution;
    lastPredictedGesture =
        result.inDistribution ? gestures[result.maxIdx].name : null;

    stateMachine.tick(result);
  }

  /// Call when no hand is visible in the current frame.
  void onNoHand() {
    liveBuffer.clear();
    lastPredictedGesture = null;
    stateMachine.onNoHand();
  }

  // ── Training ───────────────────────────────────────────────────────────────

  /// Train classifiers on all collected gesture samples.
  Future<TrainingResult> train({
    void Function(double fraction, String status)? onProgress,
  }) async {
    if (gestures.length < 2) {
      return const TrainingResult(
          success: false, message: 'Need at least 2 gestures.');
    }
    for (final g in gestures) {
      if (!g.isRest && g.samples.length < 5) {
        return TrainingResult(
          success: false,
          message: 'Gesture "${g.name}" needs at least 5 samples '
              '(has ${g.samples.length}).',
        );
      }
    }

    onProgress?.call(0.1, 'Building augmented training set...');
    await Future.delayed(Duration.zero);

    // Build per-class lists of 20x98 model inputs.
    final trainByClass = <List<List<List<double>>>>[];
    for (final g in gestures) {
      final seqsForClass = <List<List<double>>>[];
      for (final rawSeq in g.samples) {
        seqsForClass.add(buildModelInput(rawSeq));
        for (var a = 0; a < augPerSample; a++) {
          seqsForClass.add(buildModelInput(augmentRaw(rawSeq)));
        }
      }
      trainByClass.add(seqsForClass);
    }

    onProgress?.call(0.6, 'Training DTW k-NN and nearest-prototype...');
    await Future.delayed(Duration.zero);

    classifier.train(trainByClass);

    stateMachine = HandGestureStateMachine(
      gestures: gestures,
      onGestureFired: onGestureFired,
      confidenceThreshold: confidenceThreshold,
    );

    onProgress?.call(1.0, 'Done.');
    final totalSamples =
        gestures.map((g) => g.samples.length).fold(0, (a, b) => a + b);
    return TrainingResult(
      success: true,
      message: 'Trained on $totalSamples samples '
          '(${gestures.length} gestures).',
    );
  }

  void reset() {
    liveBuffer.clear();
    classifier.reset();
    stateMachine.reset();
    lastProbs = {};
    lastPredictedGesture = null;
  }
}

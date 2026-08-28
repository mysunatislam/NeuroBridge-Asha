// hand_gesture_state_machine.dart
// Exact Dart port of the REST/CANDIDATE/WAIT_RELEASE intent state machine
// from fingerspeak.html.

import 'dart:math' as math;
import 'hand_feature_extractor.dart' show releaseStreakNeeded;
import 'hand_gesture_classifier.dart';

// ── Gesture vocabulary entry ──────────────────────────────────────────────────

class HandGesture {
  HandGesture({
    required this.id,
    required this.name,
    required this.phrase,
    this.isRest = false,
    List<List<List<double>>>? samples,
  }) : samples = samples ?? [];

  final String id;
  final String name;
  final String phrase;
  final bool isRest;

  /// Raw 20-frame landmark sequences (63 coords each, before velocity).
  final List<List<List<double>>> samples;

  Duration get dwell {
    final n = name.toLowerCase();
    if (n.contains('emergency') || n.contains('urgent')) {
      return const Duration(milliseconds: 1400);
    }
    if (n.contains('pain')) return const Duration(milliseconds: 1000);
    return const Duration(milliseconds: 650);
  }

  Map<String, dynamic> toJson() => {
        'id': id,
        'name': name,
        'phrase': phrase,
        'isRest': isRest,
      };

  factory HandGesture.fromJson(Map<String, dynamic> j) => HandGesture(
        id: j['id'] as String,
        name: j['name'] as String,
        phrase: (j['phrase'] as String?) ?? '',
        isRest: (j['isRest'] as bool?) ?? false,
      );
}

// ── State machine ─────────────────────────────────────────────────────────────

enum GestureIntent { rest, candidate, waitRelease }

typedef GestureFiredCallback = void Function(HandGesture gesture, double confidence);

class HandGestureStateMachine {
  HandGestureStateMachine({
    required this.gestures,
    required this.onGestureFired,
    double confidenceThreshold = 0.75,
  }) : _threshold = confidenceThreshold;

  final List<HandGesture> gestures;
  final GestureFiredCallback onGestureFired;

  double _threshold;
  double get confidenceThreshold => _threshold;
  set confidenceThreshold(double v) => _threshold = v.clamp(0.5, 0.98);

  GestureIntent _state = GestureIntent.rest;
  int? _candidateIdx;
  DateTime? _candidateStart;
  int _restStreak = 0;

  GestureIntent get currentState => _state;

  double get dwellProgress {
    if (_state != GestureIntent.candidate) return 0.0;
    final idx = _candidateIdx;
    if (idx == null) return 0.0;
    final elapsed = DateTime.now().difference(_candidateStart!);
    final need = gestures[idx].dwell;
    return math.min(1.0, elapsed.inMilliseconds / need.inMilliseconds);
  }

  void tick(ClassifyResult result) {
    final restIdx = gestures.indexWhere((g) => g.isRest);
    final isRestOrOOD = result.maxIdx == restIdx ||
        !result.inDistribution ||
        result.confidence < _threshold;

    switch (_state) {
      case GestureIntent.rest:
        if (!isRestOrOOD) {
          _state = GestureIntent.candidate;
          _candidateIdx = result.maxIdx;
          _candidateStart = DateTime.now();
        }

      case GestureIntent.candidate:
        if (isRestOrOOD || result.maxIdx != _candidateIdx) {
          _state = GestureIntent.rest;
          _candidateIdx = null;
          return;
        }
        final elapsed = DateTime.now().difference(_candidateStart!);
        final need = gestures[_candidateIdx!].dwell;
        if (elapsed >= need) {
          final g = gestures[_candidateIdx!];
          if (g.phrase.isNotEmpty) {
            onGestureFired(g, result.confidence);
          }
          _state = GestureIntent.waitRelease;
          _restStreak = 0;
          _candidateIdx = null;
        }

      case GestureIntent.waitRelease:
        if (isRestOrOOD || result.confidence < _threshold) {
          _restStreak++;
        } else {
          _restStreak = 0;
        }
        if (_restStreak >= releaseStreakNeeded) {
          _state = GestureIntent.rest;
          _restStreak = 0;
        }
    }
  }

  void onNoHand() {
    switch (_state) {
      case GestureIntent.candidate:
        _state = GestureIntent.rest;
        _candidateIdx = null;
      case GestureIntent.waitRelease:
        _restStreak++;
        if (_restStreak >= releaseStreakNeeded) {
          _state = GestureIntent.rest;
          _restStreak = 0;
        }
      default:
        break;
    }
  }

  void reset() {
    _state = GestureIntent.rest;
    _candidateIdx = null;
    _restStreak = 0;
  }
}

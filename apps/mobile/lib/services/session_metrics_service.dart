import 'package:flutter/foundation.dart';

/// Tracks session-level quality metrics for the caregiver dashboard.
/// Counters are in-memory only and reset when the app restarts.
class SessionMetricsService extends ChangeNotifier {
  int _phrasesSpoken = 0;
  int _falseActivations = 0;
  int _missedGestures = 0;

  int get phrasesSpoken => _phrasesSpoken;
  int get falseActivations => _falseActivations;
  int get missedGestures => _missedGestures;

  /// Called automatically whenever a phrase is spoken by the recognition system.
  void recordPhraseSpoken() {
    _phrasesSpoken++;
    notifyListeners();
  }

  /// Called by the caregiver to mark the last activation as a false positive.
  void markFalseActivation() {
    _falseActivations++;
    notifyListeners();
  }

  /// Called by the caregiver to mark a phrase they expected but was not triggered.
  void markMissedGesture() {
    _missedGestures++;
    notifyListeners();
  }

  /// Resets all counters (e.g. for a new session).
  void reset() {
    _phrasesSpoken = 0;
    _falseActivations = 0;
    _missedGestures = 0;
    notifyListeners();
  }
}

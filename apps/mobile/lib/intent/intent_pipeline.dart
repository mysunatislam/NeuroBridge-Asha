// intent_pipeline.dart
// On-device orchestration (port of neurobridge_intent/pipeline.py):
//
//   IntentFrame -> FeatureWindow -> IntentRuntime (Phase 1)
//                               -> TemporalCnnRuntime (Phase 2)
//                               -> AbnormalRuntime (Phase 3)
//                               -> PatientProfile prototypes / normaliser
//                               -> ConfidenceVerificationEngine -> Verdict
//
// Everything runs in Dart with no network access. The pipeline never maps a
// single frame to a command: a decision needs a full 2.5 s window and a 3 s
// sequence, re-evaluated at 4 Hz.

import 'dart:collection';

import 'intent_runtimes.dart';
import 'intent_schema.dart';
import 'patient_profile.dart';
import 'verification_engine.dart';
import 'window_features.dart';

class PipelineEvent {
  const PipelineEvent({
    required this.tSeconds,
    required this.verdict,
    required this.intent,
    required this.temporal,
    required this.abnormal,
  });

  final double tSeconds;
  final Verdict verdict;
  final Map<String, Object?> intent;
  final Map<String, Object?> temporal;
  final Map<String, Object?> abnormal;

  Map<String, Object?> toJson() => {
        't_s': double.parse(tSeconds.toStringAsFixed(3)),
        'verdict': verdict.toJson(),
        'intent': intent,
        'temporal': temporal,
        'abnormal': abnormal,
      };
}

class IntentPipeline {
  IntentPipeline({
    required this.bundle,
    required PatientProfile profile,
    ConfidenceVerificationEngine? engine,
    this.decisionIntervalSeconds = 0.25,
    this.historySize = 200,
  })  : _profile = profile,
        engine = engine ?? ConfidenceVerificationEngine() {
    window = FeatureWindow(
      windowFrames: kWindowFrames,
      sequenceFrames: kSequenceFrames,
      rateHz: kFrameRateHz,
    );
    _applyProfile();
  }

  final IntentModelBundle bundle;
  final ConfidenceVerificationEngine engine;
  final double decisionIntervalSeconds;
  final int historySize;
  late final FeatureWindow window;
  final ListQueue<PipelineEvent> history = ListQueue();
  PatientProfile _profile;
  double _lastDecisionT = -1e9;

  PatientProfile get profile => _profile;

  set profile(PatientProfile value) {
    _profile = value;
    _applyProfile();
  }

  void _applyProfile() {
    engine.ignoreBelow = _profile.ignoreBelow;
    engine.executeAt = _profile.executeAt;
    engine.prototypeWeight = _profile.prototypeWeight;
    engine.confirmationWindowSeconds = _profile.confirmationWindowSeconds;
    bundle.abnormal.restHfRatio = _profile.restHfRatio;
    bundle.abnormal.restRhythmicity = _profile.restRhythmicity;
  }

  /// Feed one resampled frame; returns a verdict only when a decision was made.
  Verdict? push(IntentFrame frame) {
    window.push(frame);
    if (!window.isReady) return null;
    if (frame.tSeconds - _lastDecisionT < decisionIntervalSeconds) return null;
    _lastDecisionT = frame.tSeconds;
    return _decide(frame.tSeconds);
  }

  Verdict? _decide(double tSeconds) {
    final features = window.features(openEar: _profile.openEar);
    final sequence = _profile.normalize(window.sequence());
    final intent = bundle.intent.predict(features);
    final temporal = bundle.temporal.predict(sequence, normalized: true);
    final abnormal = bundle.abnormal.predict(features);
    final pPrototype = _profile.intentionalPrototypeProbability(features);
    final verdict = engine.evaluate(IntentEvidence(
      command: temporal.label,
      pCommand: temporal.probability,
      pIntentional: intent.pIntentional,
      intentLabel: intent.label,
      pPrototype: pPrototype,
      pAbnormal: abnormal.pAbnormal,
      abnormalLabel: abnormal.label,
      tSeconds: tSeconds,
    ));
    switch (verdict.decision) {
      case VerificationDecision.execute:
      case VerificationDecision.confirm:
      case VerificationDecision.alert:
      case VerificationDecision.cancel:
        _remember(PipelineEvent(
          tSeconds: tSeconds,
          verdict: verdict,
          intent: intent.toJson(),
          temporal: {
            'command': temporal.label,
            'p_command': double.parse(temporal.probability.toStringAsFixed(4)),
          },
          abnormal: abnormal.toJson(),
        ));
        return verdict;
      case VerificationDecision.ignore:
        return null;
    }
  }

  void _remember(PipelineEvent event) {
    history.addLast(event);
    while (history.length > historySize) {
      history.removeFirst();
    }
  }

  /// Map a verified command pattern to the app's PatientSignalKind name.
  String? signalFor(String command) {
    if (command == CommandClass.nonCommand) return null;
    return _profile.commandMap[command] ?? kDefaultCommandSignals[command];
  }

  Verdict? confirmByTouch(double tSeconds) {
    final verdict = engine.confirmExternally(tSeconds);
    if (verdict != null) {
      _remember(PipelineEvent(
        tSeconds: tSeconds,
        verdict: verdict,
        intent: const {},
        temporal: const {},
        abnormal: const {},
      ));
    }
    return verdict;
  }

  void cancelPending() => engine.cancel();

  /// Structured, camera-free summary for the optional Gemini layer.
  Map<String, Object?> eventPayload({String patientHistory = ''}) {
    final latest = history.isEmpty ? null : history.last;
    final recent = history.length <= 10
        ? history.toList()
        : history.toList().sublist(history.length - 10);
    var state = 'idle';
    if (latest != null) {
      switch (latest.verdict.decision) {
        case VerificationDecision.alert:
          state = 'possible_abnormal_movement';
        case VerificationDecision.execute:
          state = 'command_${latest.verdict.command}';
        case VerificationDecision.confirm:
          state = 'awaiting_confirmation';
        default:
          state = 'idle';
      }
    }
    return {
      'patient_state': state,
      'gesture': latest?.verdict.command,
      'confidence': latest == null
          ? null
          : double.parse(latest.verdict.confidence.toStringAsFixed(3)),
      'decision': latest?.verdict.decision.name,
      'patient_history': patientHistory,
      'profile': {
        'patient_id': _profile.patientId,
        'blink_rate_per_min': double.parse(
            (_profile.blink['rate_per_min'] ?? 0.0).toStringAsFixed(1)),
        'command_map': _profile.commandMap,
      },
      'recent_events': recent.map((e) => e.toJson()).toList(),
    };
  }

  void reset() {
    window.clear();
    engine.reset();
    history.clear();
    _lastDecisionT = -1e9;
  }
}

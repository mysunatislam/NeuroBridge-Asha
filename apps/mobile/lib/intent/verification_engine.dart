// verification_engine.dart
// Confidence Verification Engine (port of neurobridge_intent/verification.py).
//
//   confidence < 0.70         -> ignore
//   0.70 <= confidence < 0.90 -> ask for confirmation ("Did you mean help?")
//   confidence >= 0.90        -> execute
//
// Abnormal movement always wins: it never becomes a command and seizure-like or
// spasm activity is escalated as an alert.

import 'intent_schema.dart';

enum VerificationDecision { ignore, confirm, execute, alert, cancel }

class IntentEvidence {
  const IntentEvidence({
    required this.command,
    required this.pCommand,
    required this.pIntentional,
    required this.intentLabel,
    required this.pPrototype,
    required this.pAbnormal,
    required this.abnormalLabel,
    required this.tSeconds,
  });

  final String command;
  final double pCommand;
  final double pIntentional;
  final String intentLabel;
  final double pPrototype;
  final double pAbnormal;
  final String abnormalLabel;
  final double tSeconds;
}

class Verdict {
  const Verdict({
    required this.decision,
    required this.command,
    required this.confidence,
    required this.reason,
    this.prompt,
    this.evidence,
  });

  final VerificationDecision decision;
  final String command;
  final double confidence;
  final String reason;
  final String? prompt;
  final IntentEvidence? evidence;

  Map<String, Object?> toJson() => {
        'decision': decision.name,
        'command': command,
        'confidence': double.parse(confidence.toStringAsFixed(4)),
        'reason': reason,
        'prompt': prompt,
      };
}

double fuseConfidence({
  required double pCommand,
  required double pIntentional,
  required String intentLabel,
  required double pPrototype,
  required double pAbnormal,
  double prototypeWeight = 0.4,
}) {
  for (final v in [pCommand, pIntentional, pPrototype, pAbnormal]) {
    if (!v.isFinite || v < 0 || v > 1) {
      throw ArgumentError('probabilities must be within [0, 1]');
    }
  }
  final double gate;
  if (intentLabel == IntentClass.accidental) {
    gate = 0.5 * pIntentional;
  } else if (intentLabel == IntentClass.unknown) {
    gate = 0.35 + 0.35 * pIntentional;
  } else {
    gate = 0.75 + 0.25 * pIntentional;
  }
  var personal = (1.0 - prototypeWeight) + prototypeWeight * (0.5 + pPrototype);
  if (personal > 1.0 + 0.5 * prototypeWeight) personal = 1.0 + 0.5 * prototypeWeight;
  final veto = 1.0 - (pAbnormal - 0.1).clamp(0.0, 1.0) / 0.9;
  final fused = pCommand * gate * personal * veto;
  return fused.clamp(0.0, 1.0).toDouble();
}

class _Pending {
  _Pending(this.command, this.confidence, this.askedAt, this.expiresAt);
  final String command;
  final double confidence;
  final double askedAt;
  final double expiresAt;
}

class ConfidenceVerificationEngine {
  ConfidenceVerificationEngine({
    this.ignoreBelow = kIgnoreBelow,
    this.executeAt = kExecuteAt,
    this.prototypeWeight = 0.4,
    this.confirmationWindowSeconds = 8.0,
    this.cooldownSeconds = 3.0,
    this.abnormalAlertThreshold = 0.6,
    this.confirmCommands = const [
      CommandClass.doubleBlink,
      CommandClass.longBlink,
      CommandClass.browRaiseHold,
    ],
    Map<String, String>? prompts,
  }) : prompts = prompts ?? const {} {
    if (!(ignoreBelow > 0 && ignoreBelow <= executeAt && executeAt <= 1)) {
      throw ArgumentError('thresholds must satisfy 0 < ignore <= execute <= 1');
    }
  }

  double ignoreBelow;
  double executeAt;
  double prototypeWeight;
  double confirmationWindowSeconds;
  final double cooldownSeconds;
  final double abnormalAlertThreshold;
  final List<String> confirmCommands;
  final Map<String, String> prompts;

  _Pending? _pending;
  final Map<String, double> _lastExecution = {};
  double _lastAlertAt = -1e9;

  bool get hasPending => _pending != null;
  String? get pendingCommand => _pending?.command;

  String promptFor(String command) =>
      prompts[command] ?? 'Did you mean ${command.replaceAll('_', ' ')}?';

  Verdict evaluate(IntentEvidence e) {
    if (e.abnormalLabel != AbnormalClass.normalVoluntary &&
        e.pAbnormal >= abnormalAlertThreshold) {
      _pending = null;
      final escalate = e.abnormalLabel == AbnormalClass.possibleSeizureLike ||
          e.abnormalLabel == AbnormalClass.possibleSpasm;
      if (escalate && e.tSeconds - _lastAlertAt >= cooldownSeconds) {
        _lastAlertAt = e.tSeconds;
        return Verdict(
          decision: VerificationDecision.alert,
          command: e.abnormalLabel,
          confidence: e.pAbnormal,
          reason: 'abnormal movement detected; commands suppressed',
          evidence: e,
        );
      }
      return Verdict(
        decision: VerificationDecision.ignore,
        command: e.abnormalLabel,
        confidence: e.pAbnormal,
        reason: 'involuntary movement; not a command',
        evidence: e,
      );
    }

    if (e.command == CommandClass.nonCommand) {
      final pending = _pending;
      if (pending != null && e.tSeconds > pending.expiresAt) {
        _pending = null;
        return Verdict(
          decision: VerificationDecision.cancel,
          command: pending.command,
          confidence: pending.confidence,
          reason: 'confirmation window expired',
          evidence: e,
        );
      }
      return Verdict(
        decision: VerificationDecision.ignore,
        command: e.command,
        confidence: 0.0,
        reason: 'no command pattern',
        evidence: e,
      );
    }

    final confidence = fuseConfidence(
      pCommand: e.pCommand,
      pIntentional: e.pIntentional,
      intentLabel: e.intentLabel,
      pPrototype: e.pPrototype,
      pAbnormal: e.pAbnormal,
      prototypeWeight: prototypeWeight,
    );

    final pending = _pending;
    if (pending != null) {
      if (e.tSeconds > pending.expiresAt) {
        _pending = null;
        return Verdict(
          decision: VerificationDecision.cancel,
          command: pending.command,
          confidence: pending.confidence,
          reason: 'confirmation window expired',
          evidence: e,
        );
      }
      final isConfirmGesture =
          confirmCommands.contains(e.command) || e.command == pending.command;
      if (isConfirmGesture && confidence >= ignoreBelow) {
        _pending = null;
        _lastExecution[pending.command] = e.tSeconds;
        return Verdict(
          decision: VerificationDecision.execute,
          command: pending.command,
          confidence: pending.confidence > confidence ? pending.confidence : confidence,
          reason: 'confirmed by patient',
          evidence: e,
        );
      }
      return Verdict(
        decision: VerificationDecision.ignore,
        command: e.command,
        confidence: confidence,
        reason: 'awaiting confirmation',
        evidence: e,
      );
    }

    if (confidence < ignoreBelow) {
      return Verdict(
        decision: VerificationDecision.ignore,
        command: e.command,
        confidence: confidence,
        reason: 'confidence below ignore threshold',
        evidence: e,
      );
    }
    final last = _lastExecution[e.command];
    if (last != null && e.tSeconds - last < cooldownSeconds) {
      return Verdict(
        decision: VerificationDecision.ignore,
        command: e.command,
        confidence: confidence,
        reason: 'cooldown after execution',
        evidence: e,
      );
    }
    if (confidence >= executeAt) {
      _lastExecution[e.command] = e.tSeconds;
      return Verdict(
        decision: VerificationDecision.execute,
        command: e.command,
        confidence: confidence,
        reason: 'high confidence',
        evidence: e,
      );
    }
    _pending = _Pending(e.command, confidence, e.tSeconds,
        e.tSeconds + confirmationWindowSeconds);
    return Verdict(
      decision: VerificationDecision.confirm,
      command: e.command,
      confidence: confidence,
      reason: 'moderate confidence; asking for confirmation',
      prompt: promptFor(e.command),
      evidence: e,
    );
  }

  /// Touch / caregiver confirmation of the pending command.
  Verdict? confirmExternally(double tSeconds) {
    final pending = _pending;
    if (pending == null) return null;
    _pending = null;
    _lastExecution[pending.command] = tSeconds;
    return Verdict(
      decision: VerificationDecision.execute,
      command: pending.command,
      confidence: pending.confidence > executeAt ? pending.confidence : executeAt,
      reason: 'confirmed by touch',
    );
  }

  void cancel() => _pending = null;

  void reset() {
    _pending = null;
    _lastExecution.clear();
    _lastAlertAt = -1e9;
  }
}

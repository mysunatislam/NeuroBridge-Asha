// multimodal_fusion_engine.dart
// Multimodal Confidence Fusion & Safety Gating Engine.

import 'dart:async';

enum SafetyTier {
  lowRisk(1, 0.65, false),
  mediumRisk(2, 0.78, false),
  emergencyRisk(3, 0.90, true);

  const SafetyTier(this.level, this.minConfidence, this.requiresConfirmation);
  final int level;
  final double minConfidence;
  final bool requiresConfirmation;
}

class FusedIntentEvent {
  const FusedIntentEvent({
    required this.intent,
    required this.confidence,
    required this.safetyTier,
    required this.isConfirmed,
    this.secondaryModality,
  });

  final String intent;
  final double confidence;
  final SafetyTier safetyTier;
  final bool isConfirmed;
  final String? secondaryModality;
}

class MultimodalFusionEngine {
  MultimodalFusionEngine({
    required this.onIntentExecuted,
    required this.onConfirmationPromptRequested,
  });

  final void Function(FusedIntentEvent event) onIntentExecuted;
  final void Function(String intent, double confidence) onConfirmationPromptRequested;

  String? _pendingEmergencyIntent;
  Timer? _emergencyConfirmationTimer;

  static SafetyTier classifySafetyTier(String intent) {
    final lower = intent.toLowerCase();
    if (lower.contains('help') || lower.contains('pain') || lower.contains('emergency') || lower.contains('urgent') || lower.contains('doctor')) {
      return SafetyTier.emergencyRisk;
    }
    if (lower.contains('water') || lower.contains('food') || lower.contains('toilet') || lower.contains('turn')) {
      return SafetyTier.mediumRisk;
    }
    return SafetyTier.lowRisk;
  }

  void processSignal({
    required String intent,
    required double primaryConfidence,
    double? secondaryConfidence,
    String? secondaryModality,
  }) {
    final tier = classifySafetyTier(intent);
    final fusedConfidence = secondaryConfidence != null
        ? (primaryConfidence * 0.7) + (secondaryConfidence * 0.3)
        : primaryConfidence;

    if (tier == SafetyTier.emergencyRisk) {
      if (fusedConfidence >= 0.95) {
        onIntentExecuted(FusedIntentEvent(
          intent: intent,
          confidence: fusedConfidence,
          safetyTier: tier,
          isConfirmed: true,
          secondaryModality: secondaryModality,
        ));
      } else if (fusedConfidence >= 0.75) {
        _pendingEmergencyIntent = intent;
        _emergencyConfirmationTimer?.cancel();
        _emergencyConfirmationTimer = Timer(const Duration(seconds: 8), () {
          _pendingEmergencyIntent = null;
        });
        onConfirmationPromptRequested(intent, fusedConfidence);
      }
    } else if (fusedConfidence >= tier.minConfidence) {
      onIntentExecuted(FusedIntentEvent(
        intent: intent,
        confidence: fusedConfidence,
        safetyTier: tier,
        isConfirmed: true,
        secondaryModality: secondaryModality,
      ));
    }
  }

  void confirmPendingIntent() {
    if (_pendingEmergencyIntent != null) {
      final intent = _pendingEmergencyIntent!;
      _pendingEmergencyIntent = null;
      _emergencyConfirmationTimer?.cancel();
      onIntentExecuted(FusedIntentEvent(
        intent: intent,
        confidence: 0.98,
        safetyTier: SafetyTier.emergencyRisk,
        isConfirmed: true,
      ));
    }
  }
}

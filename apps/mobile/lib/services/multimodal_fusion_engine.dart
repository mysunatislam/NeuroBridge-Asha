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

  /// Multimodal Understanding Engine:
  /// Converts combined human signals (gestures, face mesh expressions, voice, context) into semantic intent.
  FusedIntentEvent fuseMultimodalSignals({
    String? gestureIntent,
    double gestureConfidence = 0.0,
    double smileScore = 0.0,
    double grimaceScore = 0.0,
    double eyeBlinkRate = 12.0, // normal blinks/min
    String? acousticCue,
    String? patientContext,
  }) {
    String semanticIntent;
    double fusedConfidence;
    String secondaryModality = 'face_landmarks';

    // 1. Severe pain / grimacing detection
    if (grimaceScore >= 0.65) {
      semanticIntent = 'User experiencing discomfort';
      fusedConfidence = 0.70 + (grimaceScore * 0.25);
      secondaryModality = 'facial_pain_grimace';
    }
    // 2. Hydration / Biological Request
    else if (gestureIntent == 'water' ||
        (acousticCue != null && (acousticCue.contains('water') || acousticCue.contains('thirsty')))) {
      semanticIntent = 'User wants water';
      fusedConfidence = gestureConfidence > 0 ? gestureConfidence : 0.88;
      secondaryModality = gestureConfidence > 0 ? 'micro_gesture' : 'voice_cue';
    }
    // 3. Rehabilitation Engagement
    else if (gestureIntent == 'rehab' || gestureIntent == 'exercise') {
      semanticIntent = 'User starting rehabilitation';
      fusedConfidence = gestureConfidence > 0 ? gestureConfidence : 0.85;
      secondaryModality = 'kinematic_gesture';
    }
    // 4. Positive Emotion / Satisfaction
    else if (smileScore >= 0.70) {
      semanticIntent = 'User pleased and comfortable';
      fusedConfidence = smileScore;
      secondaryModality = 'facial_smile_mesh';
    }
    // 5. Fatigue / Drowsiness
    else if (eyeBlinkRate > 35.0 || eyeBlinkRate < 3.0) {
      semanticIntent = 'User experiencing severe fatigue';
      fusedConfidence = 0.82;
      secondaryModality = 'eye_aspect_ratio_tracking';
    }
    // Default to provided gesture or ambient monitoring
    else {
      semanticIntent = gestureIntent ?? 'Ambient patient monitoring';
      fusedConfidence = gestureConfidence > 0 ? gestureConfidence : 0.75;
      secondaryModality = 'ambient_sensors';
    }

    final tier = classifySafetyTier(semanticIntent);
    final event = FusedIntentEvent(
      intent: semanticIntent,
      confidence: fusedConfidence,
      safetyTier: tier,
      isConfirmed: fusedConfidence >= tier.minConfidence,
      secondaryModality: secondaryModality,
    );

    if (event.isConfirmed) {
      onIntentExecuted(event);
    }
    return event;
  }
}

// multimodal_fusion_test.dart
import 'package:flutter_test/flutter_test.dart';
import 'package:fingerspeak_mobile/services/multimodal_fusion_engine.dart';

void main() {
  group('MultimodalFusionEngine Tests', () {
    test('Classifies Safety Tiers correctly', () {
      expect(MultimodalFusionEngine.classifySafetyTier('Help please'), equals(SafetyTier.emergencyRisk));
      expect(MultimodalFusionEngine.classifySafetyTier('Emergency SOS'), equals(SafetyTier.emergencyRisk));
      expect(MultimodalFusionEngine.classifySafetyTier('I have severe pain'), equals(SafetyTier.emergencyRisk));
      expect(MultimodalFusionEngine.classifySafetyTier('Water please'), equals(SafetyTier.mediumRisk));
      expect(MultimodalFusionEngine.classifySafetyTier('Need toilet'), equals(SafetyTier.mediumRisk));
      expect(MultimodalFusionEngine.classifySafetyTier('Yes'), equals(SafetyTier.lowRisk));
      expect(MultimodalFusionEngine.classifySafetyTier('Thank you'), equals(SafetyTier.lowRisk));
    });

    test('Executes low risk intent immediately when confidence meets threshold', () {
      FusedIntentEvent? executed;
      final engine = MultimodalFusionEngine(
        onIntentExecuted: (e) => executed = e,
        onConfirmationPromptRequested: (_, __) {},
      );

      engine.processSignal(intent: 'Yes', primaryConfidence: 0.80);

      expect(executed, isNotNull);
      expect(executed!.intent, equals('Yes'));
      expect(executed!.safetyTier, equals(SafetyTier.lowRisk));
    });

    test('Requests confirmation gate for emergency intent with moderate confidence', () {
      FusedIntentEvent? executed;
      String? promptIntent;

      final engine = MultimodalFusionEngine(
        onIntentExecuted: (e) => executed = e,
        onConfirmationPromptRequested: (intent, _) => promptIntent = intent,
      );

      engine.processSignal(intent: 'Help please', primaryConfidence: 0.82);

      // Should not execute immediately
      expect(executed, isNull);
      // Should prompt user for confirmation
      expect(promptIntent, equals('Help please'));

      // Confirm with secondary movement
      engine.confirmPendingIntent();
      expect(executed, isNotNull);
      expect(executed!.intent, equals('Help please'));
      expect(executed!.safetyTier, equals(SafetyTier.emergencyRisk));
      expect(executed!.isConfirmed, isTrue);
    });

    test('Fuses primary and secondary confidence values', () {
      FusedIntentEvent? executed;
      final engine = MultimodalFusionEngine(
        onIntentExecuted: (e) => executed = e,
        onConfirmationPromptRequested: (_, __) {},
      );

      // Primary: 0.70 (below medium risk 0.78), Secondary: 0.90 -> Fused: (0.70*0.7) + (0.90*0.3) = 0.49 + 0.27 = 0.76
      // Still below 0.78 for medium risk
      engine.processSignal(intent: 'Water please', primaryConfidence: 0.70, secondaryConfidence: 0.90);
      expect(executed, isNull);

      // Primary: 0.80, Secondary: 0.90 -> Fused: 0.56 + 0.27 = 0.83 -> Meets 0.78!
      engine.processSignal(intent: 'Water please', primaryConfidence: 0.80, secondaryConfidence: 0.90);
      expect(executed, isNotNull);
      expect(executed!.intent, equals('Water please'));
    });
  });
}

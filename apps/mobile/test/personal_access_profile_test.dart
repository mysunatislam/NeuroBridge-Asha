// personal_access_profile_test.dart
import 'package:flutter_test/flutter_test.dart';
import 'package:fingerspeak_mobile/models/personal_access_profile.dart';
import 'package:fingerspeak_mobile/services/access_assessment_service.dart';

void main() {
  group('PersonalAccessProfile Tests', () {
    test('Calculates capability scores accurately', () {
      final profile = PersonalAccessProfile(
        id: 'test_1',
        patientName: 'Test Patient',
        capabilities: {
          BodyPart.rightHand: CapabilityGrade.good, // 80%
          BodyPart.leftHand: CapabilityGrade.unavailable, // 0%
          BodyPart.head: CapabilityGrade.excellent, // 100%
          BodyPart.eyes: CapabilityGrade.good, // 80%
          BodyPart.blink: CapabilityGrade.excellent, // 100% -> Eye avg: 90%
          BodyPart.facialMuscles: CapabilityGrade.moderate, // 55%
          BodyPart.voice: CapabilityGrade.unavailable, // 0%
          BodyPart.touchScreen: CapabilityGrade.limited, // 25%
        },
        primaryModality: AccessModality.handGestures,
      );

      final scores = profile.capabilityScores;
      expect(scores['Right Hand'], equals(80));
      expect(scores['Left Hand'], equals(0));
      expect(scores['Head Control'], equals(100));
      expect(scores['Eye / Blink Control'], equals(90));
      expect(scores['Facial Control'], equals(55));
      expect(scores['Speech'], equals(0));
      expect(scores['Touch Capability'], equals(25));
    });

    test('Serializes to and from JSON cleanly', () {
      final profile = PersonalAccessProfile.defaultProfile(name: 'Rahim');
      final json = profile.toJson();
      final restored = PersonalAccessProfile.fromJson(json);

      expect(restored.patientName, equals('Rahim'));
      expect(restored.primaryModality, equals(AccessModality.handGestures));
      expect(restored.backupModality, equals(AccessModality.eyeBlinkGaze));
      expect(restored.sensitivity, equals(SensitivityLevel.medium));
      expect(restored.capabilities[BodyPart.blink], equals(CapabilityGrade.excellent));
    });
  });

  group('AccessAssessmentService Tests', () {
    const service = AccessAssessmentService();

    test('Recommends Hand Gestures when hand control is good', () {
      final rec = service.evaluate({
        BodyPart.rightHand: CapabilityGrade.good,
        BodyPart.leftHand: CapabilityGrade.unavailable,
        BodyPart.head: CapabilityGrade.moderate,
        BodyPart.blink: CapabilityGrade.good,
        BodyPart.touchScreen: CapabilityGrade.limited,
      });

      expect(rec.primaryModality, equals(AccessModality.handGestures));
      expect(rec.backupModality, equals(AccessModality.eyeBlinkGaze));
      expect(rec.isSingleMovementOnly, isFalse);
    });

    test('Recommends SingleSwitchScanning when only one movement is available', () {
      final rec = service.evaluate({
        BodyPart.rightHand: CapabilityGrade.unavailable,
        BodyPart.leftHand: CapabilityGrade.unavailable,
        BodyPart.head: CapabilityGrade.unavailable,
        BodyPart.facialMuscles: CapabilityGrade.unavailable,
        BodyPart.eyes: CapabilityGrade.limited,
        BodyPart.blink: CapabilityGrade.moderate, // single voluntary blink
        BodyPart.touchScreen: CapabilityGrade.unavailable,
        BodyPart.singleSwitch: CapabilityGrade.good,
      });

      expect(rec.primaryModality, equals(AccessModality.singleSwitchScanning));
      expect(rec.isSingleMovementOnly, isTrue);
    });

    test('Recommends Eye Gaze & Blink when hands are unavailable but eyes are strong', () {
      final rec = service.evaluate({
        BodyPart.rightHand: CapabilityGrade.unavailable,
        BodyPart.leftHand: CapabilityGrade.unavailable,
        BodyPart.head: CapabilityGrade.moderate,
        BodyPart.facialMuscles: CapabilityGrade.limited,
        BodyPart.eyes: CapabilityGrade.excellent,
        BodyPart.blink: CapabilityGrade.excellent,
        BodyPart.touchScreen: CapabilityGrade.unavailable,
      });

      expect(rec.primaryModality, equals(AccessModality.eyeBlinkGaze));
      expect(rec.backupModality, equals(AccessModality.headMovement));
    });
  });
}

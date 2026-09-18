// personal_access_profile_test.dart
import 'package:flutter_test/flutter_test.dart';
import 'package:fingerspeak_mobile/models/personal_access_profile.dart';
import 'package:fingerspeak_mobile/services/access_assessment_service.dart';
import 'package:fingerspeak_mobile/services/calibration_service.dart';
import 'package:shared_preferences/shared_preferences.dart';

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

    test('Auto triggers facial calibration when handFingerScore < 50%', () {
      final rec = service.evaluate({
        BodyPart.rightHand: CapabilityGrade.limited,
        BodyPart.leftHand: CapabilityGrade.unavailable,
        BodyPart.wrist: CapabilityGrade.limited,
        BodyPart.head: CapabilityGrade.good,
        BodyPart.facialMuscles: CapabilityGrade.good,
        BodyPart.eyes: CapabilityGrade.good,
        BodyPart.blink: CapabilityGrade.good,
        BodyPart.touchScreen: CapabilityGrade.unavailable,
      });

      expect(rec.handFingerScore, lessThan(50));
      expect(rec.autoFacialCalibrationTriggered, isTrue);
      expect(
        rec.primaryModality,
        isIn([AccessModality.facialControls, AccessModality.eyeBlinkGaze]),
      );
    });

    test('Two-tier facial calibration database returns standard and calibrated correctly', () async {
      SharedPreferences.setMockInitialValues({});
      final prefs = await SharedPreferences.getInstance();
      final repo = NeutralFaceBaselineRepository(prefs);

      // Default should be standard database
      expect(repo.getActiveDatasetType(), FacialCalibrationDatasetType.standardDatabase);
      final standard = repo.getEffectiveBaseline();
      expect(standard.leftEyeOpenness, 0.85);
      expect(standard.mouthDistance, 0.08);

      // Switch to patient-specific calibrated database
      await repo.setActiveDatasetType(FacialCalibrationDatasetType.patientSpecificCalibratedDatabase);
      expect(repo.getActiveDatasetType(), FacialCalibrationDatasetType.patientSpecificCalibratedDatabase);

      // Save custom patient baseline
      const custom = NeutralFaceBaseline(
        eyebrowDistance: 0.20,
        mouthDistance: 0.12,
        leftEyeOpenness: 0.75,
        rightEyeOpenness: 0.75,
        headYaw: 2.5,
        headPitch: -1.0,
      );
      await repo.save(custom);
      final effective = repo.getEffectiveBaseline();
      expect(effective.leftEyeOpenness, 0.75);
      expect(effective.mouthDistance, 0.12);
    });
  });
}

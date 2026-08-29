// access_assessment_service.dart
// Evaluates physical abilities questionnaire and recommends optimal interaction modalities.

import '../models/personal_access_profile.dart';

class AssessmentRecommendation {
  const AssessmentRecommendation({
    required this.primaryModality,
    required this.backupModality,
    required this.recommendedSensitivity,
    required this.isSingleMovementOnly,
    required this.reasoning,
    required this.capabilityScores,
  });

  final AccessModality primaryModality;
  final AccessModality? backupModality;
  final SensitivityLevel recommendedSensitivity;
  final bool isSingleMovementOnly;
  final String reasoning;
  final Map<String, int> capabilityScores;
}

class AccessAssessmentService {
  const AccessAssessmentService();

  /// Analyzes capabilities and determines the easiest, lowest-fatigue communication modality.
  AssessmentRecommendation evaluate(Map<BodyPart, CapabilityGrade> caps) {
    double score(BodyPart p) =>
        (caps[p] ?? CapabilityGrade.unavailable).scoreWeight;

    final rightHandScore = score(BodyPart.rightHand);
    final leftHandScore = score(BodyPart.leftHand);
    final wristScore = score(BodyPart.wrist);
    final headScore = score(BodyPart.head);
    final faceScore = score(BodyPart.facialMuscles);
    final eyesScore = score(BodyPart.eyes);
    final blinkScore = score(BodyPart.blink);
    final touchScore = score(BodyPart.touchScreen);
    final singleMovementScore = score(BodyPart.singleSwitch);

    final bestHandScore = rightHandScore > leftHandScore ? rightHandScore : leftHandScore;

    // Count how many distinct voluntary movement types are available (> 0.4)
    int availableModalitiesCount = 0;
    if (bestHandScore >= 0.4) availableModalitiesCount++;
    if (headScore >= 0.4) availableModalitiesCount++;
    if (faceScore >= 0.4) availableModalitiesCount++;
    if (blinkScore >= 0.4 || eyesScore >= 0.4) availableModalitiesCount++;
    if (touchScore >= 0.5) availableModalitiesCount++;

    final isSingleMovementOnly = availableModalitiesCount <= 1 &&
        (bestHandScore >= 0.25 || headScore >= 0.25 || faceScore >= 0.25 || blinkScore >= 0.25 || singleMovementScore >= 0.25);

    AccessModality primary;
    AccessModality? backup;
    String reasoning;

    if (isSingleMovementOnly && availableModalitiesCount <= 1 && bestHandScore < 0.5 && touchScore < 0.5) {
      primary = AccessModality.singleSwitchScanning;
      backup = blinkScore >= 0.5 ? AccessModality.eyeBlinkGaze : null;
      reasoning = 'Single voluntary movement detected. Auto-scanning interface provides effortless access with one trigger.';
    } else if (touchScore >= 0.8) {
      primary = AccessModality.touchScreen;
      backup = bestHandScore >= 0.5 ? AccessModality.handGestures : AccessModality.eyeBlinkGaze;
      reasoning = 'Direct touch capability is strong. Touch UI provides immediate high-speed communication.';
    } else if (bestHandScore >= 0.5) {
      primary = AccessModality.handGestures;
      backup = blinkScore >= 0.5 ? AccessModality.eyeBlinkGaze : (headScore >= 0.5 ? AccessModality.headMovement : AccessModality.facialControls);
      reasoning = 'Finger / hand control is reliable. MediaPipe 3D gesture tracking maps natural voluntary movement.';
    } else if (blinkScore >= 0.7 || eyesScore >= 0.7) {
      primary = AccessModality.eyeBlinkGaze;
      backup = headScore >= 0.5 ? AccessModality.headMovement : AccessModality.facialControls;
      reasoning = 'Eye gaze and voluntary blink are most reliable. Dwell selection and blink confirmation enabled.';
    } else if (headScore >= 0.5) {
      primary = AccessModality.headMovement;
      backup = blinkScore >= 0.5 ? AccessModality.eyeBlinkGaze : AccessModality.facialControls;
      reasoning = 'Head movement tracking provides independent cursor and gesture selection.';
    } else if (faceScore >= 0.5) {
      primary = AccessModality.facialControls;
      backup = blinkScore >= 0.5 ? AccessModality.eyeBlinkGaze : null;
      reasoning = 'Facial expressions (smile, eyebrow raise, mouth) provide natural hands-free triggers.';
    } else {
      primary = AccessModality.singleSwitchScanning;
      backup = AccessModality.eyeBlinkGaze;
      reasoning = 'Single-switch scanning mode recommended for minimal fatigue and maximum accessibility.';
    }

    SensitivityLevel sensitivity;
    if (wristScore <= 0.25 && bestHandScore <= 0.4) {
      sensitivity = SensitivityLevel.low; // High tremor tolerance
    } else if (bestHandScore >= 0.8) {
      sensitivity = SensitivityLevel.high;
    } else {
      sensitivity = SensitivityLevel.medium;
    }

    final dummyProfile = PersonalAccessProfile(
      id: 'eval',
      patientName: 'Eval',
      capabilities: caps,
      primaryModality: primary,
    );

    return AssessmentRecommendation(
      primaryModality: primary,
      backupModality: backup,
      recommendedSensitivity: sensitivity,
      isSingleMovementOnly: isSingleMovementOnly,
      reasoning: reasoning,
      capabilityScores: dummyProfile.capabilityScores,
    );
  }
}

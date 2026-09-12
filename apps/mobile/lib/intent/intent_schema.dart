// intent_schema.dart
// Dart mirror of services/intent/src/neurobridge_intent/schema.py.
//
// Feature ORDER is a contract shared with the Python trainer. The exported
// model bundle carries the same lists in manifest.json and the runtime refuses
// to load a bundle whose schema differs.

/// Nominal analysis rate; camera observations are resampled onto this grid.
const double kFrameRateHz = 20.0;
const double kWindowSeconds = 2.5;
const double kSequenceSeconds = 3.0;
const int kWindowFrames = 50; // kWindowSeconds * kFrameRateHz
const int kSequenceFrames = 60; // kSequenceSeconds * kFrameRateHz

const String kFrameSchemaVersion = 'nb-intent-frame-v1';
const String kWindowSchemaVersion = 'nb-intent-window-v1';
const String kBundleSchemaVersion = 'nb-intent-bundle-v1';
const String kProfileSchemaVersion = 'neurobridge-patient-profile-v1';

/// Per-frame feature channels (28). Order is part of the contract.
const List<String> kFrameFeatures = [
  'ear_left',
  'ear_right',
  'ear_mean',
  'mouth_open_ratio',
  'smile_ratio',
  'mouth_asymmetry',
  'lip_motion',
  'brow_raise',
  'head_yaw',
  'head_pitch',
  'head_roll',
  'head_angular_speed',
  'face_cx',
  'face_cy',
  'face_scale',
  'hand_present',
  'wrist_x',
  'wrist_y',
  'hand_speed',
  'hand_accel',
  'hand_direction',
  'elbow_angle',
  'shoulder_motion',
  'flow_mag_mean',
  'flow_mag_std',
  'flow_dir_consistency',
  'flow_dominant_hz',
  'flow_hf_ratio',
];
const int kFrameFeatureCount = 28;

/// Channel indexes for readable access.
abstract final class F {
  static const earLeft = 0;
  static const earRight = 1;
  static const earMean = 2;
  static const mouthOpenRatio = 3;
  static const smileRatio = 4;
  static const mouthAsymmetry = 5;
  static const lipMotion = 6;
  static const browRaise = 7;
  static const headYaw = 8;
  static const headPitch = 9;
  static const headRoll = 10;
  static const headAngularSpeed = 11;
  static const faceCx = 12;
  static const faceCy = 13;
  static const faceScale = 14;
  static const handPresent = 15;
  static const wristX = 16;
  static const wristY = 17;
  static const handSpeed = 18;
  static const handAccel = 19;
  static const handDirection = 20;
  static const elbowAngle = 21;
  static const shoulderMotion = 22;
  static const flowMagMean = 23;
  static const flowMagStd = 24;
  static const flowDirConsistency = 25;
  static const flowDominantHz = 26;
  static const flowHfRatio = 27;
}

const List<String> kChannelStats = [
  'mean',
  'std',
  'min',
  'max',
  'range',
  'mean_abs_diff',
];

const List<String> kEventFeatures = [
  'blink_count',
  'blink_mean_duration_ms',
  'blink_duration_cv',
  'blink_interval_cv',
  'blink_rate_hz',
  'head_dominant_hz',
  'head_rhythmicity',
  'face_jerk_rms',
  'face_smoothness',
  'hold_fraction',
  'direction_consistency',
  'onset_count',
  'peak_amplitude',
  'sustained_seconds',
];

/// 28 * 6 + 14 = 182 window features.
const int kWindowFeatureCount = kFrameFeatureCount * 6 + 14;

List<String> windowFeatureNames() => [
      for (final channel in kFrameFeatures)
        for (final stat in kChannelStats) '${channel}_$stat',
      ...kEventFeatures,
    ];

/// Temporal-model vocabulary (movement patterns, not phrases).
abstract final class CommandClass {
  static const nonCommand = 'non_command';
  static const tripleBlink = 'triple_blink';
  static const doubleBlink = 'double_blink';
  static const longBlink = 'long_blink';
  static const mouthOpenHold = 'mouth_open_hold';
  static const smileHold = 'smile_hold';
  static const browRaiseHold = 'brow_raise_hold';
  static const headLeftHold = 'head_left_hold';
  static const headRightHold = 'head_right_hold';
  static const handRaiseHold = 'hand_raise_hold';

  static const List<String> all = [
    nonCommand,
    tripleBlink,
    doubleBlink,
    longBlink,
    mouthOpenHold,
    smileHold,
    browRaiseHold,
    headLeftHold,
    headRightHold,
    handRaiseHold,
  ];
}

abstract final class IntentClass {
  static const intentional = 'intentional';
  static const accidental = 'accidental';
  static const unknown = 'unknown';
}

abstract final class AbnormalClass {
  static const normalVoluntary = 'normal_voluntary';
  static const involuntary = 'involuntary';
  static const possibleSpasm = 'possible_spasm';
  static const possibleSeizureLike = 'possible_seizure_like';
  static const List<String> all = [
    normalVoluntary,
    involuntary,
    possibleSpasm,
    possibleSeizureLike,
  ];
}

abstract final class CalibrationPhase {
  static const normalBlinking = 'normal_blinking';
  static const normalFacialMovement = 'normal_facial_movement';
  static const intentionalGestures = 'intentional_gestures';
  static const randomMovement = 'random_movement';
  static const restState = 'rest_state';
  static const List<String> all = [
    normalBlinking,
    normalFacialMovement,
    intentionalGestures,
    randomMovement,
    restState,
  ];
  static const double seconds = 30.0;
}

/// Default mapping from a verified command pattern to the app's signal kind name.
const Map<String, String> kDefaultCommandSignals = {
  CommandClass.tripleBlink: 'rapidBlink',
  CommandClass.doubleBlink: 'blink',
  CommandClass.longBlink: 'slowBlink',
  CommandClass.mouthOpenHold: 'mouthOpen',
  CommandClass.smileHold: 'smile',
  CommandClass.browRaiseHold: 'eyebrowsUp',
  CommandClass.headLeftHold: 'headLeft',
  CommandClass.headRightHold: 'headRight',
  CommandClass.handRaiseHold: 'handRaised',
};

const double kIgnoreBelow = 0.70;
const double kExecuteAt = 0.90;

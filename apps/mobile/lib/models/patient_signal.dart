enum PatientSignalKind {
  facePresent,
  faceLost,
  smile,
  smileLeft,
  smileRight,
  blink,
  rapidBlink,
  slowBlink,
  leftWink,
  rightWink,
  eyeLookLeft,
  eyeLookRight,
  eyeLookCenter,
  eyeLookUp,
  eyeLookDown,
  eyeTremor,
  eyebrowsUp,
  mouthOpen,
  headLeft,
  headRight,
  headTurnSlow,
  headTurnRapid,
  headNodSmile,
  facialMovement,
  lipTremor,
  facialMuscleMovement,
  breathingNormal,
  breathingRapid,
  breathingShallow,
  breathingPause,
  handGesture,
  handRaised,
  handOpenPalm,
  handFist,
  handIndexPoint,
  seizureAlert,
}

enum SignalCategory {
  eyes,
  face,
  head,
  breathing,
  hands,
  emergency,
}

extension PatientSignalKindExtension on PatientSignalKind {
  SignalCategory get category => switch (this) {
        PatientSignalKind.blink ||
        PatientSignalKind.rapidBlink ||
        PatientSignalKind.slowBlink ||
        PatientSignalKind.leftWink ||
        PatientSignalKind.rightWink ||
        PatientSignalKind.eyeLookLeft ||
        PatientSignalKind.eyeLookRight ||
        PatientSignalKind.eyeLookCenter ||
        PatientSignalKind.eyeLookUp ||
        PatientSignalKind.eyeLookDown ||
        PatientSignalKind.eyeTremor =>
          SignalCategory.eyes,
        PatientSignalKind.smile ||
        PatientSignalKind.smileLeft ||
        PatientSignalKind.smileRight ||
        PatientSignalKind.eyebrowsUp ||
        PatientSignalKind.mouthOpen ||
        PatientSignalKind.facialMovement ||
        PatientSignalKind.lipTremor ||
        PatientSignalKind.facialMuscleMovement =>
          SignalCategory.face,
        PatientSignalKind.headLeft ||
        PatientSignalKind.headRight ||
        PatientSignalKind.headTurnSlow ||
        PatientSignalKind.headTurnRapid ||
        PatientSignalKind.headNodSmile =>
          SignalCategory.head,
        PatientSignalKind.breathingNormal ||
        PatientSignalKind.breathingRapid ||
        PatientSignalKind.breathingShallow ||
        PatientSignalKind.breathingPause =>
          SignalCategory.breathing,
        PatientSignalKind.handGesture ||
        PatientSignalKind.handRaised ||
        PatientSignalKind.handOpenPalm ||
        PatientSignalKind.handFist ||
        PatientSignalKind.handIndexPoint =>
          SignalCategory.hands,
        PatientSignalKind.seizureAlert ||
        PatientSignalKind.facePresent ||
        PatientSignalKind.faceLost =>
          SignalCategory.emergency,
      };

  String get displayName => switch (this) {
        PatientSignalKind.facePresent => 'Face aligned in frame',
        PatientSignalKind.faceLost => 'Face moved away',
        PatientSignalKind.smile => 'Gentle symmetrical smile',
        PatientSignalKind.smileLeft => 'Smile towards left lip only',
        PatientSignalKind.smileRight => 'Smile towards right lip only',
        PatientSignalKind.blink => 'Deliberate blink',
        PatientSignalKind.rapidBlink => 'Rapid eye blink flurry',
        PatientSignalKind.slowBlink => 'Slow / prolonged blink',
        PatientSignalKind.leftWink => 'Left-eye wink only',
        PatientSignalKind.rightWink => 'Right-eye wink only',
        PatientSignalKind.eyeLookLeft => 'Eyes look left',
        PatientSignalKind.eyeLookRight => 'Eyes look right',
        PatientSignalKind.eyeLookCenter => 'Gaze straight at camera',
        PatientSignalKind.eyeLookUp => 'Eyes look up',
        PatientSignalKind.eyeLookDown => 'Eyes look down',
        PatientSignalKind.eyeTremor => 'Eye micro-tremor',
        PatientSignalKind.eyebrowsUp => 'Raise eyebrows',
        PatientSignalKind.mouthOpen => 'Open mouth',
        PatientSignalKind.headLeft => 'Turn head left',
        PatientSignalKind.headRight => 'Turn head right',
        PatientSignalKind.headTurnSlow => 'Move head slowly',
        PatientSignalKind.headTurnRapid => 'Move head rapidly',
        PatientSignalKind.headNodSmile => 'Move head while smiling',
        PatientSignalKind.facialMovement => 'Facial movement',
        PatientSignalKind.lipTremor => 'Lip micro-tremor',
        PatientSignalKind.facialMuscleMovement => 'Facial muscle activity',
        PatientSignalKind.breathingNormal => 'Breathing normal',
        PatientSignalKind.breathingRapid => 'Rapid breathing pattern',
        PatientSignalKind.breathingShallow => 'Shallow breathing pattern',
        PatientSignalKind.breathingPause => 'Breathing pause detected',
        PatientSignalKind.handGesture => 'Hand gesture',
        PatientSignalKind.handRaised => 'Raise one hand',
        PatientSignalKind.handOpenPalm => 'Open palm facing camera',
        PatientSignalKind.handFist => 'Closed fist gesture',
        PatientSignalKind.handIndexPoint => 'Pointing index finger',
        PatientSignalKind.seizureAlert => 'Sudden seizure alert',
      };
}

class PatientSignal {
  const PatientSignal({
    required this.kind,
    required this.confidence,
    required this.observedAt,
    this.sourceLabel,
    this.metadata,
  });

  final PatientSignalKind kind;
  final double confidence;
  final DateTime observedAt;
  final String? sourceLabel;
  final Map<String, Object?>? metadata;
}

enum MonitorLifecycle { stopped, starting, active, unavailable, error }

class MonitorStatus {
  const MonitorStatus({
    required this.lifecycle,
    required this.message,
    this.faceDetected = false,
    this.leftEyeOpen,
    this.rightEyeOpen,
    this.eyebrowDistance,
    this.mouthDistance,
    this.smileProbability,
    this.headYaw,
    this.headPitch,
    this.lipTremorDetected = false,
    this.eyeTremorDetected = false,
    this.breathingRatePerMin,
    this.breathingStatus = 'Normal',
    this.facialMuscleTension,
  });

  const MonitorStatus.stopped()
      : this(
          lifecycle: MonitorLifecycle.stopped,
          message: 'Continuous monitoring is off',
        );

  final MonitorLifecycle lifecycle;
  final String message;
  final bool faceDetected;
  final double? leftEyeOpen;
  final double? rightEyeOpen;
  final double? eyebrowDistance;
  final double? mouthDistance;
  final double? smileProbability;
  final double? headYaw;
  final double? headPitch;
  final bool lipTremorDetected;
  final bool eyeTremorDetected;
  final double? breathingRatePerMin;
  final String breathingStatus;
  final double? facialMuscleTension;
}

class CalibratedPhrase {
  const CalibratedPhrase({
    required this.signal,
    required this.key,
    required this.phrase,
    this.minimumConfidence = 0.72,
    this.dwell = Duration.zero,
    this.sensitivity = 0.75,
  });

  final PatientSignalKind signal;
  final String key;
  final String phrase;
  final double minimumConfidence;
  final Duration dwell;
  final double sensitivity;

  Map<String, Object> toJson() => {
        'signal': signal.name,
        'key': key,
        'phrase': phrase,
        'minimum_confidence': minimumConfidence,
        'dwell_ms': dwell.inMilliseconds,
        'sensitivity': sensitivity,
      };

  factory CalibratedPhrase.fromJson(Map<String, Object?> json) {
    return CalibratedPhrase(
      signal: PatientSignalKind.values.byName(json['signal']! as String),
      key: json['key']! as String,
      phrase: json['phrase']! as String,
      minimumConfidence:
          (json['minimum_confidence'] as num?)?.toDouble() ?? 0.72,
      dwell: Duration(milliseconds: (json['dwell_ms'] as int?) ?? 0),
      sensitivity: (json['sensitivity'] as num?)?.toDouble() ?? 0.75,
    );
  }
}

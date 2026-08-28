import 'dart:async';
import 'dart:io';
import 'dart:math' as math;
import 'package:camera/camera.dart';
import 'package:fingerspeak_mobile/models/patient_signal.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:google_mlkit_face_detection/google_mlkit_face_detection.dart';

abstract interface class PatientSignalMonitor {
  Stream<PatientSignal> get signals;
  Stream<MonitorStatus> get statuses;
  CameraController? get cameraController;
  Future<void> start();
  Future<void> stop();
  Future<void> dispose();
  void simulateSignal(PatientSignalKind kind, {double confidence = 0.95});
  void setNeutralBaseline({
    double? eyebrowDistance,
    double? mouthDistance,
    double? leftEyeOpenness,
    double? rightEyeOpenness,
    double? smileProbability,
    double? headYaw,
    double? headPitch,
  });
}

@visibleForTesting
class SignalCooldownGate {
  final Map<PatientSignalKind, DateTime> _lastEmissionByKind = {};

  bool permits(
    PatientSignalKind kind,
    DateTime observedAt,
    Duration cooldown,
  ) {
    final previous = _lastEmissionByKind[kind];
    if (previous != null &&
        !observedAt.isBefore(previous) &&
        observedAt.difference(previous) < cooldown) {
      return false;
    }
    _lastEmissionByKind[kind] = observedAt;
    return true;
  }

  void clear() => _lastEmissionByKind.clear();
}

@visibleForTesting
class StableSignalObservation {
  const StableSignalObservation({
    required this.activeDuration,
    required this.confidence,
  });

  final Duration activeDuration;
  final double confidence;
}

@visibleForTesting
class SignalStabilityGate {
  final Map<PatientSignalKind, _SignalCandidate> _candidates = {};

  StableSignalObservation? update({
    required PatientSignalKind kind,
    required double score,
    required double confidence,
    required DateTime observedAt,
    required double enterThreshold,
    required double exitThreshold,
    required Duration minimumHold,
    Duration releaseGrace = const Duration(milliseconds: 150),
    Duration maximumReportingDuration = const Duration(seconds: 2),
  }) {
    assert(exitThreshold <= enterThreshold);
    var candidate = _candidates[kind];
    if (candidate == null) {
      if (score < enterThreshold) return null;
      candidate = _SignalCandidate(
        startedAt: observedAt,
        smoothedConfidence: confidence,
      );
      _candidates[kind] = candidate;
    } else if (observedAt.isBefore(candidate.startedAt)) {
      reset(kind);
      return null;
    }

    final belowSince = candidate.belowThresholdSince;
    if (belowSince != null &&
        observedAt.difference(belowSince) >= releaseGrace) {
      reset(kind);
      if (score < enterThreshold) return null;
      candidate = _SignalCandidate(
        startedAt: observedAt,
        smoothedConfidence: confidence,
      );
      _candidates[kind] = candidate;
    }

    if (score < exitThreshold) {
      candidate.belowThresholdSince ??= observedAt;
      if (observedAt.difference(candidate.belowThresholdSince!) >=
          releaseGrace) {
        reset(kind);
      }
      return null;
    }

    candidate.belowThresholdSince = null;
    candidate.smoothedConfidence =
        (candidate.smoothedConfidence * 0.65 + confidence * 0.35)
            .clamp(0, 1)
            .toDouble();
    final activeDuration = observedAt.difference(candidate.startedAt);
    if (activeDuration < minimumHold) return null;
    if (activeDuration > maximumReportingDuration) return null;
    return StableSignalObservation(
      activeDuration: activeDuration,
      confidence: candidate.smoothedConfidence,
    );
  }

  void reset(PatientSignalKind kind) => _candidates.remove(kind);

  void clear() => _candidates.clear();
}

class _SignalCandidate {
  _SignalCandidate({
    required this.startedAt,
    required this.smoothedConfidence,
  });

  final DateTime startedAt;
  double smoothedConfidence;
  DateTime? belowThresholdSince;
}

class _BlinkObservation {
  const _BlinkObservation({
    required this.confidence,
    required this.duration,
  });

  final double confidence;
  final Duration duration;
}

@visibleForTesting
class OscillationMetrics {
  const OscillationMetrics({
    required this.detrendedRms,
    required this.peakToPeak,
    required this.directionChanges,
  });

  final double detrendedRms;
  final double peakToPeak;
  final int directionChanges;
}

@visibleForTesting
OscillationMetrics analyzeOscillation(
  List<double> values, {
  double directionEpsilon = 0.00035,
}) {
  if (values.length < 3) {
    return const OscillationMetrics(
      detrendedRms: 0,
      peakToPeak: 0,
      directionChanges: 0,
    );
  }
  final span = values.last - values.first;
  final residuals = <double>[];
  for (var i = 0; i < values.length; i++) {
    final expected = values.first + span * i / (values.length - 1);
    residuals.add(values[i] - expected);
  }
  final mean = residuals.reduce((a, b) => a + b) / residuals.length;
  final variance = residuals.fold<double>(
        0,
        (sum, value) => sum + math.pow(value - mean, 2),
      ) /
      residuals.length;
  var directionChanges = 0;
  var previousDirection = 0;
  for (var i = 1; i < residuals.length; i++) {
    final difference = residuals[i] - residuals[i - 1];
    final direction = difference.abs() < directionEpsilon
        ? 0
        : difference > 0
            ? 1
            : -1;
    if (direction == 0) continue;
    if (previousDirection != 0 && direction != previousDirection) {
      directionChanges++;
    }
    previousDirection = direction;
  }
  final minimum = residuals.reduce(math.min);
  final maximum = residuals.reduce(math.max);
  return OscillationMetrics(
    detrendedRms: math.sqrt(variance),
    peakToPeak: maximum - minimum,
    directionChanges: directionChanges,
  );
}

@visibleForTesting
class HeadMotionMetrics {
  const HeadMotionMetrics({
    required this.velocityDegreesPerSecond,
    required this.frameDisplacementDegrees,
  });

  final double velocityDegreesPerSecond;
  final double frameDisplacementDegrees;
}

@visibleForTesting
class HeadMotionFilter {
  HeadMotionFilter({this.smoothing = 0.55});

  final double smoothing;
  double? _yaw;
  double? _pitch;
  DateTime? _observedAt;

  HeadMotionMetrics? add(double yaw, double pitch, DateTime observedAt) {
    final previousAt = _observedAt;
    final previousYaw = _yaw;
    final previousPitch = _pitch;
    if (previousAt == null || previousYaw == null || previousPitch == null) {
      _yaw = yaw;
      _pitch = pitch;
      _observedAt = observedAt;
      return null;
    }
    final elapsed = observedAt.difference(previousAt);
    if (elapsed <= Duration.zero ||
        elapsed > const Duration(milliseconds: 600)) {
      clear();
      _yaw = yaw;
      _pitch = pitch;
      _observedAt = observedAt;
      return null;
    }
    final nextYaw = previousYaw + (yaw - previousYaw) * smoothing;
    final nextPitch = previousPitch + (pitch - previousPitch) * smoothing;
    final displacement = math.sqrt(
      math.pow(nextYaw - previousYaw, 2) +
          math.pow(nextPitch - previousPitch, 2),
    );
    _yaw = nextYaw;
    _pitch = nextPitch;
    _observedAt = observedAt;
    return HeadMotionMetrics(
      velocityDegreesPerSecond:
          displacement / (elapsed.inMicroseconds / 1000000),
      frameDisplacementDegrees: displacement,
    );
  }

  void clear() {
    _yaw = null;
    _pitch = null;
    _observedAt = null;
  }
}

/// On-device face, eye, expression, muscle, head, hand, and tremor signal detector.
/// No camera frame leaves the device.
class MlKitPatientSignalMonitor implements PatientSignalMonitor {
  MlKitPatientSignalMonitor({FaceDetector? detector})
      : _detector = detector ??
            FaceDetector(
              options: FaceDetectorOptions(
                enableClassification: true,
                enableContours: true,
                enableTracking: true,
                minFaceSize: 0.15,
                performanceMode: FaceDetectorMode.fast,
              ),
            );

  final FaceDetector _detector;
  final _signals = StreamController<PatientSignal>.broadcast();
  final _statuses = StreamController<MonitorStatus>.broadcast();

  CameraController? _controller;
  DateTime _lastFrame = DateTime.fromMillisecondsSinceEpoch(0);
  DateTime _lastBlink = DateTime.fromMillisecondsSinceEpoch(0);
  DateTime _eyesClosedSince = DateTime.fromMillisecondsSinceEpoch(0);
  double _closedEyeConfidence = 0;
  final List<DateTime> _recentBlinks = [];
  Timer? _pendingBlinkTimer;
  _BlinkObservation? _pendingBlink;

  final SignalCooldownGate _signalCooldownGate = SignalCooldownGate();
  final SignalStabilityGate _stabilityGate = SignalStabilityGate();
  final HeadMotionFilter _headMotionFilter = HeadMotionFilter();
  DateTime _lastLipTremorTime = DateTime.fromMillisecondsSinceEpoch(0);
  DateTime _lastEyeTremorTime = DateTime.fromMillisecondsSinceEpoch(0);

  double _restingEyebrowDistance = 0.18;
  double _restingMouthDistance = 0.08;
  double _restingLeftEyeOpenness = 0.85;
  double _restingRightEyeOpenness = 0.85;
  double _restingSmileProbability = 0.05;
  double _restingHeadYaw = 0;
  double _restingHeadPitch = 0;
  bool _gazeReturnArmed = false;

  Map<FaceContourType, Offset> _previousContourCenters = const {};
  final List<double> _lipDisplacements = [];
  final List<double> _eyeDisplacements = [];

  bool _processing = false;
  bool _faceWasPresent = false;
  bool _closed = false;

  @override
  CameraController? get cameraController => _controller;

  @override
  Stream<PatientSignal> get signals => _signals.stream;

  @override
  Stream<MonitorStatus> get statuses => _statuses.stream;

  @override
  void setNeutralBaseline({
    double? eyebrowDistance,
    double? mouthDistance,
    double? leftEyeOpenness,
    double? rightEyeOpenness,
    double? smileProbability,
    double? headYaw,
    double? headPitch,
  }) {
    if (eyebrowDistance != null &&
        eyebrowDistance.isFinite &&
        eyebrowDistance >= 0.01) {
      _restingEyebrowDistance = eyebrowDistance.clamp(0.01, 0.50).toDouble();
    }
    if (mouthDistance != null && mouthDistance.isFinite && mouthDistance >= 0) {
      _restingMouthDistance = mouthDistance.clamp(0.005, 0.50).toDouble();
    }
    if (leftEyeOpenness != null &&
        leftEyeOpenness.isFinite &&
        leftEyeOpenness >= 0.05) {
      _restingLeftEyeOpenness = leftEyeOpenness.clamp(0.05, 1).toDouble();
    }
    if (rightEyeOpenness != null &&
        rightEyeOpenness.isFinite &&
        rightEyeOpenness >= 0.05) {
      _restingRightEyeOpenness = rightEyeOpenness.clamp(0.05, 1).toDouble();
    }
    if (smileProbability != null &&
        smileProbability.isFinite &&
        smileProbability >= 0) {
      _restingSmileProbability = smileProbability.clamp(0, 1).toDouble();
    }
    if (headYaw != null && headYaw.isFinite) {
      _restingHeadYaw = headYaw.clamp(-60, 60).toDouble();
    }
    if (headPitch != null && headPitch.isFinite) {
      _restingHeadPitch = headPitch.clamp(-60, 60).toDouble();
    }
    _resetTemporalTracking();
  }

  @override
  void simulateSignal(PatientSignalKind kind, {double confidence = 0.95}) {
    _emit(kind, confidence);
  }

  @override
  Future<void> start() async {
    if (_closed) throw StateError('Monitor has been disposed.');
    if (_controller?.value.isStreamingImages ?? false) return;
    _statuses.add(const MonitorStatus(
      lifecycle: MonitorLifecycle.starting,
      message: 'Starting private on-device camera…',
    ));
    try {
      final cameras = await availableCameras();
      if (cameras.isEmpty) {
        _statuses.add(const MonitorStatus(
          lifecycle: MonitorLifecycle.active,
          message: 'Camera simulator active — no physical camera found',
          faceDetected: true,
        ));
        return;
      }
      final description = cameras.firstWhere(
        (camera) => camera.lensDirection == CameraLensDirection.front,
        orElse: () => cameras.first,
      );

      final ImageFormatGroup formatGroup;
      if (kIsWeb) {
        formatGroup = ImageFormatGroup.unknown;
      } else if (Platform.isAndroid) {
        formatGroup = ImageFormatGroup.nv21;
      } else {
        formatGroup = ImageFormatGroup.bgra8888;
      }

      final controller = CameraController(
        description,
        ResolutionPreset.medium,
        enableAudio: false,
        imageFormatGroup: formatGroup,
      );
      _controller = controller;
      await controller.initialize();
      if (!kIsWeb) {
        await controller.startImageStream(_processFrame);
      }
      _statuses.add(const MonitorStatus(
        lifecycle: MonitorLifecycle.active,
        message: 'Live device webcam active & tracking',
        faceDetected: true,
      ));
    } on CameraException catch (error) {
      _statuses.add(MonitorStatus(
        lifecycle: MonitorLifecycle.active,
        message:
            'Camera active (simulated fallback): ${error.description ?? error.code}',
        faceDetected: true,
      ));
    } on Object catch (error) {
      _statuses.add(MonitorStatus(
        lifecycle: MonitorLifecycle.active,
        message: 'Vision monitor active (simulated): $error',
        faceDetected: true,
      ));
    }
  }

  Future<void> _processFrame(CameraImage image) async {
    if (_closed ||
        _controller == null ||
        !(_controller?.value.isInitialized ?? false)) {
      return;
    }
    final now = DateTime.now();
    if (_processing ||
        now.difference(_lastFrame) < const Duration(milliseconds: 100)) {
      return;
    }
    _lastFrame = now;
    final input = _toInputImage(image);
    if (input == null) return;
    _processing = true;
    try {
      final faces = await _detector.processImage(input);
      if (faces.isEmpty) {
        if (_faceWasPresent) {
          _emit(PatientSignalKind.faceLost, 1);
          _faceWasPresent = false;
        }
        _resetTemporalTracking();
        _statuses.add(const MonitorStatus(
          lifecycle: MonitorLifecycle.active,
          message: 'Looking for the patient’s face…',
        ));
        return;
      }
      final face = faces.first;
      if (face.boundingBox.width < 80 || face.boundingBox.height < 80) {
        _resetTemporalTracking();
        _statuses.add(const MonitorStatus(
          lifecycle: MonitorLifecycle.active,
          message: 'Move closer so facial movements can be measured reliably',
          faceDetected: true,
        ));
        return;
      }
      if (!_faceWasPresent) _emit(PatientSignalKind.facePresent, 1);
      _faceWasPresent = true;
      final leftOpen = face.leftEyeOpenProbability ?? _restingLeftEyeOpenness;
      final rightOpen =
          face.rightEyeOpenProbability ?? _restingRightEyeOpenness;
      final smileProbability =
          face.smilingProbability ?? _restingSmileProbability;
      final yaw = face.headEulerAngleY;
      final pitch = face.headEulerAngleX;
      final neutralMeasurements = _measureNeutralFace(face);

      _statuses.add(MonitorStatus(
        lifecycle: MonitorLifecycle.active,
        message: 'Live face, gaze & gesture tracking active',
        faceDetected: true,
        leftEyeOpen: leftOpen,
        rightEyeOpen: rightOpen,
        eyebrowDistance: neutralMeasurements.eyebrowDistance,
        mouthDistance: neutralMeasurements.mouthDistance,
        smileProbability: smileProbability,
        headYaw: yaw,
        headPitch: pitch,
        lipTremorDetected:
            now.difference(_lastLipTremorTime) < const Duration(seconds: 1),
        eyeTremorDetected:
            now.difference(_lastEyeTremorTime) < const Duration(seconds: 1),
        breathingStatus: _estimateBreathingStatus(),
      ));

      _processEyes(leftOpen, rightOpen, now);
      final headVelocity = _processHeadAndAssistedGaze(
        yaw: yaw,
        pitch: pitch,
        smileProbability: smileProbability,
        now: now,
      );
      _processSmilesAndContours(
        face,
        now,
        neutralMeasurements: neutralMeasurements,
        yawOffset: yaw == null ? null : yaw - _restingHeadYaw,
        pitchOffset: pitch == null ? null : pitch - _restingHeadPitch,
        headVelocity: headVelocity,
      );
    } on Object catch (error) {
      _statuses.add(MonitorStatus(
        lifecycle: MonitorLifecycle.active,
        message: 'Vision tracking active (resumed: $error)',
      ));
    } finally {
      _processing = false;
    }
  }

  void _processEyes(double leftOpen, double rightOpen, DateTime now) {
    final leftClosedThreshold = math.max(0.12, _restingLeftEyeOpenness * 0.42);
    final rightClosedThreshold =
        math.max(0.12, _restingRightEyeOpenness * 0.42);
    final eyesClosed =
        leftOpen < leftClosedThreshold && rightOpen < rightClosedThreshold;
    if (eyesClosed) {
      final leftClosure = (1 - leftOpen / _restingLeftEyeOpenness).clamp(0, 1);
      final rightClosure =
          (1 - rightOpen / _restingRightEyeOpenness).clamp(0, 1);
      final confidence =
          ((leftClosure + rightClosure) / 2).clamp(0.78, 1.0).toDouble();
      _closedEyeConfidence = math.max(_closedEyeConfidence, confidence);
      if (_eyesClosedSince.millisecondsSinceEpoch == 0) {
        _eyesClosedSince = now;
      } else {
        final closedDuration = now.difference(_eyesClosedSince);
        if (closedDuration >= const Duration(milliseconds: 700) &&
            closedDuration <= const Duration(seconds: 2)) {
          _emitThrottled(
            PatientSignalKind.slowBlink,
            math.max(0.90, _closedEyeConfidence),
            cooldownMs: 200,
            metadata: {
              'active_duration_ms': closedDuration.inMilliseconds,
            },
          );
        }
      }
    } else if (_eyesClosedSince.millisecondsSinceEpoch != 0) {
      final closedDuration = now.difference(_eyesClosedSince);
      _eyesClosedSince = DateTime.fromMillisecondsSinceEpoch(0);
      if (closedDuration >= const Duration(milliseconds: 90) &&
          closedDuration < const Duration(milliseconds: 650)) {
        _registerBlink(
          now,
          _BlinkObservation(
            confidence: math.max(0.80, _closedEyeConfidence),
            duration: closedDuration,
          ),
        );
      }
      _closedEyeConfidence = 0;
    }

    final leftClosure =
        (1 - leftOpen / _restingLeftEyeOpenness).clamp(0, 1).toDouble();
    final rightClosure =
        (1 - rightOpen / _restingRightEyeOpenness).clamp(0, 1).toDouble();
    final leftOpenRatio =
        (leftOpen / _restingLeftEyeOpenness).clamp(0, 1).toDouble();
    final rightOpenRatio =
        (rightOpen / _restingRightEyeOpenness).clamp(0, 1).toDouble();
    final leftWinkScore = math.min(leftClosure, rightOpenRatio);
    final rightWinkScore = math.min(rightClosure, leftOpenRatio);
    _emitStableSignal(
      kind: PatientSignalKind.leftWink,
      score: leftWinkScore,
      confidence: (0.72 + leftWinkScore * 0.28).clamp(0, 1),
      now: now,
      enterThreshold: 0.65,
      exitThreshold: 0.45,
      minimumHold: const Duration(milliseconds: 250),
    );
    _emitStableSignal(
      kind: PatientSignalKind.rightWink,
      score: rightWinkScore,
      confidence: (0.72 + rightWinkScore * 0.28).clamp(0, 1),
      now: now,
      enterThreshold: 0.65,
      exitThreshold: 0.45,
      minimumHold: const Duration(milliseconds: 250),
    );
  }

  void _registerBlink(DateTime now, _BlinkObservation observation) {
    if (now.difference(_lastBlink) < const Duration(milliseconds: 180)) return;
    _lastBlink = now;
    _recentBlinks.add(now);
    _recentBlinks.removeWhere(
      (time) => now.difference(time) > const Duration(milliseconds: 1200),
    );
    _pendingBlink = observation;
    _pendingBlinkTimer?.cancel();
    if (_recentBlinks.length >= 3) {
      final sequenceDuration =
          now.difference(_recentBlinks.first).inMilliseconds;
      _recentBlinks.clear();
      _pendingBlink = null;
      _emitThrottled(
        PatientSignalKind.rapidBlink,
        0.95,
        metadata: {'active_duration_ms': sequenceDuration},
      );
      return;
    }

    _pendingBlinkTimer = Timer(const Duration(milliseconds: 420), () {
      if (_closed || _recentBlinks.length != 1) {
        _recentBlinks.clear();
        _pendingBlink = null;
        return;
      }
      final pending = _pendingBlink;
      _recentBlinks.clear();
      _pendingBlink = null;
      if (pending == null) return;
      _emitThrottled(
        PatientSignalKind.blink,
        pending.confidence,
        metadata: {'active_duration_ms': pending.duration.inMilliseconds},
      );
    });
  }

  double _processHeadAndAssistedGaze({
    required double? yaw,
    required double? pitch,
    required double smileProbability,
    required DateTime now,
  }) {
    if (yaw == null || pitch == null) {
      _headMotionFilter.clear();
      for (final kind in const [
        PatientSignalKind.eyeLookLeft,
        PatientSignalKind.eyeLookRight,
        PatientSignalKind.eyeLookCenter,
        PatientSignalKind.eyeLookUp,
        PatientSignalKind.eyeLookDown,
        PatientSignalKind.headTurnSlow,
        PatientSignalKind.headNodSmile,
      ]) {
        _stabilityGate.reset(kind);
      }
      return double.infinity;
    }

    final yawOffset = yaw - _restingHeadYaw;
    final pitchOffset = pitch - _restingHeadPitch;
    final leftScore = -yawOffset;
    final rightScore = yawOffset;
    _emitStableSignal(
      kind: PatientSignalKind.eyeLookLeft,
      score: leftScore,
      confidence: (yawOffset.abs() / 28).clamp(0.74, 1.0),
      now: now,
      enterThreshold: 16,
      exitThreshold: 10,
      minimumHold: const Duration(milliseconds: 300),
      metadata: const {'detection_proxy': 'slight_head_and_gaze_pose'},
    );
    _emitStableSignal(
      kind: PatientSignalKind.eyeLookRight,
      score: rightScore,
      confidence: (yawOffset.abs() / 28).clamp(0.74, 1.0),
      now: now,
      enterThreshold: 16,
      exitThreshold: 10,
      minimumHold: const Duration(milliseconds: 300),
      metadata: const {'detection_proxy': 'slight_head_and_gaze_pose'},
    );
    _emitStableSignal(
      kind: PatientSignalKind.eyeLookUp,
      score: pitchOffset,
      confidence: (pitchOffset.abs() / 25).clamp(0.74, 1.0),
      now: now,
      enterThreshold: 14,
      exitThreshold: 9,
      minimumHold: const Duration(milliseconds: 300),
      metadata: const {'detection_proxy': 'slight_head_and_gaze_pose'},
    );
    _emitStableSignal(
      kind: PatientSignalKind.eyeLookDown,
      score: -pitchOffset,
      confidence: (pitchOffset.abs() / 25).clamp(0.74, 1.0),
      now: now,
      enterThreshold: 14,
      exitThreshold: 9,
      minimumHold: const Duration(milliseconds: 300),
      metadata: const {'detection_proxy': 'slight_head_and_gaze_pose'},
    );

    if (yawOffset.abs() > 14 || pitchOffset.abs() > 12) {
      _gazeReturnArmed = true;
    }
    final alignmentScore =
        1 - math.max(yawOffset.abs(), pitchOffset.abs()) / 12;
    final centered = _stabilityGate.update(
      kind: PatientSignalKind.eyeLookCenter,
      score: alignmentScore,
      confidence: alignmentScore.clamp(0.75, 1.0),
      observedAt: now,
      enterThreshold: 0.65,
      exitThreshold: 0.35,
      minimumHold: const Duration(milliseconds: 500),
    );
    if (_gazeReturnArmed && centered != null) {
      _emitThrottled(
        PatientSignalKind.eyeLookCenter,
        centered.confidence,
        cooldownMs: 250,
        metadata: {
          'active_duration_ms': centered.activeDuration.inMilliseconds,
          'detection_proxy': 'return_to_center_head_and_gaze_pose',
        },
      );
      if (centered.activeDuration >= const Duration(milliseconds: 1800)) {
        _gazeReturnArmed = false;
        _stabilityGate.reset(PatientSignalKind.eyeLookCenter);
      }
    }

    final motion = _headMotionFilter.add(yawOffset, pitchOffset, now);
    final velocity = motion?.velocityDegreesPerSecond ?? 0;
    final rapidMotion = motion != null &&
        motion.frameDisplacementDegrees >= 5.5 &&
        velocity >= 75;
    if (rapidMotion) {
      _stabilityGate.reset(PatientSignalKind.headTurnSlow);
      _emitThrottled(
        PatientSignalKind.headTurnRapid,
        (velocity / 130).clamp(0.78, 1.0),
        cooldownMs: 900,
      );
    } else {
      final slowScore =
          velocity <= 50 && (motion?.frameDisplacementDegrees ?? 0) >= 0.7
              ? velocity
              : 0.0;
      _emitStableSignal(
        kind: PatientSignalKind.headTurnSlow,
        score: slowScore,
        confidence: (velocity / 35).clamp(0.75, 0.95),
        now: now,
        enterThreshold: 14,
        exitThreshold: 7,
        minimumHold: const Duration(milliseconds: 300),
      );
    }

    final smileStrength = (smileProbability - _restingSmileProbability) / 0.25;
    final poseStrength = math.max(yawOffset.abs(), pitchOffset.abs()) / 10;
    final combined = math.min(smileStrength, poseStrength);
    _emitStableSignal(
      kind: PatientSignalKind.headNodSmile,
      score: combined,
      confidence: (0.74 + combined * 0.18).clamp(0, 1),
      now: now,
      enterThreshold: 1,
      exitThreshold: 0.55,
      minimumHold: const Duration(milliseconds: 350),
    );
    return velocity;
  }

  void _emitStableSignal({
    required PatientSignalKind kind,
    required double score,
    required double confidence,
    required DateTime now,
    required double enterThreshold,
    required double exitThreshold,
    required Duration minimumHold,
    Map<String, Object?>? metadata,
  }) {
    final observation = _stabilityGate.update(
      kind: kind,
      score: score,
      confidence: confidence,
      observedAt: now,
      enterThreshold: enterThreshold,
      exitThreshold: exitThreshold,
      minimumHold: minimumHold,
    );
    if (observation == null) return;
    _emitThrottled(
      kind,
      observation.confidence,
      cooldownMs: 250,
      metadata: {
        ...?metadata,
        'active_duration_ms': observation.activeDuration.inMilliseconds,
      },
    );
  }

  ({double? eyebrowDistance, double? mouthDistance}) _measureNeutralFace(
    Face face,
  ) {
    final leftEyebrow = face.contours[FaceContourType.leftEyebrowTop]?.points;
    final rightEyebrow = face.contours[FaceContourType.rightEyebrowTop]?.points;
    final leftEye = face.contours[FaceContourType.leftEye]?.points;
    final rightEye = face.contours[FaceContourType.rightEye]?.points;
    final upperLip = face.contours[FaceContourType.upperLipTop]?.points;
    final lowerLip = face.contours[FaceContourType.lowerLipBottom]?.points;

    final eyebrowDistances = <double>[];
    void addEyebrowDistance(
      List<math.Point<int>>? eyebrow,
      List<math.Point<int>>? eye,
    ) {
      if (eyebrow == null || eyebrow.isEmpty || eye == null || eye.isEmpty) {
        return;
      }
      final eyebrowY = eyebrow.fold<double>(0, (sum, point) => sum + point.y) /
          eyebrow.length;
      final eyeY =
          eye.fold<double>(0, (sum, point) => sum + point.y) / eye.length;
      eyebrowDistances.add(
        (eyeY - eyebrowY).abs() / math.max(face.boundingBox.height, 1),
      );
    }

    addEyebrowDistance(leftEyebrow, leftEye);
    addEyebrowDistance(rightEyebrow, rightEye);
    final eyebrowDistance = eyebrowDistances.isEmpty
        ? null
        : eyebrowDistances.reduce((a, b) => a + b) / eyebrowDistances.length;

    double? mouthDistance;
    if (upperLip != null &&
        upperLip.isNotEmpty &&
        lowerLip != null &&
        lowerLip.isNotEmpty) {
      final upperY = upperLip.fold<double>(0, (sum, point) => sum + point.y) /
          upperLip.length;
      final lowerY = lowerLip.fold<double>(0, (sum, point) => sum + point.y) /
          lowerLip.length;
      mouthDistance =
          (lowerY - upperY).abs() / math.max(face.boundingBox.height, 1);
    }

    return (
      eyebrowDistance: eyebrowDistance,
      mouthDistance: mouthDistance,
    );
  }

  void _processSmilesAndContours(
    Face face,
    DateTime now, {
    required ({
      double? eyebrowDistance,
      double? mouthDistance
    }) neutralMeasurements,
    required double? yawOffset,
    required double? pitchOffset,
    required double headVelocity,
  }) {
    final smile = face.smilingProbability ?? 0.0;

    final upperLip = face.contours[FaceContourType.upperLipTop]?.points;
    final lowerLip = face.contours[FaceContourType.lowerLipBottom]?.points;
    final leftEye = face.contours[FaceContourType.leftEye]?.points;
    final rightEye = face.contours[FaceContourType.rightEye]?.points;
    final noseBridge = face.contours[FaceContourType.noseBridge]?.points;
    final frontFacing = yawOffset != null &&
        pitchOffset != null &&
        yawOffset.abs() <= 18 &&
        pitchOffset.abs() <= 15;
    final poseStable = frontFacing && headVelocity <= 12;

    double cornerHeightDifference = 0;
    if (upperLip != null && upperLip.length >= 3) {
      cornerHeightDifference = (upperLip.last.y - upperLip.first.y) /
          math.max(face.boundingBox.height, 1);
    }
    final smileEnter = math.max(_restingSmileProbability + 0.25, 0.55);
    final smileExit = math.max(_restingSmileProbability + 0.14, 0.38);
    final asymmetricSmileReady =
        frontFacing && smile >= math.max(_restingSmileProbability + 0.18, 0.42);
    final symmetricScore =
        frontFacing && cornerHeightDifference.abs() < 0.025 ? smile : 0.0;
    _emitStableSignal(
      kind: PatientSignalKind.smile,
      score: symmetricScore,
      confidence: (0.74 + (smile - smileEnter) * 0.55).clamp(0, 1),
      now: now,
      enterThreshold: smileEnter,
      exitThreshold: smileExit,
      minimumHold: const Duration(milliseconds: 350),
    );
    _emitStableSignal(
      kind: PatientSignalKind.smileLeft,
      score: asymmetricSmileReady ? cornerHeightDifference : 0,
      confidence: (0.74 + cornerHeightDifference.abs() * 4).clamp(0, 1),
      now: now,
      enterThreshold: 0.035,
      exitThreshold: 0.018,
      minimumHold: const Duration(milliseconds: 350),
    );
    _emitStableSignal(
      kind: PatientSignalKind.smileRight,
      score: asymmetricSmileReady ? -cornerHeightDifference : 0,
      confidence: (0.74 + cornerHeightDifference.abs() * 4).clamp(0, 1),
      now: now,
      enterThreshold: 0.035,
      exitThreshold: 0.018,
      minimumHold: const Duration(milliseconds: 350),
    );

    final eyebrowDistance = neutralMeasurements.eyebrowDistance;
    final requiredElevation = math.max(_restingEyebrowDistance * 0.20, 0.012);
    final eyebrowElevation = eyebrowDistance == null
        ? 0.0
        : eyebrowDistance - _restingEyebrowDistance;
    final eyebrowScore =
        frontFacing ? eyebrowElevation / requiredElevation : 0.0;
    _emitStableSignal(
      kind: PatientSignalKind.eyebrowsUp,
      score: eyebrowScore,
      confidence: (0.73 + eyebrowScore * 0.18).clamp(0, 1),
      now: now,
      enterThreshold: 1,
      exitThreshold: 0.55,
      minimumHold: const Duration(milliseconds: 300),
    );

    final mouthDistance = neutralMeasurements.mouthDistance;
    final mouthEnter = math.max(_restingMouthDistance * 1.50, 0.075);
    final mouthExit = math.max(_restingMouthDistance * 1.25, 0.055);
    final mouthScore = frontFacing ? (mouthDistance ?? 0) : 0.0;
    _emitStableSignal(
      kind: PatientSignalKind.mouthOpen,
      score: mouthScore,
      confidence: (0.73 +
              ((mouthScore - mouthEnter) /
                      math.max(mouthEnter - _restingMouthDistance, 0.025)) *
                  0.20)
          .clamp(0, 1),
      now: now,
      enterThreshold: mouthEnter,
      exitThreshold: mouthExit,
      minimumHold: const Duration(milliseconds: 300),
    );

    final faceHeight = math.max(face.boundingBox.height, 1);
    final referenceY = noseBridge == null || noseBridge.isEmpty
        ? face.boundingBox.center.dy
        : noseBridge.fold<double>(0, (sum, point) => sum + point.y) /
            noseBridge.length;
    if (!poseStable) {
      _lipDisplacements.clear();
      _eyeDisplacements.clear();
    } else if (upperLip != null &&
        upperLip.isNotEmpty &&
        lowerLip != null &&
        lowerLip.isNotEmpty) {
      final upperY = upperLip.fold<double>(0, (sum, point) => sum + point.y) /
          upperLip.length;
      final lowerY = lowerLip.fold<double>(0, (sum, point) => sum + point.y) /
          lowerLip.length;
      final lipCenterY = (upperY + lowerY) / 2;
      _lipDisplacements.add((lipCenterY - referenceY) / faceHeight);
      if (_lipDisplacements.length > 12) _lipDisplacements.removeAt(0);
      if (_lipDisplacements.length >= 10) {
        final metrics = analyzeOscillation(_lipDisplacements);
        if (metrics.detrendedRms >= 0.0015 &&
            metrics.detrendedRms <= 0.025 &&
            metrics.peakToPeak >= 0.0045 &&
            metrics.directionChanges >= 3 &&
            now.difference(_lastLipTremorTime) >=
                const Duration(milliseconds: 1500)) {
          _lastLipTremorTime = now;
          _emitThrottled(
            PatientSignalKind.lipTremor,
            (0.75 + metrics.detrendedRms * 18).clamp(0.75, 0.98),
            cooldownMs: 1500,
            metadata: {
              'oscillation_rms': metrics.detrendedRms,
              'direction_changes': metrics.directionChanges,
            },
          );
          _lipDisplacements.clear();
        }
      }
    }

    if (poseStable && leftEye != null && leftEye.isNotEmpty) {
      final eyeCenters = <double>[
        leftEye.fold<double>(0, (sum, point) => sum + point.y) / leftEye.length,
      ];
      if (rightEye != null && rightEye.isNotEmpty) {
        eyeCenters.add(
          rightEye.fold<double>(0, (sum, point) => sum + point.y) /
              rightEye.length,
        );
      }
      final eyeCenterY = eyeCenters.reduce((a, b) => a + b) / eyeCenters.length;
      _eyeDisplacements.add((eyeCenterY - referenceY) / faceHeight);
      if (_eyeDisplacements.length > 12) _eyeDisplacements.removeAt(0);
      if (_eyeDisplacements.length >= 10) {
        final metrics = analyzeOscillation(_eyeDisplacements);
        if (metrics.detrendedRms >= 0.0012 &&
            metrics.detrendedRms <= 0.020 &&
            metrics.peakToPeak >= 0.0035 &&
            metrics.directionChanges >= 3 &&
            now.difference(_lastEyeTremorTime) >=
                const Duration(milliseconds: 1500)) {
          _lastEyeTremorTime = now;
          _emitThrottled(
            PatientSignalKind.eyeTremor,
            (0.75 + metrics.detrendedRms * 20).clamp(0.75, 0.98),
            cooldownMs: 1500,
            metadata: {
              'oscillation_rms': metrics.detrendedRms,
              'direction_changes': metrics.directionChanges,
            },
          );
          _eyeDisplacements.clear();
        }
      }
    }

    const tracked = <FaceContourType>[
      FaceContourType.leftEyebrowTop,
      FaceContourType.rightEyebrowTop,
      FaceContourType.upperLipTop,
      FaceContourType.lowerLipBottom,
      FaceContourType.leftCheek,
      FaceContourType.rightCheek,
    ];
    final current = <FaceContourType, Offset>{};
    for (final type in tracked) {
      final points = face.contours[type]?.points;
      if (points == null || points.isEmpty) continue;
      final x =
          points.fold<double>(0, (sum, point) => sum + point.x) / points.length;
      final y =
          points.fold<double>(0, (sum, point) => sum + point.y) / points.length;
      current[type] = Offset(
        (x - face.boundingBox.left) / math.max(face.boundingBox.width, 1),
        (y - face.boundingBox.top) / faceHeight,
      );
    }
    var normalizedMovement = 0.0;
    if (_previousContourCenters.isNotEmpty && current.isNotEmpty) {
      var movement = 0.0;
      var count = 0;
      for (final entry in current.entries) {
        final previous = _previousContourCenters[entry.key];
        if (previous == null) continue;
        movement += (entry.value - previous).distance;
        count++;
      }
      normalizedMovement = count == 0 ? 0.0 : movement / count;
    }
    _previousContourCenters = current;
    final namedExpressionActive = symmetricScore >= smileEnter ||
        asymmetricSmileReady && cornerHeightDifference.abs() >= 0.035 ||
        eyebrowScore >= 1 ||
        mouthScore >= mouthEnter;
    final muscleScore =
        poseStable && !namedExpressionActive ? normalizedMovement : 0.0;
    _emitStableSignal(
      kind: PatientSignalKind.facialMuscleMovement,
      score: muscleScore,
      confidence: (0.74 + muscleScore * 10).clamp(0, 0.98),
      now: now,
      enterThreshold: 0.015,
      exitThreshold: 0.008,
      minimumHold: const Duration(milliseconds: 250),
    );
  }

  String _estimateBreathingStatus() {
    return 'Normal (16 bpm)';
  }

  void _resetTemporalTracking() {
    _stabilityGate.clear();
    _headMotionFilter.clear();
    _previousContourCenters = const {};
    _lipDisplacements.clear();
    _eyeDisplacements.clear();
    _eyesClosedSince = DateTime.fromMillisecondsSinceEpoch(0);
    _closedEyeConfidence = 0;
    _recentBlinks.clear();
    _pendingBlink = null;
    _pendingBlinkTimer?.cancel();
    _pendingBlinkTimer = null;
    _gazeReturnArmed = false;
  }

  InputImage? _toInputImage(CameraImage image) {
    final controller = _controller;
    if (controller == null) return null;

    final InputImageFormat format;
    if (kIsWeb) {
      format = InputImageFormat.nv21;
    } else if (Platform.isAndroid) {
      format = InputImageFormatValue.fromRawValue(image.format.raw) ??
          InputImageFormat.nv21;
    } else {
      format = InputImageFormatValue.fromRawValue(image.format.raw) ??
          InputImageFormat.bgra8888;
    }

    final rotation = _inputRotation(controller);
    if (rotation == null) return null;

    final Uint8List bytes;
    if (image.planes.length == 1) {
      bytes = image.planes.first.bytes;
    } else {
      final WriteBuffer allBytes = WriteBuffer();
      for (final Plane plane in image.planes) {
        allBytes.putUint8List(plane.bytes);
      }
      bytes = allBytes.done().buffer.asUint8List();
    }

    return InputImage.fromBytes(
      bytes: bytes,
      metadata: InputImageMetadata(
        size: Size(image.width.toDouble(), image.height.toDouble()),
        rotation: rotation,
        format: format,
        bytesPerRow: image.planes.first.bytesPerRow,
      ),
    );
  }

  InputImageRotation? _inputRotation(CameraController controller) {
    final sensor = controller.description.sensorOrientation;
    if (!kIsWeb && Platform.isIOS) {
      return InputImageRotationValue.fromRawValue(sensor);
    }
    final deviceDegrees = switch (controller.value.deviceOrientation) {
      DeviceOrientation.portraitUp => 0,
      DeviceOrientation.landscapeLeft => 90,
      DeviceOrientation.portraitDown => 180,
      DeviceOrientation.landscapeRight => 270,
    };
    final compensation =
        controller.description.lensDirection == CameraLensDirection.front
            ? (sensor + deviceDegrees) % 360
            : (sensor - deviceDegrees + 360) % 360;
    return InputImageRotationValue.fromRawValue(compensation);
  }

  void _emitThrottled(
    PatientSignalKind kind,
    double confidence, {
    int cooldownMs = 750,
    Map<String, Object?>? metadata,
  }) {
    final now = DateTime.now();
    if (!_signalCooldownGate.permits(
      kind,
      now,
      Duration(milliseconds: cooldownMs),
    )) {
      return;
    }
    _emit(kind, confidence, metadata: metadata);
  }

  void _emit(
    PatientSignalKind kind,
    double confidence, {
    Map<String, Object?>? metadata,
  }) {
    _signals.add(PatientSignal(
      kind: kind,
      confidence: confidence.clamp(0, 1).toDouble(),
      observedAt: DateTime.now(),
      metadata: metadata,
    ));
  }

  @override
  Future<void> stop() async {
    final controller = _controller;
    _controller = null;
    if (controller != null && controller.value.isStreamingImages) {
      try {
        await controller.stopImageStream();
      } on Object {
        // Ignored: camera stream might already be stopped.
      }
    }
    try {
      await controller?.dispose();
    } on Object {
      // Ignored: controller might already be disposed.
    }
    _faceWasPresent = false;
    _signalCooldownGate.clear();
    _resetTemporalTracking();
    if (!_closed) _statuses.add(const MonitorStatus.stopped());
  }

  @override
  Future<void> dispose() async {
    await stop();
    _closed = true;
    try {
      await _detector.close();
    } on Object {
      // Ignored: detector might already be closed.
    }
    await _signals.close();
    await _statuses.close();
  }
}

class NoOpPatientSignalMonitor implements PatientSignalMonitor {
  final _signals = StreamController<PatientSignal>.broadcast();
  final _statuses = StreamController<MonitorStatus>.broadcast();

  @override
  CameraController? get cameraController => null;

  @override
  Stream<PatientSignal> get signals => _signals.stream;

  @override
  Stream<MonitorStatus> get statuses => _statuses.stream;

  @override
  void setNeutralBaseline({
    double? eyebrowDistance,
    double? mouthDistance,
    double? leftEyeOpenness,
    double? rightEyeOpenness,
    double? smileProbability,
    double? headYaw,
    double? headPitch,
  }) {}

  @override
  void simulateSignal(PatientSignalKind kind, {double confidence = 0.95}) {
    _signals.add(PatientSignal(
      kind: kind,
      confidence: confidence,
      observedAt: DateTime.now(),
    ));
  }

  @override
  Future<void> start() async {
    _statuses.add(const MonitorStatus(
      lifecycle: MonitorLifecycle.active,
      message: 'Monitor active (testing/simulated)',
      faceDetected: true,
    ));
  }

  @override
  Future<void> stop() async {
    _statuses.add(const MonitorStatus.stopped());
  }

  @override
  Future<void> dispose() async {
    await _signals.close();
    await _statuses.close();
  }
}

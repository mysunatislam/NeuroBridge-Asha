import 'dart:async';
import 'dart:io';
import 'dart:math' as math;
import 'package:camera/camera.dart';
import 'package:fingerspeak_mobile/intent/frame_builder.dart';
import 'package:fingerspeak_mobile/models/patient_signal.dart';
import 'package:fingerspeak_mobile/services/face_camera_frame.dart';
import 'package:fingerspeak_mobile/services/respiration_rate_estimator.dart';
import 'package:fingerspeak_mobile/services/web_face_bridge.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:google_mlkit_face_detection/google_mlkit_face_detection.dart';

abstract interface class PatientSignalMonitor {
  Stream<PatientSignal> get signals;
  Stream<MonitorStatus> get statuses;

  /// Raw per-observation measurements for the intent recognition pipeline.
  /// One event per processed camera frame; never contains image data.
  Stream<IntentObservation> get observations;
  MonitorStatus get currentStatus;
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
  void setSignalSensitivities(
    Map<PatientSignalKind, double> sensitivities,
  );
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
    required this.closure,
    required this.duration,
  });

  final double closure;
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
double sensitivityAdjustedThreshold(
  double baseThreshold,
  double sensitivity,
) {
  final normalized = ((sensitivity.clamp(0.40, 0.95) - 0.40) / 0.55).toDouble();
  final factor = 1.35 - normalized * 0.57;
  return baseThreshold * factor;
}

@visibleForTesting
double blinkClosureThreshold(double sensitivity) =>
    sensitivityAdjustedThreshold(0.58, sensitivity)
        .clamp(0.35, 0.78)
        .toDouble();

/// Conservative timing check for explicitly opted-in, experimental movement.
/// This validates repeated contour motion, not a neurological tremor diagnosis.
@visibleForTesting
bool isConsistentMicroMovement(
  List<double> values,
  List<DateTime> observedAt, {
  Duration minimumObservation = const Duration(milliseconds: 2500),
}) {
  if (values.length < 20 ||
      values.length != observedAt.length ||
      values.any((value) => !value.isFinite) ||
      observedAt.last.difference(observedAt.first) < minimumObservation) {
    return false;
  }
  final elapsed = <double>[];
  for (var i = 0; i < observedAt.length; i++) {
    if (i > 0) {
      final gap = observedAt[i].difference(observedAt[i - 1]);
      if (gap <= Duration.zero || gap > const Duration(milliseconds: 350)) {
        return false;
      }
    }
    elapsed.add(
      observedAt[i].difference(observedAt.first).inMicroseconds / 1000000,
    );
  }
  final meanTime = elapsed.reduce((a, b) => a + b) / elapsed.length;
  final meanValue = values.reduce((a, b) => a + b) / values.length;
  var covariance = 0.0;
  var timeVariance = 0.0;
  for (var i = 0; i < values.length; i++) {
    covariance += (elapsed[i] - meanTime) * (values[i] - meanValue);
    timeVariance += math.pow(elapsed[i] - meanTime, 2);
  }
  if (timeVariance <= 0) return false;
  final slope = covariance / timeVariance;
  final residuals = List<double>.generate(
    values.length,
    (i) => values[i] - meanValue - slope * (elapsed[i] - meanTime),
  );
  final rms = math.sqrt(
    residuals.fold<double>(0, (sum, value) => sum + value * value) /
        residuals.length,
  );
  if (rms < 0.000001) return false;
  final hysteresis = rms * 0.4;
  final rises = <double>[];
  var wasBelow = false;
  for (var i = 0; i < residuals.length; i++) {
    if (residuals[i] <= -hysteresis) {
      wasBelow = true;
    } else if (wasBelow && residuals[i] >= hysteresis) {
      rises.add(elapsed[i]);
      wasBelow = false;
    }
  }
  if (rises.length < 3) return false;
  final periods = <double>[
    for (var i = 1; i < rises.length; i++) rises[i] - rises[i - 1],
  ];
  final meanPeriod = periods.reduce((a, b) => a + b) / periods.length;
  if (meanPeriod < 1 / 3 || meanPeriod > 1.25) return false;
  final periodVariance = periods.fold<double>(
        0,
        (sum, period) => sum + math.pow(period - meanPeriod, 2),
      ) /
      periods.length;
  return math.sqrt(periodVariance) / meanPeriod <= 0.25;
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
    if (!yaw.isFinite || !pitch.isFinite) {
      clear();
      return null;
    }
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

@visibleForTesting
class FaceMonitorLifecycleIntent {
  FaceMonitorLifecycleIntent({
    AppLifecycleState initialState = AppLifecycleState.resumed,
  }) : _suspended = initialState != AppLifecycleState.resumed;

  bool _requestedActive = false;
  bool _suspended;
  bool _disposed = false;

  bool get shouldRun => _requestedActive && !_suspended && !_disposed;

  void requestStart() {
    if (!_disposed) _requestedActive = true;
  }

  void requestStop() => _requestedActive = false;

  void update(AppLifecycleState state) {
    _suspended = state != AppLifecycleState.resumed;
  }

  void dispose() {
    _disposed = true;
    _requestedActive = false;
  }
}

/// On-device face expressions, assisted head/gaze, and optional contour motion.
/// No camera frame leaves the device.
class MlKitPatientSignalMonitor
    with WidgetsBindingObserver
    implements PatientSignalMonitor {
  MlKitPatientSignalMonitor({FaceDetector? detector})
      : _detector = detector ??
            FaceDetector(
              options: FaceDetectorOptions(
                enableClassification: true,
                enableContours: true,
                enableLandmarks: true,
                enableTracking: false,
                minFaceSize: 0.15,
                performanceMode: FaceDetectorMode.accurate,
              ),
            ) {
    final binding = WidgetsBinding.instance;
    _lifecycleIntent.update(binding.lifecycleState ?? AppLifecycleState.resumed);
    binding.addObserver(this);
    if (kIsWeb) {
      _webStatusSub = _webFaceBridge.statuses.listen((status) {
        _publishStatus(status);
      });
      _webSignalSub = _webFaceBridge.signals.listen((signal) {
        if (!_closed) _signals.add(signal);
      });
    }
  }

  final FaceDetector _detector;
  final WebFaceBridge _webFaceBridge = WebFaceBridge();
  StreamSubscription<MonitorStatus>? _webStatusSub;
  StreamSubscription<PatientSignal>? _webSignalSub;
  final _signals = StreamController<PatientSignal>.broadcast();
  final _statuses = StreamController<MonitorStatus>.broadcast();
  final _observations = StreamController<IntentObservation>.broadcast();
  MonitorStatus _currentStatus = const MonitorStatus.stopped();

  // Latest contour-derived measurements shared with the intent pipeline.
  Map<FaceContourType, Offset> _previousContourCentersAll = const {};
  double _lastContourMotion = 0;
  double _lastContourDirectionConsistency = 0;
  double _lastLipMotion = 0;
  double _lastMouthAsymmetry = 0;
  final Map<PatientSignalKind, double> _signalSensitivities = {};
  final RespirationRateEstimator _respirationEstimator =
      RespirationRateEstimator();
  int _unstableBreathingFrames = 0;
  int? _primaryTrackingId;
  Rect? _previousPrimaryBox;

  CameraController? _controller;
  int _streamGeneration = 0;
  final FaceMonitorLifecycleIntent _lifecycleIntent = FaceMonitorLifecycleIntent();
  Future<void> _cameraTransition = Future<void>.value();
  DateTime _lastFrame = DateTime.fromMillisecondsSinceEpoch(0);
  DateTime _lastBlink = DateTime.fromMillisecondsSinceEpoch(0);
  DateTime _eyesClosedSince = DateTime.fromMillisecondsSinceEpoch(0);
  double _closedEyeConfidence = 0;
  final List<DateTime> _recentBlinks = [];
  final List<DateTime> _recentRapidBlinks = [];
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
  final List<DateTime> _lipObservationTimes = [];
  final List<DateTime> _eyeObservationTimes = [];
  double _facialMovementEnergy = 0;

  bool _processing = false;
  bool _faceWasPresent = false;
  bool _closed = false;

  @override
  CameraController? get cameraController => _controller;

  @override
  MonitorStatus get currentStatus => _currentStatus;

  @override
  Stream<PatientSignal> get signals => _signals.stream;

  @override
  Stream<MonitorStatus> get statuses => _statuses.stream;

  @override
  Stream<IntentObservation> get observations => _observations.stream;

  void _publishObservation(IntentObservation observation) {
    if (!_closed && !_observations.isClosed) _observations.add(observation);
  }

  @override
  void setSignalSensitivities(
    Map<PatientSignalKind, double> sensitivities,
  ) {
    _signalSensitivities
      ..clear()
      ..addEntries(
        sensitivities.entries.where((entry) => entry.value.isFinite).map(
              (entry) => MapEntry(
                entry.key,
                entry.value.clamp(0.40, 0.95).toDouble(),
              ),
            ),
      );
    _resetTemporalTracking();
  }

  double _sensitivity(PatientSignalKind kind) =>
      _signalSensitivities[kind] ?? 0.75;

  double _threshold(PatientSignalKind kind, double baseThreshold) =>
      sensitivityAdjustedThreshold(baseThreshold, _sensitivity(kind));

  void _publishStatus(MonitorStatus status) {
    _currentStatus = status;
    if (!_closed) _statuses.add(status);
  }

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
    if (kIsWeb) {
      _webFaceBridge.start();
    }
    _lifecycleIntent.requestStart();
    await _queueCameraTransition(_startCamera);
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (_closed) return;
    _lifecycleIntent.update(state);
    if (_lifecycleIntent.shouldRun) {
      unawaited(_queueCameraTransition(_startCamera));
    } else {
      ++_streamGeneration;
      _resetTemporalTracking();
      _publishStatus(const MonitorStatus(
        lifecycle: MonitorLifecycle.stopped,
        message: 'Camera is paused while the app is in the background',
      ));
      unawaited(_queueCameraTransition(_stopCamera));
    }
  }

  Future<void> _queueCameraTransition(Future<void> Function() operation) {
    final transition = _cameraTransition.then((_) => operation());
    // A failed platform call must not poison later explicit stop/start requests.
    _cameraTransition = transition.then<void>(
      (_) {},
      onError: (Object error, StackTrace stackTrace) {},
    );
    return transition;
  }

  Future<void> _startCamera() async {
    if (!_lifecycleIntent.shouldRun || _closed) return;
    if (_controller?.value.isStreamingImages ?? false) {
      _publishStatus(_currentStatus);
      return;
    }
    final generation = ++_streamGeneration;
    final previousController = _controller;
    _controller = null;
    CameraController? startingController;
    _resetTemporalTracking();
    _publishStatus(const MonitorStatus(
      lifecycle: MonitorLifecycle.starting,
      message: 'Starting private on-device camera…',
    ));
    try {
      await _disposeController(previousController);
      if (!_isCurrentSession(generation)) return;
      final cameras = await availableCameras();
      if (!_isCurrentSession(generation)) return;
      if (cameras.isEmpty) {
        _publishStatus(const MonitorStatus(
          lifecycle: MonitorLifecycle.unavailable,
          message: 'No camera is available on this device',
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
      startingController = controller;
      _controller = controller;
      await controller.initialize();
      if (!_isCurrentSession(generation, controller)) {
        await _disposeController(controller);
        return;
      }
      if (!kIsWeb) {
        await controller.startImageStream(
          (image) => _processFrame(image, generation, controller),
        );
      }
      if (!_isCurrentSession(generation, controller)) {
        await _disposeController(controller);
        return;
      }
      _publishStatus(const MonitorStatus(
        lifecycle: MonitorLifecycle.active,
        message: 'Camera active — looking for the patient’s face…',
      ));
    } on CameraException catch (error) {
      await _handleStartFailure(
        generation,
        startingController,
        'Camera unavailable: ${error.description ?? error.code}',
      );
    } on Object catch (error) {
      await _handleStartFailure(
        generation,
        startingController,
        'Vision monitor could not start: $error',
      );
    }
  }

  bool _isCurrentSession(int generation, [CameraController? controller]) =>
      !_closed &&
      _lifecycleIntent.shouldRun &&
      generation == _streamGeneration &&
      (controller == null || identical(controller, _controller));

  Future<void> _handleStartFailure(
    int generation,
    CameraController? controller,
    String message,
  ) async {
    if (_isCurrentSession(generation)) {
      ++_streamGeneration;
      _controller = null;
      _resetTemporalTracking();
      _publishStatus(MonitorStatus(
        lifecycle: MonitorLifecycle.error,
        message: message,
      ));
    }
    await _disposeController(controller);
  }

  Future<void> _disposeController(CameraController? controller) async {
    if (controller == null) return;
    try {
      if (controller.value.isStreamingImages) {
        await controller.stopImageStream();
      }
    } on Object {
      // The platform may already have stopped this stream.
    }
    try {
      await controller.dispose();
    } on Object {
      // A cancelled start and stop can both release the same controller.
    }
  }

  int _frameSkipCounter = 0;

  Future<void> _processFrame(
    CameraImage image,
    int generation,
    CameraController controller,
  ) async {
    if (!_isCurrentSession(generation, controller) ||
        !controller.value.isInitialized) {
      return;
    }
    // Process every 2nd frame to decimate stream and preserve battery
    if (++_frameSkipCounter % 2 != 0) return;

    final now = DateTime.now();
    if (_processing ||
        now.difference(_lastFrame) < const Duration(milliseconds: 55)) {
      return;
    }
    _lastFrame = now;
    final input = _toInputImage(image, controller);
    if (input == null) {
      _faceWasPresent = false;
      _resetTemporalTracking();
      _publishStatus(const MonitorStatus(
        lifecycle: MonitorLifecycle.error,
        message: 'Camera frames could not be read. Restart the camera monitor.',
      ));
      return;
    }
    _processing = true;
    try {
      final faces = await _detector.processImage(input);
      if (!_isCurrentSession(generation, controller)) return;
      if (faces.isEmpty) {
        if (_faceWasPresent) {
          _emit(PatientSignalKind.faceLost, 1);
          _faceWasPresent = false;
        }
        _resetTemporalTracking();
        _primaryTrackingId = null;
        _previousPrimaryBox = null;
        _publishStatus(const MonitorStatus(
          lifecycle: MonitorLifecycle.active,
          message: 'Looking for the patient’s face…',
        ));
        _publishObservation(
          IntentObservation(observedAt: now, faceDetected: false),
        );
        return;
      }
      final face = _selectPrimaryFace(faces);
      if (face.boundingBox.width < 80 || face.boundingBox.height < 80) {
        _resetTemporalTracking();
        _publishStatus(const MonitorStatus(
          lifecycle: MonitorLifecycle.active,
          message: 'Move closer so facial movements can be measured reliably',
          faceDetected: true,
        ));
        return;
      }
      if (!_faceWasPresent) _emit(PatientSignalKind.facePresent, 1);
      _faceWasPresent = true;
      final leftOpen = face.leftEyeOpenProbability;
      final rightOpen = face.rightEyeOpenProbability;
      final smileProbability = face.smilingProbability;
      final yaw = face.headEulerAngleY;
      final pitch = face.headEulerAngleX;
      final neutralMeasurements = _measureNeutralFace(face);
      final headVelocity = _processHeadAndAssistedGaze(
        yaw: yaw,
        pitch: pitch,
        smileProbability: smileProbability,
        now: now,
      );
      final poseStableForBreathing = yaw != null &&
          yaw.isFinite &&
          pitch != null &&
          pitch.isFinite &&
          (yaw - _restingHeadYaw).abs() <= 16 &&
          (pitch - _restingHeadPitch).abs() <= 14 &&
          headVelocity.isFinite &&
          headVelocity <= 16;
      if (!poseStableForBreathing) {
        _unstableBreathingFrames++;
        if (_unstableBreathingFrames > 20) {
          _respirationEstimator.clear();
        }
      } else {
        _unstableBreathingFrames = 0;
      }
      final frameExtent = math.max(image.width, image.height).toDouble();
      final respirationEstimate = poseStableForBreathing
          ? _respirationEstimator.addSample(
              observedAt: now,
              verticalPosition: face.boundingBox.center.dy / frameExtent,
            )
          : _respirationEstimator.currentEstimate;
      final breathingLabel = respirationEstimate != null
          ? () {
              final rate = respirationEstimate.breathsPerMinute.round();
              final category = rate < 10
                  ? 'Slow'
                  : rate > 24
                      ? 'Rapid'
                      : 'Normal';
              return 'Estimated $rate breaths/min ($category)';
            }()
          : !poseStableForBreathing
              ? 'Unavailable — keep head and camera still'
              : 'Measuring… keep head and camera still';

      _publishStatus(MonitorStatus(
        lifecycle: MonitorLifecycle.active,
        observedAt: now,
        message: 'Live face, gaze & gesture tracking active',
        faceDetected: true,
        leftEyeOpen: leftOpen,
        rightEyeOpen: rightOpen,
        eyebrowDistance: neutralMeasurements.eyebrowDistance,
        mouthDistance: neutralMeasurements.mouthDistance,
        smileProbability: smileProbability,
        headYaw: yaw,
        headPitch: pitch,
        lipTremorDetected: poseStableForBreathing &&
            _signalSensitivities.containsKey(PatientSignalKind.lipTremor) &&
            now.difference(_lastLipTremorTime) < const Duration(seconds: 1),
        eyeTremorDetected: poseStableForBreathing &&
            _signalSensitivities.containsKey(PatientSignalKind.eyeTremor) &&
            now.difference(_lastEyeTremorTime) < const Duration(seconds: 1),
        breathingRatePerMin: respirationEstimate?.breathsPerMinute,
        breathingStatus: breathingLabel,
      ));

      if (leftOpen != null &&
          leftOpen.isFinite &&
          rightOpen != null &&
          rightOpen.isFinite) {
        _processEyes(leftOpen, rightOpen, now);
      } else {
        _resetEyeTracking();
      }
      _processSmilesAndContours(
        face,
        now,
        neutralMeasurements: neutralMeasurements,
        yawOffset: yaw == null ? null : yaw - _restingHeadYaw,
        pitchOffset: pitch == null ? null : pitch - _restingHeadPitch,
        headVelocity: headVelocity,
      );
      // Measurements only (no pixels) for the temporal intent pipeline. The
      // pipeline decides over 2-5 s windows whether movement was a command.
      final imageWidth = math.max(image.width, 1).toDouble();
      final imageHeight = math.max(image.height, 1).toDouble();
      _publishObservation(IntentObservation(
        observedAt: now,
        faceDetected: true,
        leftEyeOpen: leftOpen,
        rightEyeOpen: rightOpen,
        mouthDistance: neutralMeasurements.mouthDistance,
        smileProbability: smileProbability,
        eyebrowDistance: neutralMeasurements.eyebrowDistance,
        headYaw: yaw,
        headPitch: pitch,
        headRoll: face.headEulerAngleZ,
        faceCenterX: face.boundingBox.center.dx / imageWidth,
        faceCenterY: face.boundingBox.center.dy / imageHeight,
        faceScale: face.boundingBox.width / imageWidth,
        lipMotion: _lastLipMotion,
        contourMotionEnergy: _lastContourMotion,
        contourDirectionConsistency: _lastContourDirectionConsistency,
        mouthAsymmetry: _lastMouthAsymmetry,
      ));
    } on Object catch (error) {
      if (!_isCurrentSession(generation, controller)) return;
      _resetTemporalTracking();
      _publishStatus(MonitorStatus(
        lifecycle: MonitorLifecycle.active,
        message: 'Vision tracking active (resumed: $error)',
      ));
    } finally {
      _processing = false;
    }
  }

  Face _selectPrimaryFace(List<Face> faces) {
    Face? selected;
    final trackedId = _primaryTrackingId;
    if (trackedId != null) {
      for (final candidate in faces) {
        if (candidate.trackingId == trackedId) {
          selected = candidate;
          break;
        }
      }
    }
    selected ??= faces.reduce((first, second) {
      final firstArea = first.boundingBox.width * first.boundingBox.height;
      final secondArea = second.boundingBox.width * second.boundingBox.height;
      return firstArea >= secondArea ? first : second;
    });

    final previousBox = _previousPrimaryBox;
    final nextId = selected.trackingId;
    final trackingChanged =
        trackedId != null && nextId != null && trackedId != nextId;
    final largeUntrackedJump = previousBox != null &&
        (trackedId == null || nextId == null) &&
        (selected.boundingBox.center - previousBox.center).distance >
            math.max(previousBox.width, previousBox.height) * 0.75;
    if (trackingChanged || largeUntrackedJump) {
      _resetTemporalTracking();
    }
    _primaryTrackingId = nextId;
    _previousPrimaryBox = selected.boundingBox;
    return selected;
  }

  void _resetEyeTracking() {
    for (final kind in const [
      PatientSignalKind.leftWink,
      PatientSignalKind.rightWink,
    ]) {
      _stabilityGate.reset(kind);
    }
    _eyesClosedSince = DateTime.fromMillisecondsSinceEpoch(0);
    _closedEyeConfidence = 0;
    _recentBlinks.clear();
    _recentRapidBlinks.clear();
    _pendingBlink = null;
    _pendingBlinkTimer?.cancel();
    _pendingBlinkTimer = null;
  }

  void _processEyes(double leftOpen, double rightOpen, DateTime now) {
    final requiredClosure = [
      PatientSignalKind.blink,
      PatientSignalKind.slowBlink,
      PatientSignalKind.rapidBlink,
    ].map((kind) => blinkClosureThreshold(_sensitivity(kind))).reduce(math.min);
    final leftClosedThreshold = math.max(
      0.10,
      _restingLeftEyeOpenness * (1 - requiredClosure),
    );
    final rightClosedThreshold = math.max(
      0.10,
      _restingRightEyeOpenness * (1 - requiredClosure),
    );
    final eyesClosed =
        leftOpen < leftClosedThreshold && rightOpen < rightClosedThreshold;
    if (eyesClosed) {
      final leftClosure = (1 - leftOpen / _restingLeftEyeOpenness).clamp(0, 1);
      final rightClosure =
          (1 - rightOpen / _restingRightEyeOpenness).clamp(0, 1);
      final confidence = math.min(leftClosure, rightClosure).toDouble();
      _closedEyeConfidence = math.max(_closedEyeConfidence, confidence);
      if (_eyesClosedSince.millisecondsSinceEpoch == 0) {
        _eyesClosedSince = now;
      } else {
        final closedDuration = now.difference(_eyesClosedSince);
        if (closedDuration >= const Duration(milliseconds: 700) &&
            closedDuration <= const Duration(seconds: 2) &&
            _closedEyeConfidence >=
                blinkClosureThreshold(
                    _sensitivity(PatientSignalKind.slowBlink))) {
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
            closure: _closedEyeConfidence,
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
    final leftWinkEnter =
        _threshold(PatientSignalKind.leftWink, 0.65).clamp(0.45, 0.85);
    final rightWinkEnter =
        _threshold(PatientSignalKind.rightWink, 0.65).clamp(0.45, 0.85);
    _emitStableSignal(
      kind: PatientSignalKind.leftWink,
      score: leftWinkScore,
      confidence: (0.72 + leftWinkScore * 0.28).clamp(0, 1),
      now: now,
      enterThreshold: leftWinkEnter,
      exitThreshold: leftWinkEnter * 0.68,
      minimumHold: const Duration(milliseconds: 250),
    );
    _emitStableSignal(
      kind: PatientSignalKind.rightWink,
      score: rightWinkScore,
      confidence: (0.72 + rightWinkScore * 0.28).clamp(0, 1),
      now: now,
      enterThreshold: rightWinkEnter,
      exitThreshold: rightWinkEnter * 0.68,
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
    if (observation.closure >=
        blinkClosureThreshold(_sensitivity(PatientSignalKind.rapidBlink))) {
      _recentRapidBlinks.add(now);
    }
    _recentRapidBlinks.removeWhere(
      (time) => now.difference(time) > const Duration(milliseconds: 1200),
    );
    _pendingBlink = observation;
    _pendingBlinkTimer?.cancel();
    if (_recentRapidBlinks.length >= 3) {
      final sequenceDuration =
          now.difference(_recentRapidBlinks.first).inMilliseconds;
      _recentBlinks.clear();
      _recentRapidBlinks.clear();
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
      if (pending == null ||
          pending.closure <
              blinkClosureThreshold(_sensitivity(PatientSignalKind.blink))) {
        return;
      }
      _emitThrottled(
        PatientSignalKind.blink,
        math.max(0.80, pending.closure),
        metadata: {'active_duration_ms': pending.duration.inMilliseconds},
      );
    });
  }

  double _processHeadAndAssistedGaze({
    required double? yaw,
    required double? pitch,
    required double? smileProbability,
    required DateTime now,
  }) {
    if (yaw == null || !yaw.isFinite || pitch == null || !pitch.isFinite) {
      _headMotionFilter.clear();
      _gazeReturnArmed = false;
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
    final leftEnter = _threshold(PatientSignalKind.eyeLookLeft, 16);
    final rightEnter = _threshold(PatientSignalKind.eyeLookRight, 16);
    final upEnter = _threshold(PatientSignalKind.eyeLookUp, 14);
    final downEnter = _threshold(PatientSignalKind.eyeLookDown, 14);
    _emitStableSignal(
      kind: PatientSignalKind.eyeLookLeft,
      score: leftScore,
      confidence: (yawOffset.abs() / 28).clamp(0.74, 1.0),
      now: now,
      enterThreshold: leftEnter,
      exitThreshold: leftEnter * 0.62,
      minimumHold: const Duration(milliseconds: 300),
      metadata: const {'detection_proxy': 'slight_head_and_gaze_pose'},
    );
    _emitStableSignal(
      kind: PatientSignalKind.eyeLookRight,
      score: rightScore,
      confidence: (yawOffset.abs() / 28).clamp(0.74, 1.0),
      now: now,
      enterThreshold: rightEnter,
      exitThreshold: rightEnter * 0.62,
      minimumHold: const Duration(milliseconds: 300),
      metadata: const {'detection_proxy': 'slight_head_and_gaze_pose'},
    );
    _emitStableSignal(
      kind: PatientSignalKind.eyeLookUp,
      score: pitchOffset,
      confidence: (pitchOffset.abs() / 25).clamp(0.74, 1.0),
      now: now,
      enterThreshold: upEnter,
      exitThreshold: upEnter * 0.64,
      minimumHold: const Duration(milliseconds: 300),
      metadata: const {'detection_proxy': 'slight_head_and_gaze_pose'},
    );
    _emitStableSignal(
      kind: PatientSignalKind.eyeLookDown,
      score: -pitchOffset,
      confidence: (pitchOffset.abs() / 25).clamp(0.74, 1.0),
      now: now,
      enterThreshold: downEnter,
      exitThreshold: downEnter * 0.64,
      minimumHold: const Duration(milliseconds: 300),
      metadata: const {'detection_proxy': 'slight_head_and_gaze_pose'},
    );

    if (yawOffset.abs() > _threshold(PatientSignalKind.eyeLookCenter, 14) ||
        pitchOffset.abs() > _threshold(PatientSignalKind.eyeLookCenter, 12)) {
      _gazeReturnArmed = true;
    }
    final alignmentScore =
        1 - math.max(yawOffset.abs(), pitchOffset.abs()) / 12;
    final centerEnter =
        _threshold(PatientSignalKind.eyeLookCenter, 0.65).clamp(0.50, 0.88);
    final centered = _stabilityGate.update(
      kind: PatientSignalKind.eyeLookCenter,
      score: alignmentScore,
      confidence: alignmentScore.clamp(0.75, 1.0),
      observedAt: now,
      enterThreshold: centerEnter,
      exitThreshold: centerEnter * 0.54,
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
    final rapidDisplacement = _threshold(PatientSignalKind.headTurnRapid, 5.5);
    final rapidVelocity = _threshold(PatientSignalKind.headTurnRapid, 75);
    final rapidMotion = motion != null &&
        motion.frameDisplacementDegrees >= rapidDisplacement &&
        velocity >= rapidVelocity;
    if (rapidMotion) {
      _stabilityGate.reset(PatientSignalKind.headTurnSlow);
      _emitThrottled(
        PatientSignalKind.headTurnRapid,
        (velocity / 130).clamp(0.78, 1.0),
        cooldownMs: 900,
      );
    } else {
      final slowEnter = _threshold(PatientSignalKind.headTurnSlow, 14);
      final slowScore =
          velocity <= 50 && (motion?.frameDisplacementDegrees ?? 0) >= 0.7
              ? velocity
              : 0.0;
      _emitStableSignal(
        kind: PatientSignalKind.headTurnSlow,
        score: slowScore,
        confidence: (velocity / 35).clamp(0.75, 0.95),
        now: now,
        enterThreshold: slowEnter,
        exitThreshold: slowEnter * 0.5,
        minimumHold: const Duration(milliseconds: 300),
      );
    }

    final smileStrength = smileProbability == null
        ? 0.0
        : (smileProbability - _restingSmileProbability) /
            _threshold(PatientSignalKind.headNodSmile, 0.25);
    final poseStrength = math.max(yawOffset.abs(), pitchOffset.abs()) /
        _threshold(PatientSignalKind.headNodSmile, 10);
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
    return motion == null ? double.infinity : velocity;
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
    final leftEyebrowTop = face.contours[FaceContourType.leftEyebrowTop]?.points;
    final leftEyebrowBottom =
        face.contours[FaceContourType.leftEyebrowBottom]?.points;
    final rightEyebrowTop =
        face.contours[FaceContourType.rightEyebrowTop]?.points;
    final rightEyebrowBottom =
        face.contours[FaceContourType.rightEyebrowBottom]?.points;
    final leftEye = face.contours[FaceContourType.leftEye]?.points;
    final rightEye = face.contours[FaceContourType.rightEye]?.points;
    final upperLipTop = face.contours[FaceContourType.upperLipTop]?.points;
    final upperLipBottom =
        face.contours[FaceContourType.upperLipBottom]?.points;
    final lowerLipBottom =
        face.contours[FaceContourType.lowerLipBottom]?.points;
    final lowerLipTop = face.contours[FaceContourType.lowerLipTop]?.points;

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

    addEyebrowDistance(leftEyebrowTop ?? leftEyebrowBottom, leftEye);
    addEyebrowDistance(rightEyebrowTop ?? rightEyebrowBottom, rightEye);

    // Landmark fallback for eyebrows if contours are not detected
    if (eyebrowDistances.isEmpty) {
      final landmarkLeftEye =
          face.landmarks[FaceLandmarkType.leftEye]?.position;
      final landmarkRightEye =
          face.landmarks[FaceLandmarkType.rightEye]?.position;
      if (landmarkLeftEye != null || landmarkRightEye != null) {
        final eyeY = ((landmarkLeftEye?.y ?? landmarkRightEye!.y) +
                (landmarkRightEye?.y ?? landmarkLeftEye!.y)) /
            2.0;
        final topY = face.boundingBox.top;
        final estimatedBrowY = (eyeY + topY) / 2.0;
        eyebrowDistances.add(
          (eyeY - estimatedBrowY).abs() / math.max(face.boundingBox.height, 1),
        );
      } else {
        eyebrowDistances.add(0.18);
      }
    }

    final eyebrowDistance = eyebrowDistances.isEmpty
        ? 0.18
        : eyebrowDistances.reduce((a, b) => a + b) / eyebrowDistances.length;

    double? mouthDistance;
    final upperLip = upperLipTop ?? upperLipBottom;
    final lowerLip = lowerLipBottom ?? lowerLipTop;
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
    } else {
      // Landmark fallback for mouth
      final bottomMouth =
          face.landmarks[FaceLandmarkType.bottomMouth]?.position;
      final noseBase = face.landmarks[FaceLandmarkType.noseBase]?.position;
      final leftMouth = face.landmarks[FaceLandmarkType.leftMouth]?.position;
      final rightMouth = face.landmarks[FaceLandmarkType.rightMouth]?.position;
      if (bottomMouth != null && (leftMouth != null || rightMouth != null)) {
        final mouthCenterY = ((leftMouth?.y ?? rightMouth!.y) +
                (rightMouth?.y ?? leftMouth!.y)) /
            2.0;
        mouthDistance = (bottomMouth.y - mouthCenterY).abs() /
            math.max(face.boundingBox.height, 1);
      } else if (bottomMouth != null && noseBase != null) {
        mouthDistance = ((bottomMouth.y - noseBase.y).abs() * 0.35) /
            math.max(face.boundingBox.height, 1);
      } else {
        mouthDistance = 0.08;
      }
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
    final smile = face.smilingProbability;
    final smileValue = smile ?? 0.0;

    final upperLip = face.contours[FaceContourType.upperLipTop]?.points;
    final lowerLip = face.contours[FaceContourType.lowerLipBottom]?.points;
    final leftEye = face.contours[FaceContourType.leftEye]?.points;
    final rightEye = face.contours[FaceContourType.rightEye]?.points;
    final noseBridge = face.contours[FaceContourType.noseBridge]?.points;
    final hasValidPose = yawOffset != null &&
        yawOffset.isFinite &&
        pitchOffset != null &&
        pitchOffset.isFinite;
    final frontFacing =
        !hasValidPose || (yawOffset.abs() <= 18 && pitchOffset.abs() <= 15);
    final poseStable = hasValidPose &&
        frontFacing &&
        headVelocity.isFinite &&
        headVelocity <= 12;

    double cornerHeightDifference = 0;
    if (upperLip != null && upperLip.length >= 3) {
      cornerHeightDifference = (upperLip.last.y - upperLip.first.y) /
          math.max(face.boundingBox.height, 1);
    }
    final smileDelta = _threshold(PatientSignalKind.smile, 0.25);
    final smileEnter = math.max(
      _restingSmileProbability + smileDelta,
      _threshold(PatientSignalKind.smile, 0.55).clamp(0.38, 0.72),
    );
    final smileExit = math.max(
      _restingSmileProbability + smileDelta * 0.56,
      smileEnter * 0.68,
    );
    final leftSmileFloor = math.max(
      _restingSmileProbability + _threshold(PatientSignalKind.smileLeft, 0.18),
      _threshold(PatientSignalKind.smileLeft, 0.42).clamp(0.30, 0.58),
    );
    final rightSmileFloor = math.max(
      _restingSmileProbability + _threshold(PatientSignalKind.smileRight, 0.18),
      _threshold(PatientSignalKind.smileRight, 0.42).clamp(0.30, 0.58),
    );
    final leftSmileReady =
        smile != null && frontFacing && smileValue >= leftSmileFloor;
    final rightSmileReady =
        smile != null && frontFacing && smileValue >= rightSmileFloor;
    final symmetricScore =
        smile != null && frontFacing && cornerHeightDifference.abs() < 0.025
            ? smileValue
            : 0.0;
    _emitStableSignal(
      kind: PatientSignalKind.smile,
      score: symmetricScore,
      confidence: (0.74 + (smileValue - smileEnter) * 0.55).clamp(0, 1),
      now: now,
      enterThreshold: smileEnter,
      exitThreshold: smileExit,
      minimumHold: const Duration(milliseconds: 350),
    );
    _emitStableSignal(
      kind: PatientSignalKind.smileLeft,
      score: leftSmileReady ? cornerHeightDifference : 0,
      confidence: (0.74 + cornerHeightDifference.abs() * 4).clamp(0, 1),
      now: now,
      enterThreshold: _threshold(PatientSignalKind.smileLeft, 0.035),
      exitThreshold: _threshold(PatientSignalKind.smileLeft, 0.018),
      minimumHold: const Duration(milliseconds: 350),
    );
    _emitStableSignal(
      kind: PatientSignalKind.smileRight,
      score: rightSmileReady ? -cornerHeightDifference : 0,
      confidence: (0.74 + cornerHeightDifference.abs() * 4).clamp(0, 1),
      now: now,
      enterThreshold: _threshold(PatientSignalKind.smileRight, 0.035),
      exitThreshold: _threshold(PatientSignalKind.smileRight, 0.018),
      minimumHold: const Duration(milliseconds: 350),
    );

    final eyebrowDistance = neutralMeasurements.eyebrowDistance;
    final requiredElevation = _threshold(
      PatientSignalKind.eyebrowsUp,
      math.max(_restingEyebrowDistance * 0.20, 0.012),
    );
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
    final mouthDelta = _threshold(
      PatientSignalKind.mouthOpen,
      math.max(_restingMouthDistance * 0.50, 0.025),
    );
    final mouthEnter = _restingMouthDistance + mouthDelta;
    final mouthExit = _restingMouthDistance + mouthDelta * 0.55;
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

    final namedExpressionActive = symmetricScore >= smileEnter ||
        leftSmileReady &&
            cornerHeightDifference >=
                _threshold(PatientSignalKind.smileLeft, 0.035) ||
        rightSmileReady &&
            -cornerHeightDifference >=
                _threshold(PatientSignalKind.smileRight, 0.035) ||
        eyebrowScore >= 1 ||
        mouthScore >= mouthEnter;
    final microMotionReady = poseStable && !namedExpressionActive;
    final lipEnabled = microMotionReady &&
        _signalSensitivities.containsKey(PatientSignalKind.lipTremor);
    final eyeEnabled = microMotionReady &&
        _signalSensitivities.containsKey(PatientSignalKind.eyeTremor) &&
        (face.leftEyeOpenProbability ?? 0) >= _restingLeftEyeOpenness * 0.65 &&
        (face.rightEyeOpenProbability ?? 0) >= _restingRightEyeOpenness * 0.65;
    final faceHeight = math.max(face.boundingBox.height, 1);
    final referenceY = noseBridge == null || noseBridge.isEmpty
        ? face.boundingBox.center.dy
        : noseBridge.fold<double>(0, (sum, point) => sum + point.y) /
            noseBridge.length;
    if (!lipEnabled ||
        upperLip == null ||
        upperLip.isEmpty ||
        lowerLip == null ||
        lowerLip.isEmpty) {
      _lipDisplacements.clear();
      _lipObservationTimes.clear();
      _lastLipTremorTime = DateTime.fromMillisecondsSinceEpoch(0);
    } else {
      final upperY = upperLip.fold<double>(0, (sum, point) => sum + point.y) /
          upperLip.length;
      final lowerY = lowerLip.fold<double>(0, (sum, point) => sum + point.y) /
          lowerLip.length;
      final lipCenterY = (upperY + lowerY) / 2;
      _appendMicroMovement(
        _lipDisplacements,
        _lipObservationTimes,
        (lipCenterY - referenceY) / faceHeight,
        now,
      );
      if (isConsistentMicroMovement(_lipDisplacements, _lipObservationTimes)) {
        final metrics = analyzeOscillation(_lipDisplacements);
        if (metrics.detrendedRms >=
                _threshold(PatientSignalKind.lipTremor, 0.0018) &&
            metrics.detrendedRms <= 0.025 &&
            metrics.peakToPeak >=
                _threshold(PatientSignalKind.lipTremor, 0.0055) &&
            metrics.directionChanges >= 6 &&
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
              'experimental': true,
              'detection_proxy': 'lip_contour_micro_movement',
            },
          );
          _lipDisplacements.clear();
          _lipObservationTimes.clear();
        }
      }
    }

    if (!eyeEnabled || leftEye == null || leftEye.isEmpty) {
      _eyeDisplacements.clear();
      _eyeObservationTimes.clear();
      _lastEyeTremorTime = DateTime.fromMillisecondsSinceEpoch(0);
    } else {
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
      _appendMicroMovement(
        _eyeDisplacements,
        _eyeObservationTimes,
        (eyeCenterY - referenceY) / faceHeight,
        now,
      );
      if (isConsistentMicroMovement(_eyeDisplacements, _eyeObservationTimes)) {
        final metrics = analyzeOscillation(_eyeDisplacements);
        if (metrics.detrendedRms >=
                _threshold(PatientSignalKind.eyeTremor, 0.0015) &&
            metrics.detrendedRms <= 0.020 &&
            metrics.peakToPeak >=
                _threshold(PatientSignalKind.eyeTremor, 0.0045) &&
            metrics.directionChanges >= 6 &&
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
              'experimental': true,
              'detection_proxy': 'periocular_contour_micro_movement',
            },
          );
          _eyeDisplacements.clear();
          _eyeObservationTimes.clear();
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
    // Pose-independent contour motion for the intent pipeline (energy,
    // direction consistency, lip-specific motion). Unlike the experimental
    // muscle-movement signal below this is never gated by sensitivities.
    _lastMouthAsymmetry = cornerHeightDifference.abs();
    if (_previousContourCentersAll.isNotEmpty && current.isNotEmpty) {
      var movement = 0.0;
      var lipMovement = 0.0;
      var lipCount = 0;
      var cosSum = 0.0;
      var sinSum = 0.0;
      var count = 0;
      for (final entry in current.entries) {
        final previous = _previousContourCentersAll[entry.key];
        if (previous == null) continue;
        final delta = entry.value - previous;
        movement += delta.distance;
        count++;
        if (delta.distance > 1e-6) {
          final angle = math.atan2(delta.dy, delta.dx);
          cosSum += math.cos(angle);
          sinSum += math.sin(angle);
        }
        if (entry.key == FaceContourType.upperLipTop ||
            entry.key == FaceContourType.lowerLipBottom) {
          lipMovement += delta.distance;
          lipCount++;
        }
      }
      _lastContourMotion = count == 0 ? 0.0 : movement / count;
      _lastLipMotion = lipCount == 0 ? 0.0 : lipMovement / lipCount;
      _lastContourDirectionConsistency = count == 0
          ? 0.0
          : math.sqrt(math.pow(cosSum / count, 2) + math.pow(sinSum / count, 2));
    } else {
      _lastContourMotion = 0.0;
      _lastLipMotion = 0.0;
      _lastContourDirectionConsistency = 0.0;
    }
    _previousContourCentersAll = current;

    var normalizedMovement = 0.0;
    if (poseStable &&
        _previousContourCenters.isNotEmpty &&
        current.isNotEmpty) {
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
    _previousContourCenters = poseStable ? current : const {};
    final muscleEnabled = poseStable &&
        _signalSensitivities
            .containsKey(PatientSignalKind.facialMuscleMovement);
    if (!muscleEnabled) _facialMovementEnergy = 0;
    final muscleScore =
        muscleEnabled && !namedExpressionActive ? normalizedMovement : 0.0;
    _facialMovementEnergy = muscleScore > 0
        ? _facialMovementEnergy * 0.62 + muscleScore * 0.38
        : _facialMovementEnergy * 0.35;
    final muscleEnter =
        _threshold(PatientSignalKind.facialMuscleMovement, 0.008);
    _emitStableSignal(
      kind: PatientSignalKind.facialMuscleMovement,
      score: _facialMovementEnergy,
      confidence:
          (0.72 + _facialMovementEnergy / muscleEnter * 0.20).clamp(0, 0.98),
      now: now,
      enterThreshold: muscleEnter,
      exitThreshold: muscleEnter * 0.55,
      minimumHold: const Duration(milliseconds: 180),
      metadata: const {
        'experimental': true,
        'detection_proxy': 'facial_contour_movement',
      },
    );
  }

  void _appendMicroMovement(
    List<double> values,
    List<DateTime> observations,
    double value,
    DateTime now,
  ) {
    if (!value.isFinite ||
        observations.isNotEmpty &&
            (now.difference(observations.last) <= Duration.zero ||
                now.difference(observations.last) >
                    const Duration(milliseconds: 350))) {
      values.clear();
      observations.clear();
    }
    if (!value.isFinite) return;
    values.add(value);
    observations.add(now);
    while (values.length > 64 ||
        now.difference(observations.first) > const Duration(seconds: 4)) {
      values.removeAt(0);
      observations.removeAt(0);
    }
  }

  void _resetTemporalTracking() {
    _stabilityGate.clear();
    _headMotionFilter.clear();
    _previousContourCenters = const {};
    _previousContourCentersAll = const {};
    _lastContourMotion = 0;
    _lastContourDirectionConsistency = 0;
    _lastLipMotion = 0;
    _lastMouthAsymmetry = 0;
    _lipDisplacements.clear();
    _eyeDisplacements.clear();
    _lipObservationTimes.clear();
    _eyeObservationTimes.clear();
    _lastLipTremorTime = DateTime.fromMillisecondsSinceEpoch(0);
    _lastEyeTremorTime = DateTime.fromMillisecondsSinceEpoch(0);
    _facialMovementEnergy = 0;
    _respirationEstimator.clear();
    _eyesClosedSince = DateTime.fromMillisecondsSinceEpoch(0);
    _closedEyeConfidence = 0;
    _recentBlinks.clear();
    _recentRapidBlinks.clear();
    _pendingBlink = null;
    _pendingBlinkTimer?.cancel();
    _pendingBlinkTimer = null;
    _gazeReturnArmed = false;
  }

  InputImage? _toInputImage(CameraImage image, CameraController controller) {
    if (kIsWeb || (!Platform.isAndroid && !Platform.isIOS)) return null;
    final rotation = _inputRotation(controller);
    if (rotation == null) return null;
    final frame = prepareFaceCameraFrame(
      platform: Platform.isAndroid
          ? FaceFramePlatform.android
          : FaceFramePlatform.ios,
      width: image.width,
      height: image.height,
      rawFormat: image.format.raw,
      planes: image.planes
          .map((plane) => FaceCameraPlane(
                bytes: plane.bytes,
                bytesPerRow: plane.bytesPerRow,
                bytesPerPixel: plane.bytesPerPixel,
              ))
          .toList(growable: false),
    );
    if (frame == null) return null;

    return InputImage.fromBytes(
      bytes: frame.bytes,
      metadata: InputImageMetadata(
        size: Size(image.width.toDouble(), image.height.toDouble()),
        rotation: rotation,
        format: frame.format,
        bytesPerRow: frame.bytesPerRow,
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
    if (!_lifecycleIntent.shouldRun) return;
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
    if (_closed) return;
    _signals.add(PatientSignal(
      kind: kind,
      confidence: confidence.clamp(0, 1).toDouble(),
      observedAt: DateTime.now(),
      metadata: metadata,
    ));
  }

  @override
  Future<void> stop() async {
    if (kIsWeb) {
      _webFaceBridge.stop();
    }
    _lifecycleIntent.requestStop();
    ++_streamGeneration;
    _resetTemporalTracking();
    _publishStatus(const MonitorStatus.stopped());
    await _queueCameraTransition(_stopCamera);
  }

  Future<void> _stopCamera() async {
    ++_streamGeneration;
    final controller = _controller;
    _controller = null;
    _faceWasPresent = false;
    _primaryTrackingId = null;
    _previousPrimaryBox = null;
    _signalCooldownGate.clear();
    _resetTemporalTracking();
    _publishStatus(const MonitorStatus.stopped());
    await _disposeController(controller);
  }

  @override
  Future<void> dispose() async {
    if (_closed) return;
    _closed = true;
    _webStatusSub?.cancel();
    _webSignalSub?.cancel();
    _webFaceBridge.dispose();
    _lifecycleIntent.dispose();
    WidgetsBinding.instance.removeObserver(this);
    ++_streamGeneration;
    _resetTemporalTracking();
    await _queueCameraTransition(_stopCamera);
    try {
      await _detector.close();
    } on Object {
      // Ignored: detector might already be closed.
    }
    await _signals.close();
    await _statuses.close();
    await _observations.close();
  }
}

class NoOpPatientSignalMonitor implements PatientSignalMonitor {
  final _signals = StreamController<PatientSignal>.broadcast();
  final _statuses = StreamController<MonitorStatus>.broadcast();
  final _observations = StreamController<IntentObservation>.broadcast();
  MonitorStatus _currentStatus = const MonitorStatus.stopped();

  @override
  CameraController? get cameraController => null;

  @override
  MonitorStatus get currentStatus => _currentStatus;

  @override
  Stream<PatientSignal> get signals => _signals.stream;

  @override
  Stream<MonitorStatus> get statuses => _statuses.stream;

  @override
  Stream<IntentObservation> get observations => _observations.stream;

  /// Tests and demos feed measurements directly.
  void simulateObservation(IntentObservation observation) {
    if (!_observations.isClosed) _observations.add(observation);
  }

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
    if (_currentStatus.lifecycle == MonitorLifecycle.active) {
      _publishStatus(MonitorStatus(
        lifecycle: MonitorLifecycle.active,
        message: 'Monitor active (calibrated baseline applied)',
        faceDetected: true,
        observedAt: DateTime.now(),
        leftEyeOpen: leftEyeOpenness ?? 0.88,
        rightEyeOpen: rightEyeOpenness ?? 0.88,
        eyebrowDistance: eyebrowDistance ?? 0.18,
        mouthDistance: mouthDistance ?? 0.08,
        smileProbability: smileProbability ?? 0.04,
        headYaw: headYaw ?? 0.0,
        headPitch: headPitch ?? 0.0,
        breathingStatus: _currentStatus.breathingStatus,
      ));
    }
  }

  @override
  void setSignalSensitivities(
    Map<PatientSignalKind, double> sensitivities,
  ) {}

  void _publishStatus(MonitorStatus status) {
    _currentStatus = status;
    _statuses.add(status);
  }

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
    _publishStatus(MonitorStatus(
      lifecycle: MonitorLifecycle.active,
      message: 'Monitor active (testing/simulated)',
      faceDetected: true,
      observedAt: DateTime.now(),
      leftEyeOpen: 0.88,
      rightEyeOpen: 0.88,
      eyebrowDistance: 0.18,
      mouthDistance: 0.08,
      smileProbability: 0.04,
      headYaw: 0.0,
      headPitch: 0.0,
      breathingStatus: 'Measuring… keep head and camera still',
    ));
  }

  @override
  Future<void> stop() async {
    _publishStatus(const MonitorStatus.stopped());
  }

  @override
  Future<void> dispose() async {
    await _signals.close();
    await _statuses.close();
    await _observations.close();
  }
}

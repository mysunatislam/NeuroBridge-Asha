// intent_recognition_service.dart
// Wires the on-device pipeline into the app:
//
//   PatientSignalMonitor observations -> IntentFrameBuilder -> IntentPipeline
//        execute -> PatientSignal (existing RecognitionTriggerController path)
//        confirm -> spoken prompt + IntentDecisionEvent for the UI
//        alert   -> PatientSignalKind.seizureAlert (caregiver notification path)
//
// Also hosts the five-phase calibration recorder used by the calibration page.

import 'dart:async';

import 'package:fingerspeak_mobile/models/patient_signal.dart';
import 'package:flutter/foundation.dart';

import 'frame_builder.dart';
import 'intent_pipeline.dart';
import 'intent_runtimes.dart';
import 'intent_schema.dart';
import 'patient_calibration_service.dart';
import 'patient_profile.dart';
import 'verification_engine.dart';
import 'window_features.dart';

enum IntentDecisionKind { executed, confirmationRequested, cancelled, alert }

class IntentDecisionEvent {
  const IntentDecisionEvent({
    required this.kind,
    required this.command,
    required this.confidence,
    required this.reason,
    required this.at,
    this.prompt,
    this.signalKind,
  });

  final IntentDecisionKind kind;
  final String command;
  final double confidence;
  final String reason;
  final DateTime at;
  final String? prompt;
  final PatientSignalKind? signalKind;
}

class IntentRecognitionService extends ChangeNotifier {
  IntentRecognitionService({
    required Stream<IntentObservation> observations,
    required PatientProfileRepository profileRepository,
    required this.onExecute,
    required this.onConfirmationPrompt,
    required this.onAlert,
    Future<IntentModelBundle> Function()? bundleLoader,
    this.enabled = true,
  })  : _observations = observations,
        _profileRepository = profileRepository,
        _bundleLoader = bundleLoader ?? (() => IntentModelBundle.loadFromAssets());

  final Stream<IntentObservation> _observations;
  final PatientProfileRepository _profileRepository;
  final Future<IntentModelBundle> Function() _bundleLoader;

  /// Called with the mapped signal for a verified command.
  final void Function(PatientSignal signal, Verdict verdict) onExecute;

  /// Called when the engine wants the patient to confirm ("Did you mean help?").
  final void Function(String command, String prompt, double confidence) onConfirmationPrompt;

  /// Called for seizure-like / spasm alerts.
  final void Function(String abnormalLabel, double probability) onAlert;

  final _events = StreamController<IntentDecisionEvent>.broadcast();
  final IntentFrameBuilder _frames = IntentFrameBuilder();
  StreamSubscription<IntentObservation>? _subscription;
  IntentPipeline? _pipeline;
  IntentModelBundle? _bundle;
  PatientProfile _profile = PatientProfile.populationDefault();
  String? _loadError;
  bool enabled;
  bool _started = false;
  int _framesSeen = 0;
  PatientCalibrationSession? _calibration;
  String? _calibrationPhase;

  Stream<IntentDecisionEvent> get events => _events.stream;
  PatientProfile get profile => _profile;

  /// Enable or disable the pipeline at runtime (persisted by MobileServices).
  void setEnabled(bool value) {
    if (enabled == value) return;
    enabled = value;
    if (!value) _pipeline?.reset();
    notifyListeners();
  }
  bool get isReady => _pipeline != null;
  bool get isCalibrated => _profile.isCalibrated;
  String? get loadError => _loadError;
  int get framesSeen => _framesSeen;
  bool get hasPendingConfirmation => _pipeline?.engine.hasPending ?? false;
  String? get pendingCommand => _pipeline?.engine.pendingCommand;
  PatientCalibrationSession? get calibrationSession => _calibration;
  String? get activeCalibrationPhase => _calibrationPhase;
  Map<String, dynamic>? get bundleManifest => _bundle?.manifest;
  List<PipelineEvent> get recentEvents => _pipeline?.history.toList() ?? const [];

  Future<void> start() async {
    if (_started) return;
    _started = true;
    _profile = _profileRepository.load() ?? PatientProfile.populationDefault();
    try {
      _bundle = await _bundleLoader();
      _pipeline = IntentPipeline(bundle: _bundle!, profile: _profile);
      _loadError = null;
    } on Object catch (error) {
      _loadError = 'Intent models could not be loaded: $error';
    }
    _subscription = _observations.listen(_onObservation);
    notifyListeners();
  }

  void _onObservation(IntentObservation observation) {
    final frames = _frames.add(observation);
    if (frames.isEmpty) {
      if (!observation.faceDetected) {
        _pipeline?.window.clear();
      }
      return;
    }
    _framesSeen += frames.length;
    final phase = _calibrationPhase;
    if (phase != null && _calibration != null) {
      for (final frame in frames) {
        _calibration!.addFrame(phase, frame);
      }
      if (_framesSeen % 10 == 0) notifyListeners();
      return; // No commands are executed while calibrating.
    }
    if (!enabled) return;
    final pipeline = _pipeline;
    if (pipeline == null) return;
    for (final frame in frames) {
      final verdict = pipeline.push(frame);
      if (verdict != null) _handleVerdict(verdict, observation.observedAt);
    }
  }

  void _handleVerdict(Verdict verdict, DateTime at) {
    final pipeline = _pipeline!;
    switch (verdict.decision) {
      case VerificationDecision.execute:
        final signalName = pipeline.signalFor(verdict.command);
        final kind = signalName == null ? null : _signalKind(signalName);
        if (kind != null) {
          onExecute(
            PatientSignal(
              kind: kind,
              confidence: verdict.confidence,
              observedAt: at,
              sourceLabel: 'intent-pipeline',
              metadata: {
                'command': verdict.command,
                'reason': verdict.reason,
                'active_duration_ms': (kSequenceSeconds * 1000).round(),
                'p_intentional': verdict.evidence?.pIntentional,
                'p_abnormal': verdict.evidence?.pAbnormal,
              },
            ),
            verdict,
          );
        }
        _emit(IntentDecisionKind.executed, verdict, at, signalKind: kind);
      case VerificationDecision.confirm:
        onConfirmationPrompt(verdict.command, verdict.prompt ?? 'Did you mean that?', verdict.confidence);
        _emit(IntentDecisionKind.confirmationRequested, verdict, at);
      case VerificationDecision.alert:
        onAlert(verdict.command, verdict.confidence);
        _emit(IntentDecisionKind.alert, verdict, at, signalKind: PatientSignalKind.seizureAlert);
      case VerificationDecision.cancel:
        _emit(IntentDecisionKind.cancelled, verdict, at);
      case VerificationDecision.ignore:
        break;
    }
    notifyListeners();
  }

  void _emit(IntentDecisionKind kind, Verdict verdict, DateTime at, {PatientSignalKind? signalKind}) {
    if (_events.isClosed) return;
    _events.add(IntentDecisionEvent(
      kind: kind,
      command: verdict.command,
      confidence: verdict.confidence,
      reason: verdict.reason,
      at: at,
      prompt: verdict.prompt,
      signalKind: signalKind,
    ));
  }

  static PatientSignalKind? _signalKind(String name) {
    for (final kind in PatientSignalKind.values) {
      if (kind.name == name) return kind;
    }
    return null;
  }

  /// Patient or caregiver confirmed the pending command by touch.
  void confirmPendingByTouch() {
    final pipeline = _pipeline;
    if (pipeline == null) return;
    final verdict = pipeline.confirmByTouch(_frames.secondsFor(DateTime.now()));
    if (verdict != null) _handleVerdict(verdict, DateTime.now());
  }

  void cancelPending() {
    _pipeline?.cancelPending();
    notifyListeners();
  }

  // -- calibration ---------------------------------------------------------------

  void beginCalibration(String patientId) {
    _calibration = PatientCalibrationSession(patientId: patientId);
    _calibrationPhase = null;
    notifyListeners();
  }

  void startCalibrationPhase(String phase) {
    if (!CalibrationPhase.all.contains(phase)) throw ArgumentError('unknown phase $phase');
    _calibration ??= PatientCalibrationSession(patientId: _profile.patientId);
    _calibration!.clearPhase(phase);
    _calibrationPhase = phase;
    _frames.reset();
    notifyListeners();
  }

  void stopCalibrationPhase() {
    _calibrationPhase = null;
    _frames.reset();
    _pipeline?.window.clear();
    notifyListeners();
  }

  double calibrationProgress(String phase) => _calibration?.progress(phase) ?? 0.0;

  /// Builds, stores and activates the patient profile.
  Future<PatientProfile> finishCalibration() async {
    final session = _calibration;
    if (session == null) throw CalibrationException('no calibration in progress');
    final profile = session.buildProfile();
    await _profileRepository.save(profile);
    _profile = profile;
    _pipeline?.profile = profile;
    _pipeline?.reset();
    _calibrationPhase = null;
    notifyListeners();
    return profile;
  }

  String? exportCalibrationRecordings() => _calibration?.exportRecordingsJson();

  Future<void> importProfileJson(String json) async {
    final profile = PatientProfile.parse(json);
    await _profileRepository.save(profile);
    _profile = profile;
    _pipeline?.profile = profile;
    _pipeline?.reset();
    notifyListeners();
  }

  Future<void> resetProfile() async {
    await _profileRepository.clear();
    _profile = PatientProfile.populationDefault();
    _pipeline?.profile = _profile;
    _pipeline?.reset();
    notifyListeners();
  }

  Map<String, Object?> eventPayload({String patientHistory = ''}) =>
      _pipeline?.eventPayload(patientHistory: patientHistory) ??
      {'patient_state': 'idle', 'patient_history': patientHistory};

  /// Feed synthetic frames (tests / demo mode).
  void debugPushFrames(Iterable<IntentFrame> frames) {
    final pipeline = _pipeline;
    if (pipeline == null) return;
    for (final frame in frames) {
      final verdict = pipeline.push(frame);
      if (verdict != null) _handleVerdict(verdict, DateTime.now());
    }
  }

  @override
  void dispose() {
    unawaited(_subscription?.cancel());
    unawaited(_events.close());
    super.dispose();
  }
}

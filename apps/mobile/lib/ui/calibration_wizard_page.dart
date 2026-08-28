import 'dart:async';

import 'package:camera/camera.dart';
import 'package:fingerspeak_mobile/core/mobile_services.dart';
import 'package:fingerspeak_mobile/models/patient_signal.dart';
import 'package:fingerspeak_mobile/services/calibration_service.dart';
import 'package:fingerspeak_mobile/services/voice_service.dart';
import 'package:fingerspeak_mobile/ui/hand_calibration_page.dart';
import 'package:flutter/material.dart';

class CalibrationWizardPage extends StatefulWidget {
  const CalibrationWizardPage({required this.services, super.key});

  final MobileServices services;

  @override
  State<CalibrationWizardPage> createState() => _CalibrationWizardPageState();
}

class _CalibrationWizardPageState extends State<CalibrationWizardPage> {
  int _currentStep = 0;
  PatientSignalKind _selectedSignal = PatientSignalKind.blink;
  final TextEditingController _phraseController = TextEditingController();
  final TextEditingController _customKeyController = TextEditingController();
  double _sensitivity = 0.75;
  int _dwellMilliseconds = 500;
  bool _recording = false;
  bool _recordingBusy = false;
  bool _previewingRecording = false;
  bool _saving = false;
  bool _calibratingBaseline = false;
  double _baselineProgress = 0.0;
  bool _baselineCalibrated = false;
  Timer? _baselineTimer;

  bool _isCoachingActive = false;
  PatientSignalKind? _activeCoachingSignal;
  String _coachingPrompt = '';
  int _coachingCountdown = 0;
  Timer? _coachingTimer;

  MonitorStatus _monitorStatus = const MonitorStatus.stopped();
  PatientSignal? _lastSignal;
  StreamSubscription<MonitorStatus>? _monitorSubscription;
  StreamSubscription<PatientSignal>? _signalSubscription;

  static const _calibratableSignals = <PatientSignalKind>[
    PatientSignalKind.blink,
    PatientSignalKind.rapidBlink,
    PatientSignalKind.slowBlink,
    PatientSignalKind.eyeTremor,
    PatientSignalKind.eyeLookCenter,
    PatientSignalKind.eyeLookLeft,
    PatientSignalKind.eyeLookRight,
    PatientSignalKind.leftWink,
    PatientSignalKind.rightWink,
    PatientSignalKind.smile,
    PatientSignalKind.smileLeft,
    PatientSignalKind.smileRight,
    PatientSignalKind.eyebrowsUp,
    PatientSignalKind.mouthOpen,
    PatientSignalKind.headTurnSlow,
    PatientSignalKind.headTurnRapid,
    PatientSignalKind.headNodSmile,
    PatientSignalKind.lipTremor,
    PatientSignalKind.facialMuscleMovement,
  ];

  @override
  void initState() {
    super.initState();
    widget.services.recognition.beginCalibrationSession();
    _baselineCalibrated =
        widget.services.neutralBaselineRepository.load() != null;
    _loadCurrentPhrase();

    _monitorSubscription = widget.services.monitor.statuses.listen((status) {
      if (mounted) setState(() => _monitorStatus = status);
    });
    _signalSubscription = widget.services.monitor.signals.listen((signal) {
      if (mounted) {
        setState(() => _lastSignal = signal);
        if (_isCoachingActive && _activeCoachingSignal == signal.kind) {
          unawaited(_onCoachedSignalDetected(signal));
        }
      }
    });

    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) unawaited(widget.services.monitor.start());
    });
  }

  @override
  void dispose() {
    _baselineTimer?.cancel();
    _coachingTimer?.cancel();
    unawaited(_monitorSubscription?.cancel());
    unawaited(_signalSubscription?.cancel());
    _phraseController.dispose();
    _customKeyController.dispose();
    widget.services.recognition.endCalibrationSession();
    super.dispose();
  }

  void _startBaselineCalibration() {
    if (_calibratingBaseline) return;
    setState(() {
      _calibratingBaseline = true;
      _baselineProgress = 0.0;
      _baselineCalibrated = false;
    });

    var eyeSamplesCount = 0;
    var eyebrowSamplesCount = 0;
    var mouthSamplesCount = 0;
    var smileSamplesCount = 0;
    var poseSamplesCount = 0;
    var sumLeftEye = 0.0;
    var sumRightEye = 0.0;
    var sumEyebrowDistance = 0.0;
    var sumMouthDistance = 0.0;
    var sumSmileProbability = 0.0;
    var sumHeadYaw = 0.0;
    var sumHeadPitch = 0.0;

    const totalSteps = 40;
    var currentStep = 0;
    _baselineTimer = Timer.periodic(const Duration(milliseconds: 100), (timer) {
      currentStep++;
      if (!mounted) {
        timer.cancel();
        return;
      }
      if (_monitorStatus.faceDetected &&
          _monitorStatus.leftEyeOpen != null &&
          _monitorStatus.rightEyeOpen != null) {
        sumLeftEye += _monitorStatus.leftEyeOpen!;
        sumRightEye += _monitorStatus.rightEyeOpen!;
        eyeSamplesCount++;
      }
      if (_monitorStatus.faceDetected &&
          _monitorStatus.eyebrowDistance != null) {
        sumEyebrowDistance += _monitorStatus.eyebrowDistance!;
        eyebrowSamplesCount++;
      }
      if (_monitorStatus.faceDetected && _monitorStatus.mouthDistance != null) {
        sumMouthDistance += _monitorStatus.mouthDistance!;
        mouthSamplesCount++;
      }
      if (_monitorStatus.faceDetected &&
          _monitorStatus.smileProbability != null) {
        sumSmileProbability += _monitorStatus.smileProbability!;
        smileSamplesCount++;
      }
      if (_monitorStatus.faceDetected &&
          _monitorStatus.headYaw != null &&
          _monitorStatus.headPitch != null) {
        sumHeadYaw += _monitorStatus.headYaw!;
        sumHeadPitch += _monitorStatus.headPitch!;
        poseSamplesCount++;
      }
      setState(() {
        _baselineProgress = currentStep / totalSteps;
      });
      if (currentStep >= totalSteps) {
        timer.cancel();
        unawaited(_completeBaselineCalibration(
          eyeSamplesCount: eyeSamplesCount,
          eyebrowSamplesCount: eyebrowSamplesCount,
          mouthSamplesCount: mouthSamplesCount,
          smileSamplesCount: smileSamplesCount,
          poseSamplesCount: poseSamplesCount,
          sumLeftEye: sumLeftEye,
          sumRightEye: sumRightEye,
          sumEyebrowDistance: sumEyebrowDistance,
          sumMouthDistance: sumMouthDistance,
          sumSmileProbability: sumSmileProbability,
          sumHeadYaw: sumHeadYaw,
          sumHeadPitch: sumHeadPitch,
        ));
      }
    });
  }

  Future<void> _completeBaselineCalibration({
    required int eyeSamplesCount,
    required int eyebrowSamplesCount,
    required int mouthSamplesCount,
    required int smileSamplesCount,
    required int poseSamplesCount,
    required double sumLeftEye,
    required double sumRightEye,
    required double sumEyebrowDistance,
    required double sumMouthDistance,
    required double sumSmileProbability,
    required double sumHeadYaw,
    required double sumHeadPitch,
  }) async {
    const minimumSamples = 5;
    if (eyeSamplesCount < minimumSamples ||
        eyebrowSamplesCount < minimumSamples ||
        mouthSamplesCount < minimumSamples ||
        poseSamplesCount < minimumSamples) {
      if (!mounted) return;
      setState(() {
        _calibratingBaseline = false;
        _baselineCalibrated = false;
        _baselineProgress = 0;
      });
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text(
            'Baseline was not saved because a stable face was not measured. Keep your full face in frame and retry.',
          ),
        ),
      );
      return;
    }

    final baseline = NeutralFaceBaseline(
      leftEyeOpenness: sumLeftEye / eyeSamplesCount,
      rightEyeOpenness: sumRightEye / eyeSamplesCount,
      eyebrowDistance: sumEyebrowDistance / eyebrowSamplesCount,
      mouthDistance: sumMouthDistance / mouthSamplesCount,
      smileProbability: smileSamplesCount == 0
          ? NeutralFaceBaseline.standard.smileProbability
          : sumSmileProbability / smileSamplesCount,
      headYaw: sumHeadYaw / poseSamplesCount,
      headPitch: sumHeadPitch / poseSamplesCount,
    );

    try {
      await widget.services.saveNeutralFaceBaseline(baseline);
      if (!mounted) return;
      setState(() {
        _calibratingBaseline = false;
        _baselineCalibrated = true;
        _baselineProgress = 1.0;
      });
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text(
            'Neutral face baseline measured, saved, and applied to live detection.',
          ),
          backgroundColor: Color(0xFF0B756A),
        ),
      );
    } on Object {
      if (!mounted) return;
      setState(() {
        _calibratingBaseline = false;
        _baselineCalibrated = false;
      });
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
            content:
                Text('Could not save the neutral baseline. Please retry.')),
      );
    }
  }

  void _startCoachingAction(PatientSignalKind signal, String prompt) {
    _coachingTimer?.cancel();
    setState(() {
      _isCoachingActive = true;
      _activeCoachingSignal = signal;
      _coachingPrompt = prompt;
      _coachingCountdown = 5;
      _selectedSignal = signal;
      _loadCurrentPhrase();
    });

    _coachingTimer = Timer.periodic(const Duration(seconds: 1), (timer) {
      if (!mounted) {
        timer.cancel();
        return;
      }
      if (_coachingCountdown > 1) {
        setState(() => _coachingCountdown--);
      } else {
        timer.cancel();
        setState(() {
          _isCoachingActive = false;
          _coachingPrompt =
              'Time finished. You can retry or assign a phrase below.';
        });
      }
    });
  }

  Future<void> _onCoachedSignalDetected(PatientSignal signal) async {
    _coachingTimer?.cancel();
    setState(() {
      _isCoachingActive = false;
      _coachingPrompt =
          'PERFECT! Detected ${signal.kind.displayName} (${(signal.confidence * 100).round()}% confidence)';
    });

    final phrase = _phraseController.text.trim();
    if (phrase.isNotEmpty) {
      await widget.services.recognition.save(CalibratedPhrase(
        signal: _selectedSignal,
        key: _customKeyController.text.trim().isEmpty
            ? _selectedSignal.name
            : _customKeyController.text.trim(),
        phrase: phrase,
        minimumConfidence: (1.0 - (_sensitivity * 0.35)).clamp(0.55, 0.95),
        dwell: Duration(milliseconds: _dwellMilliseconds),
        sensitivity: _sensitivity,
      ));
    }
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(
          phrase.isEmpty
              ? 'Detected ${signal.kind.displayName}. Enter a phrase before saving.'
              : '${signal.kind.displayName} detected and its phrase mapping is now active.',
        ),
        backgroundColor: const Color(0xFF0B756A),
      ),
    );
  }

  void _loadCurrentPhrase() {
    final existing = widget.services.recognition.phrases
        .where((p) => p.signal == _selectedSignal);
    if (existing.isNotEmpty) {
      final p = existing.first;
      _phraseController.text = p.phrase;
      _customKeyController.text = p.key;
      _sensitivity = p.sensitivity;
      _dwellMilliseconds = p.dwell.inMilliseconds;
    } else {
      _phraseController.text = _defaultPhraseSuggestionFor(_selectedSignal);
      _customKeyController.text = _selectedSignal.name;
      _sensitivity = 0.75;
      _dwellMilliseconds = _defaultDwellMillisecondsFor(_selectedSignal);
    }
  }

  int _defaultDwellMillisecondsFor(PatientSignalKind signal) =>
      switch (signal) {
        PatientSignalKind.blink => 100,
        PatientSignalKind.rapidBlink ||
        PatientSignalKind.headTurnRapid ||
        PatientSignalKind.eyeTremor ||
        PatientSignalKind.lipTremor ||
        PatientSignalKind.facialMuscleMovement =>
          0,
        PatientSignalKind.leftWink || PatientSignalKind.rightWink => 250,
        PatientSignalKind.headTurnSlow => 300,
        PatientSignalKind.slowBlink => 700,
        _ => 500,
      };

  String _defaultPhraseSuggestionFor(PatientSignalKind kind) => switch (kind) {
        PatientSignalKind.blink => 'I need some help',
        PatientSignalKind.rapidBlink => 'Emergency, I need help right now',
        PatientSignalKind.slowBlink => 'Please let me rest for a moment',
        PatientSignalKind.eyeTremor => 'My eyes are trembling',
        PatientSignalKind.eyeLookCenter => 'Asha, I am looking at you',
        PatientSignalKind.eyeLookLeft => 'No, thank you',
        PatientSignalKind.eyeLookRight => 'Yes, please',
        PatientSignalKind.leftWink => 'Yes',
        PatientSignalKind.rightWink => 'No',
        PatientSignalKind.smile => 'Thank you very much',
        PatientSignalKind.smileLeft => 'I feel good',
        PatientSignalKind.smileRight => 'Please adjust my position',
        PatientSignalKind.eyebrowsUp => 'Yes',
        PatientSignalKind.mouthOpen => 'I would like some water',
        PatientSignalKind.headTurnSlow => 'Look over here',
        PatientSignalKind.headTurnRapid => 'Urgent assistance please',
        PatientSignalKind.headNodSmile => 'I agree with you',
        PatientSignalKind.handRaised => 'Hello, I am here',
        PatientSignalKind.handOpenPalm => 'Stop, please wait',
        PatientSignalKind.handFist => 'I am in pain',
        PatientSignalKind.handIndexPoint => 'I need that item',
        PatientSignalKind.lipTremor => 'I am feeling cold or shivering',
        PatientSignalKind.facialMuscleMovement => 'Muscle spasm detected',
        _ => 'Hello Asha',
      };

  String get _currentPhraseKey {
    final customKey = _customKeyController.text.trim();
    return customKey.isEmpty ? _selectedSignal.name : customKey;
  }

  bool get _hasCurrentCaregiverRecording =>
      widget.services.voice.recordings.hasRecording(
        _currentPhraseKey,
        _phraseController.text,
      );

  Future<void> _saveCalibration() async {
    final phrase = _phraseController.text.trim();
    if (phrase.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Please enter a phrase to speak.')),
      );
      return;
    }
    final key = _currentPhraseKey;

    setState(() => _saving = true);
    await widget.services.recognition.save(CalibratedPhrase(
      signal: _selectedSignal,
      key: key,
      phrase: phrase,
      minimumConfidence: (1.0 - (_sensitivity * 0.35)).clamp(0.55, 0.95),
      dwell: Duration(milliseconds: _dwellMilliseconds),
      sensitivity: _sensitivity,
    ));
    if (mounted) {
      setState(() => _saving = false);
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            'Saved mapping: ${_selectedSignal.displayName} → “$phrase”',
          ),
          backgroundColor: const Color(0xFF0B756A),
        ),
      );
    }
  }

  Future<void> _toggleCaregiverRecording() async {
    if (_recordingBusy || _previewingRecording) return;
    final phrase = _phraseController.text.trim();
    if (!_recording && phrase.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Please enter the phrase first.')),
      );
      return;
    }
    setState(() => _recordingBusy = true);
    try {
      if (_recording) {
        final path = await widget.services.voice.stopCaregiverRecording();
        if (!mounted) return;
        setState(() => _recording = false);
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(
          content: Text(path == null
              ? 'No recording was saved. Please try again.'
              : 'Caregiver recording saved. Use Listen to Recording to verify it.'),
        ));
        return;
      }

      final started = await widget.services.voice.startCaregiverRecording(
        _currentPhraseKey,
        phrase,
      );
      if (!mounted) return;
      if (started) {
        setState(() => _recording = true);
      } else {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text(
              'Microphone permission is required to record caregiver audio.',
            ),
          ),
        );
      }
    } on Object catch (error) {
      if (!mounted) return;
      setState(() => _recording = false);
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Caregiver recording failed: $error')),
      );
    } finally {
      if (mounted) setState(() => _recordingBusy = false);
    }
  }

  Future<void> _previewCaregiverRecording() async {
    if (_recording || _recordingBusy || _previewingRecording) return;
    setState(() => _previewingRecording = true);
    CaregiverRecordingPlayback result;
    try {
      result = await widget.services.voice.previewCaregiverRecording(
        _currentPhraseKey,
        _phraseController.text,
      );
    } on Object {
      result = CaregiverRecordingPlayback.failed;
    } finally {
      if (mounted) setState(() => _previewingRecording = false);
    }
    if (!mounted) return;
    final message = switch (result) {
      CaregiverRecordingPlayback.played =>
        'Caregiver recording playback complete.',
      CaregiverRecordingPlayback.missing =>
        'No recording matches these exact words. Record the phrase again.',
      CaregiverRecordingPlayback.failed =>
        'The saved recording could not be played. Record it again.',
    };
    ScaffoldMessenger.of(context)
        .showSnackBar(SnackBar(content: Text(message)));
  }

  Widget _buildCoachCard({
    required String title,
    required String prompt,
    required PatientSignalKind signal,
    required IconData icon,
  }) {
    final isSelected = _selectedSignal == signal;
    final isCoachingThis = _isCoachingActive && _activeCoachingSignal == signal;
    final isTriggered = _lastSignal?.kind == signal;

    return Card(
      elevation: isSelected ? 2 : 0,
      color: isCoachingThis
          ? const Color(0xFFE8F6F3)
          : isSelected
              ? const Color(0xFFF0FDF4)
              : const Color(0xFFF9FBFA),
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(14),
        side: BorderSide(
          color: isCoachingThis
              ? const Color(0xFF0B756A)
              : isSelected
                  ? const Color(0xFF86EFAC)
                  : const Color(0xFFE2E8F0),
          width: isCoachingThis || isSelected ? 1.8 : 1.0,
        ),
      ),
      margin: const EdgeInsets.only(bottom: 10),
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                CircleAvatar(
                  radius: 18,
                  backgroundColor: isTriggered
                      ? const Color(0xFF4ADE80)
                      : isCoachingThis
                          ? const Color(0xFF0B756A)
                          : const Color(0xFFDDE7E4),
                  child: Icon(
                    icon,
                    size: 20,
                    color: isTriggered || isCoachingThis
                        ? Colors.white
                        : const Color(0xFF0B756A),
                  ),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        title,
                        style: const TextStyle(
                            fontWeight: FontWeight.bold, fontSize: 14),
                      ),
                      Text(
                        prompt,
                        style: const TextStyle(
                            fontSize: 12, color: Color(0xFF556E68)),
                      ),
                    ],
                  ),
                ),
                if (isCoachingThis)
                  Container(
                    padding:
                        const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                    decoration: BoxDecoration(
                      color: const Color(0xFF0B756A),
                      borderRadius: BorderRadius.circular(12),
                    ),
                    child: Text(
                      '${_coachingCountdown}s',
                      style: const TextStyle(
                          color: Colors.white,
                          fontWeight: FontWeight.bold,
                          fontSize: 12),
                    ),
                  )
                else
                  FilledButton.tonal(
                    style: FilledButton.styleFrom(
                      padding: const EdgeInsets.symmetric(
                          horizontal: 10, vertical: 6),
                    ),
                    onPressed: () => _startCoachingAction(signal, prompt),
                    child: const Text('Coach & Test',
                        style: TextStyle(fontSize: 12)),
                  ),
              ],
            ),
            if (isSelected) ...[
              const SizedBox(height: 10),
              const Divider(height: 1),
              const SizedBox(height: 8),
              Row(
                children: [
                  const Icon(Icons.record_voice_over,
                      size: 16, color: Color(0xFF0B756A)),
                  const SizedBox(width: 6),
                  Expanded(
                    child: Text(
                      'Current mapped phrase: “${_phraseController.text.isEmpty ? "None" : _phraseController.text}”',
                      style: const TextStyle(
                          fontSize: 12,
                          fontWeight: FontWeight.w600,
                          color: Color(0xFF0B756A)),
                    ),
                  ),
                  TextButton(
                    onPressed: () {
                      setState(() {
                        _selectedSignal = signal;
                        _loadCurrentPhrase();
                      });
                      ScaffoldMessenger.of(context).showSnackBar(
                        SnackBar(
                            content: Text(
                                'Selected ${signal.displayName} for editing below.')),
                      );
                    },
                    child: const Text('Edit Phrase',
                        style: TextStyle(fontSize: 12)),
                  ),
                ],
              ),
            ],
          ],
        ),
      ),
    );
  }

  Future<void> _finishCalibration() async {
    if (_phraseController.text.trim().isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
            content: Text('Enter a phrase before finishing calibration.')),
      );
      return;
    }
    await _saveCalibration();
    if (mounted) Navigator.pop(context);
  }

  @override
  Widget build(BuildContext context) {
    final controller = widget.services.monitor.cameraController;
    final monitoring = _monitorStatus.lifecycle == MonitorLifecycle.active;
    final isCustomMode = widget.services.recognition.isCustomMode;

    return Scaffold(
      appBar: AppBar(
        title: const Text('Patient Signal Calibration'),
        actions: [
          IconButton(
            icon: const Icon(Icons.refresh),
            tooltip: 'Restart Camera Monitor',
            onPressed: () async {
              await widget.services.monitor.stop();
              await widget.services.monitor.start();
            },
          ),
        ],
      ),
      body: SingleChildScrollView(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Card(
              margin: const EdgeInsets.all(16),
              color: const Color(0xFF102522),
              clipBehavior: Clip.antiAlias,
              shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(20)),
              child: Column(
                children: [
                  if (monitoring &&
                      controller != null &&
                      controller.value.isInitialized)
                    SizedBox(
                      height: 200,
                      child: Stack(
                        fit: StackFit.expand,
                        children: [
                          Center(
                            child: AspectRatio(
                              aspectRatio: controller.value.aspectRatio > 0
                                  ? controller.value.aspectRatio
                                  : 4 / 3,
                              child: CameraPreview(controller),
                            ),
                          ),
                          Positioned(
                            top: 10,
                            left: 10,
                            child: Container(
                              padding: const EdgeInsets.symmetric(
                                  horizontal: 8, vertical: 4),
                              decoration: BoxDecoration(
                                color: const Color(0xCC000000),
                                borderRadius: BorderRadius.circular(6),
                                border:
                                    Border.all(color: const Color(0xFF0B756A)),
                              ),
                              child: const Row(
                                mainAxisSize: MainAxisSize.min,
                                children: [
                                  Icon(Icons.videocam,
                                      size: 13, color: Color(0xFF4ADE80)),
                                  SizedBox(width: 4),
                                  Text(
                                    'LIVE VISION CALIBRATION',
                                    style: TextStyle(
                                      color: Color(0xFF4ADE80),
                                      fontSize: 10,
                                      fontWeight: FontWeight.w700,
                                    ),
                                  ),
                                ],
                              ),
                            ),
                          ),
                          Center(
                            child: Container(
                              width: 120,
                              height: 140,
                              decoration: BoxDecoration(
                                borderRadius: BorderRadius.circular(60),
                                border: Border.all(
                                  color: const Color(0x664ADE80),
                                  width: 1.5,
                                ),
                              ),
                            ),
                          ),
                        ],
                      ),
                    )
                  else
                    Container(
                      height: 110,
                      color: const Color(0xFF0E1F1C),
                      child: Center(
                        child: Column(
                          mainAxisAlignment: MainAxisAlignment.center,
                          children: [
                            const Icon(Icons.face_retouching_natural,
                                color: Color(0xFFA6E3D9), size: 36),
                            const SizedBox(height: 6),
                            Text(
                              _monitorStatus.message,
                              style: const TextStyle(
                                  color: Color(0xFFC9D9D5), fontSize: 12),
                            ),
                          ],
                        ),
                      ),
                    ),
                  Padding(
                    padding: const EdgeInsets.symmetric(
                        horizontal: 14, vertical: 10),
                    child: Wrap(
                      spacing: 6,
                      runSpacing: 6,
                      children: [
                        _MiniChip(
                          icon: Icons.face,
                          text: _monitorStatus.faceDetected
                              ? 'Face in frame'
                              : 'Finding face',
                        ),
                        _MiniChip(
                          icon: Icons.remove_red_eye_outlined,
                          text:
                              'L:${((_monitorStatus.leftEyeOpen ?? 0.85) * 100).round()}% R:${((_monitorStatus.rightEyeOpen ?? 0.85) * 100).round()}%',
                        ),
                        if (_lastSignal != null)
                          _MiniChip(
                            icon: Icons.bolt,
                            text: _lastSignal!.kind.displayName,
                            color: const Color(0xFF4ADE80),
                          ),
                      ],
                    ),
                  ),
                  if (_coachingPrompt.isNotEmpty)
                    Container(
                      width: double.infinity,
                      padding: const EdgeInsets.symmetric(
                          horizontal: 14, vertical: 10),
                      color: const Color(0xFF0B756A),
                      child: Row(
                        children: [
                          const Icon(Icons.record_voice_over,
                              color: Colors.white, size: 20),
                          const SizedBox(width: 10),
                          Expanded(
                            child: Text(
                              _coachingPrompt,
                              style: const TextStyle(
                                  color: Colors.white,
                                  fontWeight: FontWeight.bold,
                                  fontSize: 13),
                            ),
                          ),
                        ],
                      ),
                    ),
                ],
              ),
            ),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16),
              child: Card(
                color: Colors.white,
                shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(16)),
                child: Padding(
                  padding: const EdgeInsets.all(16),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        children: [
                          const Icon(Icons.model_training,
                              color: Color(0xFF0B756A)),
                          const SizedBox(width: 8),
                          Text('Model Database & Profile Mode',
                              style: Theme.of(context)
                                  .textTheme
                                  .titleMedium
                                  ?.copyWith(fontWeight: FontWeight.bold)),
                        ],
                      ),
                      const SizedBox(height: 6),
                      const Text(
                        'Choose whether to use the pre-calibrated medical AAC database model or customized patient mappings.',
                        style:
                            TextStyle(fontSize: 13, color: Color(0xFF556E68)),
                      ),
                      const SizedBox(height: 12),
                      SegmentedButton<bool>(
                        segments: const [
                          ButtonSegment<bool>(
                            value: false,
                            label: Text('Standard Database Model'),
                            icon: Icon(Icons.storage),
                          ),
                          ButtonSegment<bool>(
                            value: true,
                            label: Text('Customized Patient Profile'),
                            icon: Icon(Icons.person),
                          ),
                        ],
                        selected: {isCustomMode},
                        onSelectionChanged: (set) async {
                          final custom = set.first;
                          if (!custom) {
                            await widget.services
                                .useStandardCalibrationProfile();
                          } else {
                            await widget.services.recognition
                                .setCustomMode(true);
                          }
                          if (mounted) setState(() => _loadCurrentPhrase());
                        },
                      ),
                    ],
                  ),
                ),
              ),
            ),
            const SizedBox(height: 12),
            Stepper(
              physics: const NeverScrollableScrollPhysics(),
              type: StepperType.vertical,
              currentStep: _currentStep,
              onStepContinue: () async {
                if (_currentStep < 5) {
                  setState(() => _currentStep++);
                } else {
                  await _finishCalibration();
                }
              },
              onStepCancel: () {
                if (_currentStep > 0) {
                  setState(() => _currentStep--);
                } else {
                  Navigator.pop(context);
                }
              },
              controlsBuilder: (context, details) {
                final isLast = _currentStep == 5;
                return Padding(
                  padding: const EdgeInsets.only(top: 16),
                  child: Row(
                    children: [
                      FilledButton(
                        onPressed: _saving ? null : details.onStepContinue,
                        child:
                            Text(isLast ? 'Finish Calibration' : 'Next Step'),
                      ),
                      const SizedBox(width: 12),
                      if (_currentStep > 0)
                        OutlinedButton(
                          onPressed: details.onStepCancel,
                          child: const Text('Back'),
                        ),
                    ],
                  ),
                );
              },
              steps: [
                Step(
                  title: const Text('1. Resting Baseline & Camera Alignment'),
                  isActive: _currentStep >= 0,
                  state:
                      _currentStep > 0 ? StepState.complete : StepState.indexed,
                  content: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      const Text(
                          'Look straight to the camera with a relaxed neutral expression. This eliminates false speech triggers.'),
                      const SizedBox(height: 12),
                      Container(
                        padding: const EdgeInsets.all(14),
                        decoration: BoxDecoration(
                          color: const Color(0xFFE8F6F3),
                          borderRadius: BorderRadius.circular(14),
                          border: Border.all(color: const Color(0xFFA6E3D9)),
                        ),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.stretch,
                          children: [
                            Row(
                              children: [
                                Icon(
                                  _baselineCalibrated
                                      ? Icons.check_circle
                                      : Icons.face_retouching_natural,
                                  color: const Color(0xFF0B756A),
                                  size: 22,
                                ),
                                const SizedBox(width: 8),
                                Text(
                                  _baselineCalibrated
                                      ? 'Neutral Baseline Calibrated'
                                      : '4-Second Neutral Calibration',
                                  style: const TextStyle(
                                      fontWeight: FontWeight.bold,
                                      fontSize: 14,
                                      color: Color(0xFF0B756A)),
                                ),
                              ],
                            ),
                            const SizedBox(height: 8),
                            if (_calibratingBaseline) ...[
                              LinearProgressIndicator(
                                  value: _baselineProgress, minHeight: 6),
                              const SizedBox(height: 8),
                              Text(
                                  'Sampling face baseline (${(_baselineProgress * 100).round()}%)… Hold relaxed expression.',
                                  style: const TextStyle(fontSize: 12)),
                            ],
                            const SizedBox(height: 10),
                            FilledButton.icon(
                              onPressed: _calibratingBaseline
                                  ? null
                                  : _startBaselineCalibration,
                              icon: const Icon(Icons.timer),
                              label: Text(_baselineCalibrated
                                  ? 'Recalibrate Neutral Face'
                                  : 'Start 4-Second Calibration'),
                            ),
                          ],
                        ),
                      ),
                    ],
                  ),
                ),
                Step(
                  title: const Text('2. Eye, Blink & Assisted Direction Suite'),
                  isActive: _currentStep >= 1,
                  state:
                      _currentStep > 1 ? StepState.complete : StepState.indexed,
                  content: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      const Text(
                        'Blinks use eye-open probability. Direction cues use a slight head-and-gaze pose because ML Kit Face Detection does not expose pupil or iris gaze.',
                      ),
                      const SizedBox(height: 10),
                      _buildCoachCard(
                        title: 'Return to Camera Center',
                        prompt:
                            'Look slightly to either side, then gently return your head and gaze to the camera.',
                        signal: PatientSignalKind.eyeLookCenter,
                        icon: Icons.center_focus_strong,
                      ),
                      _buildCoachCard(
                        title: 'Deliberate Normal Blink',
                        prompt: 'Blink your eyes naturally now.',
                        signal: PatientSignalKind.blink,
                        icon: Icons.remove_red_eye,
                      ),
                      _buildCoachCard(
                        title: 'Rapid Blink Flurry',
                        prompt: 'Blink your eyes rapidly 3 times in a row.',
                        signal: PatientSignalKind.rapidBlink,
                        icon: Icons.electric_bolt,
                      ),
                      _buildCoachCard(
                        title: 'Slow / Prolonged Blink',
                        prompt:
                            'Close your eyes slowly and hold closed for 1 second.',
                        signal: PatientSignalKind.slowBlink,
                        icon: Icons.nights_stay,
                      ),
                      _buildCoachCard(
                        title: 'Look Left Eye',
                        prompt:
                            'Turn your head slightly left while looking in that direction, then hold.',
                        signal: PatientSignalKind.eyeLookLeft,
                        icon: Icons.arrow_back,
                      ),
                      _buildCoachCard(
                        title: 'Look Right Eye',
                        prompt:
                            'Turn your head slightly right while looking in that direction, then hold.',
                        signal: PatientSignalKind.eyeLookRight,
                        icon: Icons.arrow_forward,
                      ),
                    ],
                  ),
                ),
                Step(
                  title: const Text('3. Mouth & Facial Expressions Suite'),
                  isActive: _currentStep >= 2,
                  state:
                      _currentStep > 2 ? StepState.complete : StepState.indexed,
                  content: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      const Text('Separate facial muscle mappings:'),
                      const SizedBox(height: 10),
                      _buildCoachCard(
                        title: 'Gentle Symmetrical Smile',
                        prompt: 'Smile gently with both sides of your mouth.',
                        signal: PatientSignalKind.smile,
                        icon: Icons.sentiment_satisfied_alt,
                      ),
                      _buildCoachCard(
                        title: 'Smile Left Lip Only',
                        prompt: 'Smile towards your left lip corner only.',
                        signal: PatientSignalKind.smileLeft,
                        icon: Icons.mood,
                      ),
                      _buildCoachCard(
                        title: 'Smile Right Lip Only',
                        prompt: 'Smile towards your right lip corner only.',
                        signal: PatientSignalKind.smileRight,
                        icon: Icons.mood,
                      ),
                      _buildCoachCard(
                        title: 'Open Mouth',
                        prompt: 'Open your mouth comfortably wide.',
                        signal: PatientSignalKind.mouthOpen,
                        icon: Icons.face,
                      ),
                      _buildCoachCard(
                        title: 'Raise Eyebrows',
                        prompt: 'Raise both eyebrows upwards.',
                        signal: PatientSignalKind.eyebrowsUp,
                        icon: Icons.arrow_upward,
                      ),
                    ],
                  ),
                ),
                Step(
                  title: const Text('4. Head Movement & Muscle Tremor Suite'),
                  isActive: _currentStep >= 3,
                  state:
                      _currentStep > 3 ? StepState.complete : StepState.indexed,
                  content: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      const Text('Track head motion dynamics:'),
                      const SizedBox(height: 10),
                      _buildCoachCard(
                        title: 'Move Head Slowly',
                        prompt: 'Turn your head smoothly to one side.',
                        signal: PatientSignalKind.headTurnSlow,
                        icon: Icons.rotate_left,
                      ),
                      _buildCoachCard(
                        title: 'Move Head Rapidly',
                        prompt:
                            'Move your head quickly to signal urgent attention.',
                        signal: PatientSignalKind.headTurnRapid,
                        icon: Icons.speed,
                      ),
                      _buildCoachCard(
                        title: 'Move Head While Smiling',
                        prompt: 'Nod or move your head gently while smiling.',
                        signal: PatientSignalKind.headNodSmile,
                        icon: Icons.add_reaction,
                      ),
                    ],
                  ),
                ),
                Step(
                  title: const Text('5. Hand & Finger Gesture Suite'),
                  isActive: _currentStep >= 4,
                  state:
                      _currentStep > 4 ? StepState.complete : StepState.indexed,
                  content: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      const Text(
                        'Hand gestures are calibrated and executed by the MediaPipe Hand Studio. The face monitor cannot verify hand actions on this screen.',
                      ),
                      const SizedBox(height: 12),
                      SizedBox(
                        width: double.infinity,
                        child: FilledButton.icon(
                          style: FilledButton.styleFrom(
                            backgroundColor: const Color(0xFF0F1720),
                            foregroundColor: const Color(0xFF4FD1C5),
                            side: const BorderSide(color: Color(0xFF4FD1C5)),
                            padding: const EdgeInsets.symmetric(vertical: 14),
                          ),
                          icon: const Icon(Icons.pan_tool_alt),
                          label: const Text('Open 3D MediaPipe Hand Studio'),
                          onPressed: () {
                            Navigator.of(context).push(
                              MaterialPageRoute<void>(
                                builder: (_) => HandCalibrationPage(
                                    services: widget.services),
                              ),
                            );
                          },
                        ),
                      ),
                    ],
                  ),
                ),
                Step(
                  title: const Text('6. Custom Phrase & Sensitivity Manager'),
                  isActive: _currentStep >= 5,
                  state: StepState.indexed,
                  content: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      DropdownButtonFormField<PatientSignalKind>(
                        initialValue: _selectedSignal,
                        decoration: const InputDecoration(
                          labelText: 'Select Trigger Signal to Customize',
                          border: OutlineInputBorder(),
                        ),
                        items: _calibratableSignals.map((signal) {
                          return DropdownMenuItem(
                            value: signal,
                            child: Text(signal.displayName),
                          );
                        }).toList(),
                        onChanged: _recording
                            ? null
                            : (signal) {
                                if (signal == null) return;
                                setState(() {
                                  _selectedSignal = signal;
                                  _loadCurrentPhrase();
                                });
                              },
                      ),
                      const SizedBox(height: 14),
                      TextField(
                        controller: _phraseController,
                        enabled: !_recording,
                        onChanged: (_) => setState(() {}),
                        decoration: const InputDecoration(
                          labelText: 'Spoken Phrase for this Action',
                          border: OutlineInputBorder(),
                        ),
                      ),
                      const SizedBox(height: 14),
                      Row(
                        mainAxisAlignment: MainAxisAlignment.spaceBetween,
                        children: [
                          const Text('Detection Sensitivity',
                              style: TextStyle(fontWeight: FontWeight.w600)),
                          Text('${(_sensitivity * 100).round()}%',
                              style: const TextStyle(
                                  fontWeight: FontWeight.bold,
                                  color: Color(0xFF0B756A))),
                        ],
                      ),
                      Slider(
                        value: _sensitivity,
                        min: 0.40,
                        max: 0.95,
                        divisions: 11,
                        onChanged: (val) => setState(() => _sensitivity = val),
                      ),
                      Row(
                        mainAxisAlignment: MainAxisAlignment.spaceBetween,
                        children: [
                          const Text('Intentional Hold Dwell Time',
                              style: TextStyle(fontWeight: FontWeight.w600)),
                          Text('$_dwellMilliseconds ms',
                              style: const TextStyle(
                                  fontWeight: FontWeight.bold,
                                  color: Color(0xFF0B756A))),
                        ],
                      ),
                      Slider(
                        value: _dwellMilliseconds.toDouble(),
                        min: 0,
                        max: 1500,
                        divisions: 15,
                        onChanged: (val) =>
                            setState(() => _dwellMilliseconds = val.round()),
                      ),
                      const SizedBox(height: 10),
                      Wrap(
                        spacing: 8,
                        runSpacing: 8,
                        children: [
                          OutlinedButton.icon(
                            onPressed: _recordingBusy || _previewingRecording
                                ? null
                                : _toggleCaregiverRecording,
                            icon: Icon(
                              _recording ? Icons.stop : Icons.mic,
                              color: _recording ? Colors.red : null,
                            ),
                            label: Text(_recording
                                ? 'Stop & Save Recording'
                                : 'Record Caregiver Audio'),
                          ),
                          OutlinedButton.icon(
                            onPressed: !_hasCurrentCaregiverRecording ||
                                    _recording ||
                                    _recordingBusy ||
                                    _previewingRecording
                                ? null
                                : _previewCaregiverRecording,
                            icon: Icon(_previewingRecording
                                ? Icons.volume_up
                                : Icons.play_arrow),
                            label: Text(_previewingRecording
                                ? 'Playing Recording…'
                                : 'Listen to Recording'),
                          ),
                        ],
                      ),
                      const SizedBox(height: 14),
                      FilledButton.icon(
                        onPressed: _saving ? null : _saveCalibration,
                        icon: const Icon(Icons.save),
                        label: const Text('Save Signal Mapping'),
                      ),
                    ],
                  ),
                ),
              ],
            ),
            const SizedBox(height: 24),
          ],
        ),
      ),
    );
  }
}

class _MiniChip extends StatelessWidget {
  const _MiniChip({required this.icon, required this.text, this.color});

  final IconData icon;
  final String text;
  final Color? color;

  @override
  Widget build(BuildContext context) {
    final c = color ?? const Color(0xFFA6E3D9);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      decoration: BoxDecoration(
        color: const Color(0x22FFFFFF),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: c.withValues(alpha: 0.4)),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 12, color: c),
          const SizedBox(width: 4),
          Text(text,
              style: TextStyle(
                  color: c, fontSize: 11, fontWeight: FontWeight.bold)),
        ],
      ),
    );
  }
}

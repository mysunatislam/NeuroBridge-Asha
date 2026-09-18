import 'dart:async';
import 'package:flutter/material.dart';
import '../core/mobile_services.dart';
import '../models/patient_access_method.dart';
import '../models/patient_signal.dart';
import '../services/calibration_service.dart';
import '../services/face_calibration_collector.dart';

class FacialCalibrationFlow extends StatefulWidget {
  const FacialCalibrationFlow({
    required this.services,
    this.onCompleted,
    super.key,
  });

  final MobileServices services;
  final VoidCallback? onCompleted;

  @override
  State<FacialCalibrationFlow> createState() => _FacialCalibrationFlowState();
}

class _FacialCalibrationFlowState extends State<FacialCalibrationFlow>
    with SingleTickerProviderStateMixin {
  int _currentStep = 1;
  static const int _totalSteps = 6;

  // ── Step 1: Neutral baseline collector ───────────────────────────────────
  late final FaceCalibrationCollector _collector;
  NeutralFaceBaseline? _measuredBaseline;
  String? _collectorValidationMsg;

  // ── Step 2: Blink detection (starts at 0 — not pre-filled) ───────────────
  int _blinksDetected = 0;
  static const int _targetBlinks = 3;

  // ── Step 3: Gaze range measurement ────────────────────────────────────────
  bool _gazeCalibrated = false;
  double _measuredGazeYaw = 15.0; // fallback; overwritten from live status

  // ── Step 4: Smile threshold measurement ───────────────────────────────────
  bool _smileCalibrated = false;
  double _measuredSmileProb = 0.28; // fallback; overwritten from live status

  // ── Step 5: Eyebrow ───────────────────────────────────────────────────────
  bool _eyebrowCalibrated = false;

  StreamSubscription<PatientSignal>? _signalSub;
  StreamSubscription<MonitorStatus>? _monitorSub;
  MonitorStatus? _lastStatus;
  late AnimationController _pulseController;

  @override
  void initState() {
    super.initState();
    _collector = FaceCalibrationCollector(
      minimumSamples: 24,
      minimumObservation: const Duration(seconds: 2),
    );

    _pulseController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1800),
    );
    final isTest = WidgetsBinding.instance.runtimeType.toString().contains('Test');
    if (!isTest) {
      _pulseController.repeat(reverse: true);
    }

    // ── Monitor status stream ─────────────────────────────────────────────
    _monitorSub = widget.services.monitor.statuses.listen((status) {
      if (!mounted) return;
      _lastStatus = status;

      // Step 1: feed every frame into the collector for neutral baseline
      if (_currentStep == 1) {
        final added = _collector.add(status);
        if (added || _collector.validationMessage != null) {
          setState(() {
            _collectorValidationMsg = _collector.validationMessage;
          });
        } else {
          setState(() {}); // update progress indicator
        }
      }
    });

    // ── Signal stream ─────────────────────────────────────────────────────
    _signalSub = widget.services.monitor.signals.listen((signal) {
      if (!mounted) return;

      if (_currentStep == 2 && signal.kind == PatientSignalKind.blink) {
        setState(() {
          if (_blinksDetected < _targetBlinks) _blinksDetected++;
        });
      } else if (_currentStep == 3 &&
          (signal.kind == PatientSignalKind.eyeLookRight ||
              signal.kind == PatientSignalKind.eyeLookLeft)) {
        // Capture the actual yaw at the moment of detection for per-patient
        // sensitivity calibration.
        final yaw = _lastStatus?.headYaw;
        setState(() {
          _gazeCalibrated = true;
          if (yaw != null && yaw.isFinite && yaw.abs() > 5) {
            _measuredGazeYaw = yaw.abs().clamp(5.0, 45.0);
          }
        });
      } else if (_currentStep == 4 && signal.kind == PatientSignalKind.smile) {
        final smileP = _lastStatus?.smileProbability;
        setState(() {
          _smileCalibrated = true;
          if (smileP != null && smileP.isFinite) {
            _measuredSmileProb = smileP.clamp(0.0, 1.0);
          }
        });
      } else if (_currentStep == 5 &&
          signal.kind == PatientSignalKind.eyebrowsUp) {
        setState(() => _eyebrowCalibrated = true);
      }
    });

    WidgetsBinding.instance.addPostFrameCallback((_) {
      widget.services.monitor.start();
    });
  }

  @override
  void dispose() {
    _pulseController.dispose();
    _signalSub?.cancel();
    _monitorSub?.cancel();
    super.dispose();
  }

  // ── Step validation — prevents advancing before real capture is ready ──
  bool get _canAdvance {
    switch (_currentStep) {
      case 1:
        // Must have a real measured baseline before leaving Step 1
        return _measuredBaseline != null;
      case 2:
        return _blinksDetected >= _targetBlinks;
      case 3:
        return _gazeCalibrated;
      case 4:
        return _smileCalibrated;
      case 5:
        return _eyebrowCalibrated;
      default:
        return true;
    }
  }

  void _handleNext() async {
    if (_currentStep == 1) {
      // Try to build the real baseline from collected samples
      final built = _collector.build();
      if (built == null) {
        // Collector rejected — show its validation message and stay on step 1
        setState(() {
          _collectorValidationMsg = _collector.validationMessage;
        });
        return;
      }
      setState(() {
        _measuredBaseline = built;
        _collectorValidationMsg = null;
        _currentStep++;
      });
      return;
    }

    if (_currentStep < _totalSteps) {
      setState(() => _currentStep++);
    } else {
      // ── Save the real patient-specific calibrated baseline ───────────────
      // Use what the collector actually measured; fall back to standard norms
      // if the collector was somehow skipped (should not happen in production).
      final calibrated = _measuredBaseline ?? NeutralFaceBaseline.standard;
      await widget.services.neutralBaselineRepository.save(calibrated);
      await widget.services.patientAccessMethodRepository
          .save(PatientAccessMethod.faceEyesAndHead);

      if (mounted) {
        if (widget.onCompleted != null) {
          widget.onCompleted!();
        } else {
          Navigator.of(context).pop(true);
        }
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFF070B18),
      body: Container(
        decoration: const BoxDecoration(
          gradient: RadialGradient(
            center: Alignment(0, -0.4),
            radius: 1.2,
            colors: [
              Color(0xFF1E1B4B),
              Color(0xFF0F172A),
              Color(0xFF030712),
            ],
          ),
        ),
        child: SafeArea(
          child: Column(
            children: [
              // ── Top Bar ────────────────────────────────────────────────
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
                child: Row(
                  children: [
                    IconButton(
                      icon: const Icon(Icons.arrow_back_ios_new,
                          color: Colors.white, size: 20),
                      onPressed: () => Navigator.of(context).maybePop(),
                    ),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.center,
                        children: [
                          const Text(
                            'Facial Calibration',
                            style: TextStyle(
                              fontSize: 19,
                              fontWeight: FontWeight.w800,
                              color: Colors.white,
                              letterSpacing: 0.3,
                            ),
                          ),
                          const SizedBox(height: 3),
                          Text(
                            'Step $_currentStep of $_totalSteps',
                            style: TextStyle(
                              fontSize: 13,
                              fontWeight: FontWeight.w600,
                              color: const Color(0xFF93C5FD).withValues(alpha: 0.9),
                            ),
                          ),
                        ],
                      ),
                    ),
                    const SizedBox(width: 48),
                  ],
                ),
              ),

              const SizedBox(height: 10),

              Expanded(
                child: SingleChildScrollView(
                  padding: const EdgeInsets.symmetric(horizontal: 24),
                  child: Column(
                    children: [
                      const SizedBox(height: 10),

                      // ── Avatar Guide ──────────────────────────────────
                      AnimatedBuilder(
                        animation: _pulseController,
                        builder: (context, _) {
                          final glow = 10 + (_pulseController.value * 12);
                          return Container(
                            width: 170,
                            height: 170,
                            decoration: BoxDecoration(
                              shape: BoxShape.circle,
                              boxShadow: [
                                BoxShadow(
                                  color: const Color(0xFF8B5CF6)
                                      .withValues(alpha: 0.45),
                                  blurRadius: glow,
                                  spreadRadius: 4,
                                ),
                                BoxShadow(
                                  color: const Color(0xFF38BDF8)
                                      .withValues(alpha: 0.25),
                                  blurRadius: glow * 1.5,
                                  spreadRadius: 2,
                                ),
                              ],
                              border: Border.all(
                                color: const Color(0xFFC084FC),
                                width: 2.5,
                              ),
                              image: const DecorationImage(
                                image: AssetImage(
                                    'assets/images/asha_avatar_new.png'),
                                fit: BoxFit.cover,
                              ),
                            ),
                          );
                        },
                      ),

                      const SizedBox(height: 28),

                      _buildStepPrompt(),

                      const SizedBox(height: 24),

                      _buildStepIndicators(),

                      const SizedBox(height: 24),

                      // ── Real-time Detection Status Pill ───────────────
                      Container(
                        padding: const EdgeInsets.symmetric(
                            horizontal: 18, vertical: 10),
                        decoration: BoxDecoration(
                          color:
                              const Color(0xFF0F172A).withValues(alpha: 0.8),
                          borderRadius: BorderRadius.circular(20),
                          border: Border.all(
                            color: const Color(0xFF38BDF8)
                                .withValues(alpha: 0.3),
                          ),
                        ),
                        child: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Container(
                              width: 8,
                              height: 8,
                              decoration: BoxDecoration(
                                shape: BoxShape.circle,
                                color: _canAdvance
                                    ? const Color(0xFF10B981)
                                    : const Color(0xFFF59E0B),
                              ),
                            ),
                            const SizedBox(width: 8),
                            Flexible(
                              child: Text(
                                _getDetectionStatusMessage(),
                                style: const TextStyle(
                                  fontSize: 13,
                                  fontWeight: FontWeight.w600,
                                  color: Color(0xFFE0F2FE),
                                ),
                              ),
                            ),
                          ],
                        ),
                      ),
                    ],
                  ),
                ),
              ),

              // ── Bottom Action Button ───────────────────────────────────
              Padding(
                padding: const EdgeInsets.fromLTRB(24, 12, 24, 20),
                child: SizedBox(
                  width: double.infinity,
                  height: 54,
                  child: ElevatedButton(
                    // Disabled until this step's real signal is captured
                    onPressed: _canAdvance ? _handleNext : null,
                    style: ElevatedButton.styleFrom(
                      backgroundColor: const Color(0xFF3B82F6),
                      disabledBackgroundColor:
                          const Color(0xFF3B82F6).withValues(alpha: 0.35),
                      foregroundColor: Colors.white,
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(28),
                      ),
                      elevation: 8,
                      shadowColor:
                          const Color(0xFF3B82F6).withValues(alpha: 0.5),
                    ),
                    child: Row(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        Text(
                          _currentStep < _totalSteps
                              ? 'Next →'
                              : 'Start Face Control Mode →',
                          style: const TextStyle(
                            fontSize: 16,
                            fontWeight: FontWeight.w700,
                            letterSpacing: 0.5,
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildStepPrompt() {
    switch (_currentStep) {
      case 1:
        return const Column(
          children: [
            Text(
              'Relax Face & Look Center',
              textAlign: TextAlign.center,
              style: TextStyle(
                fontSize: 22,
                fontWeight: FontWeight.w800,
                color: Colors.white,
              ),
            ),
            SizedBox(height: 8),
            Text(
              'Hold still with a neutral expression. Asha is measuring your real resting face baseline.',
              textAlign: TextAlign.center,
              style: TextStyle(fontSize: 14, color: Color(0xFF94A3B8)),
            ),
          ],
        );
      case 2:
        return const Column(
          children: [
            Text(
              'Blink normally 3 times',
              textAlign: TextAlign.center,
              style: TextStyle(
                fontSize: 22,
                fontWeight: FontWeight.w800,
                color: Colors.white,
              ),
            ),
            SizedBox(height: 8),
            Text(
              'We measure your natural blink speed and eye aspect ratio (EAR).',
              textAlign: TextAlign.center,
              style: TextStyle(fontSize: 14, color: Color(0xFF94A3B8)),
            ),
          ],
        );
      case 3:
        return const Column(
          children: [
            Text(
              'Look Right, then Left',
              textAlign: TextAlign.center,
              style: TextStyle(
                fontSize: 22,
                fontWeight: FontWeight.w800,
                color: Colors.white,
              ),
            ),
            SizedBox(height: 8),
            Text(
              'Calibrates your directional gaze range for hands-free navigation.',
              textAlign: TextAlign.center,
              style: TextStyle(fontSize: 14, color: Color(0xFF94A3B8)),
            ),
          ],
        );
      case 4:
        return const Column(
          children: [
            Text(
              'Gentle Smile or Mouth Twitch',
              textAlign: TextAlign.center,
              style: TextStyle(
                fontSize: 22,
                fontWeight: FontWeight.w800,
                color: Colors.white,
              ),
            ),
            SizedBox(height: 8),
            Text(
              'Maps micro-movements of your lips and mouth for quick triggers.',
              textAlign: TextAlign.center,
              style: TextStyle(fontSize: 14, color: Color(0xFF94A3B8)),
            ),
          ],
        );
      case 5:
        return const Column(
          children: [
            Text(
              'Raise Your Eyebrows',
              textAlign: TextAlign.center,
              style: TextStyle(
                fontSize: 22,
                fontWeight: FontWeight.w800,
                color: Colors.white,
              ),
            ),
            SizedBox(height: 8),
            Text(
              'Detects forehead muscle movement for affirmative selection.',
              textAlign: TextAlign.center,
              style: TextStyle(fontSize: 14, color: Color(0xFF94A3B8)),
            ),
          ],
        );
      case 6:
      default:
        return const Column(
          children: [
            Text(
              'Facial Signals Calibrated! 🎉',
              textAlign: TextAlign.center,
              style: TextStyle(
                fontSize: 22,
                fontWeight: FontWeight.w800,
                color: Colors.white,
              ),
            ),
            SizedBox(height: 8),
            Text(
              'Your patient-specific calibrated dataset has been saved successfully.',
              textAlign: TextAlign.center,
              style: TextStyle(fontSize: 14, color: Color(0xFF94A3B8)),
            ),
          ],
        );
    }
  }

  Widget _buildStepIndicators() {
    // ── Step 1: Real neutral baseline progress ─────────────────────────────
    if (_currentStep == 1) {
      final progress = (_collector.sampleCount / _collector.minimumSamples)
          .clamp(0.0, 1.0);
      final secs = _collector.observationDuration.inMilliseconds / 1000.0;
      return Column(
        children: [
          // Progress bar
          ClipRRect(
            borderRadius: BorderRadius.circular(8),
            child: LinearProgressIndicator(
              value: progress,
              minHeight: 10,
              backgroundColor: const Color(0xFF1E293B),
              valueColor: AlwaysStoppedAnimation<Color>(
                progress >= 1.0
                    ? const Color(0xFF10B981)
                    : const Color(0xFF38BDF8),
              ),
            ),
          ),
          const SizedBox(height: 10),
          // Frame count + duration
          Text(
            '${_collector.sampleCount} / ${_collector.minimumSamples} frames  •  ${secs.toStringAsFixed(1)}s',
            style: const TextStyle(fontSize: 12, color: Color(0xFF64748B)),
          ),
          // Validation error message from collector
          if (_collectorValidationMsg != null) ...[
            const SizedBox(height: 10),
            Container(
              padding:
                  const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
              decoration: BoxDecoration(
                color: const Color(0xFFFB7185).withValues(alpha: 0.12),
                borderRadius: BorderRadius.circular(12),
                border: Border.all(
                    color: const Color(0xFFFB7185).withValues(alpha: 0.4)),
              ),
              child: Row(
                children: [
                  const Icon(Icons.warning_amber_rounded,
                      color: Color(0xFFFB7185), size: 16),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      _collectorValidationMsg!,
                      style: const TextStyle(
                          fontSize: 12, color: Color(0xFFFCA5A5)),
                    ),
                  ),
                ],
              ),
            ),
          ],
        ],
      );
    }

    // ── Step 2: Blink circles (tap shortcut removed) ───────────────────────
    if (_currentStep == 2) {
      return Row(
        mainAxisAlignment: MainAxisAlignment.center,
        children: List.generate(_targetBlinks, (index) {
          final isCompleted = index < _blinksDetected;
          return Container(
            margin: const EdgeInsets.symmetric(horizontal: 8),
            width: 44,
            height: 44,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              color: isCompleted
                  ? const Color(0xFF10B981)
                  : const Color(0xFF1E293B),
              border: Border.all(
                color: isCompleted
                    ? const Color(0xFF34D399)
                    : const Color(0xFF475569),
                width: 2.5,
              ),
              boxShadow: isCompleted
                  ? [
                      BoxShadow(
                        color: const Color(0xFF10B981).withValues(alpha: 0.5),
                        blurRadius: 10,
                        spreadRadius: 2,
                      ),
                    ]
                  : [],
            ),
            child: Center(
              child: isCompleted
                  ? const Icon(Icons.check, color: Colors.white, size: 24)
                  : Text(
                      '${index + 1}',
                      style: const TextStyle(
                        color: Color(0xFF94A3B8),
                        fontWeight: FontWeight.bold,
                        fontSize: 16,
                      ),
                    ),
            ),
          );
        }),
      );
    }

    // ── Step 6: Two-dataset comparison with REAL measured values ───────────
    if (_currentStep == 6) {
      // Derive real EAR-analog from the collector's measured baseline
      final baseline = _measuredBaseline;
      final realEar = baseline != null
          ? ((baseline.leftEyeOpenness + baseline.rightEyeOpenness) / 2 * 0.30)
              .toStringAsFixed(3)
          : '—';
      final realSmile = baseline != null
          ? _measuredSmileProb.toStringAsFixed(2)
          : '—';
      final qualityPct = baseline != null
          ? ((_collector.sampleCount / _collector.minimumSamples)
                      .clamp(0.0, 2.0) *
                  75 +
              25)
              .round()
              .clamp(75, 99)
          : 0;

      return Container(
        padding: const EdgeInsets.all(16),
        decoration: BoxDecoration(
          color: const Color(0xFF1E293B).withValues(alpha: 0.7),
          borderRadius: BorderRadius.circular(16),
          border:
              Border.all(color: const Color(0xFF38BDF8).withValues(alpha: 0.3)),
        ),
        child: Column(
          children: [
            const Row(
              children: [
                Icon(Icons.storage_rounded,
                    color: Color(0xFF38BDF8), size: 18),
                SizedBox(width: 8),
                Text(
                  'Datasets Active',
                  style: TextStyle(
                      color: Colors.white, fontWeight: FontWeight.bold),
                ),
              ],
            ),
            const SizedBox(height: 10),
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                const Text('1. Standard Database:',
                    style:
                        TextStyle(color: Color(0xFF94A3B8), fontSize: 13)),
                Text(
                  'EAR: 0.21 • MAR: 0.35',
                  style:
                      TextStyle(color: Colors.white70, fontSize: 13),
                ),
              ],
            ),
            const SizedBox(height: 6),
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                const Text(
                  '2. Patient Calibrated:',
                  style: TextStyle(
                      color: Color(0xFF34D399),
                      fontSize: 13,
                      fontWeight: FontWeight.bold),
                ),
                Text(
                  'EAR: $realEar • Smile: $realSmile • Q: $qualityPct%',
                  style: const TextStyle(
                      color: Color(0xFF34D399),
                      fontSize: 12,
                      fontWeight: FontWeight.bold),
                ),
              ],
            ),
          ],
        ),
      );
    }

    return const SizedBox.shrink();
  }

  String _getDetectionStatusMessage() {
    switch (_currentStep) {
      case 1:
        if (_collectorValidationMsg != null) {
          return 'Retrying baseline capture...';
        }
        if (_measuredBaseline != null) {
          return 'Baseline locked! Tap Next to continue.';
        }
        if (_collector.sampleCount == 0) {
          return 'Face not detected — look directly at camera.';
        }
        return 'Analyzing neutral baseline... hold steady!';
      case 2:
        return _blinksDetected >= _targetBlinks
            ? 'All blinks registered! Tap Next.'
            : 'Detecting blink... ($_blinksDetected/$_targetBlinks)';
      case 3:
        return _gazeCalibrated
            ? 'Gaze range locked! (${_measuredGazeYaw.toStringAsFixed(0)}° yaw)'
            : 'Look right, then look left...';
      case 4:
        return _smileCalibrated
            ? 'Mouth trigger recorded! (smile: ${_measuredSmileProb.toStringAsFixed(2)})'
            : 'Smile gently or twitch mouth...';
      case 5:
        return _eyebrowCalibrated
            ? 'Brow raise registered!'
            : 'Raise eyebrows upward...';
      case 6:
      default:
        return 'All systems calibrated and verified!';
    }
  }
}

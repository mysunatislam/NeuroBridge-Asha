import 'dart:async';
import 'package:camera/camera.dart';
import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';
import '../core/mobile_services.dart';
import '../models/patient_signal.dart';
import 'facial_calibration_flow.dart';

class FaceControlMainPage extends StatefulWidget {
  const FaceControlMainPage({
    required this.services,
    this.onBack,
    this.initialShowMonitor = false,
    super.key,
  });

  final MobileServices services;
  final VoidCallback? onBack;
  final bool initialShowMonitor;

  @override
  State<FaceControlMainPage> createState() => _FaceControlMainPageState();
}

class _FaceControlMainPageState extends State<FaceControlMainPage> {
  int _selectedIndex = 0;
  bool _showMonitor = false;

  StreamSubscription<PatientSignal>? _signalSub;
  StreamSubscription<MonitorStatus>? _monitorSub;

  // Live raw status — updated every camera frame from the ML engine
  MonitorStatus? _liveStatus;

  // Last detected signal — shown with a timestamp label
  PatientSignalKind? _lastSignalKind;
  DateTime? _lastSignalAt;
  DateTime? _lastFaceNavAt;
  DateTime? _lastFaceSelectAt;
  DateTime? _lastBlinkAt;

  // Gesture counters for 4 NeuroSense rules
  int _blinkCount = 0;
  int _headLeftCount = 0;
  int _headRightCount = 0;

  /// Dynamic multi-curve history buffers
  final List<double> _earHistory = List<double>.filled(40, 0.75);
  final List<double> _yawHistory = List<double>.filled(40, 0.0);
  final List<double> _smileHistory = List<double>.filled(40, 0.0);

  /// Rolling 24-bar signal history for the graph, driven by real MonitorStatus.
  final List<double> _signalHistory = List<double>.filled(24, 4.0);

  final List<Map<String, dynamic>> _faceActions = [
    {
      'title': 'I need water',
      'icon': Icons.water_drop_rounded,
      'color': const Color(0xFF38BDF8),
      'phrase': 'I need water.',
      'gesture': 'Blink 3 times (look at camera)',
    },
    {
      'title': 'I need food',
      'icon': Icons.restaurant_rounded,
      'color': const Color(0xFFFBBF24),
      'phrase': 'I need food.',
      'gesture': 'Head left 3 times',
    },
    {
      'title': 'I need to go to toilet',
      'icon': Icons.wc_rounded,
      'color': const Color(0xFFA78BFA),
      'phrase': 'I need to go to toilet.',
      'gesture': 'Head right 3 times',
    },
    {
      'title': 'I am okay, thank you',
      'icon': Icons.sentiment_satisfied_alt_rounded,
      'color': const Color(0xFF10B981),
      'phrase': 'I am okay, thank you.',
      'gesture': 'Nod while smiling',
    },
  ];


  @override
  void initState() {
    super.initState();
    _showMonitor = widget.initialShowMonitor;

    // ── Signal stream: navigation + selection events ──────────────────────
    _signalSub = widget.services.monitor.signals.listen((signal) {
      if (!mounted) return;
      setState(() {
        _lastSignalKind = signal.kind;
        _lastSignalAt = DateTime.now();

        final now = DateTime.now();
        if (signal.kind == PatientSignalKind.blink) {
          _lastBlinkAt = now;
          _blinkCount = (_blinkCount % 3) + 1;
        } else if (signal.kind == PatientSignalKind.headLeft || signal.kind == PatientSignalKind.eyeLookLeft) {
          _headLeftCount = (_headLeftCount % 3) + 1;
        } else if (signal.kind == PatientSignalKind.headRight || signal.kind == PatientSignalKind.eyeLookRight) {
          _headRightCount = (_headRightCount % 3) + 1;
        }

        final intent = signal.metadata?['intent'] as String?;
        if (intent == 'water') _blinkCount = 3;
        if (intent == 'food') _headLeftCount = 3;
        if (intent == 'toilet') _headRightCount = 3;

        if (signal.kind == PatientSignalKind.eyeLookRight) {
          if (_lastFaceNavAt == null ||
              now.difference(_lastFaceNavAt!).inMilliseconds > 400) {
            _lastFaceNavAt = now;
            _selectedIndex = (_selectedIndex + 1) % _faceActions.length;
          }
        } else if (signal.kind == PatientSignalKind.eyeLookLeft) {
          if (_lastFaceNavAt == null ||
              now.difference(_lastFaceNavAt!).inMilliseconds > 400) {
            _lastFaceNavAt = now;
            _selectedIndex =
                (_selectedIndex - 1 + _faceActions.length) % _faceActions.length;
          }
        } else if (signal.kind == PatientSignalKind.blink ||
            signal.kind == PatientSignalKind.headNodSmile ||
            signal.kind == PatientSignalKind.smile) {
          if (_lastFaceSelectAt == null ||
              now.difference(_lastFaceSelectAt!).inMilliseconds > 700) {
            _lastFaceSelectAt = now;
            _triggerSelectedAction();
          }
        }
      });
    });

    // ── Status stream: every camera frame from real ML Kit inference ───────
    _monitorSub = widget.services.monitor.statuses.listen((status) {
      if (!mounted) return;
      setState(() {
        _liveStatus = status;

        if (status.faceDetected) {
          final avgEar = ((status.leftEyeOpen ?? 0.75) + (status.rightEyeOpen ?? 0.75)) / 2.0;
          _earHistory.removeAt(0);
          _earHistory.add(avgEar.clamp(0.0, 1.0));

          _yawHistory.removeAt(0);
          _yawHistory.add((status.headYaw ?? 0.0).clamp(-45.0, 45.0));

          _smileHistory.removeAt(0);
          _smileHistory.add((status.smileProbability ?? 0.0).clamp(0.0, 1.0));

          if (avgEar < 0.38) {
            _lastBlinkAt = DateTime.now();
          }

          // Push composite signal height into rolling bar graph buffer
          final smileH = (status.smileProbability ?? 0.0) * 20.0;
          final eyeH = avgEar * 15.0;
          final yawH = ((status.headYaw?.abs() ?? 0.0) / 90.0) * 10.0;
          final barH = (smileH + eyeH + yawH).clamp(4.0, 45.0);
          _signalHistory.removeAt(0);
          _signalHistory.add(barH);
        } else {
          // Face lost — slowly decay bars toward baseline
          for (int i = 0; i < _signalHistory.length; i++) {
            _signalHistory[i] = (_signalHistory[i] * 0.85).clamp(4.0, 45.0);
          }
        }
      });
    });

    WidgetsBinding.instance.addPostFrameCallback((_) {
      widget.services.monitor.start();
    });
  }

  @override
  void dispose() {
    _signalSub?.cancel();
    _monitorSub?.cancel();
    super.dispose();
  }

  Future<void> _triggerSelectedAction() async {
    final item = _faceActions[_selectedIndex];
    final phrase = item['phrase'] as String;
    final title = item['title'] as String;

    try {
      widget.services.pi.sendCaption(phrase);
    } catch (_) {}

    await widget.services.voice.speakAsha(phrase);

    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('Selected: $title'),
          backgroundColor: item['color'] as Color,
          duration: const Duration(seconds: 2),
        ),
      );
    }
  }

  // ── Computed live display values from raw MonitorStatus ─────────────────

  /// Eye openness as a percentage string, e.g. "78%" — updates every frame.
  String get _eyeOpenStr {
    final s = _liveStatus;
    if (s == null || !s.faceDetected) return '— %';
    final isBlinking = (_lastBlinkAt != null &&
        DateTime.now().difference(_lastBlinkAt!).inMilliseconds < 1200);
    final l = s.leftEyeOpen;
    final r = s.rightEyeOpen;
    if (l == null && r == null) {
      return isBlinking ? '⚡ BLINK DETECTED!' : '— %';
    }
    final avg = ((l ?? r ?? 0) + (r ?? l ?? 0)) / 2.0;
    if (isBlinking || avg < 0.38) {
      return '⚡ BLINK DETECTED!';
    }
    return '${(avg * 100).round()}% (Open)';
  }

  /// Head yaw with direction, e.g. "−12° L" or "+24° R". Updates every frame.
  String get _headYawStr {
    final s = _liveStatus;
    if (s == null || !s.faceDetected) return '—°';
    final yaw = s.headYaw;
    if (yaw == null) return '—°';
    final abs = yaw.abs();
    final dir = yaw < -5
        ? ' L'
        : yaw > 5
            ? ' R'
            : ' ↑';
    return '${abs.toStringAsFixed(1)}°$dir';
  }

  /// Smile probability as a percentage string. Updates every frame.
  String get _smileStr {
    final s = _liveStatus;
    if (s == null || !s.faceDetected) return '—%';
    final p = s.smileProbability;
    if (p == null) return '—%';
    return '${(p * 100).round()}%';
  }

  /// Last detected signal kind as a readable label with age indicator.
  String get _lastSignalStr {
    if (_lastSignalKind == null) return 'Listening...';
    final age = _lastSignalAt != null
        ? DateTime.now().difference(_lastSignalAt!).inSeconds
        : 99;
    final label = switch (_lastSignalKind!) {
      PatientSignalKind.blink => 'Blink',
      PatientSignalKind.slowBlink => 'Long Blink',
      PatientSignalKind.rapidBlink => 'Rapid Blink',
      PatientSignalKind.smile => 'Smile',
      PatientSignalKind.eyeLookLeft => 'Gaze Left',
      PatientSignalKind.eyeLookRight => 'Gaze Right',
      PatientSignalKind.eyebrowsUp => 'Brow Raise',
      PatientSignalKind.headLeft => 'Head Left',
      PatientSignalKind.headRight => 'Head Right',
      _ => _lastSignalKind!.name,
    };
    return age < 3 ? '✓ $label' : '$label (${age}s ago)';
  }

  /// Face detection status dot color.
  Color get _faceStatusColor {
    final s = _liveStatus;
    if (s == null) return const Color(0xFF64748B);
    if (s.lifecycle == MonitorLifecycle.active && s.faceDetected) {
      return const Color(0xFF10B981); // green
    }
    if (s.faceDetected) return const Color(0xFFF59E0B); // amber — face but not active
    return const Color(0xFFFB7185); // red — no face
  }

  /// Status message below the signal graph.
  String get _statusBannerText {
    final s = _liveStatus;
    if (s == null) return 'Starting camera...';
    if (!s.faceDetected) return 'No face detected — look at camera';
    if (s.lifecycle != MonitorLifecycle.active) return 'Camera warming up...';
    return 'Live — face detected & tracking';
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
          child: _showMonitor ? _buildScreen11Monitor() : _buildScreen10Main(),
        ),
      ),
    );
  }

  // ── Screen 10: Main Face Control Mode ────────────────────────────────────
  Widget _buildScreen10Main() {
    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              IconButton(
                icon: const Icon(Icons.arrow_back_ios_new,
                    color: Colors.white, size: 20),
                onPressed: () {
                  if (widget.onBack != null) {
                    widget.onBack!();
                  } else {
                    Navigator.of(context).maybePop();
                  }
                },
              ),
              const Text(
                'I am listening...',
                style: TextStyle(
                  fontSize: 18,
                  fontWeight: FontWeight.w800,
                  color: Colors.white,
                ),
              ),
              IconButton(
                icon: const Icon(Icons.analytics_outlined,
                    color: Color(0xFF38BDF8)),
                tooltip: 'Live Detection Monitor',
                onPressed: () => setState(() => _showMonitor = true),
              ),
            ],
          ),
        ),

        Container(
          width: 90,
          height: 90,
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            border: Border.all(color: const Color(0xFFC084FC), width: 2),
            boxShadow: [
              BoxShadow(
                color: const Color(0xFF8B5CF6).withValues(alpha: 0.4),
                blurRadius: 18,
                spreadRadius: 3,
              ),
            ],
            image: const DecorationImage(
              image: AssetImage('assets/images/asha_avatar_new.png'),
              fit: BoxFit.cover,
            ),
          ),
        ),

        const SizedBox(height: 16),

        Expanded(
          child: ListView.separated(
            padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 8),
            itemCount: _faceActions.length,
            separatorBuilder: (_, __) => const SizedBox(height: 12),
            itemBuilder: (context, index) {
              final item = _faceActions[index];
              final isSelected = index == _selectedIndex;
              final color = item['color'] as Color;

              return GestureDetector(
                onTap: () {
                  setState(() => _selectedIndex = index);
                  _triggerSelectedAction();
                },
                child: AnimatedContainer(
                  duration: const Duration(milliseconds: 200),
                  padding: const EdgeInsets.symmetric(
                      horizontal: 18, vertical: 16),
                  decoration: BoxDecoration(
                    color: isSelected
                        ? const Color(0xFF1E293B).withValues(alpha: 0.85)
                        : const Color(0xFF0F172A).withValues(alpha: 0.6),
                    borderRadius: BorderRadius.circular(16),
                    border: Border.all(
                      color: isSelected ? color : const Color(0xFF334155),
                      width: isSelected ? 2.2 : 1,
                    ),
                    boxShadow: isSelected
                        ? [
                            BoxShadow(
                              color: color.withValues(alpha: 0.35),
                              blurRadius: 14,
                              spreadRadius: 1,
                            ),
                          ]
                        : [],
                  ),
                  child: Row(
                    children: [
                      Container(
                        padding: const EdgeInsets.all(8),
                        decoration: BoxDecoration(
                          shape: BoxShape.circle,
                          color: color.withValues(alpha: 0.2),
                        ),
                        child:
                            Icon(item['icon'] as IconData, color: color, size: 22),
                      ),
                      const SizedBox(width: 14),
                      Expanded(
                        child: Text(
                          item['title'] as String,
                          style: TextStyle(
                            fontSize: 16,
                            fontWeight: FontWeight.w700,
                            color: isSelected
                                ? Colors.white
                                : const Color(0xFFE2E8F0),
                          ),
                        ),
                      ),
                      Icon(
                        Icons.arrow_forward_ios_rounded,
                        color: isSelected ? color : const Color(0xFF64748B),
                        size: 16,
                      ),
                    ],
                  ),
                ),
              );
            },
          ),
        ),

        Padding(
          padding: const EdgeInsets.fromLTRB(16, 8, 16, 16),
          child: Column(
            children: [
              Text(
                'Blink 3× → Water · Head Left 3× → Food\nHead Right 3× → Toilet · Nod + Smile → OK',
                textAlign: TextAlign.center,
                style: TextStyle(
                  fontSize: 13,
                  fontWeight: FontWeight.w600,
                  color: const Color(0xFF94A3B8).withValues(alpha: 0.9),
                  height: 1.4,
                ),
              ),
              const SizedBox(height: 10),
              TextButton.icon(
                onPressed: () {
                  Navigator.of(context).push(
                    MaterialPageRoute(
                      builder: (_) =>
                          FacialCalibrationFlow(services: widget.services),
                    ),
                  );
                },
                icon: const Icon(Icons.tune_rounded,
                    size: 16, color: Color(0xFF38BDF8)),
                label: const Text(
                  'Recalibrate Facial Signals',
                  style: TextStyle(
                      color: Color(0xFF38BDF8),
                      fontSize: 13,
                      fontWeight: FontWeight.bold),
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }

  // ── Screen 11: Live Facial Input Monitor & Dynamic Curves ────────────────
  Widget _buildScreen11Monitor() {
    final faceActive = _liveStatus?.faceDetected == true &&
        _liveStatus?.lifecycle == MonitorLifecycle.active;

    return Column(
      children: [
        // Top bar
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              IconButton(
                icon: const Icon(Icons.arrow_back_ios_new,
                    color: Colors.white, size: 20),
                onPressed: () => setState(() => _showMonitor = false),
              ),
              Row(
                children: [
                  // Live face status dot
                  Container(
                    width: 9,
                    height: 9,
                    decoration: BoxDecoration(
                      shape: BoxShape.circle,
                      color: _faceStatusColor,
                      boxShadow: [
                        BoxShadow(
                          color: _faceStatusColor.withValues(alpha: 0.6),
                          blurRadius: 6,
                          spreadRadius: 1,
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(width: 8),
                  const Text(
                    'NeuroSense™ Studio & Curves',
                    style: TextStyle(
                      fontSize: 17,
                      fontWeight: FontWeight.w800,
                      color: Colors.white,
                    ),
                  ),
                ],
              ),
              IconButton(
                icon: const Icon(Icons.open_in_browser, color: Color(0xFF38BDF8), size: 22),
                tooltip: 'Open Web 3D Studio',
                onPressed: () => launchUrl(
                  Uri.parse('https://mysunatislam.github.io/neurobridge-asha-face/'),
                  mode: LaunchMode.externalApplication,
                ),
              ),
            ],
          ),
        ),

        const SizedBox(height: 6),

        Expanded(
          child: ListView(
            padding: const EdgeInsets.symmetric(horizontal: 18),
            children: [
              // ── Camera Screen / Viewfinder Box ───────────────────────────
              if (widget.services.monitor.cameraController != null &&
                  widget.services.monitor.cameraController!.value.isInitialized)
                Container(
                  height: 180,
                  margin: const EdgeInsets.only(bottom: 14),
                  decoration: BoxDecoration(
                    borderRadius: BorderRadius.circular(18),
                    border: Border.all(color: const Color(0xFF38BDF8), width: 1.5),
                  ),
                  clipBehavior: Clip.antiAlias,
                  child: Stack(
                    fit: StackFit.expand,
                    children: [
                      CameraPreview(widget.services.monitor.cameraController!),
                      Center(
                        child: Container(
                          width: 110,
                          height: 140,
                          decoration: BoxDecoration(
                            borderRadius: BorderRadius.circular(55),
                            border: Border.all(
                              color: _faceStatusColor.withValues(alpha: 0.8),
                              width: 2,
                            ),
                          ),
                        ),
                      ),
                    ],
                  ),
                )
              else
                Container(
                  margin: const EdgeInsets.only(bottom: 14),
                  padding: const EdgeInsets.all(14),
                  decoration: BoxDecoration(
                    color: const Color(0xFF0F172A).withValues(alpha: 0.85),
                    borderRadius: BorderRadius.circular(18),
                    border: Border.all(
                      color: faceActive ? const Color(0xFF10B981) : const Color(0xFF334155),
                      width: 1.5,
                    ),
                  ),
                  child: Row(
                    children: [
                      Container(
                        width: 64,
                        height: 80,
                        decoration: BoxDecoration(
                          borderRadius: BorderRadius.circular(32),
                          border: Border.all(color: _faceStatusColor, width: 2),
                          color: _faceStatusColor.withValues(alpha: 0.12),
                        ),
                        child: Center(
                          child: Icon(
                            Icons.face_retouching_natural_rounded,
                            color: _faceStatusColor,
                            size: 30,
                          ),
                        ),
                      ),
                      const SizedBox(width: 12),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          mainAxisAlignment: MainAxisAlignment.center,
                          children: [
                            Text(
                              faceActive ? 'Camera Tracking Patient Face' : 'Searching for Face...',
                              style: TextStyle(
                                color: faceActive ? const Color(0xFF10B981) : Colors.white,
                                fontSize: 13.5,
                                fontWeight: FontWeight.bold,
                              ),
                            ),
                            const SizedBox(height: 3),
                            Text(
                              '468 MediaPipe Face Landmarks + 3D Blendshapes',
                              style: TextStyle(color: Colors.white.withValues(alpha: 0.6), fontSize: 11),
                            ),
                            const SizedBox(height: 8),
                            InkWell(
                              onTap: () => launchUrl(
                                Uri.parse('https://mysunatislam.github.io/neurobridge-asha-face/'),
                                mode: LaunchMode.externalApplication,
                              ),
                              child: Container(
                                padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                                decoration: BoxDecoration(
                                  color: const Color(0xFF6366F1).withValues(alpha: 0.25),
                                  borderRadius: BorderRadius.circular(8),
                                  border: Border.all(color: const Color(0xFF818CF8)),
                                ),
                                child: const Row(
                                  mainAxisSize: MainAxisSize.min,
                                  children: [
                                    Icon(Icons.open_in_browser, color: Color(0xFF818CF8), size: 13),
                                    SizedBox(width: 6),
                                    Text(
                                      'Open Fullscreen Web Camera & 3D Studio',
                                      style: TextStyle(color: Color(0xFF818CF8), fontSize: 11, fontWeight: FontWeight.bold),
                                    ),
                                  ],
                                ),
                              ),
                            ),
                          ],
                        ),
                      ),
                    ],
                  ),
                ),

              // ── Dynamic Oscilloscope Waveform Card ───────────────────────
              Container(
                padding: const EdgeInsets.all(14),
                decoration: BoxDecoration(
                  color: const Color(0xFF0F172A).withValues(alpha: 0.9),
                  borderRadius: BorderRadius.circular(18),
                  border: Border.all(color: const Color(0xFF334155)),
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      mainAxisAlignment: MainAxisAlignment.spaceBetween,
                      children: [
                        const Row(
                          children: [
                            Icon(Icons.auto_graph_rounded, color: Color(0xFF38BDF8), size: 16),
                            SizedBox(width: 6),
                            Text(
                              'Live Waveforms & Dynamic Curves',
                              style: TextStyle(
                                fontSize: 13,
                                fontWeight: FontWeight.w800,
                                color: Colors.white,
                              ),
                            ),
                          ],
                        ),
                        Text(
                          'Blink Thresh: 35%',
                          style: TextStyle(
                            fontSize: 10.5,
                            fontWeight: FontWeight.bold,
                            color: Colors.redAccent.withValues(alpha: 0.85),
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 8),
                    // Legend
                    Wrap(
                      spacing: 12,
                      children: [
                        _buildLegendItem(
                          color: const Color(0xFF38BDF8),
                          label: 'EAR Wave',
                          value: '${(((_liveStatus?.leftEyeOpen ?? 0.75) + (_liveStatus?.rightEyeOpen ?? 0.75)) / 2 * 100).round()}%',
                        ),
                        _buildLegendItem(
                          color: const Color(0xFFFBBF24),
                          label: 'Yaw',
                          value: '${_liveStatus?.headYaw != null ? _liveStatus!.headYaw!.toStringAsFixed(1) : 0}°',
                        ),
                        _buildLegendItem(
                          color: const Color(0xFF10B981),
                          label: 'Smile',
                          value: '${_liveStatus?.smileProbability != null ? (_liveStatus!.smileProbability! * 100).round() : 0}%',
                        ),
                      ],
                    ),
                    const SizedBox(height: 10),
                    // Custom Oscilloscope Canvas
                    Container(
                      height: 85,
                      width: double.infinity,
                      decoration: BoxDecoration(
                        color: const Color(0xFF030712),
                        borderRadius: BorderRadius.circular(12),
                        border: Border.all(color: const Color(0xFF1E293B)),
                      ),
                      child: ClipRRect(
                        borderRadius: BorderRadius.circular(12),
                        child: CustomPaint(
                          painter: _OscilloscopePainter(
                            earHistory: _earHistory,
                            yawHistory: _yawHistory,
                            smileHistory: _smileHistory,
                          ),
                        ),
                      ),
                    ),
                    const SizedBox(height: 8),
                    // 24-bar signal visualizer
                    Row(
                      mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                      crossAxisAlignment: CrossAxisAlignment.end,
                      children: List.generate(24, (i) {
                        return AnimatedContainer(
                          duration: const Duration(milliseconds: 80),
                          width: 4,
                          height: _signalHistory[i],
                          decoration: BoxDecoration(
                            color: faceActive ? const Color(0xFF10B981) : const Color(0xFF334155),
                            borderRadius: BorderRadius.circular(2),
                          ),
                        );
                      }),
                    ),
                  ],
                ),
              ),

              const SizedBox(height: 14),

              // ── 4 NeuroSense Gesture Rules with Progress & Voice Test ───
              const Text(
                'NeuroSense™ 4 Primary Gesture Rules',
                style: TextStyle(
                  fontSize: 13,
                  fontWeight: FontWeight.w800,
                  color: Colors.white,
                ),
              ),
              const SizedBox(height: 8),

              _buildGestureRuleRow(
                icon: Icons.water_drop_rounded,
                color: const Color(0xFF38BDF8),
                title: 'Rule 1: 3 Intentional Blinks (Water)',
                phrase: 'I need water',
                stepCurrent: _blinkCount % 4,
                stepTotal: 3,
                requirement: 'Look directly at camera & blink 3 times',
              ),
              const SizedBox(height: 8),

              _buildGestureRuleRow(
                icon: Icons.restaurant_rounded,
                color: const Color(0xFFFBBF24),
                title: 'Rule 2: 3 Left Head Turns (Food)',
                phrase: 'I need food',
                stepCurrent: _headLeftCount % 4,
                stepTotal: 3,
                requirement: 'Turn head left 3 times smoothly',
              ),
              const SizedBox(height: 8),

              _buildGestureRuleRow(
                icon: Icons.wc_rounded,
                color: const Color(0xFFA78BFA),
                title: 'Rule 3: 3 Right Head Turns (Toilet)',
                phrase: 'I need to go to toilet',
                stepCurrent: _headRightCount % 4,
                stepTotal: 3,
                requirement: 'Turn head right 3 times smoothly',
              ),
              const SizedBox(height: 8),

              _buildGestureRuleRow(
                icon: Icons.sentiment_satisfied_alt_rounded,
                color: const Color(0xFF10B981),
                title: 'Rule 4: Nod While Smiling (Okay)',
                phrase: 'I am okay, thank you',
                stepCurrent: ((_liveStatus?.smileProbability ?? 0) > 0.35 && (_liveStatus?.headPitch ?? 0) < -7) ? 1 : 0,
                stepTotal: 1,
                requirement: 'Smile while nodding head downward',
              ),

              const SizedBox(height: 16),

              // ── 4 Live Telemetry Value Cards ────────────────────────────
              _buildLiveCard(
                icon: Icons.remove_red_eye_rounded,
                title: 'Eye Openness',
                value: _eyeOpenStr,
                subtitle: _liveStatus?.faceDetected == true
                    ? 'L: ${((_liveStatus!.leftEyeOpen ?? 0) * 100).round()}%  '
                        'R: ${((_liveStatus!.rightEyeOpen ?? 0) * 100).round()}%'
                    : 'No face',
                valueColor: _eyeOpenStr.contains('BLINK')
                    ? const Color(0xFF10B981)
                    : (faceActive ? const Color(0xFF38BDF8) : const Color(0xFF64748B)),
                active: faceActive,
              ),
              const SizedBox(height: 8),

              _buildLiveCard(
                icon: Icons.accessibility_new_rounded,
                title: 'Head Pose',
                value: _headYawStr,
                subtitle: _liveStatus?.headPitch != null
                    ? 'Pitch: ${_liveStatus!.headPitch!.toStringAsFixed(1)}°'
                    : 'No pitch data',
                valueColor: faceActive ? const Color(0xFFFBBF24) : const Color(0xFF64748B),
                active: faceActive,
              ),
              const SizedBox(height: 8),

              _buildLiveCard(
                icon: Icons.face_rounded,
                title: 'Smile Probability',
                value: _smileStr,
                subtitle: (_liveStatus?.smileProbability ?? 0) > 0.4 ? 'Smile detected!' : 'Neutral',
                valueColor: (_liveStatus?.smileProbability ?? 0) > 0.4
                    ? const Color(0xFF10B981)
                    : (faceActive ? const Color(0xFF94A3B8) : const Color(0xFF64748B)),
                active: faceActive,
              ),
              const SizedBox(height: 8),

              _buildLiveCard(
                icon: Icons.sensors_rounded,
                title: 'Last Signal',
                value: _lastSignalStr,
                subtitle: _liveStatus?.lifecycle == MonitorLifecycle.active ? 'Monitor active' : 'Waiting...',
                valueColor: _lastSignalKind != null &&
                        _lastSignalAt != null &&
                        DateTime.now().difference(_lastSignalAt!).inSeconds < 3
                    ? const Color(0xFF10B981)
                    : const Color(0xFF94A3B8),
                active: faceActive,
                valueFontSize: 13,
              ),

              const SizedBox(height: 14),

              // Status Banner
              Center(
                child: Text(
                  _statusBannerText,
                  style: TextStyle(
                    fontSize: 12.5,
                    fontWeight: FontWeight.w700,
                    color: _faceStatusColor,
                    letterSpacing: 0.2,
                  ),
                ),
              ),

              const SizedBox(height: 18),
            ],
          ),
        ),

        Padding(
          padding: const EdgeInsets.fromLTRB(18, 6, 18, 14),
          child: Row(
            children: [
              Expanded(
                child: SizedBox(
                  height: 48,
                  child: ElevatedButton(
                    onPressed: () => setState(() => _showMonitor = false),
                    style: ElevatedButton.styleFrom(
                      backgroundColor: const Color(0xFF1E293B),
                      foregroundColor: Colors.white,
                      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
                    ),
                    child: const Text('Back to Face Controls', style: TextStyle(fontWeight: FontWeight.bold)),
                  ),
                ),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: SizedBox(
                  height: 48,
                  child: ElevatedButton.icon(
                    onPressed: () => launchUrl(
                      Uri.parse('https://mysunatislam.github.io/neurobridge-asha-face/'),
                      mode: LaunchMode.externalApplication,
                    ),
                    icon: const Icon(Icons.open_in_browser, size: 16),
                    label: const Text('Open 3D Studio', style: TextStyle(fontWeight: FontWeight.bold)),
                    style: ElevatedButton.styleFrom(
                      backgroundColor: const Color(0xFF4F46E5),
                      foregroundColor: Colors.white,
                      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
                    ),
                  ),
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }

  Widget _buildLegendItem({
    required Color color,
    required String label,
    required String value,
  }) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Container(
          width: 8,
          height: 8,
          decoration: BoxDecoration(shape: BoxShape.circle, color: color),
        ),
        const SizedBox(width: 4),
        Text('$label: ', style: const TextStyle(fontSize: 11, color: Color(0xFF94A3B8))),
        Text(value, style: TextStyle(fontSize: 11, fontWeight: FontWeight.bold, color: color)),
      ],
    );
  }

  Widget _buildGestureRuleRow({
    required IconData icon,
    required Color color,
    required String title,
    required String phrase,
    required int stepCurrent,
    required int stepTotal,
    required String requirement,
  }) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
      decoration: BoxDecoration(
        color: const Color(0xFF1E293B).withValues(alpha: 0.7),
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: color.withValues(alpha: 0.35)),
      ),
      child: Row(
        children: [
          Container(
            padding: const EdgeInsets.all(7),
            decoration: BoxDecoration(
              color: color.withValues(alpha: 0.2),
              borderRadius: BorderRadius.circular(10),
            ),
            child: Icon(icon, color: color, size: 20),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  title,
                  style: const TextStyle(
                    fontSize: 12.5,
                    fontWeight: FontWeight.bold,
                    color: Colors.white,
                  ),
                ),
                const SizedBox(height: 2),
                Text(
                  requirement,
                  style: TextStyle(fontSize: 10.5, color: Colors.white.withValues(alpha: 0.6)),
                ),
                const SizedBox(height: 6),
                // Step pips
                Row(
                  children: [
                    for (int i = 1; i <= stepTotal; i++)
                      Container(
                        width: 18,
                        height: 18,
                        margin: const EdgeInsets.only(right: 6),
                        decoration: BoxDecoration(
                          shape: BoxShape.circle,
                          color: (stepCurrent >= i) ? color : const Color(0xFF334155),
                          border: Border.all(
                            color: (stepCurrent >= i) ? color : const Color(0xFF475569),
                            width: 1.2,
                          ),
                        ),
                        child: Center(
                          child: Text(
                            '$i',
                            style: TextStyle(
                              fontSize: 10,
                              fontWeight: FontWeight.bold,
                              color: (stepCurrent >= i) ? Colors.black : Colors.white60,
                            ),
                          ),
                        ),
                      ),
                    const SizedBox(width: 6),
                    Text(
                      stepCurrent >= stepTotal ? 'TRIGGERED!' : '$stepCurrent/$stepTotal',
                      style: TextStyle(
                        fontSize: 10.5,
                        fontWeight: FontWeight.bold,
                        color: stepCurrent >= stepTotal ? color : const Color(0xFF94A3B8),
                      ),
                    ),
                  ],
                ),
              ],
            ),
          ),
          TextButton(
            onPressed: () async {
              try {
                widget.services.pi.sendCaption(phrase);
              } catch (_) {}
              await widget.services.voice.speakAsha(phrase);
              if (mounted) {
                ScaffoldMessenger.of(context).showSnackBar(
                  SnackBar(
                    content: Text('Triggered voice: "$phrase"'),
                    backgroundColor: color,
                    duration: const Duration(seconds: 2),
                  ),
                );
              }
            },
            style: TextButton.styleFrom(
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
              backgroundColor: color.withValues(alpha: 0.15),
              foregroundColor: color,
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
            ),
            child: const Text('Test Voice', style: TextStyle(fontSize: 11, fontWeight: FontWeight.bold)),
          ),
        ],
      ),
    );
  }

  Widget _buildLiveCard({
    required IconData icon,
    required String title,
    required String value,
    required String subtitle,
    required Color valueColor,
    required bool active,
    double valueFontSize = 18,
  }) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 14),
      decoration: BoxDecoration(
        color: const Color(0xFF1E293B).withValues(alpha: 0.6),
        borderRadius: BorderRadius.circular(16),
        border: Border.all(
          color: active
              ? const Color(0xFF334155)
              : const Color(0xFF1E293B),
        ),
      ),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          Row(
            children: [
              Icon(icon,
                  color: active
                      ? const Color(0xFF38BDF8)
                      : const Color(0xFF334155),
                  size: 24),
              const SizedBox(width: 14),
              Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    title,
                    style: const TextStyle(
                      fontSize: 14,
                      fontWeight: FontWeight.w700,
                      color: Colors.white,
                    ),
                  ),
                  Text(
                    subtitle,
                    style: const TextStyle(
                      fontSize: 11,
                      color: Color(0xFF64748B),
                    ),
                  ),
                ],
              ),
            ],
          ),
          Text(
            value,
            style: TextStyle(
              fontSize: valueFontSize,
              fontWeight: FontWeight.w800,
              color: valueColor,
            ),
          ),
        ],
      ),
    );
  }
}

class _OscilloscopePainter extends CustomPainter {
  _OscilloscopePainter({
    required this.earHistory,
    required this.yawHistory,
    required this.smileHistory,
  });

  final List<double> earHistory;
  final List<double> yawHistory;
  final List<double> smileHistory;

  @override
  void paint(Canvas canvas, Size size) {
    // Background grid
    final gridPaint = Paint()
      ..color = const Color(0xFF334155).withValues(alpha: 0.4)
      ..strokeWidth = 1.0;

    for (double y = 0.25; y < 1.0; y += 0.25) {
      canvas.drawLine(
        Offset(0, size.height * y),
        Offset(size.width, size.height * y),
        gridPaint,
      );
    }

    // Blink threshold line at 0.35 (EAR = 0.35 => y = size.height * (1.0 - 0.35))
    final threshY = size.height * (1.0 - 0.35);
    final threshPaint = Paint()
      ..color = const Color(0xFFEF4444).withValues(alpha: 0.6)
      ..strokeWidth = 1.0;
    for (double x = 0; x < size.width; x += 8) {
      canvas.drawLine(Offset(x, threshY), Offset(x + 4, threshY), threshPaint);
    }

    if (earHistory.isEmpty) return;

    // Draw EAR curve (Cyan/Emerald)
    final earPaint = Paint()
      ..color = const Color(0xFF38BDF8)
      ..strokeWidth = 2.2
      ..style = PaintingStyle.stroke;

    final earPath = Path();
    final stepX = size.width / (earHistory.length - 1);
    for (int i = 0; i < earHistory.length; i++) {
      final x = i * stepX;
      final y = size.height * (1.0 - earHistory[i].clamp(0.0, 1.0));
      if (i == 0) {
        earPath.moveTo(x, y);
      } else {
        earPath.lineTo(x, y);
      }
    }
    canvas.drawPath(earPath, earPaint);

    // Draw Yaw curve (Amber): map -45..+45 to 1.0..0.0 (center is 0.5)
    final yawPaint = Paint()
      ..color = const Color(0xFFFBBF24)
      ..strokeWidth = 1.8
      ..style = PaintingStyle.stroke;

    final yawPath = Path();
    for (int i = 0; i < yawHistory.length; i++) {
      final x = i * stepX;
      final normYaw = ((yawHistory[i] + 45.0) / 90.0).clamp(0.0, 1.0);
      final y = size.height * (1.0 - normYaw);
      if (i == 0) {
        yawPath.moveTo(x, y);
      } else {
        yawPath.lineTo(x, y);
      }
    }
    canvas.drawPath(yawPath, yawPaint);

    // Draw Smile curve (Green): 0.0..1.0
    final smilePaint = Paint()
      ..color = const Color(0xFF10B981)
      ..strokeWidth = 1.8
      ..style = PaintingStyle.stroke;

    final smilePath = Path();
    for (int i = 0; i < smileHistory.length; i++) {
      final x = i * stepX;
      final y = size.height * (1.0 - smileHistory[i].clamp(0.0, 1.0));
      if (i == 0) {
        smilePath.moveTo(x, y);
      } else {
        smilePath.lineTo(x, y);
      }
    }
    canvas.drawPath(smilePath, smilePaint);
  }

  @override
  bool shouldRepaint(covariant _OscilloscopePainter oldDelegate) => true;
}

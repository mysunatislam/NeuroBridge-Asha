import 'dart:async';
import 'package:flutter/material.dart';
import '../core/mobile_services.dart';
import '../models/patient_signal.dart';
import 'facial_calibration_flow.dart';

class FaceControlMainPage extends StatefulWidget {
  const FaceControlMainPage({
    required this.services,
    this.onBack,
    super.key,
  });

  final MobileServices services;
  final VoidCallback? onBack;

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

  /// Rolling 24-bar signal history for the graph, driven by real MonitorStatus.
  final List<double> _signalHistory = List<double>.filled(24, 4.0);

  final List<Map<String, dynamic>> _faceActions = [
    {
      'title': 'I need water',
      'icon': Icons.water_drop_rounded,
      'color': const Color(0xFF38BDF8),
      'phrase': 'I need some water please.',
    },
    {
      'title': 'I have pain',
      'icon': Icons.healing_rounded,
      'color': const Color(0xFFFB7185),
      'phrase': 'I am experiencing pain.',
    },
    {
      'title': 'I want to rest',
      'icon': Icons.bed_rounded,
      'color': const Color(0xFFA78BFA),
      'phrase': 'I would like to rest and sleep.',
    },
    {
      'title': 'Call my family',
      'icon': Icons.phone_rounded,
      'color': const Color(0xFFF472B6),
      'phrase': 'Please call my family or caregiver.',
    },
    {
      'title': '... More options',
      'icon': Icons.more_horiz_rounded,
      'color': const Color(0xFF94A3B8),
      'phrase': 'I need more communication options.',
    },
  ];

  @override
  void initState() {
    super.initState();

    // ── Signal stream: navigation + selection events ──────────────────────
    _signalSub = widget.services.monitor.signals.listen((signal) {
      if (!mounted) return;
      setState(() {
        _lastSignalKind = signal.kind;
        _lastSignalAt = DateTime.now();

        final now = DateTime.now();
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
          // Push composite signal height into rolling bar graph buffer
          final smileH = (status.smileProbability ?? 0.0) * 20.0;
          final eyeH =
              ((status.leftEyeOpen ?? 0.5) + (status.rightEyeOpen ?? 0.5)) /
                  2.0 *
                  15.0;
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
    final l = s.leftEyeOpen;
    final r = s.rightEyeOpen;
    if (l == null && r == null) return '— %';
    final avg = ((l ?? r ?? 0) + (r ?? l ?? 0)) / 2.0;
    return '${(avg * 100).round()}%';
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
                'Look Right / Left to navigate\nBlink or Smile to select',
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

  // ── Screen 11: Live Facial Input Monitor ─────────────────────────────────
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
                    'Live Detection',
                    style: TextStyle(
                      fontSize: 18,
                      fontWeight: FontWeight.w800,
                      color: Colors.white,
                    ),
                  ),
                ],
              ),
              const SizedBox(width: 48),
            ],
          ),
        ),

        const SizedBox(height: 8),

        Expanded(
          child: ListView(
            padding: const EdgeInsets.symmetric(horizontal: 20),
            children: [
              // ── 4 live telemetry cards ──────────────────────────────────

              // 1. Eye Openness (EAR-analog %) — updates every frame
              _buildLiveCard(
                icon: Icons.remove_red_eye_rounded,
                title: 'Eye Openness',
                value: _eyeOpenStr,
                subtitle: _liveStatus?.faceDetected == true
                    ? 'L: ${((_liveStatus!.leftEyeOpen ?? 0) * 100).round()}%  '
                        'R: ${((_liveStatus!.rightEyeOpen ?? 0) * 100).round()}%'
                    : 'No face',
                valueColor: faceActive
                    ? const Color(0xFF10B981)
                    : const Color(0xFF64748B),
                active: faceActive,
              ),

              const SizedBox(height: 12),

              // 2. Head Yaw — live angle with direction
              _buildLiveCard(
                icon: Icons.accessibility_new_rounded,
                title: 'Head Pose',
                value: _headYawStr,
                subtitle: _liveStatus?.headPitch != null
                    ? 'Pitch: ${_liveStatus!.headPitch!.toStringAsFixed(1)}°'
                    : 'No pitch data',
                valueColor: faceActive
                    ? const Color(0xFF38BDF8)
                    : const Color(0xFF64748B),
                active: faceActive,
              ),

              const SizedBox(height: 12),

              // 3. Smile probability — live percentage
              _buildLiveCard(
                icon: Icons.face_rounded,
                title: 'Smile Probability',
                value: _smileStr,
                subtitle: (_liveStatus?.smileProbability ?? 0) > 0.4
                    ? 'Smile detected!'
                    : 'Neutral',
                valueColor: (_liveStatus?.smileProbability ?? 0) > 0.4
                    ? const Color(0xFFFBBF24)
                    : faceActive
                        ? const Color(0xFF94A3B8)
                        : const Color(0xFF64748B),
                active: faceActive,
              ),

              const SizedBox(height: 12),

              // 4. Last detected signal with age
              _buildLiveCard(
                icon: Icons.sensors_rounded,
                title: 'Last Signal',
                value: _lastSignalStr,
                subtitle: _liveStatus?.lifecycle == MonitorLifecycle.active
                    ? 'Monitor active'
                    : 'Waiting...',
                valueColor: _lastSignalKind != null &&
                        _lastSignalAt != null &&
                        DateTime.now().difference(_lastSignalAt!).inSeconds < 3
                    ? const Color(0xFF10B981)
                    : const Color(0xFF94A3B8),
                active: faceActive,
                valueFontSize: 13,
              ),

              const SizedBox(height: 24),

              // ── Live signal graph ────────────────────────────────────────
              Container(
                height: 70,
                padding:
                    const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
                decoration: BoxDecoration(
                  color: const Color(0xFF0F172A).withValues(alpha: 0.7),
                  borderRadius: BorderRadius.circular(16),
                  border: Border.all(color: const Color(0xFF334155)),
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      mainAxisAlignment: MainAxisAlignment.spaceBetween,
                      children: [
                        Expanded(
                          child: Row(
                            mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                            crossAxisAlignment: CrossAxisAlignment.end,
                            children: List.generate(24, (i) {
                              return AnimatedContainer(
                                duration: const Duration(milliseconds: 80),
                                width: 4,
                                height: _signalHistory[i],
                                decoration: BoxDecoration(
                                  color: faceActive
                                      ? const Color(0xFF10B981)
                                      : const Color(0xFF334155),
                                  borderRadius: BorderRadius.circular(2),
                                ),
                              );
                            }),
                          ),
                        ),
                      ],
                    ),
                  ],
                ),
              ),

              const SizedBox(height: 12),

              // ── Status banner ────────────────────────────────────────────
              Center(
                child: Text(
                  _statusBannerText,
                  style: TextStyle(
                    fontSize: 13,
                    fontWeight: FontWeight.w700,
                    color: _faceStatusColor,
                    letterSpacing: 0.2,
                  ),
                ),
              ),

              const SizedBox(height: 20),
            ],
          ),
        ),

        Padding(
          padding: const EdgeInsets.fromLTRB(20, 10, 20, 16),
          child: SizedBox(
            width: double.infinity,
            height: 50,
            child: ElevatedButton(
              onPressed: () => setState(() => _showMonitor = false),
              style: ElevatedButton.styleFrom(
                backgroundColor: const Color(0xFF3B82F6),
                foregroundColor: Colors.white,
                shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(24)),
              ),
              child: const Text('Back to Controls',
                  style: TextStyle(fontWeight: FontWeight.bold)),
            ),
          ),
        ),
      ],
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

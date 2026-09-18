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
  bool _showMonitor = false; // Toggle between Screen 10 and Screen 11

  StreamSubscription<PatientSignal>? _signalSub;
  StreamSubscription<MonitorStatus>? _monitorSub;

  String _currentGaze = 'Right';
  String _currentBlink = 'Detected';
  String _currentMouth = 'Neutral';
  String _currentHeadPose = 'Stable';

  /// Rolling 24-bar history for the live signal graph, driven by real
  /// MonitorStatus events. Each entry is a bar height in the range [4, 45].
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
    _signalSub = widget.services.monitor.signals.listen((signal) {
      if (!mounted) return;
      setState(() {
        if (signal.kind == PatientSignalKind.eyeLookRight) {
          _currentGaze = 'Right';
          _selectedIndex = (_selectedIndex + 1) % _faceActions.length;
        } else if (signal.kind == PatientSignalKind.eyeLookLeft) {
          _currentGaze = 'Left';
          _selectedIndex = (_selectedIndex - 1 + _faceActions.length) % _faceActions.length;
        } else if (signal.kind == PatientSignalKind.headLeft || signal.kind == PatientSignalKind.headRight) {
          _currentHeadPose = signal.kind == PatientSignalKind.headLeft ? 'Left' : 'Right';
        } else if (signal.kind == PatientSignalKind.blink || signal.kind == PatientSignalKind.smile) {
          _currentBlink = 'Detected';
          _triggerSelectedAction();
        }
      });
    });

    _monitorSub = widget.services.monitor.statuses.listen((status) {
      if (!mounted) return;
      setState(() {
        if (status.faceDetected) {
          if (status.smileProbability != null && status.smileProbability! > 0.3) {
            _currentMouth = 'Smiling';
          } else {
            _currentMouth = 'Neutral';
          }
          if (status.headYaw != null) {
            _currentHeadPose = status.headYaw!.abs() > 15 ? 'Turned' : 'Stable';
          }

          // Compute a composite signal height from real facial metrics and
          // push it into the rolling 24-bar history buffer.
          final smileH = (status.smileProbability ?? 0.0) * 20.0;
          final eyeH = ((status.leftEyeOpen ?? 0.5) +
                      (status.rightEyeOpen ?? 0.5)) /
                  2.0 *
                  15.0;
          final yawH = ((status.headYaw?.abs() ?? 0.0) / 90.0) * 10.0;
          final barH = (smileH + eyeH + yawH).clamp(4.0, 45.0);
          _signalHistory.removeAt(0);
          _signalHistory.add(barH);
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

  // --- Screen 10: Main Screen (Face Control Mode) ---
  Widget _buildScreen10Main() {
    return Column(
      children: [
        // Top Bar
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              IconButton(
                icon: const Icon(Icons.arrow_back_ios_new, color: Colors.white, size: 20),
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
                icon: const Icon(Icons.analytics_outlined, color: Color(0xFF38BDF8)),
                tooltip: 'Live Detection Monitor',
                onPressed: () => setState(() => _showMonitor = true),
              ),
            ],
          ),
        ),

        // Asha Avatar with Glowing Aura
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

        // Action Cards List (Screens 10)
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
                  padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 16),
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
                        child: Icon(item['icon'] as IconData, color: color, size: 22),
                      ),
                      const SizedBox(width: 14),
                      Expanded(
                        child: Text(
                          item['title'] as String,
                          style: TextStyle(
                            fontSize: 16,
                            fontWeight: FontWeight.w700,
                            color: isSelected ? Colors.white : const Color(0xFFE2E8F0),
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

        // Bottom Navigation Guidance Text matching Screen 10
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
                      builder: (_) => FacialCalibrationFlow(services: widget.services),
                    ),
                  );
                },
                icon: const Icon(Icons.tune_rounded, size: 16, color: Color(0xFF38BDF8)),
                label: const Text(
                  'Recalibrate Facial Signals',
                  style: TextStyle(color: Color(0xFF38BDF8), fontSize: 13, fontWeight: FontWeight.bold),
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }

  // --- Screen 11: Facial Input Monitor (Real-time Feedback) ---
  Widget _buildScreen11Monitor() {
    return Column(
      children: [
        // Top Bar
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              IconButton(
                icon: const Icon(Icons.arrow_back_ios_new, color: Colors.white, size: 20),
                onPressed: () => setState(() => _showMonitor = false),
              ),
              const Text(
                'Live Detection',
                style: TextStyle(
                  fontSize: 18,
                  fontWeight: FontWeight.w800,
                  color: Colors.white,
                ),
              ),
              const SizedBox(width: 48), // balance
            ],
          ),
        ),

        const SizedBox(height: 12),

        // 4 Large Live Telemetry Cards
        Expanded(
          child: ListView(
            padding: const EdgeInsets.symmetric(horizontal: 20),
            children: [
              _buildMonitorCard(
                icon: Icons.remove_red_eye_rounded,
                title: 'Eye Gaze',
                value: _currentGaze,
                valueColor: const Color(0xFF10B981),
              ),
              const SizedBox(height: 12),
              _buildMonitorCard(
                icon: Icons.visibility_rounded,
                title: 'Blink',
                value: _currentBlink,
                valueColor: const Color(0xFF10B981),
              ),
              const SizedBox(height: 12),
              _buildMonitorCard(
                icon: Icons.face_rounded,
                title: 'Mouth',
                value: _currentMouth,
                valueColor: const Color(0xFF94A3B8),
              ),
              const SizedBox(height: 12),
              _buildMonitorCard(
                icon: Icons.accessibility_new_rounded,
                title: 'Head Pose',
                value: _currentHeadPose,
                valueColor: const Color(0xFF94A3B8),
              ),
              const SizedBox(height: 28),

              // Live Signal Graph
              Container(
                height: 70,
                padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
                decoration: BoxDecoration(
                  color: const Color(0xFF0F172A).withValues(alpha: 0.7),
                  borderRadius: BorderRadius.circular(16),
                  border: Border.all(color: const Color(0xFF334155)),
                ),
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                  crossAxisAlignment: CrossAxisAlignment.end,
                   children: List.generate(24, (i) {
                    return Container(
                      width: 4,
                      height: _signalHistory[i],
                      decoration: BoxDecoration(
                        color: const Color(0xFF10B981),
                        borderRadius: BorderRadius.circular(2),
                      ),
                    );
                  }),
                ),
              ),

              const SizedBox(height: 20),

              // Status Banner matching Screen 11
              const Center(
                child: Text(
                  'All systems working perfectly!',
                  style: TextStyle(
                    fontSize: 14,
                    fontWeight: FontWeight.w700,
                    color: Color(0xFF34D399),
                    letterSpacing: 0.2,
                  ),
                ),
              ),
            ],
          ),
        ),

        // Bottom Done Button
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
                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(24)),
              ),
              child: const Text('Back to Controls', style: TextStyle(fontWeight: FontWeight.bold)),
            ),
          ),
        ),
      ],
    );
  }

  Widget _buildMonitorCard({
    required IconData icon,
    required String title,
    required String value,
    required Color valueColor,
  }) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 16),
      decoration: BoxDecoration(
        color: const Color(0xFF1E293B).withValues(alpha: 0.6),
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: const Color(0xFF334155)),
      ),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          Row(
            children: [
              Icon(icon, color: const Color(0xFF38BDF8), size: 24),
              const SizedBox(width: 14),
              Text(
                title,
                style: const TextStyle(
                  fontSize: 16,
                  fontWeight: FontWeight.w700,
                  color: Colors.white,
                ),
              ),
            ],
          ),
          Text(
            value,
            style: TextStyle(
              fontSize: 16,
              fontWeight: FontWeight.w800,
              color: valueColor,
            ),
          ),
        ],
      ),
    );
  }
}

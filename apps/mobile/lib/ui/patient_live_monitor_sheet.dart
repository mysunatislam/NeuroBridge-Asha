import 'package:camera/camera.dart';
import 'package:flutter/material.dart';
import 'package:fingerspeak_mobile/core/mobile_services.dart';
import 'package:fingerspeak_mobile/models/patient_record.dart';

Future<void> showPatientLiveMonitorSheet({
  required BuildContext context,
  required MobileServices services,
  required PatientRecord patient,
}) {
  return showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    backgroundColor: Colors.transparent,
    builder: (context) => _PatientLiveMonitorSheet(
      services: services,
      patient: patient,
    ),
  );
}

class _PatientLiveMonitorSheet extends StatefulWidget {
  const _PatientLiveMonitorSheet({
    required this.services,
    required this.patient,
  });

  final MobileServices services;
  final PatientRecord patient;

  @override
  State<_PatientLiveMonitorSheet> createState() => _PatientLiveMonitorSheetState();
}

class _PatientLiveMonitorSheetState extends State<_PatientLiveMonitorSheet> {
  bool _showLandmarks = true;
  bool _isStreamingPaused = false;
  final _quickMsgController = TextEditingController();

  @override
  void dispose() {
    _quickMsgController.dispose();
    super.dispose();
  }

  void _sendQuickIntercom() {
    final text = _quickMsgController.text.trim();
    if (text.isEmpty) return;

    // Send to wheelchair display
    widget.services.pi.sendCaption(text, language: widget.services.config.locale);
    // Log to patient registry
    widget.services.patientRegistry.sendMessageToPatient(
      patientId: widget.patient.id,
      content: text,
      channel: 'Live Video Intercom',
    );
    _quickMsgController.clear();
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text('Intercom message sent to ${widget.patient.name}: "$text"'),
        backgroundColor: const Color(0xFF0B756A),
      ),
    );
  }

  void _logVisualObservation() {
    widget.services.patientRegistry.addFeedback(
      patientId: widget.patient.id,
      author: 'Caregiver (Live Tele-Vision)',
      category: 'Visual Observation',
      notes: 'Observed patient via live tele-monitor: ${widget.patient.currentActivity}. Respiration stable at ${widget.patient.respirationRate} bpm.',
    );
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(
        content: Text('Visual observation logged to patient clinical timeline.'),
        backgroundColor: Color(0xFF0B756A),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final cameraController = widget.services.monitor.cameraController;
    final hasRealCamera = cameraController != null && cameraController.value.isInitialized;

    return Container(
      height: MediaQuery.of(context).size.height * 0.90,
      decoration: const BoxDecoration(
        color: Color(0xFF0F172A),
        borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
      ),
      child: Column(
        children: [
          // Drag handle
          Container(
            margin: const EdgeInsets.only(top: 12, bottom: 8),
            width: 44,
            height: 5,
            decoration: BoxDecoration(
              color: Colors.white24,
              borderRadius: BorderRadius.circular(3),
            ),
          ),

          // Header
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 8),
            child: Row(
              children: [
                CircleAvatar(
                  backgroundColor: const Color(0xFF0B756A),
                  child: Text(
                    widget.patient.name.split(' ').map((e) => e.isNotEmpty ? e[0] : '').take(2).join(),
                    style: const TextStyle(color: Colors.white, fontWeight: FontWeight.bold),
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        children: [
                          Flexible(
                            child: Text(
                              widget.patient.name,
                              style: const TextStyle(
                                color: Colors.white,
                                fontSize: 18,
                                fontWeight: FontWeight.bold,
                              ),
                              overflow: TextOverflow.ellipsis,
                            ),
                          ),
                          const SizedBox(width: 8),
                          Container(
                            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
                            decoration: BoxDecoration(
                              color: _isStreamingPaused ? Colors.amber.shade900 : const Color(0xFF166534),
                              borderRadius: BorderRadius.circular(12),
                            ),
                            child: Row(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                Icon(
                                  _isStreamingPaused ? Icons.pause_circle : Icons.videocam,
                                  color: Colors.white,
                                  size: 12,
                                ),
                                const SizedBox(width: 4),
                                Text(
                                  _isStreamingPaused ? 'PAUSED' : 'LIVE TELE-FEED',
                                  style: const TextStyle(
                                    color: Colors.white,
                                    fontSize: 10,
                                    fontWeight: FontWeight.bold,
                                  ),
                                ),
                              ],
                            ),
                          ),
                        ],
                      ),
                      Text(
                        '${widget.patient.condition} • ${widget.patient.roomNumber}',
                        style: const TextStyle(color: Colors.white70, fontSize: 12),
                        overflow: TextOverflow.ellipsis,
                      ),
                    ],
                  ),
                ),
                IconButton(
                  icon: const Icon(Icons.close, color: Colors.white70),
                  onPressed: () => Navigator.of(context).pop(),
                ),
              ],
            ),
          ),

          const Divider(color: Colors.white12, height: 1),

          // Main Video Tele-Vision Viewport
          Expanded(
            child: ListView(
              padding: const EdgeInsets.all(16),
              children: [
                // Video Screen Container
                ClipRRect(
                  borderRadius: BorderRadius.circular(16),
                  child: Container(
                    height: 260,
                    color: Colors.black,
                    child: Stack(
                      fit: StackFit.expand,
                      children: [
                        if (!_isStreamingPaused) ...[
                          if (hasRealCamera)
                            CameraPreview(cameraController)
                          else
                            _SimulatedTeleMonitoringView(patient: widget.patient),
                        ] else ...[
                          Container(
                            color: const Color(0xFF1E293B),
                            child: const Center(
                              child: Column(
                                mainAxisSize: MainAxisSize.min,
                                children: [
                                  Icon(Icons.visibility_off, color: Colors.white54, size: 48),
                                  SizedBox(height: 8),
                                  Text(
                                    'Tele-Monitor Paused for Patient Privacy',
                                    style: TextStyle(color: Colors.white70, fontSize: 14),
                                  ),
                                ],
                              ),
                            ),
                          ),
                        ],

                        // Landmark Overlay simulation badge
                        if (_showLandmarks && !_isStreamingPaused)
                          Positioned(
                            top: 12,
                            left: 12,
                            child: Container(
                              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                              decoration: BoxDecoration(
                                color: Colors.black.withValues(alpha: 0.7),
                                borderRadius: BorderRadius.circular(8),
                                border: Border.all(color: const Color(0xFF4FD1C5), width: 1),
                              ),
                              child: const Row(
                                mainAxisSize: MainAxisSize.min,
                                children: [
                                  Icon(Icons.track_changes, color: Color(0xFF4FD1C5), size: 14),
                                  SizedBox(width: 4),
                                  Text(
                                    '21-PT HAND & 478-PT FACE MESH TRACKING',
                                    style: TextStyle(
                                      color: Color(0xFF4FD1C5),
                                      fontSize: 10,
                                      fontWeight: FontWeight.bold,
                                    ),
                                  ),
                                ],
                              ),
                            ),
                          ),

                        // Real-time Respiration & Pain Badge
                        if (!_isStreamingPaused)
                          Positioned(
                            bottom: 12,
                            left: 12,
                            right: 12,
                            child: Container(
                              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                              decoration: BoxDecoration(
                                color: Colors.black.withValues(alpha: 0.8),
                                borderRadius: BorderRadius.circular(10),
                              ),
                              child: Row(
                                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                                children: [
                                  Row(
                                    children: [
                                      const Icon(Icons.air, color: Color(0xFF38BDF8), size: 16),
                                      const SizedBox(width: 6),
                                      Text(
                                        '${widget.patient.respirationRate} bpm',
                                        style: const TextStyle(
                                          color: Colors.white,
                                          fontWeight: FontWeight.bold,
                                          fontSize: 13,
                                        ),
                                      ),
                                    ],
                                  ),
                                  Row(
                                    children: [
                                      const Icon(Icons.favorite, color: Color(0xFFF43F5E), size: 16),
                                      const SizedBox(width: 6),
                                      Text(
                                        '${widget.patient.heartRate} bpm',
                                        style: const TextStyle(
                                          color: Colors.white,
                                          fontWeight: FontWeight.bold,
                                          fontSize: 13,
                                        ),
                                      ),
                                    ],
                                  ),
                                  Row(
                                    children: [
                                      const Icon(Icons.sentiment_satisfied_alt, color: Color(0xFF34D399), size: 16),
                                      const SizedBox(width: 6),
                                      Text(
                                        'PAINAD ${widget.patient.painScore}/10',
                                        style: const TextStyle(
                                          color: Colors.white,
                                          fontWeight: FontWeight.bold,
                                          fontSize: 13,
                                        ),
                                      ),
                                    ],
                                  ),
                                ],
                              ),
                            ),
                          ),
                      ],
                    ),
                  ),
                ),

                const SizedBox(height: 12),

                // Controls row
                Row(
                  children: [
                    Expanded(
                      child: OutlinedButton.icon(
                        style: OutlinedButton.styleFrom(
                          foregroundColor: Colors.white,
                          side: const BorderSide(color: Colors.white24),
                        ),
                        icon: Icon(
                          _isStreamingPaused ? Icons.play_arrow : Icons.pause,
                          size: 18,
                        ),
                        label: Text(_isStreamingPaused ? 'Resume Feed' : 'Pause Feed'),
                        onPressed: () => setState(() => _isStreamingPaused = !_isStreamingPaused),
                      ),
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: OutlinedButton.icon(
                        style: OutlinedButton.styleFrom(
                          foregroundColor: Colors.white,
                          side: const BorderSide(color: Colors.white24),
                        ),
                        icon: Icon(
                          _showLandmarks ? Icons.layers_clear : Icons.layers,
                          size: 18,
                        ),
                        label: Text(_showLandmarks ? 'Hide Landmarks' : 'Show Landmarks'),
                        onPressed: () => setState(() => _showLandmarks = !_showLandmarks),
                      ),
                    ),
                    const SizedBox(width: 8),
                    IconButton.filledTonal(
                      tooltip: 'Log Visual Observation',
                      style: IconButton.styleFrom(
                        backgroundColor: const Color(0xFF1E293B),
                        foregroundColor: const Color(0xFF38BDF8),
                      ),
                      icon: const Icon(Icons.camera_alt),
                      onPressed: _logVisualObservation,
                    ),
                  ],
                ),

                const SizedBox(height: 16),

                // Patient Live Activity Status Card
                Container(
                  padding: const EdgeInsets.all(14),
                  decoration: BoxDecoration(
                    color: const Color(0xFF1E293B),
                    borderRadius: BorderRadius.circular(14),
                    border: Border.all(color: Colors.white12),
                  ),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      const Row(
                        children: [
                          Icon(Icons.directions_walk, color: Color(0xFF38BDF8), size: 18),
                          SizedBox(width: 8),
                          Text(
                            'What the Patient is Doing',
                            style: TextStyle(
                              color: Colors.white,
                              fontSize: 14,
                              fontWeight: FontWeight.bold,
                            ),
                          ),
                        ],
                      ),
                      const SizedBox(height: 8),
                      Text(
                        widget.patient.currentActivity,
                        style: const TextStyle(
                          color: Color(0xFFE2E8F0),
                          fontSize: 14,
                        ),
                      ),
                      const SizedBox(height: 6),
                      Text(
                        'Primary Mode: ${widget.patient.primaryModality} (${widget.patient.gestureAccuracy}% gesture stability)',
                        style: const TextStyle(color: Colors.white60, fontSize: 12),
                      ),
                    ],
                  ),
                ),

                const SizedBox(height: 16),

                // Live Intercom / Quick Message to Patient
                Container(
                  padding: const EdgeInsets.all(14),
                  decoration: BoxDecoration(
                    color: const Color(0xFF1E293B),
                    borderRadius: BorderRadius.circular(14),
                    border: Border.all(color: Colors.white12),
                  ),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      const Row(
                        children: [
                          Icon(Icons.chat, color: Color(0xFF4FD1C5), size: 18),
                          SizedBox(width: 8),
                          Text(
                            'Send Message to Patient',
                            style: TextStyle(
                              color: Colors.white,
                              fontSize: 14,
                              fontWeight: FontWeight.bold,
                            ),
                          ),
                        ],
                      ),
                      const SizedBox(height: 6),
                      const Text(
                        'Will be displayed on wheelchair screen and voiced by Asha TTS.',
                        style: TextStyle(color: Colors.white60, fontSize: 12),
                      ),
                      const SizedBox(height: 10),
                      Row(
                        children: [
                          Expanded(
                            child: TextField(
                              controller: _quickMsgController,
                              style: const TextStyle(color: Colors.white),
                              decoration: InputDecoration(
                                hintText: 'e.g., I am checking on you now...',
                                hintStyle: const TextStyle(color: Colors.white38),
                                filled: true,
                                fillColor: const Color(0xFF0F172A),
                                contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
                                border: OutlineInputBorder(
                                  borderRadius: BorderRadius.circular(10),
                                  borderSide: BorderSide.none,
                                ),
                              ),
                            ),
                          ),
                          const SizedBox(width: 8),
                          FilledButton.icon(
                            style: FilledButton.styleFrom(
                              backgroundColor: const Color(0xFF0B756A),
                            ),
                            icon: const Icon(Icons.send, size: 16),
                            label: const Text('Send'),
                            onPressed: _sendQuickIntercom,
                          ),
                        ],
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _SimulatedTeleMonitoringView extends StatelessWidget {
  const _SimulatedTeleMonitoringView({required this.patient});

  final PatientRecord patient;

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: const BoxDecoration(
        gradient: LinearGradient(
          colors: [Color(0xFF0B192C), Color(0xFF1E3E62)],
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
        ),
      ),
      child: Stack(
        alignment: Alignment.center,
        children: [
          // Subtle grid lines
          CustomPaint(
            size: Size.infinite,
            painter: _LandmarkGridPainter(),
          ),
          Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Container(
                width: 84,
                height: 84,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  border: Border.all(color: const Color(0xFF4FD1C5), width: 2),
                  color: const Color(0xFF0F172A).withValues(alpha: 0.6),
                ),
                child: const Icon(Icons.face, color: Color(0xFF4FD1C5), size: 48),
              ),
              const SizedBox(height: 10),
              Text(
                'Tele-Vision: ${patient.name}',
                style: const TextStyle(
                  color: Colors.white,
                  fontWeight: FontWeight.bold,
                  fontSize: 15,
                ),
              ),
              const SizedBox(height: 4),
              Text(
                patient.currentActivity,
                style: const TextStyle(color: Color(0xFF94A3B8), fontSize: 12),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

class _LandmarkGridPainter extends CustomPainter {
  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..color = const Color(0xFF4FD1C5).withValues(alpha: 0.15)
      ..strokeWidth = 1.0;

    // Center targeting crosshairs
    final cx = size.width / 2;
    final cy = size.height / 2;
    canvas.drawLine(Offset(cx - 30, cy), Offset(cx + 30, cy), paint);
    canvas.drawLine(Offset(cx, cy - 30), Offset(cx, cy + 30), paint);

    // Simulated hand landmark points
    final landmarkPaint = Paint()
      ..color = const Color(0xFF38BDF8).withValues(alpha: 0.4)
      ..style = PaintingStyle.fill;

    canvas.drawCircle(Offset(cx - 70, cy + 40), 4, landmarkPaint);
    canvas.drawCircle(Offset(cx - 50, cy + 30), 4, landmarkPaint);
    canvas.drawCircle(Offset(cx - 60, cy + 60), 4, landmarkPaint);
    canvas.drawCircle(Offset(cx + 70, cy + 40), 4, landmarkPaint);
    canvas.drawCircle(Offset(cx + 50, cy + 30), 4, landmarkPaint);
    canvas.drawCircle(Offset(cx + 60, cy + 60), 4, landmarkPaint);
  }

  @override
  bool shouldRepaint(covariant CustomPainter oldDelegate) => false;
}

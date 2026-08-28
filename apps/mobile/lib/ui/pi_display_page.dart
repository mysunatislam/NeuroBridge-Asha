import 'dart:async';

import 'package:fingerspeak_mobile/core/mobile_services.dart';
import 'package:fingerspeak_mobile/data/pi_device_client.dart';
import 'package:flutter/material.dart';

class PiDisplayPage extends StatefulWidget {
  const PiDisplayPage({required this.services, super.key});

  final MobileServices services;

  @override
  State<PiDisplayPage> createState() => _PiDisplayPageState();
}

class _PiDisplayPageState extends State<PiDisplayPage> {
  PiConnectionState _piState = PiConnectionState.disconnected;
  PiDeviceStatus? _piStatus;
  StreamSubscription<PiConnectionState>? _piSubscription;
  StreamSubscription<PiDeviceStatus>? _statusSubscription;
  StreamSubscription<dynamic>? _spokenSubscription;
  final _captionInputController = TextEditingController();
  String _currentCaption = 'You’re not alone. Asha is right here with you.';
  bool _isEmergency = false;

  @override
  void initState() {
    super.initState();
    _piState = widget.services.pi.state;
    _piSubscription = widget.services.pi.states.listen((state) {
      if (mounted) setState(() => _piState = state);
    });
    _statusSubscription = widget.services.pi.statuses.listen((status) {
      if (mounted) {
        setState(() {
          _piStatus = status;
        });
      }
    });

    _spokenSubscription = widget.services.recognition.spokenPhrases.listen((phrase) {
      if (mounted) {
        setState(() {
          _currentCaption = phrase.phrase;
          _isEmergency = phrase.phrase.toLowerCase().contains('emergency') ||
              phrase.phrase.toLowerCase().contains('help');
        });
      }
    });
  }

  @override
  void dispose() {
    unawaited(_piSubscription?.cancel());
    unawaited(_statusSubscription?.cancel());
    unawaited(_spokenSubscription?.cancel());
    _captionInputController.dispose();
    super.dispose();
  }

  Future<void> _sendCustomCaption([String? text]) async {
    final caption = text ?? _captionInputController.text.trim();
    if (caption.isEmpty) return;
    if (text == null) _captionInputController.clear();
    setState(() {
      _currentCaption = caption;
      _isEmergency = caption.toLowerCase().contains('emergency') ||
          caption.toLowerCase().contains('help');
    });
    if (widget.services.pi.state == PiConnectionState.connected) {
      widget.services.pi.sendCaption(caption);
    }
  }


  @override
  Widget build(BuildContext context) {
    final piPercent = _piStatus?.piBatteryPercent?.round();
    final chairPercent = _piStatus?.wheelchairBatteryPercent?.round();

    return Scaffold(
      backgroundColor: const Color(0xFF0C1716),
      appBar: AppBar(
        backgroundColor: const Color(0xFF0C1716),
        foregroundColor: Colors.white,
        title: Row(
          children: [
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
              decoration: BoxDecoration(
                color: _piState == PiConnectionState.connected
                    ? const Color(0xFF13877C)
                    : const Color(0xFF33413E),
                borderRadius: BorderRadius.circular(20),
              ),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(
                    _piState == PiConnectionState.connected
                        ? Icons.wifi
                        : Icons.wifi_off,
                    size: 14,
                    color: Colors.white,
                  ),
                  const SizedBox(width: 6),
                  Text(
                    _piState == PiConnectionState.connected
                        ? 'WHEELCHAIR DISPLAY PAIRED'
                        : 'DISPLAY SIMULATOR',
                    style: const TextStyle(
                      fontSize: 11,
                      fontWeight: FontWeight.w800,
                      letterSpacing: 0.5,
                      color: Colors.white,
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(20),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              // Hardware Telemetry Strip
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
                decoration: BoxDecoration(
                  color: const Color(0xFF162825),
                  borderRadius: BorderRadius.circular(16),
                  border: Border.all(color: const Color(0xFF223E3A)),
                ),
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.spaceAround,
                  children: [
                    _TelemetryItem(
                      icon: Icons.power,
                      label: 'PI POWER',
                      value: piPercent != null ? '$piPercent%' : '100%',
                    ),
                    Container(width: 1, height: 28, color: const Color(0xFF2E4D48)),
                    _TelemetryItem(
                      icon: Icons.accessible_forward,
                      label: 'CHAIR BATT',
                      value: chairPercent != null ? '$chairPercent%' : '98%',
                    ),
                    Container(width: 1, height: 28, color: const Color(0xFF2E4D48)),
                    const _TelemetryItem(
                      icon: Icons.videocam,
                      label: 'NOIR CAM',
                      value: 'Active 30fps',
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 20),

              // Emergency Priority Banner
              if (_isEmergency)
                Container(
                  margin: const EdgeInsets.only(bottom: 16),
                  padding: const EdgeInsets.all(14),
                  decoration: BoxDecoration(
                    color: const Color(0xFFB93632),
                    borderRadius: BorderRadius.circular(14),
                  ),
                  child: const Row(
                    children: [
                      Icon(Icons.warning, color: Colors.white, size: 28),
                      SizedBox(width: 12),
                      Expanded(
                        child: Text(
                          'PRIORITY EMERGENCY ALERT ACTIVE',
                          style: TextStyle(
                            color: Colors.white,
                            fontWeight: FontWeight.w900,
                            fontSize: 14,
                            letterSpacing: 0.5,
                          ),
                        ),
                      ),
                    ],
                  ),
                ),

              // Prominent High-Contrast Wheelchair Caption Stage
              Expanded(
                child: Container(
                  padding: const EdgeInsets.all(28),
                  decoration: BoxDecoration(
                    color: const Color(0xFF071110),
                    borderRadius: BorderRadius.circular(24),
                    border: Border.all(
                      color: _isEmergency
                          ? const Color(0xFFB93632)
                          : const Color(0xFF1D3B36),
                      width: _isEmergency ? 3 : 2,
                    ),
                    boxShadow: const [
                      BoxShadow(
                        color: Color(0x66000000),
                        blurRadius: 20,
                        offset: Offset(0, 10),
                      ),
                    ],
                  ),
                  child: Center(
                    child: SingleChildScrollView(
                      child: Text(
                        _currentCaption,
                        textAlign: TextAlign.center,
                        style: TextStyle(
                          color: _isEmergency
                              ? const Color(0xFFFFD1CF)
                              : const Color(0xFFA9DDD2),
                          fontSize: 32,
                          fontWeight: FontWeight.w800,
                          height: 1.3,
                          letterSpacing: -0.5,
                        ),
                      ),
                    ),
                  ),
                ),
              ),
              const SizedBox(height: 16),

              // Quick presets for test
              Wrap(
                spacing: 8,
                runSpacing: 8,
                alignment: WrapAlignment.center,
                children: [
                  _PresetButton(
                    label: '“I need some help”',
                    onTap: () => setState(() {
                      _currentCaption = 'I need some help';
                      _isEmergency = true;
                    }),
                  ),
                  _PresetButton(
                    label: '“I would like water”',
                    onTap: () => setState(() {
                      _currentCaption = 'I would like some water';
                      _isEmergency = false;
                    }),
                  ),
                  _PresetButton(
                    label: '“Thank you”',
                    onTap: () => setState(() {
                      _currentCaption = 'Thank you';
                      _isEmergency = false;
                    }),
                  ),
                  _PresetButton(
                    label: '“I’m coming now”',
                    onTap: () => setState(() {
                      _currentCaption = 'I am on my way to help you';
                      _isEmergency = false;
                    }),
                  ),
                ],
              ),
              const SizedBox(height: 14),

              // Custom Broadcast Input Row
              Row(
                children: [
                  Expanded(
                    child: TextField(
                      controller: _captionInputController,
                      style: const TextStyle(color: Colors.white),
                      decoration: InputDecoration(
                        hintText: 'Type text to display on wheelchair screen…',
                        hintStyle: const TextStyle(color: Color(0xFF6B8A84), fontSize: 13),
                        filled: true,
                        fillColor: const Color(0xFF162825),
                        border: OutlineInputBorder(
                          borderRadius: BorderRadius.circular(14),
                          borderSide: const BorderSide(color: Color(0xFF284B45)),
                        ),
                        contentPadding: const EdgeInsets.symmetric(
                            horizontal: 14, vertical: 10),
                      ),
                      onSubmitted: (val) => _sendCustomCaption(),
                    ),
                  ),
                  const SizedBox(width: 8),
                  IconButton.filled(
                    style: IconButton.styleFrom(
                      backgroundColor: const Color(0xFF13877C),
                    ),
                    onPressed: () => _sendCustomCaption(),
                    icon: const Icon(Icons.send, color: Colors.white),
                    tooltip: 'Show on Wheelchair Screen',
                  ),
                ],
              ),
            ],
          ),
        ),
      ),

    );
  }
}

class _TelemetryItem extends StatelessWidget {
  const _TelemetryItem({
    required this.icon,
    required this.label,
    required this.value,
  });

  final IconData icon;
  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(icon, color: const Color(0xFFA9DDD2), size: 18),
        const SizedBox(width: 6),
        Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              label,
              style: const TextStyle(
                color: Color(0xFF6B8A84),
                fontSize: 9,
                fontWeight: FontWeight.w700,
              ),
            ),
            Text(
              value,
              style: const TextStyle(
                color: Colors.white,
                fontSize: 12,
                fontWeight: FontWeight.w800,
              ),
            ),
          ],
        ),
      ],
    );
  }
}

class _PresetButton extends StatelessWidget {
  const _PresetButton({required this.label, required this.onTap});

  final String label;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(20),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
        decoration: BoxDecoration(
          color: const Color(0xFF162825),
          borderRadius: BorderRadius.circular(20),
          border: Border.all(color: const Color(0xFF284B45)),
        ),
        child: Text(
          label,
          style: const TextStyle(
            color: Color(0xFFA9DDD2),
            fontSize: 12,
            fontWeight: FontWeight.w600,
          ),
        ),
      ),
    );
  }
}

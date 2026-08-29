// single_switch_scanning_view.dart
// Automated scanning communication interface for users with only one reliable voluntary movement.

import 'dart:async';
import 'package:flutter/material.dart';
import '../core/mobile_services.dart';

class SingleSwitchScanningView extends StatefulWidget {
  const SingleSwitchScanningView({
    super.key,
    required this.services,
    this.scanIntervalMs = 1800,
  });

  final MobileServices services;
  final int scanIntervalMs;

  @override
  State<SingleSwitchScanningView> createState() => _SingleSwitchScanningViewState();
}

class _SingleSwitchScanningViewState extends State<SingleSwitchScanningView> {
  Timer? _scanTimer;
  int _activeCategoryIndex = 0;
  int _activePhraseIndex = 0;
  bool _inPhraseLevel = false;

  final List<Map<String, dynamic>> _catalog = [
    {
      'category': 'Urgent Needs',
      'icon': Icons.emergency,
      'color': Color(0xFFEF4444),
      'phrases': ['Help please', 'I have severe pain', 'Doctor or Nurse needed', 'Emergency SOS'],
    },
    {
      'category': 'Daily Care',
      'icon': Icons.water_drop,
      'color': Color(0xFF0EA5E9),
      'phrases': ['Water please', 'I want food', 'Need toilet', 'Change my posture'],
    },
    {
      'category': 'Comfort & Room',
      'icon': Icons.thermostat,
      'color': Color(0xFFF59E0B),
      'phrases': ['Too cold, blanket please', 'Too hot, turn fan on', 'Turn light on', 'Turn light off'],
    },
    {
      'category': 'Social & Feelings',
      'icon': Icons.favorite,
      'color': Color(0xFFEC4899),
      'phrases': ['Thank you', 'Call my family', 'I want to rest', 'I feel happy'],
    },
  ];

  @override
  void initState() {
    super.initState();
    _startScanning();
  }

  void _startScanning() {
    _scanTimer?.cancel();
    _scanTimer = Timer.periodic(Duration(milliseconds: widget.scanIntervalMs), (_) {
      if (!mounted) return;
      setState(() {
        if (!_inPhraseLevel) {
          _activeCategoryIndex = (_activeCategoryIndex + 1) % _catalog.length;
        } else {
          final phrases = _catalog[_activeCategoryIndex]['phrases'] as List<String>;
          _activePhraseIndex = (_activePhraseIndex + 1) % phrases.length;
        }
      });
    });
  }

  void onTrigger() {
    if (!_inPhraseLevel) {
      setState(() {
        _inPhraseLevel = true;
        _activePhraseIndex = 0;
      });
    } else {
      final phrases = _catalog[_activeCategoryIndex]['phrases'] as List<String>;
      final phrase = phrases[_activePhraseIndex];
      _speakAndNotify(phrase);
      setState(() {
        _inPhraseLevel = false;
      });
    }
  }

  void _speakAndNotify(String phrase) {
    widget.services.voice.speakPhrase('scan_phrase', phrase);
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text('Spoken: "$phrase"', style: const TextStyle(fontWeight: FontWeight.bold)),
        backgroundColor: const Color(0xFF14B8A6),
        duration: const Duration(seconds: 2),
      ),
    );
  }

  @override
  void dispose() {
    _scanTimer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: onTrigger,
      child: Container(
        color: const Color(0xFF0F172A),
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
              decoration: BoxDecoration(
                color: const Color(0xFF1E293B),
                borderRadius: BorderRadius.circular(12),
                border: Border.all(color: const Color(0xFF2DD4BF)),
              ),
              child: Row(
                children: [
                  const Icon(Icons.touch_app, color: Color(0xFF2DD4BF)),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Text(
                      _inPhraseLevel
                          ? 'Scanning Phrases... Tap/Blink to select phrase.'
                          : 'Scanning Categories... Tap/Blink to select category.',
                      style: const TextStyle(color: Colors.white, fontSize: 13, fontWeight: FontWeight.w600),
                    ),
                  ),
                  if (_inPhraseLevel)
                    TextButton(
                      onPressed: () => setState(() => _inPhraseLevel = false),
                      child: const Text('Back', style: TextStyle(color: Color(0xFF94A3B8))),
                    ),
                ],
              ),
            ),
            const SizedBox(height: 16),
            Expanded(
              child: _inPhraseLevel ? _buildPhraseGrid() : _buildCategoryGrid(),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildCategoryGrid() {
    return GridView.builder(
      gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
        crossAxisCount: 2,
        childAspectRatio: 1.1,
        crossAxisSpacing: 12,
        mainAxisSpacing: 12,
      ),
      itemCount: _catalog.length,
      itemBuilder: (context, i) {
        final cat = _catalog[i];
        final isSelected = i == _activeCategoryIndex;
        return Container(
          decoration: BoxDecoration(
            color: isSelected ? const Color(0xFF134E4A) : const Color(0xFF1E293B),
            borderRadius: BorderRadius.circular(16),
            border: Border.all(
              color: isSelected ? const Color(0xFF2DD4BF) : const Color(0xFF334155),
              width: isSelected ? 3.5 : 1.0,
            ),
            boxShadow: isSelected
                ? [const BoxShadow(color: Color(0x662DD4BF), blurRadius: 16, spreadRadius: 2)]
                : null,
          ),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Icon(cat['icon'] as IconData, size: 40, color: cat['color'] as Color),
              const SizedBox(height: 10),
              Text(cat['category'] as String, style: const TextStyle(color: Colors.white, fontSize: 16, fontWeight: FontWeight.bold)),
            ],
          ),
        );
      },
    );
  }

  Widget _buildPhraseGrid() {
    final phrases = _catalog[_activeCategoryIndex]['phrases'] as List<String>;
    return ListView.builder(
      itemCount: phrases.length,
      itemBuilder: (context, i) {
        final phrase = phrases[i];
        final isSelected = i == _activePhraseIndex;
        return Container(
          margin: const EdgeInsets.only(bottom: 12),
          padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 18),
          decoration: BoxDecoration(
            color: isSelected ? const Color(0xFF134E4A) : const Color(0xFF1E293B),
            borderRadius: BorderRadius.circular(14),
            border: Border.all(
              color: isSelected ? const Color(0xFF2DD4BF) : const Color(0xFF334155),
              width: isSelected ? 3.5 : 1.0,
            ),
            boxShadow: isSelected
                ? [const BoxShadow(color: Color(0x662DD4BF), blurRadius: 12, spreadRadius: 1)]
                : null,
          ),
          child: Row(
            children: [
              Icon(isSelected ? Icons.check_circle : Icons.circle_outlined, color: isSelected ? const Color(0xFF2DD4BF) : const Color(0xFF64748B)),
              const SizedBox(width: 14),
              Expanded(
                child: Text(
                  phrase,
                  style: TextStyle(color: isSelected ? Colors.white : const Color(0xFFCBD5E1), fontSize: 16, fontWeight: isSelected ? FontWeight.w800 : FontWeight.w600),
                ),
              ),
            ],
          ),
        );
      },
    );
  }
}

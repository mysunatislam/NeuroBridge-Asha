import 'package:fingerspeak_mobile/core/mobile_services.dart';
import 'package:fingerspeak_mobile/models/user_role.dart';
import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';

Future<void> showCaregiverEmergencySheet(
  BuildContext context,
  MobileServices services,
) {
  return showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    useSafeArea: true,
    showDragHandle: true,
    backgroundColor: const Color(0xFFFFF7F7),
    builder: (context) => FractionallySizedBox(
      heightFactor: 0.94,
      child: _CaregiverEmergencySheet(services: services),
    ),
  );
}

class _CaregiverEmergencySheet extends StatefulWidget {
  const _CaregiverEmergencySheet({required this.services});

  final MobileServices services;

  @override
  State<_CaregiverEmergencySheet> createState() =>
      _CaregiverEmergencySheetState();
}

class _CaregiverEmergencySheetState extends State<_CaregiverEmergencySheet> {
  final _queryController = TextEditingController();
  final _scrollController = ScrollController();
  bool _asking = false;

  @override
  void dispose() {
    _queryController.dispose();
    _scrollController.dispose();
    super.dispose();
  }

  Future<void> _makeCall(String phoneNumber, String label) async {
    final cleaned = phoneNumber.trim();
    if (cleaned.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('No phone number configured for $label.')),
      );
      return;
    }
    final uri = Uri(scheme: 'tel', path: cleaned);
    if (!await launchUrl(uri)) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Could not launch phone call dialer.')),
        );
      }
    }
  }

  Future<void> _askAsha() async {
    final text = _queryController.text.trim();
    if (text.isEmpty || _asking) return;
    _queryController.clear();
    setState(() => _asking = true);
    await widget.services.companion.send(
      text,
      role: UserRole.caregiver,
    );
    if (mounted) {
      setState(() => _asking = false);
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (_scrollController.hasClients) {
          _scrollController.animateTo(
            _scrollController.position.maxScrollExtent,
            duration: const Duration(milliseconds: 250),
            curve: Curves.easeOut,
          );
        }
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final config = widget.services.config;
    final messages = widget.services.companion.messages;

    return Padding(
      padding: EdgeInsets.only(
        left: 16,
        right: 16,
        bottom: MediaQuery.viewInsetsOf(context).bottom + 16,
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              const CircleAvatar(
                backgroundColor: Color(0xFFB42318),
                child: Icon(Icons.emergency, color: Colors.white),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      'Asha Emergency Clinical Guide',
                      style: Theme.of(context).textTheme.titleLarge?.copyWith(
                            color: const Color(0xFF7A150E),
                            fontWeight: FontWeight.w800,
                          ),
                    ),
                    const Text('Instant first-aid protocols & direct emergency calls'),
                  ],
                ),
              ),
            ],
          ),
          const SizedBox(height: 12),
          // Emergency Call Buttons
          Row(
            children: [
              Expanded(
                child: FilledButton.icon(
                  style: FilledButton.styleFrom(
                    backgroundColor: const Color(0xFFB42318),
                    foregroundColor: Colors.white,
                    padding: const EdgeInsets.symmetric(vertical: 14),
                  ),
                  onPressed: () => _makeCall(config.ambulancePhone, 'Ambulance'),
                  icon: const Icon(Icons.phone_in_talk),
                  label: Text('Call Ambulance (${config.ambulancePhone})'),
                ),
              ),
              const SizedBox(width: 8),
              if (config.doctorPhone.isNotEmpty)
                Expanded(
                  child: FilledButton.tonalIcon(
                    style: FilledButton.styleFrom(
                      padding: const EdgeInsets.symmetric(vertical: 14),
                    ),
                    onPressed: () => _makeCall(config.doctorPhone, 'Doctor'),
                    icon: const Icon(Icons.medical_services),
                    label: const Text('Call Doctor'),
                  ),
                ),
            ],
          ),
          const Divider(height: 24),
          Expanded(
            child: ListView(
              controller: _scrollController,
              children: [
                // Sudden Seizure Card
                Card(
                  color: Colors.white,
                  shape: RoundedRectangleBorder(
                    side: const BorderSide(color: Color(0xFFFECDCA), width: 1.5),
                    borderRadius: BorderRadius.circular(16),
                  ),
                  child: const Padding(
                    padding: EdgeInsets.all(16),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Row(
                          children: [
                            Icon(Icons.bolt, color: Color(0xFFB42318)),
                            SizedBox(width: 8),
                            Text(
                              'Sudden Seizure Protocol',
                              style: TextStyle(
                                fontSize: 17,
                                fontWeight: FontWeight.w800,
                                color: Color(0xFF7A150E),
                              ),
                            ),
                          ],
                        ),
                        SizedBox(height: 8),
                        Text(
                          '1. Stay Calm & Note Time: Check clock to time duration.\n'
                          '2. Protect from Injury: Clear sharp, hard objects around wheelchair.\n'
                          '3. Cushion Head: Softly support head to prevent impact.\n'
                          '4. DO NOT Restrain: Never hold patient down or place anything in their mouth.\n'
                          '5. Recovery Position: Once convulsing stops, gently turn patient onto their side to keep airway open.\n'
                          '6. Call Ambulance Immediately if seizure lasts > 5 minutes, breathing is difficult, or patient is injured.',
                          style: TextStyle(height: 1.4, color: Color(0xFF333333)),
                        ),
                      ],
                    ),
                  ),
                ),
                const SizedBox(height: 12),
                // Respiratory Distress Card
                Card(
                  color: Colors.white,
                  shape: RoundedRectangleBorder(
                    side: const BorderSide(color: Color(0xFFD0D5DD), width: 1.5),
                    borderRadius: BorderRadius.circular(16),
                  ),
                  child: const Padding(
                    padding: EdgeInsets.all(16),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Row(
                          children: [
                            Icon(Icons.air, color: Color(0xFF0B756A)),
                            SizedBox(width: 8),
                            Text(
                              'Breathing Distress / Choking Protocol',
                              style: TextStyle(
                                fontSize: 17,
                                fontWeight: FontWeight.w800,
                                color: Color(0xFF0B756A),
                              ),
                            ),
                          ],
                        ),
                        SizedBox(height: 8),
                        Text(
                          '1. Ensure patient is seated upright.\n'
                          '2. Check mouth for food obstruction if safe.\n'
                          '3. Loosen restrictive clothing around neck.\n'
                          '4. Encourage calm slow breaths; call emergency services if lips turn blue or patient cannot breathe.',
                          style: TextStyle(height: 1.4, color: Color(0xFF333333)),
                        ),
                      ],
                    ),
                  ),
                ),
                const SizedBox(height: 16),
                const Text(
                  'Asha Emergency Q&A Log:',
                  style: TextStyle(fontWeight: FontWeight.bold, fontSize: 15),
                ),
                const SizedBox(height: 8),
                ...messages.map((m) {
                  final isAsha = m.role.name == 'asha';
                  return Container(
                    margin: const EdgeInsets.only(bottom: 8),
                    padding: const EdgeInsets.all(12),
                    decoration: BoxDecoration(
                      color: isAsha ? const Color(0xFFEBF6F4) : const Color(0xFF2C3E3A),
                      borderRadius: BorderRadius.circular(12),
                    ),
                    child: Text(
                      m.text,
                      style: TextStyle(
                        color: isAsha ? Colors.black87 : Colors.white,
                        fontSize: 14,
                      ),
                    ),
                  );
                }),
              ],
            ),
          ),
          const SizedBox(height: 8),
          Row(
            children: [
              Expanded(
                child: TextField(
                  controller: _queryController,
                  decoration: const InputDecoration(
                    hintText: 'Ask Asha for medical/first-aid instructions…',
                  ),
                  onSubmitted: (_) => _askAsha(),
                ),
              ),
              const SizedBox(width: 8),
              IconButton.filled(
                style: IconButton.styleFrom(
                  backgroundColor: const Color(0xFFB42318),
                ),
                onPressed: _asking ? null : _askAsha,
                icon: const Icon(Icons.send),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

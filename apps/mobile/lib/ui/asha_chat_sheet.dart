import 'dart:async';

import 'package:fingerspeak_mobile/core/mobile_services.dart';
import 'package:fingerspeak_mobile/models/asha_message.dart';
import 'package:fingerspeak_mobile/models/user_role.dart';
import 'package:fingerspeak_mobile/services/companion_controller.dart';
import 'package:fingerspeak_mobile/services/voice_service.dart';
import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';

Future<void> showAshaChatSheet(
  BuildContext context,
  CompanionController companion, {
  UserRole role = UserRole.patient,
  PatientVoiceService? voiceService,
  MobileServices? services,
}) {
  return showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    useSafeArea: true,
    showDragHandle: true,
    backgroundColor: const Color(0xFFFFFBF5),
    shape: const RoundedRectangleBorder(
      borderRadius: BorderRadius.vertical(top: Radius.circular(28)),
    ),
    builder: (context) => FractionallySizedBox(
      heightFactor: 0.92,
      child: _AshaChatSheet(
        companion: companion,
        role: role,
        voiceService: voiceService ?? services?.voice,
        services: services,
      ),
    ),
  );
}

class _AshaChatSheet extends StatefulWidget {
  const _AshaChatSheet({
    required this.companion,
    required this.role,
    this.voiceService,
    this.services,
  });

  final CompanionController companion;
  final UserRole role;
  final PatientVoiceService? voiceService;
  final MobileServices? services;


  @override
  State<_AshaChatSheet> createState() => _AshaChatSheetState();
}

class _AshaChatSheetState extends State<_AshaChatSheet> {
  final _messageController = TextEditingController();
  final _scrollController = ScrollController();

  static const _patientPrompts = [
    'How are you feeling?',
    'Tell me something encouraging',
    'Help me relax with breathing',
    'I would like some water',
    'Call my caregiver',
    'Check wheelchair status',
  ];

  static const _caregiverPrompts = [
    'Seizure first-aid steps',
    'How to calm breathing distress',
    'Wheelchair camera alignment',
    'Emergency clinical contact advice',
  ];

  @override
  void initState() {
    super.initState();
    widget.companion.addListener(_changed);
  }

  @override
  void dispose() {
    widget.companion.removeListener(_changed);
    _messageController.dispose();
    _scrollController.dispose();
    super.dispose();
  }

  void _changed() {
    if (!mounted) return;
    setState(() {});
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

  bool _listening = false;

  Future<void> _send([String? customText]) async {
    final text = customText ?? _messageController.text;
    if (text.trim().isEmpty) return;
    if (customText == null) _messageController.clear();
    await widget.companion.send(text, role: widget.role);
  }

  Future<void> _speakMessage(String text) async {
    if (widget.voiceService != null) {
      await widget.voiceService!.speakPhrase('asha_reply', text);
    }
  }

  Future<void> _writeOnPiDisplay() async {
    final text = _messageController.text.trim().isNotEmpty
        ? _messageController.text.trim()
        : widget.companion.messages.isNotEmpty
            ? widget.companion.messages.last.text
            : 'Asha is here with you.';
    final pi = widget.services?.pi;
    if (pi != null) {
      try {
        pi.sendCaption(text);
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text('Written to Wheelchair Display: "$text"'),
              backgroundColor: const Color(0xFF0B756A),
            ),
          );
        }
      } catch (e) {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text('Could not write to display: $e')),
          );
        }
      }
    }
  }

  Future<void> _callCaregiver() async {
    final phone = widget.services?.config.caregiverPhone.trim() ?? '';
    if (phone.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Caregiver phone number not configured in Setup.'),
        ),
      );
      return;
    }
    final uri = Uri(scheme: 'tel', path: phone);
    if (!await launchUrl(uri)) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Could not open device phone dialer.')),
        );
      }
    }
  }

  Future<void> _triggerSos() async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Send Emergency SOS?'),
        content: const Text(
          'This will display an urgent alert on the wheelchair screen and speak an emergency help phrase immediately.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            style: FilledButton.styleFrom(
              backgroundColor: const Color(0xFFB42318),
            ),
            onPressed: () => Navigator.of(context).pop(true),
            child: const Text('YES, SEND SOS'),
          ),
        ],
      ),
    );

    if (confirmed == true && mounted) {
      final pi = widget.services?.pi;
      if (pi != null) {
        try {
          pi.showEmergency('EMERGENCY: Patient requested urgent help');
        } catch (_) {}
      }
      if (widget.voiceService != null) {
        await widget.voiceService!.speakPhrase('emergency', 'I need help immediately.');
      }
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('Emergency SOS broadcast sent!'),
            backgroundColor: Color(0xFFB42318),
          ),
        );
      }
    }
  }


  void _toggleVoiceInput() {
    setState(() => _listening = !_listening);
    if (_listening) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Listening… Speak now or select a quick topic.'),
          duration: Duration(seconds: 2),
        ),
      );
      // Auto-populate reassurance voice prompt after a short pause
      Future.delayed(const Duration(milliseconds: 1500), () {
        if (mounted && _listening) {
          setState(() {
            _messageController.text = 'I would like to speak with my caregiver';
            _listening = false;
          });
        }
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final messages = widget.companion.messages;
    final isCaregiver = widget.role == UserRole.caregiver;
    final prompts = isCaregiver ? _caregiverPrompts : _patientPrompts;

    return Padding(
      padding: EdgeInsets.only(
        left: 16,
        right: 16,
        bottom: MediaQuery.viewInsetsOf(context).bottom + 12,
      ),
      child: Column(
        children: [
          Row(
            children: [
              Container(
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  border: Border.all(
                    color: isCaregiver
                        ? const Color(0xFFC04B67)
                        : const Color(0xFF0B756A),
                    width: 2.5,
                  ),
                ),
                child: const CircleAvatar(
                  radius: 26,
                  backgroundImage: AssetImage('assets/images/asha-avatar.webp'),
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      isCaregiver ? 'Asha Clinical Assistant' : 'Asha Companion',
                      style: Theme.of(context).textTheme.titleLarge?.copyWith(
                            fontWeight: FontWeight.w800,
                            color: isCaregiver
                                ? const Color(0xFFC04B67)
                                : const Color(0xFF0B756A),
                          ),
                    ),
                    Row(
                      children: [
                        Icon(
                          widget.companion.online
                              ? Icons.cloud_done
                              : Icons.cloud_off,
                          size: 14,
                          color: widget.companion.online
                              ? const Color(0xFF0B756A)
                              : Colors.orange,
                        ),
                        const SizedBox(width: 4),
                        Text(
                          widget.companion.online
                              ? 'Online AI LLM • answers spoken'
                              : 'Local assistant ready',
                          style: const TextStyle(
                              fontSize: 12, color: Color(0xFF6B8A84)),
                        ),
                      ],
                    ),
                  ],
                ),
              ),
              IconButton(
                icon: const Icon(Icons.delete_sweep_outlined),
                tooltip: 'Clear Conversation',
                onPressed: () {
                  widget.companion.clear();
                  setState(() {});
                },
              ),
            ],
          ),
          const Divider(height: 24),

          // Messages
          Expanded(
            child: ListView.separated(
              controller: _scrollController,
              itemCount: messages.length,
              separatorBuilder: (_, __) => const SizedBox(height: 10),
              itemBuilder: (context, index) {
                final message = messages[index];
                final fromAsha = message.role == AshaMessageRole.asha;
                return Align(
                  alignment:
                      fromAsha ? Alignment.centerLeft : Alignment.centerRight,
                  child: Container(
                    constraints: const BoxConstraints(maxWidth: 320),
                    padding: const EdgeInsets.symmetric(
                        horizontal: 14, vertical: 12),
                    decoration: BoxDecoration(
                      color: fromAsha
                          ? const Color(0xFFE2F3EF)
                          : const Color(0xFF102522),
                      borderRadius: BorderRadius.circular(18),
                      border: Border.all(
                        color: fromAsha
                            ? const Color(0xFFBFE5DC)
                            : const Color(0xFF1B3B36),
                      ),
                    ),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          message.text,
                          style: TextStyle(
                            color: fromAsha
                                ? const Color(0xFF102522)
                                : Colors.white,
                            fontSize: 15,
                            height: 1.35,
                          ),
                        ),
                        if (fromAsha && widget.voiceService != null)
                          Align(
                            alignment: Alignment.bottomRight,
                            child: InkWell(
                              onTap: () => _speakMessage(message.text),
                              child: const Padding(
                                padding: EdgeInsets.only(top: 4),
                                child: Row(
                                  mainAxisSize: MainAxisSize.min,
                                  children: [
                                    Icon(Icons.volume_up,
                                        size: 15, color: Color(0xFF0B756A)),
                                    SizedBox(width: 4),
                                    Text('Replay',
                                        style: TextStyle(
                                            fontSize: 11,
                                            color: Color(0xFF0B756A),
                                            fontWeight: FontWeight.bold)),
                                  ],
                                ),
                              ),
                            ),
                          ),
                      ],
                    ),
                  ),
                );
              },
            ),
          ),
          if (widget.companion.sending)
            const Padding(
              padding: EdgeInsets.symmetric(vertical: 4),
              child: LinearProgressIndicator(),
            ),

          // Quick Topic Prompt Chips
          Container(
            height: 38,
            margin: const EdgeInsets.symmetric(vertical: 6),
            child: ListView.separated(
              scrollDirection: Axis.horizontal,
              itemCount: prompts.length,
              separatorBuilder: (_, __) => const SizedBox(width: 6),
              itemBuilder: (context, i) {
                final prompt = prompts[i];
                return ActionChip(
                  label: Text(prompt, style: const TextStyle(fontSize: 12)),
                  backgroundColor: const Color(0xFFF3EEE5),
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(18),
                  ),
                  onPressed: widget.companion.sending
                      ? null
                      : () => _send(prompt),
                );
              },
            ),
          ),

          // Quick Actions Toolbar (Pi display, Call caregiver, SOS)
          Container(
            height: 34,
            margin: const EdgeInsets.only(bottom: 8),
            child: ListView(
              scrollDirection: Axis.horizontal,
              children: [
                ActionChip(
                  avatar: const Icon(Icons.tv, size: 16, color: Color(0xFF0B756A)),
                  label: const Text('Write on Wheelchair Display',
                      style: TextStyle(fontSize: 11.5, fontWeight: FontWeight.w600)),
                  backgroundColor: const Color(0xFFE2F3EF),
                  side: const BorderSide(color: Color(0xFFBFE5DC)),
                  onPressed: _writeOnPiDisplay,
                ),
                const SizedBox(width: 6),
                ActionChip(
                  avatar: const Icon(Icons.phone, size: 16, color: Color(0xFF0B756A)),
                  label: const Text('Call Caregiver',
                      style: TextStyle(fontSize: 11.5, fontWeight: FontWeight.w600)),
                  backgroundColor: const Color(0xFFE2F3EF),
                  side: const BorderSide(color: Color(0xFFBFE5DC)),
                  onPressed: _callCaregiver,
                ),
                const SizedBox(width: 6),
                ActionChip(
                  avatar: const Icon(Icons.emergency, size: 16, color: Color(0xFFB42318)),
                  label: const Text('Emergency SOS',
                      style: TextStyle(
                          fontSize: 11.5,
                          fontWeight: FontWeight.bold,
                          color: Color(0xFFB42318))),
                  backgroundColor: const Color(0xFFFEE4E2),
                  side: const BorderSide(color: Color(0xFFFECDCA)),
                  onPressed: _triggerSos,
                ),
              ],
            ),
          ),

          // Input Row
          Row(
            crossAxisAlignment: CrossAxisAlignment.end,
            children: [
              IconButton.filledTonal(
                style: IconButton.styleFrom(
                  backgroundColor: _listening
                      ? Colors.redAccent.withValues(alpha: 0.2)
                      : const Color(0xFFE2F3EF),
                ),
                onPressed: _toggleVoiceInput,
                icon: Icon(
                  _listening ? Icons.mic : Icons.mic_none,
                  color: _listening ? Colors.redAccent : const Color(0xFF0B756A),
                ),
                tooltip: 'Press to talk',
              ),
              const SizedBox(width: 6),
              Expanded(
                child: TextField(
                  controller: _messageController,
                  minLines: 1,
                  maxLines: 4,
                  textInputAction: TextInputAction.send,
                  onSubmitted: (_) => _send(),
                  decoration: InputDecoration(
                    hintText: isCaregiver
                        ? 'Ask Asha for guidance or emergency tips…'
                        : 'Tell Asha what you need…',
                    contentPadding: const EdgeInsets.symmetric(
                        horizontal: 16, vertical: 12),
                  ),
                ),
              ),
              const SizedBox(width: 8),
              IconButton.filled(
                style: IconButton.styleFrom(
                  backgroundColor: isCaregiver
                      ? const Color(0xFFC04B67)
                      : const Color(0xFF0B756A),
                ),
                onPressed: widget.companion.sending ? null : () => _send(),
                icon: const Icon(Icons.send),
                tooltip: 'Send',
              ),
            ],
          ),

        ],
      ),
    );
  }
}

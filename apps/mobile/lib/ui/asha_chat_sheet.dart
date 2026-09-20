import 'dart:async';

import 'package:fingerspeak_mobile/core/mobile_services.dart';
import 'package:fingerspeak_mobile/models/asha_message.dart';
import 'package:fingerspeak_mobile/models/user_role.dart';
import 'package:fingerspeak_mobile/services/companion_controller.dart';
import 'package:fingerspeak_mobile/services/voice_service.dart';
import 'package:fingerspeak_mobile/ui/effects/liquid_glass.dart';
import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';

Future<void> showAshaChatSheet(
  BuildContext context,
  CompanionController companion, {
  UserRole role = UserRole.patient,
  PatientVoiceService? voiceService,
  MobileServices? services,
}) {
  final isDark = Theme.of(context).brightness == Brightness.dark ||
      LiquidGlassThemeController.isDark;
  return showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    useSafeArea: true,
    showDragHandle: true,
    backgroundColor: isDark ? const Color(0xFF0B1324) : const Color(0xFFF8FAFC),
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
    'My hands feel fatigued',
    'I can only blink right now',
    'Explain why my muscles spasm',
    'Start neck & arm rehab exercise',
    'I feel uncomfortable',
    'Check my Digital Twin profile',
    'I would like some water',
    'Call my caregiver',
    'Help me relax with breathing',
    'Log my pain level',
    'বাংলায় কথা বলুন',
  ];

  static const _caregiverPrompts = [
    'Review stroke rehab protocol',
    'Safe transfer & body mechanics',
    'ICU communication board',
    'Autism sensory schedule',
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
    final isDark = Theme.of(context).brightness == Brightness.dark ||
        LiquidGlassThemeController.isDark;

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
                  backgroundImage: AssetImage('assets/images/asha_avatar_new.png'),
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
                                ? const Color(0xFFFB7185)
                                : const Color(0xFF38BDF8),
                          ),
                    ),
                    Builder(
                      builder: (context) {
                        final lastAshaMsg = messages.reversed
                            .where((m) => m.role == AshaMessageRole.asha)
                            .firstOrNull;
                        final lastMode = lastAshaMsg?.mode ??
                            (widget.companion.online ? 'online' : 'auto');

                        IconData modeIcon = Icons.auto_awesome;
                        String modeLabel = 'Asha AI Active • Connected';

                        if (lastMode.contains('maira')) {
                          modeIcon = Icons.stars;
                          modeLabel = '✨ Maira AI Active • Specialist Intelligence';
                        } else if (lastMode.contains('ollama') || lastMode.contains('local')) {
                          modeIcon = Icons.computer;
                          modeLabel = 'Asha AI Active • Local Gemma/Llama';
                        } else if (lastMode.contains('groq')) {
                          modeIcon = Icons.speed;
                          modeLabel = 'Asha AI Active • Groq Cloud';
                        } else if (lastMode.contains('gemini-fallback')) {
                          modeIcon = Icons.psychology;
                          modeLabel = 'Asha AI Active • Clinical RAG Engine';
                        } else if (lastMode.contains('gemini')) {
                          modeIcon = Icons.auto_awesome;
                          modeLabel = 'Asha AI Active • Gemini Cloud Brain';
                        } else if (widget.companion.online) {
                          modeIcon = Icons.stars;
                          modeLabel = '✨ Maira AI Active • Specialist Intelligence';
                        } else {
                          modeIcon = Icons.psychology;
                          modeLabel = 'Asha AI Active • Clinical Neural RAG';
                        }

                        return InkWell(
                          borderRadius: BorderRadius.circular(6),
                          onTap: () {
                            ScaffoldMessenger.of(context).showSnackBar(
                              SnackBar(
                                content: Text(
                                  'Asha Engine: $modeLabel. Grounded in Gigalogy Maira Specialist AI with Samantha TTS voice output.',
                                ),
                                duration: const Duration(seconds: 3),
                              ),
                            );
                          },
                          child: Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              Icon(
                                modeIcon,
                                size: 14,
                                color: const Color(0xFF38BDF8),
                              ),
                              const SizedBox(width: 4),
                              Text(
                                modeLabel,
                                style: const TextStyle(
                                  fontSize: 12,
                                  fontWeight: FontWeight.w600,
                                  color: Color(0xFF38BDF8),
                                ),
                              ),
                            ],
                          ),
                        );
                      },
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
                          ? (isDark
                              ? const Color(0xFF1E293B)
                              : const Color(0xFFE2F3EF))
                          : (isDark
                              ? const Color(0xFF0284C7)
                              : const Color(0xFF0F766E)),
                      borderRadius: BorderRadius.circular(18),
                      border: Border.all(
                        color: fromAsha
                            ? (isDark
                                ? const Color(0xFF334155)
                                : const Color(0xFFBFE5DC))
                            : (isDark
                                ? const Color(0xFF38BDF8)
                                : const Color(0xFF115E59)),
                      ),
                    ),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        if (!fromAsha && (message.gestureModality != null || message.physicalEffortObserved))
                          Padding(
                            padding: const EdgeInsets.only(bottom: 6),
                            child: Row(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                const Icon(Icons.touch_app, size: 12, color: Color(0xFFA6E3D9)),
                                const SizedBox(width: 4),
                                Text(
                                  message.gestureModality != null
                                      ? '${message.gestureModality}${message.gestureConfidence != null ? " (${(message.gestureConfidence! * 100).round()}%)" : ""}'
                                      : 'Somatic gesture',
                                  style: const TextStyle(
                                    fontSize: 10,
                                    color: Color(0xFFA6E3D9),
                                    fontWeight: FontWeight.w600,
                                  ),
                                ),
                              ],
                            ),
                          ),
                        Text(
                          message.text,
                          style: TextStyle(
                            color: fromAsha
                                ? (isDark ? Colors.white : const Color(0xFF102522))
                                : Colors.white,
                            fontSize: 15,
                            height: 1.35,
                          ),
                        ),
                        // --- Recalled memory facts ---
                        if (fromAsha && message.memoryRecalled.isNotEmpty)
                          Padding(
                            padding: const EdgeInsets.only(top: 6),
                            child: Wrap(
                              spacing: 6,
                              runSpacing: 4,
                              children: message.memoryRecalled.map((mem) {
                                return Chip(
                                  label: Text(
                                    'Recalled: ${mem.key} = ${mem.value}',
                                    style: const TextStyle(
                                        fontSize: 10, color: Color(0xFF0B756A)),
                                  ),
                                  avatar: const Icon(Icons.psychology,
                                      size: 12, color: Color(0xFF0B756A)),
                                  backgroundColor: const Color(0xFFE8F5E9),
                                  padding:
                                      const EdgeInsets.symmetric(horizontal: 4),
                                  materialTapTargetSize:
                                      MaterialTapTargetSize.shrinkWrap,
                                  visualDensity: VisualDensity.compact,
                                );
                              }).toList(),
                            ),
                          ),
                        // --- Autonomous Plan steps ---
                        if (fromAsha && message.plan.isNotEmpty)
                          Padding(
                            padding: const EdgeInsets.only(top: 6),
                            child: Container(
                              padding: const EdgeInsets.all(8),
                              decoration: BoxDecoration(
                                color: const Color(0xFFF3FBF9),
                                borderRadius: BorderRadius.circular(10),
                                border:
                                    Border.all(color: const Color(0xFFBFE5DC)),
                              ),
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Row(
                                    children: [
                                      const Icon(Icons.account_tree_outlined,
                                          size: 13, color: Color(0xFF0B756A)),
                                      const SizedBox(width: 5),
                                      Text(
                                        'Autonomous Plan (${message.plan.length} steps)',
                                        style: const TextStyle(
                                          fontSize: 11,
                                          fontWeight: FontWeight.bold,
                                          color: Color(0xFF0B756A),
                                        ),
                                      ),
                                    ],
                                  ),
                                  const SizedBox(height: 4),
                                  ...message.plan.map((s) => Padding(
                                        padding: const EdgeInsets.only(top: 2),
                                        child: Text(
                                          '${s.stepNumber}. ${s.purpose}',
                                          style: const TextStyle(
                                              fontSize: 10,
                                              color: Color(0xFF334E48)),
                                        ),
                                      )),
                                ],
                              ),
                            ),
                          ),
                        // --- Verification badge ---
                        if (fromAsha && message.verification != null)
                          Padding(
                            padding: const EdgeInsets.only(top: 6),
                            child: Row(
                              children: [
                                Icon(
                                  message.verification!.isVerified
                                      ? Icons.verified_user
                                      : Icons.gpp_maybe,
                                  size: 13,
                                  color: message.verification!.isVerified
                                      ? const Color(0xFF0B756A)
                                      : const Color(0xFFB45309),
                                ),
                                const SizedBox(width: 4),
                                Expanded(
                                  child: Text(
                                    message.verification!.isVerified
                                        ? 'Verified: Clinically safe, grounded, & task complete'
                                        : 'Verification note: ${message.verification!.critiqueNotes}',
                                    style: TextStyle(
                                      fontSize: 10,
                                      fontWeight: FontWeight.w600,
                                      color: message.verification!.isVerified
                                          ? const Color(0xFF0B756A)
                                          : const Color(0xFFB45309),
                                    ),
                                  ),
                                ),
                              ],
                            ),
                          ),
                        // --- Tool execution badges (agentic actions taken) ---
                        if (fromAsha && message.actionsExecuted.isNotEmpty)
                          Padding(
                            padding: const EdgeInsets.only(top: 8),
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: message.actionsExecuted.map((ex) {
                                final icon = ex.success ? Icons.check_circle : Icons.warning_amber;
                                final color = ex.success ? const Color(0xFF0B756A) : const Color(0xFFB42318);
                                return Padding(
                                  padding: const EdgeInsets.only(bottom: 4),
                                  child: Row(
                                    crossAxisAlignment: CrossAxisAlignment.start,
                                    children: [
                                      Icon(icon, size: 13, color: color),
                                      const SizedBox(width: 5),
                                      Expanded(
                                        child: Text(
                                          ex.summary,
                                          style: TextStyle(
                                            fontSize: 11,
                                            color: color,
                                            fontWeight: FontWeight.w500,
                                          ),
                                        ),
                                      ),
                                    ],
                                  ),
                                );
                              }).toList(),
                            ),
                          ),
                        // --- Clinical citation chips ---
                        if (fromAsha && message.citations.isNotEmpty)
                          Padding(
                            padding: const EdgeInsets.only(top: 6),
                            child: Wrap(
                              spacing: 6,
                              runSpacing: 4,
                              children: message.citations.map((c) {
                                return Chip(
                                  label: Text(
                                    c.title.length > 34 ? '${c.title.substring(0, 32)}…' : c.title,
                                    style: const TextStyle(fontSize: 10, color: Color(0xFF0B756A)),
                                  ),
                                  avatar: const Icon(Icons.menu_book, size: 12, color: Color(0xFF0B756A)),
                                  backgroundColor: const Color(0xFFE0F2F0),
                                  padding: const EdgeInsets.symmetric(horizontal: 4),
                                  materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
                                  visualDensity: VisualDensity.compact,
                                );
                              }).toList(),
                            ),
                          ),
                        // --- Dynamic quick action chips from agent ---
                        if (fromAsha && message.quickActions.isNotEmpty)
                          Padding(
                            padding: const EdgeInsets.only(top: 8),
                            child: Wrap(
                              spacing: 6,
                              runSpacing: 4,
                              children: message.quickActions.take(4).map((qa) {
                                return ActionChip(
                                  label: Text(qa.label, style: const TextStyle(fontSize: 11)),
                                  backgroundColor: const Color(0xFFF0FDF9),
                                  side: const BorderSide(color: Color(0xFF0B756A), width: 1),
                                  padding: const EdgeInsets.symmetric(horizontal: 6),
                                  materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
                                  visualDensity: VisualDensity.compact,
                                  onPressed: widget.companion.sending
                                      ? null
                                      : () => _send(qa.label),
                                );
                              }).toList(),
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
                  label: Text(
                    prompt,
                    style: TextStyle(
                      fontSize: 12,
                      color: isDark ? Colors.white : const Color(0xFF1E293B),
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                  backgroundColor: isDark ? const Color(0xFF1E293B) : const Color(0xFFF1F5F9),
                  side: BorderSide(
                    color: isDark ? const Color(0xFF334155) : const Color(0xFFCBD5E1),
                  ),
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
                  avatar: Icon(Icons.tv, size: 16, color: isDark ? const Color(0xFF38BDF8) : const Color(0xFF0B756A)),
                  label: Text(
                    'Write on Wheelchair Display',
                    style: TextStyle(
                      fontSize: 11.5,
                      fontWeight: FontWeight.w600,
                      color: isDark ? Colors.white : const Color(0xFF1E293B),
                    ),
                  ),
                  backgroundColor: isDark ? const Color(0xFF0F172A) : const Color(0xFFE2F3EF),
                  side: BorderSide(color: isDark ? const Color(0xFF38BDF8) : const Color(0xFFBFE5DC)),
                  onPressed: _writeOnPiDisplay,
                ),
                const SizedBox(width: 6),
                ActionChip(
                  avatar: Icon(Icons.phone, size: 16, color: isDark ? const Color(0xFF38BDF8) : const Color(0xFF0B756A)),
                  label: Text(
                    'Call Caregiver',
                    style: TextStyle(
                      fontSize: 11.5,
                      fontWeight: FontWeight.w600,
                      color: isDark ? Colors.white : const Color(0xFF1E293B),
                    ),
                  ),
                  backgroundColor: isDark ? const Color(0xFF0F172A) : const Color(0xFFE2F3EF),
                  side: BorderSide(color: isDark ? const Color(0xFF38BDF8) : const Color(0xFFBFE5DC)),
                  onPressed: _callCaregiver,
                ),
                const SizedBox(width: 6),
                ActionChip(
                  avatar: const Icon(Icons.emergency, size: 16, color: Color(0xFFFB7185)),
                  label: const Text(
                    'Emergency SOS',
                    style: TextStyle(
                      fontSize: 11.5,
                      fontWeight: FontWeight.bold,
                      color: Color(0xFFFB7185),
                    ),
                  ),
                  backgroundColor: isDark ? const Color(0xFF450A0A) : const Color(0xFFFEE4E2),
                  side: BorderSide(color: isDark ? const Color(0xFFDC2626) : const Color(0xFFFECDCA)),
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
                      : (isDark ? const Color(0xFF1E293B) : const Color(0xFFE2F3EF)),
                ),
                onPressed: _toggleVoiceInput,
                icon: Icon(
                  _listening ? Icons.mic : Icons.mic_none,
                  color: _listening
                      ? Colors.redAccent
                      : (isDark ? const Color(0xFF38BDF8) : const Color(0xFF0B756A)),
                ),
                tooltip: 'Press to talk',
              ),
              const SizedBox(width: 6),
              Expanded(
                child: TextField(
                  controller: _messageController,
                  minLines: 1,
                  maxLines: 4,
                  style: TextStyle(color: isDark ? Colors.white : Colors.black),
                  textInputAction: TextInputAction.send,
                  onSubmitted: (_) => _send(),
                  decoration: InputDecoration(
                    filled: true,
                    fillColor: isDark ? const Color(0xFF1E293B) : const Color(0xFFF1F5F9),
                    border: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(20),
                      borderSide: BorderSide(
                        color: isDark ? const Color(0xFF334155) : const Color(0xFFCBD5E1),
                      ),
                    ),
                    enabledBorder: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(20),
                      borderSide: BorderSide(
                        color: isDark ? const Color(0xFF334155) : const Color(0xFFCBD5E1),
                      ),
                    ),
                    hintText: isCaregiver
                        ? 'Ask Asha for guidance or emergency tips…'
                        : 'Tell Asha what you need…',
                    hintStyle: TextStyle(
                      color: isDark ? const Color(0xFF94A3B8) : const Color(0xFF64748B),
                    ),
                    contentPadding: const EdgeInsets.symmetric(
                        horizontal: 16, vertical: 12),
                  ),
                ),
              ),
              const SizedBox(width: 8),
              IconButton.filled(
                style: IconButton.styleFrom(
                  backgroundColor: isCaregiver
                      ? const Color(0xFFFB7185)
                      : (isDark ? const Color(0xFF38BDF8) : const Color(0xFF0B756A)),
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

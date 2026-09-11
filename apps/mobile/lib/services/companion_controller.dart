import 'dart:async';

import 'package:fingerspeak_mobile/data/asha_api_client.dart';
import 'package:fingerspeak_mobile/data/asha_offline_agent.dart';
import 'package:fingerspeak_mobile/models/asha_message.dart';
import 'package:fingerspeak_mobile/models/user_role.dart';
import 'package:fingerspeak_mobile/services/voice_service.dart';
import 'package:flutter/foundation.dart';

class CompanionController extends ChangeNotifier {
  CompanionController({
    required AshaApiClient api,
    required PatientVoiceService voice,
    required this.locale,
    AshaOfflineAgent? offlineAgent,
  })  : _api = api,
        _voice = voice,
        _offlineAgent = offlineAgent ?? AshaOfflineAgent();

  final AshaApiClient _api;
  final PatientVoiceService _voice;
  final AshaOfflineAgent _offlineAgent;
  final String locale;
  final List<AshaMessage> _messages = [];
  Timer? _checkInTimer;
  String? _previousResponseId;
  bool _sending = false;
  bool _online = false;
  bool _started = false;

  List<AshaMessage> get messages => List.unmodifiable(_messages);
  bool get sending => _sending;
  bool get online => _online;
  AshaApiClient get api => _api;

  Future<void> start({UserRole role = UserRole.patient}) async {
    if (_started) return;
    _started = true;
    var greeting = role == UserRole.patient
        ? 'Asha is here. If you need anything, I am listening.'
        : 'Hello. I am Asha, ready to support you with patient care and emergency guidance.';
    var mode = 'offline';
    try {
      final prompt = role == UserRole.patient
          ? 'Give the patient a warm, reassuring welcome in one short sentence.'
          : 'Give the caregiver a supportive, concise welcome ready for patient care in one short sentence.';
      final reply = await _api.chat(
        message: prompt,
        locale: locale,
        careMode: role == UserRole.caregiver ? 'caregiver' : 'continuous',
      );
      greeting = reply.text;
      mode = reply.mode;
      _online = reply.isOnline;
      _previousResponseId = reply.previousResponseId;
    } on AshaUnavailableException {
      _online = false;
    }
    _messages.add(AshaMessage(
      role: AshaMessageRole.asha,
      text: greeting,
      sentAt: DateTime.now(),
      mode: mode,
    ));
    notifyListeners();
    await _voice.speakAsha(greeting);
    _checkInTimer = Timer.periodic(
      const Duration(minutes: 30),
      (_) => unawaited(_gentleCheckIn(role: role)),
    );
  }

  Future<void> _gentleCheckIn({UserRole role = UserRole.patient}) async {
    if (role != UserRole.patient) return;
    const text =
        'I’m still here. Would you like water, help, or a conversation?';
    _messages.add(AshaMessage(
      role: AshaMessageRole.asha,
      text: text,
      sentAt: DateTime.now(),
      mode: 'on-device',
    ));
    notifyListeners();
    await _voice.speakAsha(text);
  }

  Future<void> send(
    String rawMessage, {
    String? preferredName,
    UserRole role = UserRole.patient,
  }) async {
    final message = rawMessage.trim();
    if (message.isEmpty || _sending) return;
    _messages.add(AshaMessage(
      role: AshaMessageRole.patient,
      text: message,
      sentAt: DateTime.now(),
    ));
    _sending = true;
    notifyListeners();

    AshaReply reply;
    try {
      reply = await _api.chat(
        message: message,
        locale: locale,
        previousResponseId: _previousResponseId,
        preferredName: preferredName,
        careMode: role == UserRole.caregiver ? 'caregiver_emergency' : 'continuous',
      );
      _online = reply.isOnline;
      _previousResponseId = reply.previousResponseId;
    } on AshaUnavailableException {
      _online = false;
      reply = _fallbackResponseFor(
        message,
        role: role,
        preferredName: preferredName,
      );
    }
    _messages.add(AshaMessage(
      role: AshaMessageRole.asha,
      text: reply.text,
      sentAt: DateTime.now(),
      mode: reply.mode,
      actionsExecuted: reply.actionsExecuted,
      citations: reply.citations,
      quickActions: reply.quickActions,
      plan: reply.plan,
      verification: reply.verification,
      memoryRecalled: reply.memoryRecalled,
    ));
    _sending = false;
    notifyListeners();
    await _voice.speakAsha(reply.text, force: reply.urgent);
  }

  AshaReply _fallbackResponseFor(
    String query, {
    required UserRole role,
    String? preferredName,
  }) {
    return _offlineAgent.process(
      message: query,
      locale: locale,
      preferredName: preferredName,
      role: role,
    );
  }

  void clear() {
    _messages.clear();
    _previousResponseId = null;
    notifyListeners();
  }

  @override
  void dispose() {
    _checkInTimer?.cancel();
    _api.close();
    super.dispose();
  }
}

import 'dart:async';

import 'package:fingerspeak_mobile/core/mobile_services.dart';
import 'package:fingerspeak_mobile/data/pi_device_client.dart';
import 'package:fingerspeak_mobile/models/patient_access_method.dart';
import 'package:fingerspeak_mobile/models/user_role.dart';
import 'package:fingerspeak_mobile/services/voice_service.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:shared_preferences/shared_preferences.dart';

class SettingsPage extends StatefulWidget {
  const SettingsPage({required this.services, this.onRoleChanged, super.key});

  final MobileServices services;
  final void Function(UserRole role)? onRoleChanged;

  @override
  State<SettingsPage> createState() => _SettingsPageState();
}

class _SettingsPageState extends State<SettingsPage> {
  final _piUrlController = TextEditingController();
  final _pairingController = TextEditingController();
  final _doctorPhoneController = TextEditingController();
  final _caregiverPhoneController = TextEditingController();
  final _patientPhoneController = TextEditingController();
  final _ambulancePhoneController = TextEditingController();
  final _geminiKeyController = TextEditingController();
  final _customBaseUrlController = TextEditingController();
  final _customModelController = TextEditingController();
  final _customApiKeyController = TextEditingController();
  String _aiProvider = 'offline';
  bool _obscureGeminiKey = true;
  bool _obscureCustomKey = true;

  PiConnectionState _piState = PiConnectionState.disconnected;
  bool _pairing = false;
  bool _loadingVoices = true;
  List<String> _voiceNames = const [];
  late double _speechRate;
  late double _pitch;
  late double _volume;
  UserRole? _currentRole;
  PatientAccessMethod? _patientAccessMethod;
  StreamSubscription<PiConnectionState>? _piSubscription;

  @override
  void initState() {
    super.initState();
    final config = widget.services.config;
    _speechRate = widget.services.voice.preferences.speechRate;
    _pitch = widget.services.voice.preferences.pitch;
    _volume = widget.services.voice.preferences.volume;
    _piState = widget.services.pi.state;
    _currentRole = widget.services.roleRepository.load() ?? UserRole.patient;
    _patientAccessMethod = widget.services.patientAccessMethodRepository.load();
    widget.services.patientAccessMethodRepository
        .addListener(_onPatientAccessMethodChanged);

    _doctorPhoneController.text = config.doctorPhone;
    _caregiverPhoneController.text = config.caregiverPhone;
    _patientPhoneController.text = config.patientPhone;
    _ambulancePhoneController.text = config.ambulancePhone;
    _piUrlController.text = widget.services.pi.endpoint.toString();

    _piSubscription = widget.services.pi.states.listen((state) {
      if (!mounted) return;
      if (state == PiConnectionState.connected) _pairingController.clear();
      setState(() => _piState = state);
    });
    unawaited(_loadVoices());
    unawaited(_loadAiSettings());
  }

  Future<void> _loadAiSettings() async {
    final prefs = await SharedPreferences.getInstance();
    final provider = prefs.getString('ai.provider') ?? 'offline';
    final key = prefs.getString('gemini.api_key') ??
        widget.services.config.geminiApiKey;
    final baseUrl = prefs.getString('ai.base_url') ?? 'http://10.0.2.2:11434/v1';
    final model = prefs.getString('ai.model') ?? 'llama3.2:3b';
    final customKey = prefs.getString('ai.api_key') ?? '';
    if (mounted) {
      setState(() {
        _aiProvider = provider;
        _geminiKeyController.text = key;
        _customBaseUrlController.text = baseUrl;
        _customModelController.text = model;
        _customApiKeyController.text = customKey;
      });
    }
  }

  Future<void> _saveAiSettings() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString('ai.provider', _aiProvider);
    await prefs.setString('gemini.api_key', _geminiKeyController.text.trim());
    await prefs.setString('ai.base_url', _customBaseUrlController.text.trim());
    await prefs.setString('ai.model', _customModelController.text.trim());
    await prefs.setString('ai.api_key', _customApiKeyController.text.trim());
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(_aiProvider == 'offline'
              ? 'Asha set to Offline Deterministic RAG (Zero API cost).'
              : 'AI Engine settings saved for $_aiProvider mode.'),
        ),
      );
    }
  }

  @override
  void dispose() {
    widget.services.patientAccessMethodRepository
        .removeListener(_onPatientAccessMethodChanged);
    unawaited(_piSubscription?.cancel());
    _piUrlController.dispose();
    _pairingController.dispose();
    _doctorPhoneController.dispose();
    _caregiverPhoneController.dispose();
    _patientPhoneController.dispose();
    _ambulancePhoneController.dispose();
    _geminiKeyController.dispose();
    _customBaseUrlController.dispose();
    _customModelController.dispose();
    _customApiKeyController.dispose();
    super.dispose();
  }

  void _onPatientAccessMethodChanged() {
    if (!mounted) return;
    setState(() {
      _patientAccessMethod =
          widget.services.patientAccessMethodRepository.load();
    });
  }

  Future<void> _changeRole(UserRole role) async {
    await widget.services.roleRepository.save(role);
    setState(() => _currentRole = role);
    widget.onRoleChanged?.call(role);
  }

  Future<void> _setPatientAccessMethod(PatientAccessMethod method) async {
    await widget.services.patientAccessMethodRepository.save(method);
    if (mounted) setState(() => _patientAccessMethod = method);
  }

  Future<void> _pair() async {
    final customUrl = _piUrlController.text.trim();
    if (customUrl.isNotEmpty) {
      try {
        final parsed = Uri.parse(customUrl);
        if (parsed.hasScheme && {'ws', 'wss'}.contains(parsed.scheme)) {
          widget.services.pi.updateEndpoint(parsed);
          final prefs = await SharedPreferences.getInstance();
          await prefs.setString('pi.ws_url', customUrl);
        } else {
          throw const FormatException('Pi URL must start with ws:// or wss://');
        }
      } on Object catch (error) {
        if (!mounted) return;
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Invalid Pi URL: $error')),
        );
        return;
      }
    }
    setState(() => _pairing = true);
    try {
      await widget.services.pi.connect(
        oneTimePairingCode: _pairingController.text,
      );
    } on Object catch (error) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('$error')),
      );
    } finally {
      if (mounted) setState(() => _pairing = false);
    }
  }

  Future<void> _setAutoSpeak(bool enabled) async {
    await widget.services.voice.setPreferences(
      widget.services.voice.preferences.copyWith(
        automaticallySpeak: enabled,
      ),
    );
    if (mounted) setState(() {});
  }

  Future<void> _loadVoices() async {
    try {
      final names = await widget.services.voice.availableVoiceNames();
      if (mounted) setState(() => _voiceNames = names);
    } on Object {
      // Default voice fallback.
    } finally {
      if (mounted) setState(() => _loadingVoices = false);
    }
  }

  Future<void> _setTtsVoice(String? selected) async {
    if (selected == null) return;
    await widget.services.voice.setPreferences(
      widget.services.voice.preferences.copyWith(
        ttsVoiceName: selected.isEmpty ? null : selected,
        clearTtsVoiceName: selected.isEmpty,
      ),
    );
    if (mounted) setState(() {});
  }

  Future<void> _saveSpeechRate(double value) async {
    await widget.services.voice.setPreferences(
      widget.services.voice.preferences.copyWith(speechRate: value),
    );
  }

  Future<void> _savePitch(double value) async {
    await widget.services.voice.setPreferences(
      widget.services.voice.preferences.copyWith(pitch: value),
    );
  }

  Future<void> _saveVolume(double value) async {
    await widget.services.voice.setPreferences(
      widget.services.voice.preferences.copyWith(volume: value),
    );
  }

  Future<void> _setPlaybackPreference(PlaybackPreference pref) async {
    await widget.services.voice.setPreferences(
      widget.services.voice.preferences.copyWith(playbackPreference: pref),
    );
    if (mounted) setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    final selectedVoice = widget.services.voice.preferences.ttsVoiceName;
    final voices = <String>{
      if (selectedVoice != null) selectedVoice,
      ..._voiceNames,
    }.toList()
      ..sort();

    return ListView(
      padding: const EdgeInsets.fromLTRB(18, 18, 18, 120),
      children: [
        Text('SETUP & SETTINGS',
            style: Theme.of(context).textTheme.labelLarge?.copyWith(
                  color: const Color(0xFF0B756A),
                  letterSpacing: 1.6,
                  fontWeight: FontWeight.w800,
                )),
        const SizedBox(height: 6),
        Text('Preferences',
            style: Theme.of(context).textTheme.headlineMedium?.copyWith(
                  fontWeight: FontWeight.w800,
                )),
        const Text(
          'Role mode, emergency contacts, wheelchair connection & voice.',
          style: TextStyle(color: Color(0xFF556E68)),
        ),
        const SizedBox(height: 18),
        Card(
          color: const Color(0xFFFFFBEB),
          child: ListTile(
            leading: const CircleAvatar(
              backgroundColor: Color(0xFFCCFBF1),
              child: Icon(Icons.touch_app, color: Color(0xFF0F766E)),
            ),
            title: const Text('Asha Guide'),
            subtitle: const Text(
              'Replay the accessible step-by-step setup walkthrough.',
            ),
            trailing: FilledButton.tonalIcon(
              onPressed: () async {
                await widget.services.ashaGuide.restart();
                if (!context.mounted) return;
                ScaffoldMessenger.of(context).showSnackBar(
                  const SnackBar(content: Text('Asha Guide restarted.')),
                );
              },
              icon: const Icon(Icons.replay),
              label: const Text('Replay'),
            ),
          ),
        ),
        const SizedBox(height: 16),

        // Role Switcher Card
        Card(
          color: Colors.white,
          shape:
              RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Text(
                  'Active Mode',
                  style: Theme.of(context).textTheme.titleLarge,
                ),
                const SizedBox(height: 4),
                const Text(
                    'Switch between Patient and Caregiver dashboard views.'),
                const SizedBox(height: 12),
                SegmentedButton<UserRole>(
                  segments: const [
                    ButtonSegment(
                      value: UserRole.patient,
                      icon: Icon(Icons.accessible_forward),
                      label: Text('Patient Mode'),
                    ),
                    ButtonSegment(
                      value: UserRole.caregiver,
                      icon: Icon(Icons.volunteer_activism),
                      label: Text('Caregiver Mode'),
                    ),
                  ],
                  selected: {_currentRole ?? UserRole.patient},
                  onSelectionChanged: (selected) => _changeRole(selected.first),
                ),
              ],
            ),
          ),
        ),
        const SizedBox(height: 16),

        Card(
          color: Colors.white,
          shape:
              RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Text(
                  'Patient Input Method',
                  style: Theme.of(context).textTheme.titleLarge,
                ),
                const SizedBox(height: 4),
                const Text(
                  'Can the patient intentionally move their fingers? This controls which camera engine starts in Patient Mode.',
                ),
                const SizedBox(height: 12),
                Wrap(
                  spacing: 8,
                  runSpacing: 8,
                  children: [
                    ChoiceChip(
                      avatar: const Icon(Icons.pan_tool_alt, size: 18),
                      label: const Text('Yes — use fingers'),
                      selected: _patientAccessMethod ==
                          PatientAccessMethod.handGestures,
                      onSelected: (_) => _setPatientAccessMethod(
                        PatientAccessMethod.handGestures,
                      ),
                    ),
                    ChoiceChip(
                      avatar: const Icon(
                        Icons.face_retouching_natural,
                        size: 18,
                      ),
                      label: const Text('No — use face & eyes'),
                      selected: _patientAccessMethod ==
                          PatientAccessMethod.faceEyesAndHead,
                      onSelected: (_) => _setPatientAccessMethod(
                        PatientAccessMethod.faceEyesAndHead,
                      ),
                    ),
                  ],
                ),
                if (_patientAccessMethod == null) ...[
                  const SizedBox(height: 8),
                  const Text(
                    'Not chosen yet — Patient Mode will ask on next entry.',
                    style: TextStyle(color: Color(0xFF556E68)),
                  ),
                ],
              ],
            ),
          ),
        ),
        const SizedBox(height: 16),

        // Emergency Contacts Card
        Card(
          color: Colors.white,
          shape:
              RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Text(
                  'Emergency & Contact Numbers',
                  style: Theme.of(context).textTheme.titleLarge,
                ),
                const SizedBox(height: 4),
                const Text(
                  'Configured phone numbers for 1-tap dialer in emergency situations.',
                  style: TextStyle(color: Color(0xFF556E68)),
                ),
                const SizedBox(height: 12),
                TextField(
                  controller: _ambulancePhoneController,
                  keyboardType: TextInputType.phone,
                  decoration: const InputDecoration(
                    labelText: 'Ambulance Emergency Number',
                    prefixIcon: Icon(Icons.emergency, color: Color(0xFFB42318)),
                  ),
                ),
                const SizedBox(height: 10),
                TextField(
                  controller: _doctorPhoneController,
                  keyboardType: TextInputType.phone,
                  decoration: const InputDecoration(
                    labelText: 'Doctor / Physician Phone',
                    prefixIcon: Icon(Icons.medical_services),
                  ),
                ),
                const SizedBox(height: 10),
                TextField(
                  controller: _caregiverPhoneController,
                  keyboardType: TextInputType.phone,
                  decoration: const InputDecoration(
                    labelText: 'Caregiver Phone',
                    prefixIcon: Icon(Icons.person),
                  ),
                ),
                const SizedBox(height: 10),
                TextField(
                  controller: _patientPhoneController,
                  keyboardType: TextInputType.phone,
                  decoration: const InputDecoration(
                    labelText: 'Patient Phone',
                    prefixIcon: Icon(Icons.contact_phone),
                  ),
                ),
              ],
            ),
          ),
        ),
        const SizedBox(height: 16),

        // Wheelchair Hardware Connection Card
        Card(
          color: Colors.white,
          shape:
              RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Text(
                  'Pair Wheelchair Raspberry Pi',
                  style: Theme.of(context).textTheme.titleLarge,
                ),
                const SizedBox(height: 4),
                Text(_piStateLabel(_piState)),
                const SizedBox(height: 12),
                TextField(
                  controller: _piUrlController,
                  keyboardType: TextInputType.url,
                  autocorrect: false,
                  enableSuggestions: false,
                  decoration: const InputDecoration(
                    labelText: 'Pi WebSocket URL',
                    helperText:
                        'e.g. ws://192.168.43.50:8765/v1/device/ws or ws://raspberrypi.local:8765/v1/device/ws',
                  ),
                ),
                const SizedBox(height: 12),
                TextField(
                  controller: _pairingController,
                  obscureText: true,
                  enableSuggestions: false,
                  autocorrect: false,
                  decoration: const InputDecoration(
                    labelText: 'One-time Pi Pairing Code',
                    helperText:
                        'Connects wirelessly or via direct USB tethering.',
                  ),
                ),
                const SizedBox(height: 12),
                SizedBox(
                  height: 54,
                  child: FilledButton.icon(
                    onPressed: _pairing ? null : _pair,
                    icon: const Icon(Icons.link),
                    label: Text(_piState == PiConnectionState.connected
                        ? 'Reconnect Wheelchair Unit'
                        : 'Pair Wheelchair Unit'),
                  ),
                ),
                if (_piState == PiConnectionState.connected) ...[
                  const SizedBox(height: 8),
                  TextButton(
                    onPressed: widget.services.pi.forgetCredential,
                    child: const Text('Forget this wheelchair unit'),
                  ),
                ],
              ],
            ),
          ),
        ),
        const SizedBox(height: 16),

        // Asha Voice Settings Card
        Card(
          color: Colors.white,
          shape:
              RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                SwitchListTile(
                  contentPadding: EdgeInsets.zero,
                  value: widget.services.voice.preferences.automaticallySpeak,
                  onChanged: _setAutoSpeak,
                  title: const Text('Asha Speaks Automatically',
                      style: TextStyle(fontWeight: FontWeight.bold)),
                  subtitle: const Text(
                      'Plays answers and check-ins aloud through phone speaker.'),
                ),
                const Divider(),
                Text(
                  'Aasha Phone Voice',
                  style: Theme.of(context).textTheme.titleLarge,
                ),
                const SizedBox(height: 4),
                const Text(
                    'Choose an installed device TTS voice, rate, pitch and volume.'),
                const SizedBox(height: 12),

                // Playback Preference
                Text('Playback Preference',
                    style: Theme.of(context).textTheme.labelMedium?.copyWith(
                          color: const Color(0xFF0B756A),
                          fontWeight: FontWeight.w700,
                        )),
                const SizedBox(height: 6),
                SegmentedButton<PlaybackPreference>(
                  segments: const [
                    ButtonSegment(
                      value: PlaybackPreference.caregiverRecordingFirst,
                      icon: Icon(Icons.mic),
                      label: Text('Caregiver Recording First'),
                    ),
                    ButtonSegment(
                      value: PlaybackPreference.systemVoiceOnly,
                      icon: Icon(Icons.record_voice_over),
                      label: Text('System Voice Only'),
                    ),
                  ],
                  selected: {
                    widget.services.voice.preferences.playbackPreference
                  },
                  onSelectionChanged: (s) => _setPlaybackPreference(s.first),
                ),
                const SizedBox(height: 14),

                // Voice dropdown
                DropdownButtonFormField<String>(
                  key: ValueKey(
                      'voice-${selectedVoice ?? 'default'}-${voices.length}'),
                  initialValue: selectedVoice ?? '',
                  decoration: InputDecoration(
                    labelText: _loadingVoices
                        ? 'Loading installed voices…'
                        : 'Installed Voice',
                  ),
                  items: [
                    const DropdownMenuItem(
                        value: '', child: Text('System Default')),
                    ...voices.map((name) => DropdownMenuItem(
                          value: name,
                          child: Text(name, overflow: TextOverflow.ellipsis),
                        )),
                  ],
                  onChanged: _loadingVoices ? null : _setTtsVoice,
                ),
                const SizedBox(height: 12),

                // Speech Rate
                Row(children: [
                  const Icon(Icons.speed, size: 18, color: Color(0xFF0B756A)),
                  const SizedBox(width: 6),
                  Text('Speech Rate: ${_speechRate.toStringAsFixed(2)}',
                      style: const TextStyle(fontWeight: FontWeight.w600)),
                ]),
                Slider(
                  value: _speechRate.clamp(0.25, 1.0),
                  min: 0.25,
                  max: 1.0,
                  divisions: 15,
                  label: _speechRate.toStringAsFixed(2),
                  onChanged: (value) => setState(() => _speechRate = value),
                  onChangeEnd: _saveSpeechRate,
                ),

                // Pitch
                Row(children: [
                  const Icon(Icons.tune, size: 18, color: Color(0xFF0B756A)),
                  const SizedBox(width: 6),
                  Text('Pitch: ${_pitch.toStringAsFixed(2)}',
                      style: const TextStyle(fontWeight: FontWeight.w600)),
                ]),
                Slider(
                  value: _pitch,
                  min: 0.5,
                  max: 2.0,
                  divisions: 15,
                  label: _pitch.toStringAsFixed(2),
                  onChanged: (value) => setState(() => _pitch = value),
                  onChangeEnd: _savePitch,
                ),

                // Volume
                Row(children: [
                  const Icon(Icons.volume_up,
                      size: 18, color: Color(0xFF0B756A)),
                  const SizedBox(width: 6),
                  Text('Volume: ${(_volume * 100).round()}%',
                      style: const TextStyle(fontWeight: FontWeight.w600)),
                ]),
                Slider(
                  value: _volume,
                  min: 0.0,
                  max: 1.0,
                  divisions: 10,
                  label: '${(_volume * 100).round()}%',
                  onChanged: (value) => setState(() => _volume = value),
                  onChangeEnd: _saveVolume,
                ),

                SizedBox(
                  height: 50,
                  child: OutlinedButton.icon(
                    onPressed: () => widget.services.voice.speakAsha(
                      'Hello. I am Asha, and I am here with you.',
                      force: true,
                    ),
                    icon: const Icon(Icons.play_arrow),
                    label: const Text('Preview Asha Voice'),
                  ),
                ),
              ],
            ),
          ),
        ),

        const SizedBox(height: 16),

        // Asha AI & Knowledge Engine Card
        Card(
          color: Colors.white,
          shape:
              RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Row(
                  children: [
                    Container(
                      padding: const EdgeInsets.all(6),
                      decoration: BoxDecoration(
                        color: const Color(0xFFE8F0FE),
                        borderRadius: BorderRadius.circular(8),
                      ),
                      child: const Icon(Icons.psychology,
                          color: Color(0xFF0B756A), size: 22),
                    ),
                    const SizedBox(width: 10),
                    Expanded(
                      child: Text(
                        'Asha AI & Knowledge Engine',
                        style: Theme.of(context).textTheme.titleLarge,
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 6),
                const Text(
                  'Select your intelligence engine. Offline RAG works 100% locally with zero API cost, or connect to self-hosted Ollama or cloud providers.',
                  style: TextStyle(fontSize: 13, color: Color(0xFF556E68)),
                ),
                const SizedBox(height: 14),

                // Engine Selector Chips
                Wrap(
                  spacing: 8,
                  runSpacing: 8,
                  children: [
                    ChoiceChip(
                      avatar: const Icon(Icons.offline_bolt, size: 16, color: Color(0xFF15803D)),
                      label: const Text('Offline RAG (\$0)'),
                      selected: _aiProvider == 'offline',
                      onSelected: (selected) {
                        if (selected) setState(() => _aiProvider = 'offline');
                      },
                    ),
                    ChoiceChip(
                      avatar: const Icon(Icons.computer, size: 16),
                      label: const Text('Local Ollama'),
                      selected: _aiProvider == 'ollama',
                      onSelected: (selected) {
                        if (selected) setState(() => _aiProvider = 'ollama');
                      },
                    ),
                    ChoiceChip(
                      avatar: const Icon(Icons.flash_on, size: 16),
                      label: const Text('OpenAI / Groq'),
                      selected: _aiProvider == 'custom_openai',
                      onSelected: (selected) {
                        if (selected) setState(() => _aiProvider = 'custom_openai');
                      },
                    ),
                    ChoiceChip(
                      avatar: const Icon(Icons.auto_awesome, size: 16),
                      label: const Text('Gemini API'),
                      selected: _aiProvider == 'gemini',
                      onSelected: (selected) {
                        if (selected) setState(() => _aiProvider = 'gemini');
                      },
                    ),
                  ],
                ),
                const SizedBox(height: 14),

                if (_aiProvider == 'offline') ...[
                  Container(
                    padding: const EdgeInsets.all(12),
                    decoration: BoxDecoration(
                      color: const Color(0xFFF0FDF4),
                      borderRadius: BorderRadius.circular(12),
                      border: Border.all(color: const Color(0xFF86EFAC)),
                    ),
                    child: const Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Row(
                          children: [
                            Icon(Icons.check_circle, color: Color(0xFF15803D), size: 18),
                            SizedBox(width: 8),
                            Text(
                              '100% Free On-Device Deterministic RAG',
                              style: TextStyle(
                                fontWeight: FontWeight.bold,
                                color: Color(0xFF15803D),
                              ),
                            ),
                          ],
                        ),
                        SizedBox(height: 6),
                        Text(
                          '• \$0.00 API cost — no credit card, account, or API key needed.\n'
                          '• Instant bedside response (< 5ms latency) with zero network dependency.\n'
                          '• 100% HIPAA-compliant: clinical queries and vitals never leave the device.\n'
                          '• Grounded in verified medical knowledge for ALS, stroke, dysreflexia, seizures, and safe hydration.',
                          style: TextStyle(fontSize: 12, color: Color(0xFF166534), height: 1.4),
                        ),
                      ],
                    ),
                  ),
                ] else if (_aiProvider == 'ollama') ...[
                  TextField(
                    controller: _customBaseUrlController,
                    decoration: const InputDecoration(
                      labelText: 'Ollama Endpoint URL',
                      hintText: 'http://10.0.2.2:11434/v1 or http://192.168.1.X:11434/v1',
                      prefixIcon: Icon(Icons.link, color: Color(0xFF0B756A)),
                      helperText: 'Zero token cost. Runs on local bedside PC or ward server.',
                    ),
                  ),
                  const SizedBox(height: 10),
                  TextField(
                    controller: _customModelController,
                    decoration: const InputDecoration(
                      labelText: 'Ollama Model',
                      hintText: 'llama3.2:3b, qwen2.5:3b, gemma2:2b',
                      prefixIcon: Icon(Icons.memory, color: Color(0xFF0B756A)),
                    ),
                  ),
                ] else if (_aiProvider == 'custom_openai') ...[
                  TextField(
                    controller: _customBaseUrlController,
                    decoration: const InputDecoration(
                      labelText: 'API Base URL',
                      hintText: 'https://api.groq.com/openai/v1',
                      prefixIcon: Icon(Icons.cloud_queue, color: Color(0xFF0B756A)),
                    ),
                  ),
                  const SizedBox(height: 10),
                  TextField(
                    controller: _customModelController,
                    decoration: const InputDecoration(
                      labelText: 'Model Name',
                      hintText: 'llama-3.1-8b-instant, deepseek-chat',
                      prefixIcon: Icon(Icons.smart_toy, color: Color(0xFF0B756A)),
                    ),
                  ),
                  const SizedBox(height: 10),
                  TextField(
                    controller: _customApiKeyController,
                    obscureText: _obscureCustomKey,
                    decoration: InputDecoration(
                      labelText: 'API Key',
                      prefixIcon: const Icon(Icons.key, color: Color(0xFF0B756A)),
                      suffixIcon: IconButton(
                        icon: Icon(_obscureCustomKey ? Icons.visibility : Icons.visibility_off),
                        onPressed: () => setState(() => _obscureCustomKey = !_obscureCustomKey),
                      ),
                    ),
                  ),
                ] else if (_aiProvider == 'gemini') ...[
                  TextField(
                    controller: _geminiKeyController,
                    obscureText: _obscureGeminiKey,
                    decoration: InputDecoration(
                      labelText: 'Gemini API Key',
                      hintText: 'AIzaSy...',
                      prefixIcon: const Icon(Icons.key, color: Color(0xFF0B756A)),
                      suffixIcon: IconButton(
                        icon: Icon(
                          _obscureGeminiKey
                              ? Icons.visibility
                              : Icons.visibility_off,
                          color: const Color(0xFF556E68),
                        ),
                        onPressed: () => setState(
                            () => _obscureGeminiKey = !_obscureGeminiKey),
                      ),
                      helperText: 'Optional key from Google AI Studio (aistudio.google.com)',
                    ),
                  ),
                ],

                const SizedBox(height: 14),
                FilledButton.icon(
                  style: FilledButton.styleFrom(
                    backgroundColor: const Color(0xFF0B756A),
                  ),
                  onPressed: _saveAiSettings,
                  icon: const Icon(Icons.save, size: 18),
                  label: const Text('Save AI Engine Settings'),
                ),
              ],
            ),
          ),
        ),

        const SizedBox(height: 16),

        // Care Routines & Hydration Reminders Card
        Card(
          color: Colors.white,
          shape:
              RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Text(
                  'Continuous Care Routines',
                  style: Theme.of(context).textTheme.titleLarge,
                ),
                const SizedBox(height: 4),
                const Text(
                  'Automatic periodic reminders and reassuring wellness check-ins managed entirely locally.',
                  style: TextStyle(fontSize: 13, color: Color(0xFF556E68)),
                ),
                const SizedBox(height: 12),

                // Hydration Settings
                ListTile(
                  contentPadding: EdgeInsets.zero,
                  leading: const CircleAvatar(
                    backgroundColor: Color(0xFFD9F1EC),
                    child: Icon(Icons.water_drop, color: Color(0xFF0B756A)),
                  ),
                  title: const Text('Hydration Reminders',
                      style: TextStyle(fontWeight: FontWeight.bold)),
                  subtitle: Text(
                      'Interval: ${widget.services.reminders.settings.hydration.intervalMinutes} min • Active ${widget.services.reminders.settings.hydration.activeFrom}–${widget.services.reminders.settings.hydration.activeUntil}'),
                  trailing: Switch(
                    value: widget.services.reminders.settings.hydration.enabled,
                    onChanged: (val) async {
                      await widget.services.reminders
                          .setWaterRemindersEnabled(val);
                      setState(() {});
                    },
                  ),
                ),
                if (widget.services.reminders.settings.hydration.enabled) ...[
                  Row(children: [
                    const Icon(Icons.timer, size: 16, color: Color(0xFF0B756A)),
                    const SizedBox(width: 6),
                    Text(
                        'Hydration Interval: ${widget.services.reminders.settings.hydration.intervalMinutes} minutes',
                        style: const TextStyle(
                            fontSize: 13, fontWeight: FontWeight.w600)),
                  ]),
                  Slider(
                    value: widget
                        .services.reminders.settings.hydration.intervalMinutes
                        .toDouble(),
                    min: 15,
                    max: 360,
                    divisions: 23,
                    label:
                        '${widget.services.reminders.settings.hydration.intervalMinutes}m',
                    onChanged: (val) {
                      final updated =
                          widget.services.reminders.settings.copyWith(
                        hydration: widget.services.reminders.settings.hydration
                            .copyWith(intervalMinutes: val.round()),
                      );
                      widget.services.reminders.saveSettings(updated);
                      setState(() {});
                    },
                  ),
                ],
                const Divider(),

                // Check-Ins Settings
                ListTile(
                  contentPadding: EdgeInsets.zero,
                  leading: const CircleAvatar(
                    backgroundColor: Color(0xFFFBE4E8),
                    child: Icon(Icons.favorite, color: Color(0xFFC04B67)),
                  ),
                  title: const Text('Reassuring Wellness Check-Ins',
                      style: TextStyle(fontWeight: FontWeight.bold)),
                  subtitle: Text(
                      'Interval: ${widget.services.reminders.settings.checkIns.intervalMinutes} min • Active ${widget.services.reminders.settings.checkIns.activeFrom}–${widget.services.reminders.settings.checkIns.activeUntil}'),
                  trailing: Switch(
                    value: widget.services.reminders.settings.checkIns.enabled,
                    onChanged: (val) async {
                      final updated =
                          widget.services.reminders.settings.copyWith(
                        checkIns: widget.services.reminders.settings.checkIns
                            .copyWith(enabled: val),
                      );
                      await widget.services.reminders.saveSettings(updated);
                      setState(() {});
                    },
                  ),
                ),
                if (widget.services.reminders.settings.checkIns.enabled) ...[
                  Row(children: [
                    const Icon(Icons.timer, size: 16, color: Color(0xFFC04B67)),
                    const SizedBox(width: 6),
                    Text(
                        'Check-in Interval: ${widget.services.reminders.settings.checkIns.intervalMinutes} minutes',
                        style: const TextStyle(
                            fontSize: 13, fontWeight: FontWeight.w600)),
                  ]),
                  Slider(
                    value: widget
                        .services.reminders.settings.checkIns.intervalMinutes
                        .toDouble(),
                    min: 5,
                    max: 240,
                    divisions: 47,
                    label:
                        '${widget.services.reminders.settings.checkIns.intervalMinutes}m',
                    onChanged: (val) {
                      final updated =
                          widget.services.reminders.settings.copyWith(
                        checkIns: widget.services.reminders.settings.checkIns
                            .copyWith(intervalMinutes: val.round()),
                      );
                      widget.services.reminders.saveSettings(updated);
                      setState(() {});
                    },
                  ),
                ],

                const SizedBox(height: 8),
                Row(
                  children: [
                    Expanded(
                      child: OutlinedButton.icon(
                        onPressed: () async {
                          await widget.services.reminders.remindNow();
                          await widget.services.voice.speakAsha(
                            widget.services.reminders.settings.hydrationMessage,
                            force: true,
                          );
                          if (context.mounted) {
                            ScaffoldMessenger.of(context).showSnackBar(
                              const SnackBar(
                                  content: Text(
                                      'Hydration reminder triggered & spoken.')),
                            );
                          }
                        },
                        icon: const Icon(Icons.water_drop, size: 16),
                        label: const Text('Test Water'),
                      ),
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: OutlinedButton.icon(
                        onPressed: () async {
                          await widget.services.reminders.checkInNow();
                          await widget.services.voice.speakAsha(
                            widget.services.reminders.settings.checkInMessages
                                .first,
                            force: true,
                          );
                          if (context.mounted) {
                            ScaffoldMessenger.of(context).showSnackBar(
                              const SnackBar(
                                  content: Text(
                                      'Check-in message triggered & spoken.')),
                            );
                          }
                        },
                        icon: const Icon(Icons.favorite, size: 16),
                        label: const Text('Test Check-In'),
                      ),
                    ),
                  ],
                ),
              ],
            ),
          ),
        ),
        const SizedBox(height: 16),

        // Profile Management & Backup Card
        Card(
          color: Colors.white,
          shape:
              RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Text(
                  'Profile & Gesture Model Management',
                  style: Theme.of(context).textTheme.titleLarge,
                ),
                const SizedBox(height: 4),
                const Text(
                  'Choose between standard factory database thresholds or individual patient calibrated profile.',
                  style: TextStyle(fontSize: 13, color: Color(0xFF556E68)),
                ),
                const SizedBox(height: 12),
                SegmentedButton<bool>(
                  segments: const [
                    ButtonSegment<bool>(
                      value: false,
                      label: Text('Standard Database Model'),
                      icon: Icon(Icons.storage),
                    ),
                    ButtonSegment<bool>(
                      value: true,
                      label: Text('Custom Patient Profile'),
                      icon: Icon(Icons.person),
                    ),
                  ],
                  selected: {widget.services.recognition.isCustomMode},
                  onSelectionChanged: (set) async {
                    final custom = set.first;
                    if (!custom) {
                      await widget.services.useStandardCalibrationProfile();
                    } else {
                      await widget.services.recognition.setCustomMode(true);
                    }
                    if (mounted) setState(() {});
                  },
                ),
                const SizedBox(height: 14),
                Row(
                  children: [
                    Expanded(
                      child: OutlinedButton.icon(
                        onPressed: _showExportDialog,
                        icon: const Icon(Icons.file_download_outlined),
                        label: const Text('Export Profile'),
                      ),
                    ),
                    const SizedBox(width: 10),
                    Expanded(
                      child: OutlinedButton.icon(
                        onPressed: _showImportDialog,
                        icon: const Icon(Icons.file_upload_outlined),
                        label: const Text('Import Profile'),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 8),
                TextButton.icon(
                  onPressed: () async {
                    await widget.services.useStandardCalibrationProfile();
                    if (mounted) {
                      setState(() {});
                    }
                    if (context.mounted) {
                      ScaffoldMessenger.of(context).showSnackBar(
                        const SnackBar(
                            content: Text(
                                'Reset phrases and face baseline to the factory AAC profile.')),
                      );
                    }
                  },
                  icon: const Icon(Icons.restart_alt, size: 16),
                  label:
                      const Text('Reset All Calibration to Factory Baseline'),
                ),
              ],
            ),
          ),
        ),
        const SizedBox(height: 16),

        // Cloud Privacy & Profile Sync Card
        ListenableBuilder(
          listenable: widget.services.cloudSync,
          builder: (context, _) {
            final sync = widget.services.cloudSync;
            final profileId = sync.remoteProfileId;
            return Card(
              color: Colors.white,
              shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(16)),
              child: Padding(
                padding: const EdgeInsets.all(16),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Row(
                      children: [
                        const Icon(Icons.cloud_sync, color: Color(0xFF0B756A)),
                        const SizedBox(width: 8),
                        Text(
                          'Cloud Privacy & Caregiver Sync',
                          style: Theme.of(context).textTheme.titleLarge,
                        ),
                      ],
                    ),
                    const SizedBox(height: 4),
                    const Text(
                      'Zero-knowledge telemetry and voluntary alert sharing with authorized caregivers.',
                      style: TextStyle(fontSize: 13, color: Color(0xFF556E68)),
                    ),
                    const SizedBox(height: 12),

                    // Remote Profile UUID
                    if (profileId != null) ...[
                      Container(
                        padding: const EdgeInsets.all(12),
                        decoration: BoxDecoration(
                          color: const Color(0xFFE8F6F3),
                          borderRadius: BorderRadius.circular(10),
                          border: Border.all(color: const Color(0xFFA6E3D9)),
                        ),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            const Text(
                              'Patient Profile ID (Share with Caregiver):',
                              style: TextStyle(
                                  fontSize: 11,
                                  fontWeight: FontWeight.bold,
                                  color: Color(0xFF0B756A)),
                            ),
                            const SizedBox(height: 4),
                            Row(
                              children: [
                                Expanded(
                                  child: SelectableText(
                                    profileId,
                                    style: const TextStyle(
                                        fontFamily: 'monospace',
                                        fontSize: 12,
                                        fontWeight: FontWeight.bold),
                                  ),
                                ),
                                IconButton(
                                  icon: const Icon(Icons.copy, size: 18),
                                  tooltip: 'Copy Profile ID',
                                  onPressed: () {
                                    Clipboard.setData(
                                        ClipboardData(text: profileId));
                                    ScaffoldMessenger.of(context).showSnackBar(
                                      const SnackBar(
                                        content: Text(
                                            'Profile ID copied to clipboard!'),
                                      ),
                                    );
                                  },
                                ),
                              ],
                            ),
                          ],
                        ),
                      ),
                      const SizedBox(height: 12),
                    ],

                    // Consent Toggle 1
                    SwitchListTile(
                      contentPadding: EdgeInsets.zero,
                      value: sync.consentToEventSync,
                      onChanged: (val) =>
                          sync.setConsent(consentToEventSync: val),
                      title: const Text('Share Confirmed Activity',
                          style: TextStyle(
                              fontWeight: FontWeight.bold, fontSize: 14)),
                      subtitle: const Text(
                          'Opaque gesture keys and timestamps only. Zero raw video.'),
                    ),
                    const Divider(),

                    // Consent Toggle 2
                    SwitchListTile(
                      contentPadding: EdgeInsets.zero,
                      value: sync.consentToCaregiverAlerts,
                      onChanged: (val) =>
                          sync.setConsent(consentToCaregiverAlerts: val),
                      title: const Text('Send Caregiver Cloud Alerts',
                          style: TextStyle(
                              fontWeight: FontWeight.bold, fontSize: 14)),
                      subtitle: const Text(
                          'Allows urgent and emergency spoken phrases to reach approved caregivers.'),
                    ),
                    const SizedBox(height: 12),

                    SizedBox(
                      height: 46,
                      child: FilledButton.tonalIcon(
                        onPressed: sync.isSyncing
                            ? null
                            : () async {
                                await sync.ensureLinked();
                                if (context.mounted) {
                                  ScaffoldMessenger.of(context).showSnackBar(
                                    const SnackBar(
                                      content: Text(
                                          'Profile synced with cloud backend.'),
                                      backgroundColor: Color(0xFF0B756A),
                                    ),
                                  );
                                }
                              },
                        icon: sync.isSyncing
                            ? const SizedBox(
                                width: 16,
                                height: 16,
                                child:
                                    CircularProgressIndicator(strokeWidth: 2),
                              )
                            : const Icon(Icons.sync),
                        label: Text(profileId != null
                            ? 'Sync Profile & Consent Now'
                            : 'Link & Register Cloud Profile'),
                      ),
                    ),
                  ],
                ),
              ),
            );
          },
        ),
      ],
    );
  }

  void _showExportDialog() {
    final jsonText = widget.services.recognition.exportProfileJson();
    showDialog<void>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Export Patient Profile'),
        content: SizedBox(
          width: double.maxFinite,
          child: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                const Text(
                    'Copy this JSON configuration to backup or transfer:'),
                const SizedBox(height: 8),
                Container(
                  padding: const EdgeInsets.all(12),
                  decoration: BoxDecoration(
                    color: const Color(0xFFF4F8F7),
                    borderRadius: BorderRadius.circular(8),
                    border: Border.all(color: const Color(0xFFD0E4E0)),
                  ),
                  child: SelectableText(
                    jsonText,
                    style:
                        const TextStyle(fontFamily: 'monospace', fontSize: 11),
                  ),
                ),
              ],
            ),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: const Text('Close'),
          ),
          FilledButton.icon(
            onPressed: () async {
              await Clipboard.setData(ClipboardData(text: jsonText));
              if (context.mounted) {
                Navigator.of(context).pop();
                ScaffoldMessenger.of(context).showSnackBar(
                  const SnackBar(
                    content: Text('Profile JSON copied to clipboard!'),
                    backgroundColor: Color(0xFF0B756A),
                  ),
                );
              }
            },
            icon: const Icon(Icons.copy, size: 16),
            label: const Text('Copy JSON'),
          ),
        ],
      ),
    );
  }

  void _showImportDialog() {
    final importController = TextEditingController();
    showDialog<void>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Import Patient Profile'),
        content: SizedBox(
          width: double.maxFinite,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              const Text('Paste a valid NeuroBridge Asha profile JSON below:'),
              const SizedBox(height: 8),
              TextField(
                controller: importController,
                minLines: 4,
                maxLines: 8,
                style: const TextStyle(fontFamily: 'monospace', fontSize: 12),
                decoration: const InputDecoration(
                  hintText:
                      '{\n  "schema_version": "fingerspeak-v1",\n  ...\n}',
                ),
              ),
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () async {
              final text = importController.text.trim();
              if (text.isEmpty) return;
              try {
                final count =
                    await widget.services.importCalibrationProfile(text);
                if (context.mounted) {
                  Navigator.of(context).pop();
                  setState(() {});
                  ScaffoldMessenger.of(context).showSnackBar(
                    SnackBar(
                      content: Text('Successfully imported $count phrases!'),
                      backgroundColor: const Color(0xFF0B756A),
                    ),
                  );
                }
              } catch (e) {
                if (context.mounted) {
                  ScaffoldMessenger.of(context).showSnackBar(
                    SnackBar(
                      content: Text('Import failed: $e'),
                      backgroundColor: Colors.redAccent,
                    ),
                  );
                }
              }
            },
            child: const Text('Import'),
          ),
        ],
      ),
    );
  }

  String _piStateLabel(PiConnectionState state) => switch (state) {
        PiConnectionState.disconnected => 'Not connected (Offline)',
        PiConnectionState.connecting => 'Connecting over WebSocket / USB…',
        PiConnectionState.authenticating =>
          'Authenticating with Wheelchair Pi…',
        PiConnectionState.connected =>
          'Connected and synced to wheelchair display',
        PiConnectionState.error =>
          'Connection error — check Wi-Fi / Hotspot / USB',
      };
}

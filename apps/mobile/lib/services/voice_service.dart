import 'dart:convert';

import 'package:flutter_tts/flutter_tts.dart';
import 'package:just_audio/just_audio.dart';
import 'package:path_provider/path_provider.dart';
import 'package:record/record.dart';
import 'package:shared_preferences/shared_preferences.dart';

enum PhraseVoiceMode { asha, caregiverRecording }

/// Playback preference matches the web PatientSpeechSettings:
///   caregiverRecordingFirst → play caregiver audio first, TTS as fallback
///   systemVoiceOnly        → TTS only (web: "system-voice")
enum PlaybackPreference { caregiverRecordingFirst, systemVoiceOnly }

enum CaregiverRecordingPlayback { played, missing, failed }

enum PatientPhrasePlayback { caregiverRecording, systemVoice, unavailable }

class VoicePreferences {
  const VoicePreferences({
    this.automaticallySpeak = true,
    this.phraseMode = PhraseVoiceMode.caregiverRecording,
    this.ttsVoiceName = 'Samantha',
    this.speechRate = 0.50,
    this.pitch = 1.00,
    this.volume = 1.0,
    this.playbackPreference = PlaybackPreference.caregiverRecordingFirst,
  });


  final bool automaticallySpeak;
  final PhraseVoiceMode phraseMode;
  final String? ttsVoiceName;
  final double speechRate;
  final double pitch;
  final double volume;
  final PlaybackPreference playbackPreference;

  VoicePreferences copyWith({
    bool? automaticallySpeak,
    PhraseVoiceMode? phraseMode,
    String? ttsVoiceName,
    bool clearTtsVoiceName = false,
    double? speechRate,
    double? pitch,
    double? volume,
    PlaybackPreference? playbackPreference,
  }) {
    return VoicePreferences(
      automaticallySpeak: automaticallySpeak ?? this.automaticallySpeak,
      phraseMode: phraseMode ?? this.phraseMode,
      ttsVoiceName:
          clearTtsVoiceName ? null : (ttsVoiceName ?? this.ttsVoiceName),
      speechRate: speechRate ?? this.speechRate,
      pitch: pitch ?? this.pitch,
      volume: volume ?? this.volume,
      playbackPreference: playbackPreference ?? this.playbackPreference,
    );
  }
}

class SavedPhraseRecording {
  const SavedPhraseRecording({
    required this.path,
    required this.phraseSnapshot,
  });

  final String path;
  final String phraseSnapshot;

  bool matches(String phrase) => phraseSnapshot == phrase.trim();

  Map<String, String> toJson() => {
        'path': path,
        'phrase_snapshot': phraseSnapshot,
      };

  static SavedPhraseRecording? fromJson(Object? raw) {
    if (raw is! Map<String, Object?>) return null;
    final path = raw['path'];
    final snapshot = raw['phrase_snapshot'];
    if (path is! String || snapshot is! String || snapshot.isEmpty) return null;
    return SavedPhraseRecording(path: path, phraseSnapshot: snapshot);
  }
}

class HandStudioVoicePhrase {
  const HandStudioVoicePhrase({
    required this.key,
    required this.gestureName,
    required this.phrase,
  });

  final String key;
  final String gestureName;
  final String phrase;
}

class VoicePreferenceRepository {
  VoicePreferenceRepository(this._preferences);

  static const _autoKey = 'voice.auto_speak';
  static const _modeKey = 'voice.phrase_mode';
  static const _nameKey = 'voice.tts_name';
  static const _rateKey = 'voice.speech_rate';
  static const _pitchKey = 'voice.pitch';
  static const _volumeKey = 'voice.volume';
  static const _playbackPrefKey = 'voice.playback_preference';

  final SharedPreferences _preferences;

  VoicePreferences load() {
    final modeName = _preferences.getString(_modeKey);
    final playbackPrefName = _preferences.getString(_playbackPrefKey);
    return VoicePreferences(
      automaticallySpeak: _preferences.getBool(_autoKey) ?? true,
      phraseMode: PhraseVoiceMode.values.firstWhere(
        (mode) => mode.name == modeName,
        orElse: () => PhraseVoiceMode.caregiverRecording,
      ),
      ttsVoiceName: _preferences.getString(_nameKey) ?? 'Samantha',
      speechRate: _preferences.getDouble(_rateKey) ?? 0.50,
      pitch: _preferences.getDouble(_pitchKey) ?? 1.00,
      volume: _preferences.getDouble(_volumeKey) ?? 1.0,
      playbackPreference: PlaybackPreference.values.firstWhere(
        (p) => p.name == playbackPrefName,
        orElse: () => PlaybackPreference.caregiverRecordingFirst,
      ),
    );
  }

  Future<void> save(VoicePreferences value) async {
    await _preferences.setBool(_autoKey, value.automaticallySpeak);
    await _preferences.setString(_modeKey, value.phraseMode.name);
    await _preferences.setDouble(_rateKey, value.speechRate);
    await _preferences.setDouble(_pitchKey, value.pitch);
    await _preferences.setDouble(_volumeKey, value.volume);
    await _preferences.setString(
        _playbackPrefKey, value.playbackPreference.name);
    if (value.ttsVoiceName == null) {
      await _preferences.remove(_nameKey);
    } else {
      await _preferences.setString(_nameKey, value.ttsVoiceName!);
    }
  }
}

class RecordedPhraseRepository {
  RecordedPhraseRepository(
    this._preferences, {
    AudioRecorder? recorder,
  }) : _customRecorder = recorder;

  static const _pathsKey = 'voice.recorded_phrase_paths';
  static const _handStudioMetaKey = 'hand_studio.fingerspeak_model_meta';
  final SharedPreferences _preferences;
  final AudioRecorder? _customRecorder;
  AudioRecorder? _recorderInstance;
  AudioRecorder get _recorder =>
      _recorderInstance ??= (_customRecorder ?? AudioRecorder());
  String? _recordingKey;
  String? _recordingPhraseSnapshot;

  Map<String, SavedPhraseRecording> get recordings {
    final raw = _preferences.getString(_pathsKey);
    if (raw == null) return const {};
    try {
      final decoded = jsonDecode(raw);
      if (decoded is! Map<String, Object?>) return const {};
      return <String, SavedPhraseRecording>{
        for (final entry in decoded.entries)
          if (SavedPhraseRecording.fromJson(entry.value) case final recording?)
            entry.key: recording,
      };
    } on Object {
      return const {};
    }
  }

  bool hasRecording(String phraseKey, String phrase) =>
      recordings[phraseKey]?.matches(phrase) ?? false;

  List<HandStudioVoicePhrase> get handStudioPhrases {
    final raw = _preferences.getString(_handStudioMetaKey);
    if (raw == null || raw.isEmpty) return const [];
    try {
      final decoded = jsonDecode(raw);
      if (decoded is! Map) return const [];
      final root = Map<String, Object?>.from(decoded);
      final metaValue = root['meta'];
      final meta =
          metaValue is Map ? Map<String, Object?>.from(metaValue) : root;
      final gestures = meta['gestures'];
      if (gestures is! List) return const [];

      final seen = <String>{};
      final phrases = <HandStudioVoicePhrase>[];
      for (final value in gestures) {
        if (value is! Map) continue;
        final gesture = Map<String, Object?>.from(value);
        final gestureName = gesture['name']?.toString().trim() ?? '';
        final phrase = gesture['phrase']?.toString().trim() ?? '';
        if (gestureName.isEmpty ||
            gestureName.toLowerCase() == 'rest' ||
            phrase.isEmpty) {
          continue;
        }
        final key = 'gesture_$gestureName';
        if (!seen.add('$key\u0000$phrase')) continue;
        phrases.add(
          HandStudioVoicePhrase(
            key: key,
            gestureName: gestureName,
            phrase: phrase,
          ),
        );
      }
      return phrases;
    } on Object {
      return const [];
    }
  }

  String? pathFor(String phraseKey, String phrase) {
    final recording = recordings[phraseKey];
    if (recording == null || !recording.matches(phrase)) return null;
    return recording.path;
  }

  bool get isRecording => _recordingKey != null;

  Future<bool> start(String phraseKey, String phrase) async {
    final snapshot = phrase.trim();
    if (snapshot.isEmpty) {
      throw const FormatException('Enter the exact phrase before recording.');
    }
    if (!await _recorder.hasPermission()) return false;
    if (_recordingKey != null) await stop();
    final directory = await getApplicationDocumentsDirectory();
    final safeKey = phraseKey.replaceAll(RegExp('[^A-Za-z0-9_.-]'), '_');
    final path = '${directory.path}/caregiver-$safeKey.m4a';
    await _recorder.start(
      const RecordConfig(
        encoder: AudioEncoder.aacLc,
        bitRate: 96000,
        sampleRate: 44100,
      ),
      path: path,
    );
    _recordingKey = phraseKey;
    _recordingPhraseSnapshot = snapshot;
    return true;
  }

  Future<String?> stop() async {
    final key = _recordingKey;
    final snapshot = _recordingPhraseSnapshot;
    if (key == null || snapshot == null) return null;
    String? path;
    try {
      path = await _recorder.stop();
    } finally {
      _recordingKey = null;
      _recordingPhraseSnapshot = null;
    }
    if (path != null) {
      final updated = Map<String, SavedPhraseRecording>.from(recordings)
        ..[key] = SavedPhraseRecording(
          path: path,
          phraseSnapshot: snapshot,
        );
      await _preferences.setString(
        _pathsKey,
        jsonEncode(updated.map((key, value) => MapEntry(key, value.toJson()))),
      );
    }
    return path;
  }

  Future<void> delete(String phraseKey) async {
    final updated = Map<String, SavedPhraseRecording>.from(recordings)
      ..remove(phraseKey);
    await _preferences.setString(
      _pathsKey,
      jsonEncode(updated.map((key, value) => MapEntry(key, value.toJson()))),
    );
  }

  Future<void> cancel() async {
    if (_recordingKey == null) return;
    try {
      await _recorder.cancel();
    } finally {
      _recordingKey = null;
      _recordingPhraseSnapshot = null;
    }
  }

  Future<void> dispose() async {
    if (_recordingKey != null) await cancel();
    final rec = _recorderInstance;
    if (rec != null) await rec.dispose();
  }
}

class PatientVoiceService {
  PatientVoiceService({
    required VoicePreferenceRepository preferenceRepository,
    required this.recordings,
    FlutterTts? tts,
    AudioPlayer? audioPlayer,
  })  : _preferenceRepository = preferenceRepository,
        _tts = tts ?? FlutterTts(),
        _audioPlayer = audioPlayer ?? AudioPlayer(),
        preferences = preferenceRepository.load();

  final VoicePreferenceRepository _preferenceRepository;
  final FlutterTts _tts;
  final AudioPlayer _audioPlayer;
  final RecordedPhraseRepository recordings;
  VoicePreferences preferences;
  String _locale = 'en-US';

  Future<void> initialize({String locale = 'en-US'}) async {
    _locale = locale;
    try {
      try {
        await _tts.setIosAudioCategory(
          IosTextToSpeechAudioCategory.playback,
          [
            IosTextToSpeechAudioCategoryOptions.defaultToSpeaker,
            IosTextToSpeechAudioCategoryOptions.allowBluetooth,
            IosTextToSpeechAudioCategoryOptions.allowBluetoothA2DP,
            IosTextToSpeechAudioCategoryOptions.mixWithOthers,
          ],
          IosTextToSpeechAudioMode.defaultMode,
        );
      } catch (_) {}
      await _tts.setLanguage(locale);
      await _tts.setSpeechRate(preferences.speechRate);
      await _tts.setPitch(preferences.pitch);
      await _tts.awaitSpeakCompletion(true);
      final allVoices = await availableVoiceNames();

      // Look specifically for Samantha first
      String? voice = allVoices.cast<String?>().firstWhere(
            (v) => v != null && v.toLowerCase().contains('samantha'),
            orElse: () => null,
          );

      // If Samantha is not found, check if a custom voice was explicitly configured
      if (voice == null &&
          preferences.ttsVoiceName != null &&
          preferences.ttsVoiceName!.isNotEmpty) {
        if (allVoices.contains(preferences.ttsVoiceName)) {
          voice = preferences.ttsVoiceName;
        }
      }

      // Otherwise fall back to a clear natural female voice
      voice ??= allVoices.cast<String?>().firstWhere(
            (v) =>
                v != null &&
                RegExp(r'(female|zira|karen|victoria|eva|jenny|aria|sfg)',
                        caseSensitive: false)
                    .hasMatch(v),
            orElse: () => null,
          );
      if (voice != null) {
        await _tts.setVoice(<String, String>{'name': voice, 'locale': locale});
      }
    } on Object {
      // Some devices have no TTS engine installed. The visual app and recorded
      // caregiver phrases remain usable, and Android can install an engine later.
    }
  }

  Future<List<String>> availableVoiceNames() async {
    final raw = await _tts.getVoices;
    if (raw is! List) return const [];
    return raw
        .whereType<Map<Object?, Object?>>()
        .map((voice) => voice['name']?.toString())
        .whereType<String>()
        .toSet()
        .toList()
      ..sort();
  }

  Future<void> setPreferences(VoicePreferences next) async {
    preferences = next;
    await _preferenceRepository.save(next);
    try {
      await _tts.setSpeechRate(next.speechRate);
      await _tts.setPitch(next.pitch);
      await _tts.setVolume(next.volume);
      final voice = next.ttsVoiceName;
      if (voice == null) {
        await _tts.setLanguage(_locale);
      } else {
        String targetVoice = voice;
        if (voice.toLowerCase().contains('samantha')) {
          final allVoices = await availableVoiceNames();
          final sam = allVoices.cast<String?>().firstWhere(
                (v) => v != null && v.toLowerCase().contains('samantha'),
                orElse: () => null,
              );
          if (sam != null) targetVoice = sam;
        }
        await _tts.setVoice(<String, String>{
          'name': targetVoice,
          'locale': _locale,
        });
      }
    } on Object {
      // The preference remains saved even when a phone TTS engine is missing.
    }
  }

  Future<void> setCaregiverRecordingsPreferred(bool preferred) async {
    // This choice only changes which already-configured audio source is used.
    // Reconfiguring the platform TTS engine here can block the guided setup on
    // devices whose TTS service is still starting, even though the preference
    // has already been saved successfully.
    final next = preferences.copyWith(
      phraseMode: preferred
          ? PhraseVoiceMode.caregiverRecording
          : PhraseVoiceMode.asha,
      playbackPreference: preferred
          ? PlaybackPreference.caregiverRecordingFirst
          : PlaybackPreference.systemVoiceOnly,
    );
    preferences = next;
    await _preferenceRepository.save(next);
  }

  Future<void> speakAsha(String text, {bool force = false}) async {
    if (!force && !preferences.automaticallySpeak) return;
    try {
      await _audioPlayer.stop();
      await _tts.stop();
      await _tts.speak(text).timeout(const Duration(seconds: 2));
    } on Object {
      // The message remains visible if audio output is unavailable.
    }
  }

  Future<void> speakSystemPrompt(String text) => speakAsha(text, force: true);

  Future<bool> startCaregiverRecording(
    String phraseKey,
    String phrase,
  ) async {
    await _stopPlayback();
    return recordings.start(phraseKey, phrase);
  }

  Future<String?> stopCaregiverRecording() => recordings.stop();

  Future<void> cancelCaregiverRecording() => recordings.cancel();

  /// Plays the caregiver's exact saved recording regardless of the patient's
  /// normal playback preference. This is used to verify a recording while
  /// calibrating it.
  Future<CaregiverRecordingPlayback> previewCaregiverRecording(
    String phraseKey,
    String phrase,
  ) async {
    final recording = recordings.pathFor(phraseKey, phrase);
    if (recording == null) return CaregiverRecordingPlayback.missing;
    return await _playRecordedFile(recording)
        ? CaregiverRecordingPlayback.played
        : CaregiverRecordingPlayback.failed;
  }

  /// Speaks a calibrated patient phrase immediately.
  /// Playback order: if [playbackPreference] is caregiverRecordingFirst (default),
  /// caregiver audio is used when available; otherwise TTS is used directly.
  Future<PatientPhrasePlayback> speakPhrase(
    String phraseKey,
    String text,
  ) async {
    final recording = recordings.pathFor(phraseKey, text);
    if (preferences.playbackPreference ==
            PlaybackPreference.caregiverRecordingFirst &&
        recording != null &&
        await _playRecordedFile(recording)) {
      return PatientPhrasePlayback.caregiverRecording;
    }

    // A missing, damaged, or temporarily unplayable recording must never make
    // an assistive phrase silent. Fall back to the configured system voice.
    await _stopPlayback();
    try {
      await _tts.speak(text).timeout(const Duration(seconds: 2));
      return PatientPhrasePlayback.systemVoice;
    } on Object {
      // The Pi/display caption is still sent by the trigger controller.
      return PatientPhrasePlayback.unavailable;
    }
  }

  Future<bool> _playRecordedFile(String path) async {
    await _stopPlayback();
    try {
      await _audioPlayer.setVolume(preferences.volume);
      await _audioPlayer.setFilePath(path);
      await _audioPlayer.play();
      return true;
    } on Object {
      return false;
    }
  }

  Future<void> _stopPlayback() async {
    try {
      await _tts.stop();
    } on Object {
      // Continue so one unavailable audio engine cannot block the other.
    }
    try {
      await _audioPlayer.stop();
    } on Object {
      // Best effort; the next load can still recover the player.
    }
  }

  Future<void> dispose() async {
    try {
      await _tts.stop().timeout(const Duration(milliseconds: 500));
    } on Object {
      // Ignore during test/teardown.
    }
    try {
      await _audioPlayer.dispose().timeout(const Duration(milliseconds: 500));
    } on Object {
      // Ignore during test/teardown.
    }
    try {
      await recordings.dispose();
    } on Object {
      // Ignore during test/teardown.
    }
  }
}

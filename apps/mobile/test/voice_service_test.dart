import 'dart:convert';

import 'package:fingerspeak_mobile/services/voice_service.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_tts/flutter_tts.dart';
import 'package:just_audio/just_audio.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues({});
  });

  test('damaged caregiver audio falls back to system speech', () async {
    final preferences = await SharedPreferences.getInstance();
    await _saveRecordingMetadata(preferences);
    final tts = _FakeFlutterTts();
    final player = _FakeAudioPlayer(failToLoad: true);
    final service = PatientVoiceService(
      preferenceRepository: VoicePreferenceRepository(preferences),
      recordings: RecordedPhraseRepository(preferences),
      tts: tts,
      audioPlayer: player,
    );

    final result = await service.speakPhrase('blink', 'I need some help');

    expect(result, PatientPhrasePlayback.systemVoice);
    expect(player.loadedPath, 'private/caregiver-blink.m4a');
    expect(tts.spoken, ['I need some help']);
    await service.dispose();
  });

  test('missing caregiver audio safely uses system speech', () async {
    final preferences = await SharedPreferences.getInstance();
    final tts = _FakeFlutterTts();
    final player = _FakeAudioPlayer();
    final service = PatientVoiceService(
      preferenceRepository: VoicePreferenceRepository(preferences),
      recordings: RecordedPhraseRepository(preferences),
      tts: tts,
      audioPlayer: player,
    );

    final result = await service.speakPhrase('blink', 'I need some help');

    expect(result, PatientPhrasePlayback.systemVoice);
    expect(player.loadedPath, isNull);
    expect(tts.spoken, ['I need some help']);
    await service.dispose();
  });

  test('global system voice choice bypasses an available recording', () async {
    final preferences = await SharedPreferences.getInstance();
    await _saveRecordingMetadata(preferences);
    await preferences.setString(
      'voice.playback_preference',
      PlaybackPreference.systemVoiceOnly.name,
    );
    final tts = _FakeFlutterTts();
    final player = _FakeAudioPlayer();
    final service = PatientVoiceService(
      preferenceRepository: VoicePreferenceRepository(preferences),
      recordings: RecordedPhraseRepository(preferences),
      tts: tts,
      audioPlayer: player,
    );

    final result = await service.speakPhrase('blink', 'I need some help');

    expect(result, PatientPhrasePlayback.systemVoice);
    expect(player.loadedPath, isNull);
    expect(tts.spoken, ['I need some help']);
    await service.dispose();
  });

  test('caregiver recording can be previewed directly', () async {
    final preferences = await SharedPreferences.getInstance();
    await _saveRecordingMetadata(preferences);
    final tts = _FakeFlutterTts();
    final player = _FakeAudioPlayer();
    final service = PatientVoiceService(
      preferenceRepository: VoicePreferenceRepository(preferences),
      recordings: RecordedPhraseRepository(preferences),
      tts: tts,
      audioPlayer: player,
    );

    final result = await service.previewCaregiverRecording(
      'blink',
      'I need some help',
    );

    expect(result, CaregiverRecordingPlayback.played);
    expect(player.played, isTrue);
    expect(player.configuredVolume, 1.0);
    expect(tts.spoken, isEmpty);
    await service.dispose();
  });

  test('preview reports when no recording matches the edited phrase', () async {
    final preferences = await SharedPreferences.getInstance();
    await _saveRecordingMetadata(preferences);
    final service = PatientVoiceService(
      preferenceRepository: VoicePreferenceRepository(preferences),
      recordings: RecordedPhraseRepository(preferences),
      tts: _FakeFlutterTts(),
      audioPlayer: _FakeAudioPlayer(),
    );

    final result = await service.previewCaregiverRecording(
      'blink',
      'These words have changed',
    );

    expect(result, CaregiverRecordingPlayback.missing);
    await service.dispose();
  });

  test('damaged recording metadata is ignored instead of breaking voice',
      () async {
    final preferences = await SharedPreferences.getInstance();
    await preferences.setString(
      'voice.recorded_phrase_paths',
      '{not valid json',
    );

    final recordings = RecordedPhraseRepository(preferences);

    expect(recordings.recordings, isEmpty);
    expect(recordings.pathFor('blink', 'I need some help'), isNull);
    await recordings.dispose();
  });

  test('global caregiver voice preference is applied and persisted', () async {
    final preferences = await SharedPreferences.getInstance();
    final repository = VoicePreferenceRepository(preferences);
    final service = PatientVoiceService(
      preferenceRepository: repository,
      recordings: RecordedPhraseRepository(preferences),
      tts: _FakeFlutterTts(),
      audioPlayer: _FakeAudioPlayer(),
    );

    await service.setCaregiverRecordingsPreferred(false);
    expect(
      service.preferences.playbackPreference,
      PlaybackPreference.systemVoiceOnly,
    );
    expect(service.preferences.phraseMode, PhraseVoiceMode.asha);
    expect(
      repository.load().playbackPreference,
      PlaybackPreference.systemVoiceOnly,
    );

    await service.setCaregiverRecordingsPreferred(true);
    expect(
      repository.load().playbackPreference,
      PlaybackPreference.caregiverRecordingFirst,
    );
    expect(repository.load().phraseMode, PhraseVoiceMode.caregiverRecording);
    await service.dispose();
  });

  test('Hand Studio voice phrases exclude rest and exact duplicates', () async {
    final preferences = await SharedPreferences.getInstance();
    await preferences.setString(
      'hand_studio.fingerspeak_model_meta',
      jsonEncode({
        'gestures': [
          {'name': 'Rest', 'phrase': ''},
          {'name': 'Water', 'phrase': 'I need water, please.'},
          {'name': 'Water', 'phrase': 'I need water, please.'},
          {'name': 'Water', 'phrase': 'Please bring water.'},
          {'name': 'Empty', 'phrase': '   '},
        ],
      }),
    );

    final phrases = RecordedPhraseRepository(preferences).handStudioPhrases;

    expect(phrases, hasLength(2));
    expect(phrases.map((phrase) => phrase.key), everyElement('gesture_Water'));
    expect(
      phrases.map((phrase) => phrase.phrase),
      ['I need water, please.', 'Please bring water.'],
    );
  });

  test(
      'Asha voice initializes with Samantha, normal speech rate, and normal pitch',
      () async {
    final preferences = await SharedPreferences.getInstance();
    final tts = _FakeFlutterTts();
    final player = _FakeAudioPlayer();
    final service = PatientVoiceService(
      preferenceRepository: VoicePreferenceRepository(preferences),
      recordings: RecordedPhraseRepository(preferences),
      tts: tts,
      audioPlayer: player,
    );

    await service.initialize();

    expect(tts.speechRate, 0.50); // Normal speech rate
    expect(tts.pitch, 1.00); // Normal pitch
    expect(tts.configuredVoice?['name'],
        'com.apple.voice.compact.en-US.Samantha');
    await service.dispose();
  });
}

Future<void> _saveRecordingMetadata(SharedPreferences preferences) {
  return preferences.setString(
    'voice.recorded_phrase_paths',
    jsonEncode({
      'blink': {
        'path': 'private/caregiver-blink.m4a',
        'phrase_snapshot': 'I need some help',
      },
    }),
  );
}

class _FakeAudioPlayer implements AudioPlayer {
  _FakeAudioPlayer({this.failToLoad = false});

  final bool failToLoad;
  String? loadedPath;
  bool played = false;
  double? configuredVolume;

  @override
  Future<void> dispose() async {}

  @override
  Future<void> play() async {
    played = true;
  }

  @override
  Future<Duration?> setFilePath(
    String filePath, {
    Duration? initialPosition,
    bool preload = true,
    dynamic tag,
  }) async {
    loadedPath = filePath;
    if (failToLoad) throw StateError('The saved audio is damaged.');
    return const Duration(seconds: 1);
  }

  @override
  Future<void> setVolume(double volume) async {
    configuredVolume = volume;
  }

  @override
  Future<void> stop() async {}

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _FakeFlutterTts implements FlutterTts {
  final List<String> spoken = [];
  double? speechRate;
  double? pitch;
  Map<String, String>? configuredVoice;
  List<dynamic> voices = [
    {'name': 'com.apple.voice.compact.en-US.Samantha', 'locale': 'en-US'},
    {'name': 'en-us-x-sfg-network', 'locale': 'en-US'},
  ];

  @override
  Future<dynamic> get getVoices async => voices;

  @override
  Future<dynamic> setSpeechRate(double rate) async {
    speechRate = rate;
    return 1;
  }

  @override
  Future<dynamic> setPitch(double p) async {
    pitch = p;
    return 1;
  }

  @override
  Future<dynamic> setVoice(Map<String, String> voice) async {
    configuredVoice = voice;
    return 1;
  }

  @override
  Future<dynamic> setLanguage(String language) async => 1;

  @override
  Future<dynamic> awaitSpeakCompletion(bool awaitCompletion) async => 1;

  @override
  Future<dynamic> speak(String text, {bool focus = false}) async {
    spoken.add(text);
    return 1;
  }

  @override
  Future<dynamic> stop() async => 1;

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

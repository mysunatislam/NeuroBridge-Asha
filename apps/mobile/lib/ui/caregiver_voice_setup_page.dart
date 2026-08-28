import 'dart:async';

import 'package:fingerspeak_mobile/core/mobile_services.dart';
import 'package:fingerspeak_mobile/models/patient_signal.dart';
import 'package:fingerspeak_mobile/services/voice_service.dart';
import 'package:flutter/material.dart';

class CaregiverVoiceSetupPage extends StatefulWidget {
  const CaregiverVoiceSetupPage({required this.services, super.key});

  final MobileServices services;

  @override
  State<CaregiverVoiceSetupPage> createState() =>
      _CaregiverVoiceSetupPageState();
}

class _CaregiverVoiceSetupPageState extends State<CaregiverVoiceSetupPage> {
  bool _caregiverConfirmed = false;
  bool _updatingPreference = false;
  String? _recordingKey;
  String? _recordingPhrase;
  String? _busyKey;
  String? _previewingKey;
  String? _testingKey;
  int? _guidedIndex;

  List<_VoicePhrase> get _phrases {
    final combined = <_VoicePhrase>[];
    final seen = <String>{};

    void add(_VoicePhrase phrase) {
      if (seen.add('${phrase.key}\u0000${phrase.phrase}')) combined.add(phrase);
    }

    for (final phrase in widget.services.recognition.phrases) {
      add(
        _VoicePhrase(
          key: phrase.key,
          phrase: phrase.phrase,
          sourceLabel: phrase.signal.displayName,
        ),
      );
    }
    for (final phrase in widget.services.voice.recordings.handStudioPhrases) {
      add(
        _VoicePhrase(
          key: phrase.key,
          phrase: phrase.phrase,
          sourceLabel: 'MediaPipe Hand Studio • ${phrase.gestureName}',
        ),
      );
    }
    return combined;
  }

  bool get _caregiverRecordingsPreferred =>
      widget.services.voice.preferences.playbackPreference ==
      PlaybackPreference.caregiverRecordingFirst;

  bool get _audioBusy =>
      _busyKey != null || _previewingKey != null || _testingKey != null;

  bool _isRecording(_VoicePhrase phrase) =>
      _recordingKey == phrase.key && _recordingPhrase == phrase.phrase;

  @override
  void dispose() {
    if (_recordingKey != null) {
      unawaited(widget.services.voice.cancelCaregiverRecording());
    }
    super.dispose();
  }

  _RecordingAvailability _availability(_VoicePhrase phrase) {
    final saved = widget.services.voice.recordings.recordings[phrase.key];
    if (saved == null) return _RecordingAvailability.missing;
    return saved.matches(phrase.phrase)
        ? _RecordingAvailability.recorded
        : _RecordingAvailability.outdated;
  }

  Future<void> _setCaregiverRecordingsPreferred(bool preferred) async {
    if (_updatingPreference) return;
    setState(() => _updatingPreference = true);
    try {
      await widget.services.voice.setCaregiverRecordingsPreferred(preferred);
      if (!mounted) return;
      _showMessage(
        preferred
            ? 'Caregiver recordings are now preferred for every matching phrase. Missing recordings will use the system voice.'
            : 'Patient phrases will use the system voice.',
      );
    } on Object catch (error) {
      if (mounted) _showMessage('Could not save the voice preference: $error');
    } finally {
      if (mounted) setState(() => _updatingPreference = false);
    }
  }

  Future<void> _startGuidedRecording() async {
    final phrases = _phrases;
    if (phrases.isEmpty) {
      _showMessage('Calibrate at least one patient phrase first.');
      return;
    }

    final useRecordings = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Use the caregiver voice for patient phrases?'),
        content: const Text(
          'Each phrase needs its own direct recording. NeuroBridge Asha will use a matching caregiver recording across the app and safely use the system voice for any missing, changed, or damaged recording. The voice is not cloned.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Keep System Voice'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Use Recordings First'),
          ),
        ],
      ),
    );
    if (!mounted || useRecordings == null) return;
    await _setCaregiverRecordingsPreferred(useRecordings);
    if (!mounted) return;

    final firstMissing = phrases.indexWhere(
      (phrase) => _availability(phrase) != _RecordingAvailability.recorded,
    );
    setState(() => _guidedIndex = firstMissing < 0 ? 0 : firstMissing);
  }

  Future<void> _toggleRecording(_VoicePhrase phrase) async {
    if (_audioBusy && _busyKey != phrase.key) return;
    final recordingThisPhrase = _isRecording(phrase);
    if (_recordingKey != null && !recordingThisPhrase) {
      _showMessage(
          'Stop the current recording before choosing another phrase.');
      return;
    }
    if (!recordingThisPhrase && !_caregiverConfirmed) {
      _showMessage('Confirm caregiver consent before recording.');
      return;
    }

    setState(() => _busyKey = phrase.key);
    try {
      if (recordingThisPhrase) {
        final path = await widget.services.voice.stopCaregiverRecording();
        if (!mounted) return;
        setState(() {
          _recordingKey = null;
          _recordingPhrase = null;
        });
        _showMessage(
          path == null
              ? 'No audio was saved. Please record the phrase again.'
              : 'Saved this exact phrase. Listen to it before moving on.',
        );
        return;
      }

      final started = await widget.services.voice.startCaregiverRecording(
        phrase.key,
        phrase.phrase,
      );
      if (!mounted) return;
      if (started) {
        setState(() {
          _recordingKey = phrase.key;
          _recordingPhrase = phrase.phrase;
        });
        _showMessage('Recording now. Speak the displayed phrase exactly.');
      } else {
        _showMessage('Microphone permission is required to record audio.');
      }
    } on Object catch (error) {
      if (!mounted) return;
      setState(() {
        _recordingKey = null;
        _recordingPhrase = null;
      });
      _showMessage('Recording failed: $error');
    } finally {
      if (mounted) setState(() => _busyKey = null);
    }
  }

  Future<void> _previewRecording(_VoicePhrase phrase) async {
    if (_audioBusy || _recordingKey != null) return;
    setState(() => _previewingKey = phrase.key);
    CaregiverRecordingPlayback result;
    try {
      result = await widget.services.voice.previewCaregiverRecording(
        phrase.key,
        phrase.phrase,
      );
    } on Object {
      result = CaregiverRecordingPlayback.failed;
    } finally {
      if (mounted) setState(() => _previewingKey = null);
    }
    if (!mounted) return;
    _showMessage(switch (result) {
      CaregiverRecordingPlayback.played => 'Recording playback complete.',
      CaregiverRecordingPlayback.missing =>
        'No recording matches these exact words. Record the phrase again.',
      CaregiverRecordingPlayback.failed =>
        'The recording could not be played. Record the phrase again.',
    });
  }

  Future<void> _testPatientOutput(_VoicePhrase phrase) async {
    if (_audioBusy || _recordingKey != null) return;
    setState(() => _testingKey = phrase.key);
    PatientPhrasePlayback result;
    try {
      result = await widget.services.voice.speakPhrase(
        phrase.key,
        phrase.phrase,
      );
    } on Object {
      result = PatientPhrasePlayback.unavailable;
    } finally {
      if (mounted) setState(() => _testingKey = null);
    }
    if (!mounted) return;
    _showMessage(switch (result) {
      PatientPhrasePlayback.caregiverRecording =>
        'Patient output used the caregiver recording.',
      PatientPhrasePlayback.systemVoice =>
        'Patient output used the system voice fallback.',
      PatientPhrasePlayback.unavailable =>
        'Audio output was unavailable; the phrase remains visible.',
    });
  }

  void _moveGuide(int delta) {
    if (_recordingKey != null || _audioBusy) return;
    final phrases = _phrases;
    final current = _guidedIndex;
    if (current == null || phrases.isEmpty) return;
    final next = current + delta;
    if (next < 0) return;
    if (next >= phrases.length) {
      final recorded = phrases
          .where(
            (phrase) =>
                _availability(phrase) == _RecordingAvailability.recorded,
          )
          .length;
      setState(() => _guidedIndex = null);
      _showMessage(
        recorded == phrases.length
            ? 'Caregiver voice setup complete for all phrases.'
            : 'Guide finished: $recorded of ${phrases.length} phrases are ready.',
      );
      return;
    }
    setState(() => _guidedIndex = next);
  }

  void _showMessage(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(message)));
  }

  @override
  Widget build(BuildContext context) {
    final phrases = _phrases;
    final recordedCount = phrases
        .where(
          (phrase) => _availability(phrase) == _RecordingAvailability.recorded,
        )
        .length;
    final progress = phrases.isEmpty ? 0.0 : recordedCount / phrases.length;
    final guidedIndex = _guidedIndex;

    return Scaffold(
      appBar: AppBar(title: const Text('Caregiver Voice Setup')),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(16, 12, 16, 32),
        children: [
          _VoicePreferenceCard(
            recordingsPreferred: _caregiverRecordingsPreferred,
            updating: _updatingPreference,
            onChanged: _audioBusy || _recordingKey != null
                ? null
                : _setCaregiverRecordingsPreferred,
          ),
          const SizedBox(height: 12),
          Card(
            child: CheckboxListTile(
              value: _caregiverConfirmed,
              onChanged: _recordingKey == null
                  ? (value) =>
                      setState(() => _caregiverConfirmed = value ?? false)
                  : null,
              title: const Text(
                'I am the caregiver and consent to save my direct recordings',
              ),
              subtitle: const Text(
                'Audio stays in private app storage and is used only for the exact displayed phrases.',
              ),
              controlAffinity: ListTileControlAffinity.leading,
            ),
          ),
          const SizedBox(height: 12),
          _CoverageCard(
            recordedCount: recordedCount,
            totalCount: phrases.length,
            progress: progress,
            guideActive: guidedIndex != null,
            onStart: _audioBusy || _recordingKey != null
                ? null
                : _startGuidedRecording,
          ),
          if (guidedIndex != null && guidedIndex < phrases.length) ...[
            const SizedBox(height: 12),
            _GuidedPhraseCard(
              phrase: phrases[guidedIndex],
              index: guidedIndex,
              total: phrases.length,
              availability: _availability(phrases[guidedIndex]),
              recording: _isRecording(phrases[guidedIndex]),
              recordingBusy: _busyKey == phrases[guidedIndex].key,
              previewing: _previewingKey == phrases[guidedIndex].key,
              testing: _testingKey == phrases[guidedIndex].key,
              canGoBack: guidedIndex > 0,
              onRecord: () => _toggleRecording(phrases[guidedIndex]),
              onPreview: () => _previewRecording(phrases[guidedIndex]),
              onTest: () => _testPatientOutput(phrases[guidedIndex]),
              onBack: () => _moveGuide(-1),
              onNext: () => _moveGuide(1),
              onClose: _recordingKey == null && !_audioBusy
                  ? () => setState(() => _guidedIndex = null)
                  : null,
            ),
          ],
          const SizedBox(height: 20),
          Text(
            'All patient phrases',
            style: Theme.of(context).textTheme.titleLarge,
          ),
          const SizedBox(height: 4),
          const Text(
            'Record, listen, or test each phrase independently. Changed wording always requires a new matching recording.',
            style: TextStyle(color: Color(0xFF556E68)),
          ),
          const SizedBox(height: 10),
          if (phrases.isEmpty)
            const Card(
              child: Padding(
                padding: EdgeInsets.all(16),
                child: Text(
                  'No patient phrases are available. Complete Patient Signal Calibration or save a MediaPipe Hand Studio model first.',
                ),
              ),
            )
          else
            for (final phrase in phrases)
              _PhraseRecordingCard(
                phrase: phrase,
                availability: _availability(phrase),
                recording: _isRecording(phrase),
                recordingBusy: _busyKey == phrase.key,
                previewing: _previewingKey == phrase.key,
                testing: _testingKey == phrase.key,
                anotherRecordingActive:
                    _recordingKey != null && !_isRecording(phrase),
                audioBusy: _audioBusy,
                onRecord: () => _toggleRecording(phrase),
                onPreview: () => _previewRecording(phrase),
                onTest: () => _testPatientOutput(phrase),
              ),
        ],
      ),
    );
  }
}

enum _RecordingAvailability { recorded, outdated, missing }

class _VoicePhrase {
  const _VoicePhrase({
    required this.key,
    required this.phrase,
    required this.sourceLabel,
  });

  final String key;
  final String phrase;
  final String sourceLabel;
}

extension on _RecordingAvailability {
  String get label => switch (this) {
        _RecordingAvailability.recorded => 'Recorded',
        _RecordingAvailability.outdated => 'Phrase changed',
        _RecordingAvailability.missing => 'Not recorded',
      };

  Color get color => switch (this) {
        _RecordingAvailability.recorded => const Color(0xFF0B756A),
        _RecordingAvailability.outdated => const Color(0xFFB54708),
        _RecordingAvailability.missing => const Color(0xFF667085),
      };

  IconData get icon => switch (this) {
        _RecordingAvailability.recorded => Icons.check_circle,
        _RecordingAvailability.outdated => Icons.update,
        _RecordingAvailability.missing => Icons.mic_none,
      };
}

class _VoicePreferenceCard extends StatelessWidget {
  const _VoicePreferenceCard({
    required this.recordingsPreferred,
    required this.updating,
    required this.onChanged,
  });

  final bool recordingsPreferred;
  final bool updating;
  final ValueChanged<bool>? onChanged;

  @override
  Widget build(BuildContext context) {
    return Card(
      color: const Color(0xFFF3FBF9),
      child: SwitchListTile(
        value: recordingsPreferred,
        onChanged: updating ? null : onChanged,
        secondary: const Icon(Icons.family_restroom, color: Color(0xFF0B756A)),
        title: const Text(
          'Prefer caregiver recordings for patient phrases',
          style: TextStyle(fontWeight: FontWeight.bold),
        ),
        subtitle: Text(
          recordingsPreferred
              ? 'Applied across the app. Missing or unusable recordings safely fall back to the system voice.'
              : 'The system voice is used for every patient phrase.',
        ),
      ),
    );
  }
}

class _CoverageCard extends StatelessWidget {
  const _CoverageCard({
    required this.recordedCount,
    required this.totalCount,
    required this.progress,
    required this.guideActive,
    required this.onStart,
  });

  final int recordedCount;
  final int totalCount;
  final double progress;
  final bool guideActive;
  final VoidCallback? onStart;

  @override
  Widget build(BuildContext context) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              children: [
                const Icon(Icons.multitrack_audio, color: Color(0xFF0B756A)),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    '$recordedCount of $totalCount phrases recorded',
                    style: Theme.of(context).textTheme.titleMedium?.copyWith(
                          fontWeight: FontWeight.bold,
                        ),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 12),
            LinearProgressIndicator(value: progress),
            const SizedBox(height: 12),
            FilledButton.icon(
              onPressed: onStart,
              icon: const Icon(Icons.assistant),
              label: Text(
                guideActive
                    ? 'Restart Guided Recording'
                    : 'Start Guided Recording',
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _GuidedPhraseCard extends StatelessWidget {
  const _GuidedPhraseCard({
    required this.phrase,
    required this.index,
    required this.total,
    required this.availability,
    required this.recording,
    required this.recordingBusy,
    required this.previewing,
    required this.testing,
    required this.canGoBack,
    required this.onRecord,
    required this.onPreview,
    required this.onTest,
    required this.onBack,
    required this.onNext,
    required this.onClose,
  });

  final _VoicePhrase phrase;
  final int index;
  final int total;
  final _RecordingAvailability availability;
  final bool recording;
  final bool recordingBusy;
  final bool previewing;
  final bool testing;
  final bool canGoBack;
  final VoidCallback onRecord;
  final VoidCallback onPreview;
  final VoidCallback onTest;
  final VoidCallback onBack;
  final VoidCallback onNext;
  final VoidCallback? onClose;

  @override
  Widget build(BuildContext context) {
    final audioBusy = recordingBusy || previewing || testing;
    return Card(
      color: const Color(0xFF0F1720),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              children: [
                Text(
                  'GUIDED PHRASE ${index + 1} OF $total',
                  style: const TextStyle(
                    color: Color(0xFF4FD1C5),
                    fontWeight: FontWeight.bold,
                  ),
                ),
                const Spacer(),
                IconButton(
                  onPressed: onClose,
                  color: Colors.white70,
                  icon: const Icon(Icons.close),
                  tooltip: 'Close guide',
                ),
              ],
            ),
            const Text(
              'Speak these exact words:',
              style: TextStyle(color: Colors.white70),
            ),
            const SizedBox(height: 8),
            Text(
              '“${phrase.phrase}”',
              style: const TextStyle(
                color: Colors.white,
                fontSize: 24,
                height: 1.25,
                fontWeight: FontWeight.bold,
              ),
            ),
            const SizedBox(height: 8),
            Text(
              phrase.sourceLabel,
              style: const TextStyle(color: Color(0xFFA6E3D9)),
            ),
            const SizedBox(height: 12),
            _StatusChip(availability: availability, dark: true),
            const SizedBox(height: 12),
            FilledButton.icon(
              onPressed: audioBusy ? null : onRecord,
              style: recording
                  ? FilledButton.styleFrom(backgroundColor: Colors.red.shade700)
                  : null,
              icon: Icon(recording ? Icons.stop : Icons.mic),
              label: Text(
                recording ? 'Stop & Save Recording' : 'Record This Phrase',
              ),
            ),
            const SizedBox(height: 8),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                OutlinedButton.icon(
                  onPressed: availability == _RecordingAvailability.recorded &&
                          !audioBusy &&
                          !recording
                      ? onPreview
                      : null,
                  icon: const Icon(Icons.play_arrow),
                  label: Text(previewing ? 'Playing…' : 'Listen'),
                ),
                OutlinedButton.icon(
                  onPressed: !audioBusy && !recording ? onTest : null,
                  icon: const Icon(Icons.hearing),
                  label: Text(testing ? 'Testing…' : 'Test Patient Output'),
                ),
              ],
            ),
            const SizedBox(height: 12),
            Row(
              children: [
                TextButton.icon(
                  onPressed:
                      canGoBack && !audioBusy && !recording ? onBack : null,
                  icon: const Icon(Icons.arrow_back),
                  label: const Text('Back'),
                ),
                const Spacer(),
                FilledButton.tonalIcon(
                  onPressed: !audioBusy && !recording ? onNext : null,
                  icon: const Icon(Icons.arrow_forward),
                  label: Text(index + 1 == total ? 'Finish' : 'Next Phrase'),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

class _PhraseRecordingCard extends StatelessWidget {
  const _PhraseRecordingCard({
    required this.phrase,
    required this.availability,
    required this.recording,
    required this.recordingBusy,
    required this.previewing,
    required this.testing,
    required this.anotherRecordingActive,
    required this.audioBusy,
    required this.onRecord,
    required this.onPreview,
    required this.onTest,
  });

  final _VoicePhrase phrase;
  final _RecordingAvailability availability;
  final bool recording;
  final bool recordingBusy;
  final bool previewing;
  final bool testing;
  final bool anotherRecordingActive;
  final bool audioBusy;
  final VoidCallback onRecord;
  final VoidCallback onPreview;
  final VoidCallback onTest;

  @override
  Widget build(BuildContext context) {
    return Card(
      margin: const EdgeInsets.only(bottom: 10),
      child: Padding(
        padding: const EdgeInsets.all(14),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        phrase.phrase,
                        style: const TextStyle(
                          fontWeight: FontWeight.bold,
                          fontSize: 16,
                        ),
                      ),
                      const SizedBox(height: 2),
                      Text(
                        phrase.sourceLabel,
                        style: const TextStyle(color: Color(0xFF556E68)),
                      ),
                    ],
                  ),
                ),
                const SizedBox(width: 8),
                _StatusChip(availability: availability),
              ],
            ),
            if (availability == _RecordingAvailability.outdated) ...[
              const SizedBox(height: 8),
              const Text(
                'The phrase wording changed after recording. Re-record these exact words.',
                style: TextStyle(color: Color(0xFFB54708), fontSize: 12),
              ),
            ],
            const SizedBox(height: 10),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                OutlinedButton.icon(
                  onPressed:
                      anotherRecordingActive || (audioBusy && !recordingBusy)
                          ? null
                          : onRecord,
                  icon: Icon(recording ? Icons.stop : Icons.mic),
                  label: Text(
                    recording
                        ? 'Stop & Save'
                        : availability == _RecordingAvailability.recorded
                            ? 'Re-record'
                            : 'Record',
                  ),
                ),
                OutlinedButton.icon(
                  onPressed: availability == _RecordingAvailability.recorded &&
                          !audioBusy &&
                          !recording
                      ? onPreview
                      : null,
                  icon: const Icon(Icons.play_arrow),
                  label: Text(previewing ? 'Playing…' : 'Listen'),
                ),
                TextButton.icon(
                  onPressed: !audioBusy && !recording && !anotherRecordingActive
                      ? onTest
                      : null,
                  icon: const Icon(Icons.hearing),
                  label: Text(testing ? 'Testing…' : 'Test Output'),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

class _StatusChip extends StatelessWidget {
  const _StatusChip({required this.availability, this.dark = false});

  final _RecordingAvailability availability;
  final bool dark;

  @override
  Widget build(BuildContext context) {
    final color = availability.color;
    return Align(
      alignment: Alignment.centerLeft,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
        decoration: BoxDecoration(
          color: dark
              ? color.withValues(alpha: 0.25)
              : color.withValues(alpha: 0.1),
          border: Border.all(color: color.withValues(alpha: 0.55)),
          borderRadius: BorderRadius.circular(999),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(availability.icon,
                size: 14, color: dark ? Colors.white : color),
            const SizedBox(width: 4),
            Text(
              availability.label,
              style: TextStyle(
                color: dark ? Colors.white : color,
                fontSize: 12,
                fontWeight: FontWeight.bold,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

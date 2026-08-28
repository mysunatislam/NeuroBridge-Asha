import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'adb.dart';
import 'arguments.dart';
import 'parsers.dart';
import 'utils.dart';

const List<String> defaultResearchGestures = <String>[
  'Yes',
  'No',
  'Water',
  'Nurse',
];

/// Validated options for one interactive benchmark run.
class CollectorOptions {
  const CollectorOptions({
    required this.phase,
    required this.participantId,
    required this.sessionId,
    required this.gestures,
    required this.repetitions,
    required this.restTrials,
    required this.seed,
    required this.trialWindow,
    required this.outputPath,
    required this.packageName,
    required this.sampleInterval,
    required this.systemSampling,
    required this.launch,
    required this.clearLogcat,
    required this.marker,
    this.activity,
    this.adbPath,
    this.serial,
  });

  factory CollectorOptions.fromArguments(CliArguments arguments) {
    final phase = arguments.string('phase', 'benchmark').trim();
    final participant = _stringOption(arguments, const <String>[
      'participant',
      'participant-id',
    ], 'anonymous').trim();
    final session = _stringOption(arguments, const <String>[
      'session',
      'session-id',
    ], 'session-1').trim();
    if (phase.isEmpty || participant.isEmpty || session.isEmpty) {
      throw const FormatException(
        '--phase, --participant, and --session must not be empty.',
      );
    }

    final repetitions = arguments.integer('repetitions', 3, minimum: 1);
    final requestedGestures = arguments.commaList(
      'gestures',
      defaultResearchGestures,
    );
    final gestures = <String>[];
    final seen = <String>{};
    for (final requested in requestedGestures) {
      final display = requested.trim();
      final canonical = canonicalLabel(display);
      if (canonical == 'rest') {
        continue;
      }
      if (canonical.isEmpty) continue;
      if (!seen.add(canonical)) {
        throw FormatException('Duplicate gesture label: "$display".');
      }
      gestures.add(display);
    }

    final includeRest = arguments.boolean('include-rest', true);
    final restTrials = arguments.has('rest-trials')
        ? arguments.integer('rest-trials', 0, minimum: 0)
        : (includeRest ? repetitions : 0);
    if (gestures.isEmpty && restTrials == 0) {
      throw const FormatException(
        'At least one gesture or one Rest trial is required.',
      );
    }

    final nowSeed = DateTime.now().millisecondsSinceEpoch & 0x7fffffff;
    final seed = arguments.integer('seed', nowSeed);
    final trialWindow = _durationOption(
      arguments,
      millisecondsKeys: const <String>['window-ms', 'trial-window-ms'],
      secondsKeys: const <String>['window', 'window-seconds'],
      fallback: const Duration(seconds: 5),
      minimumMilliseconds: 100,
    );
    final sampleInterval = _durationOption(
      arguments,
      millisecondsKeys: const <String>['sample-interval-ms', 'sample-ms'],
      secondsKeys: const <String>['sample-interval'],
      fallback: const Duration(seconds: 2),
      minimumMilliseconds: 500,
    );
    final output = arguments
        .string('output', defaultRunDirectory(phase))
        .trim();
    final package = arguments
        .string('package', 'org.fingerspeak.mobile')
        .trim();
    final marker = arguments.string('marker', 'FINGERSPEAK_RESEARCH').trim();
    if (output.isEmpty || package.isEmpty || marker.isEmpty) {
      throw const FormatException(
        '--output, --package, and --marker must not be empty.',
      );
    }

    return CollectorOptions(
      phase: phase,
      participantId: participant,
      sessionId: session,
      gestures: List<String>.unmodifiable(gestures),
      repetitions: repetitions,
      restTrials: restTrials,
      seed: seed,
      trialWindow: trialWindow,
      outputPath: output,
      packageName: package,
      sampleInterval: sampleInterval,
      systemSampling: arguments.boolean('system-sampling', true),
      launch: arguments.boolean('launch', false),
      clearLogcat: arguments.boolean('clear-logcat', true),
      marker: marker,
      activity: _nullableOption(arguments, const <String>['activity']),
      adbPath: _nullableOption(arguments, const <String>['adb', 'adb-path']),
      serial: _nullableOption(arguments, const <String>['serial']),
    );
  }

  final String phase;
  final String participantId;
  final String sessionId;
  final List<String> gestures;
  final int repetitions;
  final int restTrials;
  final int seed;
  final Duration trialWindow;
  final String outputPath;
  final String packageName;
  final Duration sampleInterval;
  final bool systemSampling;
  final bool launch;
  final bool clearLogcat;
  final String marker;
  final String? activity;
  final String? adbPath;
  final String? serial;

  int get trialCount => gestures.length * repetitions + restTrials;

  Map<String, dynamic> toJson() => <String, dynamic>{
    'phase': phase,
    'participant_id': participantId,
    'session_id': sessionId,
    'gestures': gestures,
    'repetitions': repetitions,
    'rest_trials': restTrials,
    'seed': seed,
    'window_ms': trialWindow.inMilliseconds,
    'output': Directory(outputPath).absolute.path,
    'package': packageName,
    'sample_interval_ms': sampleInterval.inMilliseconds,
    'system_sampling': systemSampling,
    'launch': launch,
    'clear_logcat': clearLogcat,
    'research_marker': marker,
    'activity': activity,
    'requested_adb_path': adbPath == null ? null : '[explicit]',
    'requested_serial': serial == null ? null : '[redacted]',
  };
}

class TrialSpec {
  const TrialSpec({
    required this.index,
    required this.id,
    required this.expectedLabel,
    required this.repetition,
    required this.isRest,
  });

  final int index;
  final String id;
  final String expectedLabel;
  final int repetition;
  final bool isRest;

  String get expectedCanonical => canonicalLabel(expectedLabel);

  Map<String, dynamic> toJson() => <String, dynamic>{
    'trial_index': index,
    'trial_id': id,
    'expected_label': expectedLabel,
    'expected_label_canonical': expectedCanonical,
    'is_rest': isRest,
    'repetition': repetition,
  };
}

List<TrialSpec> buildRandomizedTrialProtocol(CollectorOptions options) {
  final pending = <({String label, int repetition, bool isRest})>[];
  for (final gesture in options.gestures) {
    for (var repetition = 1; repetition <= options.repetitions; repetition++) {
      pending.add((label: gesture, repetition: repetition, isRest: false));
    }
  }
  for (var repetition = 1; repetition <= options.restTrials; repetition++) {
    pending.add((label: 'Rest', repetition: repetition, isRest: true));
  }
  pending.shuffle(Random(options.seed));
  return List<TrialSpec>.unmodifiable(<TrialSpec>[
    for (var index = 0; index < pending.length; index++)
      TrialSpec(
        index: index + 1,
        id: 'trial-${(index + 1).toString().padLeft(4, '0')}',
        expectedLabel: pending[index].label,
        repetition: pending[index].repetition,
        isRest: pending[index].isRest,
      ),
  ]);
}

class TrialResult {
  const TrialResult({
    required this.spec,
    required this.phase,
    required this.participantId,
    required this.sessionId,
    required this.seed,
    required this.hostPromptUtc,
    required this.hostOnsetUtc,
    required this.hostOnsetElapsedMs,
    required this.windowMs,
    required this.outcome,
    required this.correct,
    this.event,
    this.hostObservedLatencyMs,
  });

  final TrialSpec spec;
  final String phase;
  final String participantId;
  final String sessionId;
  final int seed;
  final String hostPromptUtc;
  final String hostOnsetUtc;
  final double hostOnsetElapsedMs;
  final int windowMs;
  final String outcome;
  final bool correct;
  final ResearchEvent? event;
  final double? hostObservedLatencyMs;

  static const List<String> csvHeader = <String>[
    'trial_index',
    'trial_id',
    'phase',
    'participant_id',
    'session_id',
    'expected_label',
    'expected_label_canonical',
    'is_rest',
    'repetition',
    'seed',
    'host_prompt_utc',
    'host_onset_utc',
    'host_onset_elapsed_ms',
    'window_ms',
    'event_received_utc',
    'event_host_elapsed_ms',
    'logcat_epoch_seconds',
    'predicted_label',
    'confidence',
    'outcome',
    'correct',
    'host_observed_latency_ms',
    'device_activation_latency_ms',
  ];

  List<Object?> toCsvCells() => <Object?>[
    spec.index,
    spec.id,
    phase,
    participantId,
    sessionId,
    spec.expectedLabel,
    spec.expectedCanonical,
    spec.isRest,
    spec.repetition,
    seed,
    hostPromptUtc,
    hostOnsetUtc,
    hostOnsetElapsedMs,
    windowMs,
    event?.hostReceivedUtc,
    event?.hostElapsedMs,
    event?.logcatEpochSeconds,
    event?.label,
    event?.confidence,
    outcome,
    correct,
    hostObservedLatencyMs,
    event?.activationLatencyMs,
  ];

  Map<String, dynamic> toJson() => <String, dynamic>{
    ...spec.toJson(),
    'phase': phase,
    'participant_id': participantId,
    'session_id': sessionId,
    'seed': seed,
    'host_prompt_utc': hostPromptUtc,
    'host_onset_utc': hostOnsetUtc,
    'host_onset_elapsed_ms': hostOnsetElapsedMs,
    'window_ms': windowMs,
    'event_received_utc': event?.hostReceivedUtc,
    'event_host_elapsed_ms': event?.hostElapsedMs,
    'logcat_epoch_seconds': event?.logcatEpochSeconds,
    'predicted_label': event?.label,
    'confidence': event?.confidence,
    'outcome': outcome,
    'correct': correct,
    'host_observed_latency_ms': hostObservedLatencyMs,
    'device_activation_latency_ms': event?.activationLatencyMs,
  };
}

class CollectorRunResult {
  const CollectorRunResult({
    required this.outputDirectory,
    required this.trials,
    required this.metadata,
  });

  final Directory outputDirectory;
  final List<TrialResult> trials;
  final Map<String, dynamic> metadata;
}

class CollectorCancelledException implements Exception {
  const CollectorCancelledException();

  @override
  String toString() => 'Collection cancelled.';
}

/// Runs randomized, host-cued gesture trials while collecting device data.
class InteractiveCollector {
  InteractiveCollector({
    required this.options,
    AdbClient? adb,
    Stream<String>? inputLines,
    void Function(String)? writeLine,
  }) : adb = adb ?? AdbClient(adbPath: options.adbPath, serial: options.serial),
       _inputLines =
           inputLines ??
           stdin
               .transform(systemEncoding.decoder)
               .transform(const LineSplitter()),
       _writeLine = writeLine ?? print;

  final CollectorOptions options;
  final AdbClient adb;
  final Stream<String> _inputLines;
  final void Function(String) _writeLine;

  final Stopwatch _clock = Stopwatch();
  final StreamController<ResearchEvent> _gestureEvents =
      StreamController<ResearchEvent>.broadcast(sync: true);
  final StreamController<ResearchEvent> _researchEvents =
      StreamController<ResearchEvent>.broadcast(sync: true);
  final Completer<void> _cancelled = Completer<void>();

  StreamIterator<String>? _input;
  IOSink? _eventsSink;
  IOSink? _samplesSink;
  IOSink? _trialsSink;
  Process? _logcatProcess;
  StreamSubscription<String>? _logcatSubscription;
  Future<void>? _logcatStderrDrain;
  Future<void>? _sampler;
  var _stopSampling = false;
  var _eventCount = 0;
  var _eventParseErrorCount = 0;

  void cancel() {
    if (!_cancelled.isCompleted) _cancelled.complete();
  }

  Future<CollectorRunResult> run() async {
    final outputDirectory = createFreshDirectory(options.outputPath);
    final protocol = buildRandomizedTrialProtocol(options);
    final metadata = <String, dynamic>{
      'schema_version': 1,
      'status': 'starting',
      'started_utc': utcNow(),
      'options': options.toJson(),
      'files': <String, String>{
        'events': 'events.jsonl',
        'system_samples': 'system_samples.csv',
        'trials': 'trials.csv',
        'trial_protocol': 'trial_protocol.json',
        'metadata': 'metadata.json',
        'raw_snapshots': 'raw/{start,end}/*.txt',
      },
      'measurement_notes': <String>[
        'System samples are collected externally through ADB top and dumpsys.',
        'The sampler is not zero-overhead; top, cpuinfo, and meminfo may perturb '
            'the measured workload, especially at short intervals.',
      ],
    };
    final metadataFile = File(
      '${outputDirectory.path}${Platform.pathSeparator}metadata.json',
    );
    final results = <TrialResult>[];
    AdbDeviceSession? device;
    StreamSubscription<ProcessSignal>? interruptSubscription;
    Object? runError;
    StackTrace? runStackTrace;

    _clock.start();
    _input = StreamIterator<String>(_inputLines);
    _eventsSink = File(
      '${outputDirectory.path}${Platform.pathSeparator}events.jsonl',
    ).openWrite();
    _samplesSink = File(
      '${outputDirectory.path}${Platform.pathSeparator}system_samples.csv',
    ).openWrite();
    _trialsSink = File(
      '${outputDirectory.path}${Platform.pathSeparator}trials.csv',
    ).openWrite();
    _samplesSink!.writeln(csvRow(_systemSampleHeader));
    _trialsSink!.writeln(csvRow(TrialResult.csvHeader));
    writePrettyJson(
      File(
        '${outputDirectory.path}${Platform.pathSeparator}trial_protocol.json',
      ),
      <String, dynamic>{
        'schema_version': 1,
        'generated_utc': utcNow(),
        'randomization': 'dart Random(seed), Fisher-Yates shuffle',
        'seed': options.seed,
        'phase': options.phase,
        'participant_id': options.participantId,
        'session_id': options.sessionId,
        'window_ms': options.trialWindow.inMilliseconds,
        'trials': protocol.map((trial) => trial.toJson()).toList(),
      },
    );
    writePrettyJson(metadataFile, metadata);

    try {
      try {
        interruptSubscription = ProcessSignal.sigint.watch().listen((_) {
          _writeLine(
            '\nInterrupt received; finishing current device command and saving data...',
          );
          cancel();
        });
      } on Object {
        // Signal watching is not available in every embedded Dart runtime.
      }

      device = await adb.selectSession(serial: options.serial);
      metadata['device_serial'] = '[redacted]';
      metadata['doctor'] = _sanitizeDoctorData(
        await adb.collectDoctorData(packageName: options.packageName),
      );
      metadata['raw_start'] = await _captureSnapshot(
        device,
        outputDirectory,
        'start',
      );

      final gfxReset = await device.shell(<String>[
        'dumpsys',
        'gfxinfo',
        options.packageName,
        'reset',
      ], throwOnError: false);
      metadata['gfxinfo_reset'] = <String, dynamic>{
        'succeeded': gfxReset.succeeded,
        'exit_code': gfxReset.exitCode,
        'stderr': gfxReset.stderr.trim(),
      };
      if (options.clearLogcat) {
        final clear = await device.run(const <String>[
          'logcat',
          '-c',
        ], throwOnError: false);
        metadata['logcat_clear'] = <String, dynamic>{
          'succeeded': clear.succeeded,
          'exit_code': clear.exitCode,
          'stderr': clear.stderr.trim(),
        };
      }

      await _startLogcat(device);
      if (options.launch) {
        metadata['launch'] = await _launchApplication(device);
      } else {
        metadata['launch'] = <String, dynamic>{'requested': false};
      }
      if (options.systemSampling) {
        _sampler = _sampleSystem(device);
      }

      metadata['readiness'] = await _readinessGate();

      metadata['status'] = 'running';
      writePrettyJson(metadataFile, metadata);
      _writeLine('');
      _writeLine('FingerSpeak research collection');
      _writeLine('Device: ${device.serial}');
      _writeLine('Output: ${outputDirectory.path}');
      _writeLine(
        '${protocol.length} randomized trials; each window is '
        '${options.trialWindow.inMilliseconds} ms.',
      );
      _writeLine(
        'For gesture trials, press Enter at the instant you begin the gesture. '
        'For Rest, press Enter and remain still until the window ends.',
      );

      for (final trial in protocol) {
        _throwIfCancelled();
        final result = await _runTrial(trial, protocol.length);
        results.add(result);
        _trialsSink!.writeln(csvRow(result.toCsvCells()));
        await _trialsSink!.flush();
      }

      metadata['status'] = 'completed';
    } catch (error, stackTrace) {
      runError = error;
      runStackTrace = stackTrace;
      metadata['status'] = error is CollectorCancelledException
          ? 'cancelled'
          : 'failed';
      metadata['error'] = error.toString();
    } finally {
      _stopSampling = true;
      await _sampler;
      await _stopLogcat();
      if (device != null) {
        try {
          metadata['raw_end'] = await _captureSnapshot(
            device,
            outputDirectory,
            'end',
          );
        } on Object catch (error) {
          metadata['raw_end_error'] = error.toString();
        }
      }
      metadata['completed_utc'] = utcNow();
      metadata['host_elapsed_ms'] = _clock.elapsedMicroseconds / 1000;
      metadata['completed_trials'] = results.length;
      metadata['planned_trials'] = protocol.length;
      metadata['research_event_count'] = _eventCount;
      metadata['research_parse_error_count'] = _eventParseErrorCount;
      metadata['outcome_counts'] = _outcomeCounts(results);
      writePrettyJson(metadataFile, metadata);

      await _eventsSink?.flush();
      await _samplesSink?.flush();
      await _trialsSink?.flush();
      await _eventsSink?.close();
      await _samplesSink?.close();
      await _trialsSink?.close();
      await _input?.cancel();
      await interruptSubscription?.cancel();
      await _gestureEvents.close();
      await _researchEvents.close();
      _clock.stop();
    }

    if (runError != null) {
      Error.throwWithStackTrace(runError, runStackTrace ?? StackTrace.current);
    }
    return CollectorRunResult(
      outputDirectory: outputDirectory,
      trials: List<TrialResult>.unmodifiable(results),
      metadata: Map<String, dynamic>.unmodifiable(metadata),
    );
  }

  Future<TrialResult> _runTrial(TrialSpec trial, int total) async {
    _writeLine('');
    _writeLine(
      'Trial ${trial.index}/$total — EXPECTED: ${trial.expectedLabel}',
    );
    _writeLine(
      trial.isRest
          ? 'Prepare a neutral Rest pose, then press Enter to start the no-gesture window.'
          : 'Prepare ${trial.expectedLabel}, then press Enter exactly when the gesture begins.',
    );
    final hostPromptUtc = utcNow();
    await _waitForEnter();
    final onsetElapsedMs = _clock.elapsedMicroseconds / 1000;
    final onsetUtc = utcNow();
    final event = await _firstGestureWithin(
      options.trialWindow,
      onsetElapsedMs: onsetElapsedMs,
    );
    final predicted = event?.label ?? '';
    final correct = trial.isRest
        ? event == null
        : event != null && predicted == trial.expectedCanonical;
    final outcome = trial.isRest
        ? (event == null ? 'true_negative' : 'false_activation')
        : (event == null ? 'miss' : (correct ? 'correct' : 'incorrect'));
    final hostLatency = event == null
        ? null
        : event.hostElapsedMs - onsetElapsedMs;
    final result = TrialResult(
      spec: trial,
      phase: options.phase,
      participantId: options.participantId,
      sessionId: options.sessionId,
      seed: options.seed,
      hostPromptUtc: hostPromptUtc,
      hostOnsetUtc: onsetUtc,
      hostOnsetElapsedMs: onsetElapsedMs,
      windowMs: options.trialWindow.inMilliseconds,
      outcome: outcome,
      correct: correct,
      event: event,
      hostObservedLatencyMs: hostLatency,
    );
    if (event == null) {
      _writeLine(
        trial.isRest
            ? 'Result: no activation (correct Rest).'
            : 'Result: MISS (no activation).',
      );
    } else {
      _writeLine(
        'Result: ${event.label.isEmpty ? '(unlabelled)' : event.label} — '
        '$outcome; host latency ${hostLatency!.toStringAsFixed(1)} ms; '
        'device activation ${formatNumber(event.activationLatencyMs)} ms.',
      );
    }
    return result;
  }

  Future<void> _waitForEnter() async {
    final input = _input;
    if (input == null) throw StateError('Collector input is not initialized.');
    final completed = await Future.any<String>(<Future<String>>[
      input.moveNext().then((hasLine) => hasLine ? 'line' : 'eof'),
      _cancelled.future.then((_) => 'cancelled'),
    ]);
    if (completed == 'cancelled') throw const CollectorCancelledException();
    if (completed == 'eof') {
      throw const FormatException(
        'Standard input ended before all trial onsets were recorded.',
      );
    }
  }

  Future<ResearchEvent?> _firstGestureWithin(
    Duration duration, {
    required double onsetElapsedMs,
  }) async {
    final completer = Completer<ResearchEvent?>();
    late final StreamSubscription<ResearchEvent> subscription;
    Timer? timer;
    subscription = _gestureEvents.stream.listen((event) {
      // Broadcast streams do not buffer, but retain this boundary check so a
      // delayed callback can never turn a pre-onset event into a prediction.
      if (event.hostElapsedMs < onsetElapsedMs) return;
      if (!completer.isCompleted) completer.complete(event);
    });
    timer = Timer(duration, () {
      if (!completer.isCompleted) completer.complete(null);
    });
    final cancelled = _cancelled.future.then<ResearchEvent?>((_) {
      throw const CollectorCancelledException();
    });
    try {
      return await Future.any<ResearchEvent?>(<Future<ResearchEvent?>>[
        completer.future,
        cancelled,
      ]);
    } finally {
      timer.cancel();
      await subscription.cancel();
    }
  }

  Future<void> _startLogcat(AdbDeviceSession device) async {
    final process = await device.start(const <String>['logcat', '-v', 'epoch']);
    _logcatProcess = process;
    _logcatStderrDrain = process.stderr.transform(utf8.decoder).listen((line) {
      if (line.trim().isNotEmpty) {
        _writeEventRecord(<String, dynamic>{
          'record_kind': 'logcat_stderr',
          'host_received_utc': utcNow(),
          'host_elapsed_ms': _clock.elapsedMicroseconds / 1000,
          'message': line.trim(),
        });
      }
    }).asFuture<void>();
    _logcatSubscription = process.stdout
        .transform(utf8.decoder)
        .transform(const LineSplitter())
        .listen(
          (line) {
            final receivedUtc = utcNow();
            final elapsedMs = _clock.elapsedMicroseconds / 1000;
            final parsed = parseResearchLine(
              line,
              marker: options.marker,
              hostReceivedUtc: receivedUtc,
              hostElapsedMs: elapsedMs,
            );
            final event = parsed.event;
            if (event != null) {
              _eventCount++;
              _writeEventRecord(event.toJson());
              _researchEvents.add(event);
              if (event.eventType == 'gesture_fired') {
                _gestureEvents.add(event);
              }
            } else if (parsed.error != null) {
              _eventParseErrorCount++;
              _writeEventRecord(<String, dynamic>{
                'record_kind': 'parse_error',
                'host_received_utc': receivedUtc,
                'host_elapsed_ms': elapsedMs,
                'error': parsed.error,
                'raw_logcat_line': line,
              });
            }
          },
          onError: (Object error, StackTrace stackTrace) {
            _writeEventRecord(<String, dynamic>{
              'record_kind': 'logcat_stream_error',
              'host_received_utc': utcNow(),
              'host_elapsed_ms': _clock.elapsedMicroseconds / 1000,
              'error': error.toString(),
            });
          },
          cancelOnError: false,
        );
  }

  Future<void> _stopLogcat() async {
    final process = _logcatProcess;
    if (process == null) return;
    process.kill();
    try {
      await process.exitCode.timeout(const Duration(seconds: 5));
    } on TimeoutException {
      process.kill(ProcessSignal.sigkill);
    }
    await _logcatSubscription?.cancel();
    try {
      await _logcatStderrDrain;
    } on Object {
      // Stream shutdown errors after killing adb are not collection failures.
    }
    _logcatProcess = null;
  }

  void _writeEventRecord(Map<String, dynamic> record) {
    _eventsSink?.writeln(jsonEncode(record));
  }

  Future<Map<String, dynamic>> _readinessGate() async {
    _writeLine('');
    _writeLine('Readiness check');
    _writeLine(
      'Open the MediaPipe patient hand mode, enable the camera and speak mode, '
      'then press Enter. Keep a hand visible while the research build warms up.',
    );
    await _waitForEnter();
    final gateStartedMs = _clock.elapsedMicroseconds / 1000;
    final completer = Completer<ResearchEvent?>();
    var sawResearchReady = false;
    late final StreamSubscription<ResearchEvent> subscription;
    subscription = _researchEvents.stream.listen((event) {
      if (event.hostElapsedMs < gateStartedMs) return;
      if (event.eventType == 'research_ready') sawResearchReady = true;
      if (event.eventType != 'frame_stats') return;
      final model = event.payload['model']?.toString().trim() ?? '';
      final liveMode = _asBoolean(event.payload['live_mode']);
      if (model.isNotEmpty && liveMode == true && !completer.isCompleted) {
        completer.complete(event);
      }
    });
    final timer = Timer(const Duration(seconds: 15), () {
      if (!completer.isCompleted) completer.complete(null);
    });
    final cancelled = _cancelled.future.then<ResearchEvent?>((_) {
      throw const CollectorCancelledException();
    });
    ResearchEvent? readyEvent;
    try {
      readyEvent = await Future.any<ResearchEvent?>(<Future<ResearchEvent?>>[
        completer.future,
        cancelled,
      ]);
    } finally {
      timer.cancel();
      await subscription.cancel();
    }
    if (readyEvent == null) {
      throw StateError(
        'No ready FingerSpeak research telemetry was received within 15 '
        'seconds. Use an APK compiled with FINGERSPEAK_RESEARCH=true, open the '
        'MediaPipe patient hand mode, enable its camera and speak mode, and '
        'confirm that frame_stats reports a loaded model and live_mode=true.'
        '${sawResearchReady ? ' A research_ready event was seen, but no ready frame_stats followed.' : ''}',
      );
    }
    _writeLine(
      'Research telemetry ready (model ${readyEvent.payload['model']}). '
      'Warming up for 5 seconds...',
    );
    await Future.any<void>(<Future<void>>[
      Future<void>.delayed(const Duration(seconds: 5)),
      _cancelled.future,
    ]);
    _throwIfCancelled();
    return <String, dynamic>{
      'ready_utc': readyEvent.hostReceivedUtc,
      'ready_host_elapsed_ms': readyEvent.hostElapsedMs,
      'model': readyEvent.payload['model'],
      'live_mode': true,
      'saw_research_ready_event': sawResearchReady,
      'warmup_ms': 5000,
    };
  }

  Future<void> _sampleSystem(AdbDeviceSession device) async {
    while (!_stopSampling) {
      final sampleStarted = _clock.elapsed;
      await _takeSystemSample(device);
      final spent = _clock.elapsed - sampleStarted;
      final remaining = options.sampleInterval - spent;
      if (_stopSampling) break;
      if (remaining > Duration.zero) {
        await Future.any<void>(<Future<void>>[
          Future<void>.delayed(remaining),
          _cancelled.future,
        ]);
      }
    }
  }

  Future<void> _takeSystemSample(AdbDeviceSession device) async {
    final capturedUtc = utcNow();
    final capturedElapsedMs = _clock.elapsedMicroseconds / 1000;
    int? pid;
    String? topError;
    String? cpuInfoError;
    String? memInfoError;
    Map<String, double?> top = const <String, double?>{
      'cpu_percent': null,
      'rss_kb': null,
    };
    double? cpuInfo;
    Map<String, double?> memory = const <String, double?>{
      'pss_kb': null,
      'rss_kb': null,
    };

    final pidResult = await device.shell(<String>[
      'pidof',
      options.packageName,
    ], throwOnError: false);
    if (pidResult.succeeded) {
      pid = pidResult.stdout
          .trim()
          .split(RegExp(r'\s+'))
          .map(int.tryParse)
          .whereType<int>()
          .firstOrNull;
    }

    if (pid != null) {
      var topResult = await device.shell(<String>[
        'top',
        '-b',
        '-n',
        '1',
        '-p',
        '$pid',
      ], throwOnError: false);
      if (!topResult.succeeded) {
        topResult = await device.shell(<String>[
          'top',
          '-n',
          '1',
          '-p',
          '$pid',
        ], throwOnError: false);
      }
      if (topResult.succeeded) {
        top = parseTopProcess(topResult.stdout, pid, '');
      } else {
        topError = _commandError(topResult);
      }
    } else {
      topError = pidResult.succeeded
          ? 'package process not running'
          : 'pidof: ${_commandError(pidResult)}';
    }

    final cpuResult = await device.shell(const <String>[
      'dumpsys',
      'cpuinfo',
    ], throwOnError: false);
    if (cpuResult.succeeded) {
      cpuInfo = parseCpuInfoPercent(cpuResult.stdout, options.packageName);
    } else {
      cpuInfoError = _commandError(cpuResult);
    }

    final memResult = await device.shell(<String>[
      'dumpsys',
      'meminfo',
      options.packageName,
    ], throwOnError: false);
    if (memResult.succeeded) {
      memory = parseMemInfo(memResult.stdout);
    } else {
      memInfoError = _commandError(memResult);
    }

    _samplesSink?.writeln(
      csvRow(<Object?>[
        capturedUtc,
        capturedElapsedMs,
        pid,
        top['cpu_percent'],
        cpuInfo,
        memory['pss_kb'],
        memory['rss_kb'] ?? top['rss_kb'],
        topError,
        cpuInfoError,
        memInfoError,
      ]),
    );
  }

  Future<Map<String, dynamic>> _captureSnapshot(
    AdbDeviceSession device,
    Directory outputDirectory,
    String point,
  ) async {
    final snapshotDirectory = Directory(
      '${outputDirectory.path}${Platform.pathSeparator}raw'
      '${Platform.pathSeparator}$point',
    )..createSync(recursive: true);
    final results = await Future.wait(<Future<AdbCommandResult>>[
      device.shell(const <String>['dumpsys', 'battery'], throwOnError: false),
      device.shell(const <String>[
        'dumpsys',
        'thermalservice',
      ], throwOnError: false),
      device.shell(<String>[
        'dumpsys',
        'package',
        options.packageName,
      ], throwOnError: false),
      device.shell(
        <String>['dumpsys', 'gfxinfo', options.packageName, 'framestats'],
        timeout: const Duration(minutes: 1),
        throwOnError: false,
      ),
    ]);
    const names = <String>['battery', 'thermal', 'package', 'gfxinfo'];
    for (var index = 0; index < names.length; index++) {
      final result = results[index];
      File(
        '${snapshotDirectory.path}${Platform.pathSeparator}${names[index]}.txt',
      ).writeAsStringSync(
        result.stdout +
            (result.stderr.trim().isEmpty
                ? ''
                : '\n\n--- adb stderr ---\n${result.stderr}'),
      );
    }

    final frames = parseGfxInfoFramestats(results[3].stdout);
    final frameDurations = frames
        .map((frame) => frame.frameDurationMs)
        .toList();
    return <String, dynamic>{
      'captured_utc': utcNow(),
      'directory': 'raw/$point',
      'battery': parseBattery(results[0].stdout),
      'thermal': parseThermal(results[1].stdout),
      'package': parsePackageInfo(results[2].stdout),
      'gfxinfo': <String, dynamic>{
        'frame_count': frames.length,
        'janky_frame_count': frames.where((frame) => frame.janky).length,
        'mean_frame_duration_ms': frameDurations.isEmpty
            ? null
            : frameDurations.reduce((a, b) => a + b) / frameDurations.length,
      },
      'commands': <String, dynamic>{
        for (var index = 0; index < names.length; index++)
          names[index]: <String, dynamic>{
            'exit_code': results[index].exitCode,
            'succeeded': results[index].succeeded,
            'timed_out': results[index].timedOut,
          },
      },
    };
  }

  Future<Map<String, dynamic>> _launchApplication(
    AdbDeviceSession device,
  ) async {
    final activity = options.activity;
    final result = activity == null
        ? await device.shell(<String>[
            'monkey',
            '-p',
            options.packageName,
            '-c',
            'android.intent.category.LAUNCHER',
            '1',
          ], throwOnError: false)
        : await device.shell(
            <String>[
              'am',
              'start',
              '-W',
              '-n',
              activity.contains('/')
                  ? activity
                  : '${options.packageName}/$activity',
            ],
            timeout: const Duration(minutes: 1),
            throwOnError: false,
          );
    if (!result.succeeded) {
      throw AdbException(
        'Could not launch ${options.packageName}: ${_commandError(result)}',
        result: result,
      );
    }
    return <String, dynamic>{
      'requested': true,
      'activity': activity,
      'exit_code': result.exitCode,
      'stdout': result.stdout.trim(),
      'stderr': result.stderr.trim(),
    };
  }

  void _throwIfCancelled() {
    if (_cancelled.isCompleted) throw const CollectorCancelledException();
  }
}

/// Convenience entry point for a CLI command.
Future<CollectorRunResult> runInteractiveCollector(
  CliArguments arguments, {
  AdbClient? adb,
  Stream<String>? inputLines,
  void Function(String)? writeLine,
}) {
  final options = CollectorOptions.fromArguments(arguments);
  return InteractiveCollector(
    options: options,
    adb: adb,
    inputLines: inputLines,
    writeLine: writeLine,
  ).run();
}

const List<String> _systemSampleHeader = <String>[
  'host_utc',
  'host_elapsed_ms',
  'pid',
  'top_cpu_percent',
  'cpuinfo_percent',
  'pss_kb',
  'rss_kb',
  'top_error',
  'cpuinfo_error',
  'meminfo_error',
];

Map<String, int> _outcomeCounts(List<TrialResult> results) {
  final counts = <String, int>{};
  for (final result in results) {
    counts.update(result.outcome, (value) => value + 1, ifAbsent: () => 1);
  }
  return counts;
}

Map<String, dynamic> _sanitizeDoctorData(Map<String, dynamic> doctor) {
  final serials = <String>{};
  final requested = doctor['requested_serial'];
  if (requested is String && requested.isNotEmpty) serials.add(requested);
  final devices = doctor['devices'];
  if (devices is List) {
    for (final device in devices.whereType<Map>()) {
      final serial = device['serial'];
      if (serial is String && serial.isNotEmpty) serials.add(serial);
    }
  }
  final selected = doctor['selected_device'];
  if (selected is Map) {
    final serial = selected['serial'];
    if (serial is String && serial.isNotEmpty) serials.add(serial);
  }

  Object? scrub(Object? value, {String? key}) {
    final normalizedKey = key?.toLowerCase();
    if (normalizedKey == 'build_fingerprint') return null;
    if (normalizedKey != null && normalizedKey.contains('serial')) {
      return value == null ? null : '[redacted]';
    }
    if (value is Map) {
      final result = <String, dynamic>{};
      for (final entry in value.entries) {
        final childKey = entry.key.toString();
        if (childKey.toLowerCase() == 'build_fingerprint') continue;
        result[childKey] = scrub(entry.value, key: childKey);
      }
      return result;
    }
    if (value is List) {
      return value.map((item) => scrub(item)).toList();
    }
    if (value is String) {
      var redacted = value;
      for (final serial in serials) {
        redacted = redacted.replaceAll(serial, '[redacted]');
      }
      return redacted;
    }
    return value;
  }

  return scrub(doctor)! as Map<String, dynamic>;
}

bool? _asBoolean(Object? value) {
  if (value is bool) return value;
  if (value is num) return value != 0;
  if (value is String) {
    switch (value.trim().toLowerCase()) {
      case 'true':
      case '1':
      case 'yes':
        return true;
      case 'false':
      case '0':
      case 'no':
        return false;
    }
  }
  return null;
}

String _commandError(AdbCommandResult result) {
  final detail = result.stderr.trim().isNotEmpty
      ? result.stderr.trim()
      : result.stdout.trim();
  return result.timedOut
      ? 'timed out'
      : 'exit ${result.exitCode}${detail.isEmpty ? '' : ': $detail'}';
}

String _stringOption(
  CliArguments arguments,
  List<String> keys,
  String fallback,
) {
  for (final key in keys) {
    final value = arguments.value(key);
    if (value != null) return value;
  }
  return fallback;
}

String? _nullableOption(CliArguments arguments, List<String> keys) {
  final value = _stringOption(arguments, keys, '').trim();
  return value.isEmpty ? null : value;
}

Duration _durationOption(
  CliArguments arguments, {
  required List<String> millisecondsKeys,
  required List<String> secondsKeys,
  required Duration fallback,
  required int minimumMilliseconds,
}) {
  for (final key in millisecondsKeys) {
    if (arguments.has(key)) {
      return Duration(
        milliseconds: arguments.integer(
          key,
          fallback.inMilliseconds,
          minimum: minimumMilliseconds,
        ),
      );
    }
  }
  for (final key in secondsKeys) {
    if (arguments.has(key)) {
      return Duration(
        microseconds:
            (arguments.number(
                      key,
                      fallback.inMicroseconds / Duration.microsecondsPerSecond,
                      minimum:
                          minimumMilliseconds / Duration.millisecondsPerSecond,
                    ) *
                    Duration.microsecondsPerSecond)
                .round(),
      );
    }
  }
  return fallback;
}

extension _FirstOrNull<T> on Iterable<T> {
  T? get firstOrNull {
    final iterator = this.iterator;
    return iterator.moveNext() ? iterator.current : null;
  }
}

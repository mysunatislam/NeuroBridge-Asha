import 'dart:convert';
import 'dart:io';

import 'parsers.dart';
import 'statistics.dart';
import 'utils.dart';

const String _noPredictionLabel = 'no_prediction';

/// Parses RFC 4180-style CSV, including quoted commas, escaped quotes, CRLF,
/// and newlines embedded in quoted fields.
///
/// Empty physical lines are retained here; [parseCsvRecords] ignores them.
List<List<String>> parseCsv(String input, {String source = 'CSV'}) {
  if (input.isEmpty) return <List<String>>[];
  if (input.codeUnitAt(0) == 0xfeff) input = input.substring(1);

  final rows = <List<String>>[];
  var row = <String>[];
  var field = StringBuffer();
  var inQuotes = false;
  var afterQuote = false;
  var recordStarted = false;
  var line = 1;

  void finishField() {
    row.add(field.toString());
    field = StringBuffer();
    afterQuote = false;
  }

  void finishRecord() {
    finishField();
    rows.add(row);
    row = <String>[];
    recordStarted = false;
  }

  for (var index = 0; index < input.length; index++) {
    final character = input[index];
    if (inQuotes) {
      if (character == '"') {
        if (index + 1 < input.length && input[index + 1] == '"') {
          field.write('"');
          index++;
        } else {
          inQuotes = false;
          afterQuote = true;
        }
      } else {
        field.write(character);
        if (character == '\n') line++;
      }
      continue;
    }

    if (afterQuote) {
      if (character == ',') {
        finishField();
        recordStarted = true;
        continue;
      }
      if (character == '\r' || character == '\n') {
        finishRecord();
        if (character == '\r' &&
            index + 1 < input.length &&
            input[index + 1] == '\n')
          index++;
        line++;
        continue;
      }
      // A small amount of real-world CSV includes padding after a closing
      // quote. Accept it without putting the padding in the value.
      if (character == ' ' || character == '\t') continue;
      throw FormatException(
        '$source line $line has data after a closing quote.',
      );
    }

    if (character == '"') {
      if (field.isNotEmpty) {
        throw FormatException(
          '$source line $line has an unexpected quote in an unquoted field.',
        );
      }
      inQuotes = true;
      recordStarted = true;
    } else if (character == ',') {
      finishField();
      recordStarted = true;
    } else if (character == '\r' || character == '\n') {
      finishRecord();
      if (character == '\r' &&
          index + 1 < input.length &&
          input[index + 1] == '\n')
        index++;
      line++;
    } else {
      field.write(character);
      recordStarted = true;
    }
  }

  if (inQuotes) throw FormatException('$source ends inside a quoted field.');
  if (recordStarted || row.isNotEmpty || field.isNotEmpty || afterQuote)
    finishRecord();
  return rows;
}

/// Parses CSV into maps whose keys are normalized lower_snake_case headers.
List<Map<String, String>> parseCsvRecords(
  String input, {
  String source = 'CSV',
}) {
  final rows = parseCsv(input, source: source);
  if (rows.isEmpty) return <Map<String, String>>[];
  final headerIndex = rows.indexWhere(
    (cells) => cells.any((cell) => cell.trim().isNotEmpty),
  );
  if (headerIndex < 0) return <Map<String, String>>[];
  final headers = <String>[];
  final occurrences = <String, int>{};
  for (var index = 0; index < rows[headerIndex].length; index++) {
    var header = _canonicalColumnName(rows[headerIndex][index]);
    if (header.isEmpty) header = 'column_${index + 1}';
    final occurrence = (occurrences[header] ?? 0) + 1;
    occurrences[header] = occurrence;
    headers.add(occurrence == 1 ? header : '${header}_$occurrence');
  }

  final records = <Map<String, String>>[];
  for (final cells in rows.skip(headerIndex + 1)) {
    if (cells.every((cell) => cell.trim().isEmpty)) continue;
    final record = <String, String>{};
    for (var index = 0; index < cells.length; index++) {
      final key = index < headers.length
          ? headers[index]
          : 'extra_column_${index - headers.length + 1}';
      record[key] = cells[index];
    }
    for (final header in headers) {
      record.putIfAbsent(header, () => '');
    }
    records.add(record);
  }
  return records;
}

/// Analyzes a benchmark run without mutating its input artifacts.
Map<String, dynamic> analyzeRun(Directory runDirectory) {
  final data = _readRun(runDirectory);
  return _summarize(data);
}

/// Compares calibrated accuracy with baseline accuracy.
///
/// The default confidence interval is unpaired. Paired mode is opt-in and
/// uses only unique trials with the same participant, session, and trial key
/// in both runs. Ambiguous duplicate keys are excluded.
Map<String, dynamic> compareRuns(
  Directory baseline,
  Directory calibrated, {
  bool paired = false,
}) {
  final baselineData = _readRun(baseline);
  final calibratedData = _readRun(calibrated);
  final baselineSummary = _summarize(baselineData);
  final calibratedSummary = _summarize(calibratedData);
  final baselineAccuracy = _map(baselineSummary['accuracy']);
  final calibratedAccuracy = _map(calibratedSummary['accuracy']);

  final warnings = <String>[];
  late final Map<String, dynamic> accuracyDifference;
  if (paired) {
    final baselineProtocol = _trialProtocolSignature(baselineData.trials);
    final calibratedProtocol = _trialProtocolSignature(calibratedData.trials);
    if (!_sameStrings(baselineProtocol, calibratedProtocol)) {
      warnings.add(
        'Paired comparison protocols differ by trial id, expected label, repetition, or window; '
        'only exact matching trial keys were paired.',
      );
    }
    final baselineSeeds = baselineData.trials
        .map((trial) => trial.seed)
        .where((seed) => seed.isNotEmpty)
        .toSet();
    final calibratedSeeds = calibratedData.trials
        .map((trial) => trial.seed)
        .where((seed) => seed.isNotEmpty)
        .toSet();
    if (baselineSeeds.isNotEmpty &&
        calibratedSeeds.isNotEmpty &&
        !_sameStrings(baselineSeeds.toList(), calibratedSeeds.toList())) {
      warnings.add(
        'Paired comparison randomization seeds differ (baseline: ${baselineSeeds.join(', ')}, '
        'calibrated: ${calibratedSeeds.join(', ')}).',
      );
    }
    final pairing = _pairedTrials(baselineData.trials, calibratedData.trials);
    final differences = pairing.differences;
    final baselineMatched = pairing.baselineCorrect.fold<int>(
      0,
      (sum, value) => sum + (value ? 1 : 0),
    );
    final calibratedMatched = pairing.calibratedCorrect.fold<int>(
      0,
      (sum, value) => sum + (value ? 1 : 0),
    );
    final interval = pairedDifferenceInterval(differences);
    if (differences.isEmpty) {
      warnings.add(
        'Paired comparison requested, but no unambiguous trials shared participant_id, '
        'session_id, trial_id/trial_index, expected_label, and repetition keys.',
      );
    }
    if (pairing.duplicateBaselineKeys > 0 ||
        pairing.duplicateCalibratedKeys > 0) {
      warnings.add(
        'Excluded ambiguous paired keys (baseline: ${pairing.duplicateBaselineKeys}, '
        'calibrated: ${pairing.duplicateCalibratedKeys}).',
      );
    }
    accuracyDifference = <String, dynamic>{
      'estimate': mean(differences),
      'absolute_difference': mean(differences),
      'ci95': interval,
      'confidence_interval': interval,
      'method': interval['method'],
      'paired': true,
      'matched_pairs': differences.length,
      'baseline_matched_correct': baselineMatched,
      'calibrated_matched_correct': calibratedMatched,
      'baseline_matched_accuracy': differences.isEmpty
          ? null
          : baselineMatched / differences.length,
      'calibrated_matched_accuracy': differences.isEmpty
          ? null
          : calibratedMatched / differences.length,
      'duplicate_baseline_keys': pairing.duplicateBaselineKeys,
      'duplicate_calibrated_keys': pairing.duplicateCalibratedKeys,
      'baseline_trials_without_pair_key': pairing.baselineWithoutKey,
      'calibrated_trials_without_pair_key': pairing.calibratedWithoutKey,
      'pairing_key_fields': <String>[
        'participant_id',
        'session_id',
        'trial_id (trial_index fallback)',
        'expected_label',
        'repetition',
      ],
    };
  } else {
    final baselineCorrect = asInt(baselineAccuracy['correct']) ?? 0;
    final baselineTotal = asInt(baselineAccuracy['total']) ?? 0;
    final calibratedCorrect = asInt(calibratedAccuracy['correct']) ?? 0;
    final calibratedTotal = asInt(calibratedAccuracy['total']) ?? 0;
    final baselineRate = asDouble(baselineAccuracy['rate']);
    final calibratedRate = asDouble(calibratedAccuracy['rate']);
    final interval = unpairedDifferenceInterval(
      baselineCorrect,
      baselineTotal,
      calibratedCorrect,
      calibratedTotal,
    );
    accuracyDifference = <String, dynamic>{
      'estimate': baselineRate == null || calibratedRate == null
          ? null
          : calibratedRate - baselineRate,
      'absolute_difference': baselineRate == null || calibratedRate == null
          ? null
          : calibratedRate - baselineRate,
      'ci95': interval,
      'confidence_interval': interval,
      'method': interval['method'],
      'paired': false,
      'matched_pairs': null,
    };
  }

  final differenceEstimate = asDouble(accuracyDifference['estimate']);
  final comparisonBaselineRate = paired
      ? asDouble(accuracyDifference['baseline_matched_accuracy'])
      : asDouble(baselineAccuracy['rate']);
  accuracyDifference['percentage_point_difference'] = differenceEstimate;
  accuracyDifference['relative_improvement'] =
      differenceEstimate == null ||
          comparisonBaselineRate == null ||
          comparisonBaselineRate <= 0
      ? null
      : differenceEstimate / comparisonBaselineRate;

  final metricDeltas = <String, dynamic>{};
  final baselineMetrics = _map(baselineSummary['metrics']);
  final calibratedMetrics = _map(calibratedSummary['metrics']);
  for (final key in <String>[
    'host_observed_latency_ms',
    'device_activation_latency_ms',
    'model_latency_ms',
    'mediapipe_latency_ms',
    'tracking_fps',
    'cpu_percent',
    'top_cpu_percent',
    'pss_kb',
    'rss_kb',
  ]) {
    final base = _map(baselineMetrics[key]);
    final tuned = _map(calibratedMetrics[key]);
    final baseMean = asDouble(base['mean']);
    final tunedMean = asDouble(tuned['mean']);
    metricDeltas[key] = <String, dynamic>{
      'baseline_mean': baseMean,
      'calibrated_mean': tunedMean,
      'mean_difference': baseMean == null || tunedMean == null
          ? null
          : tunedMean - baseMean,
    };
  }

  return <String, dynamic>{
    'schema_version': 1,
    'generated_utc': utcNow(),
    'comparison_mode': paired ? 'paired' : 'unpaired',
    'paired_requested': paired,
    'baseline_directory': baseline.absolute.path,
    'calibrated_directory': calibrated.absolute.path,
    'baseline': baselineSummary,
    'calibrated': calibratedSummary,
    'accuracy_difference': accuracyDifference,
    'accuracy': accuracyDifference,
    'macro_f1_difference': _difference(
      asDouble(baselineSummary['macro_f1']),
      asDouble(calibratedSummary['macro_f1']),
    ),
    'metric_deltas': metricDeltas,
    'warnings': warnings,
  };
}

_RunData _readRun(Directory inputDirectory) {
  final directory = inputDirectory.absolute;
  if (!directory.existsSync()) {
    throw FileSystemException(
      'Benchmark run directory does not exist',
      directory.path,
    );
  }
  final trialsFile = File(_join(directory.path, 'trials.csv'));
  final eventsFile = File(_join(directory.path, 'events.jsonl'));
  final samplesFile = File(_join(directory.path, 'system_samples.csv'));
  final metadataFile = File(_join(directory.path, 'metadata.json'));
  for (final file in <File>[
    trialsFile,
    eventsFile,
    samplesFile,
    metadataFile,
  ]) {
    if (!file.existsSync()) {
      throw FileSystemException(
        'Required benchmark artifact is missing',
        file.path,
      );
    }
  }

  final rawTrialRows = parseCsvRecords(
    trialsFile.readAsStringSync(),
    source: trialsFile.path,
  );
  final rawSampleRows = parseCsvRecords(
    samplesFile.readAsStringSync(),
    source: samplesFile.path,
  );
  final events = _readJsonLines(eventsFile);
  final trials = <_Trial>[];
  for (var index = 0; index < rawTrialRows.length; index++) {
    trials.add(_Trial.fromRow(rawTrialRows[index], index));
  }
  return _RunData(
    directory: directory,
    metadata: readJsonObject(metadataFile),
    trialRows: rawTrialRows,
    trials: trials,
    events: events,
    systemSamples: rawSampleRows,
    gfxFiles: _findGfxFiles(directory),
  );
}

List<Map<String, dynamic>> _readJsonLines(File file) {
  final events = <Map<String, dynamic>>[];
  final lines = const LineSplitter().convert(file.readAsStringSync());
  for (var index = 0; index < lines.length; index++) {
    final line = lines[index].trim();
    if (line.isEmpty) continue;
    try {
      final decoded = jsonDecode(line);
      if (decoded is! Map) {
        throw const FormatException('JSONL record is not an object');
      }
      events.add(decoded.map((key, value) => MapEntry(key.toString(), value)));
    } on FormatException catch (error) {
      throw FormatException('${file.path}:${index + 1}: ${error.message}');
    }
  }
  return events;
}

Map<String, dynamic> _summarize(_RunData data) {
  final warnings = <String>[];
  final classified = data.trials
      .where((trial) => trial.correct != null)
      .toList();
  final correct = classified.where((trial) => trial.correct!).length;
  final total = classified.length;
  final accuracyRate = total == 0 ? null : correct / total;
  if (data.trials.isNotEmpty && classified.length != data.trials.length) {
    warnings.add(
      '${data.trials.length - classified.length} trial(s) lacked enough data to determine correctness.',
    );
  }
  if (total == 0) warnings.add('No classifiable trials were found.');

  final confusion = <String, Map<String, int>>{};
  final expectedLabels = <String>{};
  final predictedLabels = <String>{};
  for (final trial in data.trials) {
    if (trial.expectedLabel.isEmpty) continue;
    final predicted = trial.predictedLabel.isEmpty
        ? _noPredictionLabel
        : trial.predictedLabel;
    expectedLabels.add(trial.expectedLabel);
    if (predicted != _noPredictionLabel) predictedLabels.add(predicted);
    final row = confusion.putIfAbsent(
      trial.expectedLabel,
      () => <String, int>{},
    );
    row[predicted] = (row[predicted] ?? 0) + 1;
  }
  final classLabels = <String>{...expectedLabels, ...predictedLabels}.toList()
    ..sort();
  final perClass = <String, dynamic>{};
  for (final label in classLabels) {
    final truePositive = confusion[label]?[label] ?? 0;
    var falsePositive = 0;
    for (final expected in confusion.keys) {
      if (expected != label) falsePositive += confusion[expected]?[label] ?? 0;
    }
    final support =
        confusion[label]?.values.fold<int>(0, (sum, count) => sum + count) ?? 0;
    final falseNegative = support - truePositive;
    final precisionDenominator = truePositive + falsePositive;
    final recallDenominator = truePositive + falseNegative;
    final precision = precisionDenominator == 0
        ? 0.0
        : truePositive / precisionDenominator;
    final recall = recallDenominator == 0
        ? 0.0
        : truePositive / recallDenominator;
    final f1 = precision + recall == 0
        ? 0.0
        : 2 * precision * recall / (precision + recall);
    perClass[label] = <String, dynamic>{
      'support': support,
      'true_positive': truePositive,
      'false_positive': falsePositive,
      'false_negative': falseNegative,
      'precision': precision,
      'recall': recall,
      'f1': f1,
    };
  }
  final macroF1 = mean(
    perClass.values
        .map((value) => asDouble(_map(value)['f1']))
        .whereType<double>(),
  );
  final wilson = wilsonInterval(correct, total);
  final accuracy = <String, dynamic>{
    'correct': correct,
    'incorrect': total - correct,
    'total': total,
    'rate': accuracyRate,
    'value': accuracyRate,
    'ci95': wilson,
    'wilson_95_ci': wilson,
  };
  final gestureTrials = data.trials
      .where((trial) => !trial.isRest && trial.expectedLabel.isNotEmpty)
      .toList();
  final gestureClassified = gestureTrials
      .where((trial) => trial.correct != null)
      .toList();
  final gestureAccuracy = _accuracySummary(gestureClassified);
  final gestureMacroF1 = mean(
    perClass.entries
        .where((entry) => entry.key != 'rest')
        .map((entry) => asDouble(_map(entry.value)['f1']))
        .whereType<double>(),
  );
  final misses = gestureTrials.where((trial) {
    return trial.outcome == 'miss' ||
        (trial.correct == false && trial.predictedLabel.isEmpty);
  }).length;
  final missRate = gestureTrials.isEmpty ? null : misses / gestureTrials.length;
  final restTrials = data.trials.where((trial) => trial.isRest).toList();
  final restClassified = restTrials
      .where((trial) => trial.correct != null)
      .toList();
  final trueNegatives = restClassified.where((trial) => trial.correct!).length;
  final falseActivations = restClassified.length - trueNegatives;
  final restSpecificity = restClassified.isEmpty
      ? null
      : trueNegatives / restClassified.length;
  final restWindows = restTrials
      .map((trial) => trial.windowMs)
      .whereType<double>()
      .where((value) => value > 0)
      .toList();
  final restObservationMs = restWindows.isEmpty
      ? null
      : restWindows.fold<double>(0, (sum, value) => sum + value);
  final restObservationMinutes = restObservationMs == null
      ? null
      : restObservationMs / 60000.0;
  final restObservationHours = restObservationMs == null
      ? null
      : restObservationMs / 3600000.0;
  final restExposureComplete = restTrials.isNotEmpty &&
      restWindows.length == restTrials.length;
  final restMetrics = <String, dynamic>{
    'trials': restTrials.length,
    'classifiable_trials': restClassified.length,
    'true_negatives': trueNegatives,
    'false_activations': falseActivations,
    'specificity': restSpecificity,
    'specificity_ci95': wilsonInterval(
      trueNegatives,
      restClassified.length,
    ),
    'observation_ms': restObservationMs,
    'observation_minutes': restObservationMinutes,
    'observation_hours': restObservationHours,
    'trials_with_window_ms': restWindows.length,
    'exposure_complete': restExposureComplete,
    'false_activations_per_minute': !restExposureComplete ||
            restObservationMinutes == null ||
            restObservationMinutes <= 0
        ? null
        : falseActivations / restObservationMinutes,
    'false_activations_per_hour': !restExposureComplete ||
            restObservationHours == null ||
            restObservationHours <= 0
        ? null
        : falseActivations / restObservationHours,
  };
  final missMetrics = <String, dynamic>{
    'count': misses,
    'gesture_trials': gestureTrials.length,
    'rate': missRate,
    'ci95': wilsonInterval(misses, gestureTrials.length),
  };

  final hostLatency = data.trials
      .map((trial) => trial.hostLatencyMs)
      .whereType<double>();
  final trialDeviceLatency = data.trials
      .map((trial) => trial.deviceLatencyMs)
      .whereType<double>()
      .toList();
  final eventDeviceLatency = _eventNumbers(data.events, <String>{
    'activation_latency_ms',
    'device_activation_latency_ms',
    'pipeline_latency_ms',
  });
  final deviceLatency = trialDeviceLatency.isNotEmpty
      ? trialDeviceLatency
      : eventDeviceLatency;
  final perInferenceModelLatency = _eventNumbers(data.events, <String>{
    'model_latency_ms',
    'model_inference_latency_ms',
    'inference_latency_ms',
    'inference_time_ms',
    'classifier_ms',
  });
  final modelLatency = perInferenceModelLatency.isNotEmpty
      ? perInferenceModelLatency
      : _eventNumbers(data.events, <String>{'classifier_mean_ms'});
  final mediapipeLatency = _eventNumbers(data.events, <String>{
    'mediapipe_latency_ms',
    'mediapipe_time_ms',
    'mediapipe_mean_ms',
    'landmark_latency_ms',
    'tracking_latency_ms',
    'hand_tracking_latency_ms',
    'detection_latency_ms',
  });
  final trackingFps = _eventNumbers(data.events, <String>{
    'tracking_fps',
    'mediapipe_fps',
    'hand_tracking_fps',
    'camera_fps',
    'fps',
  });
  final cpu = <double>[];
  final topCpu = <double>[];
  final cpuInfo = <double>[];
  final pss = <double>[];
  final rss = <double>[];
  for (final sample in data.systemSamples) {
    final primaryCpu = _number(sample, <String>[
      'cpu_percent',
      'top_cpu_percent',
      'process_cpu_percent',
    ]);
    final secondaryCpu = _number(sample, <String>[
      'cpuinfo_percent',
      'dumpsys_cpu_percent',
    ]);
    if (secondaryCpu != null) {
      cpu.add(secondaryCpu);
    } else if (primaryCpu != null) {
      cpu.add(primaryCpu);
    }
    if (primaryCpu != null) topCpu.add(primaryCpu);
    if (secondaryCpu != null) cpuInfo.add(secondaryCpu);
    final pssValue = _number(sample, <String>['pss_kb', 'total_pss_kb', 'pss']);
    final rssValue = _number(sample, <String>['rss_kb', 'total_rss_kb', 'rss']);
    if (pssValue != null) pss.add(pssValue);
    if (rssValue != null) rss.add(rssValue);
  }

  final hostDistribution = distribution(hostLatency);
  final deviceDistribution = distribution(deviceLatency);
  final modelDistribution = distribution(modelLatency);
  final mediapipeDistribution = distribution(mediapipeLatency);
  final trackingFpsDistribution = distribution(trackingFps);
  final cpuDistribution = distribution(cpu);
  final topCpuDistribution = distribution(topCpu);
  final cpuInfoDistribution = distribution(cpuInfo);
  final pssDistribution = distribution(pss);
  final rssDistribution = distribution(rss);
  final metrics = <String, dynamic>{
    'host_observed_latency_ms': hostDistribution,
    'device_activation_latency_ms': deviceDistribution,
    'model_latency_ms': modelDistribution,
    'mediapipe_latency_ms': mediapipeDistribution,
    'tracking_fps': trackingFpsDistribution,
    'cpu_percent': cpuDistribution,
    'top_cpu_percent': topCpuDistribution,
    'cpuinfo_percent': cpuInfoDistribution,
    'pss_kb': pssDistribution,
    'rss_kb': rssDistribution,
  };

  final eventTypeCounts = <String, int>{};
  for (final event in data.events) {
    final type = canonicalLabel(
      event['event_type'] ?? event['event'] ?? _map(event['payload'])['event'],
    );
    final key = type.isEmpty ? 'unknown' : type;
    eventTypeCounts[key] = (eventTypeCounts[key] ?? 0) + 1;
  }

  final outcomeCounts = <String, int>{};
  for (final trial in data.trials) {
    final outcome = trial.outcome.isEmpty ? 'unspecified' : trial.outcome;
    outcomeCounts[outcome] = (outcomeCounts[outcome] ?? 0) + 1;
  }

  final uiFrames = _uiFrameSummary(data.gfxFiles);
  return <String, dynamic>{
    'schema_version': 1,
    'generated_utc': utcNow(),
    'run_directory': data.directory.path,
    'metadata': data.metadata,
    'inputs': <String, dynamic>{
      'trial_rows': data.trialRows.length,
      'event_records': data.events.length,
      'system_samples': data.systemSamples.length,
      'gfxinfo_files': data.gfxFiles.map((file) => file.path).toList(),
    },
    'accuracy': accuracy,
    'overall_accuracy': accuracy,
    'gesture_accuracy': gestureAccuracy,
    'accuracy_rate': accuracyRate,
    'classification': <String, dynamic>{
      'confusion_matrix': confusion,
      'per_class': perClass,
      'macro_f1': macroF1,
      'gesture_macro_f1': gestureMacroF1,
      'labels': classLabels,
      'no_prediction_label': _noPredictionLabel,
    },
    'confusion_matrix': confusion,
    'per_class': perClass,
    'macro_f1': macroF1,
    'gesture_macro_f1': gestureMacroF1,
    'rest': restMetrics,
    'misses': missMetrics,
    'latencies_ms': <String, dynamic>{
      'host_observed': hostDistribution,
      'device_activation': deviceDistribution,
      'model': modelDistribution,
      'mediapipe': mediapipeDistribution,
    },
    'fps': <String, dynamic>{'tracking': trackingFpsDistribution},
    'resources': <String, dynamic>{
      'cpu_percent': cpuDistribution,
      'top_cpu_percent': topCpuDistribution,
      'cpuinfo_percent': cpuInfoDistribution,
      'pss_kb': pssDistribution,
      'rss_kb': rssDistribution,
    },
    'metrics': metrics,
    'ui_frames': uiFrames,
    'events': <String, dynamic>{
      'total': data.events.length,
      'by_type': eventTypeCounts,
    },
    'outcomes': outcomeCounts,
    'warnings': warnings,
  };
}

Map<String, dynamic>? _uiFrameSummary(List<File> files) {
  if (files.isEmpty) return null;
  final frames = <GfxFrame>[];
  final parsedFiles = <String>[];
  for (final file in files) {
    final parsed = parseGfxInfoFramestats(file.readAsStringSync());
    if (parsed.isNotEmpty) {
      frames.addAll(parsed);
      parsedFiles.add(file.path);
    }
  }
  final slowFrames = frames.where((frame) => frame.janky).length;
  return <String, dynamic>{
    'available': true,
    'source_files': files.map((file) => file.path).toList(),
    'parsed_source_files': parsedFiles,
    'frame_count': frames.length,
    'slow_frame_threshold_ms': 16.666667,
    'slow_frames_over_threshold': slowFrames,
    'approx_slow_frame_rate': frames.isEmpty
        ? null
        : slowFrames / frames.length,
    'frame_duration_ms': distribution(
      frames.map((frame) => frame.frameDurationMs),
    ),
    'inter_frame_fps': distribution(
      frames.map((frame) => frame.interFrameFps).whereType<double>(),
    ),
  };
}

List<File> _findGfxFiles(Directory directory) {
  final files = <File>[];
  for (final entity in directory.listSync(
    recursive: true,
    followLinks: false,
  )) {
    if (entity is! File) continue;
    final name = _basename(entity.path).toLowerCase();
    if (!name.contains('gfxinfo')) continue;
    if (name == 'summary.json' || name == 'comparison.json') continue;
    files.add(entity);
  }
  files.sort((a, b) => a.path.compareTo(b.path));
  final endSnapshots = files.where((file) {
    final normalized = file.path.replaceAll('\\', '/').toLowerCase();
    return normalized.contains('/raw/end/');
  }).toList();
  // Current collectors reset gfxinfo at run start. The end snapshot therefore
  // represents the study window, while the start snapshot contains history.
  // Fall back to any gfxinfo file solely for older flat fixture layouts.
  return endSnapshots.isNotEmpty ? endSnapshots : files;
}

List<double> _eventNumbers(
  List<Map<String, dynamic>> events,
  Set<String> aliases,
) {
  final normalizedAliases = aliases.map(_canonicalColumnName).toSet();
  final values = <double>[];
  for (final event in events) {
    final value = _findNestedValue(event, normalizedAliases);
    final number = asDouble(value);
    if (number != null && number.isFinite) values.add(number);
  }
  return values;
}

Object? _findNestedValue(Object? value, Set<String> aliases, [int depth = 0]) {
  if (depth > 5 || value is! Map) return null;
  for (final entry in value.entries) {
    if (aliases.contains(_canonicalColumnName(entry.key.toString())))
      return entry.value;
  }
  const preferredContainers = <String>{
    'payload',
    'metrics',
    'timing',
    'performance',
    'stats',
    'data',
  };
  for (final entry in value.entries) {
    if (!preferredContainers.contains(
      _canonicalColumnName(entry.key.toString()),
    ))
      continue;
    final found = _findNestedValue(entry.value, aliases, depth + 1);
    if (found != null) return found;
  }
  return null;
}

_Pairing _pairedTrials(List<_Trial> baseline, List<_Trial> calibrated) {
  final baselineGroups = _groupPairableTrials(baseline);
  final calibratedGroups = _groupPairableTrials(calibrated);
  final duplicateBaseline = baselineGroups.values
      .where((values) => values.length > 1)
      .length;
  final duplicateCalibrated = calibratedGroups.values
      .where((values) => values.length > 1)
      .length;
  final keys =
      baselineGroups.keys
          .toSet()
          .intersection(calibratedGroups.keys.toSet())
          .toList()
        ..sort();
  final differences = <double>[];
  final baselineCorrect = <bool>[];
  final calibratedCorrect = <bool>[];
  for (final key in keys) {
    final baseCandidates = baselineGroups[key]!;
    final tunedCandidates = calibratedGroups[key]!;
    if (baseCandidates.length != 1 || tunedCandidates.length != 1) continue;
    final base = baseCandidates.single.correct;
    final tuned = tunedCandidates.single.correct;
    if (base == null || tuned == null) continue;
    baselineCorrect.add(base);
    calibratedCorrect.add(tuned);
    differences.add((tuned ? 1.0 : 0.0) - (base ? 1.0 : 0.0));
  }
  return _Pairing(
    differences: differences,
    baselineCorrect: baselineCorrect,
    calibratedCorrect: calibratedCorrect,
    duplicateBaselineKeys: duplicateBaseline,
    duplicateCalibratedKeys: duplicateCalibrated,
    baselineWithoutKey: baseline.where((trial) => trial.pairKey == null).length,
    calibratedWithoutKey: calibrated
        .where((trial) => trial.pairKey == null)
        .length,
  );
}

Map<String, List<_Trial>> _groupPairableTrials(List<_Trial> trials) {
  final groups = <String, List<_Trial>>{};
  for (final trial in trials) {
    final key = trial.pairKey;
    if (key != null) groups.putIfAbsent(key, () => <_Trial>[]).add(trial);
  }
  return groups;
}

double? _number(Map<String, String> row, List<String> aliases) =>
    asDouble(_first(row, aliases));

String _first(Map<String, String> row, List<String> aliases) {
  for (final alias in aliases) {
    final value = row[_canonicalColumnName(alias)];
    if (value != null && value.trim().isNotEmpty) return value.trim();
  }
  return '';
}

bool? _asBool(Object? value) {
  if (value is bool) return value;
  if (value is num) return value != 0;
  final text = canonicalLabel(value);
  if (<String>{
    'true',
    '1',
    'yes',
    'y',
    'correct',
    'success',
    'pass',
    'passed',
    'true_negative',
  }.contains(text)) {
    return true;
  }
  if (<String>{
    'false',
    '0',
    'no',
    'n',
    'incorrect',
    'failure',
    'fail',
    'failed',
    'miss',
    'timeout',
    'false_activation',
  }.contains(text)) {
    return false;
  }
  return null;
}

String _canonicalColumnName(String value) => value
    .trim()
    .toLowerCase()
    .replaceAll(RegExp(r'[\s.\-/]+'), '_')
    .replaceAll(RegExp(r'[^a-z0-9_]+'), '')
    .replaceAll(RegExp(r'_+'), '_')
    .replaceAll(RegExp(r'^_|_$'), '');

String _join(String directory, String name) =>
    '$directory${Platform.pathSeparator}$name';

String _basename(String path) {
  final normalized = path.replaceAll('\\', '/');
  final slash = normalized.lastIndexOf('/');
  return slash < 0 ? normalized : normalized.substring(slash + 1);
}

Map<String, dynamic> _map(Object? value) {
  if (value is Map<String, dynamic>) return value;
  if (value is Map)
    return value.map((key, item) => MapEntry(key.toString(), item));
  return <String, dynamic>{};
}

double? _difference(double? baseline, double? calibrated) {
  if (baseline == null || calibrated == null) return null;
  return calibrated - baseline;
}

Map<String, dynamic> _accuracySummary(Iterable<_Trial> trials) {
  final classifiable = trials.where((trial) => trial.correct != null).toList();
  final correct = classifiable.where((trial) => trial.correct!).length;
  final total = classifiable.length;
  final rate = total == 0 ? null : correct / total;
  final interval = wilsonInterval(correct, total);
  return <String, dynamic>{
    'correct': correct,
    'incorrect': total - correct,
    'total': total,
    'rate': rate,
    'value': rate,
    'ci95': interval,
    'wilson_95_ci': interval,
  };
}

List<String> _trialProtocolSignature(List<_Trial> trials) {
  final signature = trials.map((trial) {
    final id = trial.trialId.isNotEmpty ? trial.trialId : trial.trialIndex;
    return jsonEncode(<Object?>[
      id,
      trial.expectedLabel,
      trial.repetition,
      trial.windowMs,
    ]);
  }).toList();
  signature.sort();
  return signature;
}

bool _sameStrings(List<String> first, List<String> second) {
  if (first.length != second.length) return false;
  final left = List<String>.from(first)..sort();
  final right = List<String>.from(second)..sort();
  for (var index = 0; index < left.length; index++) {
    if (left[index] != right[index]) return false;
  }
  return true;
}

class _RunData {
  _RunData({
    required this.directory,
    required this.metadata,
    required this.trialRows,
    required this.trials,
    required this.events,
    required this.systemSamples,
    required this.gfxFiles,
  });

  final Directory directory;
  final Map<String, dynamic> metadata;
  final List<Map<String, String>> trialRows;
  final List<_Trial> trials;
  final List<Map<String, dynamic>> events;
  final List<Map<String, String>> systemSamples;
  final List<File> gfxFiles;
}

class _Trial {
  _Trial({
    required this.rowIndex,
    required this.trialId,
    required this.trialIndex,
    required this.participantId,
    required this.sessionId,
    required this.expectedLabel,
    required this.predictedLabel,
    required this.outcome,
    required this.repetition,
    required this.seed,
    required this.isRest,
    required this.windowMs,
    required this.correct,
    required this.hostLatencyMs,
    required this.deviceLatencyMs,
  });

  factory _Trial.fromRow(Map<String, String> row, int rowIndex) {
    final expected = canonicalLabel(
      _first(row, <String>[
        'expected_label_canonical',
        'expected_label',
        'expected',
        'ground_truth',
        'target_label',
        'actual_label',
      ]),
    );
    var predicted = canonicalLabel(
      _first(row, <String>[
        'predicted_label',
        'prediction',
        'detected_label',
        'observed_label',
      ]),
    );
    final outcome = canonicalLabel(
      _first(row, <String>['outcome', 'status', 'result']),
    );
    if (predicted.isEmpty &&
        outcome == 'true_negative' &&
        expected.isNotEmpty) {
      predicted = expected;
    }
    var correct = _asBool(
      _first(row, <String>['correct', 'is_correct', 'success']),
    );
    correct ??= _asBool(outcome);
    if (correct == null && expected.isNotEmpty) {
      correct = predicted.isNotEmpty && predicted == expected;
    }
    return _Trial(
      rowIndex: rowIndex,
      trialId: _first(row, <String>['trial_id', 'trial_uuid', 'id']),
      trialIndex: _first(row, <String>[
        'trial_index',
        'trial_number',
        'trial_no',
        'index',
      ]),
      participantId: _first(row, <String>[
        'participant_id',
        'participant',
        'subject_id',
        'subject',
      ]),
      sessionId: _first(row, <String>['session_id', 'session', 'session_key']),
      expectedLabel: expected,
      predictedLabel: predicted,
      outcome: outcome,
      repetition: _first(row, <String>['repetition', 'repeat', 'rep']),
      seed: _first(row, <String>['seed', 'randomization_seed']),
      isRest: _asBool(_first(row, <String>['is_rest', 'rest'])) ??
          expected == 'rest',
      windowMs: _number(row, <String>[
        'window_ms',
        'trial_window_ms',
        'observation_window_ms',
      ]),
      correct: correct,
      hostLatencyMs: _number(row, <String>[
        'host_observed_latency_ms',
        'host_latency_ms',
        'observed_latency_ms',
        'end_to_end_latency_ms',
      ]),
      deviceLatencyMs: _number(row, <String>[
        'device_activation_latency_ms',
        'activation_latency_ms',
        'pipeline_latency_ms',
      ]),
    );
  }

  final int rowIndex;
  final String trialId;
  final String trialIndex;
  final String participantId;
  final String sessionId;
  final String expectedLabel;
  final String predictedLabel;
  final String outcome;
  final String repetition;
  final String seed;
  final bool isRest;
  final double? windowMs;
  final bool? correct;
  final double? hostLatencyMs;
  final double? deviceLatencyMs;

  String? get pairKey {
    final trial = trialId.isNotEmpty ? trialId : trialIndex;
    if (participantId.isEmpty || sessionId.isEmpty || trial.isEmpty)
      return null;
    return jsonEncode(<String>[
      participantId,
      sessionId,
      trial,
      expectedLabel,
      repetition,
    ]);
  }
}

class _Pairing {
  _Pairing({
    required this.differences,
    required this.baselineCorrect,
    required this.calibratedCorrect,
    required this.duplicateBaselineKeys,
    required this.duplicateCalibratedKeys,
    required this.baselineWithoutKey,
    required this.calibratedWithoutKey,
  });

  final List<double> differences;
  final List<bool> baselineCorrect;
  final List<bool> calibratedCorrect;
  final int duplicateBaselineKeys;
  final int duplicateCalibratedKeys;
  final int baselineWithoutKey;
  final int calibratedWithoutKey;
}

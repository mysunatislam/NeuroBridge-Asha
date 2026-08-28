import 'dart:io';

import 'analysis.dart';
import 'utils.dart';

/// Writes both machine-readable and human-readable outputs for one run.
///
/// Passing a precomputed [summary] avoids analyzing the input files twice.
void writeRunReport(Directory runDirectory, [Map<String, dynamic>? summary]) {
  final result = summary ?? analyzeRun(runDirectory);
  writePrettyJson(
    File(_join(runDirectory.absolute.path, 'summary.json')),
    result,
  );
  final report = File(_join(runDirectory.absolute.path, 'report.md'));
  report.writeAsStringSync(_runMarkdown(result));
}

/// Writes a comparison returned by [compareRuns].
void writeComparisonReport(
  Directory outputDirectory,
  Map<String, dynamic> comparison,
) {
  outputDirectory.createSync(recursive: true);
  writePrettyJson(
    File(_join(outputDirectory.absolute.path, 'comparison.json')),
    comparison,
  );
  final report = File(_join(outputDirectory.absolute.path, 'comparison.md'));
  report.writeAsStringSync(_comparisonMarkdown(comparison));
}

String _runMarkdown(Map<String, dynamic> summary) {
  final output = StringBuffer();
  final accuracy = _map(summary['accuracy']);
  final ci = _map(accuracy['ci95']);
  final perClass = _map(summary['per_class']);
  final confusion = _map(summary['confusion_matrix']);
  final metrics = _map(summary['metrics']);
  final metadata = _map(summary['metadata']);
  final inputs = _map(summary['inputs']);

  output.writeln('# FingerSpeak benchmark report');
  output.writeln();
  output.writeln('- Run: `${markdownEscape(summary['run_directory'])}`');
  output.writeln(
    '- Generated (UTC): ${markdownEscape(summary['generated_utc'])}',
  );
  output.writeln(
    '- Trials: ${accuracy['total'] ?? 0} classifiable of ${inputs['trial_rows'] ?? 0} recorded',
  );
  output.writeln('- Events: ${inputs['event_records'] ?? 0}');
  output.writeln('- System samples: ${inputs['system_samples'] ?? 0}');

  final flatMetadata = <String, Object?>{};
  _flatten(metadata, '', flatMetadata);
  if (flatMetadata.isNotEmpty) {
    output.writeln();
    output.writeln('## Run metadata');
    output.writeln();
    output.writeln('| Field | Value |');
    output.writeln('| --- | --- |');
    for (final entry in flatMetadata.entries.take(40)) {
      output.writeln(
        '| ${markdownEscape(entry.key)} | ${markdownEscape(entry.value)} |',
      );
    }
  }

  output.writeln();
  output.writeln('## Accuracy');
  output.writeln();
  output.writeln(
    '**${accuracy['correct'] ?? 0}/${accuracy['total'] ?? 0} correct '
    '(${formatPercent(accuracy['rate'])})**, Wilson 95% CI '
    '${_interval(ci, percent: true)}.',
  );
  output.writeln();
  output.writeln(
    'Macro F1: **${formatNumber(summary['macro_f1'], decimals: 3)}**',
  );

  if (perClass.isNotEmpty) {
    output.writeln();
    output.writeln('### Per-class results');
    output.writeln();
    output.writeln('| Class | Support | Precision | Recall | F1 |');
    output.writeln('| --- | ---: | ---: | ---: | ---: |');
    final labels = perClass.keys.toList()..sort();
    for (final label in labels) {
      final values = _map(perClass[label]);
      output.writeln(
        '| ${markdownEscape(label)} | ${values['support'] ?? 0} | '
        '${formatNumber(values['precision'], decimals: 3)} | '
        '${formatNumber(values['recall'], decimals: 3)} | '
        '${formatNumber(values['f1'], decimals: 3)} |',
      );
    }
  }

  if (confusion.isNotEmpty) {
    output.writeln();
    output.writeln('### Confusion matrix');
    output.writeln();
    final predicted = <String>{};
    for (final row in confusion.values) predicted.addAll(_map(row).keys);
    final columns = predicted.toList()..sort();
    output.writeln(
      '| Expected \\ Predicted | ${columns.map(markdownEscape).join(' | ')} |',
    );
    output.writeln('| --- | ${columns.map((_) => '---:').join(' | ')} |');
    final expected = confusion.keys.toList()..sort();
    for (final label in expected) {
      final row = _map(confusion[label]);
      output.writeln(
        '| ${markdownEscape(label)} | ${columns.map((column) => row[column] ?? 0).join(' | ')} |',
      );
    }
  }

  output.writeln();
  output.writeln('## Performance and resource metrics');
  output.writeln();
  output.writeln('| Metric | Samples | Mean | Median | P95 | Min | Max |');
  output.writeln('| --- | ---: | ---: | ---: | ---: | ---: | ---: |');
  const names = <String, String>{
    'host_observed_latency_ms': 'Host-observed latency (ms)',
    'device_activation_latency_ms': 'Device activation latency (ms)',
    'model_latency_ms': 'Model latency (ms)',
    'mediapipe_latency_ms': 'MediaPipe latency (ms)',
    'tracking_fps': 'Tracking FPS',
    'cpu_percent': 'Process CPU (%)',
    'cpuinfo_percent': 'dumpsys CPU (%)',
    'pss_kb': 'PSS (KiB)',
    'rss_kb': 'RSS (KiB)',
  };
  for (final entry in names.entries) {
    final values = _map(metrics[entry.key]);
    output.writeln(
      '| ${entry.value} | ${values['count'] ?? 0} | ${formatNumber(values['mean'])} | '
      '${formatNumber(values['median'])} | ${formatNumber(values['p95'])} | '
      '${formatNumber(values['min'])} | ${formatNumber(values['max'])} |',
    );
  }

  final uiFrames = summary['ui_frames'];
  if (uiFrames is Map) {
    final ui = _map(uiFrames);
    final duration = _map(ui['frame_duration_ms']);
    final fps = _map(ui['inter_frame_fps']);
    output.writeln();
    output.writeln('## Android UI frames');
    output.writeln();
    output.writeln('- Parsed frames: ${ui['frame_count'] ?? 0}');
    output.writeln(
      '- Janky frames (>16.67 ms): ${ui['janky_frames'] ?? 0} (${formatPercent(ui['jank_rate'])})',
    );
    output.writeln(
      '- Frame duration median / p95: ${formatNumber(duration['median'])} / ${formatNumber(duration['p95'])} ms',
    );
    output.writeln('- Inter-frame FPS mean: ${formatNumber(fps['mean'])}');
  }

  final events = _map(summary['events']);
  final eventCounts = _map(events['by_type']);
  if (eventCounts.isNotEmpty) {
    output.writeln();
    output.writeln('## Event inventory');
    output.writeln();
    output.writeln('| Event | Count |');
    output.writeln('| --- | ---: |');
    final eventTypes = eventCounts.keys.toList()..sort();
    for (final eventType in eventTypes) {
      output.writeln(
        '| ${markdownEscape(eventType)} | ${eventCounts[eventType]} |',
      );
    }
  }

  _writeWarnings(output, summary['warnings']);
  return '${output.toString().trimRight()}\n';
}

String _comparisonMarkdown(Map<String, dynamic> comparison) {
  final output = StringBuffer();
  final baseline = _map(comparison['baseline']);
  final calibrated = _map(comparison['calibrated']);
  final baselineAccuracy = _map(baseline['accuracy']);
  final calibratedAccuracy = _map(calibrated['accuracy']);
  final difference = _map(comparison['accuracy_difference']);
  final differenceCi = _map(difference['ci95']);

  output.writeln('# FingerSpeak benchmark comparison');
  output.writeln();
  output.writeln(
    '- Mode: **${markdownEscape(comparison['comparison_mode'])}**',
  );
  output.writeln(
    '- Baseline: `${markdownEscape(comparison['baseline_directory'])}`',
  );
  output.writeln(
    '- Calibrated: `${markdownEscape(comparison['calibrated_directory'])}`',
  );
  output.writeln(
    '- Generated (UTC): ${markdownEscape(comparison['generated_utc'])}',
  );
  output.writeln();
  output.writeln('## Classification');
  output.writeln();
  output.writeln(
    '| Run | Correct / total | Accuracy | Wilson 95% CI | Macro F1 |',
  );
  output.writeln('| --- | ---: | ---: | ---: | ---: |');
  output.writeln(
    _classificationComparisonRow('Baseline', baseline, baselineAccuracy),
  );
  output.writeln(
    _classificationComparisonRow('Calibrated', calibrated, calibratedAccuracy),
  );
  output.writeln();
  output.writeln(
    'Calibrated − baseline accuracy: **${formatPercent(difference['estimate'])}**; '
    '${markdownEscape(difference['method'])} CI ${_interval(differenceCi, percent: true)}.',
  );
  if (difference['paired'] == true) {
    output.writeln();
    output.writeln(
      'The paired estimate uses ${difference['matched_pairs'] ?? 0} unique participant/session/trial matches. '
      'Matched accuracy was ${formatPercent(difference['baseline_matched_accuracy'])} at baseline and '
      '${formatPercent(difference['calibrated_matched_accuracy'])} after calibration.',
    );
  }

  final deltas = _map(comparison['metric_deltas']);
  if (deltas.isNotEmpty) {
    output.writeln();
    output.writeln('## Mean metric comparison');
    output.writeln();
    output.writeln('| Metric | Baseline | Calibrated | Difference |');
    output.writeln('| --- | ---: | ---: | ---: |');
    const names = <String, String>{
      'host_observed_latency_ms': 'Host-observed latency (ms)',
      'device_activation_latency_ms': 'Device activation latency (ms)',
      'model_latency_ms': 'Model latency (ms)',
      'mediapipe_latency_ms': 'MediaPipe latency (ms)',
      'tracking_fps': 'Tracking FPS',
      'cpu_percent': 'Process CPU (%)',
      'pss_kb': 'PSS (KiB)',
      'rss_kb': 'RSS (KiB)',
    };
    for (final entry in names.entries) {
      final values = _map(deltas[entry.key]);
      output.writeln(
        '| ${entry.value} | ${formatNumber(values['baseline_mean'])} | '
        '${formatNumber(values['calibrated_mean'])} | ${_signed(values['mean_difference'])} |',
      );
    }
  }

  _writeWarnings(output, comparison['warnings']);
  return '${output.toString().trimRight()}\n';
}

String _classificationComparisonRow(
  String label,
  Map<String, dynamic> summary,
  Map<String, dynamic> accuracy,
) {
  return '| $label | ${accuracy['correct'] ?? 0} / ${accuracy['total'] ?? 0} | '
      '${formatPercent(accuracy['rate'])} | ${_interval(_map(accuracy['ci95']), percent: true)} | '
      '${formatNumber(summary['macro_f1'], decimals: 3)} |';
}

void _writeWarnings(StringBuffer output, Object? rawWarnings) {
  if (rawWarnings is! Iterable) return;
  final warnings = rawWarnings
      .where((warning) => warning.toString().trim().isNotEmpty)
      .toList();
  if (warnings.isEmpty) return;
  output.writeln();
  output.writeln('## Warnings');
  output.writeln();
  for (final warning in warnings) {
    output.writeln('- ${markdownEscape(warning)}');
  }
}

void _flatten(
  Map<String, dynamic> value,
  String prefix,
  Map<String, Object?> output,
) {
  for (final entry in value.entries) {
    final key = prefix.isEmpty ? entry.key : '$prefix.${entry.key}';
    if (entry.value is Map) {
      _flatten(_map(entry.value), key, output);
    } else if (entry.value is Iterable) {
      output[key] = (entry.value as Iterable)
          .map((item) => item.toString())
          .join(', ');
    } else {
      output[key] = entry.value;
    }
  }
}

String _interval(Map<String, dynamic> interval, {bool percent = false}) {
  final lower = interval['lower'];
  final upper = interval['upper'];
  if (lower == null || upper == null) return 'n/a';
  if (percent) return '[${formatPercent(lower)}, ${formatPercent(upper)}]';
  return '[${formatNumber(lower)}, ${formatNumber(upper)}]';
}

String _signed(Object? value) {
  final number = asDouble(value);
  if (number == null || !number.isFinite) return 'n/a';
  return '${number >= 0 ? '+' : ''}${number.toStringAsFixed(2)}';
}

Map<String, dynamic> _map(Object? value) {
  if (value is Map<String, dynamic>) return value;
  if (value is Map)
    return value.map((key, item) => MapEntry(key.toString(), item));
  return <String, dynamic>{};
}

String _join(String directory, String name) =>
    '$directory${Platform.pathSeparator}$name';

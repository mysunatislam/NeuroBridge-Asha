import 'dart:convert';

import 'utils.dart';

class ResearchEvent {
  ResearchEvent({
    required this.payload,
    required this.rawLine,
    required this.hostReceivedUtc,
    required this.hostElapsedMs,
    this.logcatEpochSeconds,
  });

  final Map<String, dynamic> payload;
  final String rawLine;
  final String hostReceivedUtc;
  final double hostElapsedMs;
  final double? logcatEpochSeconds;

  String get eventType => canonicalLabel(
        payload['event'] ?? payload['event_type'] ?? payload['type'] ?? payload['name'],
      );

  String get label => canonicalLabel(
        payload['gesture_id'] ??
            payload['predicted_label'] ??
            payload['label'] ??
            payload['gesture'] ??
            payload['gesture_label'] ??
            payload['gesture_name'] ??
            payload['prediction'],
      );

  double? get confidence => asDouble(
        payload['confidence'] ?? payload['probability'] ?? payload['score'],
      );

  double? get activationLatencyMs => asDouble(
        payload['activation_latency_ms'] ??
            payload['device_activation_latency_ms'] ??
            payload['pipeline_latency_ms'],
      );

  double? get fps => asDouble(
        payload['tracking_fps'] ??
            payload['fps'] ??
            payload['camera_fps'] ??
            payload['render_fps'],
      );

  Map<String, dynamic> toJson() => <String, dynamic>{
        'record_kind': 'logcat_event',
        'host_received_utc': hostReceivedUtc,
        'host_elapsed_ms': hostElapsedMs,
        'logcat_epoch_seconds': logcatEpochSeconds,
        'event_type': eventType,
        'label': label.isEmpty ? null : label,
        'payload': payload,
        'raw_logcat_line': rawLine,
      };
}

class ResearchLineParseResult {
  const ResearchLineParseResult({this.event, this.error});

  final ResearchEvent? event;
  final String? error;
}

ResearchLineParseResult parseResearchLine(
  String line, {
  required String marker,
  required String hostReceivedUtc,
  required double hostElapsedMs,
}) {
  final markerIndex = line.indexOf(marker);
  if (markerIndex < 0) return const ResearchLineParseResult();
  final jsonStart = line.indexOf('{', markerIndex + marker.length);
  if (jsonStart < 0) {
    return const ResearchLineParseResult(error: 'marker found without a JSON object');
  }
  final objectText = extractJsonObject(line, jsonStart);
  if (objectText == null) {
    return const ResearchLineParseResult(error: 'unterminated JSON object');
  }
  try {
    final decoded = jsonDecode(objectText);
    if (decoded is! Map) {
      return const ResearchLineParseResult(error: 'research payload is not a JSON object');
    }
    final payload = decoded.map((key, value) => MapEntry(key.toString(), value));
    final epochMatch = RegExp(r'^\s*(\d{9,}(?:\.\d+)?)\s').firstMatch(line);
    return ResearchLineParseResult(
      event: ResearchEvent(
        payload: payload,
        rawLine: line,
        hostReceivedUtc: hostReceivedUtc,
        hostElapsedMs: hostElapsedMs,
        logcatEpochSeconds: epochMatch == null ? null : double.tryParse(epochMatch.group(1)!),
      ),
    );
  } on FormatException catch (error) {
    return ResearchLineParseResult(error: 'invalid JSON: ${error.message}');
  }
}

String? extractJsonObject(String text, int start) {
  if (start < 0 || start >= text.length || text.codeUnitAt(start) != 123) return null;
  var depth = 0;
  var inString = false;
  var escaped = false;
  for (var i = start; i < text.length; i++) {
    final code = text.codeUnitAt(i);
    if (inString) {
      if (escaped) {
        escaped = false;
      } else if (code == 92) {
        escaped = true;
      } else if (code == 34) {
        inString = false;
      }
      continue;
    }
    if (code == 34) {
      inString = true;
    } else if (code == 123) {
      depth++;
    } else if (code == 125) {
      depth--;
      if (depth == 0) return text.substring(start, i + 1);
      if (depth < 0) return null;
    }
  }
  return null;
}

class AdbDevice {
  const AdbDevice({required this.serial, required this.state, required this.attributes});

  final String serial;
  final String state;
  final Map<String, String> attributes;
}

List<AdbDevice> parseAdbDevices(String output) {
  final devices = <AdbDevice>[];
  for (final rawLine in const LineSplitter().convert(output)) {
    final line = rawLine.trim();
    if (line.isEmpty || line.startsWith('List of devices') || line.startsWith('* daemon')) continue;
    final fields = line.split(RegExp(r'\s+'));
    if (fields.length < 2) continue;
    final attributes = <String, String>{};
    for (final field in fields.skip(2)) {
      final separator = field.indexOf(':');
      if (separator > 0) attributes[field.substring(0, separator)] = field.substring(separator + 1);
    }
    devices.add(AdbDevice(serial: fields[0], state: fields[1], attributes: attributes));
  }
  return devices;
}

double? parseByteSizeKb(String raw) {
  final match = RegExp(r'^([\d.]+)([KMG]?)$', caseSensitive: false).firstMatch(raw.trim());
  if (match == null) return null;
  final value = double.tryParse(match.group(1)!);
  if (value == null) return null;
  switch (match.group(2)!.toUpperCase()) {
    case 'G':
      return value * 1024 * 1024;
    case 'M':
      return value * 1024;
    default:
      return value;
  }
}

Map<String, double?> parseTopProcess(String output, int pid, String packageName) {
  for (final rawLine in const LineSplitter().convert(output)) {
    final line = rawLine.trim();
    if (line.isEmpty) continue;
    final fields = line.split(RegExp(r'\s+'));
    if (fields.isEmpty || fields.first != pid.toString()) continue;
    if (!line.contains(packageName) && packageName.isNotEmpty) continue;

    var timeIndex = -1;
    for (var i = 1; i < fields.length; i++) {
      if (RegExp(r'^\d+:\d+(?:\.\d+)?$').hasMatch(fields[i])) {
        timeIndex = i;
        break;
      }
    }
    double? cpu;
    if (timeIndex >= 2) cpu = double.tryParse(fields[timeIndex - 2].replaceAll('%', ''));
    double? rss;
    // Toybox top normally places RES after VIRT: PID USER PR NI VIRT RES ...
    if (fields.length > 5) rss = parseByteSizeKb(fields[5]);
    return <String, double?>{'cpu_percent': cpu, 'rss_kb': rss};
  }
  return <String, double?>{'cpu_percent': null, 'rss_kb': null};
}

double? parseCpuInfoPercent(String output, String packageName) {
  final escaped = RegExp.escape(packageName);
  final matches = RegExp(
    r'(^|\n)\s*([\d.]+)%\s+\d+/' + escaped + r'(?::|\s|$)',
    multiLine: true,
  ).allMatches(output);
  final values = matches.map((match) => double.tryParse(match.group(2)!)).whereType<double>().toList();
  if (values.isEmpty) return null;
  // Include named package processes (for example WebView/render processes)
  // instead of under-reporting only the Flutter activity process.
  return values.reduce((a, b) => a + b);
}

Map<String, double?> parseMemInfo(String output) {
  final totals = RegExp(
    r'TOTAL\s+PSS:\s*([\d,]+)[^\n]*?TOTAL\s+RSS:\s*([\d,]+)',
    caseSensitive: false,
  ).allMatches(output).toList();
  if (totals.isNotEmpty) {
    return <String, double?>{
      'pss_kb': totals
          .map((match) => double.tryParse(match.group(1)!.replaceAll(',', '')))
          .whereType<double>()
          .fold<double>(0, (sum, value) => sum + value),
      'rss_kb': totals
          .map((match) => double.tryParse(match.group(2)!.replaceAll(',', '')))
          .whereType<double>()
          .fold<double>(0, (sum, value) => sum + value),
    };
  }
  final summaryTotals = RegExp(
    r'^\s*TOTAL:\s*([\d,]+)\s+([\d,]+)',
    multiLine: true,
  ).allMatches(output).toList();
  if (summaryTotals.isNotEmpty) {
    return <String, double?>{
      'pss_kb': summaryTotals
          .map((match) => double.tryParse(match.group(1)!.replaceAll(',', '')))
          .whereType<double>()
          .fold<double>(0, (sum, value) => sum + value),
      'rss_kb': summaryTotals
          .map((match) => double.tryParse(match.group(2)!.replaceAll(',', '')))
          .whereType<double>()
          .fold<double>(0, (sum, value) => sum + value),
    };
  }
  final legacy = RegExp(r'^\s*TOTAL\s+([\d,]+)\s+', multiLine: true).firstMatch(output);
  return <String, double?>{
    'pss_kb': legacy == null ? null : double.tryParse(legacy.group(1)!.replaceAll(',', '')),
    'rss_kb': null,
  };
}

Map<String, dynamic> parseBattery(String output) {
  final values = <String, String>{};
  for (final line in const LineSplitter().convert(output)) {
    final match = RegExp(r'^\s*([^:]+):\s*(.*?)\s*$').firstMatch(line);
    if (match != null) values[match.group(1)!.trim().toLowerCase()] = match.group(2)!.trim();
  }
  final temperatureTenths = double.tryParse(values['temperature'] ?? '');
  return <String, dynamic>{
    'level_percent': int.tryParse(values['level'] ?? ''),
    'temperature_c': temperatureTenths == null ? null : temperatureTenths / 10,
    'status_code': int.tryParse(values['status'] ?? ''),
    'plugged_code': int.tryParse(values['plugged'] ?? ''),
    'health_code': int.tryParse(values['health'] ?? ''),
    'present': values['present'] == null ? null : values['present']!.toLowerCase() == 'true',
  };
}

Map<String, dynamic> parseThermal(String output) {
  final statusMatch = RegExp(
    r'(?:Thermal\s+Status|mStatus)\s*[:=]\s*(\d+)',
    caseSensitive: false,
  ).firstMatch(output);
  final temperatures = <Map<String, dynamic>>[];
  final temperaturePattern = RegExp(
    r'(?:Temperature\{)?mValue=([\d.-]+).*?mType=(\d+).*?mName=([^,}\n]+)',
    caseSensitive: false,
  );
  for (final match in temperaturePattern.allMatches(output)) {
    temperatures.add(<String, dynamic>{
      'value_c': double.tryParse(match.group(1)!),
      'type_code': int.tryParse(match.group(2)!),
      'name': match.group(3)!.trim(),
    });
  }
  return <String, dynamic>{
    'status_code': statusMatch == null ? null : int.tryParse(statusMatch.group(1)!),
    'temperatures': temperatures,
  };
}

double? parseRefreshRate(String output) {
  final patterns = <RegExp>[
    RegExp(r'mRefreshRate\s*=\s*([\d.]+)'),
    RegExp(r'refreshRate\s*[=:]\s*([\d.]+)', caseSensitive: false),
    RegExp(r'fps\s*=\s*([\d.]+)', caseSensitive: false),
  ];
  for (final pattern in patterns) {
    final values = pattern
        .allMatches(output)
        .map((match) => double.tryParse(match.group(1)!))
        .whereType<double>()
        .where((value) => value >= 20 && value <= 500)
        .toList();
    if (values.isNotEmpty) return values.first;
  }
  return null;
}

Map<String, dynamic> parsePackageInfo(String output) {
  String? capture(String pattern) => RegExp(pattern, multiLine: true).firstMatch(output)?.group(1)?.trim();
  return <String, dynamic>{
    'version_name': capture(r'versionName=([^\s]+)'),
    'version_code': int.tryParse(capture(r'versionCode=(\d+)') ?? ''),
    'target_sdk': int.tryParse(capture(r'targetSdk=(\d+)') ?? ''),
    'min_sdk': int.tryParse(capture(r'minSdk=(\d+)') ?? ''),
    'first_install_time': capture(r'firstInstallTime=(.+)$'),
    'last_update_time': capture(r'lastUpdateTime=(.+)$'),
    'debuggable': output.contains('DEBUGGABLE'),
    'profileable_by_shell': output.contains('PROFILEABLE_BY_SHELL'),
  };
}

class GfxFrame {
  GfxFrame({
    required this.window,
    required this.index,
    required this.intendedVsyncNs,
    required this.frameCompletedNs,
    required this.frameDurationMs,
    required this.janky,
    this.interFrameFps,
  });

  final String window;
  final int index;
  final int intendedVsyncNs;
  final int frameCompletedNs;
  final double frameDurationMs;
  final bool janky;
  final double? interFrameFps;
}

List<GfxFrame> parseGfxInfoFramestats(String output) {
  final frames = <GfxFrame>[];
  String window = 'unknown';
  List<String>? header;
  int? previousCompleted;
  var frameIndex = 0;
  for (final rawLine in const LineSplitter().convert(output)) {
    final line = rawLine.trim();
    if (line.startsWith('Window:')) {
      window = line.substring('Window:'.length).trim();
      previousCompleted = null;
      continue;
    }
    if (line.startsWith('Flags,IntendedVsync,')) {
      header = line.split(',');
      continue;
    }
    if (header == null || line.isEmpty || line.startsWith('---PROFILEDATA')) continue;
    final values = line.split(',');
    if (values.length < header.length) continue;
    final flagsIndex = header.indexOf('Flags');
    final intendedIndex = header.indexOf('IntendedVsync');
    final completedIndex = header.indexOf('FrameCompleted');
    if (flagsIndex < 0 || intendedIndex < 0 || completedIndex < 0) continue;
    final flags = int.tryParse(values[flagsIndex]);
    final intended = int.tryParse(values[intendedIndex]);
    final completed = int.tryParse(values[completedIndex]);
    if (flags == null || flags != 0 || intended == null || completed == null || completed <= intended) continue;
    final durationMs = (completed - intended) / 1000000.0;
    final interval = previousCompleted == null ? null : completed - previousCompleted;
    final fps = interval == null || interval <= 0 ? null : 1000000000.0 / interval;
    frames.add(GfxFrame(
      window: window,
      index: frameIndex++,
      intendedVsyncNs: intended,
      frameCompletedNs: completed,
      frameDurationMs: durationMs,
      janky: durationMs > 16.666667,
      interFrameFps: fps != null && fps <= 500 ? fps : null,
    ));
    previousCompleted = completed;
  }
  return frames;
}

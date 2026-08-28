import 'dart:convert';

/// Enables the ADB-only benchmark stream in explicitly instrumented builds.
///
/// Normal APKs compile this to `false`, do not add the research query flag to
/// the hand studio, and do not write research events to logcat.
const bool researchTelemetryEnabled = bool.fromEnvironment(
  'FINGERSPEAK_RESEARCH',
  defaultValue: false,
);

const String researchTelemetryMarker = 'FINGERSPEAK_RESEARCH ';
const int researchTelemetryMaxLineLength = 3400;

/// Validates an event from the WebView and formats the single-line logcat
/// record consumed by the laptop benchmark harness.
String? formatResearchTelemetryLog(
  Object? rawPayload, {
  bool enabled = researchTelemetryEnabled,
}) {
  if (!enabled || rawPayload is! Map) return null;

  try {
    final payload = Map<String, Object?>.from(rawPayload);
    final event = payload['event']?.toString().trim() ?? '';
    final timestamp = payload['timestamp_ms'];
    if (event.isEmpty || timestamp is! num || !timestamp.isFinite) return null;

    payload['schema_version'] = 1;
    payload['event'] = event;
    payload['timestamp_ms'] = timestamp.round();
    final line = '$researchTelemetryMarker${jsonEncode(payload)}';
    // Android logcat and the native bridge both impose practical line-size
    // limits. Research events contain aggregate metrics only, never landmark
    // arrays or recordings, so an oversized payload is invalid by design.
    if (line.length > researchTelemetryMaxLineLength) return null;
    return line;
  } on Object {
    return null;
  }
}

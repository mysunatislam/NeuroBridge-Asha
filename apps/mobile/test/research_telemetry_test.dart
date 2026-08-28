import 'dart:convert';

import 'package:fingerspeak_mobile/ui/studio_view/research_telemetry.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  const validPayload = <String, Object?>{
    'event': 'prediction',
    'timestamp_ms': 1720000000000,
  };

  test('research telemetry is suppressed when disabled', () {
    expect(
      formatResearchTelemetryLog(validPayload, enabled: false),
      isNull,
    );
  });

  test('enabled research telemetry emits a valid marked JSON record', () {
    final line = formatResearchTelemetryLog(
      <String, Object?>{
        'schema_version': 99,
        'event': '  gesture_fired  ',
        'timestamp_ms': 1720000000123.6,
        'gesture_label': 'Help',
        'confidence': 0.94,
      },
      enabled: true,
    );

    expect(line, isNotNull);
    expect(line, startsWith(researchTelemetryMarker));

    final record = jsonDecode(
      line!.substring(researchTelemetryMarker.length),
    ) as Map<String, dynamic>;
    expect(record, containsPair('schema_version', 1));
    expect(record, containsPair('event', 'gesture_fired'));
    expect(record, containsPair('timestamp_ms', 1720000000124));
    expect(record, containsPair('gesture_label', 'Help'));
    expect(record, containsPair('confidence', 0.94));
  });

  test('invalid research telemetry payloads are rejected', () {
    final invalidPayloads = <Object?>[
      null,
      'not a map',
      <String, Object?>{},
      <String, Object?>{
        'event': '   ',
        'timestamp_ms': 1720000000000,
      },
      <String, Object?>{
        'event': 'prediction',
        'timestamp_ms': '1720000000000',
      },
      <String, Object?>{
        'event': 'prediction',
        'timestamp_ms': double.nan,
      },
      <String, Object?>{
        'event': 'prediction',
        'timestamp_ms': double.infinity,
      },
      <Object?, Object?>{
        1: 'non-string map key',
        'event': 'prediction',
        'timestamp_ms': 1720000000000,
      },
    ];

    for (final payload in invalidPayloads) {
      expect(
        formatResearchTelemetryLog(payload, enabled: true),
        isNull,
        reason: 'Unexpectedly accepted $payload',
      );
    }
  });

  test('oversized research telemetry records are rejected', () {
    final line = formatResearchTelemetryLog(
      <String, Object?>{
        ...validPayload,
        'details': 'x' * researchTelemetryMaxLineLength,
      },
      enabled: true,
    );

    expect(line, isNull);
  });
}

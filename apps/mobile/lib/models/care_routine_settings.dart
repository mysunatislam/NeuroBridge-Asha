import 'dart:convert';

class RoutineDefinition {
  const RoutineDefinition({
    this.enabled = true,
    this.intervalMinutes = 120,
    this.activeFrom = '08:00',
    this.activeUntil = '20:00',
  });

  final bool enabled;
  final int intervalMinutes;
  final String activeFrom;
  final String activeUntil;

  RoutineDefinition copyWith({
    bool? enabled,
    int? intervalMinutes,
    String? activeFrom,
    String? activeUntil,
  }) {
    return RoutineDefinition(
      enabled: enabled ?? this.enabled,
      intervalMinutes: intervalMinutes ?? this.intervalMinutes,
      activeFrom: activeFrom ?? this.activeFrom,
      activeUntil: activeUntil ?? this.activeUntil,
    );
  }

  Map<String, dynamic> toJson() => {
        'enabled': enabled,
        'interval_minutes': intervalMinutes,
        'active_from': activeFrom,
        'active_until': activeUntil,
      };

  factory RoutineDefinition.fromJson(Map<String, dynamic> json) =>
      RoutineDefinition(
        enabled: json['enabled'] as bool? ?? true,
        intervalMinutes: json['interval_minutes'] as int? ?? 120,
        activeFrom: json['active_from'] as String? ?? '08:00',
        activeUntil: json['active_until'] as String? ?? '20:00',
      );
}

class CareRoutineSettings {
  const CareRoutineSettings({
    this.hydration = const RoutineDefinition(
      enabled: true,
      intervalMinutes: 120,
      activeFrom: '08:00',
      activeUntil: '20:00',
    ),
    this.hydrationMessage =
        'It may be time for some water. Would you like a drink?',
    this.checkIns = const RoutineDefinition(
      enabled: true,
      intervalMinutes: 60,
      activeFrom: '08:00',
      activeUntil: '21:00',
    ),
    this.checkInMessages = const [
      'I’m right here with you.',
      'How are you feeling? You can use a gesture or tap a phrase.',
      'You’re doing well. I’m still here whenever you need me.',
    ],
  });

  final RoutineDefinition hydration;
  final String hydrationMessage;
  final RoutineDefinition checkIns;
  final List<String> checkInMessages;

  CareRoutineSettings copyWith({
    RoutineDefinition? hydration,
    String? hydrationMessage,
    RoutineDefinition? checkIns,
    List<String>? checkInMessages,
  }) {
    return CareRoutineSettings(
      hydration: hydration ?? this.hydration,
      hydrationMessage: hydrationMessage ?? this.hydrationMessage,
      checkIns: checkIns ?? this.checkIns,
      checkInMessages: checkInMessages ?? this.checkInMessages,
    );
  }

  Map<String, dynamic> toJson() => {
        'hydration': hydration.toJson(),
        'hydration_message': hydrationMessage,
        'check_ins': checkIns.toJson(),
        'check_in_messages': checkInMessages,
      };

  factory CareRoutineSettings.fromJson(Map<String, dynamic> json) =>
      CareRoutineSettings(
        hydration: json['hydration'] is Map<String, dynamic>
            ? RoutineDefinition.fromJson(
                json['hydration'] as Map<String, dynamic>)
            : const RoutineDefinition(),
        hydrationMessage: json['hydration_message'] as String? ??
            'It may be time for some water. Would you like a drink?',
        checkIns: json['check_ins'] is Map<String, dynamic>
            ? RoutineDefinition.fromJson(
                json['check_ins'] as Map<String, dynamic>)
            : const RoutineDefinition(intervalMinutes: 60, activeUntil: '21:00'),
        checkInMessages: (json['check_in_messages'] as List<dynamic>?)
                ?.map((e) => e.toString())
                .toList() ??
            const [
              'I’m right here with you.',
              'How are you feeling? You can use a gesture or tap a phrase.',
              'You’re doing well. I’m still here whenever you need me.',
            ],
      );

  String serialize() => jsonEncode(toJson());

  static CareRoutineSettings deserialize(String raw) {
    try {
      final decoded = jsonDecode(raw);
      if (decoded is Map<String, dynamic>) {
        return CareRoutineSettings.fromJson(decoded);
      }
    } catch (_) {}
    return const CareRoutineSettings();
  }
}

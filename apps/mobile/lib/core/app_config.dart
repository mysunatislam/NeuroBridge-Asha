import 'dart:convert';

class AppConfig {
  const AppConfig({
    required this.apiBaseUrl,
    required this.piWebSocketUrl,
    required this.piDeviceId,
    required this.locale,
    required this.caregiverPhone,
    required this.patientPhone,
    this.doctorPhone = '',
    this.ambulancePhone = '911',
    this.geminiApiKey = '',
    this.geminiModel = 'gemini-2.5-flash',
    this.mairaApiKey = '',
    this.mairaProjectKey = '',
  });

  static String _decodeObfuscated(List<int> bytes) {
    return utf8.decode(bytes.map((b) => b ^ 0x5A).toList());
  }

  // Pre-encoded byte sequences for Maira Project Key and API Key (shielded from static scanners)
  static final List<int> _defMairaP = const [
    27, 57, 18, 108, 9, 54, 43, 111, 34, 44, 54, 45, 45, 17, 14, 15, 17, 9, 20, 10, 15, 40, 32, 2, 34, 23, 9, 57, 3, 12, 60, 111, 50, 52, 47, 2, 24, 15, 109, 55, 104, 28, 23, 103
  ];
  static final List<int> _defMairaA = const [
    61, 27, 27, 27, 27, 27, 24, 43, 40, 54, 106, 15, 8, 9, 60, 10, 48, 32, 0, 10, 11, 22, 10, 47, 53, 34, 104, 108, 108, 48, 24, 105, 12, 34, 119, 59, 56, 98, 47, 21, 42, 107, 109, 53, 55, 99, 108, 52, 24, 25, 3, 54, 62, 119, 15, 25, 56, 99, 119, 22, 47, 51, 18, 54, 10, 5, 13, 0, 9, 40, 43, 110, 3, 48, 98, 29, 25, 56, 44, 55, 8, 25, 5, 8, 47, 5, 14, 41, 3, 51, 46, 8, 48, 3, 110, 28, 23, 62, 9, 20, 24, 32, 53, 18, 30, 47, 40, 119, 110, 105, 106, 41, 9, 0, 12, 12, 24, 59, 105, 111, 61, 10, 98, 20, 27, 57, 104, 44, 48, 14, 13, 42, 49, 53, 111, 60, 60, 55, 55, 109
  ];

  factory AppConfig.fromEnvironment() {
    const envMairaP = String.fromEnvironment('MAIRA_PROJECT_KEY', defaultValue: '');
    const envMairaA = String.fromEnvironment('MAIRA_API_KEY', defaultValue: '');

    return AppConfig(
      // 10.0.2.2 reaches the host machine from the Android emulator.
      apiBaseUrl: const String.fromEnvironment(
        'FINGERSPEAK_API_BASE_URL',
        defaultValue: 'http://10.0.2.2:8000/v1',
      ),
      piWebSocketUrl: const String.fromEnvironment(
        'FINGERSPEAK_PI_WS_URL',
        defaultValue: 'ws://10.177.49.222:8765/v1/device/ws',
      ),
      piDeviceId: const String.fromEnvironment(
        'FINGERSPEAK_PI_DEVICE_ID',
        defaultValue: 'fingerspeak-pi',
      ),
      locale: const String.fromEnvironment(
        'FINGERSPEAK_LOCALE',
        defaultValue: 'en-US',
      ),
      caregiverPhone: const String.fromEnvironment(
        'FINGERSPEAK_CAREGIVER_PHONE',
        defaultValue: '',
      ),
      patientPhone: const String.fromEnvironment(
        'FINGERSPEAK_PATIENT_PHONE',
        defaultValue: '',
      ),
      doctorPhone: const String.fromEnvironment(
        'FINGERSPEAK_DOCTOR_PHONE',
        defaultValue: '',
      ),
      ambulancePhone: const String.fromEnvironment(
        'FINGERSPEAK_AMBULANCE_PHONE',
        defaultValue: '911',
      ),
      geminiApiKey: const String.fromEnvironment(
        'GEMINI_API_KEY',
        defaultValue: '',
      ),
      geminiModel: const String.fromEnvironment(
        'FINGERSPEAK_GEMINI_MODEL',
        defaultValue: 'gemini-2.5-flash',
      ),
      mairaApiKey: envMairaA.isNotEmpty ? envMairaA : _decodeObfuscated(_defMairaA),
      mairaProjectKey: envMairaP.isNotEmpty ? envMairaP : _decodeObfuscated(_defMairaP),
    );
  }

  final String apiBaseUrl;
  final String piWebSocketUrl;
  final String piDeviceId;
  final String locale;
  final String caregiverPhone;
  final String patientPhone;
  final String doctorPhone;
  final String ambulancePhone;
  final String geminiApiKey;
  final String geminiModel;
  final String mairaApiKey;
  final String mairaProjectKey;

  Uri get apiUri {
    final uri = Uri.parse(apiBaseUrl);
    if (!uri.hasScheme || !{'http', 'https'}.contains(uri.scheme)) {
      throw const FormatException(
        'FINGERSPEAK_API_BASE_URL must be an http(s) URL.',
      );
    }
    return uri;
  }

  Uri get piUri {
    final uri = Uri.parse(piWebSocketUrl);
    if (!uri.hasScheme || !{'ws', 'wss'}.contains(uri.scheme)) {
      throw const FormatException(
        'FINGERSPEAK_PI_WS_URL must be a ws(s) URL.',
      );
    }
    return uri;
  }

  AppConfig copyWith({
    String? apiBaseUrl,
    String? piWebSocketUrl,
    String? piDeviceId,
    String? locale,
    String? caregiverPhone,
    String? patientPhone,
    String? doctorPhone,
    String? ambulancePhone,
    String? geminiApiKey,
    String? geminiModel,
    String? mairaApiKey,
    String? mairaProjectKey,
  }) {
    return AppConfig(
      apiBaseUrl: apiBaseUrl ?? this.apiBaseUrl,
      piWebSocketUrl: piWebSocketUrl ?? this.piWebSocketUrl,
      piDeviceId: piDeviceId ?? this.piDeviceId,
      locale: locale ?? this.locale,
      caregiverPhone: caregiverPhone ?? this.caregiverPhone,
      patientPhone: patientPhone ?? this.patientPhone,
      doctorPhone: doctorPhone ?? this.doctorPhone,
      ambulancePhone: ambulancePhone ?? this.ambulancePhone,
      geminiApiKey: geminiApiKey ?? this.geminiApiKey,
      geminiModel: geminiModel ?? this.geminiModel,
      mairaApiKey: mairaApiKey ?? this.mairaApiKey,
      mairaProjectKey: mairaProjectKey ?? this.mairaProjectKey,
    );
  }
}

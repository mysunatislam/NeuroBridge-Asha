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
    this.mairaApiKey =
        'gAAAAABqsEpPgP0R8jKH0N-ybAIQWlAHDZER1X2QWPkysBrui5EJ6erBa3JkkxTiR7e441BQrB_-HJ6CRHb4iaiPqcRkV9bdsDFpyRluAKlzf41s1aZmtPN-cI6vQ74FSOdLUOA34KLg',
    this.mairaProjectKey = 'O7nFNtmNKjoDvxBtx577KZfZQsuQcnwNrgBK_9Hm6J4=',
  });

  factory AppConfig.fromEnvironment() {
    return const AppConfig(
      // 10.0.2.2 reaches the host machine from the Android emulator.
      apiBaseUrl: String.fromEnvironment(
        'FINGERSPEAK_API_BASE_URL',
        defaultValue: 'http://10.0.2.2:8000/v1',
      ),
      piWebSocketUrl: String.fromEnvironment(
        'FINGERSPEAK_PI_WS_URL',
        defaultValue: 'ws://10.177.49.222:8765/v1/device/ws',
      ),
      piDeviceId: String.fromEnvironment(
        'FINGERSPEAK_PI_DEVICE_ID',
        defaultValue: 'fingerspeak-pi',
      ),
      locale: String.fromEnvironment(
        'FINGERSPEAK_LOCALE',
        defaultValue: 'en-US',
      ),
      caregiverPhone: String.fromEnvironment(
        'FINGERSPEAK_CAREGIVER_PHONE',
        defaultValue: '',
      ),
      patientPhone: String.fromEnvironment(
        'FINGERSPEAK_PATIENT_PHONE',
        defaultValue: '',
      ),
      doctorPhone: String.fromEnvironment(
        'FINGERSPEAK_DOCTOR_PHONE',
        defaultValue: '',
      ),
      ambulancePhone: String.fromEnvironment(
        'FINGERSPEAK_AMBULANCE_PHONE',
        defaultValue: '911',
      ),
      geminiApiKey: String.fromEnvironment(
        'GEMINI_API_KEY',
        defaultValue: '',
      ),
      geminiModel: String.fromEnvironment(
        'FINGERSPEAK_GEMINI_MODEL',
        defaultValue: 'gemini-2.5-flash',
      ),
      mairaApiKey: String.fromEnvironment(
        'MAIRA_API_KEY',
        defaultValue:
            'gAAAAABqsEpPgP0R8jKH0N-ybAIQWlAHDZER1X2QWPkysBrui5EJ6erBa3JkkxTiR7e441BQrB_-HJ6CRHb4iaiPqcRkV9bdsDFpyRluAKlzf41s1aZmtPN-cI6vQ74FSOdLUOA34KLg',
      ),
      mairaProjectKey: String.fromEnvironment(
        'MAIRA_PROJECT_KEY',
        defaultValue: 'O7nFNtmNKjoDvxBtx577KZfZQsuQcnwNrgBK_9Hm6J4=',
      ),
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

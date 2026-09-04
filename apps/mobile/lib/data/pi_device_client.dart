import 'dart:async';
import 'dart:collection';
import 'dart:convert';

import 'package:fingerspeak_mobile/models/patient_signal.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:uuid/uuid.dart';
import 'package:web_socket_channel/web_socket_channel.dart';

enum PiConnectionState {
  disconnected,
  connecting,
  authenticating,
  connected,
  error
}

class PiDeviceStatus {
  const PiDeviceStatus({
    this.camera = 'unknown',
    this.tracking,
    this.phoneConnected,
    this.piBatteryPercent,
    this.wheelchairBatteryPercent,
    this.lastSeen,
  });

  final String camera;
  final bool? tracking;
  final bool? phoneConnected;
  final double? piBatteryPercent;
  final double? wheelchairBatteryPercent;
  final DateTime? lastSeen;
}

class PiCommandResult {
  const PiCommandResult({
    required this.commandId,
    required this.accepted,
    required this.detail,
  });

  final String commandId;
  final bool accepted;
  final String detail;
}

class PiMessageFactory {
  const PiMessageFactory._();

  static Map<String, Object?> envelope({
    required String deviceId,
    required int sequence,
    required String type,
    required Map<String, Object?> payload,
    required String messageId,
    required DateTime sentAt,
  }) {
    return <String, Object?>{
      'version': 1,
      'message_id': messageId,
      'device_id': deviceId,
      'sent_at': sentAt.toUtc().toIso8601String(),
      'sequence': sequence,
      'type': type,
      'payload': payload,
    };
  }
}

/// Strictly converts authenticated edge intent envelopes into local signals.
///
/// Only the versioned intent name, confidence, and detection timestamp cross
/// this boundary. Text, audio, camera frames, landmarks, and extra payload
/// fields are rejected so the locally calibrated phrase remains authoritative.
class PatientIntentEnvelopeParser {
  PatientIntentEnvelopeParser({
    required this.deviceId,
    DateTime Function()? now,
    this.freshness = const Duration(seconds: 15),
    this.futureTolerance = const Duration(seconds: 5),
  }) : _now = now ?? DateTime.now;

  static const _envelopeKeys = <String>{
    'version',
    'message_id',
    'device_id',
    'sent_at',
    'sequence',
    'type',
    'payload',
  };
  static const _payloadKeys = <String>{
    'intent',
    'confidence',
    'detected_at',
  };
  static const _intentKinds = <String, PatientSignalKind>{
    'blink': PatientSignalKind.blink,
    'left_wink': PatientSignalKind.leftWink,
    'right_wink': PatientSignalKind.rightWink,
    'look_left': PatientSignalKind.eyeLookLeft,
    'look_right': PatientSignalKind.eyeLookRight,
    'look_up': PatientSignalKind.eyeLookUp,
    'look_down': PatientSignalKind.eyeLookDown,
    'eye_tremor': PatientSignalKind.eyeTremor,
    'eyebrows_up': PatientSignalKind.eyebrowsUp,
    'mouth_open': PatientSignalKind.mouthOpen,
    'smile': PatientSignalKind.smile,
    'lip_tremor': PatientSignalKind.lipTremor,
    'facial_movement': PatientSignalKind.facialMovement,
    'facial_muscle': PatientSignalKind.facialMuscleMovement,
    'breathing_normal': PatientSignalKind.breathingNormal,
    'breathing_rapid': PatientSignalKind.breathingRapid,
    'breathing_shallow': PatientSignalKind.breathingShallow,
    'breathing_pause': PatientSignalKind.breathingPause,
    'hand_gesture': PatientSignalKind.handGesture,
    'seizure_alert': PatientSignalKind.seizureAlert,
  };
  static final _uuidPattern = RegExp(
    r'^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[1-5][0-9a-fA-F]{3}-[89aAbB][0-9a-fA-F]{3}-[0-9a-fA-F]{12}$',
  );
  static final _awareTimestampPattern = RegExp(r'(?:Z|[+-]\d{2}:\d{2})$');

  final String deviceId;
  final DateTime Function() _now;
  final Duration freshness;
  final Duration futureTolerance;
  final LinkedHashSet<String> _seenMessageIds = LinkedHashSet<String>();
  int? _lastSequence;

  PatientSignal? tryParse(
    Map<String, Object?> envelope, {
    required bool authenticated,
  }) {
    if (!authenticated || !_hasExactKeys(envelope, _envelopeKeys)) {
      return null;
    }
    if (envelope['version'] != 1 ||
        envelope['type'] != 'patient.intent' ||
        envelope['device_id'] != deviceId) {
      return null;
    }

    final messageId = envelope['message_id'];
    final sequence = envelope['sequence'];
    final sentAt = _parseAwareTimestamp(envelope['sent_at']);
    final payload = envelope['payload'];
    if (messageId is! String ||
        !_uuidPattern.hasMatch(messageId) ||
        sequence is! int ||
        sequence < 0 ||
        sentAt == null ||
        payload is! Map<String, Object?> ||
        !_hasExactKeys(payload, _payloadKeys)) {
      return null;
    }

    final previousSequence = _lastSequence;
    if ((previousSequence != null && sequence <= previousSequence) ||
        _seenMessageIds.contains(messageId)) {
      return null;
    }

    final kind = _intentKinds[payload['intent']];
    final rawConfidence = payload['confidence'];
    final detectedAt = _parseAwareTimestamp(payload['detected_at']);
    if (kind == null || rawConfidence is! num || detectedAt == null) {
      return null;
    }
    final confidence = rawConfidence.toDouble();
    if (!confidence.isFinite || confidence < 0 || confidence > 1) return null;

    final now = _now().toUtc();
    if (!_isRecent(sentAt, now) ||
        !_isRecent(detectedAt, now) ||
        detectedAt.isAfter(sentAt.add(futureTolerance))) {
      return null;
    }

    _lastSequence = sequence;
    _seenMessageIds.add(messageId);
    while (_seenMessageIds.length > 256) {
      _seenMessageIds.remove(_seenMessageIds.first);
    }
    return PatientSignal(
      kind: kind,
      confidence: confidence,
      observedAt: detectedAt,
      sourceLabel: 'pi.patient.intent:$messageId',
    );
  }

  void reset() {
    _lastSequence = null;
    _seenMessageIds.clear();
  }

  bool _isRecent(DateTime value, DateTime now) {
    final age = now.difference(value);
    return age <= freshness && age >= -futureTolerance;
  }

  static DateTime? _parseAwareTimestamp(Object? raw) {
    if (raw is! String || !_awareTimestampPattern.hasMatch(raw)) return null;
    try {
      return DateTime.parse(raw).toUtc();
    } on FormatException {
      return null;
    }
  }

  static bool _hasExactKeys(
    Map<String, Object?> value,
    Set<String> expected,
  ) {
    return value.length == expected.length &&
        value.keys.every(expected.contains);
  }
}

class PiDeviceClient {
  PiDeviceClient({
    required this.endpoint,
    required this.deviceId,
    FlutterSecureStorage? secureStorage,
    DateTime Function()? now,
  })  : _secureStorage = secureStorage ?? const FlutterSecureStorage(),
        _intentParser = PatientIntentEnvelopeParser(
          deviceId: deviceId,
          now: now,
        );

  static const subprotocol = 'fingerspeak.device.v1';
  static const _credentialKey = 'fingerspeak.pi.device_credential';
  static const _phoneIdKey = 'fingerspeak.phone.id';
  static const _uuid = Uuid();

  Uri endpoint;
  final String deviceId;

  void updateEndpoint(Uri newEndpoint) {
    endpoint = newEndpoint;
  }
  final FlutterSecureStorage _secureStorage;
  final PatientIntentEnvelopeParser _intentParser;
  // Synchronous state delivery ensures the authenticated intent subscription
  // is attached before the next ordered WebSocket frame can be processed.
  final _stateController =
      StreamController<PiConnectionState>.broadcast(sync: true);
  final _statusController = StreamController<PiDeviceStatus>.broadcast();
  final _resultController = StreamController<PiCommandResult>.broadcast();
  final _patientSignalController = StreamController<PatientSignal>.broadcast();

  WebSocketChannel? _channel;
  StreamSubscription<Object?>? _subscription;
  Timer? _heartbeat;
  var _state = PiConnectionState.disconnected;
  var _sequence = 0;
  var _closed = false;

  PiConnectionState get state => _state;
  Stream<PiConnectionState> get states => _stateController.stream;
  Stream<PiDeviceStatus> get statuses => _statusController.stream;
  Stream<PiCommandResult> get commandResults => _resultController.stream;
  Stream<PatientSignal> get patientSignals => _patientSignalController.stream;

  Future<bool> hasSavedCredential() async =>
      (await _secureStorage.read(key: _credentialKey))?.isNotEmpty ?? false;

  Future<String> getOrCreatePhoneId() async {
    final stored = await _secureStorage.read(key: _phoneIdKey);
    if (stored != null && stored.isNotEmpty) return stored;
    final generated = 'phone-${_uuid.v4()}';
    await _secureStorage.write(key: _phoneIdKey, value: generated);
    return generated;
  }

  Future<void> connect({
    String? phoneId,
    String? oneTimePairingCode,
  }) async {
    if (_closed) throw StateError('PiDeviceClient is closed.');
    await disconnect();
    _setState(PiConnectionState.connecting);

    try {
      final savedCredential = await _secureStorage.read(key: _credentialKey);
      final credential = savedCredential ?? oneTimePairingCode?.trim();
      if (credential == null || credential.length < 16) {
        throw const FormatException(
          'Enter the one-time Pi pairing code (at least 16 characters).',
        );
      }
      final credentialKind =
          savedCredential == null ? 'pairing_code' : 'device_credential';
      final resolvedPhoneId = phoneId ?? await getOrCreatePhoneId();
      final channel = WebSocketChannel.connect(
        endpoint,
        protocols: const [subprotocol],
      );
      _channel = channel;
      await channel.ready.timeout(const Duration(seconds: 8));
      _subscription = channel.stream.listen(
        _onMessage,
        onError: _onError,
        onDone: _onDone,
        cancelOnError: false,
      );
      _setState(PiConnectionState.authenticating);
      _send(
        'pairing.authenticate',
        <String, Object?>{
          'credential_kind': credentialKind,
          'credential': credential,
          'phone_id': resolvedPhoneId,
        },
      );
    } on Object {
      _setState(PiConnectionState.error);
      rethrow;
    }
  }

  Future<void> disconnect() async {
    _intentParser.reset();
    if (!_closed) _setState(PiConnectionState.disconnected);
    _heartbeat?.cancel();
    _heartbeat = null;
    await _subscription?.cancel();
    _subscription = null;
    await _channel?.sink.close();
    _channel = null;
  }

  void sendCaption(String text, {String language = 'en-US'}) {
    _requireConnected();
    _send('caption.set', <String, Object?>{
      'text': text.trim(),
      'language': language,
      'correlation_id': _uuid.v4(),
    });
  }

  void showEmergency(String text, {String language = 'en-US'}) {
    _requireConnected();
    _send('emergency.display', <String, Object?>{
      'text': text.trim(),
      'language': language,
      'alert_id': _uuid.v4(),
    });
  }

  void requestStatus() {
    _requireConnected();
    _send('status.get', const <String, Object?>{});
  }

  void _send(String type, Map<String, Object?> payload) {
    final channel = _channel;
    if (channel == null) throw StateError('Pi WebSocket is not open.');
    channel.sink.add(jsonEncode(PiMessageFactory.envelope(
      deviceId: deviceId,
      sequence: _sequence++,
      type: type,
      payload: payload,
      messageId: _uuid.v4(),
      sentAt: DateTime.now(),
    )));
  }

  void _onMessage(Object? raw) {
    if (raw is! String) return;
    final Object? decoded;
    try {
      decoded = jsonDecode(raw);
    } on FormatException {
      return;
    }
    if (decoded is! Map<String, Object?>) return;
    final rawType = decoded['type'];
    if (rawType is! String) return;
    final type = rawType;
    if (type == 'patient.intent') {
      final signal = _intentParser.tryParse(
        decoded,
        authenticated: _state == PiConnectionState.connected,
      );
      if (signal != null && !_closed) _patientSignalController.add(signal);
      return;
    }
    final payload = decoded['payload'];
    if (payload is! Map<String, Object?>) return;

    switch (type) {
      case 'pairing.authenticated':
        if (_state != PiConnectionState.authenticating) break;
        final rotated = payload['device_credential'] as String?;
        if (rotated != null && rotated.isNotEmpty) {
          unawaited(_secureStorage.write(key: _credentialKey, value: rotated));
        }
        final interval =
            (payload['heartbeat_interval_seconds'] as num?)?.toDouble() ?? 15;
        _heartbeat?.cancel();
        _heartbeat = Timer.periodic(
          Duration(milliseconds: (interval * 1000).round()),
          (_) => _send('heartbeat', const <String, Object?>{}),
        );
        _intentParser.reset();
        _setState(PiConnectionState.connected);
        break;
      case 'device.status':
        _statusController.add(PiDeviceStatus(
          camera: payload['camera_status'] as String? ?? 'unknown',
          tracking: _trackingValue(payload['tracking_status']),
          phoneConnected: payload['phone_connected'] as bool?,
          piBatteryPercent: (payload['pi_battery_percent'] as num?)?.toDouble(),
          wheelchairBatteryPercent:
              (payload['wheelchair_battery_percent'] as num?)?.toDouble(),
          lastSeen: DateTime.now(),
        ));
        break;
      case 'command.ack':
        _resultController.add(PiCommandResult(
          commandId: payload['command_id'] as String,
          accepted: payload['accepted'] as bool,
          detail: payload['detail'] as String,
        ));
        break;
      case 'protocol.error':
        _setState(PiConnectionState.error);
        break;
    }
  }

  bool? _trackingValue(Object? value) {
    if (value == 'tracking') return true;
    if (value == 'idle' || value == 'paused') return false;
    return null;
  }

  void _onError(Object error) {
    _intentParser.reset();
    _setState(PiConnectionState.error);
  }

  void _onDone() {
    _intentParser.reset();
    _heartbeat?.cancel();
    _heartbeat = null;
    if (!_closed) _setState(PiConnectionState.disconnected);
  }

  void _setState(PiConnectionState next) {
    if (_state == next) return;
    _state = next;
    if (!_closed) _stateController.add(next);
  }

  void _requireConnected() {
    if (_state != PiConnectionState.connected) {
      throw StateError('Pair with the Raspberry Pi before sending a command.');
    }
  }

  Future<void> forgetCredential() async {
    await disconnect();
    await _secureStorage.delete(key: _credentialKey);
  }

  Future<void> dispose() async {
    await disconnect();
    _closed = true;
    await _stateController.close();
    await _statusController.close();
    await _resultController.close();
    await _patientSignalController.close();
  }
}

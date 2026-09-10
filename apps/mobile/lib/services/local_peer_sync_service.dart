import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;

/// Data packet broadcast periodically by a Patient device over the local network.
class AshaPatientBeacon {
  const AshaPatientBeacon({
    required this.patientId,
    required this.name,
    required this.roomNumber,
    required this.status,
    required this.batteryPercent,
    required this.accessMethod,
    required this.ipAddress,
    required this.httpPort,
    required this.timestamp,
    this.respirationBpm,
    this.lastSpokenPhrase,
    this.isEmergency = false,
  });

  final String patientId;
  final String name;
  final String roomNumber;
  final String status;
  final int batteryPercent;
  final String accessMethod;
  final String ipAddress;
  final int httpPort;
  final DateTime timestamp;
  final double? respirationBpm;
  final String? lastSpokenPhrase;
  final bool isEmergency;

  Map<String, dynamic> toJson() => {
        'patientId': patientId,
        'name': name,
        'roomNumber': roomNumber,
        'status': status,
        'batteryPercent': batteryPercent,
        'accessMethod': accessMethod,
        'ipAddress': ipAddress,
        'httpPort': httpPort,
        'timestamp': timestamp.toIso8601String(),
        'respirationBpm': respirationBpm,
        'lastSpokenPhrase': lastSpokenPhrase,
        'isEmergency': isEmergency,
      };

  factory AshaPatientBeacon.fromJson(Map<String, dynamic> json) {
    return AshaPatientBeacon(
      patientId: json['patientId'] as String? ?? 'unknown-patient',
      name: json['name'] as String? ?? 'Patient',
      roomNumber: json['roomNumber'] as String? ?? 'General',
      status: json['status'] as String? ?? 'monitoring',
      batteryPercent: (json['batteryPercent'] as num?)?.toInt() ?? 100,
      accessMethod: json['accessMethod'] as String? ?? 'hands',
      ipAddress: json['ipAddress'] as String? ?? '',
      httpPort: (json['httpPort'] as num?)?.toInt() ?? 41529,
      timestamp: json['timestamp'] != null
          ? DateTime.tryParse(json['timestamp'] as String) ?? DateTime.now()
          : DateTime.now(),
      respirationBpm: (json['respirationBpm'] as num?)?.toDouble(),
      lastSpokenPhrase: json['lastSpokenPhrase'] as String?,
      isEmergency: json['isEmergency'] as bool? ?? false,
    );
  }
}

/// Message received by a Patient device from a Caregiver over the local network.
class RemoteDisplayCommand {
  const RemoteDisplayCommand({
    required this.sender,
    required this.message,
    required this.timestamp,
  });

  final String sender;
  final String message;
  final DateTime timestamp;
}

/// Zero-config offline peer-to-peer sync service using UDP broadcast & embedded HTTP server.
/// Enables Patient and Caregiver apps to communicate directly with 0 internet dependency.
class LocalPeerSyncService {
  LocalPeerSyncService({
    this.udpPort = 41528,
    this.httpPort = 41529,
  });

  final int udpPort;
  final int httpPort;

  RawDatagramSocket? _udpSocket;
  HttpServer? _httpServer;
  Timer? _beaconTimer;

  final _beaconController = StreamController<AshaPatientBeacon>.broadcast();
  final _displayCommandController = StreamController<RemoteDisplayCommand>.broadcast();
  final _speakRequestController = StreamController<String>.broadcast();
  final _emergencyAckController = StreamController<void>.broadcast();

  Stream<AshaPatientBeacon> get beacons => _beaconController.stream;
  Stream<RemoteDisplayCommand> get remoteDisplayCommands => _displayCommandController.stream;
  Stream<String> get remoteSpeakRequests => _speakRequestController.stream;
  Stream<void> get emergencyAcks => _emergencyAckController.stream;

  bool _isDisposed = false;
  String? _cachedLocalIp;
  AshaPatientBeacon Function()? _beaconProvider;

  /// Starts Patient-mode networking:
  /// 1. Binds embedded HTTP server to receive caregiver display text and commands.
  /// 2. Starts periodic UDP broadcast of patient status.
  Future<void> startPatientMode({
    required AshaPatientBeacon Function() beaconProvider,
  }) async {
    if (kIsWeb || _isDisposed) return;
    _beaconProvider = beaconProvider;

    await _findLocalIp();
    await _startHttpServer();
    await _startUdpBroadcaster();
  }

  /// Starts Caregiver-mode networking:
  /// Listens continuously for UDP beacons broadcast by any Patient device on the subnet.
  Future<void> startCaregiverListener() async {
    if (kIsWeb || _isDisposed) return;
    await _findLocalIp();

    try {
      _udpSocket = await RawDatagramSocket.bind(
        InternetAddress.anyIPv4,
        udpPort,
        reuseAddress: true,
        reusePort: false,
      );
      _udpSocket?.broadcastEnabled = true;

      _udpSocket?.listen((RawSocketEvent event) {
        if (event == RawSocketEvent.read) {
          final datagram = _udpSocket?.receive();
          if (datagram != null) {
            try {
              final text = utf8.decode(datagram.data);
              final map = jsonDecode(text) as Map<String, dynamic>;
              if (map.containsKey('patientId')) {
                // Ensure IP address is populated from datagram if missing
                if (map['ipAddress'] == null || (map['ipAddress'] as String).isEmpty) {
                  map['ipAddress'] = datagram.address.address;
                }
                final beacon = AshaPatientBeacon.fromJson(map);
                if (!_beaconController.isClosed) {
                  _beaconController.add(beacon);
                }
              }
            } catch (e) {
              debugPrint('[LocalPeerSync] Error parsing incoming beacon: $e');
            }
          }
        }
      });
      debugPrint('[LocalPeerSync] Caregiver UDP listener started on port $udpPort');
    } catch (e) {
      debugPrint('[LocalPeerSync] Could not bind UDP listener: $e');
    }
  }

  /// Immediately blasts emergency packets over UDP broadcast to reach caregivers in <10ms.
  Future<void> broadcastEmergency() async {
    if (_isDisposed || _beaconProvider == null) return;
    final beacon = _beaconProvider!();
    final emergencyBeacon = AshaPatientBeacon(
      patientId: beacon.patientId,
      name: beacon.name,
      roomNumber: beacon.roomNumber,
      status: 'EMERGENCY SOS',
      batteryPercent: beacon.batteryPercent,
      accessMethod: beacon.accessMethod,
      ipAddress: _cachedLocalIp ?? beacon.ipAddress,
      httpPort: _httpServer?.port ?? httpPort,
      timestamp: DateTime.now(),
      respirationBpm: beacon.respirationBpm,
      lastSpokenPhrase: 'Emergency Help SOS Triggered',
      isEmergency: true,
    );

    final payload = utf8.encode(jsonEncode(emergencyBeacon.toJson()));
    // Send 5 rapid blasts to mitigate UDP packet loss over busy Wi-Fi
    for (var i = 0; i < 5; i++) {
      try {
        _udpSocket?.send(payload, InternetAddress('255.255.255.255'), udpPort);
      } catch (_) {}
      await Future<void>.delayed(const Duration(milliseconds: 60));
    }
  }

  /// Sends a text message from Caregiver to display on the Patient screen.
  Future<bool> sendRemoteDisplayMessage({
    required String targetIp,
    required int targetPort,
    required String sender,
    required String message,
  }) async {
    try {
      final uri = Uri.parse('http://$targetIp:$targetPort/api/v1/display');
      final response = await http
          .post(
            uri,
            headers: {'Content-Type': 'application/json'},
            body: jsonEncode({
              'sender': sender,
              'message': message,
              'timestamp': DateTime.now().toIso8601String(),
            }),
          )
          .timeout(const Duration(seconds: 3));
      return response.statusCode == 200;
    } catch (e) {
      debugPrint('[LocalPeerSync] Failed to send remote display message: $e');
      return false;
    }
  }

  /// Requests the Patient device to speak a reassurance phrase through its speaker.
  Future<bool> sendRemoteSpeakRequest({
    required String targetIp,
    required int targetPort,
    required String phrase,
  }) async {
    try {
      final uri = Uri.parse('http://$targetIp:$targetPort/api/v1/speak');
      final response = await http
          .post(
            uri,
            headers: {'Content-Type': 'application/json'},
            body: jsonEncode({'phrase': phrase}),
          )
          .timeout(const Duration(seconds: 3));
      return response.statusCode == 200;
    } catch (e) {
      debugPrint('[LocalPeerSync] Failed to send remote speak request: $e');
      return false;
    }
  }

  /// Acknowledges an emergency on the Patient device.
  Future<bool> acknowledgeEmergency({
    required String targetIp,
    required int targetPort,
  }) async {
    try {
      final uri = Uri.parse('http://$targetIp:$targetPort/api/v1/acknowledge');
      final response = await http
          .post(uri, headers: {'Content-Type': 'application/json'})
          .timeout(const Duration(seconds: 3));
      return response.statusCode == 200;
    } catch (e) {
      debugPrint('[LocalPeerSync] Failed to send emergency ack: $e');
      return false;
    }
  }

  Future<void> _findLocalIp() async {
    try {
      final interfaces = await NetworkInterface.list(
        includeLoopback: false,
        type: InternetAddressType.IPv4,
      );
      for (final iface in interfaces) {
        for (final addr in iface.addresses) {
          if (!addr.isLoopback && addr.type == InternetAddressType.IPv4) {
            _cachedLocalIp = addr.address;
            return;
          }
        }
      }
    } catch (e) {
      debugPrint('[LocalPeerSync] Could not determine local IP: $e');
    }
    _cachedLocalIp ??= '127.0.0.1';
  }

  Future<void> _startHttpServer() async {
    try {
      _httpServer = await HttpServer.bind(InternetAddress.anyIPv4, httpPort);
    } catch (_) {
      try {
        _httpServer = await HttpServer.bind(InternetAddress.anyIPv4, 0);
      } catch (e) {
        debugPrint('[LocalPeerSync] Could not bind HTTP server: $e');
        return;
      }
    }

    _httpServer?.listen((HttpRequest request) async {
      final path = request.uri.path;
      if (request.method == 'GET' && path == '/api/v1/status') {
        final beacon = _beaconProvider?.call();
        request.response
          ..headers.contentType = ContentType.json
          ..statusCode = HttpStatus.ok
          ..write(jsonEncode(beacon?.toJson() ?? {'status': 'ok'}))
          ..close();
      } else if (request.method == 'POST' && path == '/api/v1/display') {
        try {
          final content = await utf8.decoder.bind(request).join();
          final data = jsonDecode(content) as Map<String, dynamic>;
          final cmd = RemoteDisplayCommand(
            sender: data['sender'] as String? ?? 'Caregiver',
            message: data['message'] as String? ?? '',
            timestamp: DateTime.now(),
          );
          if (!_displayCommandController.isClosed) {
            _displayCommandController.add(cmd);
          }
          request.response
            ..statusCode = HttpStatus.ok
            ..write(jsonEncode({'status': 'displayed'}))
            ..close();
        } catch (e) {
          request.response
            ..statusCode = HttpStatus.badRequest
            ..close();
        }
      } else if (request.method == 'POST' && path == '/api/v1/speak') {
        try {
          final content = await utf8.decoder.bind(request).join();
          final data = jsonDecode(content) as Map<String, dynamic>;
          final phrase = data['phrase'] as String? ?? '';
          if (phrase.isNotEmpty && !_speakRequestController.isClosed) {
            _speakRequestController.add(phrase);
          }
          request.response
            ..statusCode = HttpStatus.ok
            ..write(jsonEncode({'status': 'spoken'}))
            ..close();
        } catch (e) {
          request.response
            ..statusCode = HttpStatus.badRequest
            ..close();
        }
      } else if (request.method == 'POST' && path == '/api/v1/acknowledge') {
        if (!_emergencyAckController.isClosed) {
          _emergencyAckController.add(null);
        }
        request.response
          ..statusCode = HttpStatus.ok
          ..write(jsonEncode({'status': 'acknowledged'}))
          ..close();
      } else {
        request.response
          ..statusCode = HttpStatus.notFound
          ..close();
      }
    });

    debugPrint('[LocalPeerSync] Patient HTTP server running on port ${_httpServer?.port}');
  }

  Future<void> _startUdpBroadcaster() async {
    try {
      _udpSocket = await RawDatagramSocket.bind(InternetAddress.anyIPv4, 0);
      _udpSocket?.broadcastEnabled = true;

      _beaconTimer = Timer.periodic(const Duration(milliseconds: 2500), (_) {
        if (_isDisposed || _beaconProvider == null) return;
        try {
          final beacon = _beaconProvider!();
          final updated = AshaPatientBeacon(
            patientId: beacon.patientId,
            name: beacon.name,
            roomNumber: beacon.roomNumber,
            status: beacon.status,
            batteryPercent: beacon.batteryPercent,
            accessMethod: beacon.accessMethod,
            ipAddress: _cachedLocalIp ?? beacon.ipAddress,
            httpPort: _httpServer?.port ?? httpPort,
            timestamp: DateTime.now(),
            respirationBpm: beacon.respirationBpm,
            lastSpokenPhrase: beacon.lastSpokenPhrase,
            isEmergency: beacon.isEmergency,
          );
          final bytes = utf8.encode(jsonEncode(updated.toJson()));
          _udpSocket?.send(bytes, InternetAddress('255.255.255.255'), udpPort);
        } catch (e) {
          debugPrint('[LocalPeerSync] Error sending UDP beacon: $e');
        }
      });
      debugPrint('[LocalPeerSync] Patient UDP beacon broadcaster started.');
    } catch (e) {
      debugPrint('[LocalPeerSync] Could not start UDP broadcaster: $e');
    }
  }

  void dispose() {
    _isDisposed = true;
    _beaconTimer?.cancel();
    _udpSocket?.close();
    _httpServer?.close(force: true);
    _beaconController.close();
    _displayCommandController.close();
    _speakRequestController.close();
    _emergencyAckController.close();
  }
}

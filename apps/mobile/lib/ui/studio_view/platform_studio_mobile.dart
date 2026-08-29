import 'dart:convert';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'platform_studio_stub.dart';
import 'research_telemetry.dart';

Widget buildPlatformStudio({
  required BuildContext context,
  required GestureCallback onGestureFired,
  required VoidCallback onHandDetected,
  required StatusCallback onTrainingCompleted,
  bool patientExecutionMode = false,
}) {
  return _MobileStudioView(
    onGestureFired: onGestureFired,
    onHandDetected: onHandDetected,
    onTrainingCompleted: onTrainingCompleted,
    patientExecutionMode: patientExecutionMode,
  );
}

class _MobileStudioView extends StatefulWidget {
  const _MobileStudioView({
    required this.onGestureFired,
    required this.onHandDetected,
    required this.onTrainingCompleted,
    required this.patientExecutionMode,
  });

  final GestureCallback onGestureFired;
  final VoidCallback onHandDetected;
  final StatusCallback onTrainingCompleted;
  final bool patientExecutionMode;

  @override
  State<_MobileStudioView> createState() => _MobileStudioViewState();
}

class _MobileStudioViewState extends State<_MobileStudioView> {
  static const _researchLogChannel =
      MethodChannel('org.fingerspeak.mobile/research');

  HttpServer? _server;
  String? _serverUrl;
  bool _loading = true;
  late final Future<SharedPreferences> _preferences =
      SharedPreferences.getInstance();

  @override
  void initState() {
    super.initState();
    _startServer();
  }

  Future<PermissionStatus> _ensurePermission(Permission permission) async {
    final current = await permission.status;
    if (current.isGranted ||
        current.isPermanentlyDenied ||
        current.isRestricted) {
      return current;
    }
    return permission.request();
  }

  Future<Map<String, Object?>> _requestCameraPermission() async {
    try {
      final status = await _ensurePermission(Permission.camera);
      debugPrint('[OS Camera Permission]: $status');
      return <String, Object?>{
        'granted': status.isGranted,
        'permanentlyDenied': status.isPermanentlyDenied,
        'restricted': status.isRestricted,
        'status': status.toString().split('.').last,
      };
    } catch (error) {
      debugPrint('[OS Camera Permission Error]: $error');
      return <String, Object?>{
        'granted': false,
        'error': error.toString(),
      };
    }
  }

  Future<PermissionResponse> _handleMediaPermissionRequest(
    PermissionRequest request,
  ) async {
    debugPrint(
      '[WebView Permission] origin=${request.origin} resources=${request.resources} action=GRANT',
    );
    return PermissionResponse(
      resources: request.resources,
      action: PermissionResponseAction.GRANT,
    );
  }

  Future<void> _startServer() async {
    try {
      final server = await HttpServer.bind(InternetAddress.anyIPv4, 0);
      _server = server;
      final url = 'http://localhost:${server.port}/';

      server.listen((HttpRequest request) async {
        try {
          final path = request.uri.path;
          String assetPath;
          ContentType contentType;

          if (path == '/' ||
              path == '/index.html' ||
              path == '/fingerspeak_studio.html') {
            assetPath = 'assets/web/fingerspeak_studio.html';
            contentType = ContentType.html;
          } else if (path.startsWith('/wasm/')) {
            final fileName = path.substring('/wasm/'.length);
            assetPath = 'assets/web/wasm/$fileName';
            contentType = fileName.endsWith('.wasm')
                ? ContentType('application', 'wasm')
                : ContentType('application', 'javascript', charset: 'utf-8');
          } else if (path.startsWith('/models/')) {
            final fileName = path.substring('/models/'.length);
            assetPath = 'assets/web/models/$fileName';
            contentType = ContentType('application', 'octet-stream');
          } else if (path == '/fingerspeak_hand_runtime.js') {
            assetPath = 'assets/web/fingerspeak_hand_runtime.js';
            contentType =
                ContentType('application', 'javascript', charset: 'utf-8');
          } else {
            assetPath = 'assets/web/fingerspeak_studio.html';
            contentType = ContentType.html;
          }

          final data = await rootBundle.load(assetPath);
          final bytes = data.buffer.asUint8List();
          request.response.headers.contentType = contentType;
          request.response.headers.set('Access-Control-Allow-Origin', '*');
          request.response.headers
              .set('Access-Control-Allow-Methods', 'GET, OPTIONS');
          request.response.headers.set('Access-Control-Allow-Headers', '*');
          request.response.headers.set('Cache-Control', 'no-cache');
          request.response.add(bytes);
          await request.response.close();
        } catch (e) {
          debugPrint('[HttpServer asset load error]: $e');
          request.response.statusCode = HttpStatus.notFound;
          await request.response.close();
        }
      });

      debugPrint('[MediaPipe Studio]: Loopback server ready at $url');
      if (mounted) {
        setState(() => _serverUrl = url);
      }
    } catch (e) {
      debugPrint('[MediaPipe Studio]: Server bind error: $e');
      if (mounted) {
        setState(() => _serverUrl = '');
      }
    }
  }

  @override
  void dispose() {
    _server?.close(force: true);
    super.dispose();
  }

  void _handleMessage(dynamic raw) {
    try {
      final Map<String, dynamic> data;
      if (raw is Map) {
        data = Map<String, dynamic>.from(raw);
      } else if (raw is String) {
        data = jsonDecode(raw) as Map<String, dynamic>;
      } else {
        return;
      }
      final type = data['type'] as String?;
      debugPrint('[PlatformStudio Mobile]: message received: type=$type');
      if (type == 'research_event') {
        final line = formatResearchTelemetryLog(data['payload']);
        if (line != null) {
          _researchLogChannel.invokeMethod<void>('log', line).catchError((_) {
            debugPrint(line);
          });
        }
      } else if (type == 'gesture_fired') {
        final g = data['gesture'] as String? ?? '';
        final p = data['phrase'] as String? ?? '';
        final c = (data['confidence'] as num?)?.toDouble() ?? 0.85;
        debugPrint('[PlatformStudio Mobile]: onGestureFired gesture=$g phrase="$p" conf=$c');
        widget.onGestureFired(g, p, c);
      } else if (type == 'hand_detected') {
        widget.onHandDetected();
      } else if (type == 'training_completed') {
        final s = data['accSummary'] as String? ?? 'Training complete';
        widget.onTrainingCompleted(s);
      }
    } catch (e) {
      debugPrint('[PlatformStudio Mobile]: Message parse error: $e');
    }
  }

  Future<Map<String, Object?>> _handleStorageRequest(List<dynamic> args) async {
    try {
      if (args.isEmpty || args.first is! Map) {
        return const {'ok': false, 'error': 'Invalid storage request'};
      }
      final request = Map<String, dynamic>.from(args.first as Map);
      final action = request['action']?.toString() ?? '';
      final key = request['key']?.toString() ?? '';
      if (key.isEmpty || key.length > 128) {
        return const {'ok': false, 'error': 'Invalid storage key'};
      }

      final preferences = await _preferences;
      final scopedKey = 'hand_studio.$key';
      if (action == 'get') {
        return {'ok': true, 'value': preferences.getString(scopedKey)};
      }
      if (action == 'set') {
        final value = request['value']?.toString() ?? '';
        final saved = await preferences.setString(scopedKey, value);
        return {'ok': saved};
      }
      return const {'ok': false, 'error': 'Unsupported storage action'};
    } catch (error) {
      debugPrint('[MediaPipe Studio Storage]: $error');
      return const {'ok': false, 'error': 'Storage unavailable'};
    }
  }

  @override
  Widget build(BuildContext context) {
    final serverUrl = _serverUrl;
    if (serverUrl == null) {
      return const Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            CircularProgressIndicator(color: Color(0xFF4FD1C5)),
            SizedBox(height: 12),
            Text(
              'Starting MediaPipe Studio…',
              style: TextStyle(color: Color(0xFF8CA0A8), fontSize: 13),
            ),
          ],
        ),
      );
    }

    final baseUrl = serverUrl.isNotEmpty ? serverUrl : 'http://localhost/';
    final Map<String, String> queryParams = {};
    if (researchTelemetryEnabled) queryParams['research'] = '1';
    if (widget.patientExecutionMode) queryParams['mode'] = 'patient';
    final studioUrl = queryParams.isNotEmpty
        ? Uri.parse(baseUrl).replace(queryParameters: queryParams)
        : Uri.parse(baseUrl);

    return Stack(
      children: [
        InAppWebView(
          initialUrlRequest: URLRequest(
            url: WebUri(studioUrl.toString()),
          ),
          initialSettings: InAppWebViewSettings(
            mediaPlaybackRequiresUserGesture: false,
            allowsInlineMediaPlayback: true,
            allowsAirPlayForMediaPlayback: true,
            allowsPictureInPictureMediaPlayback: true,
            isInspectable: true,
            javaScriptEnabled: true,
            javaScriptCanOpenWindowsAutomatically: true,
            useHybridComposition: true,
            useShouldOverrideUrlLoading: false,
            transparentBackground: false,
            mixedContentMode: MixedContentMode.MIXED_CONTENT_ALWAYS_ALLOW,
            allowFileAccessFromFileURLs: true,
            allowUniversalAccessFromFileURLs: true,
            allowContentAccess: true,
            allowFileAccess: true,
            hardwareAcceleration: true,
          ),
          onWebViewCreated: (controller) {
            controller.addJavaScriptHandler(
              handlerName: 'FingerSpeakBridge',
              callback: (args) {
                if (args.isNotEmpty) _handleMessage(args.first);
              },
            );
            controller.addJavaScriptHandler(
              handlerName: 'speakPhrase',
              callback: (args) {
                if (args.isNotEmpty) {
                  final text = args.first.toString();
                  if (text.isNotEmpty) {
                    widget.onGestureFired('Micro-Gesture', text, 0.95);
                  }
                }
              },
            );
            controller.addJavaScriptHandler(
              handlerName: 'FingerSpeakStorage',
              callback: _handleStorageRequest,
            );
            controller.addJavaScriptHandler(
              handlerName: 'requestCameraPermission',
              callback: (_) => _requestCameraPermission(),
            );
            controller.addJavaScriptHandler(
              handlerName: 'openAppSettings',
              callback: (_) async => <String, Object?>{
                'opened': await openAppSettings(),
              },
            );
          },
          onLoadStop: (controller, url) {
            if (mounted) setState(() => _loading = false);

            controller.evaluateJavascript(source: """
              window.FingerSpeakBridge = {
                postMessage: function(msg) {
                  window.flutter_inappwebview.callHandler('FingerSpeakBridge', msg);
                }
              };
              if (${widget.patientExecutionMode}) {
                window.__fingerSpeakPatientMode = true;
                window.FingerSpeakStudio?.startPatientMode();
              }
            """);
          },
          onConsoleMessage: (controller, message) {
            debugPrint('[Studio JS]: ${message.message}');
          },
          onPermissionRequest: (controller, request) async {
            return _handleMediaPermissionRequest(request);
          },
        ),
        if (_loading)
          Container(
            color: const Color(0xFF0F1720),
            child: const Center(
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  CircularProgressIndicator(color: Color(0xFF4FD1C5)),
                  SizedBox(height: 16),
                  Text(
                    'Loading 3D MediaPipe Studio…',
                    style: TextStyle(color: Color(0xFF8CA0A8), fontSize: 13),
                  ),
                ],
              ),
            ),
          ),
      ],
    );
  }
}

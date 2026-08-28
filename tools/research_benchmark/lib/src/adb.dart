import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'parsers.dart';
import 'utils.dart';

/// An error produced while locating or invoking Android Debug Bridge.
class AdbException implements Exception {
  AdbException(this.message, {this.result});

  final String message;
  final AdbCommandResult? result;

  @override
  String toString() => 'AdbException: $message';
}

/// The completed result of an ADB command.
class AdbCommandResult {
  const AdbCommandResult({
    required this.executable,
    required this.arguments,
    required this.exitCode,
    required this.stdout,
    required this.stderr,
    required this.elapsed,
    this.timedOut = false,
  });

  final String executable;
  final List<String> arguments;
  final int exitCode;
  final String stdout;
  final String stderr;
  final Duration elapsed;
  final bool timedOut;

  bool get succeeded => exitCode == 0 && !timedOut;

  String get commandLine => <String>[executable, ...arguments].join(' ');

  Map<String, dynamic> toJson() => <String, dynamic>{
    'command': commandLine,
    'exit_code': exitCode,
    'timed_out': timedOut,
    'elapsed_ms': elapsed.inMicroseconds / 1000,
    'stdout': stdout,
    'stderr': stderr,
  };
}

/// Locates ADB, selects a device, and provides serial-scoped command helpers.
///
/// Construction is deliberately synchronous so a CLI can simply use
/// `AdbClient(adbPath: args.value('adb'), serial: args.value('serial'))`.
/// Discovery and validation happen on the first command or [resolveAdbPath].
class AdbClient {
  AdbClient({
    String? adbPath,
    this.serial,
    this.defaultTimeout = const Duration(seconds: 30),
    Map<String, String>? environment,
  }) : _requestedAdbPath = _blankToNull(adbPath),
       _environment = environment ?? Platform.environment;

  final String? _requestedAdbPath;
  final Map<String, String> _environment;
  final Duration defaultTimeout;

  /// A requested serial. When null, [selectDevice] requires exactly one
  /// authorized physical Android device.
  final String? serial;

  String? _resolvedAdbPath;
  AdbDevice? _selectedDevice;

  String? get resolvedAdbPath => _resolvedAdbPath;
  AdbDevice? get selectedDevice => _selectedDevice;
  String? get selectedSerial => _selectedDevice?.serial ?? serial;

  /// Finds and validates ADB. An explicit path is tried exclusively.
  Future<String> resolveAdbPath() async {
    final cached = _resolvedAdbPath;
    if (cached != null) return cached;

    final candidates = _adbCandidates(_requestedAdbPath, _environment);
    final failures = <String>[];
    for (final candidate in candidates) {
      try {
        final result = await _runExecutable(
          candidate,
          const <String>['version'],
          environment: _environment,
          timeout: const Duration(seconds: 10),
        );
        if (result.succeeded &&
            (result.stdout.contains('Android Debug Bridge') ||
                result.stderr.contains('Android Debug Bridge'))) {
          _resolvedAdbPath = candidate;
          return candidate;
        }
        failures.add(
          '$candidate (exit ${result.exitCode}${result.timedOut ? ', timed out' : ''})',
        );
      } on ProcessException catch (error) {
        failures.add('$candidate (${error.message})');
      } on AdbException catch (error) {
        failures.add('$candidate (${error.message})');
      }
    }

    if (_requestedAdbPath != null) {
      throw AdbException(
        'The ADB executable at "$_requestedAdbPath" could not be run. '
        '${failures.join('; ')}',
      );
    }
    throw AdbException(
      'Could not find Android Debug Bridge. Install Android SDK Platform-Tools, '
      'put adb on PATH, set ANDROID_SDK_ROOT/ANDROID_HOME, or pass --adb. '
      'Tried: ${failures.join('; ')}',
    );
  }

  /// Starts an ADB subprocess. By default the configured/selected serial is
  /// inserted before [arguments].
  Future<Process> start(
    List<String> arguments, {
    String? serial,
    bool useSelectedDevice = true,
    String? workingDirectory,
    ProcessStartMode mode = ProcessStartMode.normal,
  }) async {
    final executable = await resolveAdbPath();
    final commandArguments = _scopedArguments(
      arguments,
      serial: serial,
      useSelectedDevice: useSelectedDevice,
    );
    try {
      return await Process.start(
        executable,
        commandArguments,
        workingDirectory: workingDirectory,
        environment: _environment,
        mode: mode,
      );
    } on ProcessException catch (error) {
      throw AdbException(
        'Could not start ${<String>[executable, ...commandArguments].join(' ')}: '
        '${error.message}',
      );
    }
  }

  /// Runs ADB and captures both output streams.
  Future<AdbCommandResult> run(
    List<String> arguments, {
    String? serial,
    bool useSelectedDevice = true,
    String? workingDirectory,
    Duration? timeout,
    bool throwOnError = true,
  }) async {
    final executable = await resolveAdbPath();
    final commandArguments = _scopedArguments(
      arguments,
      serial: serial,
      useSelectedDevice: useSelectedDevice,
    );
    final result = await _runExecutable(
      executable,
      commandArguments,
      workingDirectory: workingDirectory,
      environment: _environment,
      timeout: timeout ?? defaultTimeout,
    );
    if (throwOnError && !result.succeeded) {
      final detail = result.stderr.trim().isNotEmpty
          ? result.stderr.trim()
          : result.stdout.trim();
      throw AdbException(
        result.timedOut
            ? 'ADB command timed out: ${result.commandLine}'
            : 'ADB command failed with exit ${result.exitCode}: '
                  '${result.commandLine}${detail.isEmpty ? '' : '\n$detail'}',
        result: result,
      );
    }
    return result;
  }

  /// Runs a device shell command without involving a host shell.
  Future<AdbCommandResult> shell(
    List<String> arguments, {
    String? serial,
    Duration? timeout,
    bool throwOnError = true,
  }) => run(
    <String>['shell', ...arguments],
    serial: serial,
    timeout: timeout,
    throwOnError: throwOnError,
  );

  /// Starts a long-running device shell command, such as logcat.
  Future<Process> startShell(
    List<String> arguments, {
    String? serial,
    ProcessStartMode mode = ProcessStartMode.normal,
  }) => start(<String>['shell', ...arguments], serial: serial, mode: mode);

  Future<List<AdbDevice>> listDevices() async {
    final result = await run(const <String>[
      'devices',
      '-l',
    ], useSelectedDevice: false);
    return parseAdbDevices(result.stdout);
  }

  /// Selects the requested device, or the sole authorized physical device.
  ///
  /// Emulators are never selected implicitly. They remain usable when their
  /// serial is explicitly supplied, which is useful for collector tests.
  Future<AdbDevice> selectDevice({String? serial}) async {
    final requested = _blankToNull(serial) ?? this.serial;
    final devices = await listDevices();

    if (requested != null) {
      final matches = devices.where((device) => device.serial == requested);
      if (matches.isEmpty) {
        throw AdbException(
          'ADB device "$requested" was not found. Connected devices: '
          '${_deviceSummary(devices)}',
        );
      }
      final device = matches.first;
      if (device.state != 'device') {
        throw AdbException(
          'ADB device "$requested" is ${device.state}, not authorized and '
          'ready. Unlock it and accept the USB debugging prompt.',
        );
      }
      _selectedDevice = device;
      return device;
    }

    final authorized = devices
        .where((device) => device.state == 'device')
        .toList();
    final physical = <AdbDevice>[];
    for (final device in authorized) {
      if (await _isPhysical(device)) physical.add(device);
    }

    if (physical.length != 1) {
      final unauthorized = devices
          .where((device) => device.state != 'device')
          .toList();
      if (physical.isEmpty && unauthorized.isNotEmpty) {
        throw AdbException(
          'No authorized physical Android device is available. Unlock the '
          'device and accept the USB debugging prompt. Connected devices: '
          '${_deviceSummary(devices)}',
        );
      }
      if (physical.isEmpty && authorized.isNotEmpty) {
        throw AdbException(
          'Only emulators were found. Connect one physical device or explicitly '
          'select a serial with --serial. Connected devices: '
          '${_deviceSummary(devices)}',
        );
      }
      throw AdbException(
        physical.isEmpty
            ? 'No authorized physical Android device was found.'
            : 'More than one authorized physical Android device was found '
                  '(${physical.map((device) => device.serial).join(', ')}). '
                  'Pass --serial to choose exactly one.',
      );
    }
    _selectedDevice = physical.single;
    return physical.single;
  }

  AdbDeviceSession session(AdbDevice device) => AdbDeviceSession(this, device);

  Future<AdbDeviceSession> selectSession({String? serial}) async =>
      session(await selectDevice(serial: serial));

  /// Returns host, ADB, connection, and selected-device diagnostics suitable
  /// for a `doctor` command or run metadata.
  Future<Map<String, dynamic>> collectDoctorData({String? packageName}) async {
    final adbPath = await resolveAdbPath();
    final version = await run(
      const <String>['version'],
      useSelectedDevice: false,
      throwOnError: false,
    );
    final devices = await listDevices();
    Map<String, dynamic>? selection;
    try {
      final device = await selectDevice();
      final deviceSession = session(device);
      final properties = await deviceSession.shell(const <String>[
        'getprop',
      ], throwOnError: false);
      final size = await deviceSession.shell(const <String>[
        'wm',
        'size',
      ], throwOnError: false);
      final density = await deviceSession.shell(const <String>[
        'wm',
        'density',
      ], throwOnError: false);
      final package = packageName == null
          ? null
          : await deviceSession.shell(<String>[
              'dumpsys',
              'package',
              packageName,
            ], throwOnError: false);
      final getprop = _parseGetprop(properties.stdout);
      selection = <String, dynamic>{
        'serial': device.serial,
        'state': device.state,
        'attributes': device.attributes,
        'manufacturer': getprop['ro.product.manufacturer'],
        'brand': getprop['ro.product.brand'],
        'model': getprop['ro.product.model'],
        'device': getprop['ro.product.device'],
        'android_release': getprop['ro.build.version.release'],
        'sdk': int.tryParse(getprop['ro.build.version.sdk'] ?? ''),
        'security_patch': getprop['ro.build.version.security_patch'],
        'build_fingerprint': getprop['ro.build.fingerprint'],
        'kernel_qemu': getprop['ro.kernel.qemu'],
        'screen_size': size.stdout.trim(),
        'screen_density': density.stdout.trim(),
        if (packageName != null) ...<String, dynamic>{
          'package_name': packageName,
          'package_installed':
              package?.succeeded == true &&
              package!.stdout.contains('Package [$packageName]'),
          'package': package == null ? null : parsePackageInfo(package.stdout),
        },
      };
    } on AdbException catch (error) {
      selection = <String, dynamic>{'error': error.message};
    }

    return <String, dynamic>{
      'captured_utc': utcNow(),
      'host': <String, dynamic>{
        'operating_system': Platform.operatingSystem,
        'operating_system_version': Platform.operatingSystemVersion,
        'dart_version': Platform.version,
      },
      'adb': <String, dynamic>{
        'path': adbPath,
        'version': version.stdout.trim(),
      },
      'requested_serial': serial,
      'devices': devices
          .map(
            (device) => <String, dynamic>{
              'serial': device.serial,
              'state': device.state,
              'attributes': device.attributes,
            },
          )
          .toList(),
      'selected_device': selection,
    };
  }

  List<String> _scopedArguments(
    List<String> arguments, {
    required String? serial,
    required bool useSelectedDevice,
  }) {
    final effectiveSerial =
        serial ?? (useSelectedDevice ? selectedSerial : null);
    return <String>[
      if (effectiveSerial != null) ...<String>['-s', effectiveSerial],
      ...arguments,
    ];
  }

  Future<bool> _isPhysical(AdbDevice device) async {
    if (device.serial.startsWith('emulator-')) return false;
    try {
      final result = await run(
        const <String>['shell', 'getprop', 'ro.kernel.qemu'],
        serial: device.serial,
        useSelectedDevice: false,
        timeout: const Duration(seconds: 5),
        throwOnError: false,
      );
      return result.stdout.trim() != '1';
    } on AdbException {
      // A non-emulator serial is treated as physical if the optional probe is
      // unavailable; subsequent session commands will still validate it.
      return true;
    }
  }
}

/// A serial-bound view of [AdbClient].
class AdbDeviceSession {
  const AdbDeviceSession(this.client, this.device);

  final AdbClient client;
  final AdbDevice device;

  String get serial => device.serial;

  Future<AdbCommandResult> run(
    List<String> arguments, {
    Duration? timeout,
    bool throwOnError = true,
  }) => client.run(
    arguments,
    serial: serial,
    timeout: timeout,
    throwOnError: throwOnError,
  );

  Future<AdbCommandResult> shell(
    List<String> arguments, {
    Duration? timeout,
    bool throwOnError = true,
  }) => client.shell(
    arguments,
    serial: serial,
    timeout: timeout,
    throwOnError: throwOnError,
  );

  Future<Process> start(
    List<String> arguments, {
    ProcessStartMode mode = ProcessStartMode.normal,
  }) => client.start(arguments, serial: serial, mode: mode);

  Future<Process> startShell(
    List<String> arguments, {
    ProcessStartMode mode = ProcessStartMode.normal,
  }) => client.startShell(arguments, serial: serial, mode: mode);
}

Future<AdbCommandResult> _runExecutable(
  String executable,
  List<String> arguments, {
  String? workingDirectory,
  Map<String, String>? environment,
  required Duration timeout,
}) async {
  final stopwatch = Stopwatch()..start();
  final process = await Process.start(
    executable,
    arguments,
    workingDirectory: workingDirectory,
    environment: environment,
  );
  final stdoutFuture = process.stdout.fold<List<int>>(
    <int>[],
    (buffer, bytes) => buffer..addAll(bytes),
  );
  final stderrFuture = process.stderr.fold<List<int>>(
    <int>[],
    (buffer, bytes) => buffer..addAll(bytes),
  );
  var timedOut = false;
  final timer = Timer(timeout, () {
    timedOut = true;
    process.kill();
  });
  final exitCode = await process.exitCode;
  timer.cancel();
  final outputBytes = await stdoutFuture;
  final errorBytes = await stderrFuture;
  stopwatch.stop();
  return AdbCommandResult(
    executable: executable,
    arguments: List<String>.unmodifiable(arguments),
    exitCode: exitCode,
    stdout: utf8.decode(outputBytes, allowMalformed: true),
    stderr: utf8.decode(errorBytes, allowMalformed: true),
    elapsed: stopwatch.elapsed,
    timedOut: timedOut,
  );
}

List<String> _adbCandidates(
  String? explicitPath,
  Map<String, String> environment,
) {
  if (explicitPath != null) return <String>[explicitPath];
  final executable = Platform.isWindows ? 'adb.exe' : 'adb';
  final candidates = <String>[];

  void addSdk(String? root) {
    final normalized = _blankToNull(root);
    if (normalized == null) return;
    candidates.add(
      '$normalized${Platform.pathSeparator}platform-tools'
      '${Platform.pathSeparator}$executable',
    );
  }

  addSdk(environment['ANDROID_SDK_ROOT']);
  addSdk(environment['ANDROID_HOME']);
  if (Platform.isWindows) {
    final localAppData = _blankToNull(environment['LOCALAPPDATA']);
    if (localAppData != null) {
      addSdk(
        '$localAppData${Platform.pathSeparator}Android${Platform.pathSeparator}Sdk',
      );
    }
  } else {
    final userHome = _blankToNull(environment['HOME']);
    if (userHome != null) {
      addSdk(
        '$userHome${Platform.pathSeparator}Android${Platform.pathSeparator}Sdk',
      );
      addSdk(
        '$userHome${Platform.pathSeparator}Library${Platform.pathSeparator}Android'
        '${Platform.pathSeparator}sdk',
      );
    }
  }
  candidates.add('adb');

  final seen = <String>{};
  return candidates.where((candidate) {
    final key = Platform.isWindows ? candidate.toLowerCase() : candidate;
    return seen.add(key);
  }).toList();
}

Map<String, String> _parseGetprop(String output) {
  final properties = <String, String>{};
  final pattern = RegExp(r'^\[([^]]+)\]: \[(.*)\]$', multiLine: true);
  for (final match in pattern.allMatches(output)) {
    properties[match.group(1)!] = match.group(2)!;
  }
  return properties;
}

String _deviceSummary(List<AdbDevice> devices) => devices.isEmpty
    ? 'none'
    : devices.map((device) => '${device.serial} (${device.state})').join(', ');

String? _blankToNull(String? value) {
  final normalized = value?.trim();
  return normalized == null || normalized.isEmpty ? null : normalized;
}

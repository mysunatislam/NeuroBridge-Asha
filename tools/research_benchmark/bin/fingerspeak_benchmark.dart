import 'dart:convert';
import 'dart:io';

import '../lib/src/adb.dart';
import '../lib/src/analysis.dart';
import '../lib/src/arguments.dart';
import '../lib/src/collector.dart';
import '../lib/src/report.dart';
import '../lib/src/utils.dart';

Future<void> main(List<String> rawArguments) async {
  try {
    final arguments = CliArguments.parse(rawArguments);
    switch (arguments.command) {
      case 'help':
        _printUsage();
        return;
      case 'doctor':
        await _doctor(arguments);
        return;
      case 'collect':
        await _collect(arguments);
        return;
      case 'analyze':
        _analyze(arguments);
        return;
      case 'compare':
        _compare(arguments);
        return;
      case 'trace':
        await _trace(arguments);
        return;
      default:
        throw FormatException(
          'Unknown command "${arguments.command}". Run help for usage.',
        );
    }
  } on FormatException catch (error) {
    stderr.writeln('Input error: ${error.message}');
    exitCode = 2;
  } on AdbException catch (error) {
    stderr.writeln('ADB error: ${error.message}');
    exitCode = 3;
  } on FileSystemException catch (error) {
    stderr.writeln(
      'File error: ${error.message}'
      '${error.path == null ? '' : ' (${error.path})'}',
    );
    exitCode = 4;
  } on Object catch (error, stackTrace) {
    stderr.writeln('Benchmark failed: $error');
    if (rawArguments.contains('--verbose')) stderr.writeln(stackTrace);
    exitCode = 1;
  }
}

Future<void> _doctor(CliArguments arguments) async {
  final client = AdbClient(
    adbPath: arguments.value('adb') ?? arguments.value('adb-path'),
    serial: arguments.value('serial'),
  );
  final packageName = arguments.string('package', 'org.fingerspeak.mobile');
  final result = await client.collectDoctorData(packageName: packageName);
  stdout.writeln(const JsonEncoder.withIndent('  ').convert(result));

  final selected = _map(result['selected_device']);
  if (selected.containsKey('error')) {
    stderr.writeln('\nDoctor failed: ${selected['error']}');
    exitCode = 3;
    return;
  }
  if (selected['package_installed'] != true) {
    stderr.writeln('\nDoctor failed: $packageName is not installed.');
    exitCode = 3;
    return;
  }
  final package = _map(selected['package']);
  if (package['profileable_by_shell'] != true) {
    stderr.writeln(
      '\nWarning: the installed package was not reported as profileable by '
      'shell. Install the FingerSpeak research profile APK before collecting.',
    );
  }
}

Future<void> _collect(CliArguments arguments) async {
  final result = await runInteractiveCollector(arguments);
  final summary = analyzeRun(result.outputDirectory);
  writeRunReport(result.outputDirectory, summary);
  stdout.writeln('');
  stdout.writeln('Collection complete: ${result.outputDirectory.path}');
  stdout.writeln('Report: ${_join(result.outputDirectory.path, 'report.md')}');
  stdout.writeln(
    'Machine-readable summary: '
    '${_join(result.outputDirectory.path, 'summary.json')}',
  );
}

void _analyze(CliArguments arguments) {
  final path =
      arguments.value('run') ??
      (arguments.positionals.isEmpty ? null : arguments.positionals.first);
  if (path == null || path.trim().isEmpty) {
    throw const FormatException(
      'analyze requires a run directory: analyze <directory>.',
    );
  }
  final directory = Directory(path).absolute;
  final summary = analyzeRun(directory);
  writeRunReport(directory, summary);
  stdout.writeln('Report: ${_join(directory.path, 'report.md')}');
  stdout.writeln('Summary: ${_join(directory.path, 'summary.json')}');
}

void _compare(CliArguments arguments) {
  final baselinePath = arguments.value('baseline');
  final calibratedPath = arguments.value('calibrated');
  if (baselinePath == null || calibratedPath == null) {
    throw const FormatException(
      'compare requires --baseline <run> and --calibrated <run>.',
    );
  }
  final output = createFreshDirectory(
    arguments.string('output', defaultRunDirectory('comparison')),
  );
  final comparison = compareRuns(
    Directory(baselinePath),
    Directory(calibratedPath),
    paired: arguments.boolean('paired', false),
  );
  writeComparisonReport(output, comparison);
  stdout.writeln('Comparison: ${_join(output.path, 'comparison.md')}');
  stdout.writeln('Data: ${_join(output.path, 'comparison.json')}');
}

Future<void> _trace(CliArguments arguments) async {
  final client = AdbClient(
    adbPath: arguments.value('adb') ?? arguments.value('adb-path'),
    serial: arguments.value('serial'),
  );
  final device = await client.selectSession(serial: arguments.value('serial'));
  final durationSeconds = arguments.integer('duration', 15, minimum: 1);
  final stamp = DateTime.now().toUtc().toIso8601String().replaceAll(
    RegExp(r'[:.]'),
    '-',
  );
  final outputPath = File(
    arguments.string(
      'output',
      'research_results${Platform.pathSeparator}fingerspeak_$stamp.perfetto-trace',
    ),
  ).absolute;
  if (outputPath.existsSync()) {
    throw FileSystemException(
      'Refusing to overwrite an existing trace',
      outputPath.path,
    );
  }
  outputPath.parent.createSync(recursive: true);
  final remotePath =
      '/data/misc/perfetto-traces/fingerspeak_$stamp.perfetto-trace';
  stdout.writeln(
    'Recording $durationSeconds seconds of Perfetto data. Exercise the hand '
    'communicator now...',
  );
  await device.shell(<String>[
    'perfetto',
    '-o',
    remotePath,
    '-t',
    '${durationSeconds}s',
    'sched',
    'freq',
    'idle',
    'am',
    'wm',
    'gfx',
    'view',
    'binder_driver',
    'camera',
    'power',
    'thermal',
  ], timeout: Duration(seconds: durationSeconds + 30));
  await device.run(<String>['pull', remotePath, outputPath.path]);
  writePrettyJson(File('${outputPath.path}.json'), <String, dynamic>{
    'schema_version': 1,
    'captured_utc': utcNow(),
    'duration_seconds': durationSeconds,
    'local_trace': outputPath.path,
    'remote_trace': remotePath,
    'note': 'Open the trace in https://ui.perfetto.dev/.',
  });
  stdout.writeln('Trace: ${outputPath.path}');
}

void _printUsage() {
  stdout.writeln(
    '''
FingerSpeak laptop research benchmark

Usage (PowerShell wrapper recommended):
  run_benchmark.ps1 build-install
  run_benchmark.ps1 doctor
  run_benchmark.ps1 collect --phase baseline --participant P001 --session S01 \\
    --gestures Yes,No,Water,Nurse --repetitions 10 --rest-trials 10 --seed 4217
  run_benchmark.ps1 analyze <run-directory>
  run_benchmark.ps1 compare --baseline <directory> --calibrated <directory>
  run_benchmark.ps1 trace --duration 15 --output <file.perfetto-trace>

Collection options:
  --phase <name>              baseline or calibrated label
  --participant <id>          pseudonymous participant ID; never use a name
  --session <id>              study session/visit ID
  --gestures <a,b,c>          expected non-Rest gesture labels
  --repetitions <n>           trials per gesture (default 3)
  --rest-trials <n>           negative/no-gesture trials
  --seed <n>                  reproducible randomization seed
  --window-ms <n>             activation window (default 5000)
  --sample-interval-ms <n>    ADB resource sample period
  --output <directory>        fresh output directory
  --launch                    launch the installed app before collection
  --serial <adb-serial>       required when selecting among multiple devices
  --no-clear-logcat           preserve the existing device log buffer
  --no-system-sampling        telemetry-only pass, if supported by collector

Latency definitions are deliberately separate in every report: host-observed
trial onset to log receipt, on-device candidate-to-confirmation activation,
classifier execution, and MediaPipe processing. Android UI frames are also
reported separately from MediaPipe tracking FPS.
'''
        .trim(),
  );
}

Map<String, dynamic> _map(Object? value) {
  if (value is Map<String, dynamic>) return value;
  if (value is Map) {
    return value.map((key, item) => MapEntry(key.toString(), item));
  }
  return <String, dynamic>{};
}

String _join(String directory, String name) =>
    '$directory${Platform.pathSeparator}$name';

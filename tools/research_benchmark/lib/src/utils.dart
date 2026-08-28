import 'dart:convert';
import 'dart:io';
import 'dart:math';

String utcNow() => DateTime.now().toUtc().toIso8601String();

String csvCell(Object? value) {
  if (value == null) return '';
  final text = value is double && !value.isFinite ? '' : value.toString();
  if (text.contains(',') || text.contains('"') || text.contains('\n') || text.contains('\r')) {
    return '"${text.replaceAll('"', '""')}"';
  }
  return text;
}

String csvRow(Iterable<Object?> values) => values.map(csvCell).join(',');

void writePrettyJson(File file, Object? value) {
  file.parent.createSync(recursive: true);
  file.writeAsStringSync('${const JsonEncoder.withIndent('  ').convert(value)}\n');
}

Map<String, dynamic> readJsonObject(File file) {
  final decoded = jsonDecode(file.readAsStringSync());
  if (decoded is! Map) {
    throw FormatException('Expected a JSON object in ${file.path}');
  }
  return decoded.map((key, value) => MapEntry(key.toString(), value));
}

double? asDouble(Object? value) {
  if (value is num) return value.toDouble();
  if (value is String) return double.tryParse(value.trim());
  return null;
}

int? asInt(Object? value) {
  if (value is int) return value;
  if (value is num) return value.toInt();
  if (value is String) return int.tryParse(value.trim());
  return null;
}

String canonicalLabel(Object? value) {
  if (value == null) return '';
  return value.toString().trim().toLowerCase().replaceAll(RegExp(r'\s+'), '_');
}

String formatNumber(Object? value, {int decimals = 2, String missing = 'n/a'}) {
  final number = asDouble(value);
  if (number == null || !number.isFinite) return missing;
  return number.toStringAsFixed(decimals);
}

String formatPercent(Object? fraction, {int decimals = 1, String missing = 'n/a'}) {
  final number = asDouble(fraction);
  if (number == null || !number.isFinite) return missing;
  return '${(number * 100).toStringAsFixed(decimals)}%';
}

String markdownEscape(Object? value) =>
    (value ?? '').toString().replaceAll('|', r'\|').replaceAll('\n', ' ');

String safeFileComponent(String input) {
  final value = input.trim().replaceAll(RegExp(r'[^A-Za-z0-9._-]+'), '_');
  return value.isEmpty ? 'run' : value;
}

Directory createFreshDirectory(String path) {
  final directory = Directory(path).absolute;
  if (directory.existsSync() && directory.listSync().isNotEmpty) {
    throw FileSystemException(
      'Output directory already exists and is not empty; refusing to overwrite it',
      directory.path,
    );
  }
  directory.createSync(recursive: true);
  return directory;
}

String defaultRunDirectory(String phase) {
  final stamp = DateTime.now().toUtc().toIso8601String().replaceAll(RegExp(r'[:.]'), '-');
  return 'research_results${Platform.pathSeparator}${stamp}_${safeFileComponent(phase)}';
}

double clampDouble(double value, double lower, double upper) => max(lower, min(upper, value));


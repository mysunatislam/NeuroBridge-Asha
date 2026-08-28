class CliArguments {
  CliArguments(this.command, this.options, this.positionals);

  final String command;
  final Map<String, List<String>> options;
  final List<String> positionals;

  static const _booleanOptions = <String>{
    'help',
    'launch',
    'clear-logcat',
    'include-rest',
    'no-include-rest',
    'system-sampling',
    'no-system-sampling',
    'paired',
    'no-launch',
    'no-clear-logcat',
  };

  factory CliArguments.parse(List<String> args) {
    if (args.isEmpty)
      return CliArguments('help', <String, List<String>>{}, <String>[]);
    var command = '';
    final options = <String, List<String>>{};
    final positionals = <String>[];
    var i = 0;
    while (i < args.length) {
      final token = args[i];
      if (!token.startsWith('--')) {
        if (command.isEmpty) {
          command = token;
        } else {
          positionals.add(token);
        }
        i++;
        continue;
      }
      final equals = token.indexOf('=');
      String key;
      String value;
      if (equals > 2) {
        key = token.substring(2, equals);
        value = token.substring(equals + 1);
      } else {
        key = token.substring(2);
        if (_booleanOptions.contains(key)) {
          value = key.startsWith('no-') ? 'false' : 'true';
          if (key.startsWith('no-')) key = key.substring(3);
        } else {
          if (i + 1 >= args.length || args[i + 1].startsWith('--')) {
            throw FormatException('Option --$key requires a value.');
          }
          value = args[++i];
        }
      }
      options.putIfAbsent(key, () => <String>[]).add(value);
      i++;
    }
    if (command.isEmpty) command = 'help';
    return CliArguments(command.toLowerCase(), options, positionals);
  }

  bool has(String key) => options.containsKey(key);

  String? value(String key) => options[key]?.last;

  String string(String key, String fallback) => value(key) ?? fallback;

  int integer(String key, int fallback, {int? minimum}) {
    final raw = value(key);
    if (raw == null) return fallback;
    final parsed = int.tryParse(raw);
    if (parsed == null || (minimum != null && parsed < minimum)) {
      throw FormatException('Invalid value for --$key: "$raw".');
    }
    return parsed;
  }

  double number(String key, double fallback, {double? minimum}) {
    final raw = value(key);
    if (raw == null) return fallback;
    final parsed = double.tryParse(raw);
    if (parsed == null ||
        !parsed.isFinite ||
        (minimum != null && parsed < minimum)) {
      throw FormatException('Invalid value for --$key: "$raw".');
    }
    return parsed;
  }

  bool boolean(String key, bool fallback) {
    final raw = value(key);
    if (raw == null) return fallback;
    switch (raw.toLowerCase()) {
      case 'true':
      case '1':
      case 'yes':
        return true;
      case 'false':
      case '0':
      case 'no':
        return false;
      default:
        throw FormatException('Invalid boolean for --$key: "$raw".');
    }
  }

  List<String> commaList(String key, List<String> fallback) {
    final values = options[key];
    if (values == null) return List<String>.from(fallback);
    return values
        .expand((value) => value.split(','))
        .map((value) => value.trim())
        .where((value) => value.isNotEmpty)
        .toList();
  }
}

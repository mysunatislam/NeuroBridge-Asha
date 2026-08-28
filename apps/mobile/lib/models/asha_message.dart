enum AshaMessageRole { patient, asha }

class AshaMessage {
  const AshaMessage({
    required this.role,
    required this.text,
    required this.sentAt,
    this.mode,
  });

  final AshaMessageRole role;
  final String text;
  final DateTime sentAt;
  final String? mode;
}

class AshaReply {
  const AshaReply({
    required this.text,
    required this.mode,
    required this.urgent,
    this.previousResponseId,
  });

  final String text;
  final String mode;
  final bool urgent;
  final String? previousResponseId;

  bool get isOnline => mode == 'llm';
}

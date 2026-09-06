enum AshaMessageRole { patient, asha }

/// Represents a tool the Asha agentic AI executed during a chat turn.
class AshaToolExecution {
  const AshaToolExecution({
    required this.toolName,
    required this.summary,
    required this.success,
  });

  final String toolName;
  final String summary;
  final bool success;

  factory AshaToolExecution.fromJson(Map<String, dynamic> json) =>
      AshaToolExecution(
        toolName: json['tool_name'] as String? ?? '',
        summary: json['summary'] as String? ?? '',
        success: json['success'] as bool? ?? false,
      );
}

/// A suggested follow-up quick action chip for single-tap / switch scanning.
class AshaQuickAction {
  const AshaQuickAction({
    required this.label,
    required this.actionKey,
    this.payload = '',
  });

  final String label;
  final String actionKey;
  final String payload;

  factory AshaQuickAction.fromJson(Map<String, dynamic> json) =>
      AshaQuickAction(
        label: json['label'] as String? ?? '',
        actionKey: json['action_key'] as String? ?? '',
        payload: json['payload'] as String? ?? '',
      );
}

/// A clinical or knowledge base citation source returned by the RAG system.
class AshaCitation {
  const AshaCitation({required this.title, this.sourceId});

  final String title;
  final String? sourceId;

  factory AshaCitation.fromJson(Map<String, dynamic> json) =>
      AshaCitation(
        title: json['title'] as String? ?? '',
        sourceId: json['source_id'] as String?,
      );
}

class AshaMessage {
  const AshaMessage({
    required this.role,
    required this.text,
    required this.sentAt,
    this.mode,
    this.actionsExecuted = const [],
    this.citations = const [],
    this.quickActions = const [],
  });

  final AshaMessageRole role;
  final String text;
  final DateTime sentAt;
  final String? mode;
  final List<AshaToolExecution> actionsExecuted;
  final List<AshaCitation> citations;
  final List<AshaQuickAction> quickActions;
}

class AshaReply {
  const AshaReply({
    required this.text,
    required this.mode,
    required this.urgent,
    this.previousResponseId,
    this.actionsExecuted = const [],
    this.citations = const [],
    this.quickActions = const [],
  });

  final String text;
  final String mode;
  final bool urgent;
  final String? previousResponseId;
  final List<AshaToolExecution> actionsExecuted;
  final List<AshaCitation> citations;
  final List<AshaQuickAction> quickActions;

  bool get isOnline =>
      mode == 'llm' || mode == 'gemini-agent' || mode == 'openai-agent';

  bool get isAgentMode =>
      mode == 'gemini-agent' || mode == 'openai-agent' || mode == 'offline-agent';
}

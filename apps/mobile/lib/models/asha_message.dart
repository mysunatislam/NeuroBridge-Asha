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

/// A planned step in Asha's multi-step autonomous execution plan.
class AshaPlanStep {
  const AshaPlanStep({
    required this.stepNumber,
    required this.toolName,
    required this.purpose,
    this.status = 'completed',
  });

  final int stepNumber;
  final String toolName;
  final String purpose;
  final String status;

  factory AshaPlanStep.fromJson(Map<String, dynamic> json) => AshaPlanStep(
        stepNumber: json['step_number'] as int? ?? 1,
        toolName: json['tool_name'] as String? ?? '',
        purpose: json['purpose'] as String? ?? '',
        status: json['status'] as String? ?? 'completed',
      );
}

/// The result of Asha's closed-loop verification critic.
class AshaVerificationResult {
  const AshaVerificationResult({
    required this.isVerified,
    required this.safetyPassed,
    required this.goalFulfilled,
    this.groundingScore = 1.0,
    this.critiqueNotes = '',
  });

  final bool isVerified;
  final bool safetyPassed;
  final bool goalFulfilled;
  final double groundingScore;
  final String critiqueNotes;

  factory AshaVerificationResult.fromJson(Map<String, dynamic> json) =>
      AshaVerificationResult(
        isVerified: json['is_verified'] as bool? ?? true,
        safetyPassed: json['safety_passed'] as bool? ?? true,
        goalFulfilled: json['goal_fulfilled'] as bool? ?? true,
        groundingScore: (json['grounding_score'] as num?)?.toDouble() ?? 1.0,
        critiqueNotes: json['critique_notes'] as String? ?? '',
      );
}

/// A recalled or stored patient memory fact.
class AshaMemoryFact {
  const AshaMemoryFact({
    required this.category,
    required this.key,
    required this.value,
  });

  final String category;
  final String key;
  final String value;

  factory AshaMemoryFact.fromJson(Map<String, dynamic> json) => AshaMemoryFact(
        category: json['category'] as String? ?? '',
        key: json['key'] as String? ?? '',
        value: json['value'] as String? ?? '',
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
    this.plan = const [],
    this.verification,
    this.memoryRecalled = const [],
  });

  final AshaMessageRole role;
  final String text;
  final DateTime sentAt;
  final String? mode;
  final List<AshaToolExecution> actionsExecuted;
  final List<AshaCitation> citations;
  final List<AshaQuickAction> quickActions;
  final List<AshaPlanStep> plan;
  final AshaVerificationResult? verification;
  final List<AshaMemoryFact> memoryRecalled;
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
    this.plan = const [],
    this.verification,
    this.memoryRecalled = const [],
  });

  final String text;
  final String mode;
  final bool urgent;
  final String? previousResponseId;
  final List<AshaToolExecution> actionsExecuted;
  final List<AshaCitation> citations;
  final List<AshaQuickAction> quickActions;
  final List<AshaPlanStep> plan;
  final AshaVerificationResult? verification;
  final List<AshaMemoryFact> memoryRecalled;

  bool get isOnline =>
      mode == 'llm' ||
      mode == 'gemini-agent' ||
      mode == 'openai-agent' ||
      mode == 'local-llm-agent';

  bool get isAgentMode =>
      mode == 'gemini-agent' ||
      mode == 'openai-agent' ||
      mode == 'offline-agent' ||
      mode == 'offline-rag-agent' ||
      mode == 'local-llm-agent';
}

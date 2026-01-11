// lib/apps/asistente_retratos/domain/model/ui_step_event.dart

class UiStepEvent {
  final String step;       // e.g. "validando_requisitos"
  final String label;      // e.g. "Validando requisitos"
  final String? requestId;

  const UiStepEvent({
    required this.step,
    required this.label,
    this.requestId,
  });

  factory UiStepEvent.fromJson(Map<String, dynamic> json) {
    return UiStepEvent(
      step: (json['step'] ?? '').toString(),
      label: (json['label'] ?? '').toString(),
      requestId: json['request_id']?.toString(),
    );
  }

  @override
  String toString() => 'UiStepEvent(step: $step, label: $label, rid: $requestId)';
}

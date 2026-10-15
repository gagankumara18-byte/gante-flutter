class AlarmItem {
  const AlarmItem({
    required this.id,
    required this.label,
    required this.dateTime,
    required this.repeat,
    required this.enabled,
    required this.createdWithAi,
    this.notificationIds = const [],
    this.wakeStyle = 'single',
    this.preparationMinutes = 0,
    this.alertOffsetsMinutes = const [0],
    this.snoozeIntervalMinutes = 5,
    this.completionStatus = 'pending',
    this.completedAt,
  });

  final int id;
  final String label;
  final DateTime dateTime;
  final String repeat;
  final bool enabled;
  final bool createdWithAi;
  final List<int> notificationIds;
  final String wakeStyle;
  final int preparationMinutes;
  final List<int> alertOffsetsMinutes;
  final int snoozeIntervalMinutes;
  final String completionStatus;
  final DateTime? completedAt;

  bool get isWakePlan => alertOffsetsMinutes.length > 1;

  List<DateTime> get alertTimes =>
      alertOffsetsMinutes
          .map((offset) => dateTime.subtract(Duration(minutes: offset)))
          .toList()
        ..sort();

  AlarmItem copyWith({
    String? label,
    String? repeat,
    bool? enabled,
    DateTime? dateTime,
    List<int>? notificationIds,
    String? wakeStyle,
    int? preparationMinutes,
    List<int>? alertOffsetsMinutes,
    int? snoozeIntervalMinutes,
    String? completionStatus,
    DateTime? completedAt,
  }) => AlarmItem(
    id: id,
    label: label ?? this.label,
    dateTime: dateTime ?? this.dateTime,
    repeat: repeat ?? this.repeat,
    enabled: enabled ?? this.enabled,
    createdWithAi: createdWithAi,
    notificationIds: notificationIds ?? this.notificationIds,
    wakeStyle: wakeStyle ?? this.wakeStyle,
    preparationMinutes: preparationMinutes ?? this.preparationMinutes,
    alertOffsetsMinutes: alertOffsetsMinutes ?? this.alertOffsetsMinutes,
    snoozeIntervalMinutes: snoozeIntervalMinutes ?? this.snoozeIntervalMinutes,
    completionStatus: completionStatus ?? this.completionStatus,
    completedAt: completedAt ?? this.completedAt,
  );

  Map<String, dynamic> toJson() => {
    'id': id,
    'label': label,
    'dateTime': dateTime.toIso8601String(),
    'repeat': repeat,
    'enabled': enabled,
    'createdWithAi': createdWithAi,
    'notificationIds': notificationIds,
    'wakeStyle': wakeStyle,
    'preparationMinutes': preparationMinutes,
    'alertOffsetsMinutes': alertOffsetsMinutes,
    'snoozeIntervalMinutes': snoozeIntervalMinutes,
    'completionStatus': completionStatus,
    'completedAt': completedAt?.toIso8601String(),
  };

  factory AlarmItem.fromJson(Map<String, dynamic> json) => AlarmItem(
    id: json['id'] as int,
    label: json['label'] as String,
    dateTime: DateTime.parse(json['dateTime'] as String),
    repeat: json['repeat'] as String? ?? 'once',
    enabled: json['enabled'] as bool? ?? true,
    createdWithAi: json['createdWithAi'] as bool? ?? false,
    notificationIds: (json['notificationIds'] as List<dynamic>? ?? const [])
        .map((value) => value as int)
        .toList(),
    wakeStyle: json['wakeStyle'] as String? ?? 'single',
    preparationMinutes: json['preparationMinutes'] as int? ?? 0,
    alertOffsetsMinutes:
        (json['alertOffsetsMinutes'] as List<dynamic>? ?? const [0])
            .map((value) => value as int)
            .toList(),
    snoozeIntervalMinutes: json['snoozeIntervalMinutes'] as int? ?? 5,
    completionStatus: json['completionStatus'] as String? ?? 'pending',
    completedAt: json['completedAt'] == null
        ? null
        : DateTime.tryParse(json['completedAt'] as String),
  );
}

class AlarmDraft {
  const AlarmDraft({
    required this.label,
    required this.dateTime,
    this.repeat = 'once',
    this.explanation = '',
    this.wakeStyle = 'single',
    this.preparationMinutes = 0,
    this.alertOffsetsMinutes = const [0],
    this.snoozeIntervalMinutes = 5,
    this.additionalDateTimes = const [],
  });

  final String label;
  final DateTime dateTime;
  final String repeat;
  final String explanation;
  final String wakeStyle;
  final int preparationMinutes;
  final List<int> alertOffsetsMinutes;
  final int snoozeIntervalMinutes;
  final List<DateTime> additionalDateTimes;

  bool get isWakePlan => alertOffsetsMinutes.length > 1;
}

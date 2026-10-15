import 'dart:convert';

import 'package:flutter_gemma/flutter_gemma.dart';
import 'package:flutter_gemma_litertlm/flutter_gemma_litertlm.dart';

import '../models/alarm.dart';

class LocalAiService {
  static const modelAsset = 'assets/models/SmolLM2_135M_Instruct.litertlm';

  InferenceModel? _model;
  bool _initializing = false;
  int _preferredPreparationMinutes = 20;
  int _preferredSnoozeMinutes = 5;

  bool get isReady => _model != null;

  void setLocalPreferences({
    required int preparationMinutes,
    required int snoozeMinutes,
  }) {
    _preferredPreparationMinutes = preparationMinutes.clamp(5, 180);
    _preferredSnoozeMinutes = snoozeMinutes.clamp(3, 30);
  }

  Future<void> initialize({void Function(int progress)? onProgress}) async {
    if (_model != null || _initializing) return;
    _initializing = true;
    try {
      await FlutterGemma.initialize(inferenceEngines: const [LiteRtLmEngine()]);
      await FlutterGemma.installModel(
        modelType: ModelType.general,
        fileType: ModelFileType.litertlm,
      ).fromAsset(modelAsset).withProgress((progress) {
        onProgress?.call(progress);
      }).install();
      _model = await FlutterGemma.getActiveModel(
        maxTokens: 1024,
        preferredBackend: PreferredBackend.cpu,
      );
    } finally {
      _initializing = false;
    }
  }

  Future<AlarmDraft> interpret(
    String prompt, {
    void Function(int progress)? onProgress,
  }) async {
    AlarmDraft? fallback;
    try {
      fallback = PromptParser.parse(prompt);
    } on FormatException {
      // The model gets a chance to understand language outside the fallback's
      // compact grammar.
    }
    // Explicit alarm grammar is faster and more reliable than loading a
    // generative model. Other languages go directly to the model because the
    // compact fallback grammar intentionally only covers common English forms.
    if (fallback != null) return fallback;
    if (_model == null) await initialize(onProgress: onProgress);
    if (_model == null) {
      throw const FormatException(
        'Include when the alarm should ring, such as “in 20 minutes” or “tomorrow at 7 AM”.',
      );
    }

    InferenceChat? chat;
    try {
      final now = DateTime.now();
      chat = await _model!.createChat(
        modelType: ModelType.general,
        temperature: 0.1,
        topK: 1,
        maxOutputTokens: 160,
        systemInstruction:
          'Understand the alarm request in any natural language and return only compact JSON. '
          'The request may contain mixed languages, translated time words, or non-Latin scripts. '
          'Infer the meaning from the whole request; do not require English keywords. '
          'Use the current local time supplied by the user message when resolving relative dates. '
            'Use keys label, mode, amount, unit, datetime, repeat, preparationMinutes, snoozeIntervalMinutes, wakeStyle. '
            'mode is relative or absolute. For a relative request, extract the integer amount and unit '
            '(minute or hour), and set datetime to null; never interpret a duration number as a clock hour. '
            'For an absolute request, set amount and unit to null and datetime to ISO-8601 local time. '
            'repeat is once, daily, weekdays, or weekends. '
            'wakeStyle is single for a simple reminder, light for an easy wake-up, normal for an activity plan, '
            'or heavy when the user says they are lazy, a heavy sleeper, or asks for repeated alarms. '
            'Estimate preparationMinutes for activities such as jogging, gym, work, or travel; use 0 for simple reminders. '
            'Choose snoozeIntervalMinutes from 3 to 30 based on the request. '
            'No markdown.',
      );
      await chat.addQuery(
        Message.text(
          text:
              'Current local time: ${now.toIso8601String()}\n'
              'Learned local defaults: preparation $_preferredPreparationMinutes minutes, snooze $_preferredSnoozeMinutes minutes.\n'
              'Request: $prompt',
          isUser: true,
        ),
      );
      final response = await chat.generateChatResponse();
      if (response is TextResponse) {
        final match = RegExp(r'\{[\s\S]*\}').firstMatch(response.token);
        if (match != null) {
          final json = jsonDecode(match.group(0)!) as Map<String, dynamic>;
          final mode = json['mode']?.toString().toLowerCase();
          DateTime? date;
          if (mode == 'relative') {
            final amount = int.tryParse(json['amount']?.toString() ?? '');
            final unit = json['unit']?.toString().toLowerCase() ?? '';
            if (amount != null && amount > 0 && amount <= 525600) {
              if (unit.startsWith('min')) {
                date = now.add(Duration(minutes: amount));
              } else if (unit.startsWith('hour') || unit == 'hr') {
                date = now.add(Duration(hours: amount));
              }
            }
          } else if (mode == 'absolute') {
            date = DateTime.tryParse(json['datetime']?.toString() ?? '');
          }
          final repeat = json['repeat']?.toString().toLowerCase() ?? 'once';
          final label = json['label']?.toString().trim() ?? '';
          final allowed = {'once', 'daily', 'weekdays', 'weekends'};
          final wakeStyles = {'single', 'light', 'normal', 'heavy'};
          var wakeStyle =
              json['wakeStyle']?.toString().toLowerCase() ?? 'single';
          if (!wakeStyles.contains(wakeStyle)) wakeStyle = 'single';
          var preparationMinutes =
              int.tryParse(json['preparationMinutes']?.toString() ?? '') ?? 0;
          preparationMinutes = preparationMinutes.clamp(0, 180).toInt();
          if (wakeStyle != 'single' && preparationMinutes == 0) {
            preparationMinutes = _preferredPreparationMinutes;
          }
          var snoozeMinutes =
              int.tryParse(json['snoozeIntervalMinutes']?.toString() ?? '') ??
              _preferredSnoozeMinutes;
          snoozeMinutes = snoozeMinutes.clamp(3, 30).toInt();

          // A known relative duration is a safety constraint, not the primary
          // language parser. Reject a model response that turns it into a clock.
          if (fallback != null &&
              PromptParser.hasRelativeDuration(prompt) &&
              mode != 'relative') {
            return fallback;
          }
          if (date != null &&
              date.isAfter(now) &&
              label.isNotEmpty &&
              allowed.contains(repeat) &&
              date.difference(now).inDays <= 370) {
            return AlarmDraft(
              label: label,
              dateTime: date,
              repeat: repeat,
              wakeStyle: wakeStyle,
              preparationMinutes: preparationMinutes,
              snoozeIntervalMinutes: snoozeMinutes,
              alertOffsetsMinutes: buildWakePlanOffsets(
                wakeStyle,
                preparationMinutes,
                snoozeMinutes,
              ),
              explanation: wakeStyle == 'single'
                  ? 'Understood privately by the on-device model.'
                  : 'Private AI planned preparation and escalating wake-up stages.',
            );
          }
        }
      }
    } catch (_) {
      // Small models occasionally return malformed JSON; deterministic parsing
      // keeps alarm creation dependable and fully offline.
    } finally {
      await chat?.close();
    }
    throw const FormatException(
      'I could not find a reliable alarm time. Try “in 20 minutes” or “tomorrow at 7 AM”.',
    );
  }
}

List<int> buildWakePlanOffsets(
  String wakeStyle,
  int preparationMinutes, [
  int snoozeIntervalMinutes = 5,
]) {
  if (wakeStyle == 'single') return const [0];
  final prep = preparationMinutes.clamp(5, 180).toInt();
  final offsets = <int>{prep + 10, prep, 0};
  if (wakeStyle == 'normal') {
    offsets.addAll(<int>[10, 5]);
  } else if (wakeStyle == 'heavy') {
    final interval = snoozeIntervalMinutes.clamp(3, 30).toInt();
    final firstAlarm = prep + 10 < 30 ? 30 : prep + 10;
    offsets.clear();
    for (var minute = firstAlarm; minute > 0; minute -= interval) {
      offsets.add(minute);
    }
    offsets.add(0);
  }
  return offsets.toList()..sort((a, b) => b.compareTo(a));
}

class PromptParser {
  static final _relativePatterns = <RegExp>[
    RegExp(
      r'(?:in|after)\s+(?:(?:the\s+)?next\s+)?(\d+)\s*(minute|minutes|min|mins|hour|hours|hr|hrs)',
      caseSensitive: false,
    ),
    RegExp(
      r'(?:from\s+now\s+)?(?:the\s+)?next\s+(\d+)\s*(minute|minutes|min|mins|hour|hours|hr|hrs)',
      caseSensitive: false,
    ),
    RegExp(
      r'from\s+now\s+(\d+)\s*(minute|minutes|min|mins|hour|hours|hr|hrs)',
      caseSensitive: false,
    ),
    RegExp(
      r'(\d+)\s*(minute|minutes|min|mins|hour|hours|hr|hrs)\s*(?:from\s+now|later)',
      caseSensitive: false,
    ),
  ];

  static bool hasRelativeDuration(String input) =>
      _relativePatterns.any((pattern) => pattern.hasMatch(input));

  static bool hasExplicitTime(String input) {
    final lower = input.toLowerCase();
    return hasRelativeDuration(lower) ||
        RegExp(r'\d{1,2}[:.]\d{2}').hasMatch(lower) ||
        RegExp(r'\b\d{1,2}\s*(?:a\.?m\.?|p\.?m\.?)\b').hasMatch(lower) ||
        RegExp(r'\b(?:at|around|by)\s+\d{1,2}\b').hasMatch(lower) ||
        RegExp(r'\b(?:noon|midnight)\b').hasMatch(lower);
  }

  static RegExpMatch? _relativeMatch(String input) {
    for (final pattern in _relativePatterns) {
      final match = pattern.firstMatch(input);
      if (match != null) return match;
    }
    return null;
  }

  static AlarmDraft parse(String input, {DateTime? referenceTime}) {
    final text = input.trim();
    final lower = text
        .toLowerCase()
        .replaceAll('tommotow', 'tomorrow')
        .replaceAll('tommorow', 'tomorrow')
        .replaceAll('tomorow', 'tomorrow');
    final now = referenceTime ?? DateTime.now();
    DateTime? date;
    var repeat = 'once';

    final intervalSeries = RegExp(
      r'every\s+(\d+)\s*(minute|minutes|min|mins)\s+(?:until|till|up\s+to)\s*(\d{1,2})(?:[:.](\d{2}))?\s*(am|pm|a\.m\.|p\.m\.)?',
      caseSensitive: false,
    ).firstMatch(lower);
    if (intervalSeries != null) {
      final interval = int.parse(intervalSeries.group(1)!);
      if (interval < 1 || interval > 180) {
        throw const FormatException('Use an interval from 1 to 180 minutes.');
      }
      var hour = int.parse(intervalSeries.group(3)!);
      final minute = int.tryParse(intervalSeries.group(4) ?? '0') ?? 0;
      final period = (intervalSeries.group(5) ?? '').replaceAll('.', '');
      if (hour > 23 || minute > 59) {
        throw const FormatException('That ending time is not valid.');
      }
      late DateTime deadline;
      if (period.isEmpty && hour <= 12) {
        final baseHour = hour == 12 ? 0 : hour;
        final candidates = <DateTime>[
          DateTime(now.year, now.month, now.day, baseHour, minute),
          DateTime(now.year, now.month, now.day, baseHour + 12, minute),
          DateTime(now.year, now.month, now.day + 1, baseHour, minute),
          DateTime(now.year, now.month, now.day + 1, baseHour + 12, minute),
        ].where((candidate) => candidate.isAfter(now)).toList()..sort();
        deadline = candidates.first;
      } else {
        if (period == 'pm' && hour < 12) hour += 12;
        if (period == 'am' && hour == 12) hour = 0;
        deadline = DateTime(now.year, now.month, now.day, hour, minute);
        if (!deadline.isAfter(now)) {
          deadline = deadline.add(const Duration(days: 1));
        }
      }
      var next = DateTime(
        now.year,
        now.month,
        now.day,
        now.hour,
        now.minute,
      ).add(Duration(minutes: interval));
      final times = <DateTime>[];
      while (next.isBefore(deadline) && times.length < 120) {
        times.add(next);
        next = next.add(Duration(minutes: interval));
      }
      if (times.isEmpty) {
        throw const FormatException(
          'The ending time must allow at least one alarm.',
        );
      }
      var label = text
          .replaceRange(intervalSeries.start, intervalSeries.end, '')
          .replaceFirst(
            RegExp(
              r'^(please\s+)?((set|create|add|make)\s+(an?\s+)?alarm(\s+(for|to))?)\s*',
              caseSensitive: false,
            ),
            '',
          )
          .trim();
      if (label.isEmpty) label = 'Interval alarm';
      label = '${label[0].toUpperCase()}${label.substring(1)}';
      return AlarmDraft(
        label: label,
        dateTime: times.first,
        additionalDateTimes: times.skip(1).toList(),
        explanation:
            '${times.length} alarms, every $interval minutes until the ending time.',
      );
    }

    final relative = _relativeMatch(lower);
    if (relative != null) {
      final amount = int.parse(relative.group(1)!);
      final isHours = relative.group(2)!.startsWith('h');
      date = now.add(
        Duration(hours: isHours ? amount : 0, minutes: isHours ? 0 : amount),
      );
    }

    if (lower.contains('weekday') || lower.contains('workday')) {
      repeat = 'weekdays';
    } else if (lower.contains('weekend')) {
      repeat = 'weekends';
    } else if (lower.contains('every day') || lower.contains('daily')) {
      repeat = 'daily';
    }

    if (date == null) {
      final timeMatch =
          RegExp(
            r'(?:(at|around|by)\s*)?(\d{1,2})(?:[:.](\d{2}))?\s*(am|pm|a\.m\.|p\.m\.)?',
          ).allMatches(lower).where((match) {
            return match.group(1) != null ||
                match.group(3) != null ||
                match.group(4) != null;
          }).lastOrNull;
      if (timeMatch == null) {
        throw const FormatException(
          'Add a time, for example “tomorrow at 7 AM” or “in 20 minutes”.',
        );
      }
      var hour = int.parse(timeMatch.group(2)!);
      final minute = int.tryParse(timeMatch.group(3) ?? '0') ?? 0;
      final period = (timeMatch.group(4) ?? '').replaceAll('.', '');
      if ((period == 'pm' ||
              lower.contains('evening') ||
              lower.contains('tonight')) &&
          hour < 12) {
        hour += 12;
      }
      if (period == 'am' && hour == 12) hour = 0;
      if (hour > 23 || minute > 59) {
        throw const FormatException('That time is not valid.');
      }
      var candidate = DateTime(now.year, now.month, now.day, hour, minute);
      if (lower.contains('tomorrow')) {
        candidate = candidate.add(const Duration(days: 1));
      }

      const days = [
        'monday',
        'tuesday',
        'wednesday',
        'thursday',
        'friday',
        'saturday',
        'sunday',
      ];
      final requestedDay = days.indexWhere(lower.contains);
      if (requestedDay >= 0) {
        var difference = ((requestedDay + 1) - candidate.weekday + 7) % 7;
        if (difference == 0 && !candidate.isAfter(now)) difference = 7;
        candidate = candidate.add(Duration(days: difference));
      } else if (!candidate.isAfter(now)) {
        candidate = candidate.add(const Duration(days: 1));
      }
      if (repeat == 'weekdays') {
        while (candidate.weekday > DateTime.friday) {
          candidate = candidate.add(const Duration(days: 1));
        }
      }
      date = candidate;
    }

    var label = text
        .replaceFirst(
          RegExp(
            r'^(tomorrow|tommotow|tommorow|tomorow|today|tonight)\s*[,.-]?\s*',
            caseSensitive: false,
          ),
          '',
        )
        .replaceFirst(
          RegExp(
            r'^(please\s+)?((set|create|add|make)\s+(an?\s+)?alarm(\s+(for|to))?|remind\s+me\s+to|i\s+need\s+to|i\s+have\s+to)\s*',
            caseSensitive: false,
          ),
          '',
        )
        .replaceFirst(
          RegExp(
            r'\s+(tomorrow|today|tonight|every day|daily|every weekday|on weekdays|every weekend|on weekends)?\s*(at|around|by)\s*\d{1,2}([:.]\d{2})?\s*(a\.?m\.?|p\.?m\.?|in the morning|in the evening|at night)?\s*$',
            caseSensitive: false,
          ),
          '',
        )
        .replaceAll(
          RegExp(
            r'\b(i\s*am\s+lazy|i\x27m\s+lazy|lazy\s+person|heavy\s+sleeper)\b',
            caseSensitive: false,
          ),
          '',
        )
        .trim();
    for (final pattern in _relativePatterns) {
      label = label.replaceFirst(pattern, '').trim();
    }
    if (label.isEmpty) {
      label = 'Alarm';
    } else if (label.toLowerCase() == 'wake me') {
      label = 'Wake up';
    }
    label = '${label[0].toUpperCase()}${label.substring(1)}';
    var wakeStyle = 'single';
    var preparationMinutes = 0;
    if (RegExp(
      r'\b(gym|jog|jogging|walk|walking|run|running|workout|exercise)\b',
    ).hasMatch(lower)) {
      wakeStyle = 'normal';
      preparationMinutes = 20;
    } else if (RegExp(r'\b(travel|trip|flight|airport|train|bus)\b')
        .hasMatch(lower)) {
      wakeStyle = 'normal';
      preparationMinutes = 45;
    } else if (RegExp(r'\b(work|office|school|college|class|meeting)\b')
        .hasMatch(lower)) {
      wakeStyle = 'normal';
      preparationMinutes = 30;
    }
    final statedPreparation = RegExp(
      r'(\d+)\s*(?:minute|minutes|min|mins)\s+(?:to\s+)?(?:get\s+)?ready',
    ).firstMatch(lower);
    if (statedPreparation != null) {
      preparationMinutes = int.parse(statedPreparation.group(1)!)
          .clamp(5, 180)
          .toInt();
      wakeStyle = 'normal';
    }
    if (RegExp(
      r'\b(lazy|heavy\s+sleeper|hard\s+to\s+wake|keep\s+waking|repeated\s+alarms?)\b',
    ).hasMatch(lower)) {
      wakeStyle = 'heavy';
      if (preparationMinutes == 0) preparationMinutes = 20;
    }
    return AlarmDraft(
      label: label,
      dateTime: date,
      repeat: repeat,
      wakeStyle: wakeStyle,
      preparationMinutes: preparationMinutes,
      snoozeIntervalMinutes: 5,
      alertOffsetsMinutes: buildWakePlanOffsets(
        wakeStyle,
        preparationMinutes,
        5,
      ),
      explanation: wakeStyle == 'single'
          ? 'Verified locally on your device.'
          : '$preparationMinutes minutes of preparation with a ${wakeStyle == 'heavy' ? '5-minute repeated' : 'progressive'} wake-up plan.',
    );
  }
}

extension _LastOrNull<T> on Iterable<T> {
  T? get lastOrNull => isEmpty ? null : last;
}

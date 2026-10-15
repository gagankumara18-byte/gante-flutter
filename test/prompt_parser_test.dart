import 'package:flutter_test/flutter_test.dart';
import 'package:gante_app/services/local_ai_service.dart';

void main() {
  group('PromptParser', () {
    test('understands relative time', () {
      final before = DateTime.now().add(const Duration(minutes: 19));
      final alarm = PromptParser.parse('Wake me in 20 minutes');
      final after = DateTime.now().add(const Duration(minutes: 21));

      expect(alarm.label, 'Wake up');
      expect(alarm.dateTime.isAfter(before), isTrue);
      expect(alarm.dateTime.isBefore(after), isTrue);
    });

    test('understands next-minute phrasing without treating it as a clock', () {
      final before = DateTime.now().add(const Duration(minutes: 9));
      final alarm = PromptParser.parse('create a alarm in next 10 mins');
      final after = DateTime.now().add(const Duration(minutes: 11));

      expect(PromptParser.hasRelativeDuration('in next 10 mins'), isTrue);
      expect(alarm.label, 'Alarm');
      expect(alarm.dateTime.isAfter(before), isTrue);
      expect(alarm.dateTime.isBefore(after), isTrue);
    });

    test('understands from-now next-minute phrasing', () {
      final before = DateTime.now().add(const Duration(minutes: 29));
      final alarm = PromptParser.parse('create a alarm from now next 30 mins');
      final after = DateTime.now().add(const Duration(minutes: 31));

      expect(PromptParser.hasRelativeDuration('from now next 30 mins'), isTrue);
      expect(alarm.label, 'Alarm');
      expect(alarm.dateTime.isAfter(before), isTrue);
      expect(alarm.dateTime.isBefore(after), isTrue);
    });

    test('understands weekday repeats', () {
      final alarm = PromptParser.parse('Gym every weekday at 6 AM');

      expect(alarm.label, 'Gym');
      expect(alarm.repeat, 'weekdays');
      expect(alarm.dateTime.hour, 6);
      expect(alarm.dateTime.weekday, lessThanOrEqualTo(DateTime.friday));
    });

    test('plans preparation for a gym intent', () {
      final alarm = PromptParser.parse(
        'tommotow i need to go to gym around 6 am',
        referenceTime: DateTime(2026, 9, 18, 12),
      );

      expect(alarm.dateTime, DateTime(2026, 9, 19, 6));
      expect(alarm.wakeStyle, 'normal');
      expect(alarm.preparationMinutes, 20);
      expect(alarm.alertOffsetsMinutes, <int>[30, 20, 10, 5, 0]);
    });

    test('creates five-minute stages for a lazy user', () {
      final alarm = PromptParser.parse(
        'Tomorrow I am lazy and need to go to gym around 6 AM',
        referenceTime: DateTime(2026, 9, 18, 12),
      );

      expect(alarm.wakeStyle, 'heavy');
      expect(alarm.alertOffsetsMinutes, <int>[30, 25, 20, 15, 10, 5, 0]);
    });

    test('asks for a time when missing', () {
      expect(() => PromptParser.parse('Go walking'), throwsFormatException);
    });

    test('does not mistake an unrelated number for an alarm time', () {
      expect(
        () => PromptParser.parse('Remind me to buy 2 eggs'),
        throwsFormatException,
      );
      expect(PromptParser.hasExplicitTime('buy 2 eggs'), isFalse);
    });

    test('creates interval alarms before, but not at, the ending time', () {
      final alarm = PromptParser.parse(
        'set a alarm for every 2 mins till 7:50',
        referenceTime: DateTime(2026, 9, 18, 7, 44),
      );

      expect(alarm.dateTime, DateTime(2026, 9, 18, 7, 46));
      expect(alarm.additionalDateTimes, <DateTime>[
        DateTime(2026, 9, 18, 7, 48),
      ]);
    });
  });

  group('wake plan', () {
    test('heavy style creates five-minute escalating stages', () {
      expect(buildWakePlanOffsets('heavy', 20), <int>[
        30,
        25,
        20,
        15,
        10,
        5,
        0,
      ]);
    });

    test('single reminders create only the requested alarm', () {
      expect(buildWakePlanOffsets('single', 20), <int>[0]);
    });

    test('heavy style uses the learned snooze interval', () {
      expect(buildWakePlanOffsets('heavy', 30, 10), <int>[40, 30, 20, 10, 0]);
    });
  });
}

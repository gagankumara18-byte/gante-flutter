import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:flutter/services.dart';
import 'package:flutter_timezone/flutter_timezone.dart';
import 'package:timezone/data/latest.dart' as tz_data;
import 'package:timezone/timezone.dart' as tz;

import '../models/alarm.dart';

class NotificationService {
  static const _adaptive = MethodChannel('com.gante.gante_app/adaptive');
  final FlutterLocalNotificationsPlugin _plugin =
      FlutterLocalNotificationsPlugin();

  static const _gentleDetails = NotificationDetails(
    android: AndroidNotificationDetails(
      'gante_wake_gentle_v1',
      'Gante gentle reminders',
      channelDescription: 'Early reminders for a Gante wake-up plan',
      importance: Importance.high,
      priority: Priority.high,
      playSound: true,
      enableVibration: true,
      category: AndroidNotificationCategory.reminder,
    ),
    iOS: DarwinNotificationDetails(
      presentAlert: true,
      presentSound: true,
      interruptionLevel: InterruptionLevel.active,
    ),
  );

  static const _mediumDetails = NotificationDetails(
    android: AndroidNotificationDetails(
      'gante_wake_medium_v1',
      'Gante wake-up alerts',
      channelDescription: 'Wake-up alerts that become stronger over time',
      importance: Importance.max,
      priority: Priority.max,
      playSound: true,
      enableVibration: true,
      category: AndroidNotificationCategory.alarm,
      audioAttributesUsage: AudioAttributesUsage.alarm,
      fullScreenIntent: true,
    ),
    iOS: DarwinNotificationDetails(
      presentAlert: true,
      presentSound: true,
      interruptionLevel: InterruptionLevel.timeSensitive,
    ),
  );

  static final _strongDetails = NotificationDetails(
    android: AndroidNotificationDetails(
      'gante_wake_strong_v1',
      'Gante strong alarms',
      channelDescription: 'Final strong alarms in a Gante wake-up plan',
      importance: Importance.max,
      priority: Priority.max,
      playSound: true,
      enableVibration: true,
      category: AndroidNotificationCategory.alarm,
      audioAttributesUsage: AudioAttributesUsage.alarm,
      fullScreenIntent: true,
      additionalFlags: Int32List.fromList(<int>[4]),
    ),
    iOS: DarwinNotificationDetails(
      presentAlert: true,
      presentSound: true,
      interruptionLevel: InterruptionLevel.timeSensitive,
    ),
  );

  Future<void> initialize() async {
    tz_data.initializeTimeZones();
    try {
      final deviceTimezone = await FlutterTimezone.getLocalTimezone();
      tz.setLocalLocation(tz.getLocation(deviceTimezone.identifier));
    } catch (_) {
      // tz.local remains UTC only if the platform cannot report a timezone.
    }

    await _plugin.initialize(
      settings: const InitializationSettings(
        android: AndroidInitializationSettings('@mipmap/ic_launcher'),
        iOS: DarwinInitializationSettings(),
      ),
    );
  }

  Future<bool> requestPermissions() async {
    if (Platform.isAndroid) {
      final android = _plugin
          .resolvePlatformSpecificImplementation<
            AndroidFlutterLocalNotificationsPlugin
          >();
      if (android == null) return false;

      var notificationsEnabled =
          await android.areNotificationsEnabled() ?? false;
      if (!notificationsEnabled) {
        notificationsEnabled =
            await android.requestNotificationsPermission() ?? false;
      }

      final exactAlarmsEnabled =
          await android.canScheduleExactNotifications() ?? true;
      if (!exactAlarmsEnabled) {
        await android.requestExactAlarmsPermission();
      }
      await android.requestFullScreenIntentPermission();
      return notificationsEnabled;
    } else if (Platform.isIOS) {
      return await _plugin
              .resolvePlatformSpecificImplementation<
                IOSFlutterLocalNotificationsPlugin
              >()
              ?.requestPermissions(alert: true, sound: true, badge: true) ??
          false;
    }
    return true;
  }

  Future<List<int>> schedule(AlarmItem alarm) async {
    await cancelAlarm(alarm);
    if (Platform.isAndroid && alarm.repeat == 'once') {
      final ids = await _adaptive.invokeMethod<List<dynamic>>('schedulePlan', {
        'alarmId': alarm.id,
        'label': alarm.label,
        'targetMillis': alarm.dateTime.millisecondsSinceEpoch,
        'offsets': alarm.alertOffsetsMinutes,
      });
      return (ids ?? const []).map((id) => id as int).toList();
    }
    final ids = <int>[];
    final offsets = alarm.alertOffsetsMinutes.toSet().toList()
      ..sort((a, b) => b.compareTo(a));
    var slot = 0;

    for (final offset in offsets) {
      final details = offset == 0
          ? _strongDetails
          : offset == offsets.first
          ? _gentleDetails
          : _mediumDetails;

      if (alarm.repeat == 'weekdays' || alarm.repeat == 'weekends') {
        final weekdays = alarm.repeat == 'weekdays'
            ? <int>[
                DateTime.monday,
                DateTime.tuesday,
                DateTime.wednesday,
                DateTime.thursday,
                DateTime.friday,
              ]
            : <int>[DateTime.saturday, DateTime.sunday];
        for (final weekday in weekdays) {
          final target = _nextWeekday(alarm.dateTime, weekday);
          final stageTime = target.subtract(Duration(minutes: offset));
          final id = _notificationId(alarm.id, slot++);
          await _scheduleOne(
            alarm,
            id,
            stageTime,
            DateTimeComponents.dayOfWeekAndTime,
            details,
            offset,
          );
          ids.add(id);
        }
      } else {
        var stageTime = alarm.dateTime.subtract(Duration(minutes: offset));
        final match = alarm.repeat == 'daily' ? DateTimeComponents.time : null;
        if (match != null) {
          while (!stageTime.isAfter(DateTime.now())) {
            stageTime = stageTime.add(const Duration(days: 1));
          }
        } else if (!stageTime.isAfter(DateTime.now())) {
          continue;
        }
        final id = _notificationId(alarm.id, slot++);
        await _scheduleOne(alarm, id, stageTime, match, details, offset);
        ids.add(id);
      }
    }
    return ids;
  }

  int _notificationId(int alarmId, int slot) =>
      (alarmId + (slot * 1000003)) & 0x7fffffff;

  Future<void> _scheduleOne(
    AlarmItem alarm,
    int id,
    DateTime date,
    DateTimeComponents? match,
    NotificationDetails details,
    int offset,
  ) async {
    final scheduled = tz.TZDateTime.from(date, tz.local);
    final body = offset == 0
        ? '${alarm.label} starts now. Time to get moving.'
        : offset == alarm.alertOffsetsMinutes.reduce((a, b) => a > b ? a : b)
        ? '${alarm.label} is in $offset minutes. Get ready soon.'
        : 'Wake up for ${alarm.label}. $offset minutes remaining.';
    try {
      await _plugin.zonedSchedule(
        id: id,
        title: 'Gante · ${alarm.label}',
        body: body,
        scheduledDate: scheduled,
        notificationDetails: details,
        androidScheduleMode: AndroidScheduleMode.exactAllowWhileIdle,
        matchDateTimeComponents: match,
        payload: alarm.id.toString(),
      );
    } catch (_) {
      await _plugin.zonedSchedule(
        id: id,
        title: 'Gante · ${alarm.label}',
        body: body,
        scheduledDate: scheduled,
        notificationDetails: details,
        androidScheduleMode: AndroidScheduleMode.inexactAllowWhileIdle,
        matchDateTimeComponents: match,
        payload: alarm.id.toString(),
      );
    }
  }

  DateTime _nextWeekday(DateTime time, int weekday) {
    final now = DateTime.now();
    var candidate = DateTime(
      now.year,
      now.month,
      now.day,
      time.hour,
      time.minute,
    );
    var days = (weekday - candidate.weekday + 7) % 7;
    if (days == 0 && !candidate.isAfter(now)) days = 7;
    return candidate.add(Duration(days: days));
  }

  Future<void> cancel(List<int> ids) async {
    for (final id in ids) {
      await _plugin.cancel(id: id);
    }
  }

  Future<void> cancelAlarm(AlarmItem alarm) async {
    await cancel(alarm.notificationIds);
    if (Platform.isAndroid) {
      await _adaptive.invokeMethod<void>('cancelPlan', {'alarmId': alarm.id});
    }
  }

  Future<void> completeAlarm(AlarmItem alarm) async {
    await cancel(alarm.notificationIds);
    if (Platform.isAndroid) {
      await _adaptive.invokeMethod<void>('completePlan', {'alarmId': alarm.id});
    }
  }

  Future<bool> hasUsageAccess() async {
    if (!Platform.isAndroid) return false;
    return await _adaptive.invokeMethod<bool>('hasUsageAccess') ?? false;
  }

  Future<void> requestUsageAccess() async {
    if (Platform.isAndroid) {
      await _adaptive.invokeMethod<void>('requestUsageAccess');
    }
  }

  Future<Set<int>> completedAlarmIds() async {
    if (!Platform.isAndroid) return const {};
    final ids = await _adaptive.invokeMethod<List<dynamic>>('completedIds');
    return (ids ?? const []).map((id) => id as int).toSet();
  }
}

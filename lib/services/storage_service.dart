import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

import '../models/alarm.dart';

class StorageService {
  static const _alarmsKey = 'gante_alarms_v1';
  static const _profileKey = 'gante_adaptive_profile_v1';

  Future<List<AlarmItem>> loadAlarms() async {
    final preferences = await SharedPreferences.getInstance();
    final raw = preferences.getString(_alarmsKey);
    if (raw == null) return [];
    try {
      final decoded = jsonDecode(raw) as List<dynamic>;
      return decoded
          .map((item) => AlarmItem.fromJson(item as Map<String, dynamic>))
          .toList();
    } catch (_) {
      return [];
    }
  }

  Future<void> saveAlarms(List<AlarmItem> alarms) async {
    final preferences = await SharedPreferences.getInstance();
    await preferences.setString(
      _alarmsKey,
      jsonEncode(alarms.map((alarm) => alarm.toJson()).toList()),
    );
  }

  Future<AdaptiveProfile> loadProfile() async {
    final preferences = await SharedPreferences.getInstance();
    final raw = preferences.getString(_profileKey);
    if (raw == null) return const AdaptiveProfile();
    try {
      return AdaptiveProfile.fromJson(jsonDecode(raw) as Map<String, dynamic>);
    } catch (_) {
      return const AdaptiveProfile();
    }
  }

  Future<AdaptiveProfile> learnFromCompletion(AlarmItem alarm) async {
    final current = await loadProfile();
    final count = current.samples + 1;
    final updated = AdaptiveProfile(
      preparationMinutes:
          ((current.preparationMinutes * current.samples +
                      alarm.preparationMinutes) /
                  count)
              .round(),
      snoozeIntervalMinutes:
          ((current.snoozeIntervalMinutes * current.samples +
                      alarm.snoozeIntervalMinutes) /
                  count)
              .round(),
      samples: count,
    );
    final preferences = await SharedPreferences.getInstance();
    await preferences.setString(_profileKey, jsonEncode(updated.toJson()));
    return updated;
  }
}

class AdaptiveProfile {
  const AdaptiveProfile({
    this.preparationMinutes = 20,
    this.snoozeIntervalMinutes = 5,
    this.samples = 0,
  });

  final int preparationMinutes;
  final int snoozeIntervalMinutes;
  final int samples;

  Map<String, dynamic> toJson() => {
    'preparationMinutes': preparationMinutes,
    'snoozeIntervalMinutes': snoozeIntervalMinutes,
    'samples': samples,
  };

  factory AdaptiveProfile.fromJson(Map<String, dynamic> json) =>
      AdaptiveProfile(
        preparationMinutes: json['preparationMinutes'] as int? ?? 20,
        snoozeIntervalMinutes: json['snoozeIntervalMinutes'] as int? ?? 5,
        samples: json['samples'] as int? ?? 0,
      );
}

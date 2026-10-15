import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:intl/intl.dart';
import 'package:speech_to_text/speech_to_text.dart' as stt;

import 'models/alarm.dart';
import 'services/local_ai_service.dart';
import 'services/notification_service.dart';
import 'services/storage_service.dart';

const ink = Color(0xFF18352E);
const coral = Color(0xFFED775F);
const paper = Color(0xFFF5F2EB);
const cream = Color(0xFFFFFDF8);
const muted = Color(0xFF718078);
const mint = Color(0xFFDCEADF);
const smallLabel = TextStyle(
  color: muted,
  fontSize: 9,
  fontWeight: FontWeight.w800,
  letterSpacing: 1.5,
);

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  runApp(const GanteApp());
}

class GanteApp extends StatelessWidget {
  const GanteApp({super.key});
  @override
  Widget build(BuildContext context) => MaterialApp(
    debugShowCheckedModeBanner: false,
    title: 'Gante',
    theme: ThemeData(
      useMaterial3: true,
      scaffoldBackgroundColor: paper,
      colorScheme: ColorScheme.fromSeed(
        seedColor: coral,
        primary: coral,
        secondary: ink,
        surface: cream,
      ),
      textTheme: const TextTheme(
        displaySmall: TextStyle(
          color: ink,
          fontSize: 40,
          height: 1.06,
          fontWeight: FontWeight.w700,
          letterSpacing: -1.8,
        ),
        headlineSmall: TextStyle(
          color: ink,
          fontSize: 25,
          fontWeight: FontWeight.w700,
          letterSpacing: -.7,
        ),
        bodyMedium: TextStyle(color: muted, height: 1.5),
      ),
      inputDecorationTheme: InputDecorationTheme(
        filled: true,
        fillColor: cream,
        contentPadding: const EdgeInsets.symmetric(
          horizontal: 18,
          vertical: 16,
        ),
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(16),
          borderSide: const BorderSide(color: Color(0xFFDEDBD2)),
        ),
        enabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(16),
          borderSide: const BorderSide(color: Color(0xFFDEDBD2)),
        ),
        focusedBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(16),
          borderSide: const BorderSide(color: coral, width: 1.5),
        ),
      ),
    ),
    home: const GanteHome(),
  );
}

class GanteHome extends StatefulWidget {
  const GanteHome({super.key});
  @override
  State<GanteHome> createState() => _GanteHomeState();
}

class _GanteHomeState extends State<GanteHome> with WidgetsBindingObserver {
  static const shareChannel = MethodChannel('com.gante.gante_app/share');
  final storage = StorageService();
  final notifications = NotificationService();
  final ai = LocalAiService();
  final promptKey = GlobalKey<_PromptScreenState>();
  List<AlarmItem> alarms = [];
  int page = 0;
  bool loading = true;
  bool awakePromptOpen = false;
  bool usageAccessGranted = false;
  String? pendingSharedText;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    initializeSharing();
    bootstrap();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    shareChannel.setMethodCallHandler(null);
    super.dispose();
  }

  Future<void> initializeSharing() async {
    shareChannel.setMethodCallHandler((call) async {
      if (call.method == 'sharedText' && call.arguments is String) {
        openSharedText(call.arguments as String);
      }
    });
    try {
      final text = await shareChannel.invokeMethod<String>('getInitialText');
      if (text != null && text.trim().isNotEmpty) openSharedText(text);
    } on PlatformException {
      // Sharing is an Android enhancement; the rest of Gante still works.
    }
  }

  void openSharedText(String text) {
    pendingSharedText = text.trim();
    if (!mounted || loading) return;
    setState(() => page = 1);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      final shared = pendingSharedText;
      if (shared == null) return;
      promptKey.currentState?.acceptSharedText(shared);
      pendingSharedText = null;
    });
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed && !loading) {
      refreshUsageAccess();
      syncNativeCompletions().then((_) {
        WidgetsBinding.instance.addPostFrameCallback((_) => confirmIfAwake());
      });
    }
  }

  Future<void> refreshUsageAccess() async {
    try {
      final granted = await notifications.hasUsageAccess();
      if (mounted) setState(() => usageAccessGranted = granted);
    } catch (_) {}
  }

  Future<void> enableUsageAccess() => notifications.requestUsageAccess();

  Future<void> syncNativeCompletions() async {
    try {
      final completedIds = await notifications.completedAlarmIds();
      final newlyCompleted = alarms
          .where(
            (alarm) =>
                completedIds.contains(alarm.id) &&
                alarm.completionStatus == 'pending',
          )
          .toList();
      if (newlyCompleted.isEmpty) return;
      for (final alarm in newlyCompleted.where((alarm) => alarm.isWakePlan)) {
        final profile = await storage.learnFromCompletion(alarm);
        ai.setLocalPreferences(
          preparationMinutes: profile.preparationMinutes,
          snoozeMinutes: profile.snoozeIntervalMinutes,
        );
      }
      if (!mounted) return;
      setState(() {
        alarms = alarms.map((alarm) {
          if (!completedIds.contains(alarm.id) ||
              alarm.completionStatus != 'pending') {
            return alarm;
          }
          return alarm.copyWith(
            enabled: false,
            completionStatus: 'completed',
            completedAt: DateTime.now(),
          );
        }).toList();
      });
      await storage.saveAlarms(alarms);
    } catch (_) {}
  }

  Future<void> bootstrap() async {
    var saved = await storage.loadAlarms();
    final profile = await storage.loadProfile();
    ai.setLocalPreferences(
      preparationMinutes: profile.preparationMinutes,
      snoozeMinutes: profile.snoozeIntervalMinutes,
    );
    try {
      await notifications.initialize();
      await notifications.requestPermissions();
      usageAccessGranted = await notifications.hasUsageAccess();
      final completedIds = await notifications.completedAlarmIds();
      for (final alarm in saved.where(
        (alarm) =>
            completedIds.contains(alarm.id) &&
            alarm.completionStatus == 'pending' &&
            alarm.isWakePlan,
      )) {
        final learned = await storage.learnFromCompletion(alarm);
        ai.setLocalPreferences(
          preparationMinutes: learned.preparationMinutes,
          snoozeMinutes: learned.snoozeIntervalMinutes,
        );
      }
      saved = saved.map((alarm) {
        if (completedIds.contains(alarm.id) &&
            alarm.completionStatus == 'pending') {
          return alarm.copyWith(
            enabled: false,
            completionStatus: 'completed',
            completedAt: DateTime.now(),
          );
        }
        return alarm;
      }).toList();
      final now = DateTime.now();
      final refreshed = <AlarmItem>[];
      for (final alarm in saved) {
        final shouldSchedule =
            alarm.enabled &&
            (alarm.repeat != 'once' || alarm.dateTime.isAfter(now));
        if (shouldSchedule) {
          try {
            refreshed.add(
              alarm.copyWith(
                notificationIds: await notifications.schedule(alarm),
              ),
            );
          } catch (_) {
            refreshed.add(alarm);
          }
        } else {
          refreshed.add(alarm);
        }
      }
      saved = refreshed;
      await storage.saveAlarms(saved);
    } catch (_) {}
    if (!mounted) return;
    setState(() {
      alarms = saved..sort((a, b) => a.dateTime.compareTo(b.dateTime));
      loading = false;
    });
    WidgetsBinding.instance.addPostFrameCallback((_) {
      confirmIfAwake();
      final shared = pendingSharedText;
      if (shared != null) openSharedText(shared);
    });
  }

  Future<void> addAlarm(
    AlarmDraft draft, {
    required bool fromAi,
    bool partOfSeries = false,
  }) async {
    if (draft.additionalDateTimes.isNotEmpty) {
      final dates = <DateTime>[draft.dateTime, ...draft.additionalDateTimes];
      for (final date in dates) {
        await addAlarm(
          AlarmDraft(
            label: draft.label,
            dateTime: date,
            explanation: draft.explanation,
          ),
          fromAi: fromAi,
          partOfSeries: true,
        );
      }
      if (mounted) {
        notice(
          '${dates.length} alarms created: ${dates.map((date) => DateFormat('h:mm a').format(date)).join(', ')}',
        );
      }
      return;
    }
    final relatedMatches = alarms
        .where(
          (item) =>
              !partOfSeries && item.enabled && alarmsAreRelated(item, draft),
        )
        .toList();
    final related = relatedMatches.isEmpty ? null : relatedMatches.first;
    if (related != null) await notifications.cancelAlarm(related);
    final wakeStyle = related == null
        ? draft.wakeStyle
        : strongerWakeStyle(related.wakeStyle, draft.wakeStyle);
    final preparationMinutes = related == null
        ? draft.preparationMinutes
        : (related.preparationMinutes > draft.preparationMinutes
              ? related.preparationMinutes
              : draft.preparationMinutes);
    final snoozeMinutes = related == null
        ? draft.snoozeIntervalMinutes
        : ((related.snoozeIntervalMinutes + draft.snoozeIntervalMinutes) / 2)
              .round();
    var alarm = AlarmItem(
      id:
          related?.id ??
          (DateTime.now().millisecondsSinceEpoch +
                  draft.dateTime.millisecondsSinceEpoch)
              .remainder(2000000000),
      label: related != null && related.label.length > draft.label.length
          ? related.label
          : draft.label,
      dateTime: draft.dateTime,
      repeat: draft.repeat,
      enabled: true,
      createdWithAi: fromAi || (related?.createdWithAi ?? false),
      wakeStyle: wakeStyle,
      preparationMinutes: preparationMinutes,
      alertOffsetsMinutes: buildWakePlanOffsets(
        wakeStyle,
        preparationMinutes,
        snoozeMinutes,
      ),
      snoozeIntervalMinutes: snoozeMinutes,
    );
    var scheduled = false;
    try {
      final notificationsAllowed = await notifications.requestPermissions();
      if (!notificationsAllowed) {
        throw StateError('Notifications are disabled');
      }
      alarm = alarm.copyWith(
        notificationIds: await notifications.schedule(alarm),
      );
      scheduled = alarm.notificationIds.isNotEmpty;
    } catch (_) {
      scheduled = false;
    }
    if (!mounted) return;
    setState(() {
      alarms = [...alarms.where((item) => item.id != related?.id), alarm]
        ..sort((a, b) => a.dateTime.compareTo(b.dateTime));
      page = 0;
    });
    await storage.saveAlarms(alarms);
    if (mounted && !partOfSeries) {
      notice(
        scheduled
            ? '${draft.label} · ${DateFormat('EEE, h:mm a').format(draft.dateTime)}'
            : 'Alarm saved, but notifications are disabled. Allow them in Android settings.',
      );
    }
  }

  Future<void> toggleAlarm(AlarmItem alarm) async {
    final index = alarms.indexWhere((item) => item.id == alarm.id);
    if (index < 0) return;
    var changed = alarm.copyWith(enabled: !alarm.enabled);
    if (changed.enabled) {
      changed = changed.copyWith(completionStatus: 'pending');
      try {
        changed = changed.copyWith(
          notificationIds: await notifications.schedule(changed),
        );
      } catch (_) {}
    } else {
      await notifications.cancelAlarm(alarm);
      changed = changed.copyWith(completionStatus: 'dismissed');
    }
    setState(() => alarms[index] = changed);
    await storage.saveAlarms(alarms);
  }

  Future<void> editAlarm(AlarmItem alarm) async {
    final labelController = TextEditingController(text: alarm.label);
    var selectedDate = alarm.dateTime;
    var selectedRepeat = alarm.repeat;
    String? validation;
    final draft = await showDialog<AlarmDraft>(
      context: context,
      builder: (dialogContext) => StatefulBuilder(
        builder: (context, setDialogState) => AlertDialog(
          title: const Text('Edit alarm'),
          content: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                TextField(
                  controller: labelController,
                  textCapitalization: TextCapitalization.sentences,
                  decoration: const InputDecoration(labelText: 'Alarm name'),
                ),
                const SizedBox(height: 14),
                ListTile(
                  contentPadding: EdgeInsets.zero,
                  leading: const Icon(Icons.calendar_today_outlined),
                  title: Text(DateFormat('EEE, MMM d').format(selectedDate)),
                  onTap: () async {
                    final picked = await showDatePicker(
                      context: dialogContext,
                      initialDate: selectedDate,
                      firstDate: DateTime.now(),
                      lastDate: DateTime.now().add(const Duration(days: 730)),
                    );
                    if (picked != null) {
                      setDialogState(() {
                        selectedDate = DateTime(
                          picked.year,
                          picked.month,
                          picked.day,
                          selectedDate.hour,
                          selectedDate.minute,
                        );
                      });
                    }
                  },
                ),
                ListTile(
                  contentPadding: EdgeInsets.zero,
                  leading: const Icon(Icons.schedule),
                  title: Text(DateFormat('h:mm a').format(selectedDate)),
                  onTap: () async {
                    final picked = await showTimePicker(
                      context: dialogContext,
                      initialTime: TimeOfDay.fromDateTime(selectedDate),
                    );
                    if (picked != null) {
                      setDialogState(() {
                        selectedDate = DateTime(
                          selectedDate.year,
                          selectedDate.month,
                          selectedDate.day,
                          picked.hour,
                          picked.minute,
                        );
                      });
                    }
                  },
                ),
                DropdownButtonFormField<String>(
                  initialValue: selectedRepeat,
                  decoration: const InputDecoration(labelText: 'Repeat'),
                  items: const [
                    DropdownMenuItem(value: 'once', child: Text('Once')),
                    DropdownMenuItem(value: 'daily', child: Text('Every day')),
                    DropdownMenuItem(
                      value: 'weekdays',
                      child: Text('Weekdays'),
                    ),
                    DropdownMenuItem(
                      value: 'weekends',
                      child: Text('Weekends'),
                    ),
                  ],
                  onChanged: (value) {
                    if (value != null) {
                      setDialogState(() => selectedRepeat = value);
                    }
                  },
                ),
                if (validation != null) ...[
                  const SizedBox(height: 10),
                  Text(validation!, style: const TextStyle(color: coral)),
                ],
              ],
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(dialogContext),
              child: const Text('Cancel'),
            ),
            FilledButton(
              onPressed: () {
                if (selectedRepeat == 'once' &&
                    !selectedDate.isAfter(DateTime.now())) {
                  setDialogState(
                    () => validation = 'Choose a future date and time.',
                  );
                  return;
                }
                Navigator.pop(
                  dialogContext,
                  AlarmDraft(
                    label: labelController.text.trim().isEmpty
                        ? 'Alarm'
                        : labelController.text.trim(),
                    dateTime: selectedDate,
                    repeat: selectedRepeat,
                  ),
                );
              },
              child: const Text('Save'),
            ),
          ],
        ),
      ),
    );
    labelController.dispose();
    if (draft == null) return;
    final index = alarms.indexWhere((item) => item.id == alarm.id);
    if (index < 0) return;
    await notifications.cancelAlarm(alarm);
    var changed = alarm.copyWith(
      label: draft.label,
      dateTime: draft.dateTime,
      repeat: draft.repeat,
      enabled: true,
      completionStatus: 'pending',
      notificationIds: const [],
    );
    try {
      changed = changed.copyWith(
        notificationIds: await notifications.schedule(changed),
      );
    } catch (_) {}
    if (!mounted) return;
    setState(() {
      alarms[index] = changed;
      alarms.sort((a, b) => a.dateTime.compareTo(b.dateTime));
    });
    await storage.saveAlarms(alarms);
    if (mounted) notice('Alarm updated and rescheduled.');
  }

  Future<void> deleteAlarm(AlarmItem alarm) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Delete alarm?'),
        content: Text('Delete "${alarm.label}" and cancel its notifications?'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Keep'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Delete'),
          ),
        ],
      ),
    );
    if (confirmed != true) return;
    await notifications.cancelAlarm(alarm);
    if (!mounted) return;
    setState(() => alarms.removeWhere((item) => item.id == alarm.id));
    await storage.saveAlarms(alarms);
  }

  Future<void> acknowledgeAlarm(AlarmItem alarm) async {
    final index = alarms.indexWhere((item) => item.id == alarm.id);
    if (index < 0) return;
    await notifications.completeAlarm(alarm);
    final changed = alarm.copyWith(
      enabled: false,
      completionStatus: 'completed',
      completedAt: DateTime.now(),
    );
    if (!mounted) return;
    setState(() => alarms[index] = changed);
    await storage.saveAlarms(alarms);
    final profile = await storage.learnFromCompletion(alarm);
    ai.setLocalPreferences(
      preparationMinutes: profile.preparationMinutes,
      snoozeMinutes: profile.snoozeIntervalMinutes,
    );
    if (mounted) notice("You're awake · remaining alarms cancelled");
  }

  AlarmItem? activeWakePlan() {
    final now = DateTime.now();
    for (final alarm in alarms.where(
      (item) => item.enabled && item.isWakePlan,
    )) {
      var target = alarm.dateTime;
      if (alarm.repeat != 'once') {
        target = DateTime(
          now.year,
          now.month,
          now.day,
          target.hour,
          target.minute,
        );
        final validToday =
            alarm.repeat == 'daily' ||
            (alarm.repeat == 'weekdays' && now.weekday <= DateTime.friday) ||
            (alarm.repeat == 'weekends' && now.weekday >= DateTime.saturday);
        if (!validToday) continue;
      }
      final first = target.subtract(
        Duration(
          minutes: alarm.alertOffsetsMinutes.reduce((a, b) => a > b ? a : b),
        ),
      );
      if (!now.isBefore(first) &&
          now.isBefore(target.add(const Duration(minutes: 10)))) {
        return alarm;
      }
    }
    return null;
  }

  Future<void> confirmIfAwake() async {
    if (!mounted || awakePromptOpen) return;
    final alarm = activeWakePlan();
    if (alarm == null) return;
    awakePromptOpen = true;
    final awake = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Are you awake?'),
        content: Text(
          'You are using your phone during the ${alarm.label} wake-up window. Cancel the remaining alarms?',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Keep alarms'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text("I'm awake"),
          ),
        ],
      ),
    );
    awakePromptOpen = false;
    if (awake == true) await acknowledgeAlarm(alarm);
  }

  void notice(String message) {
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(
        SnackBar(
          content: Text(message),
          backgroundColor: ink,
          behavior: SnackBarBehavior.floating,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(14),
          ),
        ),
      );
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    body: SafeArea(
      bottom: false,
      child: loading
          ? const Center(child: CircularProgressIndicator(color: coral))
          : IndexedStack(
              index: page,
              children: [
                ManualScreen(
                  alarms: alarms,
                  onCreate: (d) => addAlarm(d, fromAi: false),
                  onToggle: toggleAlarm,
                  onEdit: editAlarm,
                  onDelete: deleteAlarm,
                  onAwake: acknowledgeAlarm,
                  usageAccessGranted: usageAccessGranted,
                  onEnableUsageAccess: enableUsageAccess,
                ),
                PromptScreen(
                  key: promptKey,
                  ai: ai,
                  onCreate: (d) => addAlarm(d, fromAi: true),
                ),
              ],
            ),
    ),
    bottomNavigationBar: NavigationBar(
      height: 72,
      selectedIndex: page,
      backgroundColor: cream,
      indicatorColor: mint,
      onDestinationSelected: (value) => setState(() => page = value),
      destinations: const [
        NavigationDestination(
          icon: Icon(Icons.alarm_outlined),
          selectedIcon: Icon(Icons.alarm, color: ink),
          label: 'Manual',
        ),
        NavigationDestination(
          icon: Icon(Icons.auto_awesome_outlined),
          selectedIcon: Icon(Icons.auto_awesome, color: ink),
          label: 'Ask Gante',
        ),
      ],
    ),
  );
}

class ManualScreen extends StatefulWidget {
  const ManualScreen({
    super.key,
    required this.alarms,
    required this.onCreate,
    required this.onToggle,
    required this.onEdit,
    required this.onDelete,
    required this.onAwake,
    required this.usageAccessGranted,
    required this.onEnableUsageAccess,
  });
  final List<AlarmItem> alarms;
  final Future<void> Function(AlarmDraft) onCreate;
  final Future<void> Function(AlarmItem) onToggle;
  final Future<void> Function(AlarmItem) onEdit;
  final Future<void> Function(AlarmItem) onDelete;
  final Future<void> Function(AlarmItem) onAwake;
  final bool usageAccessGranted;
  final Future<void> Function() onEnableUsageAccess;
  @override
  State<ManualScreen> createState() => _ManualScreenState();
}

class _ManualScreenState extends State<ManualScreen> {
  final label = TextEditingController();
  final upcomingKey = GlobalKey();
  TimeOfDay time = const TimeOfDay(hour: 7, minute: 30);
  String repeat = 'once';
  bool saving = false;
  @override
  void dispose() {
    label.dispose();
    super.dispose();
  }

  Future<void> pickTime() async {
    final selected = await showTimePicker(context: context, initialTime: time);
    if (selected != null) setState(() => time = selected);
  }

  Future<void> submit() async {
    if (saving) return;
    setState(() => saving = true);
    final now = DateTime.now();
    var date = DateTime(now.year, now.month, now.day, time.hour, time.minute);
    if (!date.isAfter(now)) date = date.add(const Duration(days: 1));
    if (repeat == 'weekdays') {
      while (date.weekday > DateTime.friday) {
        date = date.add(const Duration(days: 1));
      }
    }
    try {
      await widget.onCreate(
        AlarmDraft(
          label: label.text.trim().isEmpty ? 'Alarm' : label.text.trim(),
          dateTime: date,
          repeat: repeat,
        ),
      );
      label.clear();
      WidgetsBinding.instance.addPostFrameCallback((_) {
        final target = upcomingKey.currentContext;
        if (target != null) {
          Scrollable.ensureVisible(
            target,
            duration: const Duration(milliseconds: 450),
            curve: Curves.easeOutCubic,
          );
        }
      });
    } finally {
      if (mounted) setState(() => saving = false);
    }
  }

  @override
  Widget build(BuildContext context) => CustomScrollView(
    slivers: [
      SliverToBoxAdapter(
        child: PageHeader(
          eyebrow: 'GOOD ${greeting()}',
          title: 'Your time,\nbeautifully managed.',
          trailing: DateBadge(date: DateTime.now()),
        ),
      ),
      SliverPadding(
        padding: const EdgeInsets.fromLTRB(20, 0, 20, 16),
        sliver: SliverToBoxAdapter(
          child: InfoBox(
            icon: widget.usageAccessGranted
                ? Icons.auto_awesome
                : Icons.phone_android,
            color: widget.usageAccessGranted ? const Color(0xFF4F936B) : coral,
            child: Row(
              children: [
                Expanded(
                  child: Text(
                    widget.usageAccessGranted
                        ? 'Adaptive activity is on. Early stages are skipped when you are already active.'
                        : 'Enable adaptive activity to suppress early alarm stages when you are using your phone.',
                    style: const TextStyle(color: ink, fontSize: 12),
                  ),
                ),
                if (!widget.usageAccessGranted)
                  TextButton(
                    onPressed: widget.onEnableUsageAccess,
                    child: const Text('ENABLE'),
                  ),
              ],
            ),
          ),
        ),
      ),
      SliverPadding(
        padding: const EdgeInsets.fromLTRB(20, 0, 20, 28),
        sliver: SliverToBoxAdapter(
          child: CreatorCard(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const SectionHeading(number: '01', title: 'Choose your moment'),
                const SizedBox(height: 26),
                Center(
                  child: InkWell(
                    onTap: pickTime,
                    borderRadius: BorderRadius.circular(18),
                    child: Padding(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 18,
                        vertical: 10,
                      ),
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        crossAxisAlignment: CrossAxisAlignment.end,
                        children: [
                          Text(
                            time.format(context),
                            style: const TextStyle(
                              color: ink,
                              fontSize: 55,
                              fontWeight: FontWeight.w600,
                              letterSpacing: -2.5,
                            ),
                          ),
                          const Padding(
                            padding: EdgeInsets.only(left: 9, bottom: 9),
                            child: Icon(
                              Icons.edit_outlined,
                              size: 18,
                              color: coral,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
                const SizedBox(height: 24),
                TextField(
                  controller: label,
                  textCapitalization: TextCapitalization.sentences,
                  decoration: const InputDecoration(
                    labelText: 'ALARM NAME',
                    hintText: 'Morning walk',
                  ),
                ),
                const SizedBox(height: 16),
                const Text('REPEAT', style: smallLabel),
                const SizedBox(height: 9),
                Wrap(
                  spacing: 8,
                  runSpacing: 8,
                  children:
                      {
                            'once': 'Once',
                            'daily': 'Every day',
                            'weekdays': 'Weekdays',
                            'weekends': 'Weekends',
                          }.entries
                          .map(
                            (option) => ChoiceChip(
                              label: Text(option.value),
                              selected: repeat == option.key,
                              onSelected: (_) =>
                                  setState(() => repeat = option.key),
                              selectedColor: ink,
                              labelStyle: TextStyle(
                                color: repeat == option.key
                                    ? Colors.white
                                    : muted,
                                fontWeight: FontWeight.w600,
                                fontSize: 12,
                              ),
                              side: BorderSide.none,
                              backgroundColor: paper,
                            ),
                          )
                          .toList(),
                ),
                const SizedBox(height: 22),
                PrimaryButton(
                  label: 'Set alarm',
                  icon: Icons.arrow_forward,
                  busy: saving,
                  onPressed: submit,
                ),
              ],
            ),
          ),
        ),
      ),
      SliverPadding(
        padding: const EdgeInsets.fromLTRB(20, 12, 20, 12),
        sliver: SliverToBoxAdapter(
          child: Row(
            key: upcomingKey,
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            crossAxisAlignment: CrossAxisAlignment.end,
            children: [
              const Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text('YOUR DAY', style: smallLabel),
                  SizedBox(height: 4),
                  Text(
                    'Upcoming alarms',
                    style: TextStyle(
                      color: ink,
                      fontSize: 24,
                      fontWeight: FontWeight.w700,
                      letterSpacing: -.6,
                    ),
                  ),
                ],
              ),
              Text(
                '${widget.alarms.length} alarms',
                style: const TextStyle(color: muted, fontSize: 12),
              ),
            ],
          ),
        ),
      ),
      if (widget.alarms.isEmpty)
        const SliverPadding(
          padding: EdgeInsets.fromLTRB(20, 12, 20, 60),
          sliver: SliverToBoxAdapter(child: EmptyAlarms()),
        )
      else
        SliverPadding(
          padding: const EdgeInsets.fromLTRB(20, 8, 20, 60),
          sliver: SliverList.separated(
            itemCount: widget.alarms.length,
            separatorBuilder: (_, _) => const SizedBox(height: 10),
            itemBuilder: (_, index) {
              final alarm = widget.alarms[index];
              return AlarmTile(
                alarm: alarm,
                onToggle: () => widget.onToggle(alarm),
                onEdit: () => widget.onEdit(alarm),
                onDelete: () => widget.onDelete(alarm),
                onAwake: () => widget.onAwake(alarm),
              );
            },
          ),
        ),
    ],
  );
}

class PromptScreen extends StatefulWidget {
  const PromptScreen({super.key, required this.ai, required this.onCreate});
  final LocalAiService ai;
  final Future<void> Function(AlarmDraft) onCreate;
  @override
  State<PromptScreen> createState() => _PromptScreenState();
}

class _PromptScreenState extends State<PromptScreen> {
  final prompt = TextEditingController();
  final speech = stt.SpeechToText();
  AlarmDraft? draft;
  bool working = false;
  bool listening = false;
  bool sharedFromApp = false;
  DateTime? selectedSharedTime;
  int? modelProgress;
  String? error;

  Future<void> toggleVoiceInput() async {
    if (listening) {
      await speech.stop();
      if (mounted) setState(() => listening = false);
      return;
    }
    final available = await speech.initialize(
      onStatus: (status) {
        if (status == 'notListening' && mounted) {
          setState(() => listening = false);
        }
      },
      onError: (speechError) {
        if (mounted) {
          setState(() {
            listening = false;
            error = speechError.errorMsg;
          });
        }
      },
    );
    if (!available || !mounted) {
      if (mounted) {
        setState(() => error = 'Voice input is unavailable on this device.');
      }
      return;
    }
    setState(() {
      listening = true;
      draft = null;
      error = null;
    });
    await speech.listen(
      onResult: (result) {
        if (!mounted) return;
        setState(() {
          prompt.text = result.recognizedWords;
          prompt.selection = TextSelection.collapsed(offset: prompt.text.length);
          draft = null;
          error = null;
        });
      },
      listenFor: const Duration(minutes: 1),
      pauseFor: const Duration(seconds: 4),
      partialResults: true,
      cancelOnError: true,
      listenMode: stt.ListenMode.dictation,
    );
  }

  void acceptSharedText(String text) {
    if (!mounted) return;
    prompt.text = text;
    prompt.selection = TextSelection.collapsed(offset: prompt.text.length);
    setState(() {
      sharedFromApp = true;
      selectedSharedTime = null;
      draft = null;
      error = null;
    });
  }

  Future<void> chooseSharedReminderTime() async {
    final now = DateTime.now();
    final selectedDate = await showDatePicker(
      context: context,
      initialDate: now,
      firstDate: DateTime(now.year, now.month, now.day),
      lastDate: DateTime(now.year + 2, 12, 31),
    );
    if (selectedDate == null || !mounted) return;
    final selectedTime = await showTimePicker(
      context: context,
      initialTime: TimeOfDay.fromDateTime(now.add(const Duration(hours: 1))),
    );
    if (selectedTime == null || !mounted) return;
    final selected = DateTime(
      selectedDate.year,
      selectedDate.month,
      selectedDate.day,
      selectedTime.hour,
      selectedTime.minute,
    );
    if (!selected.isAfter(DateTime.now())) {
      setState(() => error = 'Choose a reminder time in the future.');
      return;
    }
    selectedSharedTime = selected;
    final original = prompt.text.trim();
    prompt.text =
        '$original\nCreate a reminder for this at ${selected.toIso8601String()}.';
    prompt.selection = TextSelection.collapsed(offset: prompt.text.length);
    await understand();
  }

  AlarmDraft applySelectedTime(AlarmDraft result) {
    final selected = selectedSharedTime;
    if (selected == null) return result;
    return AlarmDraft(
      label: result.label,
      dateTime: selected,
      repeat: result.repeat,
      explanation: '${result.explanation} Time selected by you.',
      wakeStyle: result.wakeStyle,
      preparationMinutes: result.preparationMinutes,
      alertOffsetsMinutes: result.alertOffsetsMinutes,
      snoozeIntervalMinutes: result.snoozeIntervalMinutes,
    );
  }

  @override
  void dispose() {
    speech.stop();
    prompt.dispose();
    super.dispose();
  }

  Future<void> understand() async {
    if (prompt.text.trim().isEmpty) return;
    setState(() {
      working = true;
      error = null;
      draft = null;
    });
    try {
      final result = applySelectedTime(
        await widget.ai.interpret(
          prompt.text,
          onProgress: (progress) {
            if (mounted) setState(() => modelProgress = progress);
          },
        ),
      );
      if (mounted) setState(() => draft = result);
    } on FormatException catch (e) {
      if (mounted) setState(() => error = e.message);
    } catch (_) {
      try {
        final result = applySelectedTime(PromptParser.parse(prompt.text));
        if (mounted) setState(() => draft = result);
      } on FormatException catch (e) {
        if (mounted) setState(() => error = e.message);
      }
    } finally {
      if (mounted) {
        setState(() {
          working = false;
          modelProgress = null;
        });
      }
    }
  }

  Future<void> confirm() async {
    if (draft == null) return;
    await widget.onCreate(draft!);
    prompt.clear();
    setState(() {
      draft = null;
      sharedFromApp = false;
      selectedSharedTime = null;
    });
  }

  @override
  Widget build(BuildContext context) => ListView(
    padding: EdgeInsets.zero,
    children: [
      const PageHeader(
        eyebrow: 'PRIVATE · ON DEVICE',
        title: 'Tell Gante\nwhat you need.',
        trailing: AiOrb(),
      ),
      Padding(
        padding: const EdgeInsets.fromLTRB(20, 0, 20, 28),
        child: CreatorCard(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  const Expanded(
                    child: SectionHeading(
                      number: '02',
                      title: 'Describe your plan',
                    ),
                  ),
                  StatusPill(ready: widget.ai.isReady),
                ],
              ),
              const SizedBox(height: 24),
              TextField(
                controller: prompt,
                maxLines: 5,
                minLines: 4,
                textCapitalization: TextCapitalization.sentences,
                onChanged: (_) => setState(() {
                  draft = null;
                  error = null;
                }),
                style: const TextStyle(
                  color: ink,
                  fontSize: 18,
                  height: 1.5,
                  fontWeight: FontWeight.w500,
                ),
                decoration: const InputDecoration(
                  hintText:
                      'I need to go walking tomorrow at 6:30 in the morning…',
                ),
              ),
              Align(
                alignment: Alignment.centerRight,
                child: IconButton.filledTonal(
                  onPressed: working ? null : toggleVoiceInput,
                  tooltip: listening ? 'Stop voice input' : 'Use voice input',
                  icon: Icon(
                    listening ? Icons.stop_rounded : Icons.mic_none_rounded,
                  ),
                  style: IconButton.styleFrom(
                    foregroundColor: listening ? cream : ink,
                    backgroundColor: listening ? coral : mint,
                  ),
                ),
              ),
              if (sharedFromApp) ...[
                const SizedBox(height: 12),
                InfoBox(
                  icon: Icons.ios_share,
                  color: coral,
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      const Text('SHARED FROM ANOTHER APP', style: smallLabel),
                      const SizedBox(height: 5),
                      const Text(
                        'Gante keeps this text on your phone. Choose when you want to be reminded.',
                        style: TextStyle(color: muted, fontSize: 11),
                      ),
                      const SizedBox(height: 9),
                      OutlinedButton.icon(
                        onPressed: working ? null : chooseSharedReminderTime,
                        icon: const Icon(Icons.event_outlined, size: 17),
                        label: const Text('Choose date and time'),
                      ),
                    ],
                  ),
                ),
              ],
              const SizedBox(height: 12),
              Wrap(
                spacing: 7,
                runSpacing: 7,
                children:
                    [
                          'Wake me in 20 minutes',
                          'Gym every weekday at 6 AM',
                          'Call mom tomorrow at 7 PM',
                        ]
                        .map(
                          (text) => ActionChip(
                            label: Text(text),
                            onPressed: () {
                              prompt.text = text;
                              setState(() {
                                draft = null;
                                error = null;
                              });
                            },
                            labelStyle: const TextStyle(
                              color: muted,
                              fontSize: 11,
                            ),
                            side: const BorderSide(color: Color(0xFFDEDBD2)),
                            backgroundColor: cream,
                          ),
                        )
                        .toList(),
              ),
              if (working) ...[
                const SizedBox(height: 20),
                LinearProgressIndicator(
                  value: modelProgress == null ? null : modelProgress! / 100,
                  color: coral,
                  backgroundColor: mint,
                  borderRadius: BorderRadius.circular(5),
                ),
                const SizedBox(height: 9),
                Text(
                  modelProgress == null
                      ? 'SmolLM2 is understanding your request…'
                      : 'Preparing private AI · $modelProgress%',
                  style: const TextStyle(color: muted, fontSize: 11),
                ),
              ],
              if (error != null) ...[
                const SizedBox(height: 18),
                InfoBox(
                  icon: Icons.info_outline,
                  color: coral,
                  child: Text(
                    error!,
                    style: const TextStyle(color: ink, fontSize: 13),
                  ),
                ),
              ],
              if (draft != null) ...[
                const SizedBox(height: 18),
                AlarmPreview(draft: draft!),
              ],
              const SizedBox(height: 20),
              PrimaryButton(
                label: draft == null
                    ? 'Understand my request'
                    : 'Set this alarm',
                icon: draft == null ? Icons.auto_awesome : Icons.check,
                dark: true,
                busy: working,
                onPressed: draft == null ? understand : confirm,
              ),
              const SizedBox(height: 14),
              const Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Icon(Icons.lock_outline, color: muted, size: 13),
                  SizedBox(width: 5),
                  Flexible(
                    child: Text(
                      'No API. No cloud. Your words stay on this phone.',
                      textAlign: TextAlign.center,
                      style: TextStyle(color: muted, fontSize: 10),
                    ),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
      const Padding(
        padding: EdgeInsets.fromLTRB(26, 8, 26, 60),
        child: InfoBox(
          icon: Icons.memory,
          color: ink,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text('SMALL MODEL, FULL PRIVACY', style: smallLabel),
              SizedBox(height: 5),
              Text(
                'SmolLM2 135M runs inside Gante. Alarm details are cached only in device storage.',
                style: TextStyle(color: muted, fontSize: 12, height: 1.5),
              ),
            ],
          ),
        ),
      ),
    ],
  );
}

class PageHeader extends StatelessWidget {
  const PageHeader({
    super.key,
    required this.eyebrow,
    required this.title,
    required this.trailing,
  });
  final String eyebrow;
  final String title;
  final Widget trailing;
  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.fromLTRB(24, 26, 24, 34),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            Row(
              children: [
                Container(
                  width: 40,
                  height: 40,
                  decoration: BoxDecoration(
                    color: cream,
                    borderRadius: BorderRadius.circular(20),
                    border: Border.all(color: const Color(0xFFDEDBD2)),
                  ),
                  child: const Icon(
                    Icons.notifications_active_outlined,
                    color: coral,
                    size: 20,
                  ),
                ),
                const SizedBox(width: 11),
                const Text(
                  'Gante',
                  style: TextStyle(
                    color: ink,
                    fontSize: 21,
                    fontWeight: FontWeight.w800,
                    letterSpacing: -.5,
                  ),
                ),
              ],
            ),
            trailing,
          ],
        ),
        const SizedBox(height: 38),
        Text(eyebrow, style: smallLabel.copyWith(color: coral)),
        const SizedBox(height: 10),
        Text(title, style: Theme.of(context).textTheme.displaySmall),
      ],
    ),
  );
}

class CreatorCard extends StatelessWidget {
  const CreatorCard({super.key, required this.child});
  final Widget child;
  @override
  Widget build(BuildContext context) => Container(
    padding: const EdgeInsets.all(22),
    decoration: BoxDecoration(
      color: cream,
      borderRadius: BorderRadius.circular(24),
      border: Border.all(color: const Color(0x1F18352E)),
      boxShadow: const [
        BoxShadow(
          color: Color(0x1218372E),
          blurRadius: 30,
          offset: Offset(0, 12),
        ),
      ],
    ),
    child: child,
  );
}

class SectionHeading extends StatelessWidget {
  const SectionHeading({super.key, required this.number, required this.title});
  final String number;
  final String title;
  @override
  Widget build(BuildContext context) => Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      Text('$number / CREATE ALARM', style: smallLabel.copyWith(color: coral)),
      const SizedBox(height: 5),
      Text(title, style: Theme.of(context).textTheme.headlineSmall),
    ],
  );
}

class PrimaryButton extends StatelessWidget {
  const PrimaryButton({
    super.key,
    required this.label,
    required this.icon,
    required this.onPressed,
    this.dark = false,
    this.busy = false,
  });
  final String label;
  final IconData icon;
  final VoidCallback onPressed;
  final bool dark;
  final bool busy;
  @override
  Widget build(BuildContext context) => SizedBox(
    width: double.infinity,
    height: 55,
    child: FilledButton(
      onPressed: busy ? null : onPressed,
      style: FilledButton.styleFrom(
        backgroundColor: dark ? ink : coral,
        disabledBackgroundColor: (dark ? ink : coral).withValues(alpha: .55),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(15)),
        padding: const EdgeInsets.symmetric(horizontal: 19),
      ),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          Text(label, style: const TextStyle(fontWeight: FontWeight.w700)),
          busy
              ? const SizedBox(
                  width: 20,
                  height: 20,
                  child: CircularProgressIndicator(
                    strokeWidth: 2,
                    color: Colors.white,
                  ),
                )
              : Icon(icon, size: 19),
        ],
      ),
    ),
  );
}

class AlarmTile extends StatelessWidget {
  const AlarmTile({
    super.key,
    required this.alarm,
    required this.onToggle,
    required this.onEdit,
    required this.onDelete,
    required this.onAwake,
  });
  final AlarmItem alarm;
  final VoidCallback onToggle;
  final VoidCallback onEdit;
  final VoidCallback onDelete;
  final VoidCallback onAwake;
  String repeatLabel() => switch (alarm.repeat) {
    'daily' => 'Every day',
    'weekdays' => 'Every weekday',
    'weekends' => 'Every weekend',
    _ => DateFormat('EEE, MMM d').format(alarm.dateTime),
  };
  @override
  Widget build(BuildContext context) => Dismissible(
    key: ValueKey(alarm.id),
    direction: DismissDirection.none,
    onDismissed: (_) => onDelete(),
    background: Container(
      alignment: Alignment.centerRight,
      padding: const EdgeInsets.only(right: 24),
      decoration: BoxDecoration(
        color: coral,
        borderRadius: BorderRadius.circular(17),
      ),
      child: const Icon(Icons.delete_outline, color: Colors.white),
    ),
    child: Container(
      padding: const EdgeInsets.fromLTRB(0, 15, 12, 15),
      decoration: BoxDecoration(
        color: cream,
        borderRadius: BorderRadius.circular(17),
        border: Border.all(color: const Color(0xFFDEDBD2)),
      ),
      child: Column(
        children: [
          Row(
            children: [
              Container(
                width: 5,
                height: 55,
                decoration: const BoxDecoration(
                  color: coral,
                  borderRadius: BorderRadius.horizontal(
                    right: Radius.circular(5),
                  ),
                ),
              ),
              const SizedBox(width: 14),
              SizedBox(
                width: 82,
                child: Text(
                  DateFormat('h:mm\na').format(alarm.dateTime),
                  style: TextStyle(
                    color: alarm.enabled ? ink : muted,
                    fontSize: 23,
                    height: .9,
                    fontWeight: FontWeight.w700,
                    letterSpacing: -.8,
                  ),
                ),
              ),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Flexible(
                          child: Text(
                            alarm.label,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(
                              color: ink,
                              fontWeight: FontWeight.w700,
                            ),
                          ),
                        ),
                        if (alarm.createdWithAi) ...[
                          const SizedBox(width: 5),
                          const Icon(
                            Icons.auto_awesome,
                            color: coral,
                            size: 12,
                          ),
                        ],
                      ],
                    ),
                    const SizedBox(height: 4),
                    Text(
                      repeatLabel(),
                      style: const TextStyle(color: muted, fontSize: 10),
                    ),
                    if (alarm.completionStatus != 'pending')
                      Text(
                        alarm.completionStatus == 'completed'
                            ? 'Intent completed'
                            : 'Alarm dismissed',
                        style: TextStyle(
                          color: alarm.completionStatus == 'completed'
                              ? const Color(0xFF4F936B)
                              : muted,
                          fontSize: 10,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                  ],
                ),
              ),
              Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Switch(
                    value: alarm.enabled,
                    onChanged: (_) => onToggle(),
                    activeTrackColor: ink,
                    activeThumbColor: Colors.white,
                  ),
                  PopupMenuButton<String>(
                    tooltip: 'Edit or delete alarm',
                    padding: EdgeInsets.zero,
                    icon: const Icon(Icons.more_horiz, color: muted),
                    onSelected: (action) {
                      if (action == 'edit') onEdit();
                      if (action == 'delete') onDelete();
                    },
                    itemBuilder: (_) => const [
                      PopupMenuItem(
                        value: 'edit',
                        child: ListTile(
                          contentPadding: EdgeInsets.zero,
                          leading: Icon(Icons.edit_outlined),
                          title: Text('Edit'),
                        ),
                      ),
                      PopupMenuItem(
                        value: 'delete',
                        child: ListTile(
                          contentPadding: EdgeInsets.zero,
                          leading: Icon(Icons.delete_outline, color: coral),
                          title: Text('Delete'),
                        ),
                      ),
                    ],
                  ),
                ],
              ),
            ],
          ),
          if (alarm.isWakePlan && alarm.enabled) ...[
            const Divider(height: 18, indent: 19),
            Padding(
              padding: const EdgeInsets.only(left: 19),
              child: Row(
                children: [
                  Expanded(
                    child: Text(
                      '${alarm.alertOffsetsMinutes.length} stages · ${alarm.wakeStyle} · ${alarm.preparationMinutes} min prep',
                      style: const TextStyle(color: muted, fontSize: 10),
                    ),
                  ),
                  TextButton.icon(
                    onPressed: onAwake,
                    icon: const Icon(Icons.wb_sunny_outlined, size: 15),
                    label: const Text("I'm awake"),
                  ),
                ],
              ),
            ),
          ],
        ],
      ),
    ),
  );
}

class AlarmPreview extends StatelessWidget {
  const AlarmPreview({super.key, required this.draft});
  final AlarmDraft draft;
  @override
  Widget build(BuildContext context) => InfoBox(
    icon: Icons.check,
    color: ink,
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Text('I UNDERSTAND', style: smallLabel),
        const SizedBox(height: 5),
        Text(
          draft.label,
          style: const TextStyle(
            color: ink,
            fontSize: 17,
            fontWeight: FontWeight.w700,
          ),
        ),
        const SizedBox(height: 3),
        Text(
          '${DateFormat('EEEE, MMM d · h:mm a').format(draft.dateTime)} · ${draft.repeat}',
          style: const TextStyle(color: muted, fontSize: 12),
        ),
        if (draft.additionalDateTimes.isNotEmpty) ...[
          const SizedBox(height: 6),
          Text(
            <DateTime>[
              draft.dateTime,
              ...draft.additionalDateTimes,
            ].map((date) => DateFormat('h:mm a').format(date)).join('  ->  '),
            style: const TextStyle(
              color: ink,
              fontSize: 11,
              fontWeight: FontWeight.w700,
            ),
          ),
        ],
        if (draft.isWakePlan) ...[
          const SizedBox(height: 7),
          Text(
            '${draft.wakeStyle.toUpperCase()} WAKE PLAN · ${draft.preparationMinutes} MIN PREP',
            style: smallLabel.copyWith(color: coral),
          ),
          const SizedBox(height: 4),
          Text(
            draft.alertOffsetsMinutes
                .map(
                  (offset) => DateFormat(
                    'h:mm a',
                  ).format(draft.dateTime.subtract(Duration(minutes: offset))),
                )
                .join('  →  '),
            style: const TextStyle(color: ink, fontSize: 11),
          ),
        ],
        const SizedBox(height: 3),
        Text(
          draft.explanation,
          style: const TextStyle(color: muted, fontSize: 10),
        ),
      ],
    ),
  );
}

class InfoBox extends StatelessWidget {
  const InfoBox({
    super.key,
    required this.icon,
    required this.color,
    required this.child,
  });
  final IconData icon;
  final Color color;
  final Widget child;
  @override
  Widget build(BuildContext context) => Container(
    padding: const EdgeInsets.all(14),
    decoration: BoxDecoration(
      color: mint.withValues(alpha: .65),
      borderRadius: BorderRadius.circular(15),
      border: Border.all(color: const Color(0xFFCDDFD2)),
    ),
    child: Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Container(
          width: 30,
          height: 30,
          decoration: BoxDecoration(color: color, shape: BoxShape.circle),
          child: Icon(icon, color: Colors.white, size: 15),
        ),
        const SizedBox(width: 12),
        Expanded(child: child),
      ],
    ),
  );
}

class DateBadge extends StatelessWidget {
  const DateBadge({super.key, required this.date});
  final DateTime date;
  @override
  Widget build(BuildContext context) => Container(
    width: 60,
    height: 60,
    decoration: const BoxDecoration(color: ink, shape: BoxShape.circle),
    child: Column(
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        Text(
          DateFormat('MMM').format(date).toUpperCase(),
          style: const TextStyle(
            color: Colors.white70,
            fontSize: 8,
            letterSpacing: 1.3,
          ),
        ),
        Text(
          '${date.day}',
          style: const TextStyle(
            color: Colors.white,
            fontSize: 22,
            height: 1.05,
            fontWeight: FontWeight.w600,
          ),
        ),
      ],
    ),
  );
}

class AiOrb extends StatelessWidget {
  const AiOrb({super.key});
  @override
  Widget build(BuildContext context) => Container(
    width: 60,
    height: 60,
    decoration: const BoxDecoration(color: ink, shape: BoxShape.circle),
    child: const Icon(Icons.auto_awesome, color: coral, size: 25),
  );
}

class StatusPill extends StatelessWidget {
  const StatusPill({super.key, required this.ready});
  final bool ready;
  @override
  Widget build(BuildContext context) => Container(
    padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 7),
    decoration: BoxDecoration(
      color: mint,
      borderRadius: BorderRadius.circular(20),
    ),
    child: Row(
      children: [
        Container(
          width: 6,
          height: 6,
          decoration: BoxDecoration(
            color: ready ? const Color(0xFF4F936B) : coral,
            shape: BoxShape.circle,
          ),
        ),
        const SizedBox(width: 5),
        Text(
          ready ? 'AI READY' : 'LOCAL AI',
          style: const TextStyle(
            color: ink,
            fontSize: 8,
            fontWeight: FontWeight.w800,
            letterSpacing: .7,
          ),
        ),
      ],
    ),
  );
}

class EmptyAlarms extends StatelessWidget {
  const EmptyAlarms({super.key});
  @override
  Widget build(BuildContext context) => Container(
    padding: const EdgeInsets.all(32),
    decoration: BoxDecoration(
      border: Border.all(color: const Color(0xFFC9CBC4)),
      borderRadius: BorderRadius.circular(17),
    ),
    child: const Column(
      children: [
        Icon(Icons.notifications_none, color: coral, size: 28),
        SizedBox(height: 9),
        Text(
          'No alarms yet',
          style: TextStyle(color: ink, fontWeight: FontWeight.w700),
        ),
        SizedBox(height: 3),
        Text(
          'Your next moment starts here.',
          style: TextStyle(color: muted, fontSize: 12),
        ),
      ],
    ),
  );
}

String greeting() {
  final hour = DateTime.now().hour;
  if (hour < 12) return 'MORNING';
  if (hour < 17) return 'AFTERNOON';
  return 'EVENING';
}

bool alarmsAreRelated(AlarmItem existing, AlarmDraft incoming) {
  if (existing.repeat != incoming.repeat) return false;
  if (existing.dateTime.difference(incoming.dateTime).abs() >
      const Duration(minutes: 15)) {
    return false;
  }
  final left = _intentWords(existing.label);
  final right = _intentWords(incoming.label);
  if (left.isEmpty || right.isEmpty) return false;
  return left.intersection(right).isNotEmpty;
}

Set<String> _intentWords(String label) {
  const ignored = {
    'alarm',
    'reminder',
    'the',
    'a',
    'an',
    'to',
    'for',
    'my',
    'at',
    'in',
  };
  return RegExp(r'[a-z0-9]+')
      .allMatches(label.toLowerCase())
      .map((match) => match.group(0)!)
      .where((word) => word.length > 2 && !ignored.contains(word))
      .toSet();
}

String strongerWakeStyle(String left, String right) {
  const rank = {'single': 0, 'light': 1, 'normal': 2, 'heavy': 3};
  return (rank[left] ?? 0) >= (rank[right] ?? 0) ? left : right;
}

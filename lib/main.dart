import 'dart:async';
import 'dart:convert';
import 'dart:math';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:flutter_timezone/flutter_timezone.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:timezone/data/latest_all.dart' as tz;
import 'package:timezone/timezone.dart' as tz;

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();

  await _MindeAlarmService.ensureInitialized();
  final launchedFromAlarm =
      await _MindeAlarmService.didAlarmNotificationLaunchApp();
  final preferences = await SharedPreferences.getInstance();
  final initialPalette = _paletteFromStoredValue(
    preferences.getString(_appThemePrefsKey),
  );
  final initialBackdropId = _backdropIdFromStoredValue(
    preferences.getString(_appBackdropPrefsKey),
  );
  _applySystemUiStyle(initialPalette);

  runApp(
    _MyAppRoot(
      preferences: preferences,
      initialPalette: initialPalette,
      initialBackdropId: initialBackdropId,
      showLaunchExperience: !launchedFromAlarm,
      openAlarmSheetOnStart: launchedFromAlarm,
    ),
  );
}

class _AlarmScheduleResult {
  const _AlarmScheduleResult({
    required this.scheduled,
    required this.exact,
    required this.notificationsGranted,
    required this.supportedPlatform,
  });

  final bool scheduled;
  final bool exact;
  final bool notificationsGranted;
  final bool supportedPlatform;
}

class _MindeAlarmService {
  _MindeAlarmService._();

  static const int notificationId = 92001;
  static const String _channelId = 'minde_alarm_daily_v2';
  static const String _channelName = 'Alarm';
  static const String _channelDescription =
      'Codzienny alarm uruchamiający Minde.';
  static const String _notificationPayload = 'minde_daily_alarm';
  static const String _androidAlarmSoundName = 'minde_alarm';
  static const String _darwinAlarmSoundName = 'minde_alarm.wav';
  static final FlutterLocalNotificationsPlugin _notifications =
      FlutterLocalNotificationsPlugin();
  static final ValueNotifier<int> _alarmSelections = ValueNotifier<int>(0);
  static bool _initialized = false;

  static ValueListenable<int> get alarmSelections => _alarmSelections;

  static Future<void> ensureInitialized() async {
    if (_initialized) {
      return;
    }

    await _configureLocalTimezone();
    const settings = InitializationSettings(
      android: AndroidInitializationSettings('@mipmap/ic_launcher'),
      iOS: DarwinInitializationSettings(
        requestAlertPermission: false,
        requestBadgePermission: false,
        requestSoundPermission: false,
      ),
      macOS: DarwinInitializationSettings(
        requestAlertPermission: false,
        requestBadgePermission: false,
        requestSoundPermission: false,
      ),
    );

    await _notifications.initialize(
      settings: settings,
      onDidReceiveNotificationResponse: _handleNotificationResponse,
    );
    _initialized = true;
  }

  static Future<bool> didAlarmNotificationLaunchApp() async {
    final launchDetails = await _notifications
        .getNotificationAppLaunchDetails();
    final response = launchDetails?.notificationResponse;
    return launchDetails?.didNotificationLaunchApp == true &&
        response?.payload == _notificationPayload;
  }

  static Future<_AlarmScheduleResult> scheduleDailyAlarm(TimeOfDay time) async {
    await ensureInitialized();

    if (kIsWeb ||
        (defaultTargetPlatform != TargetPlatform.android &&
            defaultTargetPlatform != TargetPlatform.iOS &&
            defaultTargetPlatform != TargetPlatform.macOS)) {
      return const _AlarmScheduleResult(
        scheduled: false,
        exact: false,
        notificationsGranted: false,
        supportedPlatform: false,
      );
    }

    final notificationsGranted = await _requestNotificationPermissionIfNeeded();
    if (!notificationsGranted) {
      return const _AlarmScheduleResult(
        scheduled: false,
        exact: false,
        notificationsGranted: false,
        supportedPlatform: true,
      );
    }

    final exact = await _canUseExactAlarms();
    const androidDetails = AndroidNotificationDetails(
      _channelId,
      _channelName,
      channelDescription: _channelDescription,
      category: AndroidNotificationCategory.alarm,
      importance: Importance.max,
      priority: Priority.max,
      visibility: NotificationVisibility.public,
      playSound: true,
      sound: RawResourceAndroidNotificationSound(_androidAlarmSoundName),
      enableVibration: true,
      audioAttributesUsage: AudioAttributesUsage.alarm,
    );
    const iosDetails = DarwinNotificationDetails(
      presentAlert: true,
      presentBadge: false,
      presentSound: true,
      sound: _darwinAlarmSoundName,
      interruptionLevel: InterruptionLevel.timeSensitive,
    );
    const macosDetails = DarwinNotificationDetails(
      presentAlert: true,
      presentBadge: false,
      presentSound: true,
    );

    await _notifications.cancel(id: notificationId);
    await _notifications.zonedSchedule(
      id: notificationId,
      title: 'Alarm',
      body: 'Czas wejść do Minde i rozpocząć sesję.',
      scheduledDate: _nextInstanceOf(time),
      notificationDetails: const NotificationDetails(
        android: androidDetails,
        iOS: iosDetails,
        macOS: macosDetails,
      ),
      androidScheduleMode: exact
          ? AndroidScheduleMode.exactAllowWhileIdle
          : AndroidScheduleMode.inexactAllowWhileIdle,
      matchDateTimeComponents: DateTimeComponents.time,
      payload: _notificationPayload,
    );

    return _AlarmScheduleResult(
      scheduled: true,
      exact: exact || defaultTargetPlatform != TargetPlatform.android,
      notificationsGranted: true,
      supportedPlatform: true,
    );
  }

  static Future<void> cancelDailyAlarm() async {
    await ensureInitialized();
    await _notifications.cancel(id: notificationId);
  }

  static Future<bool> _requestNotificationPermissionIfNeeded() async {
    switch (defaultTargetPlatform) {
      case TargetPlatform.android:
        final android = _notifications
            .resolvePlatformSpecificImplementation<
              AndroidFlutterLocalNotificationsPlugin
            >();
        final granted = await android?.requestNotificationsPermission();
        return granted ?? true;
      case TargetPlatform.iOS:
        final ios = _notifications
            .resolvePlatformSpecificImplementation<
              IOSFlutterLocalNotificationsPlugin
            >();
        return await ios?.requestPermissions(
              alert: true,
              badge: false,
              sound: true,
            ) ??
            false;
      case TargetPlatform.macOS:
        final macos = _notifications
            .resolvePlatformSpecificImplementation<
              MacOSFlutterLocalNotificationsPlugin
            >();
        return await macos?.requestPermissions(
              alert: true,
              badge: false,
              sound: true,
            ) ??
            false;
      case TargetPlatform.fuchsia:
      case TargetPlatform.linux:
      case TargetPlatform.windows:
        return false;
    }
  }

  static Future<bool> _canUseExactAlarms() async {
    if (defaultTargetPlatform != TargetPlatform.android) {
      return true;
    }

    final android = _notifications
        .resolvePlatformSpecificImplementation<
          AndroidFlutterLocalNotificationsPlugin
        >();
    if (android == null) {
      return false;
    }

    final canScheduleNow = await android.canScheduleExactNotifications();
    if (canScheduleNow ?? false) {
      return true;
    }

    await android.requestExactAlarmsPermission();
    return await android.canScheduleExactNotifications() ?? false;
  }

  static Future<void> _configureLocalTimezone() async {
    tz.initializeTimeZones();

    try {
      final timezone = await FlutterTimezone.getLocalTimezone();
      tz.setLocalLocation(tz.getLocation(timezone.identifier));
    } catch (_) {
      tz.setLocalLocation(tz.getLocation('UTC'));
    }
  }

  static tz.TZDateTime _nextInstanceOf(TimeOfDay time) {
    final now = tz.TZDateTime.now(tz.local);
    var scheduled = tz.TZDateTime(
      tz.local,
      now.year,
      now.month,
      now.day,
      time.hour,
      time.minute,
    );

    if (!scheduled.isAfter(now)) {
      scheduled = scheduled.add(const Duration(days: 1));
    }

    return scheduled;
  }

  static void _handleNotificationResponse(NotificationResponse response) {
    if (response.payload == _notificationPayload) {
      _alarmSelections.value++;
    }
  }
}

class _AlarmSheetResult {
  const _AlarmSheetResult._({required this.enabled, this.time});

  const _AlarmSheetResult.save(TimeOfDay time)
    : this._(enabled: true, time: time);

  const _AlarmSheetResult.disable() : this._(enabled: false);

  final bool enabled;
  final TimeOfDay? time;
}

const String _appThemePrefsKey = 'minde_app_theme_v1';
const String _appBackdropPrefsKey = 'minde_app_backdrop_v1';

enum _AppThemeId { liquidGlass, liquidNight, graphite, ink, obsidian }

enum _AppBackdropId {
  glow,
  grid,
  diagonal,
  rings,
  dots,
  polynesiaChevron,
  polynesiaTapa,
  polynesiaWaves,
  polynesiaSpears,
  polynesiaDiamond,
  warriorTattoo,
  warriorMask,
  warriorShield,
  warriorTotem,
  warriorSpears,
}

class _AppBackdropDefinition {
  const _AppBackdropDefinition({required this.id, required this.label});

  final _AppBackdropId id;
  final String label;
}

class _AppPalette extends ThemeExtension<_AppPalette> {
  const _AppPalette({
    required this.id,
    required this.label,
    required this.subtitle,
    required this.seedColor,
    required this.backdropStart,
    required this.backdropMiddle,
    required this.backdropEnd,
    required this.glowTop,
    required this.glowMiddle,
    required this.glowBottom,
    required this.fullscreenStart,
    required this.fullscreenMiddle,
    required this.fullscreenEnd,
    required this.drawerSurface,
    required this.drawerBorder,
    required this.heroSurface,
    required this.heroGlass,
    required this.heroBorder,
    required this.heroText,
    required this.heroMutedText,
    required this.surface,
    required this.surfaceStrong,
    required this.surfaceMuted,
    required this.surfaceBorder,
    required this.primaryText,
    required this.secondaryText,
    required this.tertiaryText,
    required this.primaryButton,
    required this.onPrimaryButton,
    required this.outlinedButtonText,
    required this.outlinedButtonBorder,
    required this.success,
    required this.onSuccess,
    required this.warning,
    required this.onWarning,
    required this.shadowColor,
  });

  final _AppThemeId id;
  final String label;
  final String subtitle;
  final Color seedColor;
  final Color backdropStart;
  final Color backdropMiddle;
  final Color backdropEnd;
  final Color glowTop;
  final Color glowMiddle;
  final Color glowBottom;
  final Color fullscreenStart;
  final Color fullscreenMiddle;
  final Color fullscreenEnd;
  final Color drawerSurface;
  final Color drawerBorder;
  final Color heroSurface;
  final Color heroGlass;
  final Color heroBorder;
  final Color heroText;
  final Color heroMutedText;
  final Color surface;
  final Color surfaceStrong;
  final Color surfaceMuted;
  final Color surfaceBorder;
  final Color primaryText;
  final Color secondaryText;
  final Color tertiaryText;
  final Color primaryButton;
  final Color onPrimaryButton;
  final Color outlinedButtonText;
  final Color outlinedButtonBorder;
  final Color success;
  final Color onSuccess;
  final Color warning;
  final Color onWarning;
  final Color shadowColor;

  @override
  _AppPalette copyWith({
    _AppThemeId? id,
    String? label,
    String? subtitle,
    Color? seedColor,
    Color? backdropStart,
    Color? backdropMiddle,
    Color? backdropEnd,
    Color? glowTop,
    Color? glowMiddle,
    Color? glowBottom,
    Color? fullscreenStart,
    Color? fullscreenMiddle,
    Color? fullscreenEnd,
    Color? drawerSurface,
    Color? drawerBorder,
    Color? heroSurface,
    Color? heroGlass,
    Color? heroBorder,
    Color? heroText,
    Color? heroMutedText,
    Color? surface,
    Color? surfaceStrong,
    Color? surfaceMuted,
    Color? surfaceBorder,
    Color? primaryText,
    Color? secondaryText,
    Color? tertiaryText,
    Color? primaryButton,
    Color? onPrimaryButton,
    Color? outlinedButtonText,
    Color? outlinedButtonBorder,
    Color? success,
    Color? onSuccess,
    Color? warning,
    Color? onWarning,
    Color? shadowColor,
  }) {
    return _AppPalette(
      id: id ?? this.id,
      label: label ?? this.label,
      subtitle: subtitle ?? this.subtitle,
      seedColor: seedColor ?? this.seedColor,
      backdropStart: backdropStart ?? this.backdropStart,
      backdropMiddle: backdropMiddle ?? this.backdropMiddle,
      backdropEnd: backdropEnd ?? this.backdropEnd,
      glowTop: glowTop ?? this.glowTop,
      glowMiddle: glowMiddle ?? this.glowMiddle,
      glowBottom: glowBottom ?? this.glowBottom,
      fullscreenStart: fullscreenStart ?? this.fullscreenStart,
      fullscreenMiddle: fullscreenMiddle ?? this.fullscreenMiddle,
      fullscreenEnd: fullscreenEnd ?? this.fullscreenEnd,
      drawerSurface: drawerSurface ?? this.drawerSurface,
      drawerBorder: drawerBorder ?? this.drawerBorder,
      heroSurface: heroSurface ?? this.heroSurface,
      heroGlass: heroGlass ?? this.heroGlass,
      heroBorder: heroBorder ?? this.heroBorder,
      heroText: heroText ?? this.heroText,
      heroMutedText: heroMutedText ?? this.heroMutedText,
      surface: surface ?? this.surface,
      surfaceStrong: surfaceStrong ?? this.surfaceStrong,
      surfaceMuted: surfaceMuted ?? this.surfaceMuted,
      surfaceBorder: surfaceBorder ?? this.surfaceBorder,
      primaryText: primaryText ?? this.primaryText,
      secondaryText: secondaryText ?? this.secondaryText,
      tertiaryText: tertiaryText ?? this.tertiaryText,
      primaryButton: primaryButton ?? this.primaryButton,
      onPrimaryButton: onPrimaryButton ?? this.onPrimaryButton,
      outlinedButtonText: outlinedButtonText ?? this.outlinedButtonText,
      outlinedButtonBorder: outlinedButtonBorder ?? this.outlinedButtonBorder,
      success: success ?? this.success,
      onSuccess: onSuccess ?? this.onSuccess,
      warning: warning ?? this.warning,
      onWarning: onWarning ?? this.onWarning,
      shadowColor: shadowColor ?? this.shadowColor,
    );
  }

  @override
  _AppPalette lerp(ThemeExtension<_AppPalette>? other, double t) {
    if (other is! _AppPalette) {
      return this;
    }

    return _AppPalette(
      id: t < 0.5 ? id : other.id,
      label: t < 0.5 ? label : other.label,
      subtitle: t < 0.5 ? subtitle : other.subtitle,
      seedColor: Color.lerp(seedColor, other.seedColor, t)!,
      backdropStart: Color.lerp(backdropStart, other.backdropStart, t)!,
      backdropMiddle: Color.lerp(backdropMiddle, other.backdropMiddle, t)!,
      backdropEnd: Color.lerp(backdropEnd, other.backdropEnd, t)!,
      glowTop: Color.lerp(glowTop, other.glowTop, t)!,
      glowMiddle: Color.lerp(glowMiddle, other.glowMiddle, t)!,
      glowBottom: Color.lerp(glowBottom, other.glowBottom, t)!,
      fullscreenStart: Color.lerp(fullscreenStart, other.fullscreenStart, t)!,
      fullscreenMiddle: Color.lerp(
        fullscreenMiddle,
        other.fullscreenMiddle,
        t,
      )!,
      fullscreenEnd: Color.lerp(fullscreenEnd, other.fullscreenEnd, t)!,
      drawerSurface: Color.lerp(drawerSurface, other.drawerSurface, t)!,
      drawerBorder: Color.lerp(drawerBorder, other.drawerBorder, t)!,
      heroSurface: Color.lerp(heroSurface, other.heroSurface, t)!,
      heroGlass: Color.lerp(heroGlass, other.heroGlass, t)!,
      heroBorder: Color.lerp(heroBorder, other.heroBorder, t)!,
      heroText: Color.lerp(heroText, other.heroText, t)!,
      heroMutedText: Color.lerp(heroMutedText, other.heroMutedText, t)!,
      surface: Color.lerp(surface, other.surface, t)!,
      surfaceStrong: Color.lerp(surfaceStrong, other.surfaceStrong, t)!,
      surfaceMuted: Color.lerp(surfaceMuted, other.surfaceMuted, t)!,
      surfaceBorder: Color.lerp(surfaceBorder, other.surfaceBorder, t)!,
      primaryText: Color.lerp(primaryText, other.primaryText, t)!,
      secondaryText: Color.lerp(secondaryText, other.secondaryText, t)!,
      tertiaryText: Color.lerp(tertiaryText, other.tertiaryText, t)!,
      primaryButton: Color.lerp(primaryButton, other.primaryButton, t)!,
      onPrimaryButton: Color.lerp(onPrimaryButton, other.onPrimaryButton, t)!,
      outlinedButtonText: Color.lerp(
        outlinedButtonText,
        other.outlinedButtonText,
        t,
      )!,
      outlinedButtonBorder: Color.lerp(
        outlinedButtonBorder,
        other.outlinedButtonBorder,
        t,
      )!,
      success: Color.lerp(success, other.success, t)!,
      onSuccess: Color.lerp(onSuccess, other.onSuccess, t)!,
      warning: Color.lerp(warning, other.warning, t)!,
      onWarning: Color.lerp(onWarning, other.onWarning, t)!,
      shadowColor: Color.lerp(shadowColor, other.shadowColor, t)!,
    );
  }
}

const List<_AppPalette> _appPalettes = <_AppPalette>[
  _AppPalette(
    id: _AppThemeId.liquidGlass,
    label: 'Liquid Glass',
    subtitle:
        'Jasny motyw z taflą szkła, srebrnym światłem i spokojnym kontrastem.',
    seedColor: Color(0xFF5C88B8),
    backdropStart: Color(0xFFF8FBFF),
    backdropMiddle: Color(0xFFE8EFF8),
    backdropEnd: Color(0xFFDCE6F4),
    glowTop: Color(0x42FFFFFF),
    glowMiddle: Color(0x2898D6E8),
    glowBottom: Color(0x2491B2D2),
    fullscreenStart: Color(0xFFF7FAFE),
    fullscreenMiddle: Color(0xFFEAF0F8),
    fullscreenEnd: Color(0xFFDDE7F2),
    drawerSurface: Color(0xEEF7FBFF),
    drawerBorder: Color(0x99FFFFFF),
    heroSurface: Color(0xD9F9FCFF),
    heroGlass: Color(0xFFFFFFFF),
    heroBorder: Color(0xA6FFFFFF),
    heroText: Color(0xFF101A28),
    heroMutedText: Color(0xFF54667C),
    surface: Color(0xDDF5F9FF),
    surfaceStrong: Color(0xF2FFFFFF),
    surfaceMuted: Color(0xD5E4ECF6),
    surfaceBorder: Color(0x8FE7EEF8),
    primaryText: Color(0xFF122031),
    secondaryText: Color(0xFF56677D),
    tertiaryText: Color(0xFF73849A),
    primaryButton: Color(0xFF285E96),
    onPrimaryButton: Colors.white,
    outlinedButtonText: Color(0xFF234E7C),
    outlinedButtonBorder: Color(0x9FBED2E8),
    success: Color(0xFF1D9D73),
    onSuccess: Colors.white,
    warning: Color(0xFFE2A34B),
    onWarning: Color(0xFF2F220B),
    shadowColor: Color(0x1C233246),
  ),
  _AppPalette(
    id: _AppThemeId.liquidNight,
    label: 'Liquid Night',
    subtitle:
        'Ciemny motyw ze szklistą warstwą, chłodnym światłem i miękkim kontrastem.',
    seedColor: Color(0xFF7CC9E8),
    backdropStart: Color(0xFF060A12),
    backdropMiddle: Color(0xFF122033),
    backdropEnd: Color(0xFF213550),
    glowTop: Color(0x33579ED4),
    glowMiddle: Color(0x3367C5D1),
    glowBottom: Color(0x223BC6A2),
    fullscreenStart: Color(0xFF050910),
    fullscreenMiddle: Color(0xFF0F1828),
    fullscreenEnd: Color(0xFF1A2A40),
    drawerSurface: Color(0xCC0C1726),
    drawerBorder: Color(0x55EFF8FF),
    heroSurface: Color(0xA0142237),
    heroGlass: Color(0xCCEFF6FF),
    heroBorder: Color(0x55EFF6FF),
    heroText: Color(0xFFF5F8FF),
    heroMutedText: Color(0xFFD0DAEA),
    surface: Color(0x99131D2D),
    surfaceStrong: Color(0xB3172235),
    surfaceMuted: Color(0xAA213148),
    surfaceBorder: Color(0x52DDEFFD),
    primaryText: Color(0xFFF1F7FF),
    secondaryText: Color(0xFFCBD7E8),
    tertiaryText: Color(0xFFA7B8CE),
    primaryButton: Color(0xFF9ED9FF),
    onPrimaryButton: Color(0xFF0A2031),
    outlinedButtonText: Color(0xFFE7F4FF),
    outlinedButtonBorder: Color(0x66DCF1FF),
    success: Color(0xFF79E0BA),
    onSuccess: Color(0xFF071B13),
    warning: Color(0xFFFFCC7A),
    onWarning: Color(0xFF2A1B05),
    shadowColor: Color(0x70010810),
  ),
  _AppPalette(
    id: _AppThemeId.graphite,
    label: 'Jasny Tryb',
    subtitle: 'Jasne tło, chłodne boxy i ciemny tekst z mocnym kontrastem.',
    seedColor: Color(0xFF6F8FBD),
    backdropStart: Color(0xFFF6F8FD),
    backdropMiddle: Color(0xFFE7EEF8),
    backdropEnd: Color(0xFFD5E1F3),
    glowTop: Color(0x33B6D0F6),
    glowMiddle: Color(0x339AB9E8),
    glowBottom: Color(0x22AFC8EA),
    fullscreenStart: Color(0xFFEAF1FB),
    fullscreenMiddle: Color(0xFFDCE7F7),
    fullscreenEnd: Color(0xFFCBD9EF),
    drawerSurface: Color(0xFFF9FBFF),
    drawerBorder: Color(0xFFD8E2F0),
    heroSurface: Color(0xFFE3ECF9),
    heroGlass: Color(0xFFFEFFFF),
    heroBorder: Color(0xFFB7C8E2),
    heroText: Color(0xFF19314D),
    heroMutedText: Color(0xFF5A7088),
    surface: Color(0xFFF8FBFF),
    surfaceStrong: Colors.white,
    surfaceMuted: Color(0xFFE8F0FA),
    surfaceBorder: Color(0xFFD5E0EE),
    primaryText: Color(0xFF1A2F45),
    secondaryText: Color(0xFF5A7086),
    tertiaryText: Color(0xFF7D8FA4),
    primaryButton: Color(0xFF2F5D95),
    onPrimaryButton: Colors.white,
    outlinedButtonText: Color(0xFF2F5D95),
    outlinedButtonBorder: Color(0xFF86A3C5),
    success: Color(0xFF4D9D7E),
    onSuccess: Colors.white,
    warning: Color(0xFFF2C46D),
    onWarning: Color(0xFF2B1D08),
    shadowColor: Color(0x1F27415E),
  ),
  _AppPalette(
    id: _AppThemeId.ink,
    label: 'Ciemny Tryb',
    subtitle: 'Głęboki granat, ciemne boxy i jasny tekst z mocnym kontrastem.',
    seedColor: Color(0xFF4D6A97),
    backdropStart: Color(0xFF05070C),
    backdropMiddle: Color(0xFF111827),
    backdropEnd: Color(0xFF1E2B45),
    glowTop: Color(0x334C77C7),
    glowMiddle: Color(0x333C5A8F),
    glowBottom: Color(0x22496CC0),
    fullscreenStart: Color(0xFF03050A),
    fullscreenMiddle: Color(0xFF0C1422),
    fullscreenEnd: Color(0xFF141E33),
    drawerSurface: Color(0xFF0E1522),
    drawerBorder: Color(0xFF22314C),
    heroSurface: Color(0xFF111B2D),
    heroGlass: Color(0xFF17243A),
    heroBorder: Color(0xFF2B3C5C),
    heroText: Color(0xFFF5F8FF),
    heroMutedText: Color(0xFFC8D6F0),
    surface: Color(0xFF152033),
    surfaceStrong: Color(0xFF1A2740),
    surfaceMuted: Color(0xFF223252),
    surfaceBorder: Color(0xFF31476D),
    primaryText: Color(0xFFF2F6FF),
    secondaryText: Color(0xFFC5D3EA),
    tertiaryText: Color(0xFF98ACCB),
    primaryButton: Color(0xFF6E96E9),
    onPrimaryButton: Color(0xFF07111F),
    outlinedButtonText: Color(0xFFDDE8FF),
    outlinedButtonBorder: Color(0xFF6A87BC),
    success: Color(0xFF7FD6A2),
    onSuccess: Color(0xFF08160E),
    warning: Color(0xFFF2C46D),
    onWarning: Color(0xFF231907),
    shadowColor: Color(0x6602050A),
  ),
  _AppPalette(
    id: _AppThemeId.obsidian,
    label: 'Obsydian',
    subtitle:
        'Prawie czarne tło, stalowe boxy i bardzo jasny tekst dla pełnej czytelności.',
    seedColor: Color(0xFF7C8CA8),
    backdropStart: Color(0xFF020305),
    backdropMiddle: Color(0xFF090D15),
    backdropEnd: Color(0xFF141A27),
    glowTop: Color(0x335978C5),
    glowMiddle: Color(0x223F5D98),
    glowBottom: Color(0x22344E82),
    fullscreenStart: Color(0xFF020408),
    fullscreenMiddle: Color(0xFF0A1019),
    fullscreenEnd: Color(0xFF131C2B),
    drawerSurface: Color(0xFF0A0F18),
    drawerBorder: Color(0xFF202A3D),
    heroSurface: Color(0xFF101723),
    heroGlass: Color(0xFF172233),
    heroBorder: Color(0xFF2C3950),
    heroText: Color(0xFFF7FAFF),
    heroMutedText: Color(0xFFC7D1E2),
    surface: Color(0xFF111722),
    surfaceStrong: Color(0xFF171F2E),
    surfaceMuted: Color(0xFF202A3D),
    surfaceBorder: Color(0xFF30405B),
    primaryText: Color(0xFFF3F7FD),
    secondaryText: Color(0xFFC3CDDD),
    tertiaryText: Color(0xFF92A0B8),
    primaryButton: Color(0xFF90A5CD),
    onPrimaryButton: Color(0xFF07111A),
    outlinedButtonText: Color(0xFFE2EBFA),
    outlinedButtonBorder: Color(0xFF7285A9),
    success: Color(0xFF7FD3B4),
    onSuccess: Color(0xFF07170F),
    warning: Color(0xFFF0C26A),
    onWarning: Color(0xFF251907),
    shadowColor: Color(0x8F010204),
  ),
];

const List<_AppBackdropDefinition>
_appBackdropDefinitions = <_AppBackdropDefinition>[
  _AppBackdropDefinition(
    id: _AppBackdropId.warriorShield,
    label: '3D Kryształy',
  ),
  _AppBackdropDefinition(id: _AppBackdropId.warriorTotem, label: '3D Tunel'),
  _AppBackdropDefinition(id: _AppBackdropId.warriorMask, label: '3D Schody'),
  _AppBackdropDefinition(id: _AppBackdropId.warriorTattoo, label: '3D Fale'),
  _AppBackdropDefinition(id: _AppBackdropId.warriorSpears, label: '3D Kostki'),
];

_AppPalette _paletteForId(_AppThemeId id) {
  return _appPalettes.firstWhere((_AppPalette palette) => palette.id == id);
}

final _AppPalette _defaultAppPalette = _paletteForId(_AppThemeId.liquidGlass);
const _AppBackdropId _defaultAppBackdropId = _AppBackdropId.warriorShield;

_AppPalette _paletteFromStoredValue(String? value) {
  final fallback = _defaultAppPalette;
  if (value == null || value.isEmpty) {
    return fallback;
  }

  if (value == 'ember' || value == 'forest') {
    return _appPalettes.firstWhere(
      (_AppPalette palette) => palette.id == _AppThemeId.obsidian,
    );
  }

  for (final palette in _appPalettes) {
    if (palette.id.name == value) {
      return palette;
    }
  }
  return fallback;
}

_AppBackdropId _backdropIdFromStoredValue(String? value) {
  final fallback = _defaultAppBackdropId;
  if (value == null || value.isEmpty) {
    return fallback;
  }

  for (final definition in _appBackdropDefinitions) {
    if (definition.id.name == value) {
      return definition.id;
    }
  }
  return fallback;
}

Color _contrastingForeground(Color background) {
  return ThemeData.estimateBrightnessForColor(background) == Brightness.dark
      ? Colors.white
      : const Color(0xFF16212B);
}

SystemUiOverlayStyle _systemUiStyleForPalette(_AppPalette palette) {
  final navigationColor = palette.primaryButton;
  final iconBrightness =
      ThemeData.estimateBrightnessForColor(navigationColor) == Brightness.dark
      ? Brightness.light
      : Brightness.dark;
  final statusBrightness =
      ThemeData.estimateBrightnessForColor(palette.backdropStart) ==
          Brightness.dark
      ? Brightness.light
      : Brightness.dark;

  return SystemUiOverlayStyle(
    statusBarColor: Colors.transparent,
    statusBarIconBrightness: statusBrightness,
    statusBarBrightness: statusBrightness == Brightness.light
        ? Brightness.dark
        : Brightness.light,
    systemNavigationBarColor: navigationColor,
    systemNavigationBarDividerColor: navigationColor,
    systemNavigationBarIconBrightness: iconBrightness,
  );
}

void _applySystemUiStyle(_AppPalette palette) {
  SystemChrome.setSystemUIOverlayStyle(_systemUiStyleForPalette(palette));
}

ThemeData _buildAppTheme(_AppPalette palette) {
  final brightness =
      ThemeData.estimateBrightnessForColor(palette.surface) == Brightness.dark
      ? Brightness.dark
      : Brightness.light;
  final ColorScheme scheme =
      ColorScheme.fromSeed(
        seedColor: palette.seedColor,
        brightness: brightness,
      ).copyWith(
        primary: palette.primaryButton,
        onPrimary: palette.onPrimaryButton,
        secondary: palette.seedColor,
        surface: palette.surface,
        onSurface: palette.primaryText,
        outline: palette.surfaceBorder,
      );

  final ThemeData baseTheme = ThemeData(
    useMaterial3: true,
    colorScheme: scheme,
    extensions: <ThemeExtension<dynamic>>[palette],
  );

  return baseTheme.copyWith(
    scaffoldBackgroundColor: Colors.transparent,
    appBarTheme: AppBarTheme(
      backgroundColor: Colors.transparent,
      elevation: 0,
      foregroundColor: palette.heroText,
      surfaceTintColor: Colors.transparent,
      titleTextStyle: baseTheme.textTheme.titleLarge?.copyWith(
        color: palette.heroText,
        fontWeight: FontWeight.w800,
      ),
    ),
    dialogTheme: DialogThemeData(
      backgroundColor: palette.surfaceStrong,
      surfaceTintColor: Colors.transparent,
      titleTextStyle: baseTheme.textTheme.titleLarge?.copyWith(
        color: palette.primaryText,
        fontWeight: FontWeight.w800,
      ),
      contentTextStyle: baseTheme.textTheme.bodyMedium?.copyWith(
        color: palette.secondaryText,
      ),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(24)),
    ),
    snackBarTheme: SnackBarThemeData(
      behavior: SnackBarBehavior.floating,
      backgroundColor: palette.primaryButton,
      contentTextStyle: baseTheme.textTheme.bodyMedium?.copyWith(
        color: palette.onPrimaryButton,
        fontWeight: FontWeight.w600,
      ),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(18)),
    ),
    timePickerTheme: TimePickerThemeData(
      backgroundColor: palette.surfaceStrong,
      dialBackgroundColor: palette.surfaceMuted,
      dayPeriodColor: palette.surfaceMuted,
      dayPeriodTextColor: palette.primaryText,
      dialHandColor: palette.primaryButton,
      dialTextColor: palette.primaryText,
      entryModeIconColor: palette.primaryButton,
      hourMinuteTextColor: palette.primaryText,
      hourMinuteColor: palette.surface,
    ),
    textTheme: baseTheme.textTheme.copyWith(
      displaySmall: TextStyle(
        fontFamily: 'Georgia',
        fontSize: 34,
        fontWeight: FontWeight.w700,
        height: 1.1,
        color: palette.primaryText,
      ),
      headlineMedium: TextStyle(
        fontFamily: 'Georgia',
        fontSize: 28,
        fontWeight: FontWeight.w700,
        height: 1.15,
        color: palette.primaryText,
      ),
      titleLarge: TextStyle(
        fontSize: 20,
        fontWeight: FontWeight.w700,
        height: 1.2,
        color: palette.primaryText,
      ),
      titleMedium: TextStyle(
        fontSize: 16,
        fontWeight: FontWeight.w700,
        height: 1.3,
        color: palette.primaryText,
      ),
      bodyLarge: TextStyle(
        fontSize: 16,
        fontWeight: FontWeight.w500,
        height: 1.45,
        color: palette.primaryText,
      ),
      bodyMedium: TextStyle(
        fontSize: 14,
        fontWeight: FontWeight.w500,
        height: 1.45,
        color: palette.secondaryText,
      ),
      bodySmall: TextStyle(
        fontSize: 12,
        fontWeight: FontWeight.w500,
        height: 1.35,
        color: palette.tertiaryText,
      ),
      labelLarge: TextStyle(
        fontSize: 14,
        fontWeight: FontWeight.w700,
        color: palette.secondaryText,
      ),
      labelMedium: TextStyle(
        fontSize: 12,
        fontWeight: FontWeight.w700,
        color: palette.secondaryText,
      ),
    ),
    filledButtonTheme: FilledButtonThemeData(
      style: FilledButton.styleFrom(
        backgroundColor: palette.primaryButton,
        foregroundColor: palette.onPrimaryButton,
        elevation: 0,
        padding: const EdgeInsets.symmetric(horizontal: 22, vertical: 16),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(18)),
      ),
    ),
    outlinedButtonTheme: OutlinedButtonThemeData(
      style: OutlinedButton.styleFrom(
        backgroundColor: palette.outlinedButtonText.withValues(alpha: 0.04),
        foregroundColor: palette.outlinedButtonText,
        side: BorderSide(color: palette.outlinedButtonBorder, width: 1.2),
        padding: const EdgeInsets.symmetric(horizontal: 22, vertical: 16),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(18)),
      ),
    ),
    chipTheme: baseTheme.chipTheme.copyWith(
      backgroundColor: palette.surfaceMuted,
      selectedColor: palette.seedColor.withValues(alpha: 0.18),
      side: BorderSide(color: palette.surfaceBorder),
      labelStyle: baseTheme.textTheme.labelLarge?.copyWith(
        color: palette.primaryText,
        fontWeight: FontWeight.w700,
      ),
    ),
  );
}

class _AppThemeController extends ChangeNotifier {
  _AppThemeController({
    required SharedPreferences? preferences,
    required _AppPalette initialPalette,
    required _AppBackdropId initialBackdropId,
  }) : _preferences = preferences,
       _palette = initialPalette,
       _backdropId = initialBackdropId;

  final SharedPreferences? _preferences;
  _AppPalette _palette;
  _AppBackdropId _backdropId;

  _AppPalette get palette => _palette;
  _AppBackdropId get backdropId => _backdropId;

  Future<void> selectTheme(_AppThemeId id) async {
    final nextPalette = _appPalettes.firstWhere(
      (_AppPalette palette) => palette.id == id,
    );
    if (nextPalette.id == _palette.id) {
      return;
    }

    _palette = nextPalette;
    notifyListeners();
    _applySystemUiStyle(nextPalette);
    await _preferences?.setString(_appThemePrefsKey, id.name);
  }

  Future<void> selectBackdrop(_AppBackdropId id) async {
    if (id == _backdropId) {
      return;
    }

    _backdropId = id;
    notifyListeners();
    await _preferences?.setString(_appBackdropPrefsKey, id.name);
  }
}

class _AppThemeScope extends InheritedNotifier<_AppThemeController> {
  const _AppThemeScope({
    required _AppThemeController controller,
    required super.child,
  }) : super(notifier: controller);

  static _AppThemeController of(BuildContext context) {
    final scope = context.dependOnInheritedWidgetOfExactType<_AppThemeScope>();
    assert(scope != null, 'Brak _AppThemeScope w drzewie widgetów.');
    return scope!.notifier!;
  }
}

extension _AppThemeContext on BuildContext {
  _AppPalette get appPalette =>
      Theme.of(this).extension<_AppPalette>() ?? _appPalettes.first;

  _AppThemeController get appThemeController => _AppThemeScope.of(this);

  _AppBackdropId get appBackdropId => appThemeController.backdropId;
}

class MyApp extends StatelessWidget {
  const MyApp({
    super.key,
    this.showLaunchExperience = true,
    this.openAlarmSheetOnStart = false,
  });

  final bool showLaunchExperience;
  final bool openAlarmSheetOnStart;

  @override
  Widget build(BuildContext context) {
    return _MyAppRoot(
      preferences: null,
      initialPalette: _defaultAppPalette,
      initialBackdropId: _defaultAppBackdropId,
      showLaunchExperience: showLaunchExperience,
      openAlarmSheetOnStart: openAlarmSheetOnStart,
    );
  }
}

class _MyAppRoot extends StatefulWidget {
  const _MyAppRoot({
    required this.preferences,
    required this.initialPalette,
    required this.initialBackdropId,
    this.showLaunchExperience = true,
    this.openAlarmSheetOnStart = false,
  });

  final SharedPreferences? preferences;
  final _AppPalette initialPalette;
  final _AppBackdropId initialBackdropId;
  final bool showLaunchExperience;
  final bool openAlarmSheetOnStart;

  @override
  State<_MyAppRoot> createState() => _MyAppState();
}

class _MyAppState extends State<_MyAppRoot> {
  late final _AppThemeController _themeController;

  @override
  void initState() {
    super.initState();
    _themeController = _AppThemeController(
      preferences: widget.preferences,
      initialPalette: widget.initialPalette,
      initialBackdropId: widget.initialBackdropId,
    );
  }

  @override
  void dispose() {
    _themeController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: _themeController,
      builder: (BuildContext context, Widget? child) {
        final palette = _themeController.palette;
        return _AppThemeScope(
          controller: _themeController,
          child: MaterialApp(
            debugShowCheckedModeBanner: false,
            title: 'Minde',
            theme: _buildAppTheme(palette),
            home: widget.showLaunchExperience
                ? AppLaunchGate(
                    child: FlowHomePage(
                      openAlarmSheetOnStart: widget.openAlarmSheetOnStart,
                    ),
                  )
                : FlowHomePage(
                    openAlarmSheetOnStart: widget.openAlarmSheetOnStart,
                  ),
          ),
        );
      },
    );
  }
}

class AppLaunchGate extends StatefulWidget {
  const AppLaunchGate({super.key, required this.child});

  final Widget child;

  @override
  State<AppLaunchGate> createState() => _AppLaunchGateState();
}

class _AppLaunchGateState extends State<AppLaunchGate>
    with SingleTickerProviderStateMixin {
  static const Duration _launchDuration = Duration(seconds: 3);

  late final AnimationController _animationController;
  Timer? _launchTimer;
  bool _showHome = false;

  @override
  void initState() {
    super.initState();
    _animationController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 2400),
    )..repeat();
    _launchTimer = Timer(_launchDuration, () {
      if (!mounted) {
        return;
      }
      _animationController.stop();
      setState(() {
        _showHome = true;
      });
    });
  }

  @override
  void dispose() {
    _launchTimer?.cancel();
    _animationController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final Widget currentChild = _showHome
        ? KeyedSubtree(
            key: const ValueKey<String>('minde-home'),
            child: widget.child,
          )
        : AnimatedBuilder(
            key: const ValueKey<String>('minde-launch'),
            animation: _animationController,
            builder: (BuildContext context, Widget? child) {
              return _MindeLaunchScreen(progress: _animationController.value);
            },
          );

    return AnimatedSwitcher(
      duration: const Duration(milliseconds: 650),
      switchInCurve: Curves.easeOutCubic,
      switchOutCurve: Curves.easeInCubic,
      transitionBuilder: (Widget child, Animation<double> animation) {
        return FadeTransition(opacity: animation, child: child);
      },
      child: currentChild,
    );
  }
}

class AppThemeDrawer extends StatefulWidget {
  const AppThemeDrawer({super.key});

  @override
  State<AppThemeDrawer> createState() => _AppThemeDrawerState();
}

class _AppThemeDrawerState extends State<AppThemeDrawer> {
  PageController? _themePageController;
  PageController? _backdropPageController;
  int _currentThemePageIndex = 0;
  int _currentBackdropPageIndex = 0;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final controller = context.appThemeController;
    final currentPaletteId = controller.palette.id;
    final selectedThemeIndex = _appPalettes.indexWhere(
      (_AppPalette palette) => palette.id == currentPaletteId,
    );
    final selectedBackdropIndex = _appBackdropDefinitions.indexWhere(
      (_AppBackdropDefinition definition) =>
          definition.id == controller.backdropId,
    );

    if (selectedBackdropIndex < 0 &&
        controller.backdropId != _appBackdropDefinitions.first.id) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted) {
          return;
        }
        context.appThemeController.selectBackdrop(
          _appBackdropDefinitions.first.id,
        );
      });
    }

    if (_themePageController == null) {
      _currentThemePageIndex = selectedThemeIndex < 0 ? 0 : selectedThemeIndex;
      _themePageController = PageController(
        initialPage: _currentThemePageIndex,
        viewportFraction: 0.9,
      );
    }

    if (_backdropPageController == null) {
      _currentBackdropPageIndex = selectedBackdropIndex < 0
          ? 0
          : selectedBackdropIndex;
      _backdropPageController = PageController(
        initialPage: _currentBackdropPageIndex,
        viewportFraction: 0.54,
      );
    }
  }

  @override
  void dispose() {
    _themePageController?.dispose();
    _backdropPageController?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final activePalette = context.appPalette;
    final controller = context.appThemeController;
    final themePageController = _themePageController;
    final backdropPageController = _backdropPageController;

    if (themePageController == null || backdropPageController == null) {
      return const Drawer(child: SizedBox.shrink());
    }

    return Drawer(
      width: min(360, MediaQuery.sizeOf(context).width * 0.88),
      child: DecoratedBox(
        decoration: BoxDecoration(
          color: activePalette.drawerSurface,
          border: Border(
            right: BorderSide(color: activePalette.drawerBorder, width: 1),
          ),
        ),
        child: SafeArea(
          child: ListView(
            padding: const EdgeInsets.only(bottom: 16),
            children: <Widget>[
              Padding(
                padding: const EdgeInsets.fromLTRB(20, 18, 12, 10),
                child: Row(
                  children: <Widget>[
                    Expanded(
                      child: Text(
                        'Motywy aplikacji',
                        style: theme.textTheme.titleLarge?.copyWith(
                          color: activePalette.primaryText,
                        ),
                      ),
                    ),
                    IconButton(
                      onPressed: () => Navigator.of(context).maybePop(),
                      icon: const Icon(Icons.close_rounded),
                      color: activePalette.primaryText,
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 6),
              SizedBox(
                height: 286,
                child: PageView.builder(
                  controller: themePageController,
                  physics: const BouncingScrollPhysics(),
                  itemCount: _appPalettes.length,
                  onPageChanged: (int index) {
                    setState(() {
                      _currentThemePageIndex = index;
                    });
                  },
                  itemBuilder: (BuildContext context, int index) {
                    final palette = _appPalettes[index];
                    final bool selected = palette.id == controller.palette.id;
                    return Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 8),
                      child: _ThemePreviewCard(
                        palette: palette,
                        selected: selected,
                        onSelected: () {
                          controller.selectTheme(palette.id);
                          if (_currentThemePageIndex != index) {
                            setState(() {
                              _currentThemePageIndex = index;
                            });
                            themePageController.animateToPage(
                              index,
                              duration: const Duration(milliseconds: 220),
                              curve: Curves.easeOutCubic,
                            );
                          }
                        },
                      ),
                    );
                  },
                ),
              ),
              const SizedBox(height: 14),
              Center(
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: List<Widget>.generate(_appPalettes.length, (
                    int index,
                  ) {
                    final bool selected = index == _currentThemePageIndex;
                    return AnimatedContainer(
                      duration: const Duration(milliseconds: 180),
                      margin: EdgeInsets.only(left: index == 0 ? 0 : 6),
                      width: selected ? 18 : 8,
                      height: 8,
                      decoration: BoxDecoration(
                        color: selected
                            ? activePalette.primaryButton
                            : activePalette.outlinedButtonBorder.withValues(
                                alpha: 0.32,
                              ),
                        borderRadius: BorderRadius.circular(999),
                      ),
                    );
                  }),
                ),
              ),
              const SizedBox(height: 18),
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 20),
                child: Text(
                  'Tło aplikacji',
                  style: theme.textTheme.titleMedium?.copyWith(
                    color: activePalette.primaryText,
                    fontWeight: FontWeight.w800,
                  ),
                ),
              ),
              const SizedBox(height: 12),
              if (_appBackdropDefinitions.length == 1)
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 20),
                  child: _BackdropPreviewCard(
                    palette: activePalette,
                    definition: _appBackdropDefinitions.first,
                    selected:
                        controller.backdropId ==
                        _appBackdropDefinitions.first.id,
                    onSelected: () => controller.selectBackdrop(
                      _appBackdropDefinitions.first.id,
                    ),
                  ),
                )
              else ...<Widget>[
                SizedBox(
                  height: 154,
                  child: PageView.builder(
                    controller: backdropPageController,
                    physics: const BouncingScrollPhysics(),
                    itemCount: _appBackdropDefinitions.length,
                    onPageChanged: (int index) {
                      setState(() {
                        _currentBackdropPageIndex = index;
                      });
                    },
                    itemBuilder: (BuildContext context, int index) {
                      final definition = _appBackdropDefinitions[index];
                      return Padding(
                        padding: EdgeInsets.only(
                          left: index == 0 ? 20 : 8,
                          right: index == _appBackdropDefinitions.length - 1
                              ? 20
                              : 8,
                        ),
                        child: _BackdropPreviewCard(
                          palette: activePalette,
                          definition: definition,
                          selected: controller.backdropId == definition.id,
                          onSelected: () {
                            controller.selectBackdrop(definition.id);
                            if (_currentBackdropPageIndex != index) {
                              setState(() {
                                _currentBackdropPageIndex = index;
                              });
                              backdropPageController.animateToPage(
                                index,
                                duration: const Duration(milliseconds: 220),
                                curve: Curves.easeOutCubic,
                              );
                            }
                          },
                        ),
                      );
                    },
                  ),
                ),
                const SizedBox(height: 12),
                Center(
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: List<Widget>.generate(
                      _appBackdropDefinitions.length,
                      (int index) {
                        final bool selected =
                            index == _currentBackdropPageIndex;
                        return AnimatedContainer(
                          duration: const Duration(milliseconds: 180),
                          margin: EdgeInsets.only(left: index == 0 ? 0 : 6),
                          width: selected ? 18 : 8,
                          height: 8,
                          decoration: BoxDecoration(
                            color: selected
                                ? activePalette.primaryButton
                                : activePalette.outlinedButtonBorder.withValues(
                                    alpha: 0.32,
                                  ),
                            borderRadius: BorderRadius.circular(999),
                          ),
                        );
                      },
                    ),
                  ),
                ),
              ],
              const SizedBox(height: 16),
            ],
          ),
        ),
      ),
    );
  }
}

class _BackdropPreviewCard extends StatelessWidget {
  const _BackdropPreviewCard({
    required this.palette,
    required this.definition,
    required this.selected,
    required this.onSelected,
  });

  final _AppPalette palette;
  final _AppBackdropDefinition definition;
  final bool selected;
  final VoidCallback onSelected;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: onSelected,
        borderRadius: BorderRadius.circular(22),
        child: Ink(
          padding: const EdgeInsets.all(10),
          decoration: BoxDecoration(
            color: palette.surface.withValues(alpha: 0.94),
            borderRadius: BorderRadius.circular(22),
            border: Border.all(
              color: selected ? palette.primaryButton : palette.surfaceBorder,
              width: selected ? 1.6 : 1,
            ),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              ClipRRect(
                borderRadius: BorderRadius.circular(16),
                child: SizedBox(
                  width: double.infinity,
                  height: 74,
                  child: Stack(
                    fit: StackFit.expand,
                    children: <Widget>[
                      DecoratedBox(
                        decoration: BoxDecoration(
                          gradient: LinearGradient(
                            begin: Alignment.topLeft,
                            end: Alignment.bottomRight,
                            colors: <Color>[
                              palette.backdropStart,
                              palette.backdropMiddle,
                              palette.backdropEnd,
                            ],
                          ),
                        ),
                      ),
                      _BackdropPatternLayer(
                        backdropId: definition.id,
                        palette: palette,
                        compact: true,
                      ),
                    ],
                  ),
                ),
              ),
              const SizedBox(height: 10),
              Row(
                children: <Widget>[
                  Expanded(
                    child: Text(
                      definition.label,
                      style: theme.textTheme.labelLarge?.copyWith(
                        color: palette.primaryText,
                        fontWeight: FontWeight.w800,
                      ),
                    ),
                  ),
                  if (selected)
                    Icon(
                      Icons.check_circle_rounded,
                      size: 18,
                      color: palette.primaryButton,
                    ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _ThemePreviewCard extends StatelessWidget {
  const _ThemePreviewCard({
    required this.palette,
    required this.selected,
    required this.onSelected,
  });

  final _AppPalette palette;
  final bool selected;
  final VoidCallback onSelected;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final buttonTextColor = _contrastingForeground(palette.primaryButton);

    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: onSelected,
        borderRadius: BorderRadius.circular(30),
        child: Ink(
          padding: const EdgeInsets.all(18),
          decoration: BoxDecoration(
            gradient: LinearGradient(
              begin: Alignment.topLeft,
              end: Alignment.bottomRight,
              colors: <Color>[
                palette.backdropStart,
                palette.backdropMiddle,
                palette.backdropEnd,
              ],
            ),
            borderRadius: BorderRadius.circular(30),
            border: Border.all(
              color: selected
                  ? palette.onPrimaryButton.withValues(alpha: 0.6)
                  : Colors.white.withValues(alpha: 0.22),
              width: selected ? 1.5 : 1,
            ),
            boxShadow: <BoxShadow>[
              BoxShadow(
                color: palette.shadowColor,
                blurRadius: 24,
                offset: const Offset(0, 14),
              ),
            ],
          ),
          child: Stack(
            children: <Widget>[
              Positioned(
                top: -28,
                right: -14,
                child: GlowOrb(size: 112, color: palette.glowTop),
              ),
              Positioned(
                left: -20,
                bottom: 58,
                child: GlowOrb(size: 92, color: palette.glowMiddle),
              ),
              Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: <Widget>[
                  Row(
                    children: <Widget>[
                      Container(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 12,
                          vertical: 8,
                        ),
                        decoration: BoxDecoration(
                          color: Colors.white.withValues(alpha: 0.14),
                          borderRadius: BorderRadius.circular(999),
                        ),
                        child: Text(
                          palette.label,
                          style: theme.textTheme.labelLarge?.copyWith(
                            color: Colors.white,
                            fontWeight: FontWeight.w800,
                          ),
                        ),
                      ),
                      const Spacer(),
                      if (selected)
                        Container(
                          padding: const EdgeInsets.symmetric(
                            horizontal: 10,
                            vertical: 7,
                          ),
                          decoration: BoxDecoration(
                            color: palette.success,
                            borderRadius: BorderRadius.circular(999),
                          ),
                          child: Text(
                            'Aktywny',
                            style: theme.textTheme.labelMedium?.copyWith(
                              color: palette.onSuccess,
                              fontWeight: FontWeight.w900,
                            ),
                          ),
                        ),
                    ],
                  ),
                  const SizedBox(height: 16),
                  Container(
                    width: double.infinity,
                    padding: const EdgeInsets.all(14),
                    decoration: BoxDecoration(
                      color: palette.heroSurface.withValues(alpha: 0.96),
                      borderRadius: BorderRadius.circular(24),
                      border: Border.all(color: palette.heroBorder),
                    ),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: <Widget>[
                        Text(
                          'Minde',
                          style: theme.textTheme.headlineMedium?.copyWith(
                            color: palette.heroText,
                          ),
                        ),
                        const SizedBox(height: 10),
                        Row(
                          children: <Widget>[
                            Expanded(
                              child: Container(
                                height: 10,
                                decoration: BoxDecoration(
                                  color: palette.heroGlass.withValues(
                                    alpha: 0.24,
                                  ),
                                  borderRadius: BorderRadius.circular(999),
                                ),
                              ),
                            ),
                            const SizedBox(width: 8),
                            Container(
                              width: 36,
                              height: 10,
                              decoration: BoxDecoration(
                                color: palette.success,
                                borderRadius: BorderRadius.circular(999),
                              ),
                            ),
                          ],
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(height: 14),
                  Container(
                    width: double.infinity,
                    padding: const EdgeInsets.all(14),
                    decoration: BoxDecoration(
                      color: palette.surfaceStrong.withValues(alpha: 0.96),
                      borderRadius: BorderRadius.circular(24),
                      border: Border.all(color: palette.surfaceBorder),
                    ),
                    child: Column(
                      children: <Widget>[
                        Row(
                          children: <Widget>[
                            Expanded(
                              child: Container(
                                height: 34,
                                decoration: BoxDecoration(
                                  color: palette.primaryButton,
                                  borderRadius: BorderRadius.circular(14),
                                ),
                                alignment: Alignment.center,
                                child: Text(
                                  'Przycisk',
                                  style: theme.textTheme.labelLarge?.copyWith(
                                    color: buttonTextColor,
                                    fontWeight: FontWeight.w800,
                                  ),
                                ),
                              ),
                            ),
                            const SizedBox(width: 10),
                            Expanded(
                              child: Container(
                                height: 34,
                                decoration: BoxDecoration(
                                  color: palette.outlinedButtonText.withValues(
                                    alpha: 0.04,
                                  ),
                                  borderRadius: BorderRadius.circular(14),
                                  border: Border.all(
                                    color: palette.outlinedButtonBorder,
                                  ),
                                ),
                                alignment: Alignment.center,
                                child: Text(
                                  'Box',
                                  style: theme.textTheme.labelLarge?.copyWith(
                                    color: palette.outlinedButtonText,
                                    fontWeight: FontWeight.w800,
                                  ),
                                ),
                              ),
                            ),
                          ],
                        ),
                        const SizedBox(height: 12),
                        Row(
                          children: <Widget>[
                            Expanded(
                              child: Container(
                                height: 10,
                                decoration: BoxDecoration(
                                  color: palette.surface,
                                  borderRadius: BorderRadius.circular(999),
                                ),
                              ),
                            ),
                            const SizedBox(width: 8),
                            Expanded(
                              child: Container(
                                height: 10,
                                decoration: BoxDecoration(
                                  color: palette.surfaceMuted,
                                  borderRadius: BorderRadius.circular(999),
                                ),
                              ),
                            ),
                          ],
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _MindeLaunchScreen extends StatelessWidget {
  const _MindeLaunchScreen({required this.progress});

  final double progress;

  @override
  Widget build(BuildContext context) {
    final double pulse = 0.96 + (0.08 * (0.5 + (0.5 * sin(progress * 2 * pi))));
    final double haloOpacity =
        0.18 + (0.14 * (0.5 + (0.5 * sin(progress * 2 * pi))));
    final double crownBob = 6 * sin(progress * 2 * pi);
    final double crownScale =
        0.98 + (0.05 * (0.5 + (0.5 * sin((progress * 2 * pi) + (pi / 4)))));

    return ColoredBox(
      color: Colors.black,
      child: LayoutBuilder(
        builder: (BuildContext context, BoxConstraints constraints) {
          final double crownOffset = constraints.maxHeight < 720 ? 82 : 94;
          final double textOffset = crownOffset + 88;

          return Stack(
            fit: StackFit.expand,
            children: <Widget>[
              const DecoratedBox(
                decoration: BoxDecoration(
                  gradient: RadialGradient(
                    center: Alignment.center,
                    radius: 0.72,
                    colors: <Color>[
                      Color(0xFF101010),
                      Color(0xFF050505),
                      Colors.black,
                    ],
                    stops: <double>[0, 0.42, 1],
                  ),
                ),
              ),
              Center(
                child: IgnorePointer(
                  child: Container(
                    width: 176,
                    height: 176,
                    decoration: BoxDecoration(
                      shape: BoxShape.circle,
                      gradient: RadialGradient(
                        colors: <Color>[
                          Colors.white.withValues(alpha: haloOpacity),
                          Colors.transparent,
                        ],
                        stops: const <double>[0, 1],
                      ),
                    ),
                  ),
                ),
              ),
              Center(
                child: Transform.scale(
                  scale: pulse,
                  child: Container(
                    width: 22,
                    height: 22,
                    decoration: BoxDecoration(
                      shape: BoxShape.circle,
                      color: Colors.white,
                      boxShadow: <BoxShadow>[
                        BoxShadow(
                          color: Colors.white.withValues(alpha: 0.32),
                          blurRadius: 42,
                          spreadRadius: 2,
                        ),
                      ],
                    ),
                  ),
                ),
              ),
              Center(
                child: Transform.translate(
                  offset: Offset(0, crownOffset + crownBob),
                  child: Transform.scale(
                    scale: crownScale,
                    child: const SizedBox(
                      width: 112,
                      height: 82,
                      child: CustomPaint(painter: _CrownPainter()),
                    ),
                  ),
                ),
              ),
              Center(
                child: Transform.translate(
                  offset: Offset(0, textOffset),
                  child: Text(
                    'Minde',
                    style:
                        Theme.of(context).textTheme.headlineMedium?.copyWith(
                          color: Colors.white,
                          fontWeight: FontWeight.w800,
                          letterSpacing: 0.5,
                        ) ??
                        const TextStyle(
                          color: Colors.white,
                          fontSize: 28,
                          fontWeight: FontWeight.w800,
                          letterSpacing: 0.5,
                        ),
                  ),
                ),
              ),
            ],
          );
        },
      ),
    );
  }
}

class _CrownPainter extends CustomPainter {
  const _CrownPainter();

  @override
  void paint(Canvas canvas, Size size) {
    final Rect rect = Offset.zero & size;
    final Path spikes = _buildSpikes(rect);
    final RRect band = _buildBand(rect);
    final Paint glowPaint = Paint()
      ..color = const Color(0xFFE4B552).withValues(alpha: 0.3)
      ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 16);
    final Paint fillPaint = Paint()
      ..shader = const LinearGradient(
        begin: Alignment.topCenter,
        end: Alignment.bottomCenter,
        colors: <Color>[
          Color(0xFFFFF1B8),
          Color(0xFFE1B34A),
          Color(0xFFB87A14),
        ],
      ).createShader(rect);
    final Paint strokePaint = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 2.2
      ..color = const Color(0xFFFFF6D7).withValues(alpha: 0.92);
    final Paint jewelPaint = Paint()..color = const Color(0xFFFFF6D7);

    canvas.drawPath(spikes.shift(const Offset(0, 4)), glowPaint);
    canvas.drawRRect(band.shift(const Offset(0, 4)), glowPaint);

    canvas.drawPath(spikes, fillPaint);
    canvas.drawRRect(band, fillPaint);
    canvas.drawPath(spikes, strokePaint);
    canvas.drawRRect(band, strokePaint);

    final double jewelY = rect.top + (rect.height * 0.64);
    canvas.drawCircle(
      Offset(rect.left + (rect.width * 0.32), jewelY),
      4,
      jewelPaint,
    );
    canvas.drawCircle(
      Offset(rect.left + (rect.width * 0.5), jewelY - 2),
      4.8,
      jewelPaint,
    );
    canvas.drawCircle(
      Offset(rect.left + (rect.width * 0.68), jewelY),
      4,
      jewelPaint,
    );
  }

  Path _buildSpikes(Rect rect) {
    final double left = rect.left;
    final double top = rect.top;
    final double width = rect.width;
    final double height = rect.height;
    final double bottom = rect.bottom - (height * 0.18);
    final double shoulder = top + (height * 0.56);

    return Path()
      ..moveTo(left + (width * 0.14), bottom)
      ..lineTo(left + (width * 0.22), shoulder)
      ..lineTo(left + (width * 0.34), top + (height * 0.24))
      ..lineTo(left + (width * 0.44), shoulder - (height * 0.12))
      ..lineTo(left + (width * 0.5), top + (height * 0.08))
      ..lineTo(left + (width * 0.56), shoulder - (height * 0.12))
      ..lineTo(left + (width * 0.66), top + (height * 0.24))
      ..lineTo(left + (width * 0.78), shoulder)
      ..lineTo(left + (width * 0.86), bottom)
      ..close();
  }

  RRect _buildBand(Rect rect) {
    return RRect.fromRectAndRadius(
      Rect.fromLTWH(
        rect.left + (rect.width * 0.16),
        rect.top + (rect.height * 0.56),
        rect.width * 0.68,
        rect.height * 0.18,
      ),
      Radius.circular(rect.height * 0.08),
    );
  }

  @override
  bool shouldRepaint(covariant _CrownPainter oldDelegate) => false;
}

enum ExerciseKind {
  breathFlow,
  flowRunner,
  focusDot,
  focusScan,
  splitDecision,
  speedRead,
  memoryChain,
  mnemonicVault,
}

class ExerciseDefinition {
  const ExerciseDefinition({
    required this.kind,
    required this.title,
    required this.subtitle,
    required this.duration,
    required this.idealMoment,
    required this.outcome,
    required this.summary,
    required this.instructions,
    required this.tags,
    required this.icon,
    required this.accent,
  });

  final ExerciseKind kind;
  final String title;
  final String subtitle;
  final String duration;
  final String idealMoment;
  final String outcome;
  final String summary;
  final List<String> instructions;
  final List<String> tags;
  final IconData icon;
  final Color accent;
}

const List<ExerciseDefinition> exerciseDefinitions = <ExerciseDefinition>[
  ExerciseDefinition(
    kind: ExerciseKind.focusDot,
    title: 'Punkt Centralny',
    subtitle: 'Jedna kropka na środku i czysta praktyka nieruchomej uwagi.',
    duration: '2, 5 lub 10 min',
    idealMoment: 'Przed głębokim skupieniem',
    outcome: 'Spokojniejszy wzrok i szybszy powrót do jednego punktu.',
    summary:
        'Patrzysz w centralną kropkę bez szukania nowych bodźców. To prosty trening stabilnej uwagi i wyciszania wewnętrznego szumu.',
    instructions: <String>[
      'Wybierz 2, 5 albo 10 minut i usiądź bez poruszania telefonem.',
      'Patrz w sam środek kropki i wracaj do niej za każdym razem, gdy odpływasz.',
      'Oddychaj naturalnie. Nie walcz z myślami, tylko wracaj do punktu.',
    ],
    tags: <String>['fiksacja', 'cisza', 'uważność'],
    icon: Icons.adjust_rounded,
    accent: Color(0xFF5C7A9E),
  ),
  ExerciseDefinition(
    kind: ExerciseKind.focusScan,
    title: 'Skan Koncentracji',
    subtitle: 'Trzy poziomy konfliktu bodźców: podstawowa, średnia i hard.',
    duration: '45 s na poziom',
    idealMoment: 'Gdy myśli skaczą',
    outcome:
        'Mocniejszy filtr uwagi, szybsze przełączanie reguły i lepsza pamięć robocza.',
    summary:
        'Zaczynasz od prostego konfliktu słowo kontra kolor. Potem dochodzi tło, a na końcu odpowiadasz o poprzedniej planszy. Każdy poziom wzmacnia inny element koncentracji.',
    instructions: <String>[
      'Wybierz poziom Podstawowa, Średnia albo Hard.',
      'Na podstawowej oceniasz zgodność słowa i koloru, na średniej dochodzi tło, a na hard odpowiadasz o poprzedniej planszy.',
      'Reaguj szybko, ale trzymaj aktywną regułę i nie klikaj impulsem.',
    ],
    tags: <String>['uwaga', 'filtr', 'pamięć'],
    icon: Icons.visibility_rounded,
    accent: Color(0xFFD46C4E),
  ),
  ExerciseDefinition(
    kind: ExerciseKind.splitDecision,
    title: 'Split Decision',
    subtitle: 'Go / no-go z rosnącym tempem i zasadami zmienianymi w locie.',
    duration: '2 min',
    idealMoment: 'Gdy chcesz obudzić szybkość decyzji',
    outcome: 'Szybsze filtrowanie bodźców i pewniejsze hamowanie reakcji.',
    summary:
        'To ćwiczenie rozwija szybkie filtrowanie bodźców, kontrolę impulsu i zmianę reguły pod presją czasu. Uczysz się wychwytywać właściwy sygnał, ignorować resztę i reagować bez chaosu.',
    instructions: <String>[
      'Patrz na aktualną zasadę u góry i trzymaj ją aktywnie w głowie.',
      'Tapnij ekran tylko wtedy, gdy bieżący bodziec spełnia warunek.',
      'Gdy zasada się zmieni, przełącz filtr od razu i nie nadrabiaj spóźnionych reakcji.',
    ],
    tags: <String>['go/no-go', 'decyzja', 'tempo'],
    icon: Icons.flash_on_rounded,
    accent: Color(0xFF3466C2),
  ),
  ExerciseDefinition(
    kind: ExerciseKind.breathFlow,
    title: 'Pulse Sync',
    subtitle:
        'Pulsujące koło i rytmiczne tapnięcia do szybkiego wejścia w flow.',
    duration: '1 min',
    idealMoment: 'Tuż przed zadaniem',
    outcome: 'Lepsza synchronizacja ciało-uwaga i szybszy stan gotowości.',
    summary:
        'Koło wybija puls, a ty trafiasz dotykiem dokładnie w rytm. Wybierasz jeden z trzech poziomów tempa i przez minutę ustawiasz ciało oraz uwagę pod konkretny rytm.',
    instructions: <String>[
      'Wybierz poziom Łatwy, Średni albo Hard i ustaw telefon stabilnie przed sobą.',
      'Dotykaj koła dokładnie wtedy, gdy wybija rytm i daje krótką haptykę.',
      'Po minucie od razu przejdź do zadania, zanim rytm opadnie.',
    ],
    tags: <String>['flow', 'rytm', 'haptyka'],
    icon: Icons.graphic_eq_rounded,
    accent: Color(0xFF4C9B8F),
  ),
  ExerciseDefinition(
    kind: ExerciseKind.speedRead,
    title: 'Sprint Czytania',
    subtitle: 'Pojedyncze słowa lecą w szybkim rytmie z auto-przejściami.',
    duration: '4-5 min',
    idealMoment: 'Przed nauką lub czytaniem',
    outcome: 'Lepszy rytm wzroku i szybsze wejście w tekst.',
    summary:
        'Po starcie wchodzisz w serię 20 tekstów, ale każde zdanie rozbija się na pojedyncze słowa wyświetlane w środku ekranu. Wybierasz poziom długości tekstu, ustawiasz tempo w zakresie 400-1000 słów na minutę i utrzymujesz rytm dzięki automatycznemu 2, 1, START.',
    instructions: <String>[
      'Wybierz poziom 1-5. Każdy wyższy poziom daje dłuższe i gęstsze teksty.',
      'Pod poziomami ustaw oś prędkości w zakresie 400-1000 sł/min.',
      'Po kliknięciu Start sesji patrz w środek ekranu i łap słowa bez cofania wzroku.',
    ],
    tags: <String>['czytanie', 'tempo', 'nauka'],
    icon: Icons.menu_book_rounded,
    accent: Color(0xFFE1A94A),
  ),
  ExerciseDefinition(
    kind: ExerciseKind.memoryChain,
    title: 'Drabina Pamięci',
    subtitle: 'Trzy różne gry pamięciowe do treningu cyfr, słów i sekwencji.',
    duration: '4 min',
    idealMoment: 'Codzienny trening',
    outcome: 'Stabilniejsze trzymanie informacji w głowie.',
    summary:
        'Wybierasz jeden z trzech trybów: sekwencje ruchów, kod cyfr albo półkę słów. Każdy wariant podbija obciążenie pamięci roboczej, ale robi to innym kanałem.',
    instructions: <String>[
      'Wybierz grę pamięciową: ruch, cyfry albo słowa.',
      'Patrz na układ tylko do momentu, aż zniknie z ekranu.',
      'Odtwórz go z pamięci i utrzymuj serię, żeby dojść do dłuższych ciągów.',
    ],
    tags: <String>['pamięć', 'kolejność', 'precyzja'],
    icon: Icons.route_rounded,
    accent: Color(0xFF7A82D6),
  ),
  ExerciseDefinition(
    kind: ExerciseKind.mnemonicVault,
    title: 'Sejf cyfr ∞',
    subtitle: 'Baza skojarzeń 0-100, szybki recall, sprint i serie cyfr.',
    duration: 'Mapa 0-100',
    idealMoment: 'Przed nauką i powtórką',
    outcome:
        'Trzymasz stałą bazę skojarzeń i szybko sprawdzasz, czy odpowiedź wraca bez podpowiedzi.',
    summary:
        'Ten box łączy stałą bazę cyfr 0-100 z trzema trybami pracy. Recall losuje liczbę i wymusza szybką reakcję Tak/Nie, sprint przewija po kolei cyfra + obraz, a seria cyfr pokazuje 10 rund sekwencji do zapamiętania i wpisania.',
    instructions: <String>[
      'Kliknij box ∞, żeby rozwinąć bazę i uruchomić trening.',
      'Recall pokazuje liczbę, odpala krótki timer i wymaga szybkiej decyzji: Tak albo Nie.',
      'Sprint przewija po kolei liczby z opisami w dwóch sekcjach 0-50 i 51-100 z krótką pauzą między nimi.',
      'Seria cyfr pokazuje 3-22 liczb, od 6 elementów rozkłada je na kolejne rzędy i pozwala wrócić dokładnie do tej samej rundy.',
      'Bez odsłaniania skojarzenia zaznacz od razu: Tak albo Nie i przejdź do kolejnej liczby.',
    ],
    tags: <String>['mnemotechnika', 'cyfry', 'skojarzenia'],
    icon: Icons.all_inclusive_rounded,
    accent: Color(0xFF9B7A39),
  ),
  ExerciseDefinition(
    kind: ExerciseKind.flowRunner,
    title: 'Flow Runner',
    subtitle: 'Płynny ruch pod palcem, uniki i bonusy przy rosnącym tempie.',
    duration: 'bez limitu',
    idealMoment: 'Gdy chcesz wejść w rytm i refleks',
    outcome:
        'Lepsze wyczucie tempa, szybsze korekty i dłuższe utrzymanie flow.',
    summary:
        'Płyniesz cały czas do przodu, omijasz przeszkody i zbierasz bonusy, a arena stopniowo przyspiesza. Nie ma tur ani limitu czasu, jest tylko ruch, rytm i szybkie korekty prowadzone palcem po ekranie.',
    instructions: <String>[
      'Wybierz poziom Flow, Surge albo Apex i trzymaj wzrok kilka kroków przed sobą.',
      'Przesuwaj palcem w lewo i w prawo po ekranie, a kulka będzie płynnie podążać za ruchem.',
      'Zbieraj bonusy i reaguj wcześnie, bo z każdą chwilą tempo rośnie.',
    ],
    tags: <String>['flow', 'reakcja', 'ruch'],
    icon: Icons.show_chart_rounded,
    accent: Color(0xFF2E9E89),
  ),
];

class FlowHomePage extends StatefulWidget {
  const FlowHomePage({super.key, this.openAlarmSheetOnStart = false});

  final bool openAlarmSheetOnStart;

  @override
  State<FlowHomePage> createState() => _FlowHomePageState();
}

class _FlowHomePageState extends State<FlowHomePage>
    with WidgetsBindingObserver {
  static const String _flowProgressPrefsKey = 'flow_home_progress_v2';
  static const String _mnemonicMorningReviewPrefsKey =
      'mnemonic_morning_review_v1';
  static const String _mnemonicMorningReviewCountPrefsKey =
      'mnemonic_morning_review_count_v1';
  static const int _mnemonicMorningDailyTarget = 3;
  static const String _trainingDailyCompletedCountPrefsKey =
      'training_daily_completed_count_v1';
  static const String _trainingDailyCompletedDatePrefsKey =
      'training_daily_completed_date_v1';
  static const String _strawDailyCompletedCountPrefsKey =
      'straw_daily_completed_count_v1';
  static const String _strawDailyCompletedDatePrefsKey =
      'straw_daily_completed_date_v1';
  static const int _dailyHeroMetricTarget = 3;
  static const String _alarmEnabledPrefsKey = 'minde_alarm_enabled_v1';
  static const String _alarmHourPrefsKey = 'minde_alarm_hour_v1';
  static const String _alarmMinutePrefsKey = 'minde_alarm_minute_v1';
  static const Duration _goldenSecretDuration = Duration(seconds: 10);

  Set<ExerciseKind> _completed = <ExerciseKind>{};
  List<_FlowProgressEntry> _savedProgressEntries = <_FlowProgressEntry>[];
  late DateTime _visibleCalendarMonth;
  String _activeProgressDateKey = _dateKeyFor(DateTime.now());
  String? _currentCycleRecordId;
  String? _selectedCalendarDateKey;
  bool _calendarExpanded = false;
  Timer? _dayRefreshTimer;
  int _mnemonicMorningCompletedCount = 0;
  bool _mnemonicMorningCardFlipped = false;
  bool _mnemonicMorningShowCompletionPrompt = false;
  TimeOfDay? _alarmTime;
  bool _alarmEnabled = false;
  bool _alarmSheetVisible = false;
  Timer? _goldenSecretTimer;
  bool _goldenSecretVisible = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    final now = DateTime.now();
    _visibleCalendarMonth = DateTime(now.year, now.month);
    _selectedCalendarDateKey = _dateKeyFor(now);
    unawaited(_initializeHomeState());
    final alarmInitialization = _initializeAlarm();
    _MindeAlarmService.alarmSelections.addListener(_handleAlarmNotificationTap);
    if (widget.openAlarmSheetOnStart) {
      alarmInitialization.whenComplete(_scheduleAlarmSheetOpen);
    }
    _scheduleDayRefresh();
  }

  String get _todayKey => _dateKeyFor(DateTime.now());

  bool get _mnemonicMorningCompletedToday => _mnemonicMorningCompletedCount > 0;

  bool get _progressComplete =>
      _completed.length == exerciseDefinitions.length &&
      _currentCycleRecordId != null;

  int get _completedCyclesToday => _savedProgressEntries
      .where(
        (entry) =>
            entry.dateKey == _todayKey &&
            entry.type == _FlowProgressEntryType.cycle,
      )
      .length;

  Future<void> _initializeHomeState() async {
    await _loadFlowProgress();
    await _loadMnemonicMorningReview();
    await _syncDailyHeroEntriesFromPrefs();
  }

  int get _displayedCycleNumber {
    final completedCycles = _completedCyclesToday;
    if (_progressComplete && completedCycles > 0) {
      return completedCycles;
    }
    return completedCycles + 1;
  }

  Future<void> _initializeAlarm() async {
    await _MindeAlarmService.ensureInitialized();
    final prefs = await SharedPreferences.getInstance();
    final enabled = prefs.getBool(_alarmEnabledPrefsKey) ?? false;
    final hour = prefs.getInt(_alarmHourPrefsKey);
    final minute = prefs.getInt(_alarmMinutePrefsKey);
    final alarmTime = hour != null && minute != null
        ? TimeOfDay(hour: hour, minute: minute)
        : null;

    if (!mounted) {
      return;
    }

    setState(() {
      _alarmEnabled = enabled && alarmTime != null;
      _alarmTime = alarmTime;
    });
  }

  Future<void> _persistAlarmSettings({
    required bool enabled,
    required TimeOfDay? time,
  }) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_alarmEnabledPrefsKey, enabled);

    if (time == null) {
      await prefs.remove(_alarmHourPrefsKey);
      await prefs.remove(_alarmMinutePrefsKey);
      return;
    }

    await prefs.setInt(_alarmHourPrefsKey, time.hour);
    await prefs.setInt(_alarmMinutePrefsKey, time.minute);
  }

  Future<void> _openAlarmSheet() async {
    if (_alarmSheetVisible || !mounted) {
      return;
    }

    _alarmSheetVisible = true;
    var draftTime = _alarmTime ?? const TimeOfDay(hour: 7, minute: 0);
    final theme = Theme.of(context);
    final palette = context.appPalette;
    try {
      final result = await showModalBottomSheet<_AlarmSheetResult>(
        context: context,
        showDragHandle: true,
        backgroundColor: palette.surfaceStrong,
        builder: (BuildContext sheetContext) {
          return StatefulBuilder(
            builder: (BuildContext context, StateSetter setSheetState) {
              return Padding(
                padding: const EdgeInsets.fromLTRB(20, 4, 20, 24),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: <Widget>[
                    Row(
                      children: <Widget>[
                        Container(
                          padding: const EdgeInsets.all(10),
                          decoration: BoxDecoration(
                            color: palette.primaryButton.withValues(
                              alpha: 0.12,
                            ),
                            borderRadius: BorderRadius.circular(16),
                          ),
                          child: Icon(
                            Icons.alarm_rounded,
                            color: palette.primaryButton,
                          ),
                        ),
                        const SizedBox(width: 12),
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: <Widget>[
                              Text(
                                'Alarm',
                                style: theme.textTheme.titleLarge?.copyWith(
                                  color: palette.primaryText,
                                ),
                              ),
                              const SizedBox(height: 4),
                              Text(
                                'Ustaw codzienny alarm z mocniejszym dźwiękiem, który po kliknięciu otworzy aplikację.',
                                style: theme.textTheme.bodyMedium?.copyWith(
                                  color: palette.secondaryText,
                                  height: 1.45,
                                ),
                              ),
                            ],
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 20),
                    Container(
                      width: double.infinity,
                      padding: const EdgeInsets.symmetric(
                        horizontal: 18,
                        vertical: 16,
                      ),
                      decoration: BoxDecoration(
                        color: palette.primaryButton,
                        borderRadius: BorderRadius.circular(22),
                      ),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: <Widget>[
                          Text(
                            'Godzina alarmu',
                            style: theme.textTheme.labelLarge?.copyWith(
                              color: palette.onPrimaryButton.withValues(
                                alpha: 0.76,
                              ),
                              fontWeight: FontWeight.w700,
                            ),
                          ),
                          const SizedBox(height: 8),
                          Text(
                            _formatAlarmTime(draftTime),
                            style: theme.textTheme.displaySmall?.copyWith(
                              color: palette.onPrimaryButton,
                              fontSize: 30,
                            ),
                          ),
                        ],
                      ),
                    ),
                    const SizedBox(height: 16),
                    OutlinedButton.icon(
                      onPressed: () async {
                        final pickedTime = await showTimePicker(
                          context: sheetContext,
                          initialTime: draftTime,
                          initialEntryMode: TimePickerEntryMode.dialOnly,
                        );
                        if (pickedTime == null) {
                          return;
                        }
                        setSheetState(() {
                          draftTime = pickedTime;
                        });
                      },
                      icon: const Icon(Icons.schedule_rounded),
                      label: const Text('Wybierz godzinę'),
                    ),
                    const SizedBox(height: 12),
                    Row(
                      children: <Widget>[
                        Expanded(
                          child: OutlinedButton(
                            onPressed: _alarmEnabled
                                ? () => Navigator.of(
                                    sheetContext,
                                  ).pop(const _AlarmSheetResult.disable())
                                : null,
                            child: const Text('Wyłącz'),
                          ),
                        ),
                        const SizedBox(width: 12),
                        Expanded(
                          child: FilledButton(
                            onPressed: () => Navigator.of(
                              sheetContext,
                            ).pop(_AlarmSheetResult.save(draftTime)),
                            child: Text(_alarmEnabled ? 'Zapisz' : 'Włącz'),
                          ),
                        ),
                      ],
                    ),
                  ],
                ),
              );
            },
          );
        },
      );

      if (result == null) {
        return;
      }

      if (!result.enabled) {
        await _disableAlarm();
        return;
      }

      final selectedTime = result.time;
      if (selectedTime == null) {
        return;
      }

      await _saveAlarm(selectedTime);
    } finally {
      _alarmSheetVisible = false;
    }
  }

  Future<void> _saveAlarm(TimeOfDay time) async {
    final result = await _MindeAlarmService.scheduleDailyAlarm(time);
    if (!mounted) {
      return;
    }

    if (!result.supportedPlatform) {
      _showAlarmSnackBar(
        'Alarm działa obecnie na Androidzie, iPhonie i macOS.',
      );
      return;
    }

    if (!result.notificationsGranted || !result.scheduled) {
      _showAlarmSnackBar(
        'Brak zgody na powiadomienia. Włącz ją, aby alarm mógł zadziałać.',
      );
      return;
    }

    await _persistAlarmSettings(enabled: true, time: time);
    if (!mounted) {
      return;
    }

    setState(() {
      _alarmEnabled = true;
      _alarmTime = time;
    });

    final timeLabel = _formatAlarmTime(time);
    _showAlarmSnackBar(
      result.exact
          ? 'Alarm ustawiony na $timeLabel.'
          : 'Alarm ustawiony na $timeLabel. System może odpalić go z małym opóźnieniem.',
    );
  }

  Future<void> _disableAlarm() async {
    await _MindeAlarmService.cancelDailyAlarm();
    await _persistAlarmSettings(enabled: false, time: _alarmTime);

    if (!mounted) {
      return;
    }

    setState(() {
      _alarmEnabled = false;
    });

    _showAlarmSnackBar('Alarm został wyłączony.');
  }

  void _showAlarmSnackBar(String message) {
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(message)));
  }

  Future<void> _openMindeIdeasPage() {
    return Navigator.of(context).push<void>(
      _buildExerciseSessionRoute<void>(
        builder: (BuildContext context) {
          return const MindeIdeasPage();
        },
      ),
    );
  }

  String _formatAlarmTime(TimeOfDay time) {
    return MaterialLocalizations.of(
      context,
    ).formatTimeOfDay(time, alwaysUse24HourFormat: true);
  }

  Map<String, int> get _progressCountByDate {
    final counts = <String, int>{};
    for (final entry in _savedProgressEntries) {
      counts.update(entry.dateKey, (value) => value + 1, ifAbsent: () => 1);
    }
    return counts;
  }

  List<_FlowProgressEntry> _entriesForDate(String dateKey) {
    final entries = _savedProgressEntries
        .where((entry) => entry.dateKey == dateKey)
        .toList();
    entries.sort((a, b) => b.completedAtIso.compareTo(a.completedAtIso));
    return entries;
  }

  Future<void> _syncDailyHeroEntriesFromPrefs() async {
    final prefs = await SharedPreferences.getInstance();
    final todayKey = _todayKey;
    final desiredTypes = <_FlowProgressEntryType>[
      if (prefs.getString(_mnemonicMorningReviewPrefsKey) == todayKey &&
          (prefs.getInt(_mnemonicMorningReviewCountPrefsKey) ?? 0) >=
              _mnemonicMorningDailyTarget)
        _FlowProgressEntryType.memory,
      if (prefs.getString(_strawDailyCompletedDatePrefsKey) == todayKey &&
          (prefs.getInt(_strawDailyCompletedCountPrefsKey) ?? 0) >=
              _dailyHeroMetricTarget)
        _FlowProgressEntryType.vibration,
      if (prefs.getString(_trainingDailyCompletedDatePrefsKey) == todayKey &&
          (prefs.getInt(_trainingDailyCompletedCountPrefsKey) ?? 0) >=
              _dailyHeroMetricTarget)
        _FlowProgressEntryType.training,
    ];

    final existingTodayMetricEntries =
        <_FlowProgressEntryType, _FlowProgressEntry>{};
    for (final entry in _savedProgressEntries) {
      if (entry.dateKey != todayKey ||
          entry.type == _FlowProgressEntryType.cycle) {
        continue;
      }
      existingTodayMetricEntries.putIfAbsent(entry.type, () => entry);
    }

    final preservedEntries = _savedProgressEntries
        .where(
          (entry) =>
              entry.dateKey != todayKey ||
              entry.type == _FlowProgressEntryType.cycle,
        )
        .toList();
    final now = DateTime.now();
    final nextEntries = <_FlowProgressEntry>[
      ...preservedEntries,
      ...desiredTypes.map(
        (type) =>
            existingTodayMetricEntries[type] ??
            _FlowProgressEntry(
              id: '${type.name}-${now.microsecondsSinceEpoch}',
              dateKey: todayKey,
              completedAtIso: now.toIso8601String(),
              type: type,
            ),
      ),
    ]..sort((a, b) => b.completedAtIso.compareTo(a.completedAtIso));

    if (_sameFlowProgressEntries(nextEntries, _savedProgressEntries) ||
        !mounted) {
      return;
    }

    setState(() {
      _savedProgressEntries = nextEntries;
      final selectedDateKey = _selectedCalendarDateKey;
      if (selectedDateKey == null ||
          !nextEntries.any((entry) => entry.dateKey == selectedDateKey)) {
        _selectedCalendarDateKey = nextEntries.isNotEmpty
            ? nextEntries.first.dateKey
            : todayKey;
      }
      final selectedDate =
          _parseDateKey(_selectedCalendarDateKey ?? todayKey) ?? DateTime.now();
      _visibleCalendarMonth = DateTime(selectedDate.year, selectedDate.month);
    });
    await _persistFlowProgress();
  }

  Future<void> _loadFlowProgress() async {
    final prefs = await SharedPreferences.getInstance();
    final rawSnapshot = prefs.getString(_flowProgressPrefsKey);
    if (rawSnapshot == null) {
      return;
    }

    try {
      final decoded = jsonDecode(rawSnapshot);
      if (decoded is! Map<String, dynamic>) {
        return;
      }

      final snapshot = _FlowProgressSnapshot.fromJson(decoded);
      final todayKey = _todayKey;
      final entries = snapshot.entries.toList()
        ..sort((a, b) => b.completedAtIso.compareTo(a.completedAtIso));
      final activeDateMatchesToday = snapshot.activeDateKey == todayKey;
      final currentCycleRecordId =
          activeDateMatchesToday &&
              snapshot.currentCycleRecordId != null &&
              entries.any((entry) => entry.id == snapshot.currentCycleRecordId)
          ? snapshot.currentCycleRecordId
          : null;
      final selectedDateKey = entries.any((entry) => entry.dateKey == todayKey)
          ? todayKey
          : entries.isNotEmpty
          ? entries.first.dateKey
          : todayKey;
      final selectedDate = _parseDateKey(selectedDateKey) ?? DateTime.now();

      if (!mounted) {
        return;
      }

      setState(() {
        _activeProgressDateKey = todayKey;
        _completed = activeDateMatchesToday
            ? snapshot.completedKinds.toSet()
            : <ExerciseKind>{};
        _currentCycleRecordId = currentCycleRecordId;
        _savedProgressEntries = entries;
        _selectedCalendarDateKey = selectedDateKey;
        _visibleCalendarMonth = DateTime(selectedDate.year, selectedDate.month);
      });

      if (_completed.length == exerciseDefinitions.length &&
          _currentCycleRecordId == null) {
        await _archiveCompletedProgress();
      }
    } on FormatException {
      return;
    }
  }

  Future<void> _persistFlowProgress() async {
    final prefs = await SharedPreferences.getInstance();
    final snapshot = _FlowProgressSnapshot(
      activeDateKey: _activeProgressDateKey,
      completedKinds: _completed,
      currentCycleRecordId: _currentCycleRecordId,
      entries: _savedProgressEntries,
    );
    await prefs.setString(_flowProgressPrefsKey, jsonEncode(snapshot.toJson()));
  }

  Future<void> _updateCompletion(ExerciseKind kind, bool completed) async {
    final todayKey = _todayKey;
    var shouldArchiveCompletedProgress = false;

    setState(() {
      if (_activeProgressDateKey != todayKey) {
        _activeProgressDateKey = todayKey;
        _completed = <ExerciseKind>{};
        _currentCycleRecordId = null;
      }

      if (completed) {
        _completed.add(kind);
      } else {
        _completed.remove(kind);
      }

      shouldArchiveCompletedProgress =
          _completed.length == exerciseDefinitions.length &&
          _currentCycleRecordId == null;
    });

    if (shouldArchiveCompletedProgress) {
      await _archiveCompletedProgress();
      return;
    }

    await _persistFlowProgress();
  }

  Future<void> _archiveCompletedProgress() async {
    final now = DateTime.now();
    final entry = _FlowProgressEntry(
      id: now.microsecondsSinceEpoch.toString(),
      dateKey: _dateKeyFor(now),
      completedAtIso: now.toIso8601String(),
      type: _FlowProgressEntryType.cycle,
    );

    if (!mounted) {
      return;
    }

    setState(() {
      _activeProgressDateKey = entry.dateKey;
      _currentCycleRecordId = entry.id;
      _savedProgressEntries = <_FlowProgressEntry>[
        entry,
        ..._savedProgressEntries,
      ]..sort((a, b) => b.completedAtIso.compareTo(a.completedAtIso));
      _selectedCalendarDateKey = entry.dateKey;
      _visibleCalendarMonth = DateTime(now.year, now.month);
    });

    await _persistFlowProgress();
  }

  Future<void> _startNextProgressCycle() async {
    setState(() {
      _activeProgressDateKey = _todayKey;
      _completed = <ExerciseKind>{};
      _currentCycleRecordId = null;
      _selectedCalendarDateKey = _todayKey;
      final now = DateTime.now();
      _visibleCalendarMonth = DateTime(now.year, now.month);
    });
    await _persistFlowProgress();
  }

  Future<void> _deleteSavedProgress(_FlowProgressEntry entry) async {
    final shouldDelete = await showDialog<bool>(
      context: context,
      builder: (BuildContext context) {
        return AlertDialog(
          title: const Text('Usunąć zapis?'),
          content: Text(
            'To usunie wpis "${entry.calendarLabel}" z ${_formatFlowLongDateLabel(entry.dateKey)} o ${_formatSessionTimeLabel(entry.completedAtIso)}.',
          ),
          actions: <Widget>[
            TextButton(
              onPressed: () => Navigator.of(context).pop(false),
              child: const Text('Anuluj'),
            ),
            FilledButton(
              onPressed: () => Navigator.of(context).pop(true),
              child: const Text('Usuń'),
            ),
          ],
        );
      },
    );

    if (shouldDelete != true) {
      return;
    }

    setState(() {
      _savedProgressEntries =
          _savedProgressEntries
              .where((candidate) => candidate.id != entry.id)
              .toList()
            ..sort((a, b) => b.completedAtIso.compareTo(a.completedAtIso));

      if (_currentCycleRecordId == entry.id) {
        _currentCycleRecordId = null;
        _completed = <ExerciseKind>{};
        _activeProgressDateKey = _todayKey;
      }

      final selectedDateKey = _selectedCalendarDateKey;
      if (selectedDateKey != null &&
          !_savedProgressEntries.any(
            (candidate) => candidate.dateKey == selectedDateKey,
          )) {
        _selectedCalendarDateKey = _savedProgressEntries.isNotEmpty
            ? _savedProgressEntries.first.dateKey
            : _todayKey;
        final selectedDate =
            _parseDateKey(_selectedCalendarDateKey!) ?? DateTime.now();
        _visibleCalendarMonth = DateTime(selectedDate.year, selectedDate.month);
      }
    });

    await _persistFlowProgress();
  }

  void _changeCalendarMonth(int monthDelta) {
    setState(() {
      _visibleCalendarMonth = DateTime(
        _visibleCalendarMonth.year,
        _visibleCalendarMonth.month + monthDelta,
      );
    });
  }

  void _selectCalendarDate(DateTime date) {
    setState(() {
      _selectedCalendarDateKey = _dateKeyFor(date);
      _visibleCalendarMonth = DateTime(date.year, date.month);
    });
  }

  void _toggleCalendarExpanded() {
    setState(() {
      _calendarExpanded = !_calendarExpanded;
    });
  }

  Future<void> _loadMnemonicMorningReview() async {
    final prefs = await SharedPreferences.getInstance();
    final todayKey = _todayKey;
    final storedDateKey = prefs.getString(_mnemonicMorningReviewPrefsKey);
    final storedCount = prefs.getInt(_mnemonicMorningReviewCountPrefsKey);
    final completedToday = storedDateKey == todayKey;
    final completedCount = completedToday
        ? min(
            max(
              storedCount ??
                  (storedDateKey != null ? _mnemonicMorningDailyTarget : 0),
              0,
            ),
            _mnemonicMorningDailyTarget,
          )
        : 0;

    if (!mounted) {
      return;
    }

    setState(() {
      _mnemonicMorningCompletedCount = completedCount;
      _mnemonicMorningCardFlipped = completedCount > 0;
      _mnemonicMorningShowCompletionPrompt = false;
    });

    if (storedDateKey != null && !completedToday) {
      await prefs.remove(_mnemonicMorningReviewPrefsKey);
      await prefs.remove(_mnemonicMorningReviewCountPrefsKey);
    }
  }

  Future<void> _markMnemonicMorningReviewCompleted() async {
    if (_mnemonicMorningCompletedCount >= _mnemonicMorningDailyTarget) {
      return;
    }

    if (_mnemonicMorningShowCompletionPrompt) {
      setState(() {
        _mnemonicMorningShowCompletionPrompt = false;
      });
      return;
    }

    final todayKey = _todayKey;
    final nextCount = min(
      _mnemonicMorningCompletedCount + 1,
      _mnemonicMorningDailyTarget,
    );
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_mnemonicMorningReviewPrefsKey, todayKey);
    await prefs.setInt(_mnemonicMorningReviewCountPrefsKey, nextCount);

    if (!mounted) {
      return;
    }

    setState(() {
      _mnemonicMorningCompletedCount = nextCount;
      _mnemonicMorningCardFlipped = true;
      _mnemonicMorningShowCompletionPrompt =
          nextCount < _mnemonicMorningDailyTarget;
    });

    if (nextCount >= _mnemonicMorningDailyTarget) {
      await _syncDailyHeroEntriesFromPrefs();
    }
  }

  Future<void> _resetMnemonicMorningReview() async {
    final shouldReset = await showDialog<bool>(
      context: context,
      builder: (BuildContext dialogContext) {
        return AlertDialog(
          title: const Text('Czy wyzerować progres?'),
          content: const Text('To cofnie box ∞ do stanu początkowego.'),
          actions: <Widget>[
            TextButton(
              onPressed: () => Navigator.of(dialogContext).pop(false),
              child: const Text('Nie'),
            ),
            FilledButton(
              onPressed: () => Navigator.of(dialogContext).pop(true),
              child: const Text('Tak'),
            ),
          ],
        );
      },
    );

    if (shouldReset != true) {
      return;
    }

    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(_mnemonicMorningReviewPrefsKey);
    await prefs.remove(_mnemonicMorningReviewCountPrefsKey);

    if (!mounted) {
      return;
    }

    setState(() {
      _mnemonicMorningCompletedCount = 0;
      _mnemonicMorningCardFlipped = false;
      _mnemonicMorningShowCompletionPrompt = false;
    });

    await _syncDailyHeroEntriesFromPrefs();
  }

  void _toggleMnemonicMorningCard() {
    if (_mnemonicMorningCompletedToday) {
      return;
    }

    setState(() {
      _mnemonicMorningCardFlipped = !_mnemonicMorningCardFlipped;
    });
  }

  void _scheduleDayRefresh() {
    _dayRefreshTimer?.cancel();
    final now = DateTime.now();
    final nextDay = DateTime(now.year, now.month, now.day + 1);
    _dayRefreshTimer = Timer(
      nextDay.difference(now) + const Duration(seconds: 1),
      () {
        _handleDayRefresh();
      },
    );
  }

  Future<void> _handleDayRefresh() async {
    await _loadFlowProgress();
    await _loadMnemonicMorningReview();
    await _syncDailyHeroEntriesFromPrefs();
    if (!mounted) {
      return;
    }
    _scheduleDayRefresh();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      _handleDayRefresh();
    }
  }

  void _handleAlarmNotificationTap() {
    _scheduleAlarmSheetOpen();
  }

  void _scheduleAlarmSheetOpen() {
    if (!mounted || _alarmSheetVisible) {
      return;
    }

    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || _alarmSheetVisible) {
        return;
      }

      unawaited(_openAlarmSheet());
    });
  }

  void _showGoldenSecretScaffold() {
    _goldenSecretTimer?.cancel();
    if (!_goldenSecretVisible) {
      setState(() {
        _goldenSecretVisible = true;
      });
    }
    _goldenSecretTimer = Timer(_goldenSecretDuration, () {
      if (!mounted) {
        return;
      }
      setState(() {
        _goldenSecretVisible = false;
      });
    });
  }

  @override
  void dispose() {
    _MindeAlarmService.alarmSelections.removeListener(
      _handleAlarmNotificationTap,
    );
    WidgetsBinding.instance.removeObserver(this);
    _dayRefreshTimer?.cancel();
    _goldenSecretTimer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final palette = context.appPalette;
    final progress = _completed.length / exerciseDefinitions.length;
    final progressColor = _progressComplete ? palette.success : palette.warning;
    final selectedDateKey = _selectedCalendarDateKey ?? _todayKey;
    final selectedEntries = _entriesForDate(selectedDateKey);
    final progressCountByDate = _progressCountByDate;
    final calendarDays = _buildCalendarDays(_visibleCalendarMonth);
    final calendarSummary = selectedEntries.isEmpty
        ? 'Brak zapisów.'
        : '${_formatFlowLongDateLabel(selectedDateKey)} • ${selectedEntries.length} ${_formatFlowCalendarEntryCountLabel(selectedEntries.length)}';

    if (_goldenSecretVisible) {
      return Scaffold(
        key: const ValueKey<String>('golden-secret-scaffold'),
        backgroundColor: Colors.transparent,
        body: Stack(
          children: <Widget>[
            const AppBackdrop(),
            DecoratedBox(
              decoration: BoxDecoration(
                gradient: RadialGradient(
                  center: const Alignment(0, -0.08),
                  radius: 0.95,
                  colors: <Color>[
                    const Color(0xFFFFE29A).withValues(alpha: 0.12),
                    Colors.transparent,
                  ],
                ),
              ),
            ),
            SafeArea(
              child: Center(
                child: Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 28),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: <Widget>[
                      Text(
                        'Ta gra jest z myślą o tobie',
                        key: const ValueKey<String>('golden-secret-title'),
                        textAlign: TextAlign.center,
                        style: theme.textTheme.displaySmall?.copyWith(
                          color: palette.heroText,
                          fontWeight: FontWeight.w900,
                        ),
                      ),
                      const SizedBox(height: 18),
                      Text(
                        'Jesteś Najlepszy',
                        key: const ValueKey<String>('golden-secret-subtitle'),
                        textAlign: TextAlign.center,
                        style: theme.textTheme.headlineMedium?.copyWith(
                          color: const Color(0xFFFFD978),
                          fontWeight: FontWeight.w800,
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ],
        ),
      );
    }

    return Scaffold(
      drawer: const AppThemeDrawer(),
      drawerEdgeDragWidth: 28,
      body: Stack(
        children: <Widget>[
          const AppBackdrop(),
          SafeArea(
            child: ListView(
              padding: const EdgeInsets.fromLTRB(20, 16, 20, 32),
              children: <Widget>[
                SurfaceCard(
                  color: palette.heroSurface.withValues(alpha: 0.94),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: <Widget>[
                      Row(
                        children: <Widget>[
                          Expanded(
                            child: Text(
                              'Minde',
                              style: theme.textTheme.displaySmall?.copyWith(
                                color: palette.heroText,
                              ),
                            ),
                          ),
                          IconButton.filledTonal(
                            key: const ValueKey<String>('minde-ideas-open'),
                            onPressed: _openMindeIdeasPage,
                            tooltip: 'Tarcza pomysłów',
                            style: IconButton.styleFrom(
                              backgroundColor: palette.heroText.withValues(
                                alpha: 0.12,
                              ),
                              foregroundColor: palette.heroText,
                            ),
                            icon: const Icon(Icons.gpp_good_rounded),
                          ),
                        ],
                      ),
                      const SizedBox(height: 12),
                      Text.rich(
                        TextSpan(
                          style: theme.textTheme.bodyLarge?.copyWith(
                            color: palette.heroMutedText,
                          ),
                          children: const <InlineSpan>[
                            TextSpan(
                              text: '"',
                              style: TextStyle(color: Color(0xFFD4A63A)),
                            ),
                            TextSpan(
                              text:
                                  'To, co czuję jako zatrzymanie, to moment, w którym mózg buduje połączenia — a flow pojawi się, gdy staną się automatyczne.',
                            ),
                            TextSpan(
                              text: '"',
                              style: TextStyle(color: Color(0xFFD4A63A)),
                            ),
                          ],
                        ),
                      ),
                      const SizedBox(height: 24),
                      IntrinsicHeight(
                        child: Row(
                          crossAxisAlignment: CrossAxisAlignment.stretch,
                          children: <Widget>[
                            Expanded(
                              child: MnemonicMorningReviewMetric(
                                isFlipped: _mnemonicMorningCardFlipped,
                                completedCount: _mnemonicMorningCompletedCount,
                                dailyTarget: _mnemonicMorningDailyTarget,
                                showCompletionPrompt:
                                    _mnemonicMorningShowCompletionPrompt,
                                onFlip: _toggleMnemonicMorningCard,
                                onLongPress: _resetMnemonicMorningReview,
                                onMarkCompleted:
                                    _markMnemonicMorningReviewCompleted,
                              ),
                            ),
                            const SizedBox(width: 12),
                            Expanded(
                              child: HeroStrawMetric(
                                onProgressChanged:
                                    _syncDailyHeroEntriesFromPrefs,
                              ),
                            ),
                            const SizedBox(width: 12),
                            Expanded(
                              child: HeroTrainingMetric(
                                onProgressChanged:
                                    _syncDailyHeroEntriesFromPrefs,
                              ),
                            ),
                          ],
                        ),
                      ),
                      const SizedBox(height: 20),
                      Text(
                        'Dzisiejszy progres',
                        style: theme.textTheme.titleMedium?.copyWith(
                          color: palette.heroText,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                      const SizedBox(height: 8),
                      Text(
                        'Aktywny cykl $_displayedCycleNumber',
                        style: theme.textTheme.bodyMedium?.copyWith(
                          color: palette.heroMutedText,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                      const SizedBox(height: 10),
                      ClipRRect(
                        borderRadius: BorderRadius.circular(12),
                        child: LinearProgressIndicator(
                          minHeight: 12,
                          value: progress,
                          backgroundColor: palette.heroText.withValues(
                            alpha: 0.16,
                          ),
                          valueColor: AlwaysStoppedAnimation<Color>(
                            progressColor,
                          ),
                        ),
                      ),
                      const SizedBox(height: 8),
                      AnimatedSwitcher(
                        duration: const Duration(milliseconds: 220),
                        child: _progressComplete
                            ? Row(
                                key: const ValueKey<String>(
                                  'flow-progress-complete',
                                ),
                                children: <Widget>[
                                  Icon(
                                    Icons.check_circle_rounded,
                                    color: palette.success,
                                  ),
                                  const SizedBox(width: 8),
                                  Text(
                                    'Progres ukończono',
                                    style: theme.textTheme.bodyMedium?.copyWith(
                                      color: palette.success,
                                      fontWeight: FontWeight.w800,
                                    ),
                                  ),
                                ],
                              )
                            : Text(
                                '${_completed.length} z ${exerciseDefinitions.length} ćwiczeń oznaczone jako wykonane',
                                key: const ValueKey<String>(
                                  'flow-progress-active',
                                ),
                                style: theme.textTheme.bodyMedium?.copyWith(
                                  color: palette.heroMutedText,
                                ),
                              ),
                      ),
                      if (_completedCyclesToday > 0) ...<Widget>[
                        const SizedBox(height: 8),
                        Text(
                          'Dzisiaj ukończono już $_completedCyclesToday ${_formatFlowProgressCountLabel(_completedCyclesToday)}.',
                          style: theme.textTheme.bodyMedium?.copyWith(
                            color: palette.heroMutedText,
                          ),
                        ),
                      ],
                      if (_progressComplete) ...<Widget>[
                        const SizedBox(height: 14),
                        FilledButton.icon(
                          key: const ValueKey<String>(
                            'flow-progress-next-cycle',
                          ),
                          onPressed: _startNextProgressCycle,
                          style: FilledButton.styleFrom(
                            backgroundColor: palette.success,
                            foregroundColor: palette.onSuccess,
                          ),
                          icon: const Icon(Icons.replay_rounded),
                          label: const Text('Rozpocznij kolejny progres'),
                        ),
                      ],
                    ],
                  ),
                ),
                const SizedBox(height: 18),
                SurfaceCard(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: <Widget>[
                      AnimatedSize(
                        duration: const Duration(milliseconds: 180),
                        curve: Curves.easeOut,
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: <Widget>[
                            Material(
                              color: Colors.transparent,
                              child: InkWell(
                                key: const ValueKey<String>(
                                  'flow-calendar-toggle',
                                ),
                                onTap: _toggleCalendarExpanded,
                                borderRadius: BorderRadius.circular(20),
                                child: Padding(
                                  padding: const EdgeInsets.symmetric(
                                    vertical: 2,
                                  ),
                                  child: Column(
                                    crossAxisAlignment:
                                        CrossAxisAlignment.start,
                                    children: <Widget>[
                                      const SectionHeader(
                                        eyebrow: 'Historia dnia',
                                        title: 'Kalendarz progresu',
                                      ),
                                      const SizedBox(height: 8),
                                      Text(
                                        calendarSummary,
                                        style: theme.textTheme.bodyMedium
                                            ?.copyWith(
                                              color: palette.secondaryText,
                                              height: 1.45,
                                            ),
                                      ),
                                    ],
                                  ),
                                ),
                              ),
                            ),
                            if (_calendarExpanded) ...<Widget>[
                              const SizedBox(height: 18),
                              Row(
                                children: <Widget>[
                                  IconButton(
                                    onPressed: () => _changeCalendarMonth(-1),
                                    icon: const Icon(
                                      Icons.chevron_left_rounded,
                                    ),
                                    tooltip: 'Poprzedni miesiąc',
                                  ),
                                  Expanded(
                                    child: Text(
                                      _formatFlowMonthYearLabel(
                                        _visibleCalendarMonth,
                                      ),
                                      textAlign: TextAlign.center,
                                      style: theme.textTheme.titleMedium
                                          ?.copyWith(
                                            color: palette.primaryText,
                                            fontWeight: FontWeight.w800,
                                          ),
                                    ),
                                  ),
                                  IconButton(
                                    onPressed: () => _changeCalendarMonth(1),
                                    icon: const Icon(
                                      Icons.chevron_right_rounded,
                                    ),
                                    tooltip: 'Następny miesiąc',
                                  ),
                                ],
                              ),
                              const SizedBox(height: 10),
                              Row(
                                children: _flowWeekdayLabels
                                    .map(
                                      (label) => Expanded(
                                        child: Text(
                                          label,
                                          textAlign: TextAlign.center,
                                          style: theme.textTheme.labelMedium
                                              ?.copyWith(
                                                color: palette.tertiaryText,
                                                fontWeight: FontWeight.w800,
                                              ),
                                        ),
                                      ),
                                    )
                                    .toList(),
                              ),
                              const SizedBox(height: 10),
                              GridView.builder(
                                shrinkWrap: true,
                                physics: const NeverScrollableScrollPhysics(),
                                itemCount: calendarDays.length,
                                gridDelegate:
                                    const SliverGridDelegateWithFixedCrossAxisCount(
                                      crossAxisCount: 7,
                                      mainAxisSpacing: 8,
                                      crossAxisSpacing: 4,
                                      childAspectRatio: 0.8,
                                    ),
                                itemBuilder: (BuildContext context, int index) {
                                  final day = calendarDays[index];
                                  if (day == null) {
                                    return const SizedBox.shrink();
                                  }

                                  final dateKey = _dateKeyFor(day);
                                  final count =
                                      progressCountByDate[dateKey] ?? 0;

                                  return _FlowCalendarDayTile(
                                    key: ValueKey<String>(
                                      'flow-calendar-day-$dateKey',
                                    ),
                                    dayNumber: day.day,
                                    count: count,
                                    selected: selectedDateKey == dateKey,
                                    today: dateKey == _todayKey,
                                    onTap: () => _selectCalendarDate(day),
                                  );
                                },
                              ),
                              const SizedBox(height: 16),
                              Text(
                                _formatFlowLongDateLabel(selectedDateKey),
                                style: theme.textTheme.titleMedium?.copyWith(
                                  color: palette.primaryText,
                                  fontWeight: FontWeight.w800,
                                ),
                              ),
                              const SizedBox(height: 6),
                              if (selectedEntries.isEmpty) ...<Widget>[
                                Text(
                                  'Brak zapisów dla tego dnia.',
                                  style: theme.textTheme.bodyMedium?.copyWith(
                                    color: palette.secondaryText,
                                    height: 1.45,
                                  ),
                                ),
                                const SizedBox(height: 14),
                              ],
                              if (selectedEntries.isEmpty)
                                Container(
                                  width: double.infinity,
                                  padding: const EdgeInsets.all(16),
                                  decoration: BoxDecoration(
                                    color: palette.surfaceMuted,
                                    borderRadius: BorderRadius.circular(20),
                                  ),
                                  child: Text(
                                    'Ten dzień nie ma jeszcze zapisanych aktywności.',
                                    style: theme.textTheme.bodyMedium?.copyWith(
                                      color: palette.tertiaryText,
                                    ),
                                  ),
                                )
                              else ...<Widget>[
                                for (
                                  var index = 0;
                                  index < selectedEntries.length;
                                  index++
                                )
                                  Padding(
                                    padding: EdgeInsets.only(
                                      bottom:
                                          index == selectedEntries.length - 1
                                          ? 0
                                          : 10,
                                    ),
                                    child: _FlowSavedProgressTile(
                                      key: ValueKey<String>(
                                        'flow-progress-record-${selectedEntries[index].id}',
                                      ),
                                      label:
                                          selectedEntries[index].calendarLabel,
                                      subtitle:
                                          'Zapisano o ${_formatSessionTimeLabel(selectedEntries[index].completedAtIso)}',
                                      onLongPress: () => _deleteSavedProgress(
                                        selectedEntries[index],
                                      ),
                                    ),
                                  ),
                              ],
                            ],
                          ],
                        ),
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: 18),
                SurfaceCard(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: <Widget>[
                      const SectionHeader(
                        eyebrow: 'Plan dnia',
                        title: 'Krótka ścieżka wejścia w rytm',
                      ),
                      const SizedBox(height: 18),
                      const DailyRoutineStep(
                        title: '1. Punkt centralny',
                        details:
                            'Zacznij od spokojnej fiksacji wzroku i wyciszenia bodźców.',
                      ),
                      const SizedBox(height: 12),
                      const DailyRoutineStep(
                        title: '2. Skan koncentracji',
                        details:
                            'Krótki test selektywnej uwagi i szybkiej decyzji.',
                      ),
                      const SizedBox(height: 12),
                      const DailyRoutineStep(
                        title: '3. Dalszy trening',
                        details:
                            'Pulse Sync, Sprint Czytania albo Drabina Pamięci.',
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: 18),
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 4),
                  child: Text(
                    'Mini-gry',
                    style: theme.textTheme.headlineMedium?.copyWith(
                      color: palette.heroText,
                    ),
                  ),
                ),
                const SizedBox(height: 10),
                Text(
                  'Każda sesja ma prostą instrukcję, krótki czas i jeden konkretny efekt dla skupienia.',
                  style: theme.textTheme.bodyLarge?.copyWith(
                    color: palette.heroMutedText,
                  ),
                ),
                const SizedBox(height: 16),
                for (final exercise in exerciseDefinitions) ...<Widget>[
                  ExercisePreviewCard(
                    definition: exercise,
                    isCompleted: _completed.contains(exercise.kind),
                    onOpen: () {
                      Navigator.of(context).push(
                        MaterialPageRoute<void>(
                          builder: (BuildContext context) {
                            return ExerciseDetailPage(
                              definition: exercise,
                              initialCompleted: _completed.contains(
                                exercise.kind,
                              ),
                              onCompletionChanged: (bool completed) {
                                _updateCompletion(exercise.kind, completed);
                              },
                            );
                          },
                        ),
                      );
                    },
                  ),
                  const SizedBox(height: 14),
                ],
                _GoldenCrownCard(onUnlocked: _showGoldenSecretScaffold),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _MindeIdeaCategory {
  const _MindeIdeaCategory({
    required this.id,
    required this.name,
    required this.createdAtIso,
  });

  final String id;
  final String name;
  final String createdAtIso;

  Map<String, dynamic> toJson() => <String, dynamic>{
    'id': id,
    'name': name,
    'createdAtIso': createdAtIso,
  };

  factory _MindeIdeaCategory.fromJson(Map<String, dynamic> json) {
    final id = json['id'];
    final name = json['name'];
    final createdAtIso = json['createdAtIso'];

    if (id is! String || name is! String || createdAtIso is! String) {
      throw const FormatException('Invalid Minde idea category.');
    }

    return _MindeIdeaCategory(id: id, name: name, createdAtIso: createdAtIso);
  }
}

class _MindeIdeaNote {
  const _MindeIdeaNote({
    required this.id,
    required this.categoryId,
    required this.topic,
    required this.content,
    required this.createdAtIso,
    required this.updatedAtIso,
  });

  final String id;
  final String categoryId;
  final String topic;
  final String content;
  final String createdAtIso;
  final String updatedAtIso;

  Map<String, dynamic> toJson() => <String, dynamic>{
    'id': id,
    'categoryId': categoryId,
    'topic': topic,
    'content': content,
    'createdAtIso': createdAtIso,
    'updatedAtIso': updatedAtIso,
  };

  _MindeIdeaNote copyWith({
    String? id,
    String? categoryId,
    String? topic,
    String? content,
    String? createdAtIso,
    String? updatedAtIso,
  }) {
    return _MindeIdeaNote(
      id: id ?? this.id,
      categoryId: categoryId ?? this.categoryId,
      topic: topic ?? this.topic,
      content: content ?? this.content,
      createdAtIso: createdAtIso ?? this.createdAtIso,
      updatedAtIso: updatedAtIso ?? this.updatedAtIso,
    );
  }

  factory _MindeIdeaNote.fromJson(Map<String, dynamic> json) {
    final id = json['id'];
    final categoryId = json['categoryId'];
    final topic = json['topic'];
    final content = json['content'];
    final createdAtIso = json['createdAtIso'];
    final updatedAtIso = json['updatedAtIso'];

    if (id is! String ||
        categoryId is! String ||
        topic is! String ||
        content is! String ||
        createdAtIso is! String ||
        updatedAtIso is! String) {
      throw const FormatException('Invalid Minde idea note.');
    }

    return _MindeIdeaNote(
      id: id,
      categoryId: categoryId,
      topic: topic,
      content: content,
      createdAtIso: createdAtIso,
      updatedAtIso: updatedAtIso,
    );
  }
}

class _MindeIdeasSnapshot {
  const _MindeIdeasSnapshot({
    required this.categories,
    required this.notes,
    this.selectedCategoryId,
  });

  final List<_MindeIdeaCategory> categories;
  final List<_MindeIdeaNote> notes;
  final String? selectedCategoryId;

  Map<String, dynamic> toJson() => <String, dynamic>{
    'categories': categories
        .map((_MindeIdeaCategory category) => category.toJson())
        .toList(),
    'notes': notes.map((_MindeIdeaNote note) => note.toJson()).toList(),
    if (selectedCategoryId != null) 'selectedCategoryId': selectedCategoryId,
  };

  factory _MindeIdeasSnapshot.fromJson(Map<String, dynamic> json) {
    final rawCategories = json['categories'];
    final rawNotes = json['notes'];
    final selectedCategoryId = json['selectedCategoryId'];

    if (rawCategories is! List<dynamic> || rawNotes is! List<dynamic>) {
      throw const FormatException('Invalid Minde ideas snapshot.');
    }

    final categories = <_MindeIdeaCategory>[];
    for (final item in rawCategories) {
      if (item is! Map<dynamic, dynamic>) {
        continue;
      }
      try {
        categories.add(
          _MindeIdeaCategory.fromJson(Map<String, dynamic>.from(item)),
        );
      } on FormatException {
        continue;
      }
    }

    final notes = <_MindeIdeaNote>[];
    for (final item in rawNotes) {
      if (item is! Map<dynamic, dynamic>) {
        continue;
      }
      try {
        notes.add(_MindeIdeaNote.fromJson(Map<String, dynamic>.from(item)));
      } on FormatException {
        continue;
      }
    }

    return _MindeIdeasSnapshot(
      categories: categories,
      notes: notes,
      selectedCategoryId: selectedCategoryId is String
          ? selectedCategoryId
          : null,
    );
  }
}

enum _MindeCategoryAction { edit, moveUp, moveDown, delete }

class _MindeIdeaEditorResult {
  const _MindeIdeaEditorResult({required this.topic, required this.content});

  final String topic;
  final String content;
}

class _MindeIdeaEditorPage extends StatefulWidget {
  const _MindeIdeaEditorPage({this.note});

  final _MindeIdeaNote? note;

  @override
  State<_MindeIdeaEditorPage> createState() => _MindeIdeaEditorPageState();
}

class _MindeIdeaEditorPageState extends State<_MindeIdeaEditorPage> {
  late final TextEditingController _topicController;
  late final TextEditingController _contentController;

  String get _topicText => _topicController.text.trim();
  String get _contentText => _contentController.text.trim();
  bool get _canSave => _topicText.isNotEmpty || _contentText.isNotEmpty;

  @override
  void initState() {
    super.initState();
    _topicController = TextEditingController(text: widget.note?.topic ?? '');
    _contentController = TextEditingController(
      text: widget.note?.content ?? '',
    );
  }

  void _submit() {
    if (!_canSave) {
      return;
    }
    Navigator.of(
      context,
    ).pop(_MindeIdeaEditorResult(topic: _topicText, content: _contentText));
  }

  @override
  void dispose() {
    _topicController.dispose();
    _contentController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final palette = context.appPalette;

    return Scaffold(
      extendBodyBehindAppBar: true,
      appBar: AppBar(
        backgroundColor: Colors.transparent,
        foregroundColor: palette.heroText,
        elevation: 0,
        title: const Text('Notatka'),
        actions: <Widget>[
          IconButton(
            key: const ValueKey<String>('minde-note-save'),
            onPressed: _canSave ? _submit : null,
            icon: const Icon(Icons.check_rounded),
          ),
        ],
      ),
      body: Stack(
        children: <Widget>[
          const AppBackdrop(),
          SafeArea(
            child: Padding(
              padding: const EdgeInsets.fromLTRB(20, 76, 20, 24),
              child: Container(
                width: double.infinity,
                padding: const EdgeInsets.fromLTRB(18, 18, 18, 12),
                decoration: BoxDecoration(
                  color: palette.surfaceStrong.withValues(alpha: 0.92),
                  borderRadius: BorderRadius.circular(26),
                ),
                child: Column(
                  children: <Widget>[
                    TextField(
                      key: const ValueKey<String>('minde-note-topic-input'),
                      controller: _topicController,
                      onChanged: (_) => setState(() {}),
                      style: theme.textTheme.headlineSmall?.copyWith(
                        color: palette.primaryText,
                        fontWeight: FontWeight.w800,
                      ),
                      decoration: InputDecoration(
                        hintText: 'Temat',
                        hintStyle: theme.textTheme.headlineSmall?.copyWith(
                          color: palette.secondaryText,
                          fontWeight: FontWeight.w700,
                        ),
                        border: InputBorder.none,
                        contentPadding: EdgeInsets.zero,
                      ),
                    ),
                    Divider(height: 20, color: palette.surfaceBorder),
                    Expanded(
                      child: TextField(
                        key: const ValueKey<String>('minde-note-content-input'),
                        controller: _contentController,
                        onChanged: (_) => setState(() {}),
                        expands: true,
                        maxLines: null,
                        minLines: null,
                        textAlignVertical: TextAlignVertical.top,
                        style: theme.textTheme.bodyLarge?.copyWith(
                          color: palette.primaryText,
                          height: 1.55,
                        ),
                        decoration: InputDecoration(
                          hintText: '...',
                          hintStyle: theme.textTheme.bodyLarge?.copyWith(
                            color: palette.secondaryText,
                            height: 1.55,
                          ),
                          border: InputBorder.none,
                          contentPadding: EdgeInsets.zero,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class MindeIdeasPage extends StatefulWidget {
  const MindeIdeasPage({super.key});

  @override
  State<MindeIdeasPage> createState() => _MindeIdeasPageState();
}

class _MindeIdeasPageState extends State<MindeIdeasPage> {
  static const String _storageKey = 'minde_ideas_notes_v1';
  static const String _legacyCategoryId = 'legacy-default';

  final TextEditingController _categoryController = TextEditingController();
  final FocusNode _categoryFocusNode = FocusNode();

  List<_MindeIdeaCategory> _categories = <_MindeIdeaCategory>[];
  List<_MindeIdeaNote> _notes = <_MindeIdeaNote>[];
  String? _selectedCategoryId;
  bool _loading = true;
  bool _showCategoryComposer = false;

  String get _categoryDraft => _categoryController.text.trim();

  _MindeIdeaCategory? get _selectedCategory {
    final selectedCategoryId = _selectedCategoryId;
    if (selectedCategoryId == null) {
      return null;
    }
    for (final category in _categories) {
      if (category.id == selectedCategoryId) {
        return category;
      }
    }
    return null;
  }

  List<_MindeIdeaNote> get _selectedNotes {
    final selectedCategoryId = _selectedCategoryId;
    if (selectedCategoryId == null) {
      return <_MindeIdeaNote>[];
    }
    final notes =
        _notes
            .where(
              (_MindeIdeaNote note) => note.categoryId == selectedCategoryId,
            )
            .toList()
          ..sort(
            (_MindeIdeaNote a, _MindeIdeaNote b) =>
                b.updatedAtIso.compareTo(a.updatedAtIso),
          );
    return notes;
  }

  @override
  void initState() {
    super.initState();
    _loadIdeas();
  }

  Future<void> _loadIdeas() async {
    final preferences = await SharedPreferences.getInstance();
    final rawData = preferences.getString(_storageKey);
    final snapshot = _decodeStoredIdeas(rawData);

    if (!mounted) {
      return;
    }

    setState(() {
      _categories = snapshot.categories;
      _notes = snapshot.notes;
      _selectedCategoryId = snapshot.selectedCategoryId;
      _loading = false;
    });
  }

  _MindeIdeasSnapshot _decodeStoredIdeas(String? rawData) {
    if (rawData == null || rawData.isEmpty) {
      return const _MindeIdeasSnapshot(
        categories: <_MindeIdeaCategory>[],
        notes: <_MindeIdeaNote>[],
      );
    }

    try {
      final decoded = jsonDecode(rawData);
      if (decoded is List<dynamic>) {
        return _decodeLegacyIdeas(decoded);
      }
      if (decoded is! Map<String, dynamic>) {
        return const _MindeIdeasSnapshot(
          categories: <_MindeIdeaCategory>[],
          notes: <_MindeIdeaNote>[],
        );
      }

      final snapshot = _MindeIdeasSnapshot.fromJson(decoded);
      final categories = snapshot.categories.toList();
      final notes = snapshot.notes.toList()
        ..sort(
          (_MindeIdeaNote a, _MindeIdeaNote b) =>
              b.updatedAtIso.compareTo(a.updatedAtIso),
        );
      final selectedCategoryId =
          snapshot.selectedCategoryId != null &&
              categories.any(
                (_MindeIdeaCategory category) =>
                    category.id == snapshot.selectedCategoryId,
              )
          ? snapshot.selectedCategoryId
          : categories.isEmpty
          ? null
          : categories.first.id;

      return _MindeIdeasSnapshot(
        categories: categories,
        notes: notes,
        selectedCategoryId: selectedCategoryId,
      );
    } on FormatException {
      return const _MindeIdeasSnapshot(
        categories: <_MindeIdeaCategory>[],
        notes: <_MindeIdeaNote>[],
      );
    }
  }

  _MindeIdeasSnapshot _decodeLegacyIdeas(List<dynamic> rawNotes) {
    final legacyNotes = <_MindeIdeaNote>[];
    for (final item in rawNotes) {
      if (item is! Map<dynamic, dynamic>) {
        continue;
      }
      final json = Map<String, dynamic>.from(item);
      final id = json['id'];
      final text = json['text'];
      final createdAtIso = json['createdAtIso'];
      final updatedAtIso = json['updatedAtIso'];
      if (id is! String ||
          text is! String ||
          createdAtIso is! String ||
          updatedAtIso is! String) {
        continue;
      }
      legacyNotes.add(
        _MindeIdeaNote(
          id: id,
          categoryId: _legacyCategoryId,
          topic: 'Pomysł',
          content: text,
          createdAtIso: createdAtIso,
          updatedAtIso: updatedAtIso,
        ),
      );
    }

    if (legacyNotes.isEmpty) {
      return const _MindeIdeasSnapshot(
        categories: <_MindeIdeaCategory>[],
        notes: <_MindeIdeaNote>[],
      );
    }

    legacyNotes.sort(
      (_MindeIdeaNote a, _MindeIdeaNote b) =>
          b.updatedAtIso.compareTo(a.updatedAtIso),
    );
    return _MindeIdeasSnapshot(
      categories: <_MindeIdeaCategory>[
        _MindeIdeaCategory(
          id: _legacyCategoryId,
          name: 'Pomysły',
          createdAtIso: legacyNotes.last.createdAtIso,
        ),
      ],
      notes: legacyNotes,
      selectedCategoryId: _legacyCategoryId,
    );
  }

  Future<void> _persistIdeas() async {
    final preferences = await SharedPreferences.getInstance();
    final snapshot = _MindeIdeasSnapshot(
      categories: _categories,
      notes: _notes,
      selectedCategoryId: _selectedCategoryId,
    );
    await preferences.setString(_storageKey, jsonEncode(snapshot.toJson()));
  }

  void _showIdeasSnackBar(String message) {
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(message)));
  }

  void _openCategoryComposer() {
    if (_showCategoryComposer) {
      return;
    }
    setState(() {
      _showCategoryComposer = true;
    });
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) {
        _categoryFocusNode.requestFocus();
      }
    });
  }

  void _closeCategoryComposer() {
    setState(() {
      _showCategoryComposer = false;
      _categoryController.clear();
    });
    _categoryFocusNode.unfocus();
  }

  void _toggleCategoryComposer() {
    if (_showCategoryComposer) {
      _closeCategoryComposer();
      return;
    }
    _openCategoryComposer();
  }

  bool _categoryNameExists(
    String candidateName, {
    String? excludingCategoryId,
  }) {
    final normalizedCandidate = candidateName.trim().toLowerCase();
    if (normalizedCandidate.isEmpty) {
      return false;
    }
    for (final category in _categories) {
      if (category.id == excludingCategoryId) {
        continue;
      }
      if (category.name.trim().toLowerCase() == normalizedCandidate) {
        return true;
      }
    }
    return false;
  }

  Future<void> _addCategory() async {
    final categoryName = _categoryDraft;
    if (categoryName.isEmpty) {
      return;
    }

    for (final category in _categories) {
      if (category.name.trim().toLowerCase() == categoryName.toLowerCase()) {
        setState(() {
          _selectedCategoryId = category.id;
        });
        _closeCategoryComposer();
        await _persistIdeas();
        if (!mounted) {
          return;
        }
        _showIdeasSnackBar('Taka kategoria już istnieje.');
        return;
      }
    }

    final nowIso = DateTime.now().toIso8601String();
    final category = _MindeIdeaCategory(
      id: nowIso,
      name: categoryName,
      createdAtIso: nowIso,
    );
    final updatedCategories = <_MindeIdeaCategory>[..._categories, category];

    setState(() {
      _categories = updatedCategories;
      _selectedCategoryId = category.id;
    });
    _closeCategoryComposer();
    await _persistIdeas();
  }

  Future<void> _selectCategory(String categoryId) async {
    setState(() {
      _selectedCategoryId = categoryId;
    });
    await _persistIdeas();
  }

  Future<_MindeCategoryAction?> _showCategoryActions(
    _MindeIdeaCategory category,
  ) {
    final palette = context.appPalette;
    final categoryIndex = _categories.indexWhere(
      (_MindeIdeaCategory candidate) => candidate.id == category.id,
    );
    final canMoveUp = categoryIndex > 0;
    final canMoveDown =
        categoryIndex >= 0 && categoryIndex < _categories.length - 1;
    return showModalBottomSheet<_MindeCategoryAction>(
      context: context,
      backgroundColor: palette.surfaceStrong,
      showDragHandle: true,
      builder: (BuildContext context) {
        return SafeArea(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(20, 8, 20, 24),
            child: SingleChildScrollView(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: <Widget>[
                  ListTile(
                    key: const ValueKey<String>('minde-category-action-edit'),
                    leading: const Icon(Icons.edit_rounded),
                    title: const Text('Edytuj nazwę'),
                    subtitle: Text(category.name),
                    onTap: () =>
                        Navigator.of(context).pop(_MindeCategoryAction.edit),
                  ),
                  ListTile(
                    key: const ValueKey<String>(
                      'minde-category-action-move-up',
                    ),
                    leading: const Icon(Icons.keyboard_arrow_up_rounded),
                    title: const Text('Przesuń wyżej'),
                    onTap: canMoveUp
                        ? () => Navigator.of(
                            context,
                          ).pop(_MindeCategoryAction.moveUp)
                        : null,
                  ),
                  ListTile(
                    key: const ValueKey<String>(
                      'minde-category-action-move-down',
                    ),
                    leading: const Icon(Icons.keyboard_arrow_down_rounded),
                    title: const Text('Przesuń niżej'),
                    onTap: canMoveDown
                        ? () => Navigator.of(
                            context,
                          ).pop(_MindeCategoryAction.moveDown)
                        : null,
                  ),
                  ListTile(
                    key: const ValueKey<String>('minde-category-action-delete'),
                    leading: const Icon(Icons.delete_outline_rounded),
                    title: const Text('Usuń'),
                    subtitle: const Text(
                      'Usuń kategorię wraz z przypisanymi notatkami.',
                    ),
                    onTap: () =>
                        Navigator.of(context).pop(_MindeCategoryAction.delete),
                  ),
                ],
              ),
            ),
          ),
        );
      },
    );
  }

  Future<void> _handleCategoryLongPress(_MindeIdeaCategory category) async {
    final action = await _showCategoryActions(category);
    if (action == null || !mounted) {
      return;
    }

    switch (action) {
      case _MindeCategoryAction.edit:
        await _renameCategory(category);
        break;
      case _MindeCategoryAction.moveUp:
        await _moveCategory(category, -1);
        break;
      case _MindeCategoryAction.moveDown:
        await _moveCategory(category, 1);
        break;
      case _MindeCategoryAction.delete:
        await _deleteCategory(category);
        break;
    }
  }

  Future<void> _moveCategory(_MindeIdeaCategory category, int direction) async {
    final currentIndex = _categories.indexWhere(
      (_MindeIdeaCategory candidate) => candidate.id == category.id,
    );
    if (currentIndex < 0) {
      return;
    }
    final targetIndex = currentIndex + direction;
    if (targetIndex < 0 || targetIndex >= _categories.length) {
      return;
    }

    final updatedCategories = <_MindeIdeaCategory>[..._categories];
    final movedCategory = updatedCategories.removeAt(currentIndex);
    updatedCategories.insert(targetIndex, movedCategory);

    setState(() {
      _categories = updatedCategories;
    });
    await _persistIdeas();
  }

  Future<void> _renameCategory(_MindeIdeaCategory category) async {
    final TextEditingController controller = TextEditingController(
      text: category.name,
    );
    String draftName = category.name;

    final nextName = await showDialog<String>(
      context: context,
      builder: (BuildContext context) {
        return StatefulBuilder(
          builder: (BuildContext context, StateSetter setDialogState) {
            final trimmedDraft = draftName.trim();
            final canSave =
                trimmedDraft.isNotEmpty &&
                !_categoryNameExists(
                  trimmedDraft,
                  excludingCategoryId: category.id,
                );
            return AlertDialog(
              title: const Text('Edytuj nazwę'),
              content: TextField(
                key: const ValueKey<String>('minde-category-edit-input'),
                controller: controller,
                autofocus: true,
                onChanged: (String value) {
                  setDialogState(() {
                    draftName = value;
                  });
                },
                decoration: const InputDecoration(hintText: 'Nazwa kategorii'),
              ),
              actions: <Widget>[
                TextButton(
                  onPressed: () => Navigator.of(context).pop(),
                  child: const Text('Anuluj'),
                ),
                FilledButton(
                  key: const ValueKey<String>('minde-category-edit-save'),
                  onPressed: canSave
                      ? () => Navigator.of(context).pop(trimmedDraft)
                      : null,
                  child: const Text('Zapisz'),
                ),
              ],
            );
          },
        );
      },
    );

    if (nextName == null || nextName == category.name) {
      return;
    }

    final updatedCategories = _categories
        .map(
          (_MindeIdeaCategory candidate) => candidate.id == category.id
              ? _MindeIdeaCategory(
                  id: candidate.id,
                  name: nextName,
                  createdAtIso: candidate.createdAtIso,
                )
              : candidate,
        )
        .toList();

    setState(() {
      _categories = updatedCategories;
    });
    await _persistIdeas();

    if (!mounted) {
      return;
    }
    _showIdeasSnackBar('Nazwa kategorii została zmieniona.');
  }

  Future<void> _deleteCategory(_MindeIdeaCategory category) async {
    final notesInCategory = _notes
        .where((_MindeIdeaNote note) => note.categoryId == category.id)
        .length;
    final shouldDelete = await showDialog<bool>(
      context: context,
      builder: (BuildContext context) {
        return AlertDialog(
          title: const Text('Usunąć kategorię?'),
          content: Text(
            notesInCategory == 0
                ? 'Kategoria "${category.name}" zostanie usunięta.'
                : 'Kategoria "${category.name}" oraz $notesInCategory ${_memoryPluralLabel(notesInCategory, singular: 'notatka', paucal: 'notatki', plural: 'notatek')} zostaną usunięte.',
          ),
          actions: <Widget>[
            TextButton(
              onPressed: () => Navigator.of(context).pop(false),
              child: const Text('Anuluj'),
            ),
            FilledButton(
              key: const ValueKey<String>('minde-category-delete-confirm'),
              onPressed: () => Navigator.of(context).pop(true),
              child: const Text('Usuń'),
            ),
          ],
        );
      },
    );

    if (shouldDelete != true) {
      return;
    }

    final updatedCategories = _categories
        .where((_MindeIdeaCategory candidate) => candidate.id != category.id)
        .toList();
    final updatedNotes =
        _notes
            .where((_MindeIdeaNote note) => note.categoryId != category.id)
            .toList()
          ..sort(
            (_MindeIdeaNote a, _MindeIdeaNote b) =>
                b.updatedAtIso.compareTo(a.updatedAtIso),
          );
    final nextSelectedCategoryId = _selectedCategoryId == category.id
        ? (updatedCategories.isEmpty ? null : updatedCategories.first.id)
        : _selectedCategoryId;

    setState(() {
      _categories = updatedCategories;
      _notes = updatedNotes;
      _selectedCategoryId = nextSelectedCategoryId;
    });
    await _persistIdeas();

    if (!mounted) {
      return;
    }
    _showIdeasSnackBar('Kategoria została usunięta.');
  }

  Future<void> _openNoteEditor({_MindeIdeaNote? note}) async {
    if (_selectedCategoryId == null && note == null) {
      _openCategoryComposer();
      _showIdeasSnackBar('Najpierw dodaj kategorię.');
      return;
    }

    final result = await Navigator.of(context).push<_MindeIdeaEditorResult>(
      _buildExerciseSessionRoute<_MindeIdeaEditorResult>(
        builder: (BuildContext context) {
          return _MindeIdeaEditorPage(note: note);
        },
      ),
    );

    if (result == null) {
      return;
    }

    final nowIso = DateTime.now().toIso8601String();
    final updatedNotes = note == null
        ? <_MindeIdeaNote>[
            _MindeIdeaNote(
              id: nowIso,
              categoryId: _selectedCategoryId!,
              topic: result.topic,
              content: result.content,
              createdAtIso: nowIso,
              updatedAtIso: nowIso,
            ),
            ..._notes,
          ]
        : _notes
              .map(
                (_MindeIdeaNote candidate) => candidate.id == note.id
                    ? candidate.copyWith(
                        topic: result.topic,
                        content: result.content,
                        updatedAtIso: nowIso,
                      )
                    : candidate,
              )
              .toList();

    updatedNotes.sort(
      (_MindeIdeaNote a, _MindeIdeaNote b) =>
          b.updatedAtIso.compareTo(a.updatedAtIso),
    );

    setState(() {
      _notes = updatedNotes;
      if (note != null) {
        _selectedCategoryId = note.categoryId;
      }
    });
    await _persistIdeas();
  }

  Future<void> _deleteNote(_MindeIdeaNote note) async {
    final shouldDelete = await showDialog<bool>(
      context: context,
      builder: (BuildContext context) {
        return AlertDialog(
          title: const Text('Usunąć notatkę?'),
          content: const Text('Ta notatka zostanie trwale usunięta.'),
          actions: <Widget>[
            TextButton(
              onPressed: () => Navigator.of(context).pop(false),
              child: const Text('Anuluj'),
            ),
            FilledButton(
              onPressed: () => Navigator.of(context).pop(true),
              child: const Text('Usuń'),
            ),
          ],
        );
      },
    );

    if (shouldDelete != true) {
      return;
    }

    final updatedNotes =
        _notes
            .where((_MindeIdeaNote candidate) => candidate.id != note.id)
            .toList()
          ..sort(
            (_MindeIdeaNote a, _MindeIdeaNote b) =>
                b.updatedAtIso.compareTo(a.updatedAtIso),
          );

    setState(() {
      _notes = updatedNotes;
    });
    await _persistIdeas();

    if (!mounted) {
      return;
    }
    _showIdeasSnackBar('Notatka została usunięta.');
  }

  @override
  void dispose() {
    _categoryController.dispose();
    _categoryFocusNode.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final palette = context.appPalette;
    final selectedCategory = _selectedCategory;
    final selectedNotes = _selectedNotes;

    return Scaffold(
      extendBodyBehindAppBar: true,
      appBar: AppBar(
        backgroundColor: Colors.transparent,
        foregroundColor: palette.heroText,
        elevation: 0,
        centerTitle: true,
        title: InkWell(
          key: const ValueKey<String>('minde-ideas-category-toggle'),
          onTap: _toggleCategoryComposer,
          borderRadius: BorderRadius.circular(999),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: <Widget>[
                const Icon(Icons.notes_rounded, size: 22),
                const SizedBox(width: 8),
                ConstrainedBox(
                  constraints: const BoxConstraints(maxWidth: 220),
                  child: Text(
                    selectedCategory?.name ?? 'Nootatki',
                    overflow: TextOverflow.ellipsis,
                    style: theme.textTheme.titleMedium?.copyWith(
                      color: palette.heroText,
                      fontWeight: FontWeight.w800,
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
      floatingActionButton: FloatingActionButton(
        key: const ValueKey<String>('minde-note-create'),
        onPressed: _loading ? null : _openNoteEditor,
        child: const Icon(Icons.add_rounded),
      ),
      body: Stack(
        children: <Widget>[
          const AppBackdrop(),
          SafeArea(
            child: Column(
              children: <Widget>[
                const SizedBox(height: 72),
                Padding(
                  padding: const EdgeInsets.fromLTRB(20, 0, 20, 0),
                  child: AnimatedSize(
                    duration: const Duration(milliseconds: 220),
                    child: _showCategoryComposer
                        ? Container(
                            key: const ValueKey<String>(
                              'minde-category-composer',
                            ),
                            width: double.infinity,
                            margin: const EdgeInsets.only(bottom: 16),
                            padding: const EdgeInsets.all(14),
                            decoration: BoxDecoration(
                              color: palette.surfaceStrong.withValues(
                                alpha: 0.96,
                              ),
                              borderRadius: BorderRadius.circular(22),
                              border: Border.all(color: palette.surfaceBorder),
                            ),
                            child: Row(
                              children: <Widget>[
                                Expanded(
                                  child: TextField(
                                    key: const ValueKey<String>(
                                      'minde-category-input',
                                    ),
                                    controller: _categoryController,
                                    focusNode: _categoryFocusNode,
                                    onChanged: (_) => setState(() {}),
                                    decoration: InputDecoration(
                                      hintText: 'Nazwa kategorii',
                                      filled: true,
                                      fillColor: palette.surface,
                                      border: OutlineInputBorder(
                                        borderRadius: BorderRadius.circular(18),
                                        borderSide: BorderSide(
                                          color: palette.surfaceBorder,
                                        ),
                                      ),
                                      enabledBorder: OutlineInputBorder(
                                        borderRadius: BorderRadius.circular(18),
                                        borderSide: BorderSide(
                                          color: palette.surfaceBorder,
                                        ),
                                      ),
                                      focusedBorder: OutlineInputBorder(
                                        borderRadius: BorderRadius.circular(18),
                                        borderSide: BorderSide(
                                          color: palette.primaryButton,
                                        ),
                                      ),
                                    ),
                                  ),
                                ),
                                const SizedBox(width: 12),
                                FilledButton(
                                  key: const ValueKey<String>(
                                    'minde-category-add',
                                  ),
                                  onPressed: _categoryDraft.isEmpty
                                      ? null
                                      : _addCategory,
                                  child: const Text('Dodaj'),
                                ),
                              ],
                            ),
                          )
                        : const SizedBox.shrink(),
                  ),
                ),
                Expanded(
                  child: _loading
                      ? const Center(child: CircularProgressIndicator())
                      : ListView(
                          padding: const EdgeInsets.fromLTRB(20, 0, 20, 28),
                          children: <Widget>[
                            if (_categories.isEmpty)
                              const SizedBox.shrink()
                            else
                              Column(
                                children: _categories
                                    .map(
                                      (_MindeIdeaCategory category) => Padding(
                                        padding: const EdgeInsets.only(
                                          bottom: 12,
                                        ),
                                        child: Material(
                                          color: Colors.transparent,
                                          child: InkWell(
                                            key: ValueKey<String>(
                                              'minde-category-${category.id}',
                                            ),
                                            borderRadius: BorderRadius.circular(
                                              22,
                                            ),
                                            onTap: () =>
                                                _selectCategory(category.id),
                                            onLongPress: () =>
                                                _handleCategoryLongPress(
                                                  category,
                                                ),
                                            child: Container(
                                              width: double.infinity,
                                              padding:
                                                  const EdgeInsets.symmetric(
                                                    horizontal: 18,
                                                    vertical: 18,
                                                  ),
                                              decoration: BoxDecoration(
                                                color:
                                                    category.id ==
                                                        _selectedCategoryId
                                                    ? palette.primaryButton
                                                          .withValues(
                                                            alpha: 0.16,
                                                          )
                                                    : palette.surfaceStrong
                                                          .withValues(
                                                            alpha: 0.94,
                                                          ),
                                                borderRadius:
                                                    BorderRadius.circular(22),
                                                border: Border.all(
                                                  color:
                                                      category.id ==
                                                          _selectedCategoryId
                                                      ? palette.primaryButton
                                                      : palette.surfaceBorder,
                                                ),
                                              ),
                                              child: Row(
                                                children: <Widget>[
                                                  Expanded(
                                                    child: Text(
                                                      category.name,
                                                      style: theme
                                                          .textTheme
                                                          .titleMedium
                                                          ?.copyWith(
                                                            color: palette
                                                                .primaryText,
                                                            fontWeight:
                                                                FontWeight.w900,
                                                          ),
                                                    ),
                                                  ),
                                                  const SizedBox(width: 12),
                                                  Text(
                                                    '${_notes.where((_MindeIdeaNote note) => note.categoryId == category.id).length}',
                                                    style: theme
                                                        .textTheme
                                                        .labelLarge
                                                        ?.copyWith(
                                                          color:
                                                              category.id ==
                                                                  _selectedCategoryId
                                                              ? palette
                                                                    .primaryButton
                                                              : palette
                                                                    .secondaryText,
                                                          fontWeight:
                                                              FontWeight.w800,
                                                        ),
                                                  ),
                                                ],
                                              ),
                                            ),
                                          ),
                                        ),
                                      ),
                                    )
                                    .toList(),
                              ),
                            if (selectedCategory != null &&
                                selectedNotes.isNotEmpty) ...<Widget>[
                              const SizedBox(height: 8),
                              Column(
                                children: selectedNotes
                                    .map(
                                      (_MindeIdeaNote note) => Padding(
                                        padding: const EdgeInsets.only(
                                          bottom: 12,
                                        ),
                                        child: Material(
                                          color: Colors.transparent,
                                          child: InkWell(
                                            key: ValueKey<String>(
                                              'minde-note-card-${note.id}',
                                            ),
                                            borderRadius: BorderRadius.circular(
                                              22,
                                            ),
                                            onTap: () =>
                                                _openNoteEditor(note: note),
                                            onLongPress: () =>
                                                _deleteNote(note),
                                            child: Container(
                                              width: double.infinity,
                                              padding: const EdgeInsets.all(18),
                                              decoration: BoxDecoration(
                                                color: palette.surfaceStrong
                                                    .withValues(alpha: 0.94),
                                                borderRadius:
                                                    BorderRadius.circular(22),
                                                border: Border.all(
                                                  color: palette.surfaceBorder,
                                                ),
                                              ),
                                              child: Column(
                                                crossAxisAlignment:
                                                    CrossAxisAlignment.start,
                                                children: <Widget>[
                                                  Text(
                                                    note.topic.isEmpty
                                                        ? 'Bez tematu'
                                                        : note.topic,
                                                    style: theme
                                                        .textTheme
                                                        .titleMedium
                                                        ?.copyWith(
                                                          color: palette
                                                              .primaryText,
                                                          fontWeight:
                                                              FontWeight.w900,
                                                        ),
                                                  ),
                                                  const SizedBox(height: 6),
                                                  Text(
                                                    note.content,
                                                    style: theme
                                                        .textTheme
                                                        .bodyLarge
                                                        ?.copyWith(
                                                          color: palette
                                                              .primaryText,
                                                          height: 1.55,
                                                        ),
                                                  ),
                                                  const SizedBox(height: 12),
                                                  Text(
                                                    _formatSessionDateTimeLabel(
                                                      note.updatedAtIso,
                                                    ),
                                                    style: theme
                                                        .textTheme
                                                        .labelLarge
                                                        ?.copyWith(
                                                          color: palette
                                                              .secondaryText,
                                                          fontWeight:
                                                              FontWeight.w700,
                                                        ),
                                                  ),
                                                ],
                                              ),
                                            ),
                                          ),
                                        ),
                                      ),
                                    )
                                    .toList(),
                              ),
                            ],
                          ],
                        ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class ExerciseDetailPage extends StatefulWidget {
  const ExerciseDetailPage({
    super.key,
    required this.definition,
    required this.initialCompleted,
    required this.onCompletionChanged,
  });

  final ExerciseDefinition definition;
  final bool initialCompleted;
  final ValueChanged<bool> onCompletionChanged;

  @override
  State<ExerciseDetailPage> createState() => _ExerciseDetailPageState();
}

class _ExerciseDetailPageState extends State<ExerciseDetailPage> {
  late bool _completed;
  late _MemoryGameKind _selectedMemoryGame;
  late _MnemonicVaultGameKind _selectedMnemonicVaultGame;
  late PulseSyncLevel _selectedPulseSyncLevel;
  late SpeedReadLevel _selectedSpeedReadLevel;
  late FocusScanMode _selectedFocusScanMode;
  late int _selectedSplitDecisionLevelIndex;

  @override
  void initState() {
    super.initState();
    _completed = widget.initialCompleted;
    _selectedMemoryGame = _MemoryGameKind.chain;
    _selectedMnemonicVaultGame = _MnemonicVaultGameKind.recall;
    _selectedPulseSyncLevel = PulseSyncLevel.easy;
    _selectedSpeedReadLevel = SpeedReadLevel.one;
    _selectedFocusScanMode = FocusScanMode.basic;
    _selectedSplitDecisionLevelIndex = _splitDecisionGlobalLevelIndex;
  }

  void _completeAndReturn() {
    if (!_completed) {
      setState(() {
        _completed = true;
      });
      widget.onCompletionChanged(true);
    }

    Navigator.of(context).pop();
  }

  void _markCompletedFromTraining() {
    if (_completed) {
      return;
    }

    setState(() {
      _completed = true;
    });
    widget.onCompletionChanged(true);
  }

  void _handleFocusScanModeChanged(FocusScanMode mode) {
    if (_selectedFocusScanMode == mode) {
      return;
    }

    setState(() {
      _selectedFocusScanMode = mode;
    });
  }

  void _handlePulseSyncLevelChanged(PulseSyncLevel level) {
    if (_selectedPulseSyncLevel == level) {
      return;
    }

    setState(() {
      _selectedPulseSyncLevel = level;
    });
  }

  void _handleSpeedReadLevelChanged(SpeedReadLevel level) {
    if (_selectedSpeedReadLevel == level) {
      return;
    }

    setState(() {
      _selectedSpeedReadLevel = level;
    });
  }

  void _handleMemoryGameChanged(_MemoryGameKind kind) {
    if (_selectedMemoryGame == kind) {
      return;
    }

    setState(() {
      _selectedMemoryGame = kind;
    });
  }

  void _handleMnemonicVaultGameChanged(_MnemonicVaultGameKind kind) {
    if (_selectedMnemonicVaultGame == kind) {
      return;
    }

    setState(() {
      _selectedMnemonicVaultGame = kind;
    });
  }

  void _handleSplitDecisionLevelChanged(int index) {
    if (_selectedSplitDecisionLevelIndex == index) {
      return;
    }

    setState(() {
      _selectedSplitDecisionLevelIndex = index;
    });
    _splitDecisionGlobalLevelIndex = index;
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final palette = context.appPalette;
    final definition = widget.definition;
    final isMnemonicVault = definition.kind == ExerciseKind.mnemonicVault;
    final isMemoryChain = definition.kind == ExerciseKind.memoryChain;
    final isPulseSync = definition.kind == ExerciseKind.breathFlow;
    final isFlowRunner = definition.kind == ExerciseKind.flowRunner;
    final isSpeedRead = definition.kind == ExerciseKind.speedRead;
    final isFocusScan = definition.kind == ExerciseKind.focusScan;
    final isSplitDecision = definition.kind == ExerciseKind.splitDecision;
    final showInstructionBox =
        !isMnemonicVault &&
        definition.kind != ExerciseKind.focusDot &&
        !isMemoryChain &&
        !isPulseSync &&
        !isFlowRunner &&
        !isSpeedRead &&
        !isFocusScan &&
        !isSplitDecision;
    final purposeTitle = isMnemonicVault
        ? 'Co znajdziesz w boxie'
        : 'Co robi to ćwiczenie';
    final instructionTitle =
        definition.kind == ExerciseKind.splitDecision ||
            definition.kind == ExerciseKind.flowRunner
        ? 'Jak grać'
        : isMnemonicVault
        ? 'Jak korzystać'
        : 'Jak wykonać sesję';
    const trainerTitle = 'Uruchom grę';

    return Scaffold(
      extendBodyBehindAppBar: true,
      appBar: AppBar(
        backgroundColor: Colors.transparent,
        foregroundColor: palette.heroText,
        elevation: 0,
      ),
      body: Stack(
        children: <Widget>[
          const AppBackdrop(),
          SafeArea(
            child: ListView(
              padding: const EdgeInsets.fromLTRB(20, 88, 20, 32),
              children: <Widget>[
                SurfaceCard(
                  color: palette.heroSurface.withValues(alpha: 0.94),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: <Widget>[
                      Row(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: <Widget>[
                          Container(
                            width: 56,
                            height: 56,
                            decoration: BoxDecoration(
                              color: definition.accent.withValues(alpha: 0.18),
                              borderRadius: BorderRadius.circular(18),
                            ),
                            child: Icon(
                              definition.icon,
                              color: definition.accent,
                              size: 28,
                            ),
                          ),
                          const SizedBox(width: 16),
                          Expanded(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: <Widget>[
                                Text(
                                  definition.title,
                                  style: theme.textTheme.headlineMedium
                                      ?.copyWith(color: palette.heroText),
                                ),
                                const SizedBox(height: 8),
                                Text(
                                  definition.subtitle,
                                  style: theme.textTheme.bodyLarge?.copyWith(
                                    color: palette.heroMutedText,
                                  ),
                                ),
                              ],
                            ),
                          ),
                        ],
                      ),
                      const SizedBox(height: 18),
                      Wrap(
                        spacing: 8,
                        runSpacing: 8,
                        children: definition.tags
                            .map(
                              (String tag) =>
                                  TagChip(label: tag, tint: definition.accent),
                            )
                            .toList(),
                      ),
                      const SizedBox(height: 22),
                      Row(
                        children: <Widget>[
                          Expanded(
                            child: DetailMetric(
                              label: 'Czas',
                              value: definition.duration,
                            ),
                          ),
                          const SizedBox(width: 12),
                          Expanded(
                            child: DetailMetric(
                              label: 'Kiedy',
                              value: definition.idealMoment,
                            ),
                          ),
                        ],
                      ),
                      const SizedBox(height: 12),
                      DetailMetric(
                        label: 'Efekt',
                        value: definition.outcome,
                        fullWidth: true,
                      ),
                    ],
                  ),
                ),
                if (!isMnemonicVault) ...<Widget>[
                  const SizedBox(height: 18),
                  SurfaceCard(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: <Widget>[
                        SectionHeader(eyebrow: 'Po co', title: purposeTitle),
                        const SizedBox(height: 12),
                        Text(
                          definition.summary,
                          style: theme.textTheme.bodyLarge?.copyWith(
                            color: palette.primaryText,
                          ),
                        ),
                      ],
                    ),
                  ),
                  if (showInstructionBox) ...<Widget>[
                    const SizedBox(height: 18),
                    SurfaceCard(
                      child: Center(
                        child: ConstrainedBox(
                          constraints: const BoxConstraints(maxWidth: 560),
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: <Widget>[
                              SectionHeader(
                                eyebrow: 'Instrukcja',
                                title: instructionTitle,
                              ),
                              const SizedBox(height: 16),
                              for (final entry
                                  in definition.instructions
                                      .asMap()
                                      .entries) ...<Widget>[
                                InstructionStep(
                                  number: entry.key + 1,
                                  text: entry.value,
                                  tint: definition.accent,
                                ),
                                const SizedBox(height: 12),
                              ],
                            ],
                          ),
                        ),
                      ),
                    ),
                  ],
                  if (isPulseSync) ...<Widget>[
                    const SizedBox(height: 18),
                    _PulseSyncLevelSelectorCard(
                      accent: definition.accent,
                      selectedLevel: _selectedPulseSyncLevel,
                      onLevelChanged: _handlePulseSyncLevelChanged,
                    ),
                  ],
                  if (isMemoryChain) ...<Widget>[
                    const SizedBox(height: 18),
                    _MemoryGameSelectorCard(
                      accent: definition.accent,
                      selectedGame: _selectedMemoryGame,
                      onGameChanged: _handleMemoryGameChanged,
                    ),
                  ],
                  if (isSpeedRead) ...<Widget>[
                    const SizedBox(height: 18),
                    _SpeedReadLevelSelectorCard(
                      accent: definition.accent,
                      selectedLevel: _selectedSpeedReadLevel,
                      onLevelChanged: _handleSpeedReadLevelChanged,
                    ),
                  ],
                  if (isFocusScan) ...<Widget>[
                    const SizedBox(height: 18),
                    _FocusScanModeSelectorCard(
                      accent: definition.accent,
                      selectedMode: _selectedFocusScanMode,
                      onModeChanged: _handleFocusScanModeChanged,
                    ),
                  ],
                  if (isSplitDecision) ...<Widget>[
                    const SizedBox(height: 18),
                    _SplitDecisionLevelSelectorCard(
                      accent: definition.accent,
                      selectedIndex: _selectedSplitDecisionLevelIndex,
                      onLevelChanged: _handleSplitDecisionLevelChanged,
                    ),
                  ],
                ],
                if (isMnemonicVault) ...<Widget>[
                  const SizedBox(height: 18),
                  _MnemonicVaultDigitListCard(accent: definition.accent),
                  const SizedBox(height: 18),
                  _MnemonicVaultGameSelectorCard(
                    accent: definition.accent,
                    selectedGame: _selectedMnemonicVaultGame,
                    onGameChanged: _handleMnemonicVaultGameChanged,
                  ),
                ],
                const SizedBox(height: 18),
                SurfaceCard(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: <Widget>[
                      SectionHeader(eyebrow: 'Trening', title: trainerTitle),
                      const SizedBox(height: 18),
                      _TrainerHost(
                        kind: definition.kind,
                        memoryGame: _selectedMemoryGame,
                        mnemonicVaultGame: _selectedMnemonicVaultGame,
                        accent: definition.accent,
                        pulseSyncLevel: _selectedPulseSyncLevel,
                        speedReadLevel: _selectedSpeedReadLevel,
                        focusScanMode: _selectedFocusScanMode,
                        splitDecisionLevelIndex:
                            _selectedSplitDecisionLevelIndex,
                        onSessionStarted: _markCompletedFromTraining,
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: 18),
                SurfaceCard(
                  child: Row(
                    children: <Widget>[
                      Expanded(
                        child: Text(
                          _completed
                              ? 'Sesja została już zapisana jako wykonana. Możesz wrócić do listy.'
                              : 'Start gry zapisze to ćwiczenie automatycznie jako wykonane w tej sesji.',
                          style: theme.textTheme.bodyLarge?.copyWith(
                            color: palette.primaryText,
                          ),
                        ),
                      ),
                      const SizedBox(width: 16),
                      FilledButton(
                        onPressed: _completeAndReturn,
                        style: FilledButton.styleFrom(
                          backgroundColor: _completed ? palette.success : null,
                          foregroundColor: _completed
                              ? palette.onSuccess
                              : null,
                        ),
                        child: Text(_completed ? 'Wróć' : 'Gotowe'),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _TrainerHost extends StatelessWidget {
  const _TrainerHost({
    required this.kind,
    required this.accent,
    this.memoryGame = _MemoryGameKind.chain,
    this.mnemonicVaultGame = _MnemonicVaultGameKind.recall,
    this.pulseSyncLevel = PulseSyncLevel.easy,
    this.speedReadLevel = SpeedReadLevel.one,
    this.focusScanMode = FocusScanMode.basic,
    this.splitDecisionLevelIndex = 0,
    this.onSessionStarted,
  });

  final ExerciseKind kind;
  final Color accent;
  final _MemoryGameKind memoryGame;
  final _MnemonicVaultGameKind mnemonicVaultGame;
  final PulseSyncLevel pulseSyncLevel;
  final SpeedReadLevel speedReadLevel;
  final FocusScanMode focusScanMode;
  final int splitDecisionLevelIndex;
  final VoidCallback? onSessionStarted;

  @override
  Widget build(BuildContext context) {
    return switch (kind) {
      ExerciseKind.breathFlow => PulseSyncTrainer(
        accent: accent,
        fullscreenOnStart: true,
        initialLevel: pulseSyncLevel,
        showLevelSelector: false,
        onSessionStarted: onSessionStarted,
      ),
      ExerciseKind.flowRunner => FlowRunnerTrainer(
        accent: accent,
        fullscreenOnStart: true,
        onSessionStarted: onSessionStarted,
      ),
      ExerciseKind.focusScan => FocusScanTrainer(
        accent: accent,
        fullscreenOnStart: true,
        initialMode: focusScanMode,
        showModeSelector: false,
        onSessionStarted: onSessionStarted,
      ),
      ExerciseKind.splitDecision => SplitDecisionTrainer(
        accent: accent,
        fullscreenOnStart: true,
        initialLevelIndex: splitDecisionLevelIndex,
        showLauncherPreview: false,
        onSessionStarted: onSessionStarted,
      ),
      ExerciseKind.speedRead => SpeedReadTrainer(
        accent: accent,
        fullscreenOnStart: true,
        initialLevel: speedReadLevel,
        showLevelSelector: false,
        onSessionStarted: onSessionStarted,
      ),
      ExerciseKind.memoryChain => MemoryArcadeTrainer(
        accent: accent,
        initialGameIndex: memoryGame.index,
        showGameSelector: false,
        onSessionStarted: onSessionStarted,
      ),
      ExerciseKind.mnemonicVault => switch (mnemonicVaultGame) {
        _MnemonicVaultGameKind.recall => MnemonicVaultTrainer(
          accent: accent,
          fullscreenOnStart: true,
          onSessionStarted: onSessionStarted,
        ),
        _MnemonicVaultGameKind.sprint => MnemonicSprintTrainer(
          accent: accent,
          fullscreenOnStart: true,
          onSessionStarted: onSessionStarted,
        ),
        _MnemonicVaultGameKind.sequence => MnemonicSequenceTrainer(
          accent: accent,
          fullscreenOnStart: true,
          onSessionStarted: onSessionStarted,
        ),
      },
      ExerciseKind.focusDot => FocusDotTrainer(
        accent: accent,
        onSessionStarted: onSessionStarted,
      ),
    };
  }
}

class _MnemonicDigitEntry {
  const _MnemonicDigitEntry({required this.number, required this.label});

  final int number;
  final String label;
}

const List<_MnemonicDigitEntry> _mnemonicDigitEntries = <_MnemonicDigitEntry>[
  _MnemonicDigitEntry(number: 0, label: 'jajko'),
  _MnemonicDigitEntry(number: 1, label: 'żuraw'),
  _MnemonicDigitEntry(number: 2, label: 'żyrafa'),
  _MnemonicDigitEntry(number: 3, label: 'nietoperz'),
  _MnemonicDigitEntry(number: 4, label: 'hipopotam'),
  _MnemonicDigitEntry(number: 5, label: 'haczyk'),
  _MnemonicDigitEntry(number: 6, label: 'sznurek'),
  _MnemonicDigitEntry(number: 7, label: 'kosa'),
  _MnemonicDigitEntry(number: 8, label: 'bałwan'),
  _MnemonicDigitEntry(number: 9, label: 'szpilki'),
  _MnemonicDigitEntry(number: 10, label: 'tarcza'),
  _MnemonicDigitEntry(number: 11, label: 'papierosy'),
  _MnemonicDigitEntry(number: 12, label: 'zegarek'),
  _MnemonicDigitEntry(number: 13, label: 'kot'),
  _MnemonicDigitEntry(number: 14, label: 'książka'),
  _MnemonicDigitEntry(number: 15, label: 'naszyjnik'),
  _MnemonicDigitEntry(number: 16, label: 'dupa'),
  _MnemonicDigitEntry(number: 17, label: 'glock'),
  _MnemonicDigitEntry(number: 18, label: 'tort'),
  _MnemonicDigitEntry(number: 19, label: 'miecz samurajski'),
  _MnemonicDigitEntry(number: 20, label: 'MacBook'),
  _MnemonicDigitEntry(number: 21, label: 'telefon'),
  _MnemonicDigitEntry(number: 22, label: 'drabina'),
  _MnemonicDigitEntry(number: 23, label: 'drzwi'),
  _MnemonicDigitEntry(number: 24, label: 'koń'),
  _MnemonicDigitEntry(number: 25, label: 'róża czerwona'),
  _MnemonicDigitEntry(number: 26, label: 'nożyczki'),
  _MnemonicDigitEntry(number: 27, label: 'lodówka'),
  _MnemonicDigitEntry(number: 28, label: 'mikrofalówka'),
  _MnemonicDigitEntry(number: 29, label: 'rum'),
  _MnemonicDigitEntry(number: 30, label: 'lustro'),
  _MnemonicDigitEntry(number: 31, label: 'szklanka'),
  _MnemonicDigitEntry(number: 32, label: 'cola'),
  _MnemonicDigitEntry(number: 33, label: 'pralka'),
  _MnemonicDigitEntry(number: 34, label: 'zielona zbroja'),
  _MnemonicDigitEntry(number: 35, label: 'goła panna'),
  _MnemonicDigitEntry(number: 36, label: 'granaty'),
  _MnemonicDigitEntry(number: 37, label: 'kibel'),
  _MnemonicDigitEntry(number: 38, label: 'Listerine'),
  _MnemonicDigitEntry(number: 39, label: 'szczoteczka'),
  _MnemonicDigitEntry(number: 40, label: 'patelnia'),
  _MnemonicDigitEntry(number: 41, label: 'olej'),
  _MnemonicDigitEntry(number: 42, label: 'mysz'),
  _MnemonicDigitEntry(number: 43, label: 'ser'),
  _MnemonicDigitEntry(number: 44, label: 'rower'),
  _MnemonicDigitEntry(number: 45, label: 'suszarka'),
  _MnemonicDigitEntry(number: 46, label: 'haczyk'),
  _MnemonicDigitEntry(number: 47, label: 'AK-47'),
  _MnemonicDigitEntry(number: 48, label: 'Land Rover'),
  _MnemonicDigitEntry(number: 49, label: 'rękawiczka bokserska'),
  _MnemonicDigitEntry(number: 50, label: 'szpar'),
  _MnemonicDigitEntry(number: 51, label: 'wózek'),
  _MnemonicDigitEntry(number: 52, label: 'koszyk'),
  _MnemonicDigitEntry(number: 53, label: 'bramki'),
  _MnemonicDigitEntry(number: 54, label: 'PS4'),
  _MnemonicDigitEntry(number: 55, label: 'TV'),
  _MnemonicDigitEntry(number: 56, label: 'Netflix'),
  _MnemonicDigitEntry(number: 57, label: 'popcorn'),
  _MnemonicDigitEntry(number: 58, label: 'Joyi'),
  _MnemonicDigitEntry(number: 59, label: 'Czendler'),
  _MnemonicDigitEntry(number: 60, label: 'dynamit'),
  _MnemonicDigitEntry(number: 61, label: 'Burger King'),
  _MnemonicDigitEntry(number: 62, label: 'BP'),
  _MnemonicDigitEntry(number: 63, label: 'motocykl'),
  _MnemonicDigitEntry(number: 64, label: 'paliwo'),
  _MnemonicDigitEntry(number: 65, label: 'helikopter'),
  _MnemonicDigitEntry(number: 66, label: 'mały diabeł'),
  _MnemonicDigitEntry(number: 67, label: 'gowno'),
  _MnemonicDigitEntry(number: 68, label: 'Słomka'),
  _MnemonicDigitEntry(number: 69, label: 'pies'),
  _MnemonicDigitEntry(number: 70, label: 'choinka'),
  _MnemonicDigitEntry(number: 71, label: 'prezenty'),
  _MnemonicDigitEntry(number: 72, label: 'fiat świąteczny'),
  _MnemonicDigitEntry(number: 73, label: 'kebab'),
  _MnemonicDigitEntry(number: 74, label: 'maska zielona'),
  _MnemonicDigitEntry(number: 75, label: 'Borys Brejcha'),
  _MnemonicDigitEntry(number: 76, label: 'e-papieros'),
  _MnemonicDigitEntry(number: 77, label: 'tablica rejestracyjna'),
  _MnemonicDigitEntry(number: 78, label: 'rycerz'),
  _MnemonicDigitEntry(number: 79, label: 'RIB +9'),
  _MnemonicDigitEntry(number: 80, label: 'kostka Rubika'),
  _MnemonicDigitEntry(number: 81, label: 'Uber'),
  _MnemonicDigitEntry(number: 82, label: 'monster truck'),
  _MnemonicDigitEntry(number: 83, label: 'tramwaj'),
  _MnemonicDigitEntry(number: 84, label: 'drzewo'),
  _MnemonicDigitEntry(number: 85, label: 'ławka'),
  _MnemonicDigitEntry(number: 86, label: 'browar'),
  _MnemonicDigitEntry(number: 87, label: 'śmietnik'),
  _MnemonicDigitEntry(number: 88, label: 'serce'),
  _MnemonicDigitEntry(number: 89, label: 'ogień'),
  _MnemonicDigitEntry(number: 90, label: 'garnitur biały'),
  _MnemonicDigitEntry(number: 91, label: 'wędka'),
  _MnemonicDigitEntry(number: 92, label: 'ryba'),
  _MnemonicDigitEntry(number: 93, label: 'Słoik'),
  _MnemonicDigitEntry(number: 94, label: 'Statek czarna perła'),
  _MnemonicDigitEntry(number: 95, label: 'Jack Sparrow'),
  _MnemonicDigitEntry(number: 96, label: 'opaska na oko'),
  _MnemonicDigitEntry(number: 97, label: 'kot w butach'),
  _MnemonicDigitEntry(number: 98, label: 'Shrek'),
  _MnemonicDigitEntry(number: 99, label: 'osioł'),
  _MnemonicDigitEntry(number: 100, label: 'Fiona'),
];

enum _MnemonicRecallResult { remembered, needsPractice }

class _MnemonicRecallRecord {
  const _MnemonicRecallRecord({required this.number, required this.result});

  final int number;
  final _MnemonicRecallResult result;
}

class _MnemonicRecallDigitIssue {
  const _MnemonicRecallDigitIssue({required this.number, required this.misses});

  final int number;
  final int misses;

  Map<String, dynamic> toJson() => <String, dynamic>{
    'number': number,
    'misses': misses,
  };

  factory _MnemonicRecallDigitIssue.fromJson(Map<String, dynamic> json) {
    final number = json['number'];
    final misses = json['misses'];
    if (number is! int || misses is! int) {
      throw const FormatException('Invalid mnemonic recall digit issue.');
    }
    return _MnemonicRecallDigitIssue(number: number, misses: misses);
  }
}

class _MnemonicRecallSessionRecord {
  const _MnemonicRecallSessionRecord({
    required this.dateKey,
    required this.completedAtIso,
    required this.rounds,
    required this.problemDigits,
    this.durationSeconds,
  });

  final String dateKey;
  final String completedAtIso;
  final int rounds;
  final List<_MnemonicRecallDigitIssue> problemDigits;
  final int? durationSeconds;

  int get problemDigitCount => problemDigits.length;

  int get totalMistakes => problemDigits.fold<int>(
    0,
    (int sum, _MnemonicRecallDigitIssue issue) => sum + issue.misses,
  );

  Duration? get sessionDuration =>
      durationSeconds == null ? null : Duration(seconds: durationSeconds!);

  Map<String, dynamic> toJson() => <String, dynamic>{
    'dateKey': dateKey,
    'completedAtIso': completedAtIso,
    'rounds': rounds,
    if (durationSeconds != null) 'durationSeconds': durationSeconds,
    'problemDigits': problemDigits
        .map((_MnemonicRecallDigitIssue issue) => issue.toJson())
        .toList(),
  };

  factory _MnemonicRecallSessionRecord.fromJson(Map<String, dynamic> json) {
    final dateKey = json['dateKey'];
    final completedAtIso = json['completedAtIso'];
    final rounds = json['rounds'];
    final rawDurationSeconds = json['durationSeconds'];
    final rawProblemDigits = json['problemDigits'];

    if (dateKey is! String ||
        completedAtIso is! String ||
        rounds is! int ||
        rawProblemDigits is! List<dynamic>) {
      throw const FormatException('Invalid mnemonic recall session record.');
    }

    final problemDigits = <_MnemonicRecallDigitIssue>[];
    for (final item in rawProblemDigits) {
      if (item is! Map<dynamic, dynamic>) {
        continue;
      }
      try {
        problemDigits.add(
          _MnemonicRecallDigitIssue.fromJson(Map<String, dynamic>.from(item)),
        );
      } on FormatException {
        continue;
      }
    }

    final durationSeconds = rawDurationSeconds is int && rawDurationSeconds >= 0
        ? rawDurationSeconds
        : null;

    return _MnemonicRecallSessionRecord(
      dateKey: dateKey,
      completedAtIso: completedAtIso,
      rounds: rounds,
      problemDigits: problemDigits,
      durationSeconds: durationSeconds,
    );
  }
}

class _MnemonicRecallDifficultyAggregate {
  const _MnemonicRecallDifficultyAggregate({
    required this.number,
    required this.label,
    required this.totalMistakes,
    required this.sessionsWithIssue,
    required this.lastSeenIso,
    required this.currentlyProblematic,
  });

  final int number;
  final String label;
  final int totalMistakes;
  final int sessionsWithIssue;
  final String lastSeenIso;
  final bool currentlyProblematic;
}

class _MnemonicRecallDifficultyAggregateBuilder {
  _MnemonicRecallDifficultyAggregateBuilder({
    required this.number,
    required this.label,
  });

  final int number;
  final String label;
  int totalMistakes = 0;
  int sessionsWithIssue = 0;
  String lastSeenIso = '';

  _MnemonicRecallDifficultyAggregate build({
    required bool currentlyProblematic,
  }) {
    return _MnemonicRecallDifficultyAggregate(
      number: number,
      label: label,
      totalMistakes: totalMistakes,
      sessionsWithIssue: sessionsWithIssue,
      lastSeenIso: lastSeenIso,
      currentlyProblematic: currentlyProblematic,
    );
  }
}

String _mnemonicRecallMistakeCountLabel(int count) {
  return '$count ${_memoryPluralLabel(count, singular: 'potknięcie', paucal: 'potknięcia', plural: 'potknięć')}';
}

String _formatMnemonicRecallSessionDuration(Duration duration) {
  final totalSeconds = max(duration.inSeconds, 1);
  final hours = totalSeconds ~/ Duration.secondsPerHour;
  final minutes =
      (totalSeconds % Duration.secondsPerHour) ~/ Duration.secondsPerMinute;
  final seconds = totalSeconds % Duration.secondsPerMinute;

  if (hours > 0) {
    return minutes > 0 ? '$hours h $minutes min' : '$hours h';
  }
  if (minutes > 0) {
    return seconds > 0 ? '$minutes min $seconds s' : '$minutes min';
  }
  return '$seconds s';
}

String _buildMnemonicRecallProgressDetail(_MnemonicRecallSessionRecord record) {
  final stableLabel =
      'stabilne ${_mnemonicDigitEntries.length - record.problemDigitCount}/${_mnemonicDigitEntries.length}';
  final sessionDuration = record.sessionDuration;
  if (sessionDuration == null) {
    return stableLabel;
  }
  return '$stableLabel • czas sesji ${_formatMnemonicRecallSessionDuration(sessionDuration)}';
}

String _buildMnemonicRecallSessionDifficultySummary(
  _MnemonicRecallSessionRecord record,
) {
  if (record.problemDigits.isEmpty) {
    return 'Czysta runda. Żadna cyfra nie wróciła do dodatkowej serii.';
  }

  final preview = record.problemDigits
      .take(4)
      .map(
        (_MnemonicRecallDigitIssue issue) =>
            '${_formatMnemonicNumber(issue.number)} (${issue.misses}x)',
      )
      .join(', ');
  final remaining =
      record.problemDigits.length - min(4, record.problemDigits.length);
  return remaining > 0 ? '$preview, +$remaining więcej' : preview;
}

final Map<int, _MnemonicDigitEntry> _mnemonicDigitEntryByNumber =
    <int, _MnemonicDigitEntry>{
      for (final entry in _mnemonicDigitEntries) entry.number: entry,
    };

String _formatMnemonicNumber(int number) {
  return '$number';
}

enum _MnemonicVaultGameKind { recall, sprint, sequence }

class _MnemonicVaultGameDefinition {
  const _MnemonicVaultGameDefinition({required this.kind, required this.label});

  final _MnemonicVaultGameKind kind;
  final String label;
}

const List<_MnemonicVaultGameDefinition> _mnemonicVaultGameDefinitions =
    <_MnemonicVaultGameDefinition>[
      _MnemonicVaultGameDefinition(
        kind: _MnemonicVaultGameKind.recall,
        label: 'Recall',
      ),
      _MnemonicVaultGameDefinition(
        kind: _MnemonicVaultGameKind.sprint,
        label: 'Sprint',
      ),
      _MnemonicVaultGameDefinition(
        kind: _MnemonicVaultGameKind.sequence,
        label: 'Seria cyfr',
      ),
    ];

const int _mnemonicSprintMinDisplayMilliseconds = 100;
const int _mnemonicSprintMaxDisplayMilliseconds = 500;
const int _mnemonicSprintDisplayMillisecondsStep = 10;
const int _mnemonicSprintDefaultDisplayMilliseconds = 250;
const int _mnemonicSequenceMinItems = 3;
const int _mnemonicSequenceMaxItems = 22;
const int _mnemonicSequenceMinMemorizeSeconds = 2;
const int _mnemonicSequenceMaxMemorizeSeconds = 10;
const int _mnemonicSequenceRounds = 10;

String _formatMnemonicSprintSpeedLabel(int milliseconds) {
  return '${(milliseconds / 1000).toStringAsFixed(milliseconds % 1000 == 0 ? 0 : 2)} s / karta';
}

class _MnemonicVaultGameSelectorCard extends StatefulWidget {
  const _MnemonicVaultGameSelectorCard({
    required this.accent,
    required this.selectedGame,
    required this.onGameChanged,
  });

  final Color accent;
  final _MnemonicVaultGameKind selectedGame;
  final ValueChanged<_MnemonicVaultGameKind> onGameChanged;

  @override
  State<_MnemonicVaultGameSelectorCard> createState() =>
      _MnemonicVaultGameSelectorCardState();
}

class _MnemonicVaultGameSelectorCardState
    extends State<_MnemonicVaultGameSelectorCard> {
  late final PageController _pageController;

  @override
  void initState() {
    super.initState();
    _pageController = PageController(initialPage: widget.selectedGame.index);
  }

  @override
  void didUpdateWidget(covariant _MnemonicVaultGameSelectorCard oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.selectedGame == oldWidget.selectedGame ||
        !_pageController.hasClients) {
      return;
    }

    _pageController.animateToPage(
      widget.selectedGame.index,
      duration: const Duration(milliseconds: 220),
      curve: Curves.easeOutCubic,
    );
  }

  @override
  void dispose() {
    _pageController.dispose();
    super.dispose();
  }

  void _handleGameTap(_MnemonicVaultGameKind kind) {
    if (widget.selectedGame == kind) {
      return;
    }

    widget.onGameChanged(kind);
  }

  void _handlePageChanged(int index) {
    final nextGame = _mnemonicVaultGameDefinitions[index].kind;
    if (nextGame == widget.selectedGame) {
      return;
    }

    widget.onGameChanged(nextGame);
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final palette = context.appPalette;
    final selectedIndex = widget.selectedGame.index;

    return SurfaceCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          const SectionHeader(eyebrow: 'Gry', title: 'Tryby gry'),
          const SizedBox(height: 18),
          Container(
            width: double.infinity,
            height: 170,
            padding: const EdgeInsets.fromLTRB(18, 16, 18, 14),
            decoration: BoxDecoration(
              gradient: LinearGradient(
                begin: Alignment.topLeft,
                end: Alignment.bottomRight,
                colors: <Color>[
                  widget.accent.withValues(alpha: 0.16),
                  palette.surfaceStrong,
                ],
              ),
              borderRadius: BorderRadius.circular(26),
              border: Border.all(color: widget.accent.withValues(alpha: 0.18)),
            ),
            child: Column(
              children: <Widget>[
                Expanded(
                  child: PageView.builder(
                    controller: _pageController,
                    itemCount: _mnemonicVaultGameDefinitions.length,
                    physics: const BouncingScrollPhysics(),
                    onPageChanged: _handlePageChanged,
                    itemBuilder: (BuildContext context, int index) {
                      final game = _mnemonicVaultGameDefinitions[index];
                      final isSelected = index == selectedIndex;

                      return GestureDetector(
                        onTap: () => _handleGameTap(game.kind),
                        child: Container(
                          key: ValueKey<String>(
                            'mnemonic-vault-game-card-${game.kind.name}',
                          ),
                          width: double.infinity,
                          padding: const EdgeInsets.all(18),
                          decoration: BoxDecoration(
                            color: palette.surface.withValues(alpha: 0.92),
                            borderRadius: BorderRadius.circular(22),
                            border: Border.all(
                              color: isSelected
                                  ? widget.accent.withValues(alpha: 0.42)
                                  : widget.accent.withValues(alpha: 0.24),
                            ),
                          ),
                          child: Center(
                            child: Text(
                              game.label,
                              textAlign: TextAlign.center,
                              style: theme.textTheme.titleLarge?.copyWith(
                                color: palette.primaryText,
                                fontWeight: FontWeight.w900,
                              ),
                            ),
                          ),
                        ),
                      );
                    },
                  ),
                ),
                const SizedBox(height: 12),
                Row(
                  mainAxisSize: MainAxisSize.min,
                  children: List<Widget>.generate(
                    _mnemonicVaultGameDefinitions.length,
                    (int index) {
                      final bool selected = index == selectedIndex;
                      return AnimatedContainer(
                        duration: const Duration(milliseconds: 180),
                        margin: EdgeInsets.only(left: index == 0 ? 0 : 6),
                        width: selected ? 18 : 8,
                        height: 8,
                        decoration: BoxDecoration(
                          color: selected
                              ? widget.accent
                              : widget.accent.withValues(alpha: 0.24),
                          borderRadius: BorderRadius.circular(999),
                        ),
                      );
                    },
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _MnemonicVaultDigitListCard extends StatefulWidget {
  const _MnemonicVaultDigitListCard({required this.accent});

  final Color accent;

  @override
  State<_MnemonicVaultDigitListCard> createState() =>
      _MnemonicVaultDigitListCardState();
}

class _MnemonicVaultDigitListCardState
    extends State<_MnemonicVaultDigitListCard> {
  bool _expanded = false;

  void _toggleExpanded() {
    setState(() {
      _expanded = !_expanded;
    });
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final palette = context.appPalette;

    return SurfaceCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Material(
            color: Colors.transparent,
            child: InkWell(
              key: const ValueKey<String>('mnemonic-vault-digit-list-toggle'),
              onTap: _toggleExpanded,
              borderRadius: BorderRadius.circular(26),
              child: AnimatedContainer(
                duration: const Duration(milliseconds: 220),
                width: double.infinity,
                padding: EdgeInsets.symmetric(
                  horizontal: 20,
                  vertical: _expanded ? 20 : 26,
                ),
                decoration: BoxDecoration(
                  gradient: LinearGradient(
                    begin: Alignment.topLeft,
                    end: Alignment.bottomRight,
                    colors: <Color>[
                      widget.accent.withValues(alpha: 0.14),
                      palette.surfaceStrong,
                    ],
                  ),
                  borderRadius: BorderRadius.circular(26),
                  border: Border.all(
                    color: widget.accent.withValues(
                      alpha: _expanded ? 0.28 : 0.18,
                    ),
                  ),
                ),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: <Widget>[
                    Text(
                      '∞',
                      style: theme.textTheme.displaySmall?.copyWith(
                        color: widget.accent,
                        fontWeight: FontWeight.w900,
                      ),
                    ),
                    const SizedBox(height: 6),
                    Icon(
                      _expanded
                          ? Icons.keyboard_arrow_up_rounded
                          : Icons.keyboard_arrow_down_rounded,
                      color: palette.primaryText,
                    ),
                  ],
                ),
              ),
            ),
          ),
          AnimatedSize(
            duration: const Duration(milliseconds: 220),
            curve: Curves.easeOutCubic,
            child: !_expanded
                ? const SizedBox.shrink()
                : Padding(
                    padding: const EdgeInsets.fromLTRB(0, 18, 0, 0),
                    child: Container(
                      width: double.infinity,
                      padding: const EdgeInsets.all(18),
                      decoration: BoxDecoration(
                        color: palette.surfaceStrong,
                        borderRadius: BorderRadius.circular(22),
                        border: Border.all(
                          color: widget.accent.withValues(alpha: 0.12),
                        ),
                      ),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: <Widget>[
                          for (
                            var index = 0;
                            index < _mnemonicDigitEntries.length;
                            index++
                          ) ...<Widget>[
                            Row(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: <Widget>[
                                Container(
                                  width: 54,
                                  padding: const EdgeInsets.symmetric(
                                    vertical: 8,
                                  ),
                                  decoration: BoxDecoration(
                                    color: widget.accent.withValues(alpha: 0.1),
                                    borderRadius: BorderRadius.circular(14),
                                  ),
                                  alignment: Alignment.center,
                                  child: Text(
                                    _formatMnemonicNumber(
                                      _mnemonicDigitEntries[index].number,
                                    ),
                                    style: theme.textTheme.labelLarge?.copyWith(
                                      color: widget.accent,
                                      fontWeight: FontWeight.w900,
                                      letterSpacing: 0.8,
                                    ),
                                  ),
                                ),
                                const SizedBox(width: 12),
                                Expanded(
                                  child: Padding(
                                    padding: const EdgeInsets.only(top: 7),
                                    child: Text(
                                      _mnemonicDigitEntries[index].label,
                                      style: theme.textTheme.bodyLarge
                                          ?.copyWith(
                                            color: const Color(0xFF16212B),
                                            fontWeight: FontWeight.w700,
                                          ),
                                    ),
                                  ),
                                ),
                              ],
                            ),
                            if (index != _mnemonicDigitEntries.length - 1)
                              Padding(
                                padding: const EdgeInsets.symmetric(
                                  vertical: 10,
                                ),
                                child: Divider(
                                  height: 1,
                                  color: widget.accent.withValues(alpha: 0.12),
                                ),
                              ),
                          ],
                        ],
                      ),
                    ),
                  ),
          ),
        ],
      ),
    );
  }
}

int _mnemonicSequenceDefaultMemorizeSecondsForCount(int count) {
  return min(
    _mnemonicSequenceMaxMemorizeSeconds,
    max(_mnemonicSequenceMinMemorizeSeconds, count + 2),
  );
}

int _mnemonicSequenceColumnsForCount(
  int count, {
  bool compact = false,
  bool input = false,
}) {
  if (count <= 5) {
    return count;
  }
  if (input) {
    if (count <= 8) {
      return 3;
    }
    if (count <= 15) {
      return 4;
    }
    return 5;
  }
  if (compact) {
    if (count <= 8) {
      return 4;
    }
    return 5;
  }
  if (count <= 8) {
    return 3;
  }
  return 4;
}

class MnemonicVaultTrainer extends StatefulWidget {
  const MnemonicVaultTrainer({
    super.key,
    required this.accent,
    this.autoStart = false,
    this.fullscreenOnStart = false,
    this.immersiveMode = false,
    this.autoExitOnFinish = false,
    this.onSessionStarted,
  });

  final Color accent;
  final bool autoStart;
  final bool fullscreenOnStart;
  final bool immersiveMode;
  final bool autoExitOnFinish;
  final VoidCallback? onSessionStarted;

  @override
  State<MnemonicVaultTrainer> createState() => _MnemonicVaultTrainerState();
}

class _MnemonicVaultTrainerState extends State<MnemonicVaultTrainer> {
  static const int _sessionStartCountdownSeconds = 3;
  static const Duration _promptDecisionDelay = Duration(seconds: 4);
  static const Duration _finishExitDelay = Duration(seconds: 4);
  static const String _recallSessionHistoryStorageKey =
      'mnemonic_vault_recall_history_v1';

  final Random _random = Random();

  Timer? _startCountdownTimer;
  Timer? _promptTimer;
  Timer? _finishExitTimer;

  bool _hasSessionStarted = false;
  bool _finished = false;
  bool _showingPrompt = false;
  bool _showingRoundLevelIntro = false;
  bool _immersivePaused = false;
  int? _countdownValue;
  int? _currentNumber;
  int _rounds = 0;
  int _cycleNumber = 0;
  int _rememberedCount = 0;
  int _shownInCurrentCycle = 0;
  String _status = 'Uruchom trening skojarzeń.';
  List<int> _currentCycleNumbers = <int>[];
  List<int> _nextCycleNumbers = <int>[];
  List<_MnemonicRecallRecord> _history = <_MnemonicRecallRecord>[];
  List<_MnemonicRecallSessionRecord> _storedSessionHistory =
      <_MnemonicRecallSessionRecord>[];
  bool _storedHistoryLoaded = false;
  bool _finishedSessionStored = false;
  DateTime? _sessionTimingStartedAt;
  Duration _elapsedSessionDuration = Duration.zero;

  bool get _isCountingDown => _countdownValue != null;

  @override
  void initState() {
    super.initState();
    _loadStoredRecallHistory();
    if (widget.autoStart) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) {
          _startSession();
        }
      });
    }
  }

  String get _countdownLabel {
    final value = _countdownValue;
    if (value == null) {
      return '';
    }
    return value == 0 ? 'Start' : '$value';
  }

  String get _phaseHint {
    if (_finished) {
      return widget.autoExitOnFinish
          ? 'Wszystkie cyfry są już utrwalone. Za 4 sekundy wrócisz do wyboru gry.'
          : 'Wszystkie cyfry są już utrwalone. Możesz uruchomić recall jeszcze raz.';
    }
    if (_isCountingDown) {
      return _showingRoundLevelIntro
          ? 'Kolejna runda ruszy po krótkiej zapowiedzi.'
          : 'Za chwilę pojawi się liczba. Reagujesz od razu: Tak albo Nie.';
    }
    if (_showingPrompt) {
      return 'Masz 4 sekundy na decyzję: Tak albo Nie.';
    }
    if (_hasSessionStarted && _rounds > 0) {
      return 'Kolejne rundy pokażą już tylko cyfry oznaczone jako Nie.';
    }
    return 'Po pierwszej rundzie wrócą już tylko cyfry oznaczone jako Nie.';
  }

  int get _cycleTotal => _currentCycleNumbers.isEmpty
      ? _mnemonicDigitEntries.length
      : _currentCycleNumbers.length;

  String get _immersiveProgressLabel => '$_shownInCurrentCycle/$_cycleTotal';

  String get _immersiveProgressHint {
    if (_finished) {
      return 'wszystko zapamiętane';
    }
    if (!_hasSessionStarted) {
      return 'do utrwalenia ${_mnemonicDigitEntries.length}';
    }
    return 'runda ${max(_cycleNumber, 1)} • do utrwalenia $_remainingToMaster';
  }

  int get _remainingToMaster => _mnemonicDigitEntries.length - _rememberedCount;

  bool get _canFastForwardImmersiveStage =>
      !_immersivePaused && !_finished && _isCountingDown;

  _MnemonicDigitEntry? get _currentEntry {
    final currentNumber = _currentNumber;
    if (currentNumber == null) {
      return null;
    }
    return _mnemonicDigitEntryByNumber[currentNumber];
  }

  _MnemonicRecallSessionRecord? get _latestStoredSession =>
      _storedSessionHistory.isEmpty ? null : _storedSessionHistory.first;

  List<_MnemonicRecallDifficultyAggregate> get _difficultyHistoryOverview {
    final latestProblemNumbers =
        _latestStoredSession?.problemDigits
            .map((_MnemonicRecallDigitIssue issue) => issue.number)
            .toSet() ??
        <int>{};
    final Map<int, _MnemonicRecallDifficultyAggregateBuilder> aggregates =
        <int, _MnemonicRecallDifficultyAggregateBuilder>{};

    for (final record in _storedSessionHistory.take(12)) {
      for (final issue in record.problemDigits) {
        final entry = _mnemonicDigitEntryByNumber[issue.number];
        if (entry == null) {
          continue;
        }
        final aggregate = aggregates.putIfAbsent(
          issue.number,
          () => _MnemonicRecallDifficultyAggregateBuilder(
            number: issue.number,
            label: entry.label,
          ),
        );
        aggregate.totalMistakes += issue.misses;
        aggregate.sessionsWithIssue += 1;
        if (record.completedAtIso.compareTo(aggregate.lastSeenIso) > 0) {
          aggregate.lastSeenIso = record.completedAtIso;
        }
      }
    }

    final overview = aggregates.values
        .map(
          (_MnemonicRecallDifficultyAggregateBuilder aggregate) =>
              aggregate.build(
                currentlyProblematic: latestProblemNumbers.contains(
                  aggregate.number,
                ),
              ),
        )
        .toList();

    overview.sort((
      _MnemonicRecallDifficultyAggregate a,
      _MnemonicRecallDifficultyAggregate b,
    ) {
      if (a.currentlyProblematic != b.currentlyProblematic) {
        return a.currentlyProblematic ? -1 : 1;
      }
      if (a.totalMistakes != b.totalMistakes) {
        return b.totalMistakes.compareTo(a.totalMistakes);
      }
      if (a.sessionsWithIssue != b.sessionsWithIssue) {
        return b.sessionsWithIssue.compareTo(a.sessionsWithIssue);
      }
      return b.lastSeenIso.compareTo(a.lastSeenIso);
    });
    return overview;
  }

  Future<void> _loadStoredRecallHistory() async {
    final preferences = await SharedPreferences.getInstance();
    final rawHistory = preferences.getString(_recallSessionHistoryStorageKey);

    if (!mounted) {
      return;
    }

    setState(() {
      _storedSessionHistory = _decodeStoredRecallHistory(rawHistory);
      _storedHistoryLoaded = true;
    });
  }

  List<_MnemonicRecallSessionRecord> _decodeStoredRecallHistory(
    String? rawHistory,
  ) {
    if (rawHistory == null || rawHistory.isEmpty) {
      return <_MnemonicRecallSessionRecord>[];
    }

    try {
      final decoded = jsonDecode(rawHistory);
      if (decoded is! List<dynamic>) {
        return <_MnemonicRecallSessionRecord>[];
      }

      final history = <_MnemonicRecallSessionRecord>[];
      for (final item in decoded) {
        if (item is! Map<dynamic, dynamic>) {
          continue;
        }

        try {
          history.add(
            _MnemonicRecallSessionRecord.fromJson(
              Map<String, dynamic>.from(item),
            ),
          );
        } on FormatException {
          continue;
        }
      }

      history.sort(
        (_MnemonicRecallSessionRecord a, _MnemonicRecallSessionRecord b) =>
            b.completedAtIso.compareTo(a.completedAtIso),
      );
      return history;
    } on FormatException {
      return <_MnemonicRecallSessionRecord>[];
    }
  }

  Future<void> _persistRecallHistory(
    List<_MnemonicRecallSessionRecord> history,
  ) async {
    final preferences = await SharedPreferences.getInstance();
    final encodedHistory = jsonEncode(
      history
          .map((_MnemonicRecallSessionRecord record) => record.toJson())
          .toList(),
    );
    await preferences.setString(
      _recallSessionHistoryStorageKey,
      encodedHistory,
    );
  }

  Future<void> _storeFinishedRecallSession(Duration sessionDuration) async {
    if (_finishedSessionStored || _rounds == 0) {
      return;
    }
    _finishedSessionStored = true;

    final completedAt = DateTime.now();
    final Map<int, int> missesByNumber = <int, int>{};
    for (final record in _history) {
      if (record.result != _MnemonicRecallResult.needsPractice) {
        continue;
      }
      missesByNumber.update(
        record.number,
        (int count) => count + 1,
        ifAbsent: () => 1,
      );
    }

    final problemDigits =
        missesByNumber.entries
            .map(
              (MapEntry<int, int> entry) => _MnemonicRecallDigitIssue(
                number: entry.key,
                misses: entry.value,
              ),
            )
            .toList()
          ..sort(
            (_MnemonicRecallDigitIssue a, _MnemonicRecallDigitIssue b) =>
                b.misses.compareTo(a.misses) != 0
                ? b.misses.compareTo(a.misses)
                : a.number.compareTo(b.number),
          );

    final sessionRecord = _MnemonicRecallSessionRecord(
      dateKey: _dateKeyFor(completedAt),
      completedAtIso: completedAt.toIso8601String(),
      rounds: _rounds,
      problemDigits: problemDigits,
      durationSeconds: sessionDuration > Duration.zero
          ? max(sessionDuration.inSeconds, 1)
          : null,
    );

    final updatedHistory =
        <_MnemonicRecallSessionRecord>[sessionRecord, ..._storedSessionHistory]
          ..sort(
            (_MnemonicRecallSessionRecord a, _MnemonicRecallSessionRecord b) =>
                b.completedAtIso.compareTo(a.completedAtIso),
          );

    if (mounted) {
      setState(() {
        _storedSessionHistory = updatedHistory;
        _storedHistoryLoaded = true;
      });
    }

    await _persistRecallHistory(updatedHistory);
  }

  Future<void> _openRecallHistoryPage() {
    return Navigator.of(context).push<void>(
      _buildExerciseSessionRoute<void>(
        builder: (BuildContext context) {
          return FullscreenTrainerPage(
            title: 'Historia trudnych cyfr',
            accent: widget.accent,
            contentMaxWidth: 760,
            child: _MnemonicRecallHistoryContent(
              accent: widget.accent,
              historyLoaded: _storedHistoryLoaded,
              sessionHistory: _storedSessionHistory,
              difficultyOverview: _difficultyHistoryOverview,
            ),
          );
        },
      ),
    );
  }

  Widget _buildRecallHistoryLauncherCard(ThemeData theme) {
    final palette = context.appPalette;
    final latestSession = _latestStoredSession;
    final historyCount = _storedSessionHistory.length;

    return Material(
      color: Colors.transparent,
      child: InkWell(
        borderRadius: BorderRadius.circular(24),
        onTap: _openRecallHistoryPage,
        child: Container(
          width: double.infinity,
          padding: const EdgeInsets.fromLTRB(22, 22, 22, 24),
          decoration: BoxDecoration(
            gradient: LinearGradient(
              begin: Alignment.topLeft,
              end: Alignment.bottomRight,
              colors: <Color>[
                widget.accent.withValues(alpha: 0.12),
                palette.surfaceStrong,
              ],
            ),
            borderRadius: BorderRadius.circular(24),
            border: Border.all(color: widget.accent.withValues(alpha: 0.18)),
            boxShadow: <BoxShadow>[
              BoxShadow(
                color: palette.shadowColor.withValues(alpha: 0.16),
                blurRadius: 22,
                offset: const Offset(0, 12),
              ),
            ],
          ),
          child: Column(
            children: <Widget>[
              Text(
                'Zapisana historia trudnych cyfr',
                textAlign: TextAlign.center,
                style: theme.textTheme.titleMedium?.copyWith(
                  color: palette.primaryText,
                  fontWeight: FontWeight.w900,
                ),
              ),
              const SizedBox(height: 8),
              Text(
                !_storedHistoryLoaded
                    ? 'Ładowanie zapisów Recall...'
                    : latestSession == null
                    ? 'Skrzynia jest gotowa. Po pierwszej pełnej sesji zapiszą się tu Twoje wyniki i trudne cyfry.'
                    : '$historyCount zapisów • ostatnia sesja ${_formatSessionDateLabel(latestSession.dateKey)} o ${_formatSessionTimeLabel(latestSession.completedAtIso)}',
                textAlign: TextAlign.center,
                style: theme.textTheme.bodyMedium?.copyWith(
                  color: palette.secondaryText,
                  height: 1.45,
                ),
              ),
              const SizedBox(height: 20),
              Container(
                width: 116,
                height: 116,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  gradient: RadialGradient(
                    colors: <Color>[
                      widget.accent.withValues(alpha: 0.28),
                      widget.accent.withValues(alpha: 0.12),
                    ],
                  ),
                  border: Border.all(
                    color: widget.accent.withValues(alpha: 0.24),
                  ),
                  boxShadow: <BoxShadow>[
                    BoxShadow(
                      color: widget.accent.withValues(alpha: 0.18),
                      blurRadius: 24,
                      offset: const Offset(0, 10),
                    ),
                  ],
                ),
                child: Icon(
                  Icons.inventory_2_outlined,
                  size: 52,
                  color: widget.accent,
                ),
              ),
              const SizedBox(height: 14),
              Text(
                'Otwórz skrzynię wyników',
                textAlign: TextAlign.center,
                style: theme.textTheme.labelLarge?.copyWith(
                  color: widget.accent,
                  fontWeight: FontWeight.w900,
                  letterSpacing: 0.4,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildPromptDecisionButtons({required double height}) {
    return ConstrainedBox(
      constraints: const BoxConstraints(maxWidth: 360),
      child: Row(
        children: <Widget>[
          Expanded(
            child: SizedBox(
              height: height,
              child: FilledButton(
                key: const ValueKey<String>('mnemonic-answer-yes'),
                onPressed: () => _markRound(_MnemonicRecallResult.remembered),
                style: FilledButton.styleFrom(
                  backgroundColor: _memorySuccessColor,
                  foregroundColor: Colors.white,
                ),
                child: const Text('Tak'),
              ),
            ),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: SizedBox(
              height: height,
              child: FilledButton(
                key: const ValueKey<String>('mnemonic-answer-no'),
                onPressed: () =>
                    _markRound(_MnemonicRecallResult.needsPractice),
                style: FilledButton.styleFrom(
                  backgroundColor: _memoryFailureColor,
                  foregroundColor: Colors.white,
                ),
                child: const Text('Nie'),
              ),
            ),
          ),
        ],
      ),
    );
  }

  void _cancelTimers() {
    _startCountdownTimer?.cancel();
    _promptTimer?.cancel();
    _finishExitTimer?.cancel();
  }

  void _resetSessionTiming() {
    _sessionTimingStartedAt = null;
    _elapsedSessionDuration = Duration.zero;
  }

  void _resumeSessionTiming() {
    _sessionTimingStartedAt ??= DateTime.now();
  }

  void _pauseSessionTiming() {
    final sessionTimingStartedAt = _sessionTimingStartedAt;
    if (sessionTimingStartedAt == null) {
      return;
    }
    _elapsedSessionDuration += DateTime.now().difference(
      sessionTimingStartedAt,
    );
    _sessionTimingStartedAt = null;
  }

  Duration _completeSessionTiming() {
    _pauseSessionTiming();
    return _elapsedSessionDuration;
  }

  void _runStartCountdownTimer() {
    _startCountdownTimer?.cancel();
    _startCountdownTimer = Timer.periodic(const Duration(seconds: 1), (
      Timer timer,
    ) {
      if (!mounted) {
        timer.cancel();
        return;
      }

      final currentCountdown = _countdownValue;
      if (currentCountdown == null) {
        timer.cancel();
        return;
      }

      if (currentCountdown <= 0) {
        timer.cancel();
        setState(() {
          _countdownValue = null;
        });
        _beginRecallRound();
        return;
      }

      setState(() {
        _countdownValue = currentCountdown - 1;
      });

      if (_countdownValue == 0) {
        HapticFeedback.mediumImpact();
      } else {
        HapticFeedback.selectionClick();
      }
    });
  }

  void _pauseSession(String nextStatus) {
    _cancelTimers();
    _pauseSessionTiming();
    final shouldReplayCurrent = _currentNumber != null && _showingPrompt;
    setState(() {
      if (shouldReplayCurrent && _shownInCurrentCycle > 0) {
        _shownInCurrentCycle -= 1;
      }
      _immersivePaused = false;
      _countdownValue = null;
      _showingPrompt = false;
      _showingRoundLevelIntro = false;
      _currentNumber = null;
      _status = nextStatus;
    });
  }

  List<int> _reshuffledDeck(Iterable<int> numbers) {
    final deck = numbers.toList()..shuffle(_random);
    return deck;
  }

  int? _takeNextNumber() {
    if (_shownInCurrentCycle >= _currentCycleNumbers.length) {
      return null;
    }
    _shownInCurrentCycle += 1;
    return _currentCycleNumbers[_shownInCurrentCycle - 1];
  }

  Future<void> _startSession() async {
    if (_isCountingDown || _showingPrompt || _immersivePaused) {
      return;
    }

    widget.onSessionStarted?.call();
    _cancelTimers();
    _finishedSessionStored = false;

    final bool restartFromScratch = !_hasSessionStarted || _finished;
    if (restartFromScratch) {
      _resetSessionTiming();
    }
    _resumeSessionTiming();

    setState(() {
      if (restartFromScratch) {
        _hasSessionStarted = true;
        _finished = false;
        _rounds = 0;
        _cycleNumber = 1;
        _rememberedCount = 0;
        _shownInCurrentCycle = 0;
        _currentCycleNumbers = _reshuffledDeck(
          _mnemonicDigitEntries.map((entry) => entry.number),
        );
        _nextCycleNumbers = <int>[];
        _history = <_MnemonicRecallRecord>[];
      }
      _countdownValue = _sessionStartCountdownSeconds;
      _showingPrompt = false;
      _showingRoundLevelIntro = false;
      _immersivePaused = false;
      _currentNumber = null;
      _status = restartFromScratch
          ? 'Start za chwilę. Pierwsza runda przejdzie przez całą bazę cyfr.'
          : 'Wracamy do treningu. Za chwilę następna liczba.';
    });

    HapticFeedback.selectionClick();
    _runStartCountdownTimer();
  }

  Future<void> _openFullscreenSession() {
    return Navigator.of(context).push<void>(
      _buildExerciseSessionRoute<void>(
        builder: (BuildContext context) {
          return FullscreenTrainerPage(
            title: 'Sejf cyfr ∞',
            accent: widget.accent,
            expandBody: true,
            showHeader: false,
            wrapChildInSurfaceCard: false,
            contentMaxWidth: null,
            bodyPadding: EdgeInsets.zero,
            child: MnemonicVaultTrainer(
              accent: widget.accent,
              autoStart: true,
              immersiveMode: true,
              autoExitOnFinish: true,
            ),
          );
        },
      ),
    );
  }

  Future<void> _handleStartAction() async {
    if (widget.fullscreenOnStart) {
      widget.onSessionStarted?.call();
      await _openFullscreenSession();
      if (mounted) {
        await _loadStoredRecallHistory();
      }
      return;
    }

    await _startSession();
  }

  Future<void> _restartImmersiveSession() async {
    _resetTrainer();
    await _startSession();
  }

  void _pauseImmersiveSession(String nextStatus) {
    if (!widget.immersiveMode || _immersivePaused) {
      return;
    }
    _cancelTimers();
    _pauseSessionTiming();
    setState(() {
      _immersivePaused = true;
      _status = nextStatus;
    });
  }

  void _resumeImmersiveSession() {
    if (!widget.immersiveMode || !_immersivePaused) {
      return;
    }

    _resumeSessionTiming();
    setState(() {
      _immersivePaused = false;
      _status = 'Trening wznowiony.';
    });

    if (_isCountingDown) {
      _runStartCountdownTimer();
      return;
    }

    if (_showingPrompt) {
      _runPromptTimers();
      return;
    }
  }

  void _beginRecallRound() {
    _promptTimer?.cancel();
    _finishExitTimer?.cancel();

    if (_finished) {
      return;
    }

    if (_shownInCurrentCycle >= _currentCycleNumbers.length) {
      if (_nextCycleNumbers.isEmpty) {
        _finishSession();
        return;
      }

      _currentCycleNumbers = _reshuffledDeck(_nextCycleNumbers);
      _nextCycleNumbers = <int>[];
      _shownInCurrentCycle = 0;
      _cycleNumber += 1;
      _startRoundLevelIntro();
      return;
    }

    final nextNumber = _takeNextNumber();
    if (nextNumber == null) {
      _finishSession();
      return;
    }

    setState(() {
      _currentNumber = nextNumber;
      _showingPrompt = true;
      _showingRoundLevelIntro = false;
      _status = 'Szybka reakcja: Tak albo Nie.';
    });

    HapticFeedback.selectionClick();
    _runPromptTimers();
  }

  void _runPromptTimers() {
    _promptTimer?.cancel();

    _promptTimer = Timer(_promptDecisionDelay, () {
      if (!mounted) {
        return;
      }
      _markRound(_MnemonicRecallResult.needsPractice);
    });
  }

  void _startRoundLevelIntro() {
    _startCountdownTimer?.cancel();
    setState(() {
      _countdownValue = _sessionStartCountdownSeconds;
      _showingPrompt = false;
      _showingRoundLevelIntro = true;
      _currentNumber = null;
      _status = 'Utrwalanie';
    });
    _runStartCountdownTimer();
  }

  void _handleImmersiveStageTap() {
    if (!widget.immersiveMode) {
      return;
    }

    if (_isCountingDown) {
      _startCountdownTimer?.cancel();
      setState(() {
        _countdownValue = null;
      });
      _beginRecallRound();
    }
  }

  void _markRound(_MnemonicRecallResult result) {
    final currentNumber = _currentNumber;
    if (currentNumber == null || !_showingPrompt) {
      return;
    }

    _promptTimer?.cancel();

    setState(() {
      _history = <_MnemonicRecallRecord>[
        ..._history,
        _MnemonicRecallRecord(number: currentNumber, result: result),
      ];
      _rounds += 1;
      _showingPrompt = false;
      _currentNumber = null;

      if (result == _MnemonicRecallResult.remembered) {
        _rememberedCount += 1;
      } else {
        _nextCycleNumbers = <int>[..._nextCycleNumbers, currentNumber];
      }
    });

    _beginRecallRound();
  }

  void _finishSession() {
    _cancelTimers();
    final sessionDuration = _completeSessionTiming();
    setState(() {
      _finished = true;
      _countdownValue = null;
      _showingPrompt = false;
      _showingRoundLevelIntro = false;
      _immersivePaused = false;
      _currentNumber = null;
      _status = 'Gratulacje, pamiętasz wszystkie cyfry na pamięć!';
    });
    _storeFinishedRecallSession(sessionDuration);

    if (!widget.autoExitOnFinish) {
      return;
    }

    _finishExitTimer = Timer(_finishExitDelay, () {
      if (!mounted) {
        return;
      }
      Navigator.of(context).maybePop();
    });
  }

  void _resetTrainer() {
    _cancelTimers();
    _finishedSessionStored = false;
    _resetSessionTiming();
    setState(() {
      _hasSessionStarted = false;
      _finished = false;
      _showingPrompt = false;
      _showingRoundLevelIntro = false;
      _immersivePaused = false;
      _countdownValue = null;
      _currentNumber = null;
      _rounds = 0;
      _cycleNumber = 0;
      _rememberedCount = 0;
      _shownInCurrentCycle = 0;
      _currentCycleNumbers = <int>[];
      _nextCycleNumbers = <int>[];
      _history = <_MnemonicRecallRecord>[];
      _status = 'Statystyki wyczyszczone. Możesz zacząć od nowa.';
    });
  }

  @override
  void dispose() {
    _cancelTimers();
    _pauseSessionTiming();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final currentEntry = _currentEntry;

    if (widget.immersiveMode) {
      final Color chromeColor = const Color(0xFFEEF4F7);
      final Color chromeMuted = chromeColor.withValues(alpha: 0.74);
      final Color hudFill = const Color(0xFF102533).withValues(alpha: 0.72);
      final Color hudBorder = Colors.white.withValues(alpha: 0.12);
      final bool immersivePromptActive = _showingPrompt && currentEntry != null;
      final bool sessionActive =
          !_immersivePaused &&
          !_finished &&
          (_isCountingDown || _showingPrompt);
      final Widget stage = _immersivePaused
          ? Column(
              key: const ValueKey<String>('mnemonic-game-paused'),
              mainAxisSize: MainAxisSize.min,
              children: <Widget>[
                Icon(
                  Icons.pause_circle_filled_rounded,
                  size: 68,
                  color: widget.accent,
                ),
                const SizedBox(height: 14),
                Text(
                  'Sesja zatrzymana',
                  textAlign: TextAlign.center,
                  style: theme.textTheme.headlineMedium?.copyWith(
                    color: const Color(0xFF102533),
                    fontWeight: FontWeight.w900,
                  ),
                ),
              ],
            )
          : _finished
          ? Column(
              key: const ValueKey<String>('mnemonic-game-finish'),
              mainAxisSize: MainAxisSize.min,
              children: <Widget>[
                Container(
                  padding: const EdgeInsets.all(18),
                  decoration: BoxDecoration(
                    color: _memorySuccessColor.withValues(alpha: 0.14),
                    shape: BoxShape.circle,
                  ),
                  child: const Icon(
                    Icons.verified_rounded,
                    size: 62,
                    color: _memorySuccessColor,
                  ),
                ),
                const SizedBox(height: 18),
                Icon(
                  Icons.workspace_premium_rounded,
                  size: 34,
                  color: widget.accent,
                ),
                const SizedBox(height: 16),
                Text(
                  'Gratulacje, pamiętasz wszystkie cyfry na pamięć!',
                  textAlign: TextAlign.center,
                  style: theme.textTheme.headlineMedium?.copyWith(
                    color: const Color(0xFF102533),
                    fontWeight: FontWeight.w900,
                    height: 1.15,
                  ),
                ),
              ],
            )
          : _isCountingDown
          ? _showingRoundLevelIntro
                ? Column(
                    key: const ValueKey<String>('mnemonic-round-level-intro'),
                    mainAxisSize: MainAxisSize.min,
                    children: <Widget>[
                      Text(
                        'Utrwalanie',
                        textAlign: TextAlign.center,
                        style: theme.textTheme.titleLarge?.copyWith(
                          color: const Color(0xFF102533),
                          fontWeight: FontWeight.w900,
                        ),
                      ),
                      const SizedBox(height: 18),
                      _MemoryCountdownDisplay(
                        label: _countdownLabel,
                        accent: widget.accent,
                        valueKeyPrefix: 'mnemonic-vault-countdown',
                      ),
                    ],
                  )
                : _MemoryCountdownDisplay(
                    label: _countdownLabel,
                    accent: widget.accent,
                    valueKeyPrefix: 'mnemonic-vault-countdown',
                  )
          : _showingPrompt && currentEntry != null
          ? SizedBox.expand(
              key: const ValueKey<String>('mnemonic-game-number'),
              child: Stack(
                fit: StackFit.expand,
                children: <Widget>[
                  Padding(
                    padding: const EdgeInsets.only(bottom: 88),
                    child: Center(
                      child: Text(
                        _formatMnemonicNumber(currentEntry.number),
                        textAlign: TextAlign.center,
                        style: theme.textTheme.displayLarge?.copyWith(
                          color: const Color(0xFF102533),
                          fontWeight: FontWeight.w900,
                          letterSpacing: 1.8,
                        ),
                      ),
                    ),
                  ),
                  Align(
                    alignment: Alignment.bottomCenter,
                    child: Padding(
                      padding: const EdgeInsets.only(bottom: 0),
                      child: _buildPromptDecisionButtons(height: 58),
                    ),
                  ),
                ],
              ),
            )
          : Column(
              key: const ValueKey<String>('mnemonic-game-idle'),
              mainAxisSize: MainAxisSize.min,
              children: <Widget>[
                Icon(Icons.casino_outlined, size: 52, color: widget.accent),
                const SizedBox(height: 16),
                Text(
                  'Losuj liczby z całej bazy',
                  textAlign: TextAlign.center,
                  style: theme.textTheme.headlineMedium?.copyWith(
                    color: const Color(0xFF102533),
                    fontWeight: FontWeight.w900,
                  ),
                ),
                const SizedBox(height: 10),
                Text(
                  'Po pierwszej rundzie wrócą już tylko cyfry oznaczone jako Nie.',
                  textAlign: TextAlign.center,
                  style: theme.textTheme.bodyMedium?.copyWith(
                    color: const Color(0xFF4A5761),
                    height: 1.45,
                  ),
                ),
              ],
            );

      return DecoratedBox(
        decoration: BoxDecoration(
          gradient: LinearGradient(
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
            colors: <Color>[
              const Color(0xFF07131C),
              widget.accent.withValues(alpha: 0.34),
              const Color(0xFF0E2531),
            ],
          ),
        ),
        child: SafeArea(
          child: LayoutBuilder(
            builder: (BuildContext context, BoxConstraints constraints) {
              final bool compact = constraints.maxHeight < 620;
              final double stageVerticalPadding = compact ? 30 : 42;
              final double sectionGap = compact ? 14 : 18;

              return Padding(
                padding: EdgeInsets.fromLTRB(
                  16,
                  compact ? 8 : 12,
                  16,
                  compact ? 18 : 24,
                ),
                child: Column(
                  children: <Widget>[
                    Row(
                      children: <Widget>[
                        IconButton(
                          key: const ValueKey<String>(
                            'mnemonic-immersive-close',
                          ),
                          onPressed: () => Navigator.of(context).maybePop(),
                          color: chromeColor,
                          splashRadius: 24,
                          icon: const Icon(Icons.close_rounded, size: 28),
                        ),
                        const Spacer(),
                        Container(
                          key: const ValueKey<String>(
                            'mnemonic-immersive-progress',
                          ),
                          padding: const EdgeInsets.symmetric(
                            horizontal: 16,
                            vertical: 12,
                          ),
                          decoration: BoxDecoration(
                            color: hudFill,
                            borderRadius: BorderRadius.circular(22),
                            border: Border.all(color: hudBorder),
                          ),
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.end,
                            children: <Widget>[
                              Text(
                                _immersiveProgressLabel,
                                style: theme.textTheme.titleMedium?.copyWith(
                                  color: chromeColor,
                                  fontWeight: FontWeight.w900,
                                  letterSpacing: 0.6,
                                ),
                              ),
                              const SizedBox(height: 2),
                              Text(
                                _immersiveProgressHint,
                                style: theme.textTheme.bodySmall?.copyWith(
                                  color: chromeMuted,
                                  fontWeight: FontWeight.w700,
                                ),
                              ),
                            ],
                          ),
                        ),
                      ],
                    ),
                    Expanded(
                      child: LayoutBuilder(
                        builder:
                            (
                              BuildContext context,
                              BoxConstraints stageConstraints,
                            ) {
                              return Center(
                                child: ConstrainedBox(
                                  constraints: BoxConstraints(
                                    maxWidth: 560,
                                    minHeight: stageConstraints.maxHeight,
                                    maxHeight: stageConstraints.maxHeight,
                                  ),
                                  child: GestureDetector(
                                    key: const ValueKey<String>(
                                      'mnemonic-immersive-stage-box',
                                    ),
                                    behavior: HitTestBehavior.opaque,
                                    onTap: _canFastForwardImmersiveStage
                                        ? _handleImmersiveStageTap
                                        : null,
                                    child: AnimatedContainer(
                                      duration: const Duration(
                                        milliseconds: 220,
                                      ),
                                      width: double.infinity,
                                      padding: EdgeInsets.fromLTRB(
                                        26,
                                        stageVerticalPadding,
                                        26,
                                        immersivePromptActive
                                            ? (compact ? 10 : 14)
                                            : stageVerticalPadding,
                                      ),
                                      decoration: BoxDecoration(
                                        gradient: const LinearGradient(
                                          begin: Alignment.topLeft,
                                          end: Alignment.bottomRight,
                                          colors: <Color>[
                                            Color(0xFFF9F3EA),
                                            Color(0xFFEDE2D2),
                                          ],
                                        ),
                                        borderRadius: BorderRadius.circular(34),
                                        border: Border.all(
                                          color: Colors.white.withValues(
                                            alpha: 0.46,
                                          ),
                                        ),
                                        boxShadow: <BoxShadow>[
                                          BoxShadow(
                                            color: Colors.black.withValues(
                                              alpha: 0.18,
                                            ),
                                            blurRadius: 34,
                                            offset: const Offset(0, 18),
                                          ),
                                        ],
                                      ),
                                      child: SizedBox.expand(
                                        child: AnimatedSwitcher(
                                          duration: const Duration(
                                            milliseconds: 220,
                                          ),
                                          switchInCurve: Curves.easeOutCubic,
                                          switchOutCurve: Curves.easeInCubic,
                                          layoutBuilder:
                                              (
                                                Widget? currentChild,
                                                List<Widget> previousChildren,
                                              ) {
                                                return SizedBox.expand(
                                                  child: Stack(
                                                    fit: StackFit.expand,
                                                    alignment: Alignment.center,
                                                    children: <Widget>[
                                                      ...previousChildren,
                                                      ?currentChild,
                                                    ],
                                                  ),
                                                );
                                              },
                                          transitionBuilder:
                                              (
                                                Widget child,
                                                Animation<double> animation,
                                              ) {
                                                return FadeTransition(
                                                  opacity: animation,
                                                  child: child,
                                                );
                                              },
                                          child: stage,
                                        ),
                                      ),
                                    ),
                                  ),
                                ),
                              );
                            },
                      ),
                    ),
                    SizedBox(height: sectionGap),
                    ConstrainedBox(
                      constraints: const BoxConstraints(maxWidth: 420),
                      child: Container(
                        key: const ValueKey<String>(
                          'mnemonic-immersive-controls',
                        ),
                        padding: EdgeInsets.all(compact ? 12 : 14),
                        decoration: BoxDecoration(
                          color: hudFill,
                          borderRadius: BorderRadius.circular(28),
                          border: Border.all(color: hudBorder),
                          boxShadow: <BoxShadow>[
                            BoxShadow(
                              color: Colors.black.withValues(alpha: 0.12),
                              blurRadius: 24,
                              offset: const Offset(0, 10),
                            ),
                          ],
                        ),
                        child: Row(
                          children: <Widget>[
                            Expanded(
                              child: FilledButton(
                                key: const ValueKey<String>(
                                  'mnemonic-immersive-start',
                                ),
                                onPressed: _immersivePaused
                                    ? _resumeImmersiveSession
                                    : _restartImmersiveSession,
                                style: FilledButton.styleFrom(
                                  backgroundColor: const Color(0xFFF2E6D6),
                                  foregroundColor: const Color(0xFF102533),
                                ),
                                child: Text(
                                  _immersivePaused
                                      ? 'Wznów'
                                      : _finished
                                      ? 'Jeszcze raz'
                                      : 'Start',
                                ),
                              ),
                            ),
                            const SizedBox(width: 10),
                            Expanded(
                              child: OutlinedButton(
                                key: const ValueKey<String>(
                                  'mnemonic-immersive-stop',
                                ),
                                onPressed: sessionActive
                                    ? () => _pauseImmersiveSession(
                                        'Trening zatrzymany. Możesz wrócić do sesji.',
                                      )
                                    : null,
                                style: OutlinedButton.styleFrom(
                                  foregroundColor: chromeColor,
                                  side: BorderSide(
                                    color: Colors.white.withValues(alpha: 0.22),
                                  ),
                                ),
                                child: const Text('Stop'),
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),
                  ],
                ),
              );
            },
          ),
        ),
      );
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 560),
            child: Container(
              width: double.infinity,
              padding: const EdgeInsets.all(22),
              decoration: BoxDecoration(
                gradient: LinearGradient(
                  begin: Alignment.topLeft,
                  end: Alignment.bottomRight,
                  colors: <Color>[
                    widget.accent.withValues(alpha: 0.12),
                    const Color(0xFFF8F4EC),
                  ],
                ),
                borderRadius: BorderRadius.circular(26),
                border: Border.all(
                  color: widget.accent.withValues(alpha: 0.18),
                ),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.center,
                children: <Widget>[
                  Text(
                    'Szybki recall',
                    textAlign: TextAlign.center,
                    style: theme.textTheme.titleMedium?.copyWith(
                      color: const Color(0xFF16212B),
                      fontWeight: FontWeight.w900,
                    ),
                  ),
                  const SizedBox(height: 6),
                  Text(
                    _status,
                    textAlign: TextAlign.center,
                    style: theme.textTheme.bodyMedium?.copyWith(
                      color: const Color(0xFF4A5761),
                      height: 1.45,
                    ),
                  ),
                  const SizedBox(height: 4),
                  Text(
                    _phaseHint,
                    textAlign: TextAlign.center,
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: const Color(0xFF63717C),
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                  const SizedBox(height: 18),
                  Container(
                    width: double.infinity,
                    constraints: const BoxConstraints(minHeight: 240),
                    padding: const EdgeInsets.all(20),
                    decoration: BoxDecoration(
                      color: Colors.white.withValues(alpha: 0.86),
                      borderRadius: BorderRadius.circular(24),
                    ),
                    child: Center(
                      child: AnimatedSwitcher(
                        duration: const Duration(milliseconds: 220),
                        child: _isCountingDown
                            ? _showingRoundLevelIntro
                                  ? Column(
                                      key: const ValueKey<String>(
                                        'mnemonic-round-level-intro',
                                      ),
                                      mainAxisSize: MainAxisSize.min,
                                      children: <Widget>[
                                        Text(
                                          'Utrwalanie',
                                          textAlign: TextAlign.center,
                                          style: theme.textTheme.titleMedium
                                              ?.copyWith(
                                                color: const Color(0xFF16212B),
                                                fontWeight: FontWeight.w900,
                                              ),
                                        ),
                                        const SizedBox(height: 18),
                                        _MemoryCountdownDisplay(
                                          label: _countdownLabel,
                                          accent: widget.accent,
                                          valueKeyPrefix:
                                              'mnemonic-vault-countdown',
                                        ),
                                      ],
                                    )
                                  : _MemoryCountdownDisplay(
                                      label: _countdownLabel,
                                      accent: widget.accent,
                                      valueKeyPrefix:
                                          'mnemonic-vault-countdown',
                                    )
                            : _showingPrompt && currentEntry != null
                            ? SizedBox(
                                key: ValueKey<String>(
                                  'mnemonic-prompt-${currentEntry.number}',
                                ),
                                width: double.infinity,
                                child: SizedBox(
                                  height: 236,
                                  child: Stack(
                                    fit: StackFit.expand,
                                    children: <Widget>[
                                      Padding(
                                        padding: const EdgeInsets.only(
                                          bottom: 84,
                                        ),
                                        child: Center(
                                          child: Text(
                                            _formatMnemonicNumber(
                                              currentEntry.number,
                                            ),
                                            style: theme.textTheme.displayMedium
                                                ?.copyWith(
                                                  color: const Color(
                                                    0xFF16212B,
                                                  ),
                                                  fontWeight: FontWeight.w900,
                                                ),
                                          ),
                                        ),
                                      ),
                                      Align(
                                        alignment: Alignment.bottomCenter,
                                        child: Padding(
                                          padding: const EdgeInsets.only(
                                            bottom: 0,
                                          ),
                                          child: _buildPromptDecisionButtons(
                                            height: 56,
                                          ),
                                        ),
                                      ),
                                    ],
                                  ),
                                ),
                              )
                            : _finished
                            ? Column(
                                key: const ValueKey<String>('mnemonic-finish'),
                                mainAxisSize: MainAxisSize.min,
                                children: <Widget>[
                                  Container(
                                    padding: const EdgeInsets.all(18),
                                    decoration: BoxDecoration(
                                      color: _memorySuccessColor.withValues(
                                        alpha: 0.14,
                                      ),
                                      shape: BoxShape.circle,
                                    ),
                                    child: const Icon(
                                      Icons.verified_rounded,
                                      size: 52,
                                      color: _memorySuccessColor,
                                    ),
                                  ),
                                  const SizedBox(height: 16),
                                  Icon(
                                    Icons.workspace_premium_rounded,
                                    size: 30,
                                    color: widget.accent,
                                  ),
                                  const SizedBox(height: 14),
                                  Text(
                                    'Gratulacje, pamiętasz wszystkie cyfry na pamięć!',
                                    textAlign: TextAlign.center,
                                    style: theme.textTheme.headlineSmall
                                        ?.copyWith(
                                          color: const Color(0xFF16212B),
                                          fontWeight: FontWeight.w900,
                                          height: 1.15,
                                        ),
                                  ),
                                ],
                              )
                            : Column(
                                key: const ValueKey<String>('mnemonic-idle'),
                                mainAxisSize: MainAxisSize.min,
                                children: <Widget>[
                                  Icon(
                                    Icons.casino_outlined,
                                    size: 46,
                                    color: widget.accent,
                                  ),
                                  const SizedBox(height: 14),
                                  Text(
                                    'Losuj liczby z całej bazy',
                                    textAlign: TextAlign.center,
                                    style: theme.textTheme.titleLarge?.copyWith(
                                      color: const Color(0xFF16212B),
                                      fontWeight: FontWeight.w900,
                                    ),
                                  ),
                                  const SizedBox(height: 8),
                                  Text(
                                    'Po pierwszej rundzie zobaczysz już tylko cyfry oznaczone jako Nie.',
                                    textAlign: TextAlign.center,
                                    style: theme.textTheme.bodyMedium?.copyWith(
                                      color: const Color(0xFF4A5761),
                                      height: 1.45,
                                    ),
                                  ),
                                ],
                              ),
                      ),
                    ),
                  ),
                  const SizedBox(height: 18),
                  if (_isCountingDown || _showingPrompt)
                    OutlinedButton(
                      onPressed: () => _pauseSession(
                        'Trening zatrzymany. Możesz ruszyć dalej, kiedy chcesz.',
                      ),
                      child: const Text('Zatrzymaj'),
                    )
                  else
                    Wrap(
                      alignment: WrapAlignment.center,
                      spacing: 10,
                      runSpacing: 10,
                      children: <Widget>[
                        FilledButton(
                          onPressed: _handleStartAction,
                          child: Text(
                            _finished
                                ? 'Zagraj jeszcze raz'
                                : _rounds == 0
                                ? 'Start sesji'
                                : 'Losuj dalej',
                          ),
                        ),
                        if (_history.isNotEmpty)
                          OutlinedButton(
                            onPressed: _resetTrainer,
                            child: const Text('Wyczyść bieżącą sesję'),
                          ),
                      ],
                    ),
                ],
              ),
            ),
          ),
        ),
        const SizedBox(height: 18),
        Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 560),
            child: _buildRecallHistoryLauncherCard(theme),
          ),
        ),
      ],
    );
  }
}

class _MnemonicRecallMetricCard extends StatelessWidget {
  const _MnemonicRecallMetricCard({
    required this.label,
    required this.value,
    required this.detail,
    required this.tint,
  });

  final String label;
  final String value;
  final String detail;
  final Color tint;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final palette = context.appPalette;

    final card = Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: palette.surface,
        borderRadius: BorderRadius.circular(18),
        border: Border.all(color: tint.withValues(alpha: 0.18)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Text(
            label,
            style: theme.textTheme.labelLarge?.copyWith(
              color: tint,
              fontWeight: FontWeight.w800,
              letterSpacing: 0.4,
            ),
          ),
          const SizedBox(height: 8),
          Text(
            value,
            style: theme.textTheme.titleMedium?.copyWith(
              color: palette.primaryText,
              fontWeight: FontWeight.w900,
            ),
          ),
          const SizedBox(height: 6),
          Text(
            detail,
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
            style: theme.textTheme.bodySmall?.copyWith(
              color: palette.secondaryText,
              height: 1.35,
              fontWeight: FontWeight.w700,
            ),
          ),
        ],
      ),
    );
    return card;
  }
}

class _MnemonicRecallMetricCarousel extends StatefulWidget {
  const _MnemonicRecallMetricCarousel({required this.children});

  final List<Widget> children;

  @override
  State<_MnemonicRecallMetricCarousel> createState() =>
      _MnemonicRecallMetricCarouselState();
}

class _MnemonicRecallMetricCarouselState
    extends State<_MnemonicRecallMetricCarousel> {
  static const Duration _autoScrollInterval = Duration(seconds: 2);
  static const Duration _autoScrollDuration = Duration(milliseconds: 520);

  late PageController _pageController;
  Timer? _autoScrollTimer;
  double? _viewportFraction;
  int _currentIndex = 0;

  @override
  void initState() {
    super.initState();
    _pageController = PageController();
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final screenWidth = MediaQuery.sizeOf(context).width;
    final nextViewportFraction = switch (screenWidth) {
      >= 900 => 0.42,
      >= 720 => 0.5,
      >= 560 => 0.62,
      _ => 0.84,
    };

    if (_viewportFraction == nextViewportFraction) {
      return;
    }

    final previousController = _pageController;
    _viewportFraction = nextViewportFraction;
    _pageController = PageController(
      initialPage: _currentIndex,
      viewportFraction: nextViewportFraction,
    );
    previousController.dispose();
    _restartAutoScroll();
  }

  @override
  void didUpdateWidget(covariant _MnemonicRecallMetricCarousel oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.children.length == oldWidget.children.length) {
      return;
    }

    if (widget.children.isEmpty) {
      _currentIndex = 0;
    } else {
      _currentIndex = min(_currentIndex, widget.children.length - 1);
    }
    _restartAutoScroll();
  }

  void _restartAutoScroll() {
    _autoScrollTimer?.cancel();
    if (!mounted || widget.children.length < 2) {
      return;
    }

    _autoScrollTimer = Timer.periodic(_autoScrollInterval, (Timer timer) {
      if (!mounted ||
          !_pageController.hasClients ||
          widget.children.length < 2) {
        return;
      }

      final nextIndex = (_currentIndex + 1) % widget.children.length;
      _pageController.animateToPage(
        nextIndex,
        duration: _autoScrollDuration,
        curve: Curves.easeInOutCubic,
      );
    });
  }

  void _pauseAutoScroll() {
    _autoScrollTimer?.cancel();
  }

  @override
  void dispose() {
    _autoScrollTimer?.cancel();
    _pageController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Listener(
      onPointerDown: (_) => _pauseAutoScroll(),
      onPointerUp: (_) => _restartAutoScroll(),
      onPointerCancel: (_) => _restartAutoScroll(),
      child: SizedBox(
        key: const ValueKey<String>('mnemonic-recall-metric-carousel'),
        height: 136,
        child: PageView.builder(
          controller: _pageController,
          padEnds: false,
          itemCount: widget.children.length,
          onPageChanged: (int index) {
            _currentIndex = index;
          },
          itemBuilder: (BuildContext context, int index) {
            return Padding(
              padding: EdgeInsets.only(
                right: index == widget.children.length - 1 ? 0 : 12,
              ),
              child: widget.children[index],
            );
          },
        ),
      ),
    );
  }
}

class _MnemonicRecallHistoryContent extends StatefulWidget {
  const _MnemonicRecallHistoryContent({
    required this.accent,
    required this.historyLoaded,
    required this.sessionHistory,
    required this.difficultyOverview,
  });

  final Color accent;
  final bool historyLoaded;
  final List<_MnemonicRecallSessionRecord> sessionHistory;
  final List<_MnemonicRecallDifficultyAggregate> difficultyOverview;

  @override
  State<_MnemonicRecallHistoryContent> createState() =>
      _MnemonicRecallHistoryContentState();
}

class _MnemonicRecallHistoryContentState
    extends State<_MnemonicRecallHistoryContent> {
  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final palette = context.appPalette;
    final latestSession = widget.sessionHistory.isEmpty
        ? null
        : widget.sessionHistory.first;
    final stableCount = latestSession == null
        ? 0
        : _mnemonicDigitEntries.length - latestSession.problemDigitCount;
    final progressValue = latestSession == null
        ? 0.0
        : stableCount / _mnemonicDigitEntries.length;
    final topRecurringDigit = widget.difficultyOverview.isEmpty
        ? null
        : widget.difficultyOverview.first;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        Container(
          key: const ValueKey<String>('mnemonic-recall-history-header'),
          width: double.infinity,
          padding: const EdgeInsets.all(22),
          decoration: BoxDecoration(
            gradient: LinearGradient(
              begin: Alignment.topLeft,
              end: Alignment.bottomRight,
              colors: <Color>[
                widget.accent.withValues(alpha: 0.14),
                palette.surfaceStrong,
              ],
            ),
            borderRadius: BorderRadius.circular(24),
            border: Border.all(color: widget.accent.withValues(alpha: 0.18)),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              Text(
                'Historia wyników Recall',
                style: theme.textTheme.titleLarge?.copyWith(
                  color: palette.primaryText,
                  fontWeight: FontWeight.w900,
                ),
              ),
              const SizedBox(height: 6),
              Text(
                'Tutaj zapisują się tylko trudne cyfry, czyli te które wróciły do dodatkowych rund. Widzisz pełną historię, dzień, godzinę, czas sesji i progres do czystej sesji bez problemów.',
                style: theme.textTheme.bodyMedium?.copyWith(
                  color: palette.secondaryText,
                  height: 1.45,
                ),
              ),
            ],
          ),
        ),
        const SizedBox(height: 18),
        if (!widget.historyLoaded)
          const LinearProgressIndicator(minHeight: 4)
        else if (widget.sessionHistory.isEmpty)
          Container(
            width: double.infinity,
            padding: const EdgeInsets.all(20),
            decoration: BoxDecoration(
              color: palette.surface,
              borderRadius: BorderRadius.circular(22),
              border: Border.all(color: palette.surfaceBorder),
            ),
            child: Text(
              'Nie ma jeszcze zapisanej historii. Zakończ pierwszą pełną sesję Recall, a skrzynia zacznie zbierać trudne cyfry wraz z datą i godziną.',
              style: theme.textTheme.bodyLarge?.copyWith(
                color: palette.secondaryText,
                height: 1.5,
              ),
            ),
          )
        else ...<Widget>[
          _MnemonicRecallMetricCarousel(
            children: <Widget>[
              _MnemonicRecallMetricCard(
                label: 'Ostatnia sesja',
                value: _digitCountLabel(latestSession!.problemDigitCount),
                detail:
                    '${_formatSessionDateLabel(latestSession.dateKey)} • ${_formatSessionTimeLabel(latestSession.completedAtIso)}',
                tint: widget.accent,
              ),
              _MnemonicRecallMetricCard(
                label: 'Do czystej rundy',
                value: _digitCountLabel(latestSession.problemDigitCount),
                detail: _buildMnemonicRecallProgressDetail(latestSession),
                tint: latestSession.problemDigitCount == 0
                    ? _memorySuccessColor
                    : const Color(0xFFD1802F),
              ),
              _MnemonicRecallMetricCard(
                label: 'Zapisane sesje',
                value:
                    '${widget.sessionHistory.length} ${_memoryPluralLabel(widget.sessionHistory.length, singular: 'zapis', paucal: 'zapisy', plural: 'zapisów')}',
                detail: topRecurringDigit == null
                    ? 'bez aktywnych problemów'
                    : 'top cyfra ${_formatMnemonicNumber(topRecurringDigit.number)} • ${_mnemonicRecallMistakeCountLabel(topRecurringDigit.totalMistakes)}',
                tint: const Color(0xFF526A9E),
              ),
            ],
          ),
          const SizedBox(height: 18),
          Container(
            width: double.infinity,
            padding: const EdgeInsets.all(16),
            decoration: BoxDecoration(
              color: palette.surface,
              borderRadius: BorderRadius.circular(20),
              border: Border.all(color: palette.surfaceBorder),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                Row(
                  children: <Widget>[
                    Expanded(
                      child: Text(
                        latestSession.problemDigitCount == 0
                            ? 'Ostatnia sesja była czysta'
                            : 'Progres do czystej rundy',
                        style: theme.textTheme.titleSmall?.copyWith(
                          color: palette.primaryText,
                          fontWeight: FontWeight.w800,
                        ),
                      ),
                    ),
                    Text(
                      '${(progressValue * 100).round()}%',
                      style: theme.textTheme.titleSmall?.copyWith(
                        color: widget.accent,
                        fontWeight: FontWeight.w900,
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 10),
                ClipRRect(
                  borderRadius: BorderRadius.circular(999),
                  child: LinearProgressIndicator(
                    minHeight: 10,
                    value: progressValue.clamp(0.0, 1.0),
                    backgroundColor: widget.accent.withValues(alpha: 0.08),
                    valueColor: AlwaysStoppedAnimation<Color>(
                      latestSession.problemDigitCount == 0
                          ? _memorySuccessColor
                          : widget.accent,
                    ),
                  ),
                ),
                const SizedBox(height: 10),
                Text(
                  latestSession.problemDigitCount == 0
                      ? 'W ostatniej sesji żadna cyfra nie wróciła do poprawki. To jest stan docelowy.'
                      : 'W ostatniej sesji zostało ${_digitCountLabel(latestSession.problemDigitCount)} do dopracowania, a ${_digitCountLabel(stableCount)} przeszło czysto od razu.',
                  style: theme.textTheme.bodyMedium?.copyWith(
                    color: palette.secondaryText,
                    height: 1.45,
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: 18),
          Text(
            latestSession.problemDigits.isEmpty
                ? 'Aktualnie bez problematycznych cyfr'
                : 'Aktualnie problematyczne cyfry',
            style: theme.textTheme.titleSmall?.copyWith(
              color: palette.primaryText,
              fontWeight: FontWeight.w800,
            ),
          ),
          const SizedBox(height: 10),
          if (latestSession.problemDigits.isEmpty)
            Container(
              width: double.infinity,
              padding: const EdgeInsets.all(16),
              decoration: BoxDecoration(
                color: _memorySuccessColor.withValues(alpha: 0.1),
                borderRadius: BorderRadius.circular(18),
                border: Border.all(
                  color: _memorySuccessColor.withValues(alpha: 0.18),
                ),
              ),
              child: Text(
                'Ostatnia runda przeszła bez żadnej cyfry do poprawki. W historii niżej nadal możesz śledzić wcześniejsze problemy i tempo poprawy.',
                style: theme.textTheme.bodyMedium?.copyWith(
                  color: const Color(0xFF215C3D),
                  height: 1.45,
                  fontWeight: FontWeight.w700,
                ),
              ),
            )
          else
            Wrap(
              spacing: 10,
              runSpacing: 10,
              children: latestSession.problemDigits
                  .map(
                    (_MnemonicRecallDigitIssue issue) =>
                        _MnemonicRecallIssueChip(
                          issue: issue,
                          accent: widget.accent,
                        ),
                  )
                  .toList(),
            ),
          const SizedBox(height: 18),
          Text(
            'Najczęściej wracające cyfry',
            style: theme.textTheme.titleSmall?.copyWith(
              color: palette.primaryText,
              fontWeight: FontWeight.w800,
            ),
          ),
          const SizedBox(height: 10),
          if (widget.difficultyOverview.isEmpty)
            Container(
              width: double.infinity,
              padding: const EdgeInsets.all(16),
              decoration: BoxDecoration(
                color: palette.surface,
                borderRadius: BorderRadius.circular(20),
                border: Border.all(color: palette.surfaceBorder),
              ),
              child: Text(
                'Na razie nie ma cyfr, które regularnie wracają jako problem w historii.',
                style: theme.textTheme.bodyMedium?.copyWith(
                  color: palette.secondaryText,
                  height: 1.45,
                ),
              ),
            )
          else
            Container(
              width: double.infinity,
              padding: const EdgeInsets.all(14),
              decoration: BoxDecoration(
                color: palette.surface,
                borderRadius: BorderRadius.circular(20),
                border: Border.all(color: palette.surfaceBorder),
              ),
              child: Column(
                children: <Widget>[
                  for (
                    var index = 0;
                    index < min(6, widget.difficultyOverview.length);
                    index++
                  ) ...<Widget>[
                    _MnemonicRecallRecurringDigitRow(
                      aggregate: widget.difficultyOverview[index],
                      accent: widget.accent,
                    ),
                    if (index != min(6, widget.difficultyOverview.length) - 1)
                      Divider(height: 18, color: palette.surfaceBorder),
                  ],
                ],
              ),
            ),
          const SizedBox(height: 18),
          Text(
            'Historia wyników',
            style: theme.textTheme.titleSmall?.copyWith(
              color: palette.primaryText,
              fontWeight: FontWeight.w800,
            ),
          ),
          const SizedBox(height: 10),
          Column(
            children: <Widget>[
              for (
                var index = 0;
                index < widget.sessionHistory.length;
                index++
              ) ...<Widget>[
                _MnemonicRecallSessionCard(
                  record: widget.sessionHistory[index],
                  accent: widget.accent,
                  summary: _buildMnemonicRecallSessionDifficultySummary(
                    widget.sessionHistory[index],
                  ),
                ),
                if (index != widget.sessionHistory.length - 1)
                  const SizedBox(height: 10),
              ],
            ],
          ),
        ],
      ],
    );
  }
}

class _MnemonicRecallRecurringDigitRow extends StatelessWidget {
  const _MnemonicRecallRecurringDigitRow({
    required this.aggregate,
    required this.accent,
  });

  final _MnemonicRecallDifficultyAggregate aggregate;
  final Color accent;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final palette = context.appPalette;

    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        Container(
          width: 54,
          padding: const EdgeInsets.symmetric(vertical: 10),
          decoration: BoxDecoration(
            color: accent.withValues(alpha: 0.1),
            borderRadius: BorderRadius.circular(14),
          ),
          alignment: Alignment.center,
          child: Text(
            _formatMnemonicNumber(aggregate.number),
            style: theme.textTheme.labelLarge?.copyWith(
              color: accent,
              fontWeight: FontWeight.w900,
            ),
          ),
        ),
        const SizedBox(width: 12),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              Row(
                children: <Widget>[
                  Expanded(
                    child: Text(
                      aggregate.label,
                      style: theme.textTheme.bodyLarge?.copyWith(
                        color: palette.primaryText,
                        fontWeight: FontWeight.w800,
                      ),
                    ),
                  ),
                  if (aggregate.currentlyProblematic)
                    Container(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 10,
                        vertical: 6,
                      ),
                      decoration: BoxDecoration(
                        color: _memoryFailureColor.withValues(alpha: 0.1),
                        borderRadius: BorderRadius.circular(999),
                      ),
                      child: Text(
                        'aktywna',
                        style: theme.textTheme.labelMedium?.copyWith(
                          color: _memoryFailureColor,
                          fontWeight: FontWeight.w800,
                        ),
                      ),
                    ),
                ],
              ),
              const SizedBox(height: 4),
              Text(
                '${_mnemonicRecallMistakeCountLabel(aggregate.totalMistakes)} • ${aggregate.sessionsWithIssue} sesje • ostatnio ${_formatSessionDateTimeLabel(aggregate.lastSeenIso)}',
                style: theme.textTheme.bodySmall?.copyWith(
                  color: palette.secondaryText,
                  fontWeight: FontWeight.w700,
                  height: 1.4,
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }
}

class _MnemonicRecallIssueChip extends StatelessWidget {
  const _MnemonicRecallIssueChip({required this.issue, required this.accent});

  final _MnemonicRecallDigitIssue issue;
  final Color accent;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final palette = context.appPalette;
    final label = _mnemonicDigitEntryByNumber[issue.number]?.label ?? 'brak';

    return SizedBox(
      width: 148,
      child: Container(
        padding: const EdgeInsets.all(14),
        decoration: BoxDecoration(
          color: palette.surface,
          borderRadius: BorderRadius.circular(18),
          border: Border.all(color: accent.withValues(alpha: 0.16)),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            Text(
              _formatMnemonicNumber(issue.number),
              style: theme.textTheme.headlineSmall?.copyWith(
                color: const Color(0xFF16212B),
                fontWeight: FontWeight.w900,
              ),
            ),
            const SizedBox(height: 4),
            Text(
              label,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: theme.textTheme.bodyMedium?.copyWith(
                color: palette.primaryText,
                fontWeight: FontWeight.w700,
                height: 1.35,
              ),
            ),
            const SizedBox(height: 10),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 7),
              decoration: BoxDecoration(
                color: _memoryFailureColor.withValues(alpha: 0.1),
                borderRadius: BorderRadius.circular(999),
              ),
              child: Text(
                '${issue.misses}x problem',
                style: theme.textTheme.labelMedium?.copyWith(
                  color: _memoryFailureColor,
                  fontWeight: FontWeight.w800,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _MnemonicRecallSessionCard extends StatelessWidget {
  const _MnemonicRecallSessionCard({
    required this.record,
    required this.accent,
    required this.summary,
  });

  final _MnemonicRecallSessionRecord record;
  final Color accent;
  final String summary;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final palette = context.appPalette;
    final stableCount = _mnemonicDigitEntries.length - record.problemDigitCount;
    final progressValue = stableCount / _mnemonicDigitEntries.length;
    final sessionMetaParts = <String>[
      _formatSessionTimeLabel(record.completedAtIso),
      '${record.rounds} rund',
      if (record.sessionDuration != null)
        _formatMnemonicRecallSessionDuration(record.sessionDuration!),
    ];

    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: palette.surface,
        borderRadius: BorderRadius.circular(18),
        border: Border.all(color: palette.surfaceBorder),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: <Widget>[
                    Text(
                      _formatSessionDateLabel(record.dateKey),
                      style: theme.textTheme.titleSmall?.copyWith(
                        color: palette.primaryText,
                        fontWeight: FontWeight.w800,
                      ),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      sessionMetaParts.join(' • '),
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: palette.secondaryText,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(width: 12),
              Container(
                padding: const EdgeInsets.symmetric(
                  horizontal: 10,
                  vertical: 8,
                ),
                decoration: BoxDecoration(
                  color: record.problemDigitCount == 0
                      ? _memorySuccessColor.withValues(alpha: 0.12)
                      : accent.withValues(alpha: 0.1),
                  borderRadius: BorderRadius.circular(999),
                ),
                child: Text(
                  record.problemDigitCount == 0
                      ? 'czysto'
                      : _digitCountLabel(record.problemDigitCount),
                  style: theme.textTheme.labelMedium?.copyWith(
                    color: record.problemDigitCount == 0
                        ? _memorySuccessColor
                        : accent,
                    fontWeight: FontWeight.w900,
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 12),
          ClipRRect(
            borderRadius: BorderRadius.circular(999),
            child: LinearProgressIndicator(
              minHeight: 8,
              value: progressValue,
              backgroundColor: accent.withValues(alpha: 0.08),
              valueColor: AlwaysStoppedAnimation<Color>(
                record.problemDigitCount == 0 ? _memorySuccessColor : accent,
              ),
            ),
          ),
          const SizedBox(height: 10),
          Text(
            'Stabilne $stableCount/${_mnemonicDigitEntries.length}',
            style: theme.textTheme.labelLarge?.copyWith(
              color: palette.primaryText,
              fontWeight: FontWeight.w800,
            ),
          ),
          const SizedBox(height: 4),
          Text(
            summary,
            style: theme.textTheme.bodyMedium?.copyWith(
              color: palette.secondaryText,
              height: 1.45,
            ),
          ),
        ],
      ),
    );
  }
}

class MnemonicSprintTrainer extends StatefulWidget {
  const MnemonicSprintTrainer({
    super.key,
    required this.accent,
    this.fullscreenOnStart = false,
    this.onSessionStarted,
  });

  final Color accent;
  final bool fullscreenOnStart;
  final VoidCallback? onSessionStarted;

  @override
  State<MnemonicSprintTrainer> createState() => _MnemonicSprintTrainerState();
}

class _MnemonicSprintTrainerState extends State<MnemonicSprintTrainer> {
  late int _selectedDisplayMilliseconds;

  @override
  void initState() {
    super.initState();
    _selectedDisplayMilliseconds = _mnemonicSprintDefaultDisplayMilliseconds;
  }

  void _setDisplayMilliseconds(double value) {
    setState(() {
      _selectedDisplayMilliseconds = value.round();
    });
  }

  Future<void> _openSession() {
    widget.onSessionStarted?.call();
    final session = MnemonicSprintSessionView(
      accent: widget.accent,
      displayMilliseconds: _selectedDisplayMilliseconds,
      autoStart: true,
      autoExitOnFinish: true,
    );

    final route = widget.fullscreenOnStart
        ? _buildExerciseSessionRoute<void>(
            builder: (BuildContext context) {
              return FullscreenTrainerPage(
                title: 'Sprint skojarzeń',
                accent: widget.accent,
                expandBody: true,
                showHeader: false,
                wrapChildInSurfaceCard: false,
                contentMaxWidth: null,
                bodyPadding: EdgeInsets.zero,
                child: session,
              );
            },
          )
        : MaterialPageRoute<void>(
            builder: (BuildContext context) {
              return Scaffold(
                appBar: AppBar(title: const Text('Sprint skojarzeń')),
                body: session,
              );
            },
          );

    return Navigator.of(context).push<void>(route);
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final palette = context.appPalette;
    final String speedLabel = _formatMnemonicSprintSpeedLabel(
      _selectedDisplayMilliseconds,
    );

    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(22),
      decoration: BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: <Color>[
            widget.accent.withValues(alpha: 0.14),
            palette.surfaceStrong,
          ],
        ),
        borderRadius: BorderRadius.circular(26),
        border: Border.all(color: widget.accent.withValues(alpha: 0.18)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Text(
            'Sprint skojarzeń',
            style: theme.textTheme.titleMedium?.copyWith(
              color: palette.primaryText,
              fontWeight: FontWeight.w900,
            ),
          ),
          const SizedBox(height: 16),
          Container(
            width: double.infinity,
            padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 16),
            decoration: BoxDecoration(
              color: palette.surface.withValues(alpha: 0.92),
              borderRadius: BorderRadius.circular(22),
              border: Border.all(color: widget.accent.withValues(alpha: 0.14)),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                Row(
                  children: <Widget>[
                    Text(
                      'Oś tempa',
                      style: theme.textTheme.titleSmall?.copyWith(
                        color: const Color(0xFF16212B),
                        fontWeight: FontWeight.w900,
                      ),
                    ),
                    const Spacer(),
                    Text(
                      speedLabel,
                      style: theme.textTheme.bodyMedium?.copyWith(
                        color: widget.accent,
                        fontWeight: FontWeight.w800,
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 10),
                SliderTheme(
                  data: SliderTheme.of(context).copyWith(
                    activeTrackColor: widget.accent,
                    inactiveTrackColor: const Color(0xFFD9DFE4),
                    thumbColor: widget.accent,
                    overlayColor: widget.accent.withValues(alpha: 0.14),
                    trackHeight: 6,
                    thumbShape: const RoundSliderThumbShape(
                      enabledThumbRadius: 9,
                    ),
                  ),
                  child: Slider(
                    key: const ValueKey<String>('mnemonic-sprint-speed-slider'),
                    min: _mnemonicSprintMinDisplayMilliseconds.toDouble(),
                    max: _mnemonicSprintMaxDisplayMilliseconds.toDouble(),
                    divisions:
                        (_mnemonicSprintMaxDisplayMilliseconds -
                            _mnemonicSprintMinDisplayMilliseconds) ~/
                        _mnemonicSprintDisplayMillisecondsStep,
                    value: _selectedDisplayMilliseconds.toDouble(),
                    label: speedLabel,
                    onChanged: _setDisplayMilliseconds,
                  ),
                ),
                Row(
                  children: <Widget>[
                    Text(
                      _formatMnemonicSprintSpeedLabel(
                        _mnemonicSprintMinDisplayMilliseconds,
                      ),
                      style: theme.textTheme.labelMedium?.copyWith(
                        color: const Color(0xFF7A8791),
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                    const Spacer(),
                    Text(
                      _formatMnemonicSprintSpeedLabel(
                        _mnemonicSprintMaxDisplayMilliseconds,
                      ),
                      style: theme.textTheme.labelMedium?.copyWith(
                        color: const Color(0xFF7A8791),
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                  ],
                ),
              ],
            ),
          ),
          const SizedBox(height: 18),
          Center(
            child: ConstrainedBox(
              constraints: const BoxConstraints(minWidth: 220, maxWidth: 280),
              child: FilledButton(
                key: const ValueKey<String>('mnemonic-sprint-start-button'),
                onPressed: _openSession,
                child: const Text('Start sprintu'),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class MnemonicSprintSessionView extends StatefulWidget {
  const MnemonicSprintSessionView({
    super.key,
    required this.accent,
    required this.displayMilliseconds,
    this.autoStart = false,
    this.autoExitOnFinish = false,
  });

  final Color accent;
  final int displayMilliseconds;
  final bool autoStart;
  final bool autoExitOnFinish;

  @override
  State<MnemonicSprintSessionView> createState() =>
      _MnemonicSprintSessionViewState();
}

class _MnemonicSprintSessionViewState extends State<MnemonicSprintSessionView> {
  static const int _startCountdownSeconds = 3;

  Timer? _countdownTimer;
  Timer? _entryTimer;
  Timer? _finishExitTimer;
  int _currentEntryIndex = 0;
  int? _countdownValue;
  bool _started = false;
  bool _reading = false;
  bool _finished = false;

  @override
  void initState() {
    super.initState();
    if (widget.autoStart) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) {
          _startSession();
        }
      });
    }
  }

  bool get _isCountingDown => _countdownValue != null;

  int get _effectiveDisplayMilliseconds => max(50, widget.displayMilliseconds);

  _MnemonicDigitEntry? get _currentEntry {
    if (!_reading || _mnemonicDigitEntries.isEmpty) {
      return null;
    }
    return _mnemonicDigitEntries[_currentEntryIndex];
  }

  int get _shownEntriesCount {
    if (_finished) {
      return _mnemonicDigitEntries.length;
    }

    if (_reading) {
      return _currentEntryIndex + 1;
    }

    return 0;
  }

  double get _progress =>
      (_shownEntriesCount / _mnemonicDigitEntries.length).clamp(0.0, 1.0);

  int get _remainingEntriesCount =>
      max(0, _mnemonicDigitEntries.length - _shownEntriesCount);

  void _startSession() {
    _finishExitTimer?.cancel();
    _countdownTimer?.cancel();
    _entryTimer?.cancel();

    setState(() {
      _started = true;
      _finished = false;
      _reading = false;
      _currentEntryIndex = 0;
    });

    _startCountdown(seconds: _startCountdownSeconds, onComplete: _beginRun);
  }

  void _startCountdown({
    required int seconds,
    required VoidCallback onComplete,
  }) {
    _finishExitTimer?.cancel();
    _countdownTimer?.cancel();
    _entryTimer?.cancel();

    setState(() {
      _reading = false;
      _countdownValue = seconds;
    });

    _countdownTimer = Timer.periodic(const Duration(seconds: 1), (Timer timer) {
      if (!mounted) {
        timer.cancel();
        return;
      }

      final current = _countdownValue;
      if (current == null) {
        timer.cancel();
        return;
      }

      if (current <= 1) {
        timer.cancel();
        onComplete();
        return;
      }

      setState(() {
        _countdownValue = current - 1;
      });
    });
  }

  void _beginRun() {
    _countdownTimer?.cancel();
    _entryTimer?.cancel();

    setState(() {
      _currentEntryIndex = 0;
      _countdownValue = null;
      _reading = true;
    });

    _entryTimer = Timer.periodic(
      Duration(milliseconds: _effectiveDisplayMilliseconds),
      (Timer timer) {
        if (!mounted) {
          timer.cancel();
          return;
        }

        if (_currentEntryIndex >= _mnemonicDigitEntries.length - 1) {
          timer.cancel();
          _finishSession();
          return;
        }

        setState(() {
          _currentEntryIndex += 1;
        });
      },
    );
  }

  void _finishSession() {
    _finishExitTimer?.cancel();
    _countdownTimer?.cancel();
    _entryTimer?.cancel();

    setState(() {
      _finished = true;
      _reading = false;
      _countdownValue = null;
    });

    if (!widget.autoExitOnFinish) {
      return;
    }

    _finishExitTimer = Timer(const Duration(seconds: 2), () {
      if (!mounted) {
        return;
      }
      Navigator.of(context).maybePop();
    });
  }

  @override
  void dispose() {
    _finishExitTimer?.cancel();
    _countdownTimer?.cancel();
    _entryTimer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final _MnemonicDigitEntry? currentEntry = _currentEntry;

    final Widget stage = !_started
        ? Column(
            key: const ValueKey<String>('mnemonic-sprint-idle'),
            mainAxisSize: MainAxisSize.min,
            children: <Widget>[
              Text(
                'Sprint skojarzeń',
                textAlign: TextAlign.center,
                style: theme.textTheme.headlineMedium?.copyWith(
                  color: const Color(0xFF102533),
                  fontWeight: FontWeight.w900,
                ),
              ),
              const SizedBox(height: 12),
              Text(
                'Cyfry lecą jedna po drugiej bez przerwy, a pod każdą od razu widzisz przypisane skojarzenie.',
                textAlign: TextAlign.center,
                style: theme.textTheme.bodyLarge?.copyWith(
                  color: const Color(0xFF5D7380),
                  height: 1.45,
                ),
              ),
              const SizedBox(height: 20),
              FilledButton(
                onPressed: _startSession,
                child: const Text('Start'),
              ),
            ],
          )
        : _finished
        ? Column(
            key: const ValueKey<String>('mnemonic-sprint-finished'),
            mainAxisSize: MainAxisSize.min,
            children: <Widget>[
              Text(
                'Koniec sprintu',
                textAlign: TextAlign.center,
                style: theme.textTheme.headlineMedium?.copyWith(
                  color: const Color(0xFF102533),
                  fontWeight: FontWeight.w900,
                ),
              ),
              const SizedBox(height: 12),
              Text(
                'Masz za sobą pełny ciąg 0-100 bez zatrzymań po drodze.',
                textAlign: TextAlign.center,
                style: theme.textTheme.bodyLarge?.copyWith(
                  color: const Color(0xFF5D7380),
                  height: 1.45,
                ),
              ),
            ],
          )
        : _isCountingDown
        ? Container(
            key: const ValueKey<String>('mnemonic-sprint-countdown-stage'),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: <Widget>[
                Text(
                  '${_countdownValue!}',
                  key: ValueKey<String>(
                    'mnemonic-sprint-countdown-${_countdownValue!}',
                  ),
                  textAlign: TextAlign.center,
                  style: theme.textTheme.displayLarge?.copyWith(
                    color: const Color(0xFF102533),
                    fontWeight: FontWeight.w900,
                  ),
                ),
              ],
            ),
          )
        : currentEntry != null
        ? Column(
            key: ValueKey<String>(
              'mnemonic-sprint-entry-${currentEntry.number}',
            ),
            mainAxisSize: MainAxisSize.min,
            children: <Widget>[
              Text(
                _formatMnemonicNumber(currentEntry.number),
                textAlign: TextAlign.center,
                style: theme.textTheme.displayLarge?.copyWith(
                  color: const Color(0xFF102533),
                  fontWeight: FontWeight.w900,
                  letterSpacing: 1.6,
                ),
              ),
              const SizedBox(height: 18),
              Text(
                currentEntry.label,
                textAlign: TextAlign.center,
                style: theme.textTheme.headlineMedium?.copyWith(
                  color: const Color(0xFF102533),
                  fontWeight: FontWeight.w900,
                ),
              ),
            ],
          )
        : const SizedBox.shrink();

    return DecoratedBox(
      decoration: BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: <Color>[
            const Color(0xFF07131C),
            widget.accent.withValues(alpha: 0.34),
            const Color(0xFF0E2531),
          ],
        ),
      ),
      child: SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 12, 16, 24),
          child: Column(
            children: <Widget>[
              Row(
                children: <Widget>[
                  IconButton(
                    key: const ValueKey<String>('mnemonic-sprint-close'),
                    onPressed: () => Navigator.of(context).maybePop(),
                    color: const Color(0xFFEEF4F7),
                    splashRadius: 24,
                    icon: const Icon(Icons.close_rounded, size: 28),
                  ),
                  const Spacer(),
                  Container(
                    key: const ValueKey<String>('mnemonic-sprint-progress'),
                    padding: const EdgeInsets.symmetric(
                      horizontal: 16,
                      vertical: 12,
                    ),
                    decoration: BoxDecoration(
                      color: const Color(0xFF102533).withValues(alpha: 0.72),
                      borderRadius: BorderRadius.circular(22),
                      border: Border.all(
                        color: Colors.white.withValues(alpha: 0.12),
                      ),
                    ),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.end,
                      children: <Widget>[
                        Text(
                          '$_shownEntriesCount/${_mnemonicDigitEntries.length}',
                          style: theme.textTheme.titleMedium?.copyWith(
                            color: const Color(0xFFEEF4F7),
                            fontWeight: FontWeight.w900,
                          ),
                        ),
                        const SizedBox(height: 2),
                        Text(
                          'zostało $_remainingEntriesCount',
                          style: theme.textTheme.bodySmall?.copyWith(
                            color: const Color(
                              0xFFEEF4F7,
                            ).withValues(alpha: 0.82),
                            fontWeight: FontWeight.w700,
                          ),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
              Expanded(
                child: Center(
                  child: ConstrainedBox(
                    constraints: const BoxConstraints(maxWidth: 540),
                    child: Container(
                      width: double.infinity,
                      padding: const EdgeInsets.symmetric(
                        horizontal: 28,
                        vertical: 42,
                      ),
                      decoration: BoxDecoration(
                        gradient: const LinearGradient(
                          begin: Alignment.topLeft,
                          end: Alignment.bottomRight,
                          colors: <Color>[Color(0xFFF9F3EA), Color(0xFFEDE2D2)],
                        ),
                        borderRadius: BorderRadius.circular(34),
                        border: Border.all(
                          color: Colors.white.withValues(alpha: 0.46),
                        ),
                        boxShadow: <BoxShadow>[
                          BoxShadow(
                            color: Colors.black.withValues(alpha: 0.18),
                            blurRadius: 34,
                            offset: const Offset(0, 18),
                          ),
                        ],
                      ),
                      child: ConstrainedBox(
                        constraints: const BoxConstraints(minHeight: 320),
                        child: Center(
                          child: AnimatedSwitcher(
                            duration: const Duration(milliseconds: 180),
                            switchInCurve: Curves.easeOutCubic,
                            switchOutCurve: Curves.easeInCubic,
                            transitionBuilder:
                                (Widget child, Animation<double> animation) {
                                  return FadeTransition(
                                    opacity: animation,
                                    child: child,
                                  );
                                },
                            child: stage,
                          ),
                        ),
                      ),
                    ),
                  ),
                ),
              ),
              ClipRRect(
                borderRadius: BorderRadius.circular(999),
                child: LinearProgressIndicator(
                  minHeight: 10,
                  value: _progress,
                  backgroundColor: Colors.white.withValues(alpha: 0.14),
                  valueColor: AlwaysStoppedAnimation<Color>(widget.accent),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

enum _MnemonicSequencePhase {
  idle,
  countdown,
  memorizing,
  answering,
  feedback,
  paused,
  finished,
}

class _MnemonicNumberSequenceStrip extends StatelessWidget {
  const _MnemonicNumberSequenceStrip({
    required this.numbers,
    required this.accent,
    this.compact = false,
  });

  final List<int> numbers;
  final Color accent;
  final bool compact;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final Color background = Colors.white;
    final Color border = accent.withValues(alpha: 0.14);
    final Color textColor = const Color(0xFF16212B);
    final double horizontalPadding = compact ? 10 : 12;
    final double verticalPadding = compact ? 10 : 12;
    final double spacing = compact ? 8 : 10;

    if (numbers.length <= 5) {
      return SizedBox(
        width: double.infinity,
        child: FittedBox(
          fit: BoxFit.scaleDown,
          alignment: Alignment.center,
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: numbers.asMap().entries.map((MapEntry<int, int> entry) {
              final bool last = entry.key == numbers.length - 1;
              return Padding(
                padding: EdgeInsets.only(right: last ? 0 : spacing),
                child: Container(
                  constraints: const BoxConstraints(minWidth: 48),
                  padding: EdgeInsets.symmetric(
                    horizontal: horizontalPadding,
                    vertical: verticalPadding,
                  ),
                  decoration: BoxDecoration(
                    color: background,
                    borderRadius: BorderRadius.circular(compact ? 16 : 18),
                    border: Border.all(color: border),
                  ),
                  child: Text(
                    _formatMnemonicNumber(entry.value),
                    textAlign: TextAlign.center,
                    style: theme.textTheme.titleLarge?.copyWith(
                      color: textColor,
                      fontWeight: FontWeight.w900,
                      letterSpacing: 0.8,
                    ),
                  ),
                ),
              );
            }).toList(),
          ),
        ),
      );
    }

    return SizedBox(
      width: double.infinity,
      child: LayoutBuilder(
        builder: (BuildContext context, BoxConstraints constraints) {
          final int columns = _mnemonicSequenceColumnsForCount(
            numbers.length,
            compact: compact,
          );
          final double maxWidth = constraints.maxWidth.isFinite
              ? constraints.maxWidth
              : MediaQuery.sizeOf(context).width;
          final double availableWidth = max(
            0.0,
            maxWidth - spacing * (columns - 1),
          );
          final double itemWidth = availableWidth / columns;

          return Wrap(
            alignment: WrapAlignment.center,
            spacing: spacing,
            runSpacing: spacing,
            children: numbers.asMap().entries.map((MapEntry<int, int> entry) {
              return SizedBox(
                width: itemWidth,
                child: Container(
                  padding: EdgeInsets.symmetric(
                    horizontal: horizontalPadding,
                    vertical: verticalPadding,
                  ),
                  decoration: BoxDecoration(
                    color: background,
                    borderRadius: BorderRadius.circular(compact ? 16 : 18),
                    border: Border.all(color: border),
                  ),
                  child: FittedBox(
                    fit: BoxFit.scaleDown,
                    child: Text(
                      _formatMnemonicNumber(entry.value),
                      textAlign: TextAlign.center,
                      style: theme.textTheme.titleLarge?.copyWith(
                        color: textColor,
                        fontWeight: FontWeight.w900,
                        letterSpacing: 0.8,
                      ),
                    ),
                  ),
                ),
              );
            }).toList(),
          );
        },
      ),
    );
  }
}

class _MnemonicSequenceStageHeader extends StatelessWidget {
  const _MnemonicSequenceStageHeader({
    required this.label,
    required this.accent,
    this.secondaryLabel,
  });

  final String label;
  final Color accent;
  final String? secondaryLabel;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return Container(
      width: double.infinity,
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
      decoration: BoxDecoration(
        color: accent.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(22),
      ),
      child: Row(
        children: <Widget>[
          Expanded(
            child: Text(
              label,
              style: theme.textTheme.titleSmall?.copyWith(
                color: accent,
                fontWeight: FontWeight.w900,
              ),
            ),
          ),
          if (secondaryLabel != null)
            Text(
              secondaryLabel!,
              style: theme.textTheme.titleSmall?.copyWith(
                color: accent,
                fontWeight: FontWeight.w900,
              ),
            ),
        ],
      ),
    );
  }
}

class _MnemonicSequenceStageShell extends StatelessWidget {
  const _MnemonicSequenceStageShell({
    super.key,
    required this.accent,
    required this.label,
    required this.child,
    this.secondaryLabel,
  });

  final Color accent;
  final String label;
  final Widget child;
  final String? secondaryLabel;

  @override
  Widget build(BuildContext context) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: <Widget>[
        _MnemonicSequenceStageHeader(
          label: label,
          accent: accent,
          secondaryLabel: secondaryLabel,
        ),
        const SizedBox(height: 24),
        child,
      ],
    );
  }
}

class _MnemonicSequenceAnswerGrid extends StatelessWidget {
  const _MnemonicSequenceAnswerGrid({
    required this.controllers,
    required this.focusNodes,
    required this.expectedValues,
    required this.accent,
    required this.onChanged,
    required this.onSubmitted,
  });

  final List<TextEditingController> controllers;
  final List<FocusNode> focusNodes;
  final List<int> expectedValues;
  final Color accent;
  final void Function(int index, String value) onChanged;
  final void Function(int index) onSubmitted;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    const double spacing = 10;

    return LayoutBuilder(
      builder: (BuildContext context, BoxConstraints constraints) {
        final int columns = _mnemonicSequenceColumnsForCount(
          controllers.length,
          input: true,
        );
        final double maxWidth = constraints.maxWidth.isFinite
            ? constraints.maxWidth
            : MediaQuery.sizeOf(context).width;
        final double availableWidth = max(
          0.0,
          maxWidth - spacing * (columns - 1),
        );
        final double fieldWidth = availableWidth / columns;

        return Wrap(
          key: const ValueKey<String>('mnemonic-sequence-answer-grid'),
          alignment: WrapAlignment.center,
          spacing: spacing,
          runSpacing: spacing,
          children: List<Widget>.generate(controllers.length, (int index) {
            final String rawValue = controllers[index].text.trim();
            final int? parsedValue = int.tryParse(rawValue);
            final bool accepted =
                rawValue.isNotEmpty &&
                index < expectedValues.length &&
                parsedValue == expectedValues[index];
            final bool invalid =
                rawValue.isNotEmpty &&
                (parsedValue == null || parsedValue < 0 || parsedValue > 100);
            final Color borderColor = accepted
                ? _memorySuccessColor
                : invalid
                ? const Color(0xFFB42318)
                : accent.withValues(alpha: 0.2);
            final Color fillColor = accepted
                ? _memorySuccessColor.withValues(alpha: 0.12)
                : Colors.white;

            return SizedBox(
              width: fieldWidth,
              child: TextField(
                key: ValueKey<String>('mnemonic-sequence-answer-field-$index'),
                controller: controllers[index],
                focusNode: focusNodes[index],
                textAlign: TextAlign.center,
                keyboardType: TextInputType.number,
                textInputAction: index == controllers.length - 1
                    ? TextInputAction.done
                    : TextInputAction.next,
                inputFormatters: <TextInputFormatter>[
                  FilteringTextInputFormatter.digitsOnly,
                  LengthLimitingTextInputFormatter(3),
                ],
                style: theme.textTheme.titleLarge?.copyWith(
                  color: const Color(0xFF16212B),
                  fontWeight: FontWeight.w900,
                ),
                decoration: InputDecoration(
                  hintText: '${index + 1}',
                  counterText: '',
                  filled: true,
                  fillColor: fillColor,
                  contentPadding: const EdgeInsets.symmetric(
                    horizontal: 8,
                    vertical: 14,
                  ),
                  border: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(18),
                    borderSide: BorderSide(color: borderColor),
                  ),
                  enabledBorder: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(18),
                    borderSide: BorderSide(color: borderColor),
                  ),
                  focusedBorder: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(18),
                    borderSide: BorderSide(
                      color: invalid ? const Color(0xFFB42318) : accent,
                      width: 1.6,
                    ),
                  ),
                ),
                onChanged: (String value) => onChanged(index, value),
                onSubmitted: (_) => onSubmitted(index),
              ),
            );
          }),
        );
      },
    );
  }
}

class MnemonicSequenceTrainer extends StatefulWidget {
  const MnemonicSequenceTrainer({
    super.key,
    required this.accent,
    this.fullscreenOnStart = false,
    this.onSessionStarted,
  });

  final Color accent;
  final bool fullscreenOnStart;
  final VoidCallback? onSessionStarted;

  @override
  State<MnemonicSequenceTrainer> createState() =>
      _MnemonicSequenceTrainerState();
}

class _MnemonicSequenceTrainerState extends State<MnemonicSequenceTrainer> {
  late int _selectedItemCount;
  late int _selectedMemorizeSeconds;

  @override
  void initState() {
    super.initState();
    _selectedItemCount = 5;
    _selectedMemorizeSeconds = _mnemonicSequenceDefaultMemorizeSecondsForCount(
      _selectedItemCount,
    );
  }

  void _setItemCount(double value) {
    setState(() {
      _selectedItemCount = value.round();
    });
  }

  void _setMemorizeSeconds(double value) {
    setState(() {
      _selectedMemorizeSeconds = value.round();
    });
  }

  Future<void> _openSession() {
    widget.onSessionStarted?.call();
    final session = MnemonicSequenceSessionView(
      accent: widget.accent,
      itemCount: _selectedItemCount,
      memorizeSeconds: _selectedMemorizeSeconds,
      autoStart: true,
    );

    final route = widget.fullscreenOnStart
        ? _buildExerciseSessionRoute<void>(
            builder: (BuildContext context) {
              return FullscreenTrainerPage(
                title: 'Seria cyfr',
                accent: widget.accent,
                expandBody: true,
                showHeader: false,
                wrapChildInSurfaceCard: false,
                contentMaxWidth: null,
                bodyPadding: EdgeInsets.zero,
                child: session,
              );
            },
          )
        : MaterialPageRoute<void>(
            builder: (BuildContext context) {
              return Scaffold(
                appBar: AppBar(title: const Text('Seria cyfr')),
                body: session,
              );
            },
          );

    return Navigator.of(context).push<void>(route);
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final palette = context.appPalette;
    final int memorizeSeconds = _selectedMemorizeSeconds;

    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(22),
      decoration: BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: <Color>[
            widget.accent.withValues(alpha: 0.14),
            palette.surfaceStrong,
          ],
        ),
        borderRadius: BorderRadius.circular(26),
        border: Border.all(color: widget.accent.withValues(alpha: 0.18)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Container(
            width: double.infinity,
            padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 16),
            decoration: BoxDecoration(
              color: palette.surface.withValues(alpha: 0.92),
              borderRadius: BorderRadius.circular(22),
              border: Border.all(color: widget.accent.withValues(alpha: 0.14)),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                Row(
                  children: <Widget>[
                    Text(
                      'Liczba elementów',
                      style: theme.textTheme.titleSmall?.copyWith(
                        color: palette.primaryText,
                        fontWeight: FontWeight.w900,
                      ),
                    ),
                    const Spacer(),
                    Text(
                      _memoryElementCountLabel(_selectedItemCount),
                      style: theme.textTheme.bodyMedium?.copyWith(
                        color: widget.accent,
                        fontWeight: FontWeight.w800,
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 10),
                SliderTheme(
                  data: SliderTheme.of(context).copyWith(
                    activeTrackColor: widget.accent,
                    inactiveTrackColor: const Color(0xFFD9DFE4),
                    thumbColor: widget.accent,
                    overlayColor: widget.accent.withValues(alpha: 0.14),
                    trackHeight: 6,
                    thumbShape: const RoundSliderThumbShape(
                      enabledThumbRadius: 9,
                    ),
                  ),
                  child: Slider(
                    key: const ValueKey<String>(
                      'mnemonic-sequence-item-slider',
                    ),
                    min: _mnemonicSequenceMinItems.toDouble(),
                    max: _mnemonicSequenceMaxItems.toDouble(),
                    divisions:
                        _mnemonicSequenceMaxItems - _mnemonicSequenceMinItems,
                    value: _selectedItemCount.toDouble(),
                    label: _memoryElementCountLabel(_selectedItemCount),
                    onChanged: _setItemCount,
                  ),
                ),
                Row(
                  children: <Widget>[
                    Text(
                      '$_mnemonicSequenceMinItems',
                      style: theme.textTheme.labelMedium?.copyWith(
                        color: const Color(0xFF7A8791),
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                    const Spacer(),
                    Text(
                      'oś długości',
                      style: theme.textTheme.labelMedium?.copyWith(
                        color: const Color(0xFF7A8791),
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                    const Spacer(),
                    Text(
                      '$_mnemonicSequenceMaxItems',
                      style: theme.textTheme.labelMedium?.copyWith(
                        color: const Color(0xFF7A8791),
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 18),
                Row(
                  children: <Widget>[
                    Text(
                      'Czas ekspozycji',
                      style: theme.textTheme.titleSmall?.copyWith(
                        color: const Color(0xFF16212B),
                        fontWeight: FontWeight.w900,
                      ),
                    ),
                    const Spacer(),
                    Text(
                      '$memorizeSeconds s',
                      style: theme.textTheme.bodyMedium?.copyWith(
                        color: widget.accent,
                        fontWeight: FontWeight.w800,
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 10),
                SliderTheme(
                  data: SliderTheme.of(context).copyWith(
                    activeTrackColor: widget.accent,
                    inactiveTrackColor: const Color(0xFFD9DFE4),
                    thumbColor: widget.accent,
                    overlayColor: widget.accent.withValues(alpha: 0.14),
                    trackHeight: 6,
                    thumbShape: const RoundSliderThumbShape(
                      enabledThumbRadius: 9,
                    ),
                  ),
                  child: Slider(
                    key: const ValueKey<String>(
                      'mnemonic-sequence-time-slider',
                    ),
                    min: _mnemonicSequenceMinMemorizeSeconds.toDouble(),
                    max: _mnemonicSequenceMaxMemorizeSeconds.toDouble(),
                    divisions:
                        _mnemonicSequenceMaxMemorizeSeconds -
                        _mnemonicSequenceMinMemorizeSeconds,
                    value: memorizeSeconds.toDouble(),
                    label: '$memorizeSeconds s',
                    onChanged: _setMemorizeSeconds,
                  ),
                ),
                Row(
                  children: <Widget>[
                    Text(
                      '$_mnemonicSequenceMinMemorizeSeconds',
                      style: theme.textTheme.labelMedium?.copyWith(
                        color: const Color(0xFF7A8791),
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                    const Spacer(),
                    Text(
                      'sekundy',
                      style: theme.textTheme.labelMedium?.copyWith(
                        color: const Color(0xFF7A8791),
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                    const Spacer(),
                    Text(
                      '$_mnemonicSequenceMaxMemorizeSeconds',
                      style: theme.textTheme.labelMedium?.copyWith(
                        color: const Color(0xFF7A8791),
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                  ],
                ),
              ],
            ),
          ),
          const SizedBox(height: 18),
          Center(
            child: ConstrainedBox(
              constraints: const BoxConstraints(minWidth: 220, maxWidth: 280),
              child: FilledButton(
                key: const ValueKey<String>('mnemonic-sequence-start-button'),
                onPressed: _openSession,
                child: const Text('Start serii'),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class MnemonicSequenceSessionView extends StatefulWidget {
  const MnemonicSequenceSessionView({
    super.key,
    required this.accent,
    required this.itemCount,
    required this.memorizeSeconds,
    this.autoStart = false,
    this.autoExitOnFinish = false,
  });

  final Color accent;
  final int itemCount;
  final int memorizeSeconds;
  final bool autoStart;
  final bool autoExitOnFinish;

  @override
  State<MnemonicSequenceSessionView> createState() =>
      _MnemonicSequenceSessionViewState();
}

class _MnemonicSequenceSessionViewState
    extends State<MnemonicSequenceSessionView> {
  static const int _startCountdownSeconds = 3;

  final Random _random = Random();
  late final List<TextEditingController> _answerControllers;
  late final List<FocusNode> _answerFocusNodes;

  Timer? _countdownTimer;
  Timer? _memorizeTimer;
  Timer? _finishExitTimer;

  _MnemonicSequencePhase _phase = _MnemonicSequencePhase.idle;
  _MnemonicSequencePhase? _pausedPhase;
  int _roundIndex = 0;
  int _correctRounds = 0;
  int? _countdownValue;
  int _memorizeSecondsRemaining = 0;
  List<int> _currentSequence = <int>[];
  List<int> _lastSubmittedSequence = <int>[];
  bool _lastAnswerCorrect = false;
  String _status = 'Start uruchamia serię 10 rund cyfr.';

  bool get _isCountingDown => _phase == _MnemonicSequencePhase.countdown;
  bool get _isMemorizing => _phase == _MnemonicSequencePhase.memorizing;
  bool get _isAnswering => _phase == _MnemonicSequencePhase.answering;
  bool get _isFeedback => _phase == _MnemonicSequencePhase.feedback;
  bool get _isPaused => _phase == _MnemonicSequencePhase.paused;
  bool get _isFinished => _phase == _MnemonicSequencePhase.finished;

  int get _memorizeSeconds => widget.memorizeSeconds;

  int get _displayRoundNumber => min(_roundIndex + 1, _mnemonicSequenceRounds);

  int get _completedRounds {
    if (_isFinished) {
      return _mnemonicSequenceRounds;
    }
    if (_isFeedback) {
      return _roundIndex + 1;
    }
    return _roundIndex;
  }

  double get _progress =>
      (_completedRounds / _mnemonicSequenceRounds).clamp(0.0, 1.0);

  int get _filledAnswerCount => _answerControllers
      .where(
        (TextEditingController controller) => controller.text.trim().isNotEmpty,
      )
      .length;

  bool get _canSubmit =>
      _readAnswerValues(requireAll: true).length == widget.itemCount;

  bool _matchesExpectedValue(int index, String rawValue) {
    if (index < 0 || index >= _currentSequence.length) {
      return false;
    }
    final int? value = int.tryParse(rawValue.trim());
    return value != null && value == _currentSequence[index];
  }

  bool get _hasFullCorrectAnswer {
    if (_currentSequence.length != widget.itemCount) {
      return false;
    }

    for (var index = 0; index < _answerControllers.length; index += 1) {
      if (!_matchesExpectedValue(index, _answerControllers[index].text)) {
        return false;
      }
    }

    return true;
  }

  String get _countdownLabel {
    final value = _countdownValue;
    if (value == null) {
      return '';
    }
    return value == 0 ? 'Start' : '$value';
  }

  String get _progressLabel {
    if (_isFinished) {
      return '$_mnemonicSequenceRounds/$_mnemonicSequenceRounds';
    }
    return '$_displayRoundNumber/$_mnemonicSequenceRounds';
  }

  @override
  void initState() {
    super.initState();
    _answerControllers = List<TextEditingController>.generate(
      widget.itemCount,
      (_) => TextEditingController(),
    );
    _answerFocusNodes = List<FocusNode>.generate(
      widget.itemCount,
      (int index) => FocusNode(debugLabel: 'mnemonic-sequence-answer-$index'),
    );
    if (widget.autoStart) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) {
          _startSession();
        }
      });
    }
  }

  void _cancelTimers() {
    _countdownTimer?.cancel();
    _memorizeTimer?.cancel();
    _finishExitTimer?.cancel();
  }

  void _clearAnswerFields() {
    for (final TextEditingController controller in _answerControllers) {
      controller.clear();
    }
  }

  List<int> _readAnswerValues({bool requireAll = false}) {
    final values = <int>[];

    for (final TextEditingController controller in _answerControllers) {
      final String raw = controller.text.trim();
      if (raw.isEmpty) {
        if (requireAll) {
          return <int>[];
        }
        continue;
      }
      final int? value = int.tryParse(raw);
      if (value == null || value < 0 || value > 100) {
        return <int>[];
      }
      values.add(value);
    }

    if (requireAll && values.length != widget.itemCount) {
      return <int>[];
    }

    return values;
  }

  List<int> _generateSequence() {
    return List<int>.generate(
      widget.itemCount,
      (_) =>
          _mnemonicDigitEntries[_random.nextInt(_mnemonicDigitEntries.length)]
              .number,
    );
  }

  bool _sameSequence(List<int> first, List<int> second) {
    if (first.length != second.length) {
      return false;
    }

    for (var index = 0; index < first.length; index += 1) {
      if (first[index] != second[index]) {
        return false;
      }
    }

    return true;
  }

  void _startSession() {
    _cancelTimers();
    _clearAnswerFields();
    FocusScope.of(context).unfocus();

    setState(() {
      _phase = _MnemonicSequencePhase.countdown;
      _pausedPhase = null;
      _roundIndex = 0;
      _correctRounds = 0;
      _countdownValue = _startCountdownSeconds;
      _memorizeSecondsRemaining = 0;
      _currentSequence = <int>[];
      _lastSubmittedSequence = <int>[];
      _lastAnswerCorrect = false;
      _status = 'Start za chwilę. Przygotuj się na pierwszą rundę.';
    });

    HapticFeedback.selectionClick();
    _runCountdown();
  }

  void _runCountdown() {
    _countdownTimer?.cancel();
    _countdownTimer = Timer.periodic(const Duration(seconds: 1), (Timer timer) {
      if (!mounted) {
        timer.cancel();
        return;
      }

      final currentCountdown = _countdownValue;
      if (!_isCountingDown || currentCountdown == null) {
        timer.cancel();
        return;
      }

      if (currentCountdown <= 0) {
        timer.cancel();
        _beginRound();
        return;
      }

      setState(() {
        _countdownValue = currentCountdown - 1;
      });

      if (_countdownValue == 0) {
        HapticFeedback.mediumImpact();
      } else {
        HapticFeedback.selectionClick();
      }
    });
  }

  void _beginRound() {
    _countdownTimer?.cancel();
    _memorizeTimer?.cancel();
    _clearAnswerFields();
    FocusScope.of(context).unfocus();

    setState(() {
      _phase = _MnemonicSequencePhase.memorizing;
      _pausedPhase = null;
      _countdownValue = null;
      _memorizeSecondsRemaining = _memorizeSeconds;
      _currentSequence = _generateSequence();
      _lastSubmittedSequence = <int>[];
      _status =
          'Zapamiętaj ${_memoryElementCountLabel(widget.itemCount)} w tej kolejności.';
    });

    HapticFeedback.selectionClick();
    _runMemorizationTimer();
  }

  void _runMemorizationTimer() {
    _memorizeTimer?.cancel();
    _memorizeTimer = Timer.periodic(const Duration(seconds: 1), (Timer timer) {
      if (!mounted) {
        timer.cancel();
        return;
      }

      if (!_isMemorizing) {
        timer.cancel();
        return;
      }

      if (_memorizeSecondsRemaining <= 1) {
        timer.cancel();
        _showAnswerField();
        return;
      }

      setState(() {
        _memorizeSecondsRemaining -= 1;
      });
    });
  }

  void _showAnswerField() {
    _memorizeTimer?.cancel();
    setState(() {
      _phase = _MnemonicSequencePhase.answering;
      _pausedPhase = null;
      _memorizeSecondsRemaining = 0;
      _status = 'Wpisz liczby po kolei.';
    });
    _focusAnswerField();
  }

  void _pauseSession() {
    if (!(_isCountingDown || _isMemorizing || _isAnswering)) {
      return;
    }

    _countdownTimer?.cancel();
    _memorizeTimer?.cancel();
    FocusScope.of(context).unfocus();

    setState(() {
      _pausedPhase = _phase;
      _phase = _MnemonicSequencePhase.paused;
      _status = 'Pauza. Wróć, gdy chcesz kontynuować tę samą rundę.';
    });
  }

  void _resumeSession() {
    final pausedPhase = _pausedPhase;
    if (!_isPaused || pausedPhase == null) {
      return;
    }

    setState(() {
      _phase = pausedPhase;
      _status = switch (pausedPhase) {
        _MnemonicSequencePhase.countdown =>
          'Wracasz do odliczania przed rundą.',
        _MnemonicSequencePhase.memorizing =>
          'Wracasz do zapamiętywania bieżącej sekwencji.',
        _MnemonicSequencePhase.answering => 'Wracasz do wpisywania odpowiedzi.',
        _ => _status,
      };
      _pausedPhase = null;
    });

    if (_isCountingDown) {
      _runCountdown();
    } else if (_isMemorizing) {
      _runMemorizationTimer();
    } else if (_isAnswering) {
      _focusAnswerField(_preferredAnswerFieldIndex);
    }
  }

  void _submitAnswer() {
    if (!_isAnswering || !_canSubmit) {
      return;
    }

    final answer = _readAnswerValues(requireAll: true);
    final bool correct = _sameSequence(answer, _currentSequence);

    FocusScope.of(context).unfocus();
    HapticFeedback.mediumImpact();
    setState(() {
      _phase = _MnemonicSequencePhase.feedback;
      _lastSubmittedSequence = answer;
      _lastAnswerCorrect = correct;
      if (correct) {
        _correctRounds += 1;
      }
      _status = correct
          ? 'Dobrze. Kolejność się zgadza.'
          : 'Nie ta kolejność. Poprawny układ jest pokazany poniżej.';
    });
  }

  void _continueAfterFeedback() {
    if (!_isFeedback) {
      return;
    }

    if (_roundIndex >= _mnemonicSequenceRounds - 1) {
      _finishSession();
      return;
    }

    setState(() {
      _roundIndex += 1;
    });
    _beginRound();
  }

  void _finishSession() {
    _cancelTimers();
    setState(() {
      _phase = _MnemonicSequencePhase.finished;
      _pausedPhase = null;
      _countdownValue = null;
      _memorizeSecondsRemaining = 0;
      _status = 'Koniec serii.';
    });

    if (!widget.autoExitOnFinish) {
      return;
    }

    _finishExitTimer = Timer(const Duration(seconds: 3), () {
      if (!mounted) {
        return;
      }
      Navigator.of(context).maybePop();
    });
  }

  @override
  void dispose() {
    _cancelTimers();
    for (final TextEditingController controller in _answerControllers) {
      controller.dispose();
    }
    for (final FocusNode focusNode in _answerFocusNodes) {
      focusNode.dispose();
    }
    super.dispose();
  }

  int get _preferredAnswerFieldIndex {
    final int emptyIndex = _answerControllers.indexWhere(
      (TextEditingController controller) => controller.text.trim().isEmpty,
    );
    return emptyIndex == -1 ? _answerControllers.length - 1 : emptyIndex;
  }

  void _focusAnswerField([int index = 0]) {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || !_isAnswering) {
        return;
      }
      _answerFocusNodes[index].requestFocus();
    });
  }

  void _handleAnswerFieldChanged(int index, String value) {
    setState(() {});
    if (!_isAnswering) {
      return;
    }

    if (_matchesExpectedValue(index, value)) {
      if (_hasFullCorrectAnswer) {
        _submitAnswer();
        return;
      }

      if (index < _answerFocusNodes.length - 1 &&
          _answerControllers[index + 1].text.trim().isEmpty) {
        _answerFocusNodes[index + 1].requestFocus();
        return;
      }
    }

    if (value.length == 3 && index < _answerFocusNodes.length - 1) {
      _answerFocusNodes[index + 1].requestFocus();
    }
  }

  void _handleAnswerFieldSubmitted(int index) {
    if (index >= _answerFocusNodes.length - 1) {
      _submitAnswer();
      return;
    }
    _answerFocusNodes[index + 1].requestFocus();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    final Widget stage = switch (_phase) {
      _MnemonicSequencePhase.idle => Column(
        key: const ValueKey<String>('mnemonic-sequence-idle'),
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          Text(
            'Seria cyfr',
            textAlign: TextAlign.center,
            style: theme.textTheme.headlineMedium?.copyWith(
              color: const Color(0xFF102533),
              fontWeight: FontWeight.w900,
            ),
          ),
          const SizedBox(height: 12),
          Text(
            '10 rund, poziomy układ i wpisywanie całej sekwencji po zniknięciu cyfr.',
            textAlign: TextAlign.center,
            style: theme.textTheme.bodyLarge?.copyWith(
              color: const Color(0xFF5D7380),
              height: 1.45,
            ),
          ),
          const SizedBox(height: 20),
          FilledButton(onPressed: _startSession, child: const Text('Start')),
        ],
      ),
      _MnemonicSequencePhase.countdown => _MnemonicSequenceStageShell(
        key: ValueKey<String>('mnemonic-sequence-countdown-$_roundIndex'),
        accent: widget.accent,
        label: 'Runda $_progressLabel',
        child: _MemoryCountdownDisplay(
          label: _countdownLabel,
          accent: widget.accent,
          valueKeyPrefix: 'mnemonic-sequence-countdown',
        ),
      ),
      _MnemonicSequencePhase.memorizing => _MnemonicSequenceStageShell(
        key: ValueKey<String>('mnemonic-sequence-round-$_roundIndex'),
        accent: widget.accent,
        label: 'Runda $_progressLabel',
        secondaryLabel: '${_memorizeSecondsRemaining}s',
        child: _MnemonicNumberSequenceStrip(
          numbers: _currentSequence,
          accent: widget.accent,
        ),
      ),
      _MnemonicSequencePhase.answering => _MnemonicSequenceStageShell(
        key: ValueKey<String>('mnemonic-sequence-answer-$_roundIndex'),
        accent: widget.accent,
        label: 'Runda $_progressLabel',
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            Text(
              'Wpisz układ',
              textAlign: TextAlign.center,
              style: theme.textTheme.headlineSmall?.copyWith(
                color: const Color(0xFF102533),
                fontWeight: FontWeight.w900,
              ),
            ),
            const SizedBox(height: 18),
            ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 620),
              child: _MnemonicSequenceAnswerGrid(
                controllers: _answerControllers,
                focusNodes: _answerFocusNodes,
                expectedValues: _currentSequence,
                accent: widget.accent,
                onChanged: _handleAnswerFieldChanged,
                onSubmitted: _handleAnswerFieldSubmitted,
              ),
            ),
            const SizedBox(height: 14),
            Text(
              '$_filledAnswerCount/${widget.itemCount}',
              textAlign: TextAlign.center,
              style: theme.textTheme.labelLarge?.copyWith(
                color: widget.accent,
                fontWeight: FontWeight.w900,
              ),
            ),
          ],
        ),
      ),
      _MnemonicSequencePhase.feedback => _MnemonicSequenceStageShell(
        key: ValueKey<String>(
          'mnemonic-sequence-feedback-${_lastAnswerCorrect ? 'ok' : 'fail'}-$_roundIndex',
        ),
        accent: widget.accent,
        label: 'Runda $_progressLabel',
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            _MemoryRoundFeedbackBadge(
              success: _lastAnswerCorrect,
              successIcon: Icons.verified_rounded,
              failureIcon: Icons.replay_circle_filled_rounded,
            ),
            const SizedBox(height: 18),
            Text(
              _lastAnswerCorrect ? 'Dobra odpowiedź' : 'Nie ten układ',
              textAlign: TextAlign.center,
              style: theme.textTheme.headlineSmall?.copyWith(
                color: const Color(0xFF102533),
                fontWeight: FontWeight.w900,
              ),
            ),
            const SizedBox(height: 14),
            Text(
              'Poprawna sekwencja',
              textAlign: TextAlign.center,
              style: theme.textTheme.labelLarge?.copyWith(
                color: widget.accent,
                fontWeight: FontWeight.w900,
                letterSpacing: 0.5,
              ),
            ),
            const SizedBox(height: 10),
            _MnemonicNumberSequenceStrip(
              numbers: _currentSequence,
              accent: widget.accent,
              compact: true,
            ),
            if (!_lastAnswerCorrect &&
                _lastSubmittedSequence.isNotEmpty) ...<Widget>[
              const SizedBox(height: 16),
              Text(
                'Twoja odpowiedź',
                textAlign: TextAlign.center,
                style: theme.textTheme.labelLarge?.copyWith(
                  color: const Color(0xFF63717C),
                  fontWeight: FontWeight.w900,
                  letterSpacing: 0.5,
                ),
              ),
              const SizedBox(height: 10),
              _MnemonicNumberSequenceStrip(
                numbers: _lastSubmittedSequence,
                accent: const Color(0xFF8D98A1),
                compact: true,
              ),
            ],
          ],
        ),
      ),
      _MnemonicSequencePhase.paused => _MnemonicSequenceStageShell(
        key: const ValueKey<String>('mnemonic-sequence-paused'),
        accent: widget.accent,
        label: 'Runda $_progressLabel',
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            Icon(
              Icons.pause_circle_filled_rounded,
              size: 68,
              color: widget.accent,
            ),
            const SizedBox(height: 14),
            Text(
              'Gra zatrzymana',
              textAlign: TextAlign.center,
              style: theme.textTheme.headlineMedium?.copyWith(
                color: const Color(0xFF102533),
                fontWeight: FontWeight.w900,
              ),
            ),
            const SizedBox(height: 10),
            Text(
              'Wznowienie wraca dokładnie do tej samej rundy i tego samego etapu.',
              textAlign: TextAlign.center,
              style: theme.textTheme.bodyMedium?.copyWith(
                color: const Color(0xFF5D7380),
                fontWeight: FontWeight.w700,
                height: 1.4,
              ),
            ),
          ],
        ),
      ),
      _MnemonicSequencePhase.finished => _MnemonicSequenceStageShell(
        key: const ValueKey<String>('mnemonic-sequence-finished'),
        accent: widget.accent,
        label: 'Wynik $_progressLabel',
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            Text(
              'Koniec serii',
              textAlign: TextAlign.center,
              style: theme.textTheme.headlineMedium?.copyWith(
                color: const Color(0xFF102533),
                fontWeight: FontWeight.w900,
              ),
            ),
            const SizedBox(height: 12),
            Text(
              'Trafione rundy: $_correctRounds/$_mnemonicSequenceRounds',
              textAlign: TextAlign.center,
              style: theme.textTheme.titleMedium?.copyWith(
                color: widget.accent,
                fontWeight: FontWeight.w900,
              ),
            ),
            const SizedBox(height: 10),
            Text(
              '${_memoryElementCountLabel(widget.itemCount)} w rundzie • ekspozycja $_memorizeSeconds s',
              textAlign: TextAlign.center,
              style: theme.textTheme.bodyMedium?.copyWith(
                color: const Color(0xFF5D7380),
                fontWeight: FontWeight.w700,
                height: 1.4,
              ),
            ),
          ],
        ),
      ),
    };

    final List<Widget> controlButtons = switch (_phase) {
      _MnemonicSequencePhase.idle => <Widget>[
        FilledButton(onPressed: _startSession, child: const Text('Start')),
      ],
      _MnemonicSequencePhase.countdown ||
      _MnemonicSequencePhase.memorizing => <Widget>[
        OutlinedButton.icon(
          onPressed: _pauseSession,
          icon: const Icon(Icons.pause_circle_outline_rounded),
          label: const Text('Pauza'),
        ),
      ],
      _MnemonicSequencePhase.answering => <Widget>[
        OutlinedButton.icon(
          onPressed: _pauseSession,
          icon: const Icon(Icons.pause_circle_outline_rounded),
          label: const Text('Pauza'),
        ),
        FilledButton(
          onPressed: _canSubmit ? _submitAnswer : null,
          child: const Text('Sprawdź'),
        ),
      ],
      _MnemonicSequencePhase.feedback => <Widget>[
        FilledButton(
          onPressed: _continueAfterFeedback,
          child: Text(
            _roundIndex >= _mnemonicSequenceRounds - 1
                ? 'Pokaż wynik'
                : 'Następna runda',
          ),
        ),
      ],
      _MnemonicSequencePhase.paused => <Widget>[
        FilledButton.icon(
          onPressed: _resumeSession,
          icon: const Icon(Icons.play_arrow_rounded),
          label: const Text('Wróć do gry'),
        ),
        OutlinedButton(
          onPressed: _startSession,
          child: const Text('Zacznij od nowa'),
        ),
      ],
      _MnemonicSequencePhase.finished => <Widget>[
        FilledButton.icon(
          onPressed: _startSession,
          icon: const Icon(Icons.replay_rounded),
          label: const Text('Jeszcze raz'),
        ),
      ],
    };

    return DecoratedBox(
      decoration: BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: <Color>[
            const Color(0xFF07131C),
            widget.accent.withValues(alpha: 0.34),
            const Color(0xFF0E2531),
          ],
        ),
      ),
      child: SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 12, 16, 24),
          child: Column(
            children: <Widget>[
              Align(
                alignment: Alignment.centerLeft,
                child: IconButton(
                  key: const ValueKey<String>('mnemonic-sequence-close'),
                  onPressed: () => Navigator.of(context).maybePop(),
                  color: const Color(0xFFEEF4F7),
                  splashRadius: 24,
                  icon: const Icon(Icons.close_rounded, size: 28),
                ),
              ),
              Expanded(
                child: Center(
                  child: ConstrainedBox(
                    constraints: const BoxConstraints(maxWidth: 920),
                    child: Container(
                      width: double.infinity,
                      padding: const EdgeInsets.symmetric(
                        horizontal: 24,
                        vertical: 30,
                      ),
                      decoration: BoxDecoration(
                        gradient: const LinearGradient(
                          begin: Alignment.topLeft,
                          end: Alignment.bottomRight,
                          colors: <Color>[Color(0xFFF9F3EA), Color(0xFFEDE2D2)],
                        ),
                        borderRadius: BorderRadius.circular(34),
                        border: Border.all(
                          color: Colors.white.withValues(alpha: 0.46),
                        ),
                        boxShadow: <BoxShadow>[
                          BoxShadow(
                            color: Colors.black.withValues(alpha: 0.18),
                            blurRadius: 34,
                            offset: const Offset(0, 18),
                          ),
                        ],
                      ),
                      child: ConstrainedBox(
                        constraints: const BoxConstraints(minHeight: 300),
                        child: LayoutBuilder(
                          builder:
                              (
                                BuildContext context,
                                BoxConstraints constraints,
                              ) {
                                final double minHeight =
                                    constraints.hasBoundedHeight
                                    ? max(300.0, constraints.maxHeight)
                                    : 300.0;

                                return SingleChildScrollView(
                                  child: ConstrainedBox(
                                    constraints: BoxConstraints(
                                      minHeight: minHeight,
                                    ),
                                    child: Center(
                                      child: AnimatedSwitcher(
                                        duration: const Duration(
                                          milliseconds: 180,
                                        ),
                                        switchInCurve: Curves.easeOutCubic,
                                        switchOutCurve: Curves.easeInCubic,
                                        transitionBuilder:
                                            (
                                              Widget child,
                                              Animation<double> animation,
                                            ) {
                                              return FadeTransition(
                                                opacity: animation,
                                                child: child,
                                              );
                                            },
                                        child: stage,
                                      ),
                                    ),
                                  ),
                                );
                              },
                        ),
                      ),
                    ),
                  ),
                ),
              ),
              Container(
                width: double.infinity,
                padding: const EdgeInsets.all(14),
                decoration: BoxDecoration(
                  color: const Color(0xFF102533).withValues(alpha: 0.72),
                  borderRadius: BorderRadius.circular(28),
                  border: Border.all(
                    color: Colors.white.withValues(alpha: 0.12),
                  ),
                ),
                child: Wrap(
                  alignment: WrapAlignment.center,
                  spacing: 10,
                  runSpacing: 10,
                  children: controlButtons,
                ),
              ),
              const SizedBox(height: 16),
              ClipRRect(
                borderRadius: BorderRadius.circular(999),
                child: LinearProgressIndicator(
                  key: const ValueKey<String>('mnemonic-sequence-progress'),
                  minHeight: 10,
                  value: _progress,
                  backgroundColor: Colors.white.withValues(alpha: 0.14),
                  valueColor: AlwaysStoppedAnimation<Color>(widget.accent),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

enum _VoiceDrillKind { warmup, articulation, projection }

class _VoiceDrillStep {
  const _VoiceDrillStep({
    required this.label,
    required this.cue,
    required this.detail,
    required this.goal,
    required this.durationSeconds,
    required this.icon,
  });

  final String label;
  final String cue;
  final String detail;
  final String goal;
  final int durationSeconds;
  final IconData icon;
}

class _VoiceDrillDefinition {
  const _VoiceDrillDefinition({
    required this.kind,
    required this.label,
    required this.title,
    required this.summary,
    required this.focusLabel,
    required this.difficultyLabel,
    required this.idleTitle,
    required this.idleSummary,
    required this.completionMessage,
    required this.icon,
    required this.steps,
  });

  final _VoiceDrillKind kind;
  final String label;
  final String title;
  final String summary;
  final String focusLabel;
  final String difficultyLabel;
  final String idleTitle;
  final String idleSummary;
  final String completionMessage;
  final IconData icon;
  final List<_VoiceDrillStep> steps;
}

const List<_VoiceDrillDefinition>
_voiceDrillDefinitions = <_VoiceDrillDefinition>[
  _VoiceDrillDefinition(
    kind: _VoiceDrillKind.warmup,
    label: 'Rozgrzewka',
    title: 'Oddech i Rezonans',
    summary:
        'Krótka sekwencja oddechu, mruczenia i miękkiego wejścia w głos przed mówieniem.',
    focusLabel: 'Start głosu',
    difficultyLabel: 'Spokojne tempo',
    idleTitle: 'Wejście w głos bez napięcia',
    idleSummary:
        'Najpierw łapiesz spokojny oddech, potem długi wydech i lekkie mruczenie. Ta sesja prowadzi cię przez prostą rozgrzewkę bez forsowania gardła.',
    completionMessage:
        'Rozgrzewka skończona. Głos powinien wejść lżej i czyściej.',
    icon: Icons.air_rounded,
    steps: <_VoiceDrillStep>[
      _VoiceDrillStep(
        label: 'RESET • ODDECH',
        cue: 'Wdech nosem',
        detail: 'Nabierz powietrza spokojnie, bez unoszenia barków.',
        goal: 'Spokojne wejście',
        durationSeconds: 4,
        icon: Icons.air_rounded,
      ),
      _VoiceDrillStep(
        label: 'FLOW • WYDECH',
        cue: 'Długi wydech na sss',
        detail: 'Wypuszczaj powietrze równo i bez pchania końcówki.',
        goal: 'Wsparcie oddechu',
        durationSeconds: 6,
        icon: Icons.graphic_eq_rounded,
      ),
      _VoiceDrillStep(
        label: 'MASKA • MMM',
        cue: 'Mruknij mmm',
        detail: 'Poczuj lekką wibrację z przodu twarzy, nie w gardle.',
        goal: 'Rezonans maski',
        durationSeconds: 5,
        icon: Icons.multitrack_audio_rounded,
      ),
      _VoiceDrillStep(
        label: 'ENTRY • FRAZA',
        cue: 'Miękkie wejście w głos',
        detail: 'Powiedz spokojnie: "dzień dobry" na jednym, wygodnym tonie.',
        goal: 'Łagodne wejście',
        durationSeconds: 4,
        icon: Icons.record_voice_over_rounded,
      ),
    ],
  ),
  _VoiceDrillDefinition(
    kind: _VoiceDrillKind.articulation,
    label: 'Dykcja',
    title: 'Szybka Seria Sylab',
    summary:
        'Pełna seria 20 bloków na rezonans, samogłoski, dykcję, kontrolę przejść i płynność frazy.',
    focusLabel: 'Precyzja mowy',
    difficultyLabel: '20 bloków',
    idleTitle: '20 bloków szybkiej serii sylab',
    idleSummary:
        'W tej serii przechodzisz przez 20 bloków: rezonans, sylaby, samogłoski i przejścia. Trzymaj rytm, czyste końcówki i spokojne wsparcie oddechu.',
    completionMessage:
        '20 bloków skończone. Usta, język i prowadzenie dźwięku są gotowe do dalszej pracy.',
    icon: Icons.text_fields_rounded,
    steps: <_VoiceDrillStep>[
      _VoiceDrillStep(
        label: 'STARTER • MA POWER',
        cue: 'ma ma ma ma ma',
        detail: 'Wolno i stabilnie. Otwórz usta i rozluźnij szczękę.',
        goal: 'Rezonans piersiowy',
        durationSeconds: 5,
        icon: Icons.text_fields_rounded,
      ),
      _VoiceDrillStep(
        label: 'FOCUS • MI LASER',
        cue: 'mi mi mi mi mi',
        detail: 'Lekki uśmiech. Kieruj dźwięk do przodu.',
        goal: 'Maska i projekcja',
        durationSeconds: 5,
        icon: Icons.gps_fixed_rounded,
      ),
      _VoiceDrillStep(
        label: 'DEPTH • MU FLOW',
        cue: 'mu mu mu mu mu',
        detail: 'Głęboko i miękko. Poczuj klatkę piersiową.',
        goal: 'Głębia brzmienia',
        durationSeconds: 5,
        icon: Icons.keyboard_voice_rounded,
      ),
      _VoiceDrillStep(
        label: 'FLEX • ME-MA-MO',
        cue: 'me ma mo mu',
        detail: 'Na jednym wydechu i bez szarpania końcówki.',
        goal: 'Elastyczność',
        durationSeconds: 5,
        icon: Icons.sync_alt_rounded,
      ),
      _VoiceDrillStep(
        label: 'HEAD • NG VIBE',
        cue: 'nggggg',
        detail: 'Zamknięte usta. Złap wibrację wyżej w głowie.',
        goal: 'Rezonans głowy',
        durationSeconds: 5,
        icon: Icons.multitrack_audio_rounded,
      ),
      _VoiceDrillStep(
        label: 'LIGHT • LA WAVE',
        cue: 'la la la la',
        detail: 'Lekko i szybko. Puść język bez napinania.',
        goal: 'Język i luz',
        durationSeconds: 5,
        icon: Icons.waves_rounded,
      ),
      _VoiceDrillStep(
        label: 'DRIVE • PA-TA-KA',
        cue: 'pa ta ka pa ta ka',
        detail: 'Rytmicznie i wyraźnie, bez gubienia końcówek.',
        goal: 'Dykcja',
        durationSeconds: 6,
        icon: Icons.speed_rounded,
      ),
      _VoiceDrillStep(
        label: 'SCALE • MA RISE',
        cue: 'ma me mi mo mu',
        detail: 'Idź delikatnie w górę i nie ściskaj gardła.',
        goal: 'Skala i kontrola',
        durationSeconds: 6,
        icon: Icons.trending_up_rounded,
      ),
      _VoiceDrillStep(
        label: 'IMPACT • ZA POWER',
        cue: 'za zo zu',
        detail: 'Dynamicznie, ale na wsparciu oddechu.',
        goal: 'Energia i wsparcie',
        durationSeconds: 5,
        icon: Icons.bolt_rounded,
      ),
      _VoiceDrillStep(
        label: 'RHYTHM • MA FLOW',
        cue: 'ma-mi-ma | mo-mu-mo',
        detail: 'Trzymaj rytm i płynne przejścia.',
        goal: 'Płynność',
        durationSeconds: 6,
        icon: Icons.graphic_eq_rounded,
      ),
      _VoiceDrillStep(
        label: 'OPEN • A SPACE',
        cue: 'aaaaa',
        detail: 'Szeroko i swobodnie. Otwórz głos bez docisku.',
        goal: 'Otwarcie głosu',
        durationSeconds: 5,
        icon: Icons.crop_7_5_rounded,
      ),
      _VoiceDrillStep(
        label: 'BRIGHT • E SPARK',
        cue: 'eeeee',
        detail: 'Lekki uśmiech i jasny front dźwięku.',
        goal: 'Jasność',
        durationSeconds: 5,
        icon: Icons.light_mode_rounded,
      ),
      _VoiceDrillStep(
        label: 'SHARP • I POINT',
        cue: 'iiiii',
        detail: 'Skupione brzmienie i czysty kierunek do przodu.',
        goal: 'Precyzja',
        durationSeconds: 5,
        icon: Icons.adjust_rounded,
      ),
      _VoiceDrillStep(
        label: 'ROUND • O WAVE',
        cue: 'ooooo',
        detail: 'Okrągłe usta i spokojna pełnia dźwięku.',
        goal: 'Pełnia',
        durationSeconds: 5,
        icon: Icons.radio_button_checked_rounded,
      ),
      _VoiceDrillStep(
        label: 'DEEP • U CORE',
        cue: 'uuuuu',
        detail: 'Głęboko i stabilnie, bez zbijania tonu.',
        goal: 'Osadzenie',
        durationSeconds: 5,
        icon: Icons.anchor_rounded,
      ),
      _VoiceDrillStep(
        label: 'MIX • A-E FLOW',
        cue: 'a e a e a e',
        detail: 'Płynnie przechodź między samogłoskami.',
        goal: 'Przejścia',
        durationSeconds: 6,
        icon: Icons.swap_horiz_rounded,
      ),
      _VoiceDrillStep(
        label: 'SWITCH • I-O SHIFT',
        cue: 'i o i o i o',
        detail: 'Buduj kontrast bez gubienia kontroli.',
        goal: 'Kontrola',
        durationSeconds: 6,
        icon: Icons.compare_arrows_rounded,
      ),
      _VoiceDrillStep(
        label: 'MELO • U-A WAVE',
        cue: 'u a u a u a',
        detail: 'Miękko i bez sztywnego ataku.',
        goal: 'Balans',
        durationSeconds: 6,
        icon: Icons.music_note_rounded,
      ),
      _VoiceDrillStep(
        label: 'RESO • E-I FOCUS',
        cue: 'e i e i e i',
        detail: 'Prowadź dźwięk do przodu i utrzymaj koncentrację.',
        goal: 'Rezonans maski',
        durationSeconds: 6,
        icon: Icons.center_focus_strong_rounded,
      ),
      _VoiceDrillStep(
        label: 'FULL FLOW • A-E-I-O-U',
        cue: 'a e i o u',
        detail: 'Jednym ciągiem i na równym oddechu.',
        goal: 'Integracja całego głosu',
        durationSeconds: 6,
        icon: Icons.record_voice_over_rounded,
      ),
    ],
  ),
  _VoiceDrillDefinition(
    kind: _VoiceDrillKind.projection,
    label: 'Fraza',
    title: 'Stabilna Fraza',
    summary:
        'Pełna seria 20 bloków na stabilny ton, prowadzenie frazy, oddech, akcent i miękkie końcówki.',
    focusLabel: 'Prowadzenie frazy',
    difficultyLabel: '20 bloków',
    idleTitle: '20 bloków stabilnej frazy',
    idleSummary:
        'W tej serii przechodzisz przez 20 bloków: oddech, samogłoski, przejścia i coraz dłuższe frazy. Trzymaj równy kierunek głosu, spokojne wsparcie i nośne końcówki bez dociskania.',
    completionMessage:
        '20 bloków stabilnej frazy skończone. Sprawdź, czy głos niesie spokojnie od początku do końca zdania.',
    icon: Icons.campaign_rounded,
    steps: <_VoiceDrillStep>[
      _VoiceDrillStep(
        label: 'RESET • ODDECH',
        cue: 'Wdech nosem + wydech na sss',
        detail:
            'Złap spokojne podparcie i wyrównaj wydech przed wejściem w głos.',
        goal: 'Stabilny oddech',
        durationSeconds: 5,
        icon: Icons.air_rounded,
      ),
      _VoiceDrillStep(
        label: 'MASKA • MMM',
        cue: 'mmm',
        detail: 'Lekka wibracja z przodu twarzy, bez dociskania gardła.',
        goal: 'Osadzenie dźwięku',
        durationSeconds: 5,
        icon: Icons.multitrack_audio_rounded,
      ),
      _VoiceDrillStep(
        label: 'BASE • A LINE',
        cue: 'aaaaa',
        detail: 'Równo i spokojnie, bez podbijania końcówki dźwięku.',
        goal: 'Stabilny ton',
        durationSeconds: 5,
        icon: Icons.graphic_eq_rounded,
      ),
      _VoiceDrillStep(
        label: 'ROUND • O LINE',
        cue: 'ooooo',
        detail: 'Okrągłe usta i pełne, ale niewymuszone brzmienie.',
        goal: 'Nośność',
        durationSeconds: 5,
        icon: Icons.hearing_rounded,
      ),
      _VoiceDrillStep(
        label: 'CORE • U LINE',
        cue: 'uuuuu',
        detail: 'Trzymaj dół oddechu i nie cofaj dźwięku.',
        goal: 'Wsparcie',
        durationSeconds: 5,
        icon: Icons.anchor_rounded,
      ),
      _VoiceDrillStep(
        label: 'BRIGHT • E FRONT',
        cue: 'eeeee',
        detail: 'Lekki uśmiech i dźwięk prowadzony do przodu.',
        goal: 'Jasny front',
        durationSeconds: 5,
        icon: Icons.light_mode_rounded,
      ),
      _VoiceDrillStep(
        label: 'LINK • A-O FLOW',
        cue: 'a o a o a o',
        detail: 'Płynnie przechodź między samogłoskami bez skoków głośności.',
        goal: 'Równe przejścia',
        durationSeconds: 6,
        icon: Icons.swap_horiz_rounded,
      ),
      _VoiceDrillStep(
        label: 'LINK • E-U FLOW',
        cue: 'e u e u e u',
        detail: 'Zachowaj ten sam oddech i stabilny kierunek dźwięku.',
        goal: 'Kontrola przejść',
        durationSeconds: 6,
        icon: Icons.compare_arrows_rounded,
      ),
      _VoiceDrillStep(
        label: 'PHRASE • MA FLOW',
        cue: 'ma me mi mo mu',
        detail: 'Mów ciągiem, bez odcinania każdej sylaby osobno.',
        goal: 'Płynność sylab',
        durationSeconds: 6,
        icon: Icons.record_voice_over_rounded,
      ),
      _VoiceDrillStep(
        label: 'LINE • MÓWIĘ JASNO',
        cue: 'Powiedz: "mówię jasno"',
        detail: 'Krótka fraza, ale z równym początkiem i końcem.',
        goal: 'Krótka fraza',
        durationSeconds: 6,
        icon: Icons.short_text_rounded,
      ),
      _VoiceDrillStep(
        label: 'LINE • MÓWIĘ SPOKOJNIE',
        cue: 'Powiedz: "mówię spokojnie i pewnie"',
        detail: 'Nie przyspieszaj środka i nie opuszczaj końca.',
        goal: 'Równy rytm',
        durationSeconds: 6,
        icon: Icons.chat_bubble_outline_rounded,
      ),
      _VoiceDrillStep(
        label: 'ACCENT • START',
        cue: 'Powiedz: "teraz prowadzę frazę"',
        detail: 'Lekko zaznacz początek, ale utrzymaj spokojną resztę zdania.',
        goal: 'Kontrolowany atak',
        durationSeconds: 6,
        icon: Icons.play_arrow_rounded,
      ),
      _VoiceDrillStep(
        label: 'ACCENT • ŚRODEK',
        cue: 'Powiedz: "mówię teraz spokojnie"',
        detail: 'Akcent w środku bez rozbijania całej frazy.',
        goal: 'Środek frazy',
        durationSeconds: 6,
        icon: Icons.tune_rounded,
      ),
      _VoiceDrillStep(
        label: 'CARRY • KONIEC',
        cue: 'Powiedz: "prowadzę dźwięk do końca"',
        detail: 'Nie pozwól, by końcówka opadła lub zgasła za wcześnie.',
        goal: 'Nośna końcówka',
        durationSeconds: 6,
        icon: Icons.trending_flat_rounded,
      ),
      _VoiceDrillStep(
        label: 'ARC • GÓRA-DÓŁ',
        cue: 'Powiedz: "dzień dobry, mówię wyraźnie"',
        detail: 'Lekko podnieś środek i miękko wróć niżej bez skoku napięcia.',
        goal: 'Łuk frazy',
        durationSeconds: 6,
        icon: Icons.show_chart_rounded,
      ),
      _VoiceDrillStep(
        label: 'SPACE • PAUZA',
        cue: 'Powiedz: "mówię jasno | i spokojnie"',
        detail: 'Krótka pauza bez utraty podparcia po pierwszej części.',
        goal: 'Pauza i ciągłość',
        durationSeconds: 6,
        icon: Icons.pause_circle_outline_rounded,
      ),
      _VoiceDrillStep(
        label: 'LIFT • PYTANIE',
        cue: 'Powiedz pytająco: "mówię wyraźnie?"',
        detail: 'Podnieś końcówkę lekko, ale bez ściskania i forsowania.',
        goal: 'Uniesienie końca',
        durationSeconds: 6,
        icon: Icons.north_east_rounded,
      ),
      _VoiceDrillStep(
        label: 'DROP • STWIERDZENIE',
        cue: 'Powiedz: "mówię wyraźnie."',
        detail: 'Zamknij zdanie spokojnie i stabilnie, bez opadania energii.',
        goal: 'Domknięcie zdania',
        durationSeconds: 6,
        icon: Icons.south_east_rounded,
      ),
      _VoiceDrillStep(
        label: 'FULL • DŁUŻSZA FRAZA',
        cue: 'Powiedz: "mówię jasno i spokojnie, prowadzę frazę do przodu"',
        detail: 'Jeden oddech, spokojne tempo i czytelne końcówki.',
        goal: 'Dłuższa fraza',
        durationSeconds: 7,
        icon: Icons.subject_rounded,
      ),
      _VoiceDrillStep(
        label: 'OUT • MIĘKKIE ZEJŚCIE',
        cue: 'Powiedz: "kończę miękko i stabilnie"',
        detail: 'Zamknij frazę bez przyciskania ostatniego słowa.',
        goal: 'Kontrola końca',
        durationSeconds: 6,
        icon: Icons.waves_rounded,
      ),
    ],
  ),
];

class VoiceTrainer extends StatefulWidget {
  const VoiceTrainer({super.key, required this.accent});

  final Color accent;

  @override
  State<VoiceTrainer> createState() => _VoiceTrainerState();
}

class _VoiceTrainerState extends State<VoiceTrainer> {
  _VoiceDrillKind _selectedDrill = _VoiceDrillKind.warmup;

  void _selectDrill(_VoiceDrillKind kind) {
    if (_selectedDrill == kind) {
      return;
    }
    setState(() {
      _selectedDrill = kind;
    });
  }

  _VoiceDrillDefinition get _currentDefinition {
    return _voiceDrillDefinitions.firstWhere(
      (_VoiceDrillDefinition definition) => definition.kind == _selectedDrill,
    );
  }

  Widget _buildTrainer() {
    return _VoiceDrillDemo(
      key: ValueKey<String>('voice-drill-${_selectedDrill.name}'),
      definition: _currentDefinition,
      accent: widget.accent,
      fullscreenOnStart: true,
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final palette = context.appPalette;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        Container(
          width: double.infinity,
          padding: const EdgeInsets.all(18),
          decoration: BoxDecoration(
            gradient: LinearGradient(
              begin: Alignment.topLeft,
              end: Alignment.bottomRight,
              colors: <Color>[
                widget.accent.withValues(alpha: 0.16),
                palette.surfaceStrong,
              ],
            ),
            borderRadius: BorderRadius.circular(26),
            border: Border.all(color: widget.accent.withValues(alpha: 0.18)),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: _voiceDrillDefinitions.map((
                  _VoiceDrillDefinition drill,
                ) {
                  final selected = drill.kind == _selectedDrill;
                  return Padding(
                    padding: EdgeInsets.only(
                      bottom: drill == _voiceDrillDefinitions.last ? 0 : 10,
                    ),
                    child: Material(
                      color: Colors.transparent,
                      child: InkWell(
                        key: ValueKey<String>('voice-mode-${drill.kind.name}'),
                        onTap: () => _selectDrill(drill.kind),
                        borderRadius: BorderRadius.circular(22),
                        child: Ink(
                          width: double.infinity,
                          padding: const EdgeInsets.all(16),
                          decoration: BoxDecoration(
                            color: selected
                                ? palette.surface.withValues(alpha: 0.92)
                                : palette.surface.withValues(alpha: 0.72),
                            borderRadius: BorderRadius.circular(22),
                            border: Border.all(
                              color: selected
                                  ? widget.accent
                                  : palette.surfaceBorder,
                              width: selected ? 1.4 : 1,
                            ),
                          ),
                          child: Row(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: <Widget>[
                              Container(
                                width: 46,
                                height: 46,
                                decoration: BoxDecoration(
                                  color: widget.accent.withValues(
                                    alpha: selected ? 0.16 : 0.08,
                                  ),
                                  borderRadius: BorderRadius.circular(16),
                                ),
                                child: Icon(
                                  drill.icon,
                                  color: selected
                                      ? widget.accent
                                      : const Color(0xFF4A5761),
                                ),
                              ),
                              const SizedBox(width: 14),
                              Expanded(
                                child: Column(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: <Widget>[
                                    Text(
                                      drill.label,
                                      style: theme.textTheme.labelLarge
                                          ?.copyWith(
                                            color: selected
                                                ? widget.accent
                                                : const Color(0xFF63717C),
                                            fontWeight: FontWeight.w800,
                                            letterSpacing: 0.4,
                                          ),
                                    ),
                                    const SizedBox(height: 4),
                                    Text(
                                      drill.title,
                                      style: theme.textTheme.titleMedium
                                          ?.copyWith(
                                            color: const Color(0xFF16212B),
                                            fontWeight: FontWeight.w900,
                                          ),
                                    ),
                                    const SizedBox(height: 6),
                                    Text(
                                      drill.summary,
                                      style: theme.textTheme.bodyMedium
                                          ?.copyWith(
                                            color: const Color(0xFF4A5761),
                                            height: 1.4,
                                          ),
                                    ),
                                    const SizedBox(height: 8),
                                    Text(
                                      '${drill.focusLabel} • ${drill.difficultyLabel}',
                                      style: theme.textTheme.labelLarge
                                          ?.copyWith(
                                            color: selected
                                                ? widget.accent
                                                : const Color(0xFF63717C),
                                            fontWeight: FontWeight.w800,
                                          ),
                                    ),
                                  ],
                                ),
                              ),
                              const SizedBox(width: 12),
                              Icon(
                                selected
                                    ? Icons.check_circle_rounded
                                    : Icons.chevron_right_rounded,
                                color: selected
                                    ? widget.accent
                                    : const Color(0xFF92A0AA),
                              ),
                            ],
                          ),
                        ),
                      ),
                    ),
                  );
                }).toList(),
              ),
            ],
          ),
        ),
        const SizedBox(height: 18),
        AnimatedSwitcher(
          duration: const Duration(milliseconds: 220),
          child: _buildTrainer(),
        ),
      ],
    );
  }
}

class _VoiceDrillDemo extends StatefulWidget {
  const _VoiceDrillDemo({
    super.key,
    required this.definition,
    required this.accent,
    this.autoStart = false,
    this.fullscreenOnStart = false,
  });

  final _VoiceDrillDefinition definition;
  final Color accent;
  final bool autoStart;
  final bool fullscreenOnStart;

  @override
  State<_VoiceDrillDemo> createState() => _VoiceDrillDemoState();
}

class _VoiceDrillDemoState extends State<_VoiceDrillDemo> {
  static const int _sessionStartCountdownSeconds = 3;

  Timer? _countdownTimer;
  Timer? _stepTimer;

  int? _countdownValue;
  int _currentStepIndex = 0;
  int _stepSecondsRemaining = 0;
  bool _hasSessionStarted = false;
  bool _isRunning = false;
  bool _finished = false;
  late String _status;

  bool get _isCountingDown => _countdownValue != null;
  int get _totalSteps => widget.definition.steps.length;

  _VoiceDrillStep? get _currentStep {
    if (!_isRunning || _currentStepIndex >= widget.definition.steps.length) {
      return null;
    }
    return widget.definition.steps[_currentStepIndex];
  }

  String get _countdownLabel {
    final value = _countdownValue;
    if (value == null) {
      return '';
    }
    return value == 0 ? 'Start' : '$value';
  }

  int get _visibleStepNumber {
    if (_finished) {
      return _totalSteps;
    }
    if (_isRunning) {
      return _currentStepIndex + 1;
    }
    return 0;
  }

  double get _progressValue {
    if (_totalSteps == 0) {
      return 0;
    }
    if (_finished) {
      return 1;
    }
    if (_isRunning) {
      return ((_currentStepIndex + 0.5) / _totalSteps).clamp(0, 1).toDouble();
    }
    return 0;
  }

  String get _phaseHint {
    if (_isCountingDown) {
      return 'Za moment ruszy sekwencja. Mów swobodnie, na wygodnym poziomie i bez dociskania gardła.';
    }
    if (_isRunning) {
      return 'Sesja prowadzi rytm i kroki. Na tym etapie nie analizuje jeszcze mikrofonu.';
    }
    if (_finished) {
      return widget.definition.completionMessage;
    }
    return widget.definition.idleSummary;
  }

  @override
  void initState() {
    super.initState();
    _status = widget.definition.idleTitle;
    if (widget.autoStart) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) {
          _startSession();
        }
      });
    }
  }

  void _cancelTimers() {
    _countdownTimer?.cancel();
    _stepTimer?.cancel();
  }

  void _activateStep(int index) {
    final step = widget.definition.steps[index];
    HapticFeedback.selectionClick();
    setState(() {
      _isRunning = true;
      _finished = false;
      _currentStepIndex = index;
      _stepSecondsRemaining = step.durationSeconds;
      _status = step.cue;
    });
  }

  void _finishSession() {
    _cancelTimers();
    HapticFeedback.mediumImpact();
    setState(() {
      _countdownValue = null;
      _isRunning = false;
      _finished = true;
      _stepSecondsRemaining = 0;
      _status = widget.definition.completionMessage;
    });
  }

  void _startStepSequence() {
    if (widget.definition.steps.isEmpty) {
      _finishSession();
      return;
    }

    _activateStep(0);
    _stepTimer = Timer.periodic(const Duration(seconds: 1), (Timer timer) {
      if (!mounted) {
        timer.cancel();
        return;
      }

      if (_stepSecondsRemaining > 1) {
        setState(() {
          _stepSecondsRemaining -= 1;
        });
        return;
      }

      final nextStepIndex = _currentStepIndex + 1;
      if (nextStepIndex >= widget.definition.steps.length) {
        timer.cancel();
        _finishSession();
        return;
      }

      _activateStep(nextStepIndex);
    });
  }

  Future<void> _startSession() async {
    if (_isCountingDown || _isRunning) {
      return;
    }

    _cancelTimers();

    setState(() {
      _countdownValue = _sessionStartCountdownSeconds;
      _hasSessionStarted = true;
      _isRunning = false;
      _finished = false;
      _currentStepIndex = 0;
      _stepSecondsRemaining = 0;
      _status = 'Sesja startuje. Złap rytm.';
    });

    HapticFeedback.selectionClick();

    _countdownTimer = Timer.periodic(const Duration(seconds: 1), (Timer timer) {
      if (!mounted) {
        timer.cancel();
        return;
      }

      final currentCountdown = _countdownValue;
      if (currentCountdown == null) {
        timer.cancel();
        return;
      }

      if (currentCountdown <= 0) {
        timer.cancel();
        setState(() {
          _countdownValue = null;
        });
        _startStepSequence();
        return;
      }

      setState(() {
        _countdownValue = currentCountdown - 1;
      });

      if (_countdownValue == 0) {
        HapticFeedback.mediumImpact();
      } else {
        HapticFeedback.selectionClick();
      }
    });
  }

  Future<void> _openFullscreenSession() {
    return Navigator.of(context).push<void>(
      _buildExerciseSessionRoute<void>(
        builder: (BuildContext context) {
          return FullscreenTrainerPage(
            title: 'Voice • ${widget.definition.title}',
            accent: widget.accent,
            child: _VoiceDrillDemo(
              definition: widget.definition,
              accent: widget.accent,
              autoStart: true,
            ),
          );
        },
      ),
    );
  }

  Future<void> _handleStartAction() async {
    if (widget.fullscreenOnStart) {
      await _openFullscreenSession();
      return;
    }

    await _startSession();
  }

  @override
  void dispose() {
    _cancelTimers();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final currentStep = _currentStep;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        _hasSessionStarted
            ? _VoiceStatsRow(
                accent: widget.accent,
                stepLabel: '$_visibleStepNumber/$_totalSteps',
                modeLabel: widget.definition.label,
              )
            : Container(
                width: double.infinity,
                padding: const EdgeInsets.all(18),
                decoration: BoxDecoration(
                  color: widget.accent.withValues(alpha: 0.1),
                  borderRadius: BorderRadius.circular(24),
                  border: Border.all(
                    color: widget.accent.withValues(alpha: 0.18),
                  ),
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: <Widget>[
                    Text(
                      _status,
                      style: theme.textTheme.titleMedium?.copyWith(
                        color: const Color(0xFF16212B),
                        fontWeight: FontWeight.w800,
                      ),
                    ),
                    const SizedBox(height: 8),
                    Text(
                      _phaseHint,
                      style: theme.textTheme.bodyMedium?.copyWith(
                        color: const Color(0xFF4A5761),
                        height: 1.5,
                      ),
                    ),
                  ],
                ),
              ),
        const SizedBox(height: 18),
        Container(
          width: double.infinity,
          constraints: const BoxConstraints(minHeight: 320),
          padding: const EdgeInsets.all(24),
          decoration: BoxDecoration(
            color: const Color(0xFFF9F5EF),
            borderRadius: BorderRadius.circular(26),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              ClipRRect(
                borderRadius: BorderRadius.circular(12),
                child: LinearProgressIndicator(
                  minHeight: 12,
                  value: _progressValue,
                  backgroundColor: widget.accent.withValues(alpha: 0.12),
                  valueColor: AlwaysStoppedAnimation<Color>(widget.accent),
                ),
              ),
              const SizedBox(height: 24),
              AnimatedSize(
                duration: const Duration(milliseconds: 220),
                curve: Curves.easeOut,
                child: ConstrainedBox(
                  constraints: const BoxConstraints(minHeight: 260),
                  child: Center(
                    child: AnimatedSwitcher(
                      duration: const Duration(milliseconds: 220),
                      child: _isCountingDown
                          ? _MemoryCountdownDisplay(
                              label: _countdownLabel,
                              accent: widget.accent,
                              valueKeyPrefix:
                                  'voice-countdown-${widget.definition.kind.name}',
                            )
                          : _isRunning && currentStep != null
                          ? Column(
                              key: ValueKey<String>(
                                'voice-step-${widget.definition.kind.name}-${_currentStepIndex + 1}',
                              ),
                              mainAxisSize: MainAxisSize.min,
                              children: <Widget>[
                                Container(
                                  width: 88,
                                  height: 88,
                                  decoration: BoxDecoration(
                                    color: widget.accent.withValues(
                                      alpha: 0.12,
                                    ),
                                    shape: BoxShape.circle,
                                  ),
                                  alignment: Alignment.center,
                                  child: Icon(
                                    currentStep.icon,
                                    color: widget.accent,
                                    size: 42,
                                  ),
                                ),
                                const SizedBox(height: 18),
                                Text(
                                  currentStep.label,
                                  textAlign: TextAlign.center,
                                  style: theme.textTheme.labelLarge?.copyWith(
                                    color: widget.accent,
                                    fontWeight: FontWeight.w900,
                                    letterSpacing: 0.6,
                                  ),
                                ),
                                const SizedBox(height: 8),
                                Text(
                                  currentStep.cue,
                                  textAlign: TextAlign.center,
                                  style: theme.textTheme.headlineSmall
                                      ?.copyWith(
                                        color: const Color(0xFF16212B),
                                        fontWeight: FontWeight.w900,
                                      ),
                                ),
                                const SizedBox(height: 10),
                                Text(
                                  currentStep.detail,
                                  textAlign: TextAlign.center,
                                  style: theme.textTheme.bodyLarge?.copyWith(
                                    color: const Color(0xFF4A5761),
                                    height: 1.5,
                                  ),
                                ),
                                const SizedBox(height: 14),
                                Container(
                                  padding: const EdgeInsets.symmetric(
                                    horizontal: 14,
                                    vertical: 8,
                                  ),
                                  decoration: BoxDecoration(
                                    color: widget.accent.withValues(
                                      alpha: 0.12,
                                    ),
                                    borderRadius: BorderRadius.circular(16),
                                  ),
                                  child: Text(
                                    currentStep.goal,
                                    textAlign: TextAlign.center,
                                    style: theme.textTheme.labelLarge?.copyWith(
                                      color: widget.accent,
                                      fontWeight: FontWeight.w800,
                                    ),
                                  ),
                                ),
                                const SizedBox(height: 18),
                                Container(
                                  padding: const EdgeInsets.symmetric(
                                    horizontal: 18,
                                    vertical: 10,
                                  ),
                                  decoration: BoxDecoration(
                                    color: Colors.white,
                                    borderRadius: BorderRadius.circular(16),
                                    border: Border.all(
                                      color: widget.accent.withValues(
                                        alpha: 0.18,
                                      ),
                                    ),
                                  ),
                                  child: Text(
                                    '$_stepSecondsRemaining s',
                                    style: theme.textTheme.titleMedium
                                        ?.copyWith(
                                          color: widget.accent,
                                          fontWeight: FontWeight.w900,
                                        ),
                                  ),
                                ),
                              ],
                            )
                          : _finished
                          ? Column(
                              key: ValueKey<String>(
                                'voice-finished-${widget.definition.kind.name}',
                              ),
                              mainAxisSize: MainAxisSize.min,
                              children: <Widget>[
                                Icon(
                                  Icons.check_circle_rounded,
                                  color: widget.accent,
                                  size: 60,
                                ),
                                const SizedBox(height: 14),
                                Text(
                                  'Sesja zakończona',
                                  style: theme.textTheme.headlineSmall
                                      ?.copyWith(
                                        color: const Color(0xFF16212B),
                                        fontWeight: FontWeight.w900,
                                      ),
                                ),
                                const SizedBox(height: 10),
                                Text(
                                  widget.definition.completionMessage,
                                  textAlign: TextAlign.center,
                                  style: theme.textTheme.bodyLarge?.copyWith(
                                    color: const Color(0xFF4A5761),
                                    height: 1.5,
                                  ),
                                ),
                              ],
                            )
                          : Column(
                              key: ValueKey<String>(
                                'voice-idle-${widget.definition.kind.name}',
                              ),
                              mainAxisSize: MainAxisSize.min,
                              children: <Widget>[
                                Icon(
                                  widget.definition.icon,
                                  size: 52,
                                  color: widget.accent,
                                ),
                                const SizedBox(height: 16),
                                Text(
                                  widget.definition.idleTitle,
                                  textAlign: TextAlign.center,
                                  style: theme.textTheme.titleLarge?.copyWith(
                                    color: const Color(0xFF16212B),
                                    fontWeight: FontWeight.w900,
                                  ),
                                ),
                                const SizedBox(height: 10),
                                Text(
                                  widget.definition.idleSummary,
                                  textAlign: TextAlign.center,
                                  style: theme.textTheme.bodyLarge?.copyWith(
                                    color: const Color(0xFF4A5761),
                                    height: 1.5,
                                  ),
                                ),
                              ],
                            ),
                    ),
                  ),
                ),
              ),
            ],
          ),
        ),
        const SizedBox(height: 18),
        SizedBox(
          width: double.infinity,
          child: (_isCountingDown || _isRunning)
              ? const SizedBox.shrink()
              : FilledButton(
                  onPressed: _handleStartAction,
                  child: Text(_finished ? 'Powtórz sesję' : 'Start sesji'),
                ),
        ),
      ],
    );
  }
}

class _VoiceStatsRow extends StatelessWidget {
  const _VoiceStatsRow({
    required this.accent,
    required this.stepLabel,
    required this.modeLabel,
  });

  final Color accent;
  final String stepLabel;
  final String modeLabel;

  @override
  Widget build(BuildContext context) {
    return Row(
      children: <Widget>[
        Expanded(
          child: StatStrip(label: 'Etap', value: stepLabel, tint: accent),
        ),
        const SizedBox(width: 10),
        Expanded(
          child: StatStrip(label: 'Tryb', value: modeLabel, tint: accent),
        ),
      ],
    );
  }
}

PageRoute<T> _buildExerciseSessionRoute<T>({required WidgetBuilder builder}) {
  return PageRouteBuilder<T>(
    transitionDuration: const Duration(milliseconds: 220),
    reverseTransitionDuration: const Duration(milliseconds: 180),
    pageBuilder:
        (
          BuildContext context,
          Animation<double> animation,
          Animation<double> secondaryAnimation,
        ) {
          return builder(context);
        },
    transitionsBuilder:
        (
          BuildContext context,
          Animation<double> animation,
          Animation<double> secondaryAnimation,
          Widget child,
        ) {
          return FadeTransition(opacity: animation, child: child);
        },
  );
}

Future<void> _enterFullscreenSessionMode() {
  return SystemChrome.setEnabledSystemUIMode(SystemUiMode.immersiveSticky);
}

Future<void> _exitFullscreenSessionMode() {
  return SystemChrome.setEnabledSystemUIMode(
    SystemUiMode.manual,
    overlays: SystemUiOverlay.values,
  );
}

class FullscreenTrainerPage extends StatefulWidget {
  const FullscreenTrainerPage({
    super.key,
    required this.title,
    required this.accent,
    required this.child,
    this.expandBody = false,
    this.showHeader = true,
    this.wrapChildInSurfaceCard = true,
    this.contentMaxWidth = 720,
    this.bodyPadding = const EdgeInsets.fromLTRB(20, 16, 20, 24),
  });

  final String title;
  final Color accent;
  final Widget child;
  final bool expandBody;
  final bool showHeader;
  final bool wrapChildInSurfaceCard;
  final double? contentMaxWidth;
  final EdgeInsets bodyPadding;

  @override
  State<FullscreenTrainerPage> createState() => _FullscreenTrainerPageState();
}

class _FullscreenTrainerPageState extends State<FullscreenTrainerPage> {
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _enterFullscreenSessionMode();
    });
  }

  @override
  void dispose() {
    _exitFullscreenSessionMode();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final palette = context.appPalette;
    final header = Row(
      children: <Widget>[
        IconButton.filledTonal(
          onPressed: () => Navigator.of(context).maybePop(),
          style: IconButton.styleFrom(
            backgroundColor: palette.heroText.withValues(alpha: 0.14),
            foregroundColor: palette.heroText,
          ),
          icon: const Icon(Icons.close_rounded),
        ),
        const SizedBox(width: 14),
        Expanded(
          child: Text(
            widget.title,
            style: theme.textTheme.headlineMedium?.copyWith(
              color: palette.heroText,
            ),
          ),
        ),
        const SizedBox(width: 12),
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
          decoration: BoxDecoration(
            color: widget.accent.withValues(alpha: 0.18),
            borderRadius: BorderRadius.circular(18),
          ),
          child: Text(
            'Flow',
            style: theme.textTheme.labelLarge?.copyWith(
              color: palette.heroText,
              fontWeight: FontWeight.w800,
              letterSpacing: 0.8,
            ),
          ),
        ),
      ],
    );
    final content = widget.wrapChildInSurfaceCard
        ? SurfaceCard(
            color: palette.surfaceStrong.withValues(alpha: 0.96),
            child: widget.expandBody
                ? SizedBox.expand(child: widget.child)
                : widget.child,
          )
        : widget.child;
    final contentCard = widget.contentMaxWidth == null
        ? content
        : Center(
            child: ConstrainedBox(
              constraints: BoxConstraints(maxWidth: widget.contentMaxWidth!),
              child: content,
            ),
          );

    return Scaffold(
      body: DecoratedBox(
        decoration: BoxDecoration(
          gradient: LinearGradient(
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
            colors: <Color>[
              palette.fullscreenStart,
              palette.fullscreenMiddle,
              palette.fullscreenEnd,
            ],
          ),
        ),
        child: SafeArea(
          child: widget.expandBody
              ? Padding(
                  padding: widget.bodyPadding,
                  child: Column(
                    children: <Widget>[
                      if (widget.showHeader) header,
                      if (widget.showHeader) const SizedBox(height: 20),
                      Expanded(child: contentCard),
                    ],
                  ),
                )
              : ListView(
                  padding: widget.bodyPadding,
                  children: <Widget>[
                    if (widget.showHeader) header,
                    if (widget.showHeader) const SizedBox(height: 20),
                    contentCard,
                  ],
                ),
        ),
      ),
    );
  }
}

class ExercisePreviewCard extends StatelessWidget {
  const ExercisePreviewCard({
    super.key,
    required this.definition,
    required this.isCompleted,
    required this.onOpen,
  });

  final ExerciseDefinition definition;
  final bool isCompleted;
  final VoidCallback onOpen;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final palette = context.appPalette;

    return Material(
      color: Colors.transparent,
      child: InkWell(
        key: ValueKey<String>('exercise-${definition.kind.name}'),
        borderRadius: BorderRadius.circular(28),
        onTap: onOpen,
        child: SurfaceCard(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: <Widget>[
                  Container(
                    width: 54,
                    height: 54,
                    decoration: BoxDecoration(
                      color: definition.accent.withValues(alpha: 0.16),
                      borderRadius: BorderRadius.circular(18),
                    ),
                    child: Icon(
                      definition.icon,
                      color: definition.accent,
                      size: 28,
                    ),
                  ),
                  const SizedBox(width: 16),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: <Widget>[
                        Text(
                          definition.title,
                          style: theme.textTheme.titleLarge?.copyWith(
                            color: palette.primaryText,
                          ),
                        ),
                        const SizedBox(height: 6),
                        Text(
                          definition.subtitle,
                          style: theme.textTheme.bodyMedium?.copyWith(
                            color: palette.secondaryText,
                          ),
                        ),
                      ],
                    ),
                  ),
                  if (isCompleted)
                    Container(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 10,
                        vertical: 8,
                      ),
                      decoration: BoxDecoration(
                        color: palette.success.withValues(alpha: 0.14),
                        borderRadius: BorderRadius.circular(14),
                      ),
                      child: Icon(Icons.check_rounded, color: palette.success),
                    ),
                ],
              ),
              const SizedBox(height: 18),
              Wrap(
                spacing: 8,
                runSpacing: 8,
                children: definition.tags
                    .map(
                      (String tag) =>
                          TagChip(label: tag, tint: definition.accent),
                    )
                    .toList(),
              ),
              const SizedBox(height: 18),
              Row(
                children: <Widget>[
                  Expanded(
                    child: Text(
                      '${definition.duration} • ${definition.idealMoment}',
                      style: theme.textTheme.bodyMedium?.copyWith(
                        color: palette.secondaryText,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                  ),
                  FilledButton(onPressed: onOpen, child: const Text('Otwórz')),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class AppBackdrop extends StatelessWidget {
  const AppBackdrop({super.key});

  @override
  Widget build(BuildContext context) {
    final palette = context.appPalette;
    final backdropId = context.appBackdropId;
    return DecoratedBox(
      decoration: BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: <Color>[
            palette.backdropStart,
            palette.backdropMiddle,
            palette.backdropEnd,
          ],
        ),
      ),
      child: Stack(
        fit: StackFit.expand,
        children: <Widget>[
          Positioned.fill(
            child: _BackdropPatternLayer(
              backdropId: backdropId,
              palette: palette,
            ),
          ),
        ],
      ),
    );
  }
}

class GlowOrb extends StatelessWidget {
  const GlowOrb({super.key, required this.size, required this.color});

  final double size;
  final Color color;

  @override
  Widget build(BuildContext context) {
    return IgnorePointer(
      child: Container(
        width: size,
        height: size,
        decoration: BoxDecoration(shape: BoxShape.circle, color: color),
      ),
    );
  }
}

class _BackdropPatternLayer extends StatelessWidget {
  const _BackdropPatternLayer({
    required this.backdropId,
    required this.palette,
    this.compact = false,
  });

  final _AppBackdropId backdropId;
  final _AppPalette palette;
  final bool compact;

  @override
  Widget build(BuildContext context) {
    final primaryPatternColor = palette.heroText.withValues(
      alpha: compact ? 0.08 : 0.1,
    );
    final accentPatternColor = palette.glowTop.withValues(
      alpha: compact ? 0.22 : 0.34,
    );
    final accentSoftPatternColor = palette.glowMiddle.withValues(
      alpha: compact ? 0.2 : 0.28,
    );

    return IgnorePointer(
      child: switch (backdropId) {
        _AppBackdropId.glow => Stack(
          fit: StackFit.expand,
          children: <Widget>[
            Positioned(
              top: compact ? -18 : -120,
              right: compact ? -8 : -70,
              child: GlowOrb(size: compact ? 92 : 280, color: palette.glowTop),
            ),
            Positioned(
              top: compact ? 24 : 260,
              left: compact ? -16 : -70,
              child: GlowOrb(
                size: compact ? 72 : 240,
                color: palette.glowMiddle,
              ),
            ),
            Positioned(
              bottom: compact ? -10 : -80,
              right: compact ? 6 : 24,
              child: GlowOrb(
                size: compact ? 64 : 220,
                color: palette.glowBottom,
              ),
            ),
          ],
        ),
        _AppBackdropId.grid => CustomPaint(
          painter: _BackdropGridPainter(
            lineColor: primaryPatternColor,
            spacing: compact ? 14 : 32,
          ),
        ),
        _AppBackdropId.diagonal => CustomPaint(
          painter: _BackdropDiagonalPainter(
            stripeColor: primaryPatternColor,
            glowColor: accentPatternColor,
          ),
        ),
        _AppBackdropId.rings => Stack(
          fit: StackFit.expand,
          children: <Widget>[
            Positioned(
              top: compact ? -8 : 30,
              left: compact ? -12 : -28,
              child: _BackdropRing(
                size: compact ? 60 : 220,
                color: palette.heroText.withValues(alpha: compact ? 0.1 : 0.12),
              ),
            ),
            Positioned(
              top: compact ? 20 : 180,
              right: compact ? -10 : -18,
              child: _BackdropRing(
                size: compact ? 46 : 180,
                color: palette.glowTop.withValues(alpha: 0.5),
              ),
            ),
            Positioned(
              bottom: compact ? -12 : -26,
              left: compact ? 36 : 80,
              child: _BackdropRing(
                size: compact ? 54 : 200,
                color: palette.glowMiddle.withValues(alpha: 0.5),
              ),
            ),
          ],
        ),
        _AppBackdropId.dots => CustomPaint(
          painter: _BackdropDotsPainter(
            dotColor: palette.heroText.withValues(alpha: compact ? 0.14 : 0.18),
            accentColor: palette.glowTop.withValues(
              alpha: compact ? 0.3 : 0.42,
            ),
            spacing: compact ? 18 : 34,
          ),
        ),
        _AppBackdropId.polynesiaChevron => CustomPaint(
          painter: _Backdrop3DCubesPainter(
            lineColor: primaryPatternColor,
            accentColor: accentPatternColor,
            softColor: accentSoftPatternColor,
            compact: compact,
          ),
        ),
        _AppBackdropId.warriorTattoo => CustomPaint(
          painter: _Backdrop3DWavePainter(
            lineColor: primaryPatternColor,
            accentColor: accentPatternColor,
            softColor: accentSoftPatternColor,
            compact: compact,
          ),
        ),
        _AppBackdropId.warriorMask => CustomPaint(
          painter: _Backdrop3DStepsPainter(
            lineColor: primaryPatternColor,
            accentColor: accentPatternColor,
            softColor: accentSoftPatternColor,
            compact: compact,
          ),
        ),
        _AppBackdropId.warriorShield => CustomPaint(
          painter: _Backdrop3DCrystalPainter(
            lineColor: primaryPatternColor,
            accentColor: accentPatternColor,
            softColor: accentSoftPatternColor,
            compact: compact,
          ),
        ),
        _AppBackdropId.warriorTotem => CustomPaint(
          painter: _Backdrop3DTunnelPainter(
            lineColor: primaryPatternColor,
            accentColor: accentPatternColor,
            softColor: accentSoftPatternColor,
            compact: compact,
          ),
        ),
        _AppBackdropId.polynesiaTapa => CustomPaint(
          painter: _Backdrop3DWavePainter(
            lineColor: primaryPatternColor,
            accentColor: accentPatternColor,
            softColor: accentSoftPatternColor,
            compact: compact,
          ),
        ),
        _AppBackdropId.polynesiaWaves => CustomPaint(
          painter: _Backdrop3DStepsPainter(
            lineColor: primaryPatternColor,
            accentColor: accentPatternColor,
            softColor: accentSoftPatternColor,
            compact: compact,
          ),
        ),
        _AppBackdropId.polynesiaSpears => CustomPaint(
          painter: _Backdrop3DCrystalPainter(
            lineColor: primaryPatternColor,
            accentColor: accentPatternColor,
            softColor: accentSoftPatternColor,
            compact: compact,
          ),
        ),
        _AppBackdropId.polynesiaDiamond => CustomPaint(
          painter: _Backdrop3DTunnelPainter(
            lineColor: primaryPatternColor,
            accentColor: accentPatternColor,
            softColor: accentSoftPatternColor,
            compact: compact,
          ),
        ),
        _AppBackdropId.warriorSpears => CustomPaint(
          painter: _Backdrop3DCubesPainter(
            lineColor: primaryPatternColor,
            accentColor: accentPatternColor,
            softColor: accentSoftPatternColor,
            compact: compact,
          ),
        ),
      },
    );
  }
}

class _BackdropRing extends StatelessWidget {
  const _BackdropRing({required this.size, required this.color});

  final double size;
  final Color color;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: size,
      height: size,
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        border: Border.all(color: color, width: 2),
      ),
    );
  }
}

class _BackdropGridPainter extends CustomPainter {
  const _BackdropGridPainter({required this.lineColor, required this.spacing});

  final Color lineColor;
  final double spacing;

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..color = lineColor
      ..strokeWidth = 1;

    for (double x = 0; x <= size.width; x += spacing) {
      canvas.drawLine(Offset(x, 0), Offset(x, size.height), paint);
    }
    for (double y = 0; y <= size.height; y += spacing) {
      canvas.drawLine(Offset(0, y), Offset(size.width, y), paint);
    }
  }

  @override
  bool shouldRepaint(covariant _BackdropGridPainter oldDelegate) {
    return oldDelegate.lineColor != lineColor || oldDelegate.spacing != spacing;
  }
}

class _BackdropDiagonalPainter extends CustomPainter {
  const _BackdropDiagonalPainter({
    required this.stripeColor,
    required this.glowColor,
  });

  final Color stripeColor;
  final Color glowColor;

  @override
  void paint(Canvas canvas, Size size) {
    final stripePaint = Paint()
      ..color = stripeColor
      ..strokeWidth = 22;
    final glowPaint = Paint()
      ..color = glowColor
      ..strokeWidth = 48;

    canvas.drawLine(
      Offset(-size.width * 0.2, size.height * 0.2),
      Offset(size.width * 0.9, -size.height * 0.3),
      glowPaint,
    );
    canvas.drawLine(
      Offset(-size.width * 0.1, size.height * 0.78),
      Offset(size.width * 1.1, size.height * 0.08),
      stripePaint,
    );
    canvas.drawLine(
      Offset(size.width * 0.08, size.height * 1.08),
      Offset(size.width * 1.1, size.height * 0.42),
      stripePaint,
    );
  }

  @override
  bool shouldRepaint(covariant _BackdropDiagonalPainter oldDelegate) {
    return oldDelegate.stripeColor != stripeColor ||
        oldDelegate.glowColor != glowColor;
  }
}

class _BackdropDotsPainter extends CustomPainter {
  const _BackdropDotsPainter({
    required this.dotColor,
    required this.accentColor,
    required this.spacing,
  });

  final Color dotColor;
  final Color accentColor;
  final double spacing;

  @override
  void paint(Canvas canvas, Size size) {
    final dotPaint = Paint()..color = dotColor;
    final accentPaint = Paint()..color = accentColor;

    for (double y = spacing * 0.5; y < size.height; y += spacing) {
      for (double x = spacing * 0.5; x < size.width; x += spacing) {
        final bool accent =
            ((x / spacing).round() + (y / spacing).round()) % 4 == 0;
        canvas.drawCircle(
          Offset(x, y),
          accent ? 2.6 : 1.7,
          accent ? accentPaint : dotPaint,
        );
      }
    }
  }

  @override
  bool shouldRepaint(covariant _BackdropDotsPainter oldDelegate) {
    return oldDelegate.dotColor != dotColor ||
        oldDelegate.accentColor != accentColor ||
        oldDelegate.spacing != spacing;
  }
}

class _Backdrop3DCubesPainter extends CustomPainter {
  const _Backdrop3DCubesPainter({
    required this.lineColor,
    required this.accentColor,
    required this.softColor,
    required this.compact,
  });

  final Color lineColor;
  final Color accentColor;
  final Color softColor;
  final bool compact;

  @override
  void paint(Canvas canvas, Size size) {
    final outlinePaint = Paint()
      ..color = lineColor
      ..style = PaintingStyle.stroke
      ..strokeWidth = compact ? 0.8 : 1.2;
    final topPaint = Paint()
      ..color = lineColor.withValues(alpha: compact ? 0.12 : 0.1)
      ..style = PaintingStyle.fill;
    final leftPaint = Paint()
      ..color = softColor.withValues(alpha: compact ? 0.18 : 0.16)
      ..style = PaintingStyle.fill;
    final rightPaint = Paint()
      ..color = accentColor.withValues(alpha: compact ? 0.22 : 0.18)
      ..style = PaintingStyle.fill;
    final cubeWidth = compact ? 30.0 : 70.0;
    final cubeHeight = cubeWidth * 0.52;
    final depth = cubeWidth * 0.28;
    int row = 0;

    for (
      double y = -cubeHeight;
      y <= size.height + cubeHeight;
      y += cubeHeight
    ) {
      final startX = row.isOdd ? -cubeWidth * 0.5 : -cubeWidth;
      for (double x = startX; x <= size.width + cubeWidth; x += cubeWidth) {
        final top = Path()
          ..moveTo(x + cubeWidth * 0.5, y)
          ..lineTo(x + cubeWidth, y + cubeHeight * 0.28)
          ..lineTo(x + cubeWidth * 0.5, y + cubeHeight * 0.56)
          ..lineTo(x, y + cubeHeight * 0.28)
          ..close();
        final left = Path()
          ..moveTo(x, y + cubeHeight * 0.28)
          ..lineTo(x + cubeWidth * 0.5, y + cubeHeight * 0.56)
          ..lineTo(x + cubeWidth * 0.5, y + cubeHeight * 0.56 + depth)
          ..lineTo(x, y + cubeHeight * 0.28 + depth)
          ..close();
        final right = Path()
          ..moveTo(x + cubeWidth, y + cubeHeight * 0.28)
          ..lineTo(x + cubeWidth * 0.5, y + cubeHeight * 0.56)
          ..lineTo(x + cubeWidth * 0.5, y + cubeHeight * 0.56 + depth)
          ..lineTo(x + cubeWidth, y + cubeHeight * 0.28 + depth)
          ..close();

        canvas.drawPath(top, topPaint);
        canvas.drawPath(left, leftPaint);
        canvas.drawPath(right, rightPaint);
        canvas.drawPath(top, outlinePaint);
      }
      row++;
    }
  }

  @override
  bool shouldRepaint(covariant _Backdrop3DCubesPainter oldDelegate) {
    return oldDelegate.lineColor != lineColor ||
        oldDelegate.accentColor != accentColor ||
        oldDelegate.softColor != softColor ||
        oldDelegate.compact != compact;
  }
}

class _Backdrop3DWavePainter extends CustomPainter {
  const _Backdrop3DWavePainter({
    required this.lineColor,
    required this.accentColor,
    required this.softColor,
    required this.compact,
  });

  final Color lineColor;
  final Color accentColor;
  final Color softColor;
  final bool compact;

  @override
  void paint(Canvas canvas, Size size) {
    final topPaint = Paint()
      ..color = lineColor.withValues(alpha: compact ? 0.1 : 0.09)
      ..style = PaintingStyle.fill;
    final sidePaint = Paint()
      ..color = accentColor.withValues(alpha: compact ? 0.14 : 0.12)
      ..style = PaintingStyle.fill;
    final highlightPaint = Paint()
      ..color = softColor.withValues(alpha: compact ? 0.24 : 0.18)
      ..style = PaintingStyle.stroke
      ..strokeWidth = compact ? 1.1 : 1.8
      ..strokeCap = StrokeCap.round;
    final rowGap = compact ? 22.0 : 50.0;
    final bandHeight = compact ? 10.0 : 22.0;
    final waveWidth = compact ? 42.0 : 92.0;

    for (double y = -rowGap; y <= size.height + rowGap; y += rowGap) {
      final topPath = Path()..moveTo(-waveWidth, y + bandHeight);
      for (double x = -waveWidth; x <= size.width + waveWidth; x += waveWidth) {
        topPath.quadraticBezierTo(
          x + waveWidth * 0.25,
          y,
          x + waveWidth * 0.5,
          y + bandHeight * 0.55,
        );
        topPath.quadraticBezierTo(
          x + waveWidth * 0.75,
          y + bandHeight * 1.1,
          x + waveWidth,
          y + bandHeight * 0.55,
        );
      }
      topPath.lineTo(size.width + waveWidth, y + bandHeight * 1.9);
      topPath.lineTo(-waveWidth, y + bandHeight * 1.9);
      topPath.close();

      final sidePath = Path()..moveTo(-waveWidth, y + bandHeight * 1.9);
      for (double x = -waveWidth; x <= size.width + waveWidth; x += waveWidth) {
        sidePath.quadraticBezierTo(
          x + waveWidth * 0.25,
          y + bandHeight * 1.1,
          x + waveWidth * 0.5,
          y + bandHeight * 1.55,
        );
        sidePath.quadraticBezierTo(
          x + waveWidth * 0.75,
          y + bandHeight * 2.0,
          x + waveWidth,
          y + bandHeight * 1.55,
        );
      }
      sidePath.lineTo(size.width + waveWidth, y + bandHeight * 2.45);
      sidePath.lineTo(-waveWidth, y + bandHeight * 2.45);
      sidePath.close();

      canvas.drawPath(sidePath, sidePaint);
      canvas.drawPath(topPath, topPaint);

      final highlightPath = Path()..moveTo(-waveWidth, y + bandHeight);
      for (double x = -waveWidth; x <= size.width + waveWidth; x += waveWidth) {
        highlightPath.quadraticBezierTo(
          x + waveWidth * 0.25,
          y,
          x + waveWidth * 0.5,
          y + bandHeight * 0.55,
        );
        highlightPath.quadraticBezierTo(
          x + waveWidth * 0.75,
          y + bandHeight * 1.1,
          x + waveWidth,
          y + bandHeight * 0.55,
        );
      }
      canvas.drawPath(highlightPath, highlightPaint);
    }
  }

  @override
  bool shouldRepaint(covariant _Backdrop3DWavePainter oldDelegate) {
    return oldDelegate.lineColor != lineColor ||
        oldDelegate.accentColor != accentColor ||
        oldDelegate.softColor != softColor ||
        oldDelegate.compact != compact;
  }
}

class _Backdrop3DStepsPainter extends CustomPainter {
  const _Backdrop3DStepsPainter({
    required this.lineColor,
    required this.accentColor,
    required this.softColor,
    required this.compact,
  });

  final Color lineColor;
  final Color accentColor;
  final Color softColor;
  final bool compact;

  @override
  void paint(Canvas canvas, Size size) {
    final topPaint = Paint()
      ..color = lineColor.withValues(alpha: compact ? 0.12 : 0.09)
      ..style = PaintingStyle.fill;
    final facePaint = Paint()
      ..color = accentColor.withValues(alpha: compact ? 0.18 : 0.14)
      ..style = PaintingStyle.fill;
    final edgePaint = Paint()
      ..color = softColor.withValues(alpha: compact ? 0.2 : 0.16)
      ..style = PaintingStyle.stroke
      ..strokeWidth = compact ? 1 : 1.4;
    final panelWidth = compact ? 38.0 : 92.0;
    final panelHeight = compact ? 18.0 : 40.0;

    for (
      double x = -panelWidth;
      x <= size.width + panelWidth;
      x += panelWidth * 0.8
    ) {
      for (
        double y = -panelHeight;
        y <= size.height + panelHeight;
        y += panelHeight * 1.3
      ) {
        final staggerOffset = ((y / panelHeight).round()).isEven
            ? 0.0
            : panelWidth * 0.18;
        final rect = Rect.fromLTWH(
          x + staggerOffset,
          y,
          panelWidth,
          panelHeight,
        );
        final topRect = RRect.fromRectAndRadius(
          rect,
          Radius.circular(compact ? 5 : 12),
        );
        final sideRect = Rect.fromLTWH(
          rect.left + panelWidth * 0.18,
          rect.bottom,
          panelWidth * 0.82,
          panelHeight * 0.42,
        );
        canvas.drawRRect(topRect, topPaint);
        canvas.drawRRect(
          RRect.fromRectAndRadius(sideRect, Radius.circular(compact ? 4 : 10)),
          facePaint,
        );
        canvas.drawLine(
          Offset(rect.left + panelWidth * 0.1, rect.top + panelHeight * 0.28),
          Offset(rect.right - panelWidth * 0.1, rect.top + panelHeight * 0.28),
          edgePaint,
        );
      }
    }
  }

  @override
  bool shouldRepaint(covariant _Backdrop3DStepsPainter oldDelegate) {
    return oldDelegate.lineColor != lineColor ||
        oldDelegate.accentColor != accentColor ||
        oldDelegate.softColor != softColor ||
        oldDelegate.compact != compact;
  }
}

class _Backdrop3DCrystalPainter extends CustomPainter {
  const _Backdrop3DCrystalPainter({
    required this.lineColor,
    required this.accentColor,
    required this.softColor,
    required this.compact,
  });

  final Color lineColor;
  final Color accentColor;
  final Color softColor;
  final bool compact;

  @override
  void paint(Canvas canvas, Size size) {
    final leftPaint = Paint()
      ..color = lineColor.withValues(alpha: compact ? 0.12 : 0.1)
      ..style = PaintingStyle.fill;
    final rightPaint = Paint()
      ..color = accentColor.withValues(alpha: compact ? 0.18 : 0.15)
      ..style = PaintingStyle.fill;
    final topPaint = Paint()
      ..color = softColor.withValues(alpha: compact ? 0.22 : 0.18)
      ..style = PaintingStyle.fill;
    final outlinePaint = Paint()
      ..color = lineColor.withValues(alpha: compact ? 0.18 : 0.14)
      ..style = PaintingStyle.stroke
      ..strokeWidth = compact ? 0.8 : 1.2;
    final crystalWidth = compact ? 34.0 : 78.0;
    final crystalHeight = compact ? 42.0 : 94.0;
    int row = 0;

    for (
      double y = -crystalHeight;
      y <= size.height + crystalHeight;
      y += crystalHeight * 0.72
    ) {
      final startX = row.isOdd ? -crystalWidth * 0.4 : -crystalWidth;
      for (
        double x = startX;
        x <= size.width + crystalWidth;
        x += crystalWidth * 0.92
      ) {
        final top = Offset(x + crystalWidth * 0.5, y);
        final left = Offset(x, y + crystalHeight * 0.35);
        final center = Offset(x + crystalWidth * 0.5, y + crystalHeight * 0.5);
        final right = Offset(x + crystalWidth, y + crystalHeight * 0.35);
        final bottom = Offset(x + crystalWidth * 0.5, y + crystalHeight);

        canvas.drawPath(
          Path()
            ..moveTo(top.dx, top.dy)
            ..lineTo(center.dx, center.dy)
            ..lineTo(left.dx, left.dy)
            ..close(),
          leftPaint,
        );
        canvas.drawPath(
          Path()
            ..moveTo(top.dx, top.dy)
            ..lineTo(right.dx, right.dy)
            ..lineTo(center.dx, center.dy)
            ..close(),
          topPaint,
        );
        canvas.drawPath(
          Path()
            ..moveTo(left.dx, left.dy)
            ..lineTo(center.dx, center.dy)
            ..lineTo(bottom.dx, bottom.dy)
            ..close(),
          leftPaint,
        );
        canvas.drawPath(
          Path()
            ..moveTo(center.dx, center.dy)
            ..lineTo(right.dx, right.dy)
            ..lineTo(bottom.dx, bottom.dy)
            ..close(),
          rightPaint,
        );

        final crystalPath = Path()
          ..moveTo(top.dx, top.dy)
          ..lineTo(left.dx, left.dy)
          ..lineTo(bottom.dx, bottom.dy)
          ..lineTo(right.dx, right.dy)
          ..close();
        canvas.drawPath(crystalPath, outlinePaint);
      }
      row++;
    }
  }

  @override
  bool shouldRepaint(covariant _Backdrop3DCrystalPainter oldDelegate) {
    return oldDelegate.lineColor != lineColor ||
        oldDelegate.accentColor != accentColor ||
        oldDelegate.softColor != softColor ||
        oldDelegate.compact != compact;
  }
}

class _Backdrop3DTunnelPainter extends CustomPainter {
  const _Backdrop3DTunnelPainter({
    required this.lineColor,
    required this.accentColor,
    required this.softColor,
    required this.compact,
  });

  final Color lineColor;
  final Color accentColor;
  final Color softColor;
  final bool compact;

  @override
  void paint(Canvas canvas, Size size) {
    final framePaint = Paint()
      ..color = lineColor.withValues(alpha: compact ? 0.16 : 0.12)
      ..style = PaintingStyle.stroke
      ..strokeWidth = compact ? 1.2 : 2.2;
    final shadowPaint = Paint()
      ..color = accentColor.withValues(alpha: compact ? 0.18 : 0.14)
      ..style = PaintingStyle.stroke
      ..strokeWidth = compact ? 2.8 : 5;
    final glowPaint = Paint()
      ..color = softColor.withValues(alpha: compact ? 0.12 : 0.1)
      ..style = PaintingStyle.fill;

    final center = Offset(size.width * 0.5, size.height * 0.5);
    final rings = compact ? 5 : 6;

    for (int i = 0; i < rings; i++) {
      final factor = 1 - i / (rings + 1);
      final width = size.width * (0.92 * factor);
      final height = size.height * (0.82 * factor);
      final rect = Rect.fromCenter(
        center: center.translate(
          i * (compact ? 2.0 : 4.0),
          i * (compact ? 1.2 : 2.4),
        ),
        width: max(width, compact ? 18 : 30),
        height: max(height, compact ? 16 : 28),
      );
      final rrect = RRect.fromRectAndRadius(
        rect,
        Radius.circular(compact ? 10 : 24),
      );
      canvas.drawRRect(
        rrect.shift(Offset(compact ? 1.2 : 2.2, compact ? 1.2 : 2.2)),
        shadowPaint,
      );
      canvas.drawRRect(rrect, framePaint);
    }

    canvas.drawOval(
      Rect.fromCenter(
        center: center,
        width: compact ? 34 : 90,
        height: compact ? 24 : 60,
      ),
      glowPaint,
    );
  }

  @override
  bool shouldRepaint(covariant _Backdrop3DTunnelPainter oldDelegate) {
    return oldDelegate.lineColor != lineColor ||
        oldDelegate.accentColor != accentColor ||
        oldDelegate.softColor != softColor ||
        oldDelegate.compact != compact;
  }
}

class SurfaceCard extends StatelessWidget {
  const SurfaceCard({super.key, required this.child, this.color});

  final Widget child;
  final Color? color;

  @override
  Widget build(BuildContext context) {
    final palette = context.appPalette;
    return Container(
      clipBehavior: Clip.antiAlias,
      padding: const EdgeInsets.all(22),
      decoration: BoxDecoration(
        color: color ?? palette.surface.withValues(alpha: 0.9),
        borderRadius: BorderRadius.circular(28),
        border: Border.all(color: palette.surfaceBorder),
        boxShadow: <BoxShadow>[
          BoxShadow(
            color: palette.shadowColor,
            blurRadius: 32,
            offset: const Offset(0, 16),
          ),
        ],
      ),
      child: child,
    );
  }
}

class _GoldenCrownCard extends StatefulWidget {
  const _GoldenCrownCard({required this.onUnlocked});

  final VoidCallback onUnlocked;

  @override
  State<_GoldenCrownCard> createState() => _GoldenCrownCardState();
}

class _GoldenCrownCardState extends State<_GoldenCrownCard>
    with SingleTickerProviderStateMixin {
  static const int _unlockTapTarget = 20;
  static const Duration _revealDelay = Duration(milliseconds: 420);

  late final AnimationController _controller;
  Timer? _revealTimer;
  int _tapCount = 0;
  bool _showCrackedPaper = false;

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 5200),
    );

    final bool isWidgetTest = WidgetsBinding.instance.runtimeType
        .toString()
        .contains('TestWidgetsFlutterBinding');
    if (isWidgetTest) {
      _controller.value = 0.28;
    } else {
      _controller.repeat();
    }
  }

  @override
  void dispose() {
    _revealTimer?.cancel();
    _controller.dispose();
    super.dispose();
  }

  void _handleTap() {
    if (_showCrackedPaper) {
      return;
    }

    _tapCount += 1;
    if (_tapCount < _unlockTapTarget) {
      return;
    }

    setState(() {
      _showCrackedPaper = true;
    });

    _revealTimer?.cancel();
    _revealTimer = Timer(_revealDelay, widget.onUnlocked);
  }

  @override
  Widget build(BuildContext context) {
    final palette = context.appPalette;

    return GestureDetector(
      onTap: _handleTap,
      behavior: HitTestBehavior.opaque,
      child: AnimatedBuilder(
        animation: _controller,
        builder: (BuildContext context, Widget? child) {
          final double progress = _controller.value;
          final double pulse =
              0.96 + (0.08 * (0.5 + (0.5 * sin(progress * 2 * pi))));
          final double haloOpacity =
              0.18 +
              (0.2 * (0.5 + (0.5 * sin((progress * 2 * pi) - (pi / 5)))));
          final double crownBob = 6 * sin(progress * 2 * pi);
          final double crownScale =
              0.98 +
              (0.06 * (0.5 + (0.5 * sin((progress * 2 * pi) + (pi / 4)))));
          final double sweepX = -110 + (progress * 320);

          return Container(
            key: const ValueKey<String>('golden-crown-card'),
            height: 196,
            clipBehavior: Clip.antiAlias,
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(32),
              gradient: const LinearGradient(
                begin: Alignment.topLeft,
                end: Alignment.bottomRight,
                colors: <Color>[
                  Color(0xFF140D04),
                  Color(0xFF53350C),
                  Color(0xFF1A1104),
                ],
              ),
              border: Border.all(
                color: const Color(0xFFFFE7A6).withValues(alpha: 0.34),
              ),
              boxShadow: <BoxShadow>[
                BoxShadow(
                  color: palette.shadowColor.withValues(alpha: 0.7),
                  blurRadius: 34,
                  offset: const Offset(0, 18),
                ),
                BoxShadow(
                  color: const Color(0xFFE0AA42).withValues(alpha: 0.18),
                  blurRadius: 44,
                  spreadRadius: 1,
                ),
              ],
            ),
            child: Stack(
              fit: StackFit.expand,
              children: <Widget>[
                DecoratedBox(
                  decoration: BoxDecoration(
                    gradient: RadialGradient(
                      center: const Alignment(0, -0.18),
                      radius: 0.92,
                      colors: <Color>[
                        const Color(0xFFFFE29A).withValues(alpha: 0.2),
                        const Color(0xFFE2A63C).withValues(alpha: 0.08),
                        Colors.transparent,
                      ],
                      stops: const <double>[0, 0.44, 1],
                    ),
                  ),
                ),
                IgnorePointer(
                  child: CustomPaint(
                    painter: _GoldenSparklePainter(progress: progress),
                  ),
                ),
                Positioned(
                  left: sweepX,
                  top: -60,
                  child: Transform.rotate(
                    angle: -0.42,
                    child: Container(
                      width: 84,
                      height: 320,
                      decoration: BoxDecoration(
                        gradient: LinearGradient(
                          begin: Alignment.centerLeft,
                          end: Alignment.centerRight,
                          colors: <Color>[
                            Colors.transparent,
                            const Color(0xFFFFF1B8).withValues(alpha: 0.12),
                            const Color(0xFFFFF7D2).withValues(alpha: 0.3),
                            const Color(0xFFFFF1B8).withValues(alpha: 0.12),
                            Colors.transparent,
                          ],
                        ),
                      ),
                    ),
                  ),
                ),
                Center(
                  child: Transform.scale(
                    scale: pulse,
                    child: Container(
                      width: 170,
                      height: 170,
                      decoration: BoxDecoration(
                        shape: BoxShape.circle,
                        gradient: RadialGradient(
                          colors: <Color>[
                            Colors.white.withValues(alpha: haloOpacity),
                            const Color(
                              0xFFFFD77A,
                            ).withValues(alpha: haloOpacity * 0.52),
                            Colors.transparent,
                          ],
                          stops: const <double>[0, 0.22, 1],
                        ),
                      ),
                    ),
                  ),
                ),
                Align(
                  alignment: Alignment.bottomCenter,
                  child: Padding(
                    padding: const EdgeInsets.only(bottom: 28),
                    child: Container(
                      width: 170,
                      height: 2,
                      decoration: BoxDecoration(
                        gradient: LinearGradient(
                          colors: <Color>[
                            Colors.transparent,
                            const Color(0xFFFFE6A5).withValues(alpha: 0.7),
                            Colors.transparent,
                          ],
                        ),
                      ),
                    ),
                  ),
                ),
                Center(
                  child: AnimatedOpacity(
                    duration: const Duration(milliseconds: 180),
                    opacity: _showCrackedPaper ? 0.16 : 1,
                    child: Transform.translate(
                      offset: Offset(0, crownBob),
                      child: Transform.scale(
                        scale: crownScale,
                        child: const SizedBox(
                          width: 128,
                          height: 94,
                          child: CustomPaint(painter: _CrownPainter()),
                        ),
                      ),
                    ),
                  ),
                ),
                if (_showCrackedPaper)
                  Center(
                    child: TweenAnimationBuilder<double>(
                      tween: Tween<double>(begin: 0.82, end: 1),
                      duration: const Duration(milliseconds: 220),
                      curve: Curves.easeOutBack,
                      builder:
                          (BuildContext context, double scale, Widget? child) {
                            return Transform.scale(scale: scale, child: child);
                          },
                      child: Container(
                        key: const ValueKey<String>('golden-secret-paper'),
                        width: 184,
                        height: 132,
                        decoration: BoxDecoration(
                          gradient: const LinearGradient(
                            begin: Alignment.topLeft,
                            end: Alignment.bottomRight,
                            colors: <Color>[
                              Color(0xFFFBEFC8),
                              Color(0xFFE7CB88),
                              Color(0xFFF6E3B4),
                            ],
                          ),
                          borderRadius: BorderRadius.circular(18),
                          border: Border.all(
                            color: const Color(
                              0xFF8A6225,
                            ).withValues(alpha: 0.22),
                          ),
                          boxShadow: <BoxShadow>[
                            BoxShadow(
                              color: Colors.black.withValues(alpha: 0.18),
                              blurRadius: 18,
                              offset: const Offset(0, 10),
                            ),
                          ],
                        ),
                        child: CustomPaint(
                          painter: const _GoldenSecretCrackPainter(),
                        ),
                      ),
                    ),
                  ),
              ],
            ),
          );
        },
      ),
    );
  }
}

class _GoldenSparklePainter extends CustomPainter {
  const _GoldenSparklePainter({required this.progress});

  final double progress;

  @override
  void paint(Canvas canvas, Size size) {
    final Paint ringPaint = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.2
      ..color = const Color(0xFFFFE6A5).withValues(alpha: 0.14);

    canvas.drawArc(
      Rect.fromCenter(
        center: Offset(size.width * 0.5, size.height * 0.52),
        width: size.width * 0.62,
        height: size.height * 0.72,
      ),
      -pi / 2 + (progress * 0.6),
      pi * 1.35,
      false,
      ringPaint,
    );

    const List<Offset> anchors = <Offset>[
      Offset(0.2, 0.28),
      Offset(0.3, 0.74),
      Offset(0.5, 0.2),
      Offset(0.72, 0.68),
      Offset(0.82, 0.3),
    ];

    for (int i = 0; i < anchors.length; i += 1) {
      final Offset anchor = anchors[i];
      final double angle = (progress * 2 * pi) + (i * pi / 3);
      final Offset center = Offset(
        size.width * anchor.dx + (8 * sin(angle)),
        size.height * anchor.dy + (10 * cos(angle * 0.92)),
      );
      final double radius = 1.8 + (1.5 * (0.5 + (0.5 * sin(angle + (pi / 4)))));
      final double opacity = 0.2 + (0.45 * (0.5 + (0.5 * sin(angle))));

      final Paint glowPaint = Paint()
        ..color = const Color(0xFFFFD980).withValues(alpha: opacity * 0.34)
        ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 9);
      final Paint fillPaint = Paint()
        ..color = const Color(0xFFFFF8DD).withValues(alpha: opacity);

      canvas.drawCircle(center, radius * 2.6, glowPaint);
      canvas.drawCircle(center, radius, fillPaint);
    }
  }

  @override
  bool shouldRepaint(covariant _GoldenSparklePainter oldDelegate) {
    return oldDelegate.progress != progress;
  }
}

class _GoldenSecretCrackPainter extends CustomPainter {
  const _GoldenSecretCrackPainter();

  @override
  void paint(Canvas canvas, Size size) {
    final Paint shadowPaint = Paint()
      ..color = const Color(0xFF2D1A06).withValues(alpha: 0.18)
      ..style = PaintingStyle.stroke
      ..strokeWidth = 4
      ..strokeCap = StrokeCap.round;
    final Paint crackPaint = Paint()
      ..color = const Color(0xFF6A4218).withValues(alpha: 0.82)
      ..style = PaintingStyle.stroke
      ..strokeWidth = 2.3
      ..strokeCap = StrokeCap.round;
    final Paint branchPaint = Paint()
      ..color = const Color(0xFF9D6B2F).withValues(alpha: 0.44)
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.3
      ..strokeCap = StrokeCap.round;

    final Path mainCrack = Path()
      ..moveTo(size.width * 0.5, size.height * 0.02)
      ..lineTo(size.width * 0.47, size.height * 0.18)
      ..lineTo(size.width * 0.56, size.height * 0.34)
      ..lineTo(size.width * 0.43, size.height * 0.54)
      ..lineTo(size.width * 0.54, size.height * 0.72)
      ..lineTo(size.width * 0.49, size.height * 0.98);

    final Path leftBranch = Path()
      ..moveTo(size.width * 0.47, size.height * 0.18)
      ..lineTo(size.width * 0.34, size.height * 0.25)
      ..lineTo(size.width * 0.28, size.height * 0.38)
      ..moveTo(size.width * 0.43, size.height * 0.54)
      ..lineTo(size.width * 0.26, size.height * 0.61)
      ..lineTo(size.width * 0.21, size.height * 0.76);

    final Path rightBranch = Path()
      ..moveTo(size.width * 0.56, size.height * 0.34)
      ..lineTo(size.width * 0.71, size.height * 0.27)
      ..lineTo(size.width * 0.8, size.height * 0.37)
      ..moveTo(size.width * 0.54, size.height * 0.72)
      ..lineTo(size.width * 0.68, size.height * 0.77)
      ..lineTo(size.width * 0.77, size.height * 0.9);

    canvas.drawPath(mainCrack.shift(const Offset(1.4, 1.8)), shadowPaint);
    canvas.drawPath(leftBranch.shift(const Offset(1.4, 1.8)), shadowPaint);
    canvas.drawPath(rightBranch.shift(const Offset(1.4, 1.8)), shadowPaint);
    canvas.drawPath(mainCrack, crackPaint);
    canvas.drawPath(leftBranch, branchPaint);
    canvas.drawPath(rightBranch, branchPaint);
  }

  @override
  bool shouldRepaint(covariant _GoldenSecretCrackPainter oldDelegate) {
    return false;
  }
}

class MnemonicMorningReviewMetric extends StatelessWidget {
  const MnemonicMorningReviewMetric({
    super.key,
    required this.isFlipped,
    required this.completedCount,
    required this.dailyTarget,
    required this.showCompletionPrompt,
    required this.onFlip,
    required this.onLongPress,
    required this.onMarkCompleted,
  });

  final bool isFlipped;
  final int completedCount;
  final int dailyTarget;
  final bool showCompletionPrompt;
  final VoidCallback onFlip;
  final VoidCallback onLongPress;
  final VoidCallback onMarkCompleted;

  @override
  Widget build(BuildContext context) {
    return TweenAnimationBuilder<double>(
      key: const ValueKey<String>('mnemonic-morning-card'),
      tween: Tween<double>(begin: 0, end: isFlipped ? 1 : 0),
      duration: const Duration(milliseconds: 420),
      curve: Curves.easeInOutCubic,
      builder: (BuildContext context, double value, Widget? child) {
        final angle = value * pi;
        final showBack = value >= 0.5;
        final face = showBack
            ? Transform(
                alignment: Alignment.center,
                transform: Matrix4.identity()..rotateY(pi),
                child: _MnemonicMorningReviewBackFace(
                  completedCount: completedCount,
                  dailyTarget: dailyTarget,
                  showCompletionPrompt: showCompletionPrompt,
                  onLongPress: onLongPress,
                  onMarkCompleted: onMarkCompleted,
                ),
              )
            : _MnemonicMorningReviewFrontFace(
                onTap: onFlip,
                onLongPress: onLongPress,
              );

        return Transform(
          alignment: Alignment.center,
          transform: Matrix4.identity()
            ..setEntry(3, 2, 0.001)
            ..rotateY(angle),
          child: face,
        );
      },
    );
  }
}

class _MnemonicMorningReviewFrontFace extends StatelessWidget {
  const _MnemonicMorningReviewFrontFace({
    required this.onTap,
    required this.onLongPress,
  });

  final VoidCallback onTap;
  final VoidCallback onLongPress;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final palette = context.appPalette;
    final titleStyle = theme.textTheme.labelLarge?.copyWith(
      color: palette.heroText,
      fontWeight: FontWeight.w800,
      height: 1.05,
    );
    final symbolStyle = theme.textTheme.displaySmall?.copyWith(
      color: palette.warning,
      fontWeight: FontWeight.w900,
      height: 0.95,
    );

    return Material(
      color: Colors.transparent,
      child: InkWell(
        key: const ValueKey<String>('mnemonic-morning-card-front'),
        borderRadius: BorderRadius.circular(20),
        onTap: onTap,
        onLongPress: onLongPress,
        child: Ink(
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 16),
          decoration: BoxDecoration(
            color: palette.heroGlass.withValues(alpha: 0.14),
            borderRadius: BorderRadius.circular(20),
            border: Border.all(color: palette.heroBorder),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              Icon(
                Icons.bedtime_rounded,
                size: 18,
                color: palette.heroMutedText,
              ),
              const SizedBox(height: 12),
              SizedBox(
                width: double.infinity,
                child: Column(
                  children: <Widget>[
                    FittedBox(
                      fit: BoxFit.scaleDown,
                      child: Text('Energiczna', style: titleStyle),
                    ),
                    const SizedBox(height: 4),
                    FittedBox(
                      fit: BoxFit.scaleDown,
                      child: Text('Pamięć', style: titleStyle),
                    ),
                    const SizedBox(height: 6),
                    _HeroMetricHeadlineBlock(
                      lines: const <String>['∞'],
                      style: symbolStyle,
                    ),
                    const SizedBox(height: 4),
                    Text(
                      '0/3',
                      style: theme.textTheme.bodyMedium?.copyWith(
                        color: palette.heroMutedText,
                        fontWeight: FontWeight.w700,
                        height: 1.1,
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _MnemonicMorningReviewBackFace extends StatelessWidget {
  const _MnemonicMorningReviewBackFace({
    required this.completedCount,
    required this.dailyTarget,
    required this.showCompletionPrompt,
    required this.onLongPress,
    required this.onMarkCompleted,
  });

  final int completedCount;
  final int dailyTarget;
  final bool showCompletionPrompt;
  final VoidCallback onLongPress;
  final VoidCallback onMarkCompleted;

  bool get _isComplete => completedCount >= dailyTarget;

  int get _displayedProgress => _isComplete
      ? dailyTarget
      : showCompletionPrompt
      ? completedCount
      : min(completedCount + 1, dailyTarget);

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final palette = context.appPalette;
    final borderColor = _isComplete || showCompletionPrompt
        ? palette.success.withValues(alpha: 0.46)
        : palette.heroBorder;
    final backgroundColor = _isComplete || showCompletionPrompt
        ? palette.success.withValues(alpha: 0.18)
        : palette.heroGlass.withValues(alpha: 0.14);

    return Material(
      color: Colors.transparent,
      child: InkWell(
        key: const ValueKey<String>('mnemonic-morning-card-back'),
        onLongPress: onLongPress,
        borderRadius: BorderRadius.circular(20),
        child: Ink(
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 16),
          decoration: BoxDecoration(
            color: backgroundColor,
            borderRadius: BorderRadius.circular(20),
            border: Border.all(color: borderColor),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              Row(
                children: <Widget>[
                  Text(
                    '∞',
                    style: theme.textTheme.titleLarge?.copyWith(
                      color: _isComplete || showCompletionPrompt
                          ? palette.success
                          : palette.warning,
                      fontWeight: FontWeight.w900,
                    ),
                  ),
                  const Spacer(),
                  Text(
                    '$_displayedProgress/$dailyTarget',
                    style: theme.textTheme.labelLarge?.copyWith(
                      color: _isComplete || showCompletionPrompt
                          ? palette.success
                          : palette.warning,
                      fontWeight: FontWeight.w800,
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 10),
              Center(
                child: GestureDetector(
                  key: const ValueKey<String>(
                    'mnemonic-morning-complete-button',
                  ),
                  onTap: _isComplete ? null : onMarkCompleted,
                  child: AnimatedContainer(
                    duration: const Duration(milliseconds: 180),
                    width: 46,
                    height: 46,
                    decoration: BoxDecoration(
                      shape: BoxShape.circle,
                      color: _isComplete || showCompletionPrompt
                          ? palette.success
                          : Colors.transparent,
                      border: Border.all(
                        color: _isComplete || showCompletionPrompt
                            ? palette.success
                            : palette.heroMutedText.withValues(alpha: 0.78),
                        width: 2,
                      ),
                    ),
                    child: _isComplete || showCompletionPrompt
                        ? Icon(
                            Icons.check_rounded,
                            color: palette.onSuccess,
                            size: 28,
                          )
                        : null,
                  ),
                ),
              ),
              const SizedBox(height: 8),
              _HeroMetricHeadlineBlock(
                lines: const <String>['∞'],
                primaryKey: ValueKey<String>(
                  _isComplete
                      ? 'mnemonic-morning-card-completed'
                      : showCompletionPrompt
                      ? 'mnemonic-morning-card-in-progress'
                      : 'mnemonic-morning-card-pending',
                ),
                style: theme.textTheme.bodySmall?.copyWith(
                  color: _isComplete || showCompletionPrompt
                      ? palette.success
                      : palette.heroText,
                  fontWeight: FontWeight.w900,
                ),
              ),
              const SizedBox(height: 4),
              SizedBox(
                width: double.infinity,
                child: Text(
                  '$_displayedProgress/$dailyTarget',
                  textAlign: TextAlign.center,
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: _isComplete || showCompletionPrompt
                        ? palette.success
                        : palette.heroMutedText,
                    fontWeight: FontWeight.w700,
                    height: 1.1,
                  ),
                ),
              ),
              if (showCompletionPrompt && !_isComplete) ...<Widget>[
                const SizedBox(height: 6),
                _HeroMetricHeadlineBlock(
                  lines: const <String>['Kontynuować?'],
                  style: theme.textTheme.labelSmall?.copyWith(
                    color: palette.heroMutedText.withValues(alpha: 0.82),
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}

class HeroTrainingMetric extends StatefulWidget {
  const HeroTrainingMetric({super.key, this.onProgressChanged});

  final Future<void> Function()? onProgressChanged;

  @override
  State<HeroTrainingMetric> createState() => _HeroTrainingMetricState();
}

class _HeroTrainingMetricState extends State<HeroTrainingMetric>
    with WidgetsBindingObserver {
  static const String _completedCountPrefsKey =
      'training_daily_completed_count_v1';
  static const String _completedDatePrefsKey =
      'training_daily_completed_date_v1';
  static const int _dailyTarget = 3;

  Timer? _dayRefreshTimer;
  int _completedCount = 0;
  bool _showDetails = false;
  bool _showCompletionPrompt = false;

  String get _todayKey => _dateKeyFor(DateTime.now());

  bool get _isComplete => _completedCount >= _dailyTarget;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _loadProgress();
    _scheduleDayRefresh();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      _handleDayRefresh();
    }
  }

  Future<void> _loadProgress() async {
    final prefs = await SharedPreferences.getInstance();
    final todayKey = _todayKey;
    final storedDateKey = prefs.getString(_completedDatePrefsKey);
    final storedCount = prefs.getInt(_completedCountPrefsKey) ?? 0;
    final completedToday = storedDateKey == todayKey;
    final completedCount = completedToday
        ? min(max(storedCount, 0), _dailyTarget)
        : 0;

    if (storedDateKey != null && !completedToday) {
      await prefs.remove(_completedDatePrefsKey);
      await prefs.remove(_completedCountPrefsKey);
    }

    if (!mounted) {
      return;
    }

    setState(() {
      _completedCount = completedCount;
      _showDetails = completedCount > 0;
      _showCompletionPrompt = false;
    });
  }

  Future<void> _handlePrimaryTap() async {
    if (!_showDetails) {
      setState(() {
        _showDetails = true;
      });
      return;
    }

    if (_isComplete) {
      return;
    }

    if (_showCompletionPrompt) {
      setState(() {
        _showCompletionPrompt = false;
      });
      return;
    }

    final nextCount = min(_completedCount + 1, _dailyTarget);
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_completedDatePrefsKey, _todayKey);
    await prefs.setInt(_completedCountPrefsKey, nextCount);

    if (!mounted) {
      return;
    }

    setState(() {
      _completedCount = nextCount;
      _showDetails = true;
      _showCompletionPrompt = nextCount < _dailyTarget;
    });

    await widget.onProgressChanged?.call();
  }

  Future<void> _confirmResetProgress() async {
    final shouldReset = await showDialog<bool>(
      context: context,
      builder: (BuildContext dialogContext) {
        return AlertDialog(
          title: const Text('Czy zrestartować?'),
          content: const Text('To wyzeruje progres treningu do 0/3.'),
          actions: <Widget>[
            TextButton(
              onPressed: () => Navigator.of(dialogContext).pop(false),
              child: const Text('Nie'),
            ),
            FilledButton(
              onPressed: () => Navigator.of(dialogContext).pop(true),
              child: const Text('Tak'),
            ),
          ],
        );
      },
    );

    if (shouldReset != true) {
      return;
    }

    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(_completedDatePrefsKey);
    await prefs.remove(_completedCountPrefsKey);

    if (!mounted) {
      return;
    }

    setState(() {
      _completedCount = 0;
      _showDetails = false;
      _showCompletionPrompt = false;
    });

    await widget.onProgressChanged?.call();
  }

  void _scheduleDayRefresh() {
    _dayRefreshTimer?.cancel();
    final now = DateTime.now();
    final nextDay = DateTime(now.year, now.month, now.day + 1);
    _dayRefreshTimer = Timer(
      nextDay.difference(now) + const Duration(seconds: 1),
      _handleDayRefresh,
    );
  }

  Future<void> _handleDayRefresh() async {
    await _loadProgress();
    if (!mounted) {
      return;
    }
    _scheduleDayRefresh();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _dayRefreshTimer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final isFlipped = _showDetails || _completedCount > 0;
    return TweenAnimationBuilder<double>(
      key: const ValueKey<String>('training-daily-card'),
      tween: Tween<double>(begin: 0, end: isFlipped ? 1 : 0),
      duration: const Duration(milliseconds: 420),
      curve: Curves.easeInOutCubic,
      builder: (BuildContext context, double value, Widget? child) {
        final angle = value * pi;
        final showBack = value >= 0.5;
        final face = showBack
            ? Transform(
                alignment: Alignment.center,
                transform: Matrix4.identity()..rotateY(pi),
                child: _TrainingMetricBackFace(
                  completedCount: _completedCount,
                  dailyTarget: _dailyTarget,
                  showCompletionPrompt: _showCompletionPrompt,
                  onPrimaryTap: _handlePrimaryTap,
                  onLongPress: _confirmResetProgress,
                ),
              )
            : _TrainingMetricFrontFace(
                onTap: _handlePrimaryTap,
                onLongPress: _confirmResetProgress,
              );

        return Transform(
          alignment: Alignment.center,
          transform: Matrix4.identity()
            ..setEntry(3, 2, 0.001)
            ..rotateY(angle),
          child: face,
        );
      },
    );
  }
}

class _TrainingMetricFrontFace extends StatelessWidget {
  const _TrainingMetricFrontFace({
    required this.onTap,
    required this.onLongPress,
  });

  final VoidCallback onTap;
  final VoidCallback onLongPress;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final palette = context.appPalette;

    return Material(
      color: Colors.transparent,
      child: InkWell(
        key: const ValueKey<String>('training-daily-card-front'),
        borderRadius: BorderRadius.circular(20),
        onTap: onTap,
        onLongPress: onLongPress,
        child: Ink(
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 16),
          decoration: BoxDecoration(
            color: palette.heroGlass.withValues(alpha: 0.14),
            borderRadius: BorderRadius.circular(20),
            border: Border.all(color: palette.heroBorder),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              Icon(
                Icons.fitness_center_rounded,
                size: 20,
                color: palette.heroMutedText,
              ),
              const SizedBox(height: 12),
              SizedBox(
                width: double.infinity,
                child: FittedBox(
                  fit: BoxFit.scaleDown,
                  alignment: Alignment.centerLeft,
                  child: Text(
                    'Trening',
                    style: theme.textTheme.labelLarge?.copyWith(
                      color: palette.heroText,
                      fontWeight: FontWeight.w800,
                    ),
                  ),
                ),
              ),
              const SizedBox(height: 4),
              Text(
                '0/3',
                style: theme.textTheme.bodyMedium?.copyWith(
                  color: palette.heroMutedText,
                  fontWeight: FontWeight.w700,
                  height: 1.2,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _TrainingMetricBackFace extends StatelessWidget {
  const _TrainingMetricBackFace({
    required this.completedCount,
    required this.dailyTarget,
    required this.showCompletionPrompt,
    required this.onPrimaryTap,
    required this.onLongPress,
  });

  final int completedCount;
  final int dailyTarget;
  final bool showCompletionPrompt;
  final VoidCallback onPrimaryTap;
  final VoidCallback onLongPress;

  bool get _isComplete => completedCount >= dailyTarget;

  int get _displayedProgress => _isComplete
      ? dailyTarget
      : showCompletionPrompt
      ? completedCount
      : min(completedCount + 1, dailyTarget);

  String get _headline {
    if (_isComplete) {
      return 'Trening Ukończono';
    }
    return showCompletionPrompt ? 'Ukończono' : '50x Pompek';
  }

  String? get _subheadline {
    if (_isComplete || showCompletionPrompt) {
      return null;
    }
    return '50x Kółko';
  }

  String? get _caption {
    if (_isComplete) {
      return null;
    }
    return showCompletionPrompt ? 'Kontynuować?' : null;
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final palette = context.appPalette;
    final activeColor = _isComplete || showCompletionPrompt
        ? palette.success
        : palette.heroMutedText.withValues(alpha: 0.78);
    final borderColor = _isComplete || showCompletionPrompt
        ? palette.success.withValues(alpha: 0.46)
        : palette.heroBorder;
    final backgroundColor = _isComplete || showCompletionPrompt
        ? palette.success.withValues(alpha: 0.18)
        : palette.heroGlass.withValues(alpha: 0.14);

    return Material(
      color: Colors.transparent,
      child: InkWell(
        key: const ValueKey<String>('training-daily-card-back'),
        onLongPress: onLongPress,
        borderRadius: BorderRadius.circular(20),
        child: Ink(
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 16),
          decoration: BoxDecoration(
            color: backgroundColor,
            borderRadius: BorderRadius.circular(20),
            border: Border.all(color: borderColor),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              Row(
                children: <Widget>[
                  Icon(
                    Icons.fitness_center_rounded,
                    size: 18,
                    color: _isComplete || showCompletionPrompt
                        ? palette.success
                        : palette.heroMutedText,
                  ),
                  const Spacer(),
                  Text(
                    '$_displayedProgress/$dailyTarget',
                    style: theme.textTheme.labelLarge?.copyWith(
                      color: _isComplete || showCompletionPrompt
                          ? palette.success
                          : palette.warning,
                      fontWeight: FontWeight.w800,
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 10),
              Center(
                child: Material(
                  color: Colors.transparent,
                  child: InkWell(
                    key: const ValueKey<String>('training-progress-button'),
                    onTap: _isComplete ? null : onPrimaryTap,
                    borderRadius: BorderRadius.circular(999),
                    child: AnimatedContainer(
                      duration: const Duration(milliseconds: 220),
                      width: 56,
                      height: 56,
                      decoration: BoxDecoration(
                        shape: BoxShape.circle,
                        color: _isComplete || showCompletionPrompt
                            ? palette.success
                            : Colors.transparent,
                        border: Border.all(color: activeColor, width: 2.2),
                      ),
                      child: _isComplete || showCompletionPrompt
                          ? Icon(
                              Icons.check_rounded,
                              color: palette.onSuccess,
                              size: 30,
                            )
                          : null,
                    ),
                  ),
                ),
              ),
              const SizedBox(height: 8),
              _HeroMetricHeadlineBlock(
                lines: <String>[_headline, ?_subheadline],
                primaryKey: ValueKey<String>(
                  _isComplete
                      ? 'training-daily-completed'
                      : showCompletionPrompt
                      ? 'training-daily-in-progress'
                      : 'training-daily-pending',
                ),
                style: theme.textTheme.bodySmall?.copyWith(
                  color: _isComplete || showCompletionPrompt
                      ? palette.success
                      : palette.heroText,
                  fontWeight: _isComplete ? FontWeight.w900 : FontWeight.w700,
                ),
                secondaryStyle: theme.textTheme.bodySmall?.copyWith(
                  color: palette.heroText,
                  fontWeight: FontWeight.w700,
                ),
              ),
              const SizedBox(height: 4),
              SizedBox(
                width: double.infinity,
                child: Text(
                  '$_displayedProgress/$dailyTarget',
                  textAlign: TextAlign.center,
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: _isComplete || showCompletionPrompt
                        ? palette.success
                        : palette.heroMutedText,
                    fontWeight: FontWeight.w700,
                    height: 1.1,
                  ),
                ),
              ),
              if (_caption != null) ...<Widget>[
                const SizedBox(height: 6),
                _HeroMetricHeadlineBlock(
                  lines: <String>[_caption!],
                  style: theme.textTheme.labelSmall?.copyWith(
                    color: palette.heroMutedText.withValues(alpha: 0.82),
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}

class HeroStrawMetric extends StatefulWidget {
  const HeroStrawMetric({super.key, this.onProgressChanged});

  final Future<void> Function()? onProgressChanged;

  @override
  State<HeroStrawMetric> createState() => _HeroStrawMetricState();
}

class _HeroStrawMetricState extends State<HeroStrawMetric>
    with WidgetsBindingObserver {
  static const String _completedCountPrefsKey =
      'straw_daily_completed_count_v1';
  static const String _completedDatePrefsKey = 'straw_daily_completed_date_v1';
  static const int _dailyTarget = 3;

  Timer? _dayRefreshTimer;
  int _completedCount = 0;
  bool _showDetails = false;
  bool _showCompletionPrompt = false;

  String get _todayKey => _dateKeyFor(DateTime.now());

  bool get _isComplete => _completedCount >= _dailyTarget;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _loadProgress();
    _scheduleDayRefresh();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      _handleDayRefresh();
    }
  }

  Future<void> _loadProgress() async {
    final prefs = await SharedPreferences.getInstance();
    final todayKey = _todayKey;
    final storedDateKey = prefs.getString(_completedDatePrefsKey);
    final storedCount = prefs.getInt(_completedCountPrefsKey) ?? 0;
    final completedToday = storedDateKey == todayKey;
    final completedCount = completedToday
        ? min(max(storedCount, 0), _dailyTarget)
        : 0;

    if (storedDateKey != null && !completedToday) {
      await prefs.remove(_completedDatePrefsKey);
      await prefs.remove(_completedCountPrefsKey);
    }

    if (!mounted) {
      return;
    }

    setState(() {
      _completedCount = completedCount;
      _showDetails = completedCount > 0;
      _showCompletionPrompt = false;
    });
  }

  Future<void> _handlePrimaryTap() async {
    if (!_showDetails) {
      setState(() {
        _showDetails = true;
      });
      return;
    }

    if (_isComplete) {
      return;
    }

    if (_showCompletionPrompt) {
      setState(() {
        _showCompletionPrompt = false;
      });
      return;
    }

    final nextCount = min(_completedCount + 1, _dailyTarget);
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_completedDatePrefsKey, _todayKey);
    await prefs.setInt(_completedCountPrefsKey, nextCount);

    if (!mounted) {
      return;
    }

    setState(() {
      _completedCount = nextCount;
      _showDetails = true;
      _showCompletionPrompt = nextCount < _dailyTarget;
    });

    await widget.onProgressChanged?.call();
  }

  Future<void> _confirmResetProgress() async {
    final shouldReset = await showDialog<bool>(
      context: context,
      builder: (BuildContext dialogContext) {
        return AlertDialog(
          title: const Text('Czy zrestartować?'),
          content: const Text('To wyzeruje progres wibracji do 0/3.'),
          actions: <Widget>[
            TextButton(
              onPressed: () => Navigator.of(dialogContext).pop(false),
              child: const Text('Nie'),
            ),
            FilledButton(
              onPressed: () => Navigator.of(dialogContext).pop(true),
              child: const Text('Tak'),
            ),
          ],
        );
      },
    );

    if (shouldReset != true) {
      return;
    }

    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(_completedDatePrefsKey);
    await prefs.remove(_completedCountPrefsKey);

    if (!mounted) {
      return;
    }

    setState(() {
      _completedCount = 0;
      _showDetails = false;
      _showCompletionPrompt = false;
    });

    await widget.onProgressChanged?.call();
  }

  void _scheduleDayRefresh() {
    _dayRefreshTimer?.cancel();
    final now = DateTime.now();
    final nextDay = DateTime(now.year, now.month, now.day + 1);
    _dayRefreshTimer = Timer(
      nextDay.difference(now) + const Duration(seconds: 1),
      _handleDayRefresh,
    );
  }

  Future<void> _handleDayRefresh() async {
    await _loadProgress();
    if (!mounted) {
      return;
    }
    _scheduleDayRefresh();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _dayRefreshTimer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final isFlipped = _showDetails || _completedCount > 0;
    return TweenAnimationBuilder<double>(
      key: const ValueKey<String>('straw-daily-card'),
      tween: Tween<double>(begin: 0, end: isFlipped ? 1 : 0),
      duration: const Duration(milliseconds: 420),
      curve: Curves.easeInOutCubic,
      builder: (BuildContext context, double value, Widget? child) {
        final angle = value * pi;
        final showBack = value >= 0.5;
        final face = showBack
            ? Transform(
                alignment: Alignment.center,
                transform: Matrix4.identity()..rotateY(pi),
                child: _StrawMetricBackFace(
                  completedCount: _completedCount,
                  dailyTarget: _dailyTarget,
                  showCompletionPrompt: _showCompletionPrompt,
                  onPrimaryTap: _handlePrimaryTap,
                  onLongPress: _confirmResetProgress,
                ),
              )
            : _StrawMetricFrontFace(
                onTap: _handlePrimaryTap,
                onLongPress: _confirmResetProgress,
              );

        return Transform(
          alignment: Alignment.center,
          transform: Matrix4.identity()
            ..setEntry(3, 2, 0.001)
            ..rotateY(angle),
          child: face,
        );
      },
    );
  }
}

class _StrawMetricFrontFace extends StatelessWidget {
  const _StrawMetricFrontFace({required this.onTap, required this.onLongPress});

  final VoidCallback onTap;
  final VoidCallback onLongPress;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final palette = context.appPalette;

    return Material(
      color: Colors.transparent,
      child: InkWell(
        key: const ValueKey<String>('straw-daily-card-front'),
        borderRadius: BorderRadius.circular(20),
        onTap: onTap,
        onLongPress: onLongPress,
        child: Ink(
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 16),
          decoration: BoxDecoration(
            color: palette.heroGlass.withValues(alpha: 0.14),
            borderRadius: BorderRadius.circular(20),
            border: Border.all(color: palette.heroBorder),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              Icon(
                Icons.vibration_rounded,
                size: 20,
                color: palette.heroMutedText,
              ),
              const SizedBox(height: 12),
              SizedBox(
                width: double.infinity,
                child: FittedBox(
                  fit: BoxFit.scaleDown,
                  alignment: Alignment.centerLeft,
                  child: Text(
                    'Wibracja',
                    style: theme.textTheme.labelLarge?.copyWith(
                      color: palette.heroText,
                      fontWeight: FontWeight.w800,
                    ),
                  ),
                ),
              ),
              const SizedBox(height: 4),
              Text(
                '0/3',
                style: theme.textTheme.bodyMedium?.copyWith(
                  color: palette.heroMutedText,
                  fontWeight: FontWeight.w700,
                  height: 1.2,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _StrawMetricBackFace extends StatelessWidget {
  const _StrawMetricBackFace({
    required this.completedCount,
    required this.dailyTarget,
    required this.showCompletionPrompt,
    required this.onPrimaryTap,
    required this.onLongPress,
  });

  final int completedCount;
  final int dailyTarget;
  final bool showCompletionPrompt;
  final VoidCallback onPrimaryTap;
  final VoidCallback onLongPress;

  bool get _isComplete => completedCount >= dailyTarget;

  int get _displayedProgress => _isComplete
      ? dailyTarget
      : showCompletionPrompt
      ? completedCount
      : min(completedCount + 1, dailyTarget);

  String get _headline {
    if (_isComplete) {
      return 'Wibracja';
    }
    return showCompletionPrompt ? 'Ukończono' : '15min';
  }

  String? get _caption {
    if (_isComplete) {
      return null;
    }
    return showCompletionPrompt ? 'Kontynuować?' : null;
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final palette = context.appPalette;
    final borderColor = _isComplete
        ? palette.success.withValues(alpha: 0.46)
        : palette.heroBorder;
    final backgroundColor = _isComplete
        ? palette.success.withValues(alpha: 0.18)
        : palette.heroGlass.withValues(alpha: 0.14);

    return Material(
      color: Colors.transparent,
      child: InkWell(
        key: const ValueKey<String>('straw-daily-card-back'),
        onLongPress: onLongPress,
        borderRadius: BorderRadius.circular(20),
        child: Ink(
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 16),
          decoration: BoxDecoration(
            color: backgroundColor,
            borderRadius: BorderRadius.circular(20),
            border: Border.all(color: borderColor),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              Row(
                children: <Widget>[
                  Icon(
                    Icons.vibration_rounded,
                    size: 18,
                    color: _isComplete || showCompletionPrompt
                        ? palette.success
                        : palette.heroMutedText,
                  ),
                  const Spacer(),
                  Text(
                    '$_displayedProgress/$dailyTarget',
                    style: theme.textTheme.labelLarge?.copyWith(
                      color: _isComplete || showCompletionPrompt
                          ? palette.success
                          : palette.warning,
                      fontWeight: FontWeight.w800,
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 10),
              Center(
                child: Material(
                  color: Colors.transparent,
                  child: InkWell(
                    key: const ValueKey<String>('straw-progress-button'),
                    onTap: _isComplete ? null : onPrimaryTap,
                    borderRadius: BorderRadius.circular(999),
                    child: AnimatedContainer(
                      duration: const Duration(milliseconds: 220),
                      width: 56,
                      height: 56,
                      decoration: BoxDecoration(
                        shape: BoxShape.circle,
                        color: _isComplete || showCompletionPrompt
                            ? palette.success
                            : Colors.transparent,
                        border: Border.all(
                          color: _isComplete || showCompletionPrompt
                              ? palette.success
                              : palette.heroMutedText.withValues(alpha: 0.78),
                          width: 2.2,
                        ),
                      ),
                      child: _isComplete || showCompletionPrompt
                          ? Icon(
                              Icons.check_rounded,
                              color: palette.onSuccess,
                              size: 30,
                            )
                          : null,
                    ),
                  ),
                ),
              ),
              const SizedBox(height: 8),
              _HeroMetricHeadlineBlock(
                lines: <String>[_headline],
                primaryKey: ValueKey<String>(
                  _isComplete
                      ? 'straw-daily-completed'
                      : showCompletionPrompt
                      ? 'straw-daily-in-progress'
                      : 'straw-daily-pending',
                ),
                style: theme.textTheme.bodySmall?.copyWith(
                  color: _isComplete || showCompletionPrompt
                      ? palette.success
                      : palette.heroText,
                  fontWeight: _isComplete ? FontWeight.w900 : FontWeight.w700,
                ),
              ),
              const SizedBox(height: 4),
              SizedBox(
                width: double.infinity,
                child: Text(
                  '$_displayedProgress/$dailyTarget',
                  textAlign: TextAlign.center,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: _isComplete || showCompletionPrompt
                        ? palette.success
                        : palette.heroMutedText,
                    fontWeight: FontWeight.w700,
                    height: 1.1,
                  ),
                ),
              ),
              if (_caption != null) ...<Widget>[
                const SizedBox(height: 6),
                _HeroMetricHeadlineBlock(
                  lines: <String>[_caption!],
                  style: theme.textTheme.labelSmall?.copyWith(
                    color: palette.heroMutedText.withValues(alpha: 0.82),
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}

class _HeroMetricHeadlineBlock extends StatelessWidget {
  const _HeroMetricHeadlineBlock({
    required this.lines,
    required this.style,
    this.primaryKey,
    this.secondaryStyle,
  });

  final List<String> lines;
  final TextStyle? style;
  final Key? primaryKey;
  final TextStyle? secondaryStyle;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: double.infinity,
      child: FittedBox(
        fit: BoxFit.scaleDown,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: List<Widget>.generate(lines.length, (int index) {
            return Padding(
              padding: EdgeInsets.only(
                bottom: index == lines.length - 1 ? 0 : 4,
              ),
              child: Text(
                lines[index],
                key: index == 0 ? primaryKey : null,
                maxLines: 1,
                softWrap: false,
                textAlign: TextAlign.center,
                style: index == 0 ? style : (secondaryStyle ?? style),
              ),
            );
          }),
        ),
      ),
    );
  }
}

class _FlowCalendarDayTile extends StatelessWidget {
  const _FlowCalendarDayTile({
    super.key,
    required this.dayNumber,
    required this.count,
    required this.selected,
    required this.today,
    required this.onTap,
  });

  final int dayNumber;
  final int count;
  final bool selected;
  final bool today;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final palette = context.appPalette;
    final borderColor = selected
        ? palette.primaryButton
        : today
        ? palette.outlinedButtonBorder
        : palette.surfaceBorder;

    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(16),
        child: Ink(
          decoration: BoxDecoration(
            color: selected ? palette.surfaceMuted : palette.surfaceStrong,
            borderRadius: BorderRadius.circular(16),
            border: Border.all(color: borderColor, width: selected ? 1.5 : 1),
          ),
          child: Padding(
            padding: const EdgeInsets.all(6),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                SizedBox(
                  width: double.infinity,
                  child: FittedBox(
                    alignment: Alignment.centerLeft,
                    fit: BoxFit.scaleDown,
                    child: Text(
                      '$dayNumber',
                      maxLines: 1,
                      softWrap: false,
                      style: theme.textTheme.bodyMedium?.copyWith(
                        color: palette.primaryText,
                        fontWeight: FontWeight.w800,
                      ),
                    ),
                  ),
                ),
                const Spacer(),
                if (count > 0)
                  Align(
                    alignment: Alignment.bottomRight,
                    child: Container(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 7,
                        vertical: 4,
                      ),
                      decoration: BoxDecoration(
                        color: palette.success,
                        borderRadius: BorderRadius.circular(999),
                      ),
                      child: SizedBox(
                        width: 18,
                        child: FittedBox(
                          fit: BoxFit.scaleDown,
                          child: Text(
                            '$count',
                            maxLines: 1,
                            softWrap: false,
                            style: theme.textTheme.labelSmall?.copyWith(
                              color: palette.onSuccess,
                              fontWeight: FontWeight.w800,
                            ),
                          ),
                        ),
                      ),
                    ),
                  ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _FlowSavedProgressTile extends StatelessWidget {
  const _FlowSavedProgressTile({
    super.key,
    required this.label,
    required this.subtitle,
    required this.onLongPress,
  });

  final String label;
  final String subtitle;
  final VoidCallback onLongPress;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final palette = context.appPalette;
    return Material(
      color: Colors.transparent,
      child: InkWell(
        onLongPress: onLongPress,
        borderRadius: BorderRadius.circular(20),
        child: Ink(
          padding: const EdgeInsets.all(16),
          decoration: BoxDecoration(
            color: palette.surfaceMuted,
            borderRadius: BorderRadius.circular(20),
            border: Border.all(color: palette.surfaceBorder),
          ),
          child: Row(
            children: <Widget>[
              Container(
                width: 42,
                height: 42,
                decoration: BoxDecoration(
                  color: palette.success.withValues(alpha: 0.12),
                  borderRadius: BorderRadius.circular(14),
                ),
                child: Icon(Icons.check_rounded, color: palette.success),
              ),
              const SizedBox(width: 14),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: <Widget>[
                    Text(
                      label,
                      style: theme.textTheme.titleMedium?.copyWith(
                        color: palette.primaryText,
                        fontWeight: FontWeight.w800,
                      ),
                    ),
                    const SizedBox(height: 4),
                    Text(
                      subtitle,
                      style: theme.textTheme.bodyMedium?.copyWith(
                        color: palette.secondaryText,
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class SectionHeader extends StatelessWidget {
  const SectionHeader({
    super.key,
    required this.eyebrow,
    required this.title,
    this.centered = false,
  });

  final String eyebrow;
  final String title;
  final bool centered;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final palette = context.appPalette;
    return Column(
      crossAxisAlignment: centered
          ? CrossAxisAlignment.center
          : CrossAxisAlignment.start,
      children: <Widget>[
        Text(
          eyebrow.toUpperCase(),
          textAlign: centered ? TextAlign.center : TextAlign.start,
          style: theme.textTheme.labelLarge?.copyWith(
            color: palette.tertiaryText,
            fontWeight: FontWeight.w800,
            letterSpacing: 1.1,
          ),
        ),
        const SizedBox(height: 6),
        Text(
          title,
          textAlign: centered ? TextAlign.center : TextAlign.start,
          style: theme.textTheme.titleLarge?.copyWith(
            color: palette.primaryText,
          ),
        ),
      ],
    );
  }
}

class DailyRoutineStep extends StatelessWidget {
  const DailyRoutineStep({
    super.key,
    required this.title,
    required this.details,
  });

  final String title;
  final String details;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final palette = context.appPalette;
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        Container(
          width: 12,
          height: 12,
          margin: const EdgeInsets.only(top: 5),
          decoration: BoxDecoration(
            color: palette.primaryButton,
            shape: BoxShape.circle,
          ),
        ),
        const SizedBox(width: 14),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              Text(
                title,
                style: theme.textTheme.titleMedium?.copyWith(
                  color: palette.primaryText,
                  fontWeight: FontWeight.w800,
                ),
              ),
              const SizedBox(height: 4),
              Text(
                details,
                style: theme.textTheme.bodyMedium?.copyWith(
                  color: palette.secondaryText,
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }
}

class TagChip extends StatelessWidget {
  const TagChip({super.key, required this.label, required this.tint});

  final String label;
  final Color tint;

  @override
  Widget build(BuildContext context) {
    final palette = context.appPalette;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      decoration: BoxDecoration(
        color: Color.lerp(tint, palette.surfaceStrong, 0.78)!,
        borderRadius: BorderRadius.circular(999),
      ),
      child: Text(
        label,
        style: TextStyle(
          color: Color.lerp(tint, palette.primaryText, 0.18),
          fontWeight: FontWeight.w800,
        ),
      ),
    );
  }
}

class DetailMetric extends StatelessWidget {
  const DetailMetric({
    super.key,
    required this.label,
    required this.value,
    this.fullWidth = false,
  });

  final String label;
  final String value;
  final bool fullWidth;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final palette = context.appPalette;
    return Container(
      width: fullWidth ? double.infinity : null,
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
      decoration: BoxDecoration(
        color: palette.heroGlass.withValues(alpha: 0.14),
        borderRadius: BorderRadius.circular(18),
        border: Border.all(color: palette.heroBorder),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Text(
            label.toUpperCase(),
            style: theme.textTheme.labelLarge?.copyWith(
              color: palette.heroMutedText,
              fontWeight: FontWeight.w800,
              letterSpacing: 1.0,
            ),
          ),
          const SizedBox(height: 6),
          Text(
            value,
            style: theme.textTheme.bodyLarge?.copyWith(
              color: palette.heroText,
              fontWeight: FontWeight.w700,
            ),
          ),
        ],
      ),
    );
  }
}

class InstructionStep extends StatelessWidget {
  const InstructionStep({
    super.key,
    required this.number,
    required this.text,
    required this.tint,
    this.centered = false,
  });

  final int number;
  final String text;
  final Color tint;
  final bool centered;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final palette = context.appPalette;
    if (centered) {
      return Column(
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          Container(
            width: 34,
            height: 34,
            decoration: BoxDecoration(
              color: tint.withValues(alpha: 0.16),
              borderRadius: BorderRadius.circular(12),
            ),
            alignment: Alignment.center,
            child: Text(
              '$number',
              style: TextStyle(color: tint, fontWeight: FontWeight.w800),
            ),
          ),
          const SizedBox(height: 12),
          Text(
            text,
            textAlign: TextAlign.center,
            style: theme.textTheme.bodyLarge?.copyWith(
              color: palette.primaryText,
            ),
          ),
        ],
      );
    }

    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        Container(
          width: 34,
          height: 34,
          decoration: BoxDecoration(
            color: tint.withValues(alpha: 0.16),
            borderRadius: BorderRadius.circular(12),
          ),
          alignment: Alignment.center,
          child: Text(
            '$number',
            style: TextStyle(color: tint, fontWeight: FontWeight.w800),
          ),
        ),
        const SizedBox(width: 14),
        Expanded(
          child: Text(
            text,
            style: theme.textTheme.bodyLarge?.copyWith(
              color: palette.primaryText,
            ),
          ),
        ),
      ],
    );
  }
}

enum PulseSyncLevel { easy, medium, hard }

class _PulseSyncLevelDefinition {
  const _PulseSyncLevelDefinition({
    required this.level,
    required this.label,
    required this.patternMs,
  });

  final PulseSyncLevel level;
  final String label;
  final List<int> patternMs;
}

const List<_PulseSyncLevelDefinition> _pulseSyncLevels =
    <_PulseSyncLevelDefinition>[
      _PulseSyncLevelDefinition(
        level: PulseSyncLevel.easy,
        label: 'Łatwy',
        patternMs: <int>[980, 920, 860, 800, 760],
      ),
      _PulseSyncLevelDefinition(
        level: PulseSyncLevel.medium,
        label: 'Średni',
        patternMs: <int>[860, 800, 740, 680, 620],
      ),
      _PulseSyncLevelDefinition(
        level: PulseSyncLevel.hard,
        label: 'Hard',
        patternMs: <int>[740, 680, 620, 560, 500],
      ),
    ];

class _PulseSyncLevelSelectorCard extends StatefulWidget {
  const _PulseSyncLevelSelectorCard({
    required this.accent,
    required this.selectedLevel,
    required this.onLevelChanged,
  });

  final Color accent;
  final PulseSyncLevel selectedLevel;
  final ValueChanged<PulseSyncLevel> onLevelChanged;

  @override
  State<_PulseSyncLevelSelectorCard> createState() =>
      _PulseSyncLevelSelectorCardState();
}

class _PulseSyncLevelSelectorCardState
    extends State<_PulseSyncLevelSelectorCard> {
  late final PageController _pageController;

  @override
  void initState() {
    super.initState();
    _pageController = PageController(initialPage: widget.selectedLevel.index);
  }

  @override
  void didUpdateWidget(covariant _PulseSyncLevelSelectorCard oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.selectedLevel == oldWidget.selectedLevel ||
        !_pageController.hasClients) {
      return;
    }

    _pageController.animateToPage(
      widget.selectedLevel.index,
      duration: const Duration(milliseconds: 220),
      curve: Curves.easeOutCubic,
    );
  }

  @override
  void dispose() {
    _pageController.dispose();
    super.dispose();
  }

  void _handleLevelTap(PulseSyncLevel level) {
    if (widget.selectedLevel == level) {
      return;
    }

    widget.onLevelChanged(level);
  }

  void _handlePageChanged(int index) {
    final nextLevel = _pulseSyncLevels[index].level;
    if (nextLevel == widget.selectedLevel) {
      return;
    }

    widget.onLevelChanged(nextLevel);
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final palette = context.appPalette;
    final selectedIndex = widget.selectedLevel.index;

    return SurfaceCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          const SectionHeader(eyebrow: 'Poziomy', title: 'Poziomy gry'),
          const SizedBox(height: 18),
          Container(
            width: double.infinity,
            height: 170,
            padding: const EdgeInsets.fromLTRB(18, 16, 18, 14),
            decoration: BoxDecoration(
              gradient: LinearGradient(
                begin: Alignment.topLeft,
                end: Alignment.bottomRight,
                colors: <Color>[
                  widget.accent.withValues(alpha: 0.16),
                  palette.surfaceStrong,
                ],
              ),
              borderRadius: BorderRadius.circular(26),
              border: Border.all(color: widget.accent.withValues(alpha: 0.18)),
            ),
            child: Column(
              children: <Widget>[
                Expanded(
                  child: PageView.builder(
                    controller: _pageController,
                    itemCount: _pulseSyncLevels.length,
                    physics: const BouncingScrollPhysics(),
                    onPageChanged: _handlePageChanged,
                    itemBuilder: (BuildContext context, int index) {
                      final level = _pulseSyncLevels[index];
                      final isSelected = index == selectedIndex;

                      return GestureDetector(
                        onTap: () => _handleLevelTap(level.level),
                        child: Container(
                          key: ValueKey<String>(
                            'pulse-sync-level-card-${level.level.name}',
                          ),
                          width: double.infinity,
                          padding: const EdgeInsets.all(18),
                          decoration: BoxDecoration(
                            color: palette.surface.withValues(alpha: 0.92),
                            borderRadius: BorderRadius.circular(22),
                            border: Border.all(
                              color: isSelected
                                  ? widget.accent.withValues(alpha: 0.42)
                                  : widget.accent.withValues(alpha: 0.24),
                            ),
                          ),
                          child: Center(
                            child: Text(
                              level.label,
                              textAlign: TextAlign.center,
                              style: theme.textTheme.titleLarge?.copyWith(
                                color: palette.primaryText,
                                fontWeight: FontWeight.w900,
                              ),
                            ),
                          ),
                        ),
                      );
                    },
                  ),
                ),
                const SizedBox(height: 12),
                Row(
                  mainAxisSize: MainAxisSize.min,
                  children: List<Widget>.generate(_pulseSyncLevels.length, (
                    int index,
                  ) {
                    final bool selected = index == selectedIndex;
                    return AnimatedContainer(
                      duration: const Duration(milliseconds: 180),
                      margin: EdgeInsets.only(left: index == 0 ? 0 : 6),
                      width: selected ? 18 : 8,
                      height: 8,
                      decoration: BoxDecoration(
                        color: selected
                            ? widget.accent
                            : widget.accent.withValues(alpha: 0.24),
                        borderRadius: BorderRadius.circular(999),
                      ),
                    );
                  }),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class PulseSyncTrainer extends StatefulWidget {
  const PulseSyncTrainer({
    super.key,
    required this.accent,
    this.autoStart = false,
    this.fullscreenOnStart = false,
    this.autoExitOnFinish = false,
    this.initialLevel = PulseSyncLevel.easy,
    this.showLevelSelector = true,
    this.onSessionStarted,
  });

  final Color accent;
  final bool autoStart;
  final bool fullscreenOnStart;
  final bool autoExitOnFinish;
  final PulseSyncLevel initialLevel;
  final bool showLevelSelector;
  final VoidCallback? onSessionStarted;

  @override
  State<PulseSyncTrainer> createState() => _PulseSyncTrainerState();
}

class _PulseSyncTrainerState extends State<PulseSyncTrainer> {
  static const int _sessionStartCountdownSeconds = 3;
  static const int _sessionSeconds = 60;

  Timer? _startCountdownTimer;
  Timer? _sessionTimer;
  Timer? _beatTimer;
  Timer? _pulseReleaseTimer;
  Timer? _finishExitTimer;
  late PulseSyncLevel _selectedLevel;
  bool _running = false;
  bool _finished = false;
  bool _pulseExpanded = false;
  int? _countdownValue;
  int _remainingSeconds = _sessionSeconds;
  int _beatCount = 0;
  int _points = 0;
  String _status = 'Wybierz poziom i uruchom minutę rytmu.';
  DateTime? _lastBeatAt;
  DateTime? _nextBeatAt;

  @override
  void initState() {
    super.initState();
    _selectedLevel = widget.initialLevel;
    if (widget.autoStart) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) {
          _startWithCountdown();
        }
      });
    }
  }

  @override
  void didUpdateWidget(covariant PulseSyncTrainer oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.initialLevel == oldWidget.initialLevel ||
        _running ||
        _isCountingDown) {
      return;
    }

    setState(() {
      _selectedLevel = widget.initialLevel;
      _finished = false;
      _remainingSeconds = _sessionSeconds;
      _status = 'Poziom ${_currentLevel.label}. Kliknij start i złap rytm.';
    });
  }

  _PulseSyncLevelDefinition get _currentLevel => _pulseSyncLevels.firstWhere(
    (_PulseSyncLevelDefinition level) => level.level == _selectedLevel,
  );

  bool get _isCountingDown => _countdownValue != null;

  bool get _showFinishOnly => _finished && widget.autoExitOnFinish;

  String get _countdownLabel {
    final value = _countdownValue;
    if (value == null) {
      return '';
    }
    return value == 0 ? 'START' : '$value';
  }

  int get _stageIndex =>
      min(_currentLevel.patternMs.length - 1, _beatCount ~/ 10);

  int get _currentIntervalMs => _currentLevel.patternMs[_stageIndex];

  int get _currentBpm => (60000 / _currentIntervalMs).round();

  void _selectLevel(PulseSyncLevel level) {
    if (_running || _isCountingDown || level == _selectedLevel) {
      return;
    }

    final definition = _pulseSyncLevels.firstWhere(
      (_PulseSyncLevelDefinition item) => item.level == level,
    );

    setState(() {
      _selectedLevel = level;
      _finished = false;
      _remainingSeconds = _sessionSeconds;
      _status = 'Poziom ${definition.label}. Kliknij start i złap rytm.';
    });

    HapticFeedback.selectionClick();
  }

  void _startWithCountdown() {
    if (_running || _isCountingDown) {
      return;
    }

    widget.onSessionStarted?.call();
    _cancelTimers();
    setState(() {
      _running = false;
      _finished = false;
      _pulseExpanded = false;
      _countdownValue = _sessionStartCountdownSeconds;
      _remainingSeconds = _sessionSeconds;
      _beatCount = 0;
      _points = 0;
      _status = 'Start za 3 sekundy. Przygotuj rytm dłoni.';
      _lastBeatAt = null;
      _nextBeatAt = null;
    });

    HapticFeedback.selectionClick();

    _startCountdownTimer = Timer.periodic(const Duration(seconds: 1), (
      Timer timer,
    ) {
      if (!mounted) {
        timer.cancel();
        return;
      }

      final currentCountdown = _countdownValue;
      if (currentCountdown == null) {
        timer.cancel();
        return;
      }

      if (currentCountdown <= 0) {
        timer.cancel();
        _startSession();
        return;
      }

      setState(() {
        _countdownValue = currentCountdown - 1;
      });

      if (_countdownValue == 0) {
        HapticFeedback.mediumImpact();
      } else {
        HapticFeedback.selectionClick();
      }
    });
  }

  void _startSession() {
    _cancelTimers();
    setState(() {
      _running = true;
      _finished = false;
      _pulseExpanded = false;
      _countdownValue = null;
      _remainingSeconds = _sessionSeconds;
      _beatCount = 0;
      _points = 0;
      _status = 'Stukaj wtedy, gdy koło wybija puls i daje haptykę.';
      _lastBeatAt = null;
      _nextBeatAt = null;
    });

    _sessionTimer = Timer.periodic(const Duration(seconds: 1), (Timer timer) {
      if (!mounted) {
        return;
      }

      if (_remainingSeconds <= 1) {
        timer.cancel();
        _finishSession();
      } else {
        setState(() {
          _remainingSeconds -= 1;
        });
      }
    });

    _emitBeat();
  }

  void _finishSession() {
    _cancelTimers();
    setState(() {
      _running = false;
      _finished = true;
      _pulseExpanded = false;
      _countdownValue = null;
      _remainingSeconds = 0;
      _status = 'Koniec';
    });

    if (!widget.autoExitOnFinish) {
      return;
    }

    _finishExitTimer = Timer(const Duration(seconds: 2), () {
      if (!mounted) {
        return;
      }
      Navigator.of(context).maybePop();
    });
  }

  void _pause() {
    _cancelTimers();
    setState(() {
      _running = false;
      _pulseExpanded = false;
      _countdownValue = null;
      _status = 'Pauza. Wróć, gdy chcesz ponownie wejść w rytm.';
    });
  }

  void _cancelTimers() {
    _startCountdownTimer?.cancel();
    _sessionTimer?.cancel();
    _beatTimer?.cancel();
    _pulseReleaseTimer?.cancel();
    _finishExitTimer?.cancel();
  }

  void _emitBeat() {
    if (!_running) {
      return;
    }

    final interval = Duration(milliseconds: _currentIntervalMs);
    final now = DateTime.now();

    setState(() {
      _beatCount += 1;
      _pulseExpanded = true;
      _lastBeatAt = now;
      _nextBeatAt = now.add(interval);
    });

    HapticFeedback.selectionClick();

    _pulseReleaseTimer?.cancel();
    _pulseReleaseTimer = Timer(const Duration(milliseconds: 220), () {
      if (!mounted) {
        return;
      }
      setState(() {
        _pulseExpanded = false;
      });
    });

    _beatTimer = Timer(interval, _emitBeat);
  }

  Future<void> _openFullscreenSession() {
    return Navigator.of(context).push<void>(
      _buildExerciseSessionRoute<void>(
        builder: (BuildContext context) {
          return FullscreenTrainerPage(
            title: 'Pulse Sync',
            accent: widget.accent,
            child: PulseSyncTrainer(
              accent: widget.accent,
              autoStart: true,
              autoExitOnFinish: true,
              initialLevel: _selectedLevel,
              showLevelSelector: widget.showLevelSelector,
            ),
          );
        },
      ),
    );
  }

  Future<void> _handlePrimaryAction() async {
    if (widget.fullscreenOnStart && !_running && !_isCountingDown) {
      widget.onSessionStarted?.call();
      await _openFullscreenSession();
      return;
    }

    if (_running) {
      _pause();
    } else {
      _startWithCountdown();
    }
  }

  void _handleTap() {
    if (!_running || _lastBeatAt == null || _nextBeatAt == null) {
      return;
    }

    final now = DateTime.now();
    final deltaLast = now.difference(_lastBeatAt!).inMilliseconds.abs();
    final deltaNext = _nextBeatAt!.difference(now).inMilliseconds.abs();
    final delta = min(deltaLast, deltaNext);

    var message = 'Poza pulsem. Złap koło i pozwól rytmowi wejść głębiej.';

    if (delta <= 90) {
      setState(() {
        _points += 1;
        _status = 'Idealnie. Punkt zapisany. Błąd: $delta ms.';
      });
      HapticFeedback.mediumImpact();
      return;
    }

    if (delta <= 160) {
      setState(() {
        _points += 1;
        _status = 'Dobry tap. Punkt zapisany. Błąd: $delta ms.';
      });
      HapticFeedback.selectionClick();
      return;
    }

    setState(() {
      _status = '$message Błąd: $delta ms.';
    });
    HapticFeedback.lightImpact();
  }

  Widget _buildLevelSelector() {
    return Wrap(
      alignment: WrapAlignment.center,
      spacing: 10,
      runSpacing: 10,
      children: _pulseSyncLevels.map((_PulseSyncLevelDefinition level) {
        final selected = level.level == _selectedLevel;
        return ChoiceChip(
          label: Text(level.label),
          selected: selected,
          onSelected: (_) => _selectLevel(level.level),
          selectedColor: widget.accent.withValues(alpha: 0.18),
          labelStyle: TextStyle(
            color: selected ? widget.accent : context.appPalette.primaryText,
            fontWeight: FontWeight.w800,
          ),
          side: BorderSide(
            color: selected ? widget.accent : context.appPalette.surfaceBorder,
          ),
        );
      }).toList(),
    );
  }

  Widget _buildSessionBody(ThemeData theme) {
    final palette = context.appPalette;
    if (_finished) {
      return Container(
        key: const ValueKey<String>('pulse-sync-finished'),
        padding: const EdgeInsets.symmetric(horizontal: 34, vertical: 22),
        decoration: BoxDecoration(
          color: widget.accent.withValues(alpha: 0.12),
          borderRadius: BorderRadius.circular(26),
        ),
        child: Text(
          'Koniec',
          style: theme.textTheme.headlineMedium?.copyWith(
            color: palette.primaryText,
            fontWeight: FontWeight.w900,
            letterSpacing: 1.0,
          ),
        ),
      );
    }

    if (_isCountingDown) {
      final showCountdownHeading = _countdownLabel != 'START';

      return Column(
        key: ValueKey<String>('pulse-sync-countdown-$_countdownLabel'),
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          if (showCountdownHeading) ...<Widget>[
            Text(
              'START ZA',
              style: theme.textTheme.titleLarge?.copyWith(
                color: palette.secondaryText,
                fontWeight: FontWeight.w800,
                letterSpacing: 1.3,
              ),
            ),
            const SizedBox(height: 14),
          ],
          Text(
            _countdownLabel,
            style: theme.textTheme.displaySmall?.copyWith(
              color: widget.accent,
              fontWeight: FontWeight.w900,
              letterSpacing: _countdownLabel == 'START' ? 1.4 : 0.0,
            ),
          ),
        ],
      );
    }

    return Column(
      key: ValueKey<String>(
        _running ? 'pulse-sync-running' : 'pulse-sync-idle',
      ),
      children: <Widget>[
        AnimatedScale(
          duration: const Duration(milliseconds: 140),
          scale: _pulseExpanded ? 1.08 : 0.9,
          child: AnimatedContainer(
            duration: const Duration(milliseconds: 140),
            width: 180,
            height: 180,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              gradient: LinearGradient(
                colors: <Color>[
                  widget.accent.withValues(alpha: 0.24),
                  widget.accent.withValues(alpha: 0.78),
                ],
                begin: Alignment.topLeft,
                end: Alignment.bottomRight,
              ),
              boxShadow: <BoxShadow>[
                BoxShadow(
                  color: widget.accent.withValues(alpha: 0.26),
                  blurRadius: _pulseExpanded ? 34 : 18,
                  offset: const Offset(0, 12),
                ),
              ],
            ),
            alignment: Alignment.center,
            child: Text(
              _running ? 'TAP' : 'FLOW',
              style: theme.textTheme.headlineMedium?.copyWith(
                color: Colors.white,
                fontWeight: FontWeight.w900,
                letterSpacing: 1.0,
              ),
            ),
          ),
        ),
        const SizedBox(height: 14),
        Text(
          _status,
          textAlign: TextAlign.center,
          style: theme.textTheme.bodyLarge?.copyWith(
            color: palette.primaryText,
            fontWeight: FontWeight.w700,
          ),
        ),
        const SizedBox(height: 8),
        Text(
          _running
              ? 'Wibracje są aktywne na pulsie i przy dobrych trafieniach.'
              : widget.showLevelSelector
              ? 'Masz 3 poziomy tempa. Wybierz poziom i kliknij start.'
              : 'Kliknij start i złap rytm.',
          textAlign: TextAlign.center,
          style: theme.textTheme.bodyMedium?.copyWith(
            color: palette.tertiaryText,
          ),
        ),
      ],
    );
  }

  @override
  void dispose() {
    _cancelTimers();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final palette = context.appPalette;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        Row(
          children: <Widget>[
            Expanded(
              child: StatStrip(
                label: 'Tempo',
                value: '$_currentBpm BPM',
                tint: widget.accent,
              ),
            ),
            const SizedBox(width: 10),
            Expanded(
              child: StatStrip(
                label: 'Czas',
                value: '${_remainingSeconds}s',
                tint: widget.accent,
              ),
            ),
            const SizedBox(width: 10),
            Expanded(
              child: StatStrip(
                label: 'Punkty',
                value: '$_points',
                tint: widget.accent,
              ),
            ),
          ],
        ),
        const SizedBox(height: 18),
        if (widget.showLevelSelector &&
            !_running &&
            !_isCountingDown &&
            !_showFinishOnly) ...<Widget>[
          _buildLevelSelector(),
          const SizedBox(height: 18),
        ],
        GestureDetector(
          onTap: _handleTap,
          child: Container(
            width: double.infinity,
            padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 26),
            decoration: BoxDecoration(
              color: palette.surfaceStrong,
              borderRadius: BorderRadius.circular(26),
            ),
            child: SizedBox(
              width: double.infinity,
              height: 300,
              child: Center(
                child: _isCountingDown
                    ? _buildSessionBody(theme)
                    : AnimatedSwitcher(
                        duration: const Duration(milliseconds: 220),
                        child: _buildSessionBody(theme),
                      ),
              ),
            ),
          ),
        ),
        const SizedBox(height: 18),
        if (!_running && !_isCountingDown && !_showFinishOnly)
          Center(
            child: ConstrainedBox(
              constraints: const BoxConstraints(minWidth: 220, maxWidth: 280),
              child: FilledButton(
                onPressed: _handlePrimaryAction,
                child: const Text('Start sesji'),
              ),
            ),
          ),
      ],
    );
  }
}

enum FocusScanMode { basic, medium, hard }

class _FocusScanModeDefinition {
  const _FocusScanModeDefinition({
    required this.mode,
    required this.label,
    required this.title,
    required this.summary,
    required this.trainingGoal,
  });

  final FocusScanMode mode;
  final String label;
  final String title;
  final String summary;
  final String trainingGoal;
}

const List<_FocusScanModeDefinition>
_focusScanModeDefinitions = <_FocusScanModeDefinition>[
  _FocusScanModeDefinition(
    mode: FocusScanMode.basic,
    label: 'Podstawowa',
    title: 'Skan Koncentracji',
    summary: 'Jedna decyzja: czy kolor czcionki zgadza się z tym, co czytasz.',
    trainingGoal:
        'Trening hamowania automatycznej reakcji i selektywnej uwagi.',
  ),
  _FocusScanModeDefinition(
    mode: FocusScanMode.medium,
    label: 'Średnia',
    title: 'Skan Potrójny',
    summary:
        'Dochodzi tło, a pytanie zmienia filtr między napisem, barwą i planszą.',
    trainingGoal: 'Trening przełączania uwagi i odcinania rozpraszaczy.',
  ),
  _FocusScanModeDefinition(
    mode: FocusScanMode.hard,
    label: 'Hard',
    title: 'Echo Pamięci',
    summary:
        'Odpowiadasz o poprzedniej planszy, więc patrzysz, pamiętasz i porównujesz.',
    trainingGoal: 'Trening pamięci roboczej i kontroli impulsu pod presją.',
  ),
];

class _FocusScanModeSelectorCard extends StatefulWidget {
  const _FocusScanModeSelectorCard({
    required this.accent,
    required this.selectedMode,
    required this.onModeChanged,
  });

  final Color accent;
  final FocusScanMode selectedMode;
  final ValueChanged<FocusScanMode> onModeChanged;

  @override
  State<_FocusScanModeSelectorCard> createState() =>
      _FocusScanModeSelectorCardState();
}

class _FocusScanModeSelectorCardState
    extends State<_FocusScanModeSelectorCard> {
  late final PageController _pageController;

  @override
  void initState() {
    super.initState();
    _pageController = PageController(initialPage: widget.selectedMode.index);
  }

  @override
  void didUpdateWidget(covariant _FocusScanModeSelectorCard oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.selectedMode == oldWidget.selectedMode ||
        !_pageController.hasClients) {
      return;
    }

    _pageController.animateToPage(
      widget.selectedMode.index,
      duration: const Duration(milliseconds: 220),
      curve: Curves.easeOutCubic,
    );
  }

  @override
  void dispose() {
    _pageController.dispose();
    super.dispose();
  }

  void _handleModeTap(FocusScanMode mode) {
    if (widget.selectedMode == mode) {
      return;
    }

    widget.onModeChanged(mode);
  }

  void _handlePageChanged(int index) {
    final nextMode = _focusScanModeDefinitions[index].mode;
    if (nextMode == widget.selectedMode) {
      return;
    }

    widget.onModeChanged(nextMode);
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final palette = context.appPalette;
    final selectedIndex = widget.selectedMode.index;

    return SurfaceCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          const SectionHeader(eyebrow: 'Tryby', title: 'Tryby gry'),
          const SizedBox(height: 18),
          Container(
            width: double.infinity,
            height: 170,
            padding: const EdgeInsets.fromLTRB(18, 16, 18, 14),
            decoration: BoxDecoration(
              gradient: LinearGradient(
                begin: Alignment.topLeft,
                end: Alignment.bottomRight,
                colors: <Color>[
                  widget.accent.withValues(alpha: 0.16),
                  palette.surfaceStrong,
                ],
              ),
              borderRadius: BorderRadius.circular(26),
              border: Border.all(color: widget.accent.withValues(alpha: 0.18)),
            ),
            child: Column(
              children: <Widget>[
                Expanded(
                  child: PageView.builder(
                    controller: _pageController,
                    itemCount: _focusScanModeDefinitions.length,
                    physics: const BouncingScrollPhysics(),
                    onPageChanged: _handlePageChanged,
                    itemBuilder: (BuildContext context, int index) {
                      final definition = _focusScanModeDefinitions[index];
                      final isSelected = index == selectedIndex;

                      return GestureDetector(
                        onTap: () => _handleModeTap(definition.mode),
                        child: Container(
                          key: ValueKey<String>(
                            'focus-scan-mode-card-${definition.mode.name}',
                          ),
                          width: double.infinity,
                          padding: const EdgeInsets.all(18),
                          decoration: BoxDecoration(
                            color: palette.surface.withValues(alpha: 0.92),
                            borderRadius: BorderRadius.circular(22),
                            border: Border.all(
                              color: isSelected
                                  ? widget.accent.withValues(alpha: 0.42)
                                  : widget.accent.withValues(alpha: 0.24),
                            ),
                          ),
                          child: Center(
                            child: Text(
                              definition.label,
                              textAlign: TextAlign.center,
                              style: theme.textTheme.titleLarge?.copyWith(
                                color: palette.primaryText,
                                fontWeight: FontWeight.w900,
                              ),
                            ),
                          ),
                        ),
                      );
                    },
                  ),
                ),
                const SizedBox(height: 12),
                Row(
                  mainAxisSize: MainAxisSize.min,
                  children: List<Widget>.generate(
                    _focusScanModeDefinitions.length,
                    (int index) {
                      final bool selected = index == selectedIndex;
                      return AnimatedContainer(
                        duration: const Duration(milliseconds: 180),
                        margin: EdgeInsets.only(left: index == 0 ? 0 : 6),
                        width: selected ? 18 : 8,
                        height: 8,
                        decoration: BoxDecoration(
                          color: selected
                              ? widget.accent
                              : widget.accent.withValues(alpha: 0.24),
                          borderRadius: BorderRadius.circular(999),
                        ),
                      );
                    },
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class FocusScanTrainer extends StatefulWidget {
  const FocusScanTrainer({
    super.key,
    required this.accent,
    this.autoStart = false,
    this.fullscreenOnStart = false,
    this.autoExitOnFinish = false,
    this.initialMode = FocusScanMode.basic,
    this.showModeSelector = true,
    this.onSessionStarted,
  });

  final Color accent;
  final bool autoStart;
  final bool fullscreenOnStart;
  final bool autoExitOnFinish;
  final FocusScanMode initialMode;
  final bool showModeSelector;
  final VoidCallback? onSessionStarted;

  @override
  State<FocusScanTrainer> createState() => _FocusScanTrainerState();
}

class _FocusScanTrainerState extends State<FocusScanTrainer> {
  static const int _sessionStartCountdownSeconds = 3;
  static const int _sessionSeconds = 45;
  static const List<_FocusAnswerOption> _binaryOptions = <_FocusAnswerOption>[
    _FocusAnswerOption(id: 'yes', label: 'TAK'),
    _FocusAnswerOption(id: 'no', label: 'NIE'),
  ];

  final Random _random = Random();
  final List<_FocusColor> _colors = const <_FocusColor>[
    _FocusColor(
      label: 'CZERWONY',
      color: Color(0xFFD35757),
      surface: Color(0xFFF8DCDC),
    ),
    _FocusColor(
      label: 'ZIELONY',
      color: Color(0xFF3B8F5E),
      surface: Color(0xFFDFF2E5),
    ),
    _FocusColor(
      label: 'NIEBIESKI',
      color: Color(0xFF4370C7),
      surface: Color(0xFFDDE6FA),
    ),
    _FocusColor(
      label: 'ZŁOTY',
      color: Color(0xFFC68A1F),
      surface: Color(0xFFF6E9C9),
    ),
  ];

  Timer? _startCountdownTimer;
  Timer? _timer;
  Timer? _finishExitTimer;
  bool _running = false;
  bool _finished = false;
  int _remainingSeconds = _sessionSeconds;
  int _points = 0;
  int? _countdownValue;
  late FocusScanMode _selectedMode;
  late FocusScanMode _sessionMode;
  late _FocusStimulus _previewStimulus;
  _FocusStimulus? _lastStimulus;
  _FocusRound? _currentRound;
  int _roundIndex = 0;

  @override
  void initState() {
    super.initState();
    _selectedMode = widget.initialMode;
    _sessionMode = widget.initialMode;
    _previewStimulus = _buildStimulus(_selectedMode);
    if (widget.autoStart) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) {
          _startSessionWithCountdown();
        }
      });
    }
  }

  @override
  void didUpdateWidget(covariant FocusScanTrainer oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.initialMode == oldWidget.initialMode ||
        _running ||
        _isCountingDown) {
      return;
    }

    setState(() {
      _selectedMode = widget.initialMode;
      _previewStimulus = _buildStimulus(_selectedMode);
    });
  }

  bool get _isCountingDown => _countdownValue != null;

  String get _countdownLabel {
    final value = _countdownValue;
    if (value == null) {
      return '';
    }
    return value == 0 ? 'START' : '$value';
  }

  _FocusScanModeDefinition get _selectedModeDefinition =>
      _modeDefinitionFor(_selectedMode);

  _FocusScanModeDefinition get _activeModeDefinition => _modeDefinitionFor(
    _running || _isCountingDown ? _sessionMode : _selectedMode,
  );

  _FocusScanModeDefinition _modeDefinitionFor(FocusScanMode mode) {
    return _focusScanModeDefinitions.firstWhere(
      (_FocusScanModeDefinition definition) => definition.mode == mode,
    );
  }

  void _selectMode(FocusScanMode mode) {
    if (_running || _isCountingDown || mode == _selectedMode) {
      return;
    }

    setState(() {
      _selectedMode = mode;
      _previewStimulus = _buildStimulus(mode);
    });
  }

  void _startSessionWithCountdown() {
    if (_running || _isCountingDown) {
      return;
    }

    widget.onSessionStarted?.call();
    _finishExitTimer?.cancel();
    _startCountdownTimer?.cancel();
    _timer?.cancel();

    setState(() {
      _finished = false;
      _running = false;
      _remainingSeconds = _sessionSeconds;
      _points = 0;
      _countdownValue = _sessionStartCountdownSeconds;
      _sessionMode = _selectedMode;
      _currentRound = null;
      _lastStimulus = null;
      _roundIndex = 0;
    });

    HapticFeedback.selectionClick();

    _startCountdownTimer = Timer.periodic(const Duration(seconds: 1), (
      Timer timer,
    ) {
      if (!mounted) {
        timer.cancel();
        return;
      }

      final currentCountdown = _countdownValue;
      if (currentCountdown == null) {
        timer.cancel();
        return;
      }

      if (currentCountdown <= 0) {
        timer.cancel();
        _startSession();
        return;
      }

      setState(() {
        _countdownValue = currentCountdown - 1;
      });

      if (_countdownValue == 0) {
        HapticFeedback.mediumImpact();
      } else {
        HapticFeedback.selectionClick();
      }
    });
  }

  void _startSession() {
    _finishExitTimer?.cancel();
    _startCountdownTimer?.cancel();
    _timer?.cancel();

    setState(() {
      _running = true;
      _finished = false;
      _remainingSeconds = _sessionSeconds;
      _points = 0;
      _countdownValue = null;
      _roundIndex = 0;
      _lastStimulus = null;
      _prepareNextRound();
    });

    _timer = Timer.periodic(const Duration(seconds: 1), (Timer timer) {
      if (!mounted) {
        return;
      }

      if (_remainingSeconds <= 1) {
        timer.cancel();
        _finishSession();
      } else {
        setState(() {
          _remainingSeconds -= 1;
        });
      }
    });
  }

  void _prepareNextRound() {
    final stimulus = _buildStimulus(_sessionMode);
    final previousStimulus = _lastStimulus;
    final isFirstRound = _roundIndex == 0;

    _currentRound = _FocusRound(
      stimulus: stimulus,
      previousStimulus: previousStimulus,
      question: _buildQuestion(
        mode: _sessionMode,
        current: stimulus,
        previous: previousStimulus,
        isFirstRound: isFirstRound,
      ),
    );
    _lastStimulus = stimulus;
    _roundIndex += 1;
  }

  _FocusStimulus _buildStimulus(FocusScanMode mode) {
    if (mode == FocusScanMode.basic) {
      final word = _randomColor();
      final shouldMatch = _random.nextBool();
      final ink = shouldMatch
          ? word
          : _randomDifferentColor(<_FocusColor>{word});
      return _FocusStimulus(word: word, ink: ink, background: word);
    }

    final pattern = _random.nextInt(10);
    final word = _randomColor();

    switch (pattern) {
      case 0:
      case 1:
      case 2:
        final ink = _randomDifferentColor(<_FocusColor>{word});
        final background = _randomDifferentColor(<_FocusColor>{word, ink});
        return _FocusStimulus(word: word, ink: ink, background: background);
      case 3:
      case 4:
        final background = _randomDifferentColor(<_FocusColor>{word});
        return _FocusStimulus(word: word, ink: word, background: background);
      case 5:
      case 6:
        final shared = _randomDifferentColor(<_FocusColor>{word});
        return _FocusStimulus(word: word, ink: shared, background: shared);
      case 7:
        final ink = _randomDifferentColor(<_FocusColor>{word});
        return _FocusStimulus(word: word, ink: ink, background: word);
      case 8:
        return _FocusStimulus(word: word, ink: word, background: word);
      default:
        final ink = _randomColor();
        final background = _randomColor();
        return _FocusStimulus(word: word, ink: ink, background: background);
    }
  }

  _FocusColor _randomColor() => _colors[_random.nextInt(_colors.length)];

  _FocusColor _randomDifferentColor(Set<_FocusColor> excluded) {
    _FocusColor candidate = _randomColor();
    while (excluded.contains(candidate)) {
      candidate = _randomColor();
    }
    return candidate;
  }

  _FocusQuestion _buildQuestion({
    required FocusScanMode mode,
    required _FocusStimulus current,
    required _FocusStimulus? previous,
    required bool isFirstRound,
  }) {
    return switch (mode) {
      FocusScanMode.basic => _buildBasicQuestion(current),
      FocusScanMode.medium => _buildMediumQuestion(current),
      FocusScanMode.hard => _buildHardQuestion(
        current: current,
        previous: previous,
        isFirstRound: isFirstRound,
      ),
    };
  }

  _FocusQuestion _buildBasicQuestion(_FocusStimulus current) {
    return _buildBinaryQuestion(
      prompt: _pickText(<String>[
        'Szybki skan: kolor i słowo są zgodne?',
        'To, co widzisz, zgadza się z napisem?',
        'Zatrzymaj czytanie. Barwa i słowo pasują?',
      ]),
      helper: _pickText(<String>[
        'Patrz na barwę napisu i zatrzymaj odruch czytania.',
        'Liczy się tylko kolor liter. Reszta to szum.',
        'Jedna zasada, szybka decyzja, zero domysłów.',
      ]),
      correct: current.wordMatchesInk,
    );
  }

  _FocusQuestion _buildMediumQuestion(_FocusStimulus current) {
    final roll = _random.nextInt(10);

    if (roll <= 2) {
      return _buildColorSelectionQuestion(
        prompt: _pickText(<String>[
          'Odetnij resztę. Jaki jest kolor czcionki?',
          'Patrz tylko na barwę liter. Co widzisz?',
          'Filtr na kolor czcionki. Wskaż właściwy.',
        ]),
        helper: 'Ignoruj treść słowa i tło. Liczy się wyłącznie czcionka.',
        correct: current.ink,
      );
    }

    if (roll <= 4) {
      return _buildColorSelectionQuestion(
        prompt: _pickText(<String>[
          'Czytaj precyzyjnie. Co jest napisane?',
          'Teraz liczy się samo słowo. Co czytasz?',
          'Przełącz filtr na tekst. Wskaż napis.',
        ]),
        helper: 'Nie patrz na kolor. Odpowiedź siedzi w samym napisie.',
        correct: current.word,
      );
    }

    if (roll <= 6) {
      return _buildColorSelectionQuestion(
        prompt: _pickText(<String>[
          'Zmień fokus na tło. Jaki kolor ma plansza?',
          'Teraz liczy się tylko tło. Co widzisz za napisem?',
          'Odetnij napis i czcionkę. Wskaż kolor planszy.',
        ]),
        helper: 'Skup się na tle. Tekst ma tylko rozpraszać.',
        correct: current.background,
      );
    }

    if (roll == 7) {
      return _buildBinaryQuestion(
        prompt: 'Czy napis zgadza się z kolorem czcionki?',
        helper: 'Porównaj tylko te dwie warstwy: słowo i barwę liter.',
        correct: current.wordMatchesInk,
      );
    }

    if (roll == 8) {
      return _buildBinaryQuestion(
        prompt: 'Czy kolor czcionki zgadza się z tłem?',
        helper: 'Trzymaj wzrok na relacji czcionka kontra plansza.',
        correct: current.inkMatchesBackground,
      );
    }

    return _buildBinaryQuestion(
      prompt: 'Czy napis zgadza się z kolorem tła?',
      helper: 'Porównujesz słowo z planszą, nie z samą czcionką.',
      correct: current.wordMatchesBackground,
    );
  }

  _FocusQuestion _buildHardQuestion({
    required _FocusStimulus current,
    required _FocusStimulus? previous,
    required bool isFirstRound,
  }) {
    if (previous == null || isFirstRound) {
      final starter = _random.nextInt(3);
      if (starter == 0) {
        return _buildColorSelectionQuestion(
          prompt: 'Plansza startowa: zapamiętaj układ i wskaż kolor czcionki.',
          helper: 'Od następnej rundy odpowiadasz o poprzedniej planszy.',
          correct: current.ink,
        );
      }
      if (starter == 1) {
        return _buildColorSelectionQuestion(
          prompt:
              'Plansza startowa: zapamiętaj układ i wskaż, co jest napisane.',
          helper: 'To ostatni raz, gdy odpowiadasz o tym, co widzisz teraz.',
          correct: current.word,
        );
      }
      return _buildColorSelectionQuestion(
        prompt: 'Plansza startowa: zapamiętaj układ i wskaż kolor tła.',
        helper: 'Zaraz zaczniesz pracować na pamięci poprzedniej planszy.',
        correct: current.background,
      );
    }

    final roll = _random.nextInt(10);
    if (roll <= 2) {
      return _buildColorSelectionQuestion(
        prompt: 'Poprzednia plansza: jaki był kolor czcionki?',
        helper:
            'Nie odpowiadaj o tym, co widzisz teraz. Cofnij się o jedną planszę.',
        correct: previous.ink,
      );
    }

    if (roll <= 4) {
      return _buildColorSelectionQuestion(
        prompt: 'Poprzednia plansza: co było napisane?',
        helper: 'Trzymaj poprzedni napis w pamięci i odetnij aktualny bodziec.',
        correct: previous.word,
      );
    }

    if (roll <= 6) {
      return _buildColorSelectionQuestion(
        prompt: 'Poprzednia plansza: jakie było tło?',
        helper: 'Pamięć robocza ma wygrać z tym, co widzisz w tej chwili.',
        correct: previous.background,
      );
    }

    if (roll == 7) {
      return _buildBinaryQuestion(
        prompt: 'Czy poprzedni napis zgadzał się z kolorem czcionki?',
        helper:
            'Patrzysz teraz, ale odpowiadasz o relacji z poprzedniej planszy.',
        correct: previous.wordMatchesInk,
      );
    }

    if (roll == 8) {
      return _buildBinaryQuestion(
        prompt: 'Czy obecne tło jest takie samo jak poprzednie?',
        helper: 'Porównaj bieżący obraz z tym, co zostało w pamięci.',
        correct: current.background == previous.background,
      );
    }

    return _buildBinaryQuestion(
      prompt: 'Czy obecny kolor czcionki jest taki sam jak poprzednio?',
      helper: 'Nie zgaduj. Porównaj aktualną czcionkę z poprzednią planszą.',
      correct: current.ink == previous.ink,
    );
  }

  _FocusQuestion _buildBinaryQuestion({
    required String prompt,
    required String helper,
    required bool correct,
  }) {
    return _FocusQuestion(
      prompt: prompt,
      helper: helper,
      options: _binaryOptions,
      correctOptionId: correct ? 'yes' : 'no',
    );
  }

  _FocusQuestion _buildColorSelectionQuestion({
    required String prompt,
    required String helper,
    required _FocusColor correct,
  }) {
    final options =
        _colors
            .map(
              (_FocusColor color) => _FocusAnswerOption(
                id: color.label,
                label: color.label,
                tint: color.color,
              ),
            )
            .toList()
          ..shuffle(_random);

    return _FocusQuestion(
      prompt: prompt,
      helper: helper,
      options: options,
      correctOptionId: correct.label,
    );
  }

  String _pickText(List<String> values) =>
      values[_random.nextInt(values.length)];

  void _answer(String optionId) {
    if (!_running || _currentRound == null) {
      return;
    }

    final correct = optionId == _currentRound!.question.correctOptionId;
    if (correct) {
      HapticFeedback.lightImpact();
    } else {
      HapticFeedback.selectionClick();
    }

    setState(() {
      if (correct) {
        _points += 1;
      }
      _prepareNextRound();
    });
  }

  void _finishSession() {
    _finishExitTimer?.cancel();
    _startCountdownTimer?.cancel();
    _timer?.cancel();

    setState(() {
      _remainingSeconds = 0;
      _running = false;
      _finished = true;
      _countdownValue = null;
      _previewStimulus = _buildStimulus(_selectedMode);
    });

    if (!widget.autoExitOnFinish) {
      return;
    }

    _finishExitTimer = Timer(const Duration(seconds: 2), () {
      if (!mounted) {
        return;
      }
      Navigator.of(context).maybePop();
    });
  }

  Future<void> _openFullscreenSession() {
    return Navigator.of(context).push<void>(
      _buildExerciseSessionRoute<void>(
        builder: (BuildContext context) {
          return FullscreenTrainerPage(
            title: 'Skan Koncentracji',
            accent: widget.accent,
            expandBody: true,
            showHeader: false,
            wrapChildInSurfaceCard: false,
            contentMaxWidth: null,
            bodyPadding: EdgeInsets.zero,
            child: FocusScanTrainer(
              accent: widget.accent,
              autoStart: true,
              autoExitOnFinish: true,
              initialMode: _selectedMode,
              showModeSelector: widget.showModeSelector,
            ),
          );
        },
      ),
    );
  }

  Future<void> _handleStartAction() async {
    if (widget.fullscreenOnStart) {
      widget.onSessionStarted?.call();
      await _openFullscreenSession();
      return;
    }

    _startSessionWithCountdown();
  }

  Widget _buildModeSelector(ThemeData theme) {
    final palette = context.appPalette;
    return Wrap(
      spacing: 10,
      runSpacing: 10,
      children: _focusScanModeDefinitions.map((
        _FocusScanModeDefinition definition,
      ) {
        final selected = _selectedMode == definition.mode;
        return ChoiceChip(
          label: Text(definition.label),
          selected: selected,
          onSelected: _running || _isCountingDown
              ? null
              : (_) => _selectMode(definition.mode),
          labelStyle: theme.textTheme.titleSmall?.copyWith(
            color: selected ? palette.primaryText : palette.secondaryText,
            fontWeight: FontWeight.w800,
          ),
          selectedColor: widget.accent.withValues(alpha: 0.18),
          backgroundColor: palette.surface,
          side: BorderSide(
            color: selected
                ? widget.accent.withValues(alpha: 0.34)
                : palette.surfaceBorder,
          ),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(18),
          ),
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
        );
      }).toList(),
    );
  }

  Widget _buildStimulusPanel({
    required _FocusStimulus stimulus,
    required FocusScanMode mode,
    required ThemeData theme,
  }) {
    final palette = context.appPalette;
    final backgroundColor = mode == FocusScanMode.basic
        ? palette.surfaceMuted
        : stimulus.background.surface;

    return Container(
      width: double.infinity,
      padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 22),
      decoration: BoxDecoration(
        color: backgroundColor,
        borderRadius: BorderRadius.circular(24),
        border: Border.all(color: Colors.white.withValues(alpha: 0.68)),
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          if (mode != FocusScanMode.basic) ...<Widget>[
            Text(
              'TŁO',
              style: theme.textTheme.labelLarge?.copyWith(
                color: palette.secondaryText,
                fontWeight: FontWeight.w800,
                letterSpacing: 1.2,
              ),
            ),
            const SizedBox(height: 14),
          ],
          Text(
            stimulus.word.label,
            textAlign: TextAlign.center,
            style: theme.textTheme.headlineMedium?.copyWith(
              color: stimulus.ink.color,
              fontWeight: FontWeight.w900,
              letterSpacing: 1.1,
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildOptionLabel(_FocusAnswerOption option, ThemeData theme) {
    final palette = context.appPalette;
    final label = Text(
      option.label,
      textAlign: TextAlign.center,
      style: theme.textTheme.titleSmall?.copyWith(
        color: palette.primaryText,
        fontWeight: FontWeight.w800,
        letterSpacing: 0.4,
      ),
    );

    if (option.tint == null) {
      return label;
    }

    return Row(
      mainAxisAlignment: MainAxisAlignment.center,
      children: <Widget>[
        Container(
          width: 12,
          height: 12,
          decoration: BoxDecoration(color: option.tint, shape: BoxShape.circle),
        ),
        const SizedBox(width: 10),
        Flexible(child: label),
      ],
    );
  }

  Widget _buildAnswerButtons(ThemeData theme) {
    final round = _currentRound;
    if (!_running || round == null) {
      return const SizedBox.shrink();
    }

    return LayoutBuilder(
      builder: (BuildContext context, BoxConstraints constraints) {
        const spacing = 12.0;
        final itemWidth = (constraints.maxWidth - spacing) / 2;
        return Wrap(
          spacing: spacing,
          runSpacing: spacing,
          children: round.question.options.map((_FocusAnswerOption option) {
            return SizedBox(
              width: itemWidth,
              child: OutlinedButton(
                onPressed: () => _answer(option.id),
                style: OutlinedButton.styleFrom(
                  foregroundColor: const Color(0xFF16212B),
                  backgroundColor: (option.tint ?? widget.accent).withValues(
                    alpha: 0.12,
                  ),
                  side: BorderSide(
                    color: (option.tint ?? widget.accent).withValues(
                      alpha: 0.28,
                    ),
                  ),
                  padding: const EdgeInsets.symmetric(
                    horizontal: 14,
                    vertical: 18,
                  ),
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(20),
                  ),
                ),
                child: _buildOptionLabel(option, theme),
              ),
            );
          }).toList(),
        );
      },
    );
  }

  Widget _buildSessionBody(ThemeData theme) {
    final palette = context.appPalette;
    if (_finished) {
      return Container(
        key: const ValueKey<String>('focus-scan-finished'),
        padding: const EdgeInsets.symmetric(horizontal: 28, vertical: 24),
        decoration: BoxDecoration(
          color: widget.accent.withValues(alpha: 0.12),
          borderRadius: BorderRadius.circular(24),
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            Text(
              'Koniec sesji',
              style: theme.textTheme.headlineMedium?.copyWith(
                color: palette.primaryText,
                fontWeight: FontWeight.w900,
                letterSpacing: 1.0,
              ),
            ),
            const SizedBox(height: 12),
            Text(
              '${_modeDefinitionFor(_sessionMode).label} • $_points pkt',
              textAlign: TextAlign.center,
              style: theme.textTheme.titleLarge?.copyWith(
                color: palette.secondaryText,
                fontWeight: FontWeight.w800,
              ),
            ),
          ],
        ),
      );
    }

    if (_isCountingDown) {
      final showCountdownHeading = _countdownLabel != 'START';
      return Column(
        key: const ValueKey<String>('focus-scan-countdown'),
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          if (showCountdownHeading) ...<Widget>[
            Text(
              'START ZA',
              style: theme.textTheme.titleLarge?.copyWith(
                color: palette.secondaryText,
                fontWeight: FontWeight.w800,
                letterSpacing: 1.3,
              ),
            ),
            const SizedBox(height: 14),
            Text(
              _activeModeDefinition.title,
              textAlign: TextAlign.center,
              style: theme.textTheme.bodyLarge?.copyWith(
                color: widget.accent,
                fontWeight: FontWeight.w700,
              ),
            ),
            const SizedBox(height: 16),
          ],
          Text(
            _countdownLabel,
            key: ValueKey<String>('focus-scan-countdown-$_countdownLabel'),
            style: theme.textTheme.displaySmall?.copyWith(
              color: widget.accent,
              fontWeight: FontWeight.w900,
              letterSpacing: _countdownLabel == 'START' ? 1.4 : 0.0,
            ),
          ),
        ],
      );
    }

    if (_running && _currentRound != null) {
      final round = _currentRound!;
      return Column(
        key: ValueKey<String>(
          'focus-scan-running-${_sessionMode.name}-${_roundIndex % 3}',
        ),
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          Text(
            round.question.prompt,
            textAlign: TextAlign.center,
            style: theme.textTheme.titleLarge?.copyWith(
              color: palette.primaryText,
              fontWeight: FontWeight.w800,
              height: 1.25,
            ),
          ),
          const SizedBox(height: 18),
          _buildStimulusPanel(
            stimulus: round.stimulus,
            mode: _sessionMode,
            theme: theme,
          ),
        ],
      );
    }

    return Column(
      key: ValueKey<String>('focus-scan-idle-${_selectedMode.name}'),
      mainAxisSize: MainAxisSize.min,
      children: <Widget>[
        Text(
          _selectedModeDefinition.title,
          textAlign: TextAlign.center,
          style: theme.textTheme.titleLarge?.copyWith(
            color: palette.primaryText,
            fontWeight: FontWeight.w900,
          ),
        ),
        const SizedBox(height: 16),
        _buildStimulusPanel(
          stimulus: _previewStimulus,
          mode: _selectedMode,
          theme: theme,
        ),
        const SizedBox(height: 16),
        Text(
          _selectedModeDefinition.summary,
          textAlign: TextAlign.center,
          style: theme.textTheme.bodyMedium?.copyWith(
            color: palette.tertiaryText,
            fontWeight: FontWeight.w600,
          ),
        ),
      ],
    );
  }

  @override
  void dispose() {
    _finishExitTimer?.cancel();
    _startCountdownTimer?.cancel();
    _timer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final palette = context.appPalette;

    return LayoutBuilder(
      builder: (BuildContext context, BoxConstraints constraints) {
        final bool compact = constraints.maxHeight < 680;
        final double sectionGap = compact ? 12 : 18;
        final double summaryPadding = compact ? 14 : 18;
        final double sessionHeight = compact ? 230 : 320;
        final bool showModeDetails =
            widget.showModeSelector && !_running && !_isCountingDown;

        final content = Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            Row(
              children: <Widget>[
                Expanded(
                  child: StatStrip(
                    label: 'Czas',
                    value: '${_remainingSeconds}s',
                    tint: widget.accent,
                  ),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: StatStrip(
                    label: 'Punkty',
                    value: '$_points',
                    tint: widget.accent,
                  ),
                ),
              ],
            ),
            SizedBox(height: sectionGap),
            if (showModeDetails) ...<Widget>[
              _buildModeSelector(theme),
              const SizedBox(height: 14),
              Container(
                width: double.infinity,
                padding: EdgeInsets.all(summaryPadding),
                decoration: BoxDecoration(
                  color: widget.accent.withValues(alpha: 0.1),
                  borderRadius: BorderRadius.circular(22),
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: <Widget>[
                    Text(
                      '${_activeModeDefinition.label} • ${_activeModeDefinition.title}',
                      style: theme.textTheme.titleMedium?.copyWith(
                        color: palette.primaryText,
                        fontWeight: FontWeight.w900,
                      ),
                    ),
                    const SizedBox(height: 6),
                    Text(
                      _activeModeDefinition.trainingGoal,
                      style: theme.textTheme.bodyMedium?.copyWith(
                        color: palette.secondaryText,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ],
                ),
              ),
              SizedBox(height: sectionGap),
            ],
            Container(
              width: double.infinity,
              padding: EdgeInsets.all(compact ? 18 : 24),
              decoration: BoxDecoration(
                color: palette.surfaceStrong,
                borderRadius: BorderRadius.circular(26),
              ),
              child: SizedBox(
                width: double.infinity,
                height: sessionHeight,
                child: Center(
                  child: SingleChildScrollView(
                    child: AnimatedSwitcher(
                      duration: const Duration(milliseconds: 220),
                      child: _buildSessionBody(theme),
                    ),
                  ),
                ),
              ),
            ),
            SizedBox(height: sectionGap),
            if (_running)
              _buildAnswerButtons(theme)
            else if (!_isCountingDown)
              Center(
                child: ConstrainedBox(
                  constraints: const BoxConstraints(
                    minWidth: 220,
                    maxWidth: 280,
                  ),
                  child: FilledButton(
                    onPressed: _handleStartAction,
                    child: Text(_finished ? 'Zagraj ponownie' : 'Start sesji'),
                  ),
                ),
              ),
          ],
        );

        if (!compact) {
          return content;
        }

        return SingleChildScrollView(
          padding: const EdgeInsets.only(bottom: 8),
          child: content,
        );
      },
    );
  }
}

class _FocusColor {
  const _FocusColor({
    required this.label,
    required this.color,
    required this.surface,
  });

  final String label;
  final Color color;
  final Color surface;
}

class _FocusStimulus {
  const _FocusStimulus({
    required this.word,
    required this.ink,
    required this.background,
  });

  final _FocusColor word;
  final _FocusColor ink;
  final _FocusColor background;

  bool get wordMatchesInk => word == ink;
  bool get inkMatchesBackground => ink == background;
  bool get wordMatchesBackground => word == background;
}

class _FocusAnswerOption {
  const _FocusAnswerOption({required this.id, required this.label, this.tint});

  final String id;
  final String label;
  final Color? tint;
}

class _FocusQuestion {
  const _FocusQuestion({
    required this.prompt,
    required this.helper,
    required this.options,
    required this.correctOptionId,
  });

  final String prompt;
  final String helper;
  final List<_FocusAnswerOption> options;
  final String correctOptionId;
}

class _FocusRound {
  const _FocusRound({
    required this.stimulus,
    required this.previousStimulus,
    required this.question,
  });

  final _FocusStimulus stimulus;
  final _FocusStimulus? previousStimulus;
  final _FocusQuestion question;
}

enum FlowRunnerLevel { flow, surge, apex }

class _FlowRunnerLevelDefinition {
  const _FlowRunnerLevelDefinition({
    required this.level,
    required this.label,
    required this.title,
    required this.summary,
    required this.tempoLabel,
    required this.speedRampSeconds,
    required this.baseSpeed,
    required this.maxSpeed,
    required this.spawnStartMs,
    required this.spawnEndMs,
    required this.bonusChance,
    required this.maxEnergy,
    required this.tint,
  });

  final FlowRunnerLevel level;
  final String label;
  final String title;
  final String summary;
  final String tempoLabel;
  final int speedRampSeconds;
  final double baseSpeed;
  final double maxSpeed;
  final int spawnStartMs;
  final int spawnEndMs;
  final double bonusChance;
  final int maxEnergy;
  final Color tint;
}

const List<_FlowRunnerLevelDefinition>
_flowRunnerLevelDefinitions = <_FlowRunnerLevelDefinition>[
  _FlowRunnerLevelDefinition(
    level: FlowRunnerLevel.flow,
    label: 'Flow',
    title: 'Stabilny rytm',
    summary:
        'Najwięcej miejsca na wejście w ruch. Dobre tempo na złapanie serii i wyczucia torów.',
    tempoLabel: 'stabilne tempo',
    speedRampSeconds: 75,
    baseSpeed: 0.42,
    maxSpeed: 0.78,
    spawnStartMs: 980,
    spawnEndMs: 560,
    bonusChance: 0.26,
    maxEnergy: 3,
    tint: Color(0xFF2E9E89),
  ),
  _FlowRunnerLevelDefinition(
    level: FlowRunnerLevel.surge,
    label: 'Surge',
    title: 'Napięcie i korekta',
    summary:
        'Tor zagęszcza się szybciej. Nadal masz rytm, ale decyzje muszą być bardziej wyprzedzające.',
    tempoLabel: 'szybszy wzrost',
    speedRampSeconds: 75,
    baseSpeed: 0.48,
    maxSpeed: 0.9,
    spawnStartMs: 860,
    spawnEndMs: 470,
    bonusChance: 0.22,
    maxEnergy: 3,
    tint: Color(0xFF2F7FC1),
  ),
  _FlowRunnerLevelDefinition(
    level: FlowRunnerLevel.apex,
    label: 'Apex',
    title: 'Pełny napór',
    summary:
        'Najciaśniejsze okna i najwyższy sufit tempa. Liczy się czysta płynność ruchu bez zawahania.',
    tempoLabel: 'maksymalny napór',
    speedRampSeconds: 75,
    baseSpeed: 0.54,
    maxSpeed: 1.02,
    spawnStartMs: 760,
    spawnEndMs: 410,
    bonusChance: 0.18,
    maxEnergy: 3,
    tint: Color(0xFFE98F3D),
  ),
];

class _FlowRunnerLevelSelectorCard extends StatefulWidget {
  const _FlowRunnerLevelSelectorCard({
    required this.accent,
    required this.selectedLevel,
    required this.onLevelChanged,
  });

  final Color accent;
  final FlowRunnerLevel selectedLevel;
  final ValueChanged<FlowRunnerLevel> onLevelChanged;

  @override
  State<_FlowRunnerLevelSelectorCard> createState() =>
      _FlowRunnerLevelSelectorCardState();
}

class _FlowRunnerLevelSelectorCardState
    extends State<_FlowRunnerLevelSelectorCard> {
  late final PageController _pageController;

  @override
  void initState() {
    super.initState();
    _pageController = PageController(initialPage: widget.selectedLevel.index);
  }

  @override
  void didUpdateWidget(covariant _FlowRunnerLevelSelectorCard oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.selectedLevel == oldWidget.selectedLevel ||
        !_pageController.hasClients) {
      return;
    }

    _pageController.animateToPage(
      widget.selectedLevel.index,
      duration: const Duration(milliseconds: 220),
      curve: Curves.easeOutCubic,
    );
  }

  @override
  void dispose() {
    _pageController.dispose();
    super.dispose();
  }

  void _handleLevelTap(FlowRunnerLevel level) {
    if (widget.selectedLevel == level) {
      return;
    }

    widget.onLevelChanged(level);
  }

  void _handlePageChanged(int index) {
    final nextLevel = _flowRunnerLevelDefinitions[index].level;
    if (widget.selectedLevel == nextLevel) {
      return;
    }

    widget.onLevelChanged(nextLevel);
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final palette = context.appPalette;
    final selectedIndex = widget.selectedLevel.index;

    return SurfaceCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          const SectionHeader(eyebrow: 'Poziomy', title: 'Poziomy gry'),
          const SizedBox(height: 18),
          Container(
            width: double.infinity,
            height: 210,
            padding: const EdgeInsets.fromLTRB(18, 16, 18, 14),
            decoration: BoxDecoration(
              gradient: LinearGradient(
                begin: Alignment.topLeft,
                end: Alignment.bottomRight,
                colors: <Color>[
                  widget.accent.withValues(alpha: 0.16),
                  palette.surfaceStrong,
                ],
              ),
              borderRadius: BorderRadius.circular(26),
              border: Border.all(color: widget.accent.withValues(alpha: 0.18)),
            ),
            child: Column(
              children: <Widget>[
                Expanded(
                  child: PageView.builder(
                    controller: _pageController,
                    itemCount: _flowRunnerLevelDefinitions.length,
                    physics: const BouncingScrollPhysics(),
                    onPageChanged: _handlePageChanged,
                    itemBuilder: (BuildContext context, int index) {
                      final definition = _flowRunnerLevelDefinitions[index];
                      final bool selected = index == selectedIndex;

                      return GestureDetector(
                        onTap: () => _handleLevelTap(definition.level),
                        child: Container(
                          key: ValueKey<String>(
                            'flow-runner-level-card-${definition.level.name}',
                          ),
                          width: double.infinity,
                          padding: const EdgeInsets.all(18),
                          decoration: BoxDecoration(
                            color: palette.surface.withValues(alpha: 0.92),
                            borderRadius: BorderRadius.circular(22),
                            border: Border.all(
                              color: selected
                                  ? definition.tint.withValues(alpha: 0.5)
                                  : definition.tint.withValues(alpha: 0.22),
                            ),
                          ),
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: <Widget>[
                              Container(
                                padding: const EdgeInsets.symmetric(
                                  horizontal: 12,
                                  vertical: 8,
                                ),
                                decoration: BoxDecoration(
                                  color: definition.tint.withValues(
                                    alpha: 0.12,
                                  ),
                                  borderRadius: BorderRadius.circular(999),
                                ),
                                child: Text(
                                  definition.label,
                                  style: theme.textTheme.labelLarge?.copyWith(
                                    color: definition.tint,
                                    fontWeight: FontWeight.w900,
                                    letterSpacing: 0.8,
                                  ),
                                ),
                              ),
                              const SizedBox(height: 14),
                              Text(
                                definition.title,
                                style: theme.textTheme.titleLarge?.copyWith(
                                  color: palette.primaryText,
                                  fontWeight: FontWeight.w900,
                                ),
                              ),
                              const SizedBox(height: 8),
                              Text(
                                definition.summary,
                                style: theme.textTheme.bodyMedium?.copyWith(
                                  color: palette.secondaryText,
                                  height: 1.45,
                                ),
                              ),
                              const Spacer(),
                              Text(
                                definition.tempoLabel,
                                style: theme.textTheme.bodyMedium?.copyWith(
                                  color: palette.primaryText,
                                  fontWeight: FontWeight.w800,
                                ),
                              ),
                            ],
                          ),
                        ),
                      );
                    },
                  ),
                ),
                const SizedBox(height: 12),
                Row(
                  mainAxisSize: MainAxisSize.min,
                  children: List<Widget>.generate(
                    _flowRunnerLevelDefinitions.length,
                    (int index) {
                      final bool selected = index == selectedIndex;
                      return AnimatedContainer(
                        duration: const Duration(milliseconds: 180),
                        margin: EdgeInsets.only(left: index == 0 ? 0 : 6),
                        width: selected ? 18 : 8,
                        height: 8,
                        decoration: BoxDecoration(
                          color: selected
                              ? widget.accent
                              : widget.accent.withValues(alpha: 0.24),
                          borderRadius: BorderRadius.circular(999),
                        ),
                      );
                    },
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _SplitDecisionLevelSelectorCard extends StatefulWidget {
  const _SplitDecisionLevelSelectorCard({
    required this.accent,
    required this.selectedIndex,
    required this.onLevelChanged,
  });

  final Color accent;
  final int selectedIndex;
  final ValueChanged<int> onLevelChanged;

  @override
  State<_SplitDecisionLevelSelectorCard> createState() =>
      _SplitDecisionLevelSelectorCardState();
}

class _SplitDecisionLevelSelectorCardState
    extends State<_SplitDecisionLevelSelectorCard> {
  late final PageController _pageController;

  @override
  void initState() {
    super.initState();
    _pageController = PageController(initialPage: widget.selectedIndex);
  }

  @override
  void didUpdateWidget(covariant _SplitDecisionLevelSelectorCard oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.selectedIndex == oldWidget.selectedIndex ||
        !_pageController.hasClients) {
      return;
    }

    _pageController.animateToPage(
      widget.selectedIndex,
      duration: const Duration(milliseconds: 220),
      curve: Curves.easeOutCubic,
    );
  }

  @override
  void dispose() {
    _pageController.dispose();
    super.dispose();
  }

  void _handleLevelTap(int index) {
    if (widget.selectedIndex == index) {
      return;
    }

    widget.onLevelChanged(index);
  }

  void _handlePageChanged(int index) {
    if (widget.selectedIndex == index) {
      return;
    }

    widget.onLevelChanged(index);
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final palette = context.appPalette;
    final selectedIndex = widget.selectedIndex;

    return SurfaceCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          const SectionHeader(eyebrow: 'Poziomy', title: 'Poziomy gry'),
          const SizedBox(height: 18),
          Container(
            width: double.infinity,
            height: 170,
            padding: const EdgeInsets.fromLTRB(18, 16, 18, 14),
            decoration: BoxDecoration(
              gradient: LinearGradient(
                begin: Alignment.topLeft,
                end: Alignment.bottomRight,
                colors: <Color>[
                  widget.accent.withValues(alpha: 0.16),
                  palette.surfaceStrong,
                ],
              ),
              borderRadius: BorderRadius.circular(26),
              border: Border.all(color: widget.accent.withValues(alpha: 0.18)),
            ),
            child: Column(
              children: <Widget>[
                Expanded(
                  child: PageView.builder(
                    controller: _pageController,
                    itemCount: _splitLevelDefinitions.length,
                    physics: const BouncingScrollPhysics(),
                    onPageChanged: _handlePageChanged,
                    itemBuilder: (BuildContext context, int index) {
                      final level = _splitLevelDefinitions[index];
                      final isSelected = index == selectedIndex;

                      return GestureDetector(
                        onTap: () => _handleLevelTap(index),
                        child: Container(
                          key: ValueKey<String>(
                            'split-level-card-${level.level}',
                          ),
                          width: double.infinity,
                          padding: const EdgeInsets.all(18),
                          decoration: BoxDecoration(
                            color: palette.surface.withValues(alpha: 0.92),
                            borderRadius: BorderRadius.circular(22),
                            border: Border.all(
                              color: isSelected
                                  ? level.color.withValues(alpha: 0.42)
                                  : level.color.withValues(alpha: 0.24),
                            ),
                          ),
                          child: Center(
                            child: Text(
                              'Poziom ${level.level}',
                              textAlign: TextAlign.center,
                              style: theme.textTheme.titleLarge?.copyWith(
                                color: palette.primaryText,
                                fontWeight: FontWeight.w900,
                              ),
                            ),
                          ),
                        ),
                      );
                    },
                  ),
                ),
                const SizedBox(height: 12),
                Row(
                  mainAxisSize: MainAxisSize.min,
                  children: List<Widget>.generate(
                    _splitLevelDefinitions.length,
                    (int index) {
                      final bool selected = index == selectedIndex;
                      return AnimatedContainer(
                        duration: const Duration(milliseconds: 180),
                        margin: EdgeInsets.only(left: index == 0 ? 0 : 6),
                        width: selected ? 18 : 8,
                        height: 8,
                        decoration: BoxDecoration(
                          color: selected
                              ? widget.accent
                              : widget.accent.withValues(alpha: 0.24),
                          borderRadius: BorderRadius.circular(999),
                        ),
                      );
                    },
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class SplitDecisionTrainer extends StatefulWidget {
  const SplitDecisionTrainer({
    super.key,
    required this.accent,
    this.autoStart = false,
    this.fullscreenOnStart = false,
    this.immersiveLayout = false,
    this.autoExitOnFinish = false,
    this.initialLevelIndex = 0,
    this.showLauncherPreview = true,
    this.onSessionStarted,
  });

  final Color accent;
  final bool autoStart;
  final bool fullscreenOnStart;
  final bool immersiveLayout;
  final bool autoExitOnFinish;
  final int initialLevelIndex;
  final bool showLauncherPreview;
  final VoidCallback? onSessionStarted;

  @override
  State<SplitDecisionTrainer> createState() => _SplitDecisionTrainerState();
}

class _SplitDecisionTrainerState extends State<SplitDecisionTrainer> {
  static const int _sessionStartCountdownSeconds = 3;
  static const int _sessionSeconds = 120;
  static const String _splitSessionHistoryStorageKey =
      'split_decision_session_history_v1';

  final Random _random = Random();
  Timer? _countdownTimer;
  Timer? _sessionTimer;
  Timer? _stimulusTimer;
  Timer? _nextStimulusTimer;
  Timer? _ruleOverlayTimer;
  Timer? _finishExitTimer;
  late int _levelIndex;
  late int _sessionLevelIndex;
  bool _running = false;
  bool _finished = false;
  int? _countdownValue;
  int _remainingSeconds = _sessionSeconds;
  int _presented = 0;
  int _correctDecisions = 0;
  int _tapHits = 0;
  int _tapOpportunities = 0;
  int _errors = 0;
  int _streak = 0;
  int _bestStreak = 0;
  List<int> _reactionTimes = <int>[];
  _SplitRule _activeRule = _splitRules.first;
  _SplitStimulus? _currentStimulus;
  DateTime? _stimulusShownAt;
  DateTime? _nextRuleChangeAt;
  bool _stimulusVisible = false;
  bool _stimulusResolved = false;
  bool _showRuleOverlay = false;
  bool _historyExpanded = false;
  bool _historyLoaded = false;
  List<_SplitSessionRecord> _sessionHistory = <_SplitSessionRecord>[];
  String _feedback = 'Jedna zasada, jeden tap, żadnych wahań.';
  String _progressionStatus =
      'Zaczynasz od fundamentu i odblokowujesz kolejne poziomy wynikiem.';
  Color _feedbackTint = const Color(0xFF173A53);

  @override
  void initState() {
    super.initState();
    _levelIndex = _normalizedLevelIndex(widget.initialLevelIndex);
    _sessionLevelIndex = _levelIndex;
    _progressionStatus =
        'Aktualny poziom: ${_currentLevel.levelLabel} • ${_currentLevel.title}.';
    _loadStoredSessionHistory();
    if (widget.autoStart) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) {
          _startSessionWithCountdown();
        }
      });
    }
  }

  @override
  void didUpdateWidget(covariant SplitDecisionTrainer oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.initialLevelIndex == oldWidget.initialLevelIndex ||
        _running ||
        _isCountingDown) {
      return;
    }

    final nextIndex = _normalizedLevelIndex(widget.initialLevelIndex);
    setState(() {
      _levelIndex = nextIndex;
      _sessionLevelIndex = nextIndex;
      _progressionStatus =
          'Aktualny poziom: ${_currentLevel.levelLabel} • ${_currentLevel.title}.';
    });
  }

  int _normalizedLevelIndex(int index) {
    return max(0, min(index, _splitLevelDefinitions.length - 1));
  }

  bool get _isCountingDown => _countdownValue != null;

  String get _countdownLabel {
    final value = _countdownValue;
    if (value == null) {
      return '$_sessionStartCountdownSeconds';
    }
    return value == 0 ? 'START' : '$value';
  }

  _SplitLevelDefinition get _currentLevel =>
      _splitLevelDefinitions[_levelIndex];

  List<_SplitSessionDayGroup> get _dailyBestGroups {
    final Map<String, _SplitSessionRecord> bestByDateAndLevel =
        <String, _SplitSessionRecord>{};

    for (final record in _sessionHistory) {
      final key = '${record.dateKey}-${record.level}';
      final currentBest = bestByDateAndLevel[key];
      if (currentBest == null || _isBetterSessionRecord(record, currentBest)) {
        bestByDateAndLevel[key] = record;
      }
    }

    final Map<String, List<_SplitSessionRecord>> recordsByDate =
        <String, List<_SplitSessionRecord>>{};
    for (final record in bestByDateAndLevel.values) {
      recordsByDate.putIfAbsent(record.dateKey, () => <_SplitSessionRecord>[]);
      recordsByDate[record.dateKey]!.add(record);
    }

    final groups =
        recordsByDate.entries
            .map(
              (entry) => _SplitSessionDayGroup(
                dateKey: entry.key,
                records: entry.value
                  ..sort(
                    (_SplitSessionRecord a, _SplitSessionRecord b) =>
                        a.level.compareTo(b.level),
                  ),
              ),
            )
            .toList()
          ..sort(
            (_SplitSessionDayGroup a, _SplitSessionDayGroup b) =>
                b.dateKey.compareTo(a.dateKey),
          );
    return groups;
  }

  List<_SplitSessionRecord> get _todayBestRecords {
    final todayKey = _dateKeyFor(DateTime.now());
    for (final group in _dailyBestGroups) {
      if (group.dateKey == todayKey) {
        return group.records;
      }
    }
    return <_SplitSessionRecord>[];
  }

  List<_SplitRule> get _availableRules {
    return _splitRules
        .where(
          (_SplitRule rule) =>
              _currentLevel.allowedRuleKinds.contains(rule.kind),
        )
        .toList();
  }

  int get _accuracyPercent {
    if (_presented == 0) {
      return 0;
    }
    return ((_correctDecisions / _presented) * 100).round();
  }

  int get _points => _tapHits;

  int get _averageReactionMs {
    if (_reactionTimes.isEmpty) {
      return 0;
    }
    return (_reactionTimes.reduce((int a, int b) => a + b) /
            _reactionTimes.length)
        .round();
  }

  int _scaledPromotionErrorLimit(int baseLimit) {
    final scaled = ((baseLimit * _sessionSeconds) / 45).round();
    return max(baseLimit, scaled);
  }

  int get _stimulusDurationMs {
    final progress = (_sessionSeconds - _remainingSeconds) / _sessionSeconds;
    final duration =
        (_currentLevel.stimulusStartMs -
                ((_currentLevel.stimulusStartMs - _currentLevel.stimulusEndMs) *
                    progress))
            .round();
    return max(
      _currentLevel.stimulusEndMs,
      min(_currentLevel.stimulusStartMs, duration),
    );
  }

  Duration get _stimulusGap {
    final progress = (_sessionSeconds - _remainingSeconds) / _sessionSeconds;
    final rawMilliseconds =
        (_currentLevel.gapStartMs -
                ((_currentLevel.gapStartMs - _currentLevel.gapEndMs) *
                    progress))
            .round();
    final milliseconds = max(
      _currentLevel.gapEndMs,
      min(_currentLevel.gapStartMs, rawMilliseconds),
    );
    return Duration(milliseconds: milliseconds);
  }

  Duration get _currentRuleDuration {
    final progress = (_sessionSeconds - _remainingSeconds) / _sessionSeconds;
    final seconds =
        (_currentLevel.ruleWindowStartSeconds -
                ((_currentLevel.ruleWindowStartSeconds -
                        _currentLevel.ruleWindowEndSeconds) *
                    progress))
            .round();
    return Duration(
      seconds: max(
        _currentLevel.ruleWindowEndSeconds,
        min(_currentLevel.ruleWindowStartSeconds, seconds),
      ),
    );
  }

  int get _secondsToRuleChange {
    if (_nextRuleChangeAt == null) {
      return 0;
    }
    final remainingMs = _nextRuleChangeAt!
        .difference(DateTime.now())
        .inMilliseconds;
    if (remainingMs <= 0) {
      return 0;
    }
    return (remainingMs / 1000).ceil();
  }

  Duration get _ruleAnnouncementDelay {
    return widget.immersiveLayout
        ? const Duration(milliseconds: 950)
        : Duration.zero;
  }

  Future<void> _loadStoredSessionHistory() async {
    final preferences = await SharedPreferences.getInstance();
    final rawHistory = preferences.getString(_splitSessionHistoryStorageKey);

    if (!mounted) {
      return;
    }

    setState(() {
      _sessionHistory = _decodeStoredSessionHistory(rawHistory);
      _historyLoaded = true;
    });
  }

  List<_SplitSessionRecord> _decodeStoredSessionHistory(String? rawHistory) {
    if (rawHistory == null || rawHistory.isEmpty) {
      return <_SplitSessionRecord>[];
    }

    try {
      final decoded = jsonDecode(rawHistory);
      if (decoded is! List<dynamic>) {
        return <_SplitSessionRecord>[];
      }

      final history = <_SplitSessionRecord>[];
      for (final item in decoded) {
        if (item is! Map<dynamic, dynamic>) {
          continue;
        }

        try {
          history.add(
            _SplitSessionRecord.fromJson(Map<String, dynamic>.from(item)),
          );
        } on FormatException {
          continue;
        }
      }

      history.sort(
        (_SplitSessionRecord a, _SplitSessionRecord b) =>
            b.completedAtIso.compareTo(a.completedAtIso),
      );
      return history;
    } on FormatException {
      return <_SplitSessionRecord>[];
    }
  }

  Future<void> _persistSessionHistory(List<_SplitSessionRecord> history) async {
    final preferences = await SharedPreferences.getInstance();
    final encodedHistory = jsonEncode(
      history.map((_SplitSessionRecord record) => record.toJson()).toList(),
    );
    await preferences.setString(_splitSessionHistoryStorageKey, encodedHistory);
  }

  void _startSessionWithCountdown() {
    if (_running || _isCountingDown) {
      return;
    }

    widget.onSessionStarted?.call();
    _cancelTimers();

    setState(() {
      _finished = false;
      _countdownValue = _sessionStartCountdownSeconds;
      _remainingSeconds = _sessionSeconds;
      _presented = 0;
      _correctDecisions = 0;
      _tapHits = 0;
      _tapOpportunities = 0;
      _errors = 0;
      _streak = 0;
      _bestStreak = 0;
      _reactionTimes = <int>[];
      _currentStimulus = null;
      _stimulusShownAt = null;
      _nextRuleChangeAt = null;
      _stimulusVisible = false;
      _stimulusResolved = true;
      _showRuleOverlay = false;
      _feedback = 'Start za 3 sekundy. Przygotuj się na pierwszą zasadę.';
      _feedbackTint = widget.accent;
    });

    _countdownTimer = Timer.periodic(const Duration(seconds: 1), (Timer timer) {
      if (!mounted) {
        timer.cancel();
        return;
      }

      final currentCountdown = _countdownValue;
      if (currentCountdown == null) {
        timer.cancel();
        return;
      }

      if (currentCountdown <= 0) {
        timer.cancel();
        setState(() {
          _countdownValue = null;
        });
        _startSession();
        return;
      }

      setState(() {
        _countdownValue = currentCountdown - 1;
      });
    });
  }

  void _startSession() {
    _cancelTimers();
    final initialRule =
        _availableRules[_random.nextInt(_availableRules.length)];

    setState(() {
      _sessionLevelIndex = _levelIndex;
      _running = true;
      _finished = false;
      _countdownValue = null;
      _remainingSeconds = _sessionSeconds;
      _presented = 0;
      _correctDecisions = 0;
      _tapHits = 0;
      _tapOpportunities = 0;
      _errors = 0;
      _streak = 0;
      _bestStreak = 0;
      _reactionTimes = <int>[];
      _activeRule = initialRule;
      _currentStimulus = null;
      _stimulusShownAt = null;
      _nextRuleChangeAt = DateTime.now().add(_currentRuleDuration);
      _stimulusVisible = false;
      _stimulusResolved = false;
      _showRuleOverlay = widget.immersiveLayout;
      _feedback = 'Nowa zasada: ${initialRule.label}';
      _feedbackTint = widget.accent;
    });

    HapticFeedback.selectionClick();
    _announceRuleOverlay();

    _sessionTimer = Timer.periodic(const Duration(seconds: 1), (Timer timer) {
      if (!mounted) {
        return;
      }

      if (_remainingSeconds <= 1) {
        timer.cancel();
        _finishSession();
      } else {
        setState(() {
          _remainingSeconds -= 1;
        });
      }
    });

    _scheduleNextStimulus(_ruleAnnouncementDelay);
  }

  void _finishSession() {
    _sessionTimer?.cancel();
    _nextStimulusTimer?.cancel();

    if (_stimulusVisible && !_stimulusResolved && _currentStimulus != null) {
      final shouldTap = _activeRule.matches(_currentStimulus!);
      _resolveStimulus(
        correct: !shouldTap,
        feedback: shouldTap
            ? 'Pudło na końcówce. Trafiaj od razu w zgodny bodziec.'
            : 'Dobrze powstrzymane do końca rundy.',
        emitNegativeSignal: shouldTap,
        finishSession: true,
      );
      return;
    }

    _stimulusTimer?.cancel();
    setState(() {
      _running = false;
      _finished = true;
      _remainingSeconds = 0;
      _currentStimulus = null;
      _stimulusShownAt = null;
      _stimulusVisible = false;
      _stimulusResolved = true;
      _showRuleOverlay = false;
      _feedback = 'Koniec';
      _feedbackTint = const Color(0xFF173A53);
    });
    _completeSession();
    _scheduleFinishExit();
  }

  void _cancelTimers() {
    _countdownTimer?.cancel();
    _sessionTimer?.cancel();
    _stimulusTimer?.cancel();
    _nextStimulusTimer?.cancel();
    _ruleOverlayTimer?.cancel();
    _finishExitTimer?.cancel();
  }

  void _scheduleFinishExit() {
    _finishExitTimer?.cancel();
    if (!widget.autoExitOnFinish) {
      return;
    }

    _finishExitTimer = Timer(const Duration(seconds: 2), () {
      if (!mounted) {
        return;
      }
      Navigator.of(context).maybePop();
    });
  }

  void _announceRuleOverlay() {
    _ruleOverlayTimer?.cancel();
    if (!widget.immersiveLayout) {
      return;
    }

    setState(() {
      _showRuleOverlay = true;
    });

    _ruleOverlayTimer = Timer(const Duration(milliseconds: 900), () {
      if (!mounted) {
        return;
      }
      setState(() {
        _showRuleOverlay = false;
      });
    });
  }

  void _scheduleNextStimulus(Duration delay) {
    _nextStimulusTimer?.cancel();
    if (!_running) {
      return;
    }

    _nextStimulusTimer = Timer(delay, _presentStimulus);
  }

  void _presentStimulus() {
    if (!_running) {
      return;
    }

    final now = DateTime.now();
    if (_nextRuleChangeAt == null || !now.isBefore(_nextRuleChangeAt!)) {
      _switchRule();
      _scheduleNextStimulus(_ruleAnnouncementDelay);
      return;
    }

    final stimulus = _buildStimulusForRule(_activeRule);
    final shownAt = DateTime.now();
    final shouldTap = _activeRule.matches(stimulus);

    setState(() {
      _currentStimulus = stimulus;
      _stimulusShownAt = shownAt;
      _stimulusVisible = true;
      _stimulusResolved = false;
      _presented += 1;
      if (shouldTap) {
        _tapOpportunities += 1;
      }
    });

    _stimulusTimer?.cancel();
    _stimulusTimer = Timer(
      Duration(milliseconds: _stimulusDurationMs),
      _handleStimulusTimeout,
    );
  }

  void _switchRule() {
    final candidates = _availableRules
        .where((_SplitRule rule) => rule.kind != _activeRule.kind)
        .toList();
    final nextRule = candidates[_random.nextInt(candidates.length)];

    setState(() {
      _activeRule = nextRule;
      _nextRuleChangeAt = DateTime.now().add(_currentRuleDuration);
      _feedback = 'Nowa zasada: ${nextRule.label}';
      _feedbackTint = widget.accent;
    });

    HapticFeedback.selectionClick();
    _announceRuleOverlay();
  }

  _SplitStimulus _buildStimulusForRule(_SplitRule rule) {
    final shouldMatch = _random.nextDouble() < 0.42;

    return switch (rule.kind) {
      _SplitRuleKind.tapRed => _SplitStimulus.color(
        token: shouldMatch
            ? _SplitColorToken.red
            : _randomColor(excluding: _SplitColorToken.red),
      ),
      _SplitRuleKind.skipBlue => _SplitStimulus.color(
        token: shouldMatch
            ? _randomColor(excluding: _SplitColorToken.blue)
            : _SplitColorToken.blue,
      ),
      _SplitRuleKind.tapTriangle => _SplitStimulus.shape(
        token: shouldMatch
            ? _SplitShapeToken.triangle
            : _randomShape(excluding: _SplitShapeToken.triangle),
      ),
      _SplitRuleKind.skipCircle => _SplitStimulus.shape(
        token: shouldMatch
            ? _randomShape(excluding: _SplitShapeToken.circle)
            : _SplitShapeToken.circle,
      ),
      _SplitRuleKind.tapEven => _SplitStimulus.number(
        value: shouldMatch ? _randomEvenNumber() : _randomOddNumber(),
      ),
    };
  }

  _SplitColorToken _randomColor({_SplitColorToken? excluding}) {
    final options = _SplitColorToken.values
        .where((_SplitColorToken token) => token != excluding)
        .toList();
    return options[_random.nextInt(options.length)];
  }

  _SplitShapeToken _randomShape({_SplitShapeToken? excluding}) {
    final options = _SplitShapeToken.values
        .where((_SplitShapeToken token) => token != excluding)
        .toList();
    return options[_random.nextInt(options.length)];
  }

  int _randomEvenNumber() {
    const values = <int>[2, 4, 6, 8];
    return values[_random.nextInt(values.length)];
  }

  int _randomOddNumber() {
    const values = <int>[1, 3, 5, 7, 9];
    return values[_random.nextInt(values.length)];
  }

  void _handleStimulusTimeout() {
    if (!_running ||
        !_stimulusVisible ||
        _stimulusResolved ||
        _currentStimulus == null) {
      return;
    }

    final shouldTap = _activeRule.matches(_currentStimulus!);
    if (shouldTap) {
      _resolveStimulus(
        correct: false,
        feedback: 'Pudło. Trafiaj od razu, gdy bodziec spełnia regułę.',
        emitNegativeSignal: true,
      );
    } else {
      _resolveStimulus(
        correct: true,
        feedback: 'Dobrze powstrzymane. Trzymaj filtr.',
      );
    }
  }

  void _handleTap() {
    if (!_running ||
        !_stimulusVisible ||
        _stimulusResolved ||
        _currentStimulus == null) {
      return;
    }

    final shouldTap = _activeRule.matches(_currentStimulus!);
    if (shouldTap) {
      final reactionMs = _stimulusShownAt == null
          ? 0
          : DateTime.now().difference(_stimulusShownAt!).inMilliseconds;
      _resolveStimulus(
        correct: true,
        tapped: true,
        reactionMs: reactionMs,
        feedback: 'Trafienie. Szybko i czysto.',
        emitPositiveSignal: true,
      );
    } else {
      _resolveStimulus(
        correct: false,
        feedback: 'Fałszywy alarm. Nie dotykaj bodźców poza regułą.',
        emitNegativeSignal: true,
      );
    }
  }

  void _resolveStimulus({
    required bool correct,
    required String feedback,
    bool tapped = false,
    int? reactionMs,
    bool emitPositiveSignal = false,
    bool emitNegativeSignal = false,
    bool finishSession = false,
  }) {
    if (_stimulusResolved) {
      return;
    }

    _stimulusTimer?.cancel();

    final nextStreak = correct ? _streak + 1 : 0;
    final nextFeedbackTint = correct
        ? const Color(0xFF4C9B8F)
        : const Color(0xFFD46C4E);

    setState(() {
      if (correct) {
        _correctDecisions += 1;
        if (tapped) {
          _tapHits += 1;
        }
        _streak = nextStreak;
        _bestStreak = max(_bestStreak, nextStreak);
        if (reactionMs != null) {
          _reactionTimes = <int>[..._reactionTimes, reactionMs];
        }
      } else {
        _errors += 1;
        _streak = 0;
      }

      _feedback = feedback;
      _feedbackTint = nextFeedbackTint;
      _currentStimulus = null;
      _stimulusShownAt = null;
      _stimulusVisible = false;
      _stimulusResolved = true;

      if (finishSession) {
        _running = false;
        _finished = true;
        _remainingSeconds = 0;
      }
    });

    if (emitPositiveSignal) {
      SystemSound.play(SystemSoundType.click);
      HapticFeedback.lightImpact();
    }

    if (emitNegativeSignal) {
      SystemSound.play(SystemSoundType.alert);
      HapticFeedback.mediumImpact();
    }

    if (finishSession) {
      _completeSession();
      _scheduleFinishExit();
    }

    if (!finishSession && _running) {
      _scheduleNextStimulus(_stimulusGap);
    }
  }

  void _completeSession() {
    _updateAdaptiveLevel();
    _storeFinishedSessionResult();
  }

  void _updateAdaptiveLevel() {
    final nextIndex = _resolveAdaptiveLevelIndex();
    final nextLevel = _splitLevelDefinitions[nextIndex];
    final previousLevel = _splitLevelDefinitions[_levelIndex];

    setState(() {
      _levelIndex = nextIndex;
      _progressionStatus = switch (nextIndex.compareTo(
        _splitDecisionGlobalLevelIndex,
      )) {
        1 => 'Awans na ${nextLevel.levelLabel} • ${nextLevel.title}.',
        -1 =>
          'Powrót do ${nextLevel.levelLabel} • ${nextLevel.title}, żeby ustabilizować formę.',
        _ => 'Trzymasz ${nextLevel.levelLabel} • ${nextLevel.title}.',
      };
      if (nextIndex == _splitDecisionGlobalLevelIndex &&
          previousLevel.level != nextLevel.level) {
        _progressionStatus =
            'Aktualny poziom: ${nextLevel.levelLabel} • ${nextLevel.title}.';
      }
    });

    _splitDecisionGlobalLevelIndex = nextIndex;
  }

  Future<void> _storeFinishedSessionResult() async {
    if (_presented == 0) {
      return;
    }

    final completedAt = DateTime.now();
    final record = _SplitSessionRecord(
      dateKey: _dateKeyFor(completedAt),
      completedAtIso: completedAt.toIso8601String(),
      level: _sessionLevelIndex + 1,
      accuracyPercent: _accuracyPercent,
      averageReactionMs: _averageReactionMs,
      bestStreak: _bestStreak,
      correctDecisions: _correctDecisions,
      tapHits: _tapHits,
      tapOpportunities: _tapOpportunities,
      errors: _errors,
      presented: _presented,
    );

    final updatedHistory = <_SplitSessionRecord>[record, ..._sessionHistory]
      ..sort(
        (_SplitSessionRecord a, _SplitSessionRecord b) =>
            b.completedAtIso.compareTo(a.completedAtIso),
      );

    if (mounted) {
      setState(() {
        _sessionHistory = updatedHistory;
        _historyLoaded = true;
        _historyExpanded = true;
      });
    }

    await _persistSessionHistory(updatedHistory);
  }

  int _resolveAdaptiveLevelIndex() {
    var nextIndex = _levelIndex;
    final accuracy = _accuracyPercent;
    final averageReaction = _averageReactionMs;
    final severeDrop =
        accuracy <= 60 || _errors >= max(5, (_presented * 0.35).round());

    if (severeDrop && nextIndex > 0) {
      return nextIndex - 1;
    }

    final shouldPromote = switch (_currentLevel.level) {
      1 => accuracy >= 85 && _bestStreak >= 20,
      2 =>
        accuracy >= 86 &&
            averageReaction > 0 &&
            averageReaction <= 560 &&
            _errors <= _scaledPromotionErrorLimit(5),
      3 =>
        accuracy >= 88 &&
            _bestStreak >= 16 &&
            _errors <= _scaledPromotionErrorLimit(6),
      4 =>
        accuracy >= 90 &&
            averageReaction > 0 &&
            averageReaction <= 320 &&
            _errors <= _scaledPromotionErrorLimit(4),
      _ => false,
    };

    if (shouldPromote && nextIndex < _splitLevelDefinitions.length - 1) {
      nextIndex += 1;
    }

    return nextIndex;
  }

  Future<void> _openFullscreenSession() {
    return Navigator.of(context).push<void>(
      _buildExerciseSessionRoute<void>(
        builder: (BuildContext context) {
          return FullscreenTrainerPage(
            title: 'Split Decision',
            accent: widget.accent,
            expandBody: true,
            child: SplitDecisionTrainer(
              accent: widget.accent,
              autoStart: true,
              immersiveLayout: true,
              autoExitOnFinish: true,
              initialLevelIndex: _levelIndex,
              showLauncherPreview: widget.showLauncherPreview,
            ),
          );
        },
      ),
    );
  }

  Future<void> _handleStartAction() async {
    if (_isCountingDown) {
      return;
    }

    if (widget.fullscreenOnStart) {
      widget.onSessionStarted?.call();
      await _openFullscreenSession();
      if (mounted) {
        setState(() {
          _levelIndex = _splitDecisionGlobalLevelIndex;
          _progressionStatus =
              'Aktualny poziom: ${_currentLevel.levelLabel} • ${_currentLevel.title}.';
        });
        await _loadStoredSessionHistory();
      }
      return;
    }

    _startSessionWithCountdown();
  }

  void _selectLevel(int index) {
    if (_running ||
        _isCountingDown ||
        index < 0 ||
        index >= _splitLevelDefinitions.length ||
        index == _levelIndex) {
      return;
    }

    final selectedLevel = _splitLevelDefinitions[index];

    setState(() {
      _levelIndex = index;
      _splitDecisionGlobalLevelIndex = index;
      _progressionStatus =
          'Wybrany poziom startowy: ${selectedLevel.levelLabel} • ${selectedLevel.title}.';
    });

    HapticFeedback.selectionClick();
  }

  void _toggleHistoryExpanded() {
    setState(() {
      _historyExpanded = !_historyExpanded;
    });
  }

  Future<void> _handleHistoryRecordLongPress(_SplitSessionRecord record) async {
    final shouldDelete = await showDialog<bool>(
      context: context,
      builder: (BuildContext dialogContext) {
        final theme = Theme.of(dialogContext);

        return AlertDialog(
          title: const Text('Usunąć zapisany wynik?'),
          content: Text(
            'To usunie zapis poziomu ${record.level} z dnia ${_formatSessionDateLabel(record.dateKey)} wraz z pozostałymi rundami z tego dnia dla tego poziomu.',
            style: theme.textTheme.bodyMedium?.copyWith(height: 1.45),
          ),
          actions: <Widget>[
            TextButton(
              onPressed: () => Navigator.of(dialogContext).pop(false),
              child: const Text('Anuluj'),
            ),
            FilledButton(
              onPressed: () => Navigator.of(dialogContext).pop(true),
              child: const Text('Usuń'),
            ),
          ],
        );
      },
    );

    if (shouldDelete != true || !mounted) {
      return;
    }

    await _deleteHistoryLevelRecord(record);
  }

  Future<void> _deleteHistoryLevelRecord(_SplitSessionRecord record) async {
    final updatedHistory =
        _sessionHistory
            .where(
              (_SplitSessionRecord candidate) =>
                  candidate.dateKey != record.dateKey ||
                  candidate.level != record.level,
            )
            .toList()
          ..sort(
            (_SplitSessionRecord a, _SplitSessionRecord b) =>
                b.completedAtIso.compareTo(a.completedAtIso),
          );

    setState(() {
      _sessionHistory = updatedHistory;
      _historyLoaded = true;
    });

    await _persistSessionHistory(updatedHistory);
  }

  String _buildTodayBestSummary() {
    if (!_historyLoaded) {
      return 'Ładowanie zapisanych wyników...';
    }

    final todayRecords = _todayBestRecords;
    if (todayRecords.isEmpty) {
      return 'Dzisiaj nie ma jeszcze zapisanego rekordu.';
    }

    if (todayRecords.length == 1) {
      final todayBest = todayRecords.first;
      return 'Dzisiaj: poziom ${todayBest.level} • skuteczność decyzji ${todayBest.accuracyPercent}% • ${_buildSessionActionSummary(todayBest)}';
    }

    final levelList = todayRecords
        .map((_SplitSessionRecord record) => '${record.level}')
        .join(', ');
    return 'Dzisiaj zapisane poziomy: $levelList';
  }

  Widget _buildDailyBestPanel(ThemeData theme) {
    final dailyBestGroups = _dailyBestGroups;
    final palette = context.appPalette;

    return AnimatedSize(
      duration: const Duration(milliseconds: 180),
      curve: Curves.easeOut,
      child: Container(
        width: double.infinity,
        decoration: BoxDecoration(
          color: palette.surface,
          borderRadius: BorderRadius.circular(22),
          border: Border.all(color: palette.surfaceBorder),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            Material(
              color: Colors.transparent,
              child: InkWell(
                onTap: _toggleHistoryExpanded,
                borderRadius: BorderRadius.circular(22),
                child: Padding(
                  padding: const EdgeInsets.all(18),
                  child: Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: <Widget>[
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: <Widget>[
                            Text(
                              'Najlepsze wyniki dnia',
                              style: theme.textTheme.titleMedium?.copyWith(
                                color: palette.primaryText,
                                fontWeight: FontWeight.w800,
                              ),
                            ),
                            const SizedBox(height: 4),
                            Text(
                              _buildTodayBestSummary(),
                              style: theme.textTheme.bodyMedium?.copyWith(
                                color: palette.secondaryText,
                                height: 1.45,
                              ),
                            ),
                          ],
                        ),
                      ),
                      const SizedBox(width: 12),
                      AnimatedRotation(
                        duration: const Duration(milliseconds: 180),
                        turns: _historyExpanded ? 0.5 : 0,
                        child: Icon(
                          Icons.expand_more_rounded,
                          color: palette.primaryText,
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
            if (_historyExpanded)
              Padding(
                padding: const EdgeInsets.fromLTRB(18, 0, 18, 18),
                child: !_historyLoaded
                    ? const Padding(
                        padding: EdgeInsets.only(top: 8),
                        child: LinearProgressIndicator(minHeight: 3),
                      )
                    : dailyBestGroups.isEmpty
                    ? Text(
                        'Po pierwszej zakończonej rundzie rekord dnia zapisze się tutaj. Wyniki są rozdzielane osobno dla każdej daty i poziomu.',
                        style: theme.textTheme.bodyMedium?.copyWith(
                          color: palette.secondaryText,
                          height: 1.45,
                        ),
                      )
                    : Column(
                        children: <Widget>[
                          Padding(
                            padding: const EdgeInsets.only(bottom: 12),
                            child: Text(
                              'Przytrzymaj kafelek poziomu, żeby usunąć zapis z tego dnia.',
                              style: theme.textTheme.bodySmall?.copyWith(
                                color: palette.tertiaryText,
                                fontWeight: FontWeight.w700,
                                height: 1.4,
                              ),
                            ),
                          ),
                          for (
                            var i = 0;
                            i < dailyBestGroups.length;
                            i++
                          ) ...<Widget>[
                            _SplitDailyBestGroupCard(
                              group: dailyBestGroups[i],
                              highlight:
                                  dailyBestGroups[i].dateKey ==
                                  _dateKeyFor(DateTime.now()),
                              onLongPressRecord: _handleHistoryRecordLongPress,
                            ),
                            if (i != dailyBestGroups.length - 1)
                              const SizedBox(height: 10),
                          ],
                        ],
                      ),
              ),
          ],
        ),
      ),
    );
  }

  Future<void> _showLevelInfoSheet() {
    final maxHeight = MediaQuery.sizeOf(context).height * 0.82;

    return showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (BuildContext context) {
        final theme = Theme.of(context);
        final palette = context.appPalette;

        return SafeArea(
          top: false,
          child: Padding(
            padding: const EdgeInsets.fromLTRB(12, 0, 12, 12),
            child: Container(
              constraints: BoxConstraints(maxHeight: maxHeight),
              padding: const EdgeInsets.fromLTRB(18, 14, 18, 18),
              decoration: BoxDecoration(
                color: palette.surfaceStrong,
                borderRadius: const BorderRadius.vertical(
                  top: Radius.circular(28),
                ),
                border: Border.all(
                  color: widget.accent.withValues(alpha: 0.16),
                ),
              ),
              child: Column(
                children: <Widget>[
                  Container(
                    width: 48,
                    height: 4,
                    decoration: BoxDecoration(
                      color: palette.surfaceBorder,
                      borderRadius: BorderRadius.circular(999),
                    ),
                  ),
                  const SizedBox(height: 16),
                  Row(
                    children: <Widget>[
                      Expanded(
                        child: Text(
                          'Poziomy 1-5',
                          style: theme.textTheme.titleLarge?.copyWith(
                            color: palette.primaryText,
                            fontWeight: FontWeight.w800,
                          ),
                        ),
                      ),
                      IconButton(
                        onPressed: () => Navigator.of(context).pop(),
                        icon: const Icon(Icons.close_rounded),
                        tooltip: 'Zamknij',
                      ),
                    ],
                  ),
                  Text(
                    'Tutaj sprawdzisz, co zmienia się na kolejnych poziomach. Na ekranie startowym zostaje tylko wybór poziomu i przycisk startu.',
                    style: theme.textTheme.bodyMedium?.copyWith(
                      color: const Color(0xFF4A5761),
                      height: 1.45,
                    ),
                  ),
                  const SizedBox(height: 16),
                  Expanded(
                    child: ListView(
                      children: <Widget>[
                        for (final level in _splitLevelDefinitions) ...<Widget>[
                          _SplitLevelCard(
                            level: level,
                            active: level.level == _currentLevel.level,
                          ),
                          const SizedBox(height: 12),
                        ],
                        Container(
                          width: double.infinity,
                          padding: const EdgeInsets.all(16),
                          decoration: BoxDecoration(
                            color: const Color(0xFF102030),
                            borderRadius: BorderRadius.circular(20),
                          ),
                          child: Text(
                            'Wybrany poziom jest poziomem startowym. Po rundzie gra dalej może podnieść albo obniżyć trudność na podstawie wyniku.',
                            style: theme.textTheme.bodyMedium?.copyWith(
                              color: Colors.white.withValues(alpha: 0.84),
                              height: 1.45,
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
          ),
        );
      },
    );
  }

  Widget _buildLauncherPreview(ThemeData theme, bool compactWidth) {
    final blockGap = compactWidth ? 14.0 : 16.0;
    const previewRules = <String>[
      'Klikaj tylko czerwone',
      'Nie klikaj kół',
      'Klikaj tylko liczby parzyste',
    ];

    final palette = context.appPalette;
    return Container(
      width: double.infinity,
      padding: EdgeInsets.all(compactWidth ? 18 : 22),
      decoration: BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: <Color>[
            palette.surface,
            palette.surfaceStrong,
            widget.accent.withValues(alpha: 0.12),
          ],
        ),
        borderRadius: BorderRadius.circular(24),
        border: Border.all(color: widget.accent.withValues(alpha: 0.18)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
            decoration: BoxDecoration(
              color: widget.accent.withValues(alpha: 0.12),
              borderRadius: BorderRadius.circular(999),
            ),
            child: Text(
              'JAK ZAGRAĆ',
              style: theme.textTheme.labelLarge?.copyWith(
                color: widget.accent,
                fontWeight: FontWeight.w900,
                letterSpacing: 0.9,
              ),
            ),
          ),
          SizedBox(height: blockGap),
          Text(
            'Pełny ekran, 2 minuty i zmiana zasad co 12 sekund.',
            style: theme.textTheme.titleLarge?.copyWith(
              color: palette.primaryText,
              fontWeight: FontWeight.w800,
            ),
          ),
          const SizedBox(height: 8),
          Text(
            'Tapnij start, a potem dotykaj ekranu tylko wtedy, gdy bodziec spełnia aktualną regułę.',
            style: theme.textTheme.bodyLarge?.copyWith(
              color: palette.secondaryText,
            ),
          ),
          SizedBox(height: blockGap),
          _buildCurrentLevelCard(theme),
          SizedBox(height: blockGap),
          _buildLevelSelector(theme, compactWidth),
          SizedBox(height: blockGap),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: const <Widget>[
              _SplitLaunchStep(label: '1. Czytaj zasadę'),
              _SplitLaunchStep(label: '2. Tapnij tylko zgodne'),
              _SplitLaunchStep(label: '3. Przełącz filtr po zmianie'),
            ],
          ),
          SizedBox(height: blockGap),
          Container(
            width: double.infinity,
            padding: const EdgeInsets.all(18),
            decoration: BoxDecoration(
              gradient: LinearGradient(
                begin: Alignment.topLeft,
                end: Alignment.bottomRight,
                colors: <Color>[
                  palette.fullscreenStart,
                  palette.fullscreenMiddle,
                  palette.fullscreenEnd,
                ],
              ),
              borderRadius: BorderRadius.circular(22),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                Text(
                  'Przykładowe reguły w rundzie',
                  style: theme.textTheme.labelLarge?.copyWith(
                    color: Colors.white.withValues(alpha: 0.86),
                    fontWeight: FontWeight.w800,
                    letterSpacing: 0.8,
                  ),
                ),
                const SizedBox(height: 12),
                Wrap(
                  spacing: 8,
                  runSpacing: 8,
                  children: previewRules
                      .map(
                        (String label) => Container(
                          padding: const EdgeInsets.symmetric(
                            horizontal: 12,
                            vertical: 10,
                          ),
                          decoration: BoxDecoration(
                            color: Colors.white.withValues(alpha: 0.12),
                            borderRadius: BorderRadius.circular(16),
                            border: Border.all(
                              color: Colors.white.withValues(alpha: 0.14),
                            ),
                          ),
                          child: Text(
                            label,
                            style: theme.textTheme.bodyMedium?.copyWith(
                              color: Colors.white,
                              fontWeight: FontWeight.w700,
                            ),
                          ),
                        ),
                      )
                      .toList(),
                ),
              ],
            ),
          ),
          SizedBox(height: blockGap),
          SizedBox(
            width: double.infinity,
            child: FilledButton(
              onPressed: _handleStartAction,
              child: const Text('Start sesji'),
            ),
          ),
          const SizedBox(height: 8),
          Text(
            'Po starcie sesja otworzy się od razu na całym ekranie.',
            style: theme.textTheme.bodyMedium?.copyWith(
              color: palette.tertiaryText,
            ),
          ),
          SizedBox(height: blockGap),
          _buildDailyBestPanel(theme),
        ],
      ),
    );
  }

  Widget _buildCurrentLevelCard(ThemeData theme) {
    final palette = context.appPalette;
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(18),
      decoration: BoxDecoration(
        color: palette.surface,
        borderRadius: BorderRadius.circular(22),
        border: Border.all(color: _currentLevel.color.withValues(alpha: 0.18)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Row(
            children: <Widget>[
              Container(
                padding: const EdgeInsets.symmetric(
                  horizontal: 12,
                  vertical: 8,
                ),
                decoration: BoxDecoration(
                  color: _currentLevel.color.withValues(alpha: 0.12),
                  borderRadius: BorderRadius.circular(999),
                ),
                child: Text(
                  _currentLevel.levelLabel,
                  style: theme.textTheme.labelLarge?.copyWith(
                    color: _currentLevel.color,
                    fontWeight: FontWeight.w900,
                    letterSpacing: 0.8,
                  ),
                ),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: Text(
                  _currentLevel.title,
                  style: theme.textTheme.titleMedium?.copyWith(
                    color: palette.primaryText,
                    fontWeight: FontWeight.w800,
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 12),
          Text(
            _progressionStatus,
            style: theme.textTheme.bodyMedium?.copyWith(
              color: palette.secondaryText,
              height: 1.45,
            ),
          ),
          const SizedBox(height: 10),
          Text(
            'Tempo: ${_currentLevel.tempoLabel} • Zmiana zasad: ${_currentLevel.ruleLabel}',
            style: theme.textTheme.bodyMedium?.copyWith(
              color: palette.primaryText,
              fontWeight: FontWeight.w700,
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildLevelSelector(ThemeData theme, bool compactWidth) {
    final palette = context.appPalette;
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(18),
      decoration: BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: <Color>[
            widget.accent.withValues(alpha: 0.16),
            palette.surfaceStrong,
          ],
        ),
        borderRadius: BorderRadius.circular(26),
        border: Border.all(color: widget.accent.withValues(alpha: 0.18)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: <Widget>[
                    Text(
                      'Wybierz poziom startowy',
                      style: theme.textTheme.titleMedium?.copyWith(
                        color: palette.primaryText,
                        fontWeight: FontWeight.w800,
                      ),
                    ),
                    const SizedBox(height: 4),
                    Text(
                      'Wybierz poziom 1-5. Pełny opis poziomów jest pod znakiem zapytania.',
                      style: theme.textTheme.bodyMedium?.copyWith(
                        color: palette.secondaryText,
                        height: 1.45,
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(width: 12),
              Tooltip(
                message: 'Opis poziomów',
                child: Material(
                  color: Colors.transparent,
                  child: InkWell(
                    onTap: _showLevelInfoSheet,
                    borderRadius: BorderRadius.circular(999),
                    child: Ink(
                      width: 42,
                      height: 42,
                      decoration: BoxDecoration(
                        color: palette.surface,
                        shape: BoxShape.circle,
                        border: Border.all(
                          color: widget.accent.withValues(alpha: 0.22),
                        ),
                      ),
                      child: Icon(
                        Icons.question_mark_rounded,
                        color: palette.primaryText,
                        size: 20,
                      ),
                    ),
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 14),
          Text(
            'Poziomy są ułożone jak osobne ścieżki wejścia. Wybierasz poziom startowy, a gra dalej sama może podnieść albo obniżyć trudność.',
            style: theme.textTheme.bodyMedium?.copyWith(
              color: palette.secondaryText,
              height: 1.45,
            ),
          ),
          const SizedBox(height: 16),
          Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: List<Widget>.generate(_splitLevelDefinitions.length, (
              int index,
            ) {
              final level = _splitLevelDefinitions[index];

              return Padding(
                padding: EdgeInsets.only(
                  bottom: index == _splitLevelDefinitions.length - 1 ? 0 : 10,
                ),
                child: _SplitLevelPickerButton(
                  level: level,
                  selected: index == _levelIndex,
                  compact: compactWidth,
                  onTap: _running ? null : () => _selectLevel(index),
                ),
              );
            }),
          ),
        ],
      ),
    );
  }

  Widget _buildStimulusDisplay(ThemeData theme) {
    if (_isCountingDown) {
      return Column(
        key: ValueKey<String>('split-countdown-$_countdownLabel'),
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          SizedBox(
            width: double.infinity,
            child: FittedBox(
              fit: BoxFit.scaleDown,
              child: Text(
                _countdownLabel,
                maxLines: 1,
                softWrap: false,
                style: theme.textTheme.displaySmall?.copyWith(
                  fontSize: _countdownLabel == 'START' ? 58 : 108,
                  color: const Color(0xFFF0C674),
                  fontWeight: FontWeight.w900,
                  letterSpacing: _countdownLabel == 'START' ? 0.6 : 0.0,
                ),
                textAlign: TextAlign.center,
              ),
            ),
          ),
        ],
      );
    }

    if (!_stimulusVisible || _currentStimulus == null) {
      if (_running) {
        return const SizedBox.shrink();
      }

      if (_finished) {
        return Container(
          key: const ValueKey<String>('split-finished'),
          padding: const EdgeInsets.symmetric(horizontal: 34, vertical: 22),
          decoration: BoxDecoration(
            color: Colors.white.withValues(alpha: 0.1),
            borderRadius: BorderRadius.circular(26),
            border: Border.all(color: Colors.white.withValues(alpha: 0.14)),
          ),
          child: Text(
            'Koniec',
            style: theme.textTheme.headlineMedium?.copyWith(
              color: Colors.white,
              fontWeight: FontWeight.w900,
              letterSpacing: 1.0,
            ),
          ),
        );
      }

      return Column(
        key: const ValueKey<String>('split-idle'),
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          Text(
            'READY',
            style: theme.textTheme.headlineMedium?.copyWith(
              color: Colors.white,
              fontWeight: FontWeight.w900,
              letterSpacing: 1.2,
            ),
          ),
          if (!_finished &&
              (widget.showLauncherPreview ||
                  !widget.fullscreenOnStart)) ...<Widget>[
            const SizedBox(height: 10),
            Text(
              'Uruchom serię i reaguj bez zawahania.',
              textAlign: TextAlign.center,
              style: theme.textTheme.bodyLarge?.copyWith(
                color: Colors.white.withValues(alpha: 0.76),
              ),
            ),
          ],
        ],
      );
    }

    final stimulus = _currentStimulus!;
    return switch (stimulus.kind) {
      _SplitStimulusKind.color => _buildColorStimulus(theme, stimulus),
      _SplitStimulusKind.shape => _buildShapeStimulus(theme, stimulus),
      _SplitStimulusKind.number => _buildNumberStimulus(theme, stimulus),
    };
  }

  Widget _buildCompactRuleHud(ThemeData theme) {
    return IgnorePointer(
      child: AnimatedOpacity(
        duration: const Duration(milliseconds: 180),
        opacity: _showRuleOverlay ? 0 : 1,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            Container(
              constraints: const BoxConstraints(maxWidth: 260),
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 11),
              decoration: BoxDecoration(
                color: Colors.black.withValues(alpha: 0.28),
                borderRadius: BorderRadius.circular(20),
                border: Border.all(color: Colors.white.withValues(alpha: 0.12)),
              ),
              child: Text(
                _activeRule.label,
                textAlign: TextAlign.center,
                style: theme.textTheme.titleMedium?.copyWith(
                  color: Colors.white,
                  fontWeight: FontWeight.w800,
                  height: 1.2,
                ),
              ),
            ),
            const SizedBox(height: 10),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
              decoration: BoxDecoration(
                color: Colors.black.withValues(alpha: 0.22),
                borderRadius: BorderRadius.circular(999),
              ),
              child: Text(
                'Zm. za $_secondsToRuleChange s',
                style: theme.textTheme.bodySmall?.copyWith(
                  color: Colors.white.withValues(alpha: 0.74),
                  fontWeight: FontWeight.w700,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildRuleOverlay(ThemeData theme) {
    return IgnorePointer(
      child: AnimatedOpacity(
        duration: const Duration(milliseconds: 180),
        opacity: _showRuleOverlay ? 1 : 0,
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 22, vertical: 18),
          decoration: BoxDecoration(
            color: const Color(0xFF102030).withValues(alpha: 0.9),
            borderRadius: BorderRadius.circular(26),
            border: Border.all(color: Colors.white.withValues(alpha: 0.14)),
            boxShadow: <BoxShadow>[
              BoxShadow(
                color: widget.accent.withValues(alpha: 0.24),
                blurRadius: 28,
                offset: const Offset(0, 16),
              ),
            ],
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: <Widget>[
              Text(
                _activeRule.label,
                textAlign: TextAlign.center,
                style: theme.textTheme.headlineMedium?.copyWith(
                  color: Colors.white,
                  fontWeight: FontWeight.w900,
                ),
              ),
              const SizedBox(height: 10),
              Text(
                'Zm. za $_secondsToRuleChange s',
                textAlign: TextAlign.center,
                style: theme.textTheme.bodyLarge?.copyWith(
                  color: Colors.white.withValues(alpha: 0.76),
                  fontWeight: FontWeight.w700,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildColorStimulus(ThemeData theme, _SplitStimulus stimulus) {
    final token = stimulus.colorToken!;
    return Column(
      key: ValueKey<String>('split-color-${token.name}-$_presented'),
      mainAxisSize: MainAxisSize.min,
      children: <Widget>[
        Container(
          width: 176,
          height: 176,
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            color: token.color,
            boxShadow: <BoxShadow>[
              BoxShadow(
                color: token.color.withValues(alpha: 0.34),
                blurRadius: 34,
                offset: const Offset(0, 18),
              ),
            ],
          ),
        ),
        const SizedBox(height: 18),
        Text(
          token.label,
          style: theme.textTheme.titleLarge?.copyWith(
            color: Colors.white,
            fontWeight: FontWeight.w800,
            letterSpacing: 1.6,
          ),
        ),
      ],
    );
  }

  Widget _buildShapeStimulus(ThemeData theme, _SplitStimulus stimulus) {
    final token = stimulus.shapeToken!;
    return Column(
      key: ValueKey<String>('split-shape-${token.name}-$_presented'),
      mainAxisSize: MainAxisSize.min,
      children: <Widget>[
        Icon(token.icon, size: 172, color: Colors.white),
        const SizedBox(height: 14),
        Text(
          token.label,
          style: theme.textTheme.titleLarge?.copyWith(
            color: Colors.white,
            fontWeight: FontWeight.w800,
            letterSpacing: 1.4,
          ),
        ),
      ],
    );
  }

  Widget _buildNumberStimulus(ThemeData theme, _SplitStimulus stimulus) {
    final number = stimulus.number!;
    return Column(
      key: ValueKey<String>('split-number-$number-$_presented'),
      mainAxisSize: MainAxisSize.min,
      children: <Widget>[
        Text(
          '$number',
          style: theme.textTheme.displaySmall?.copyWith(
            fontSize: 108,
            color: const Color(0xFFF0C674),
            fontWeight: FontWeight.w900,
          ),
        ),
        const SizedBox(height: 10),
        Text(
          'LICZBA',
          style: theme.textTheme.titleLarge?.copyWith(
            color: Colors.white,
            fontWeight: FontWeight.w800,
            letterSpacing: 1.6,
          ),
        ),
      ],
    );
  }

  @override
  void dispose() {
    _cancelTimers();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final hideSupportInfo = widget.immersiveLayout && _running;
    final showAutoExitFinishView = _finished && widget.autoExitOnFinish;
    final showImmersiveWaitingState =
        hideSupportInfo &&
        !_showRuleOverlay &&
        (!_stimulusVisible || _currentStimulus == null);

    return LayoutBuilder(
      builder: (BuildContext context, BoxConstraints constraints) {
        final viewportSize = MediaQuery.sizeOf(context);
        final availableWidth = constraints.maxWidth.isFinite
            ? constraints.maxWidth
            : viewportSize.width;
        final availableHeight = constraints.maxHeight.isFinite
            ? constraints.maxHeight
            : viewportSize.height;
        final compactWidth = availableWidth < 360;
        final compactHeight = availableHeight < 760;
        final statSpacing = compactWidth ? 8.0 : 10.0;
        final launcherPreview =
            widget.showLauncherPreview &&
            widget.fullscreenOnStart &&
            !widget.immersiveLayout &&
            !_running;
        final sectionGap = widget.immersiveLayout
            ? (compactHeight ? 10.0 : 12.0)
            : (compactHeight ? 14.0 : 18.0);
        final panelPadding = widget.immersiveLayout
            ? (compactWidth ? 14.0 : 16.0)
            : (compactWidth ? 18.0 : 24.0);
        final ruleCardPadding = compactWidth
            ? const EdgeInsets.symmetric(horizontal: 14, vertical: 12)
            : const EdgeInsets.symmetric(horizontal: 16, vertical: 14);
        final playfieldMinHeight = widget.immersiveLayout
            ? _running
                  ? (compactHeight ? 380.0 : 450.0)
                  : (compactHeight ? 180.0 : 220.0)
            : (compactHeight ? 240.0 : 300.0);
        final immersiveContentTopInset = compactHeight ? 160.0 : 184.0;

        final ruleTag = Container(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
          decoration: BoxDecoration(
            color: Colors.white.withValues(alpha: 0.76),
            borderRadius: BorderRadius.circular(16),
          ),
          child: Text(
            _isCountingDown
                ? _countdownLabel
                : _running
                ? 'ZM. ZA $_secondsToRuleChange s'
                : 'TAP',
            style: theme.textTheme.labelLarge?.copyWith(
              color: widget.accent,
              fontWeight: FontWeight.w900,
              letterSpacing: 0.8,
            ),
          ),
        );

        final showSupportInfo =
            !hideSupportInfo &&
            !widget.immersiveLayout &&
            !showAutoExitFinishView &&
            widget.showLauncherPreview;
        final summaryPills = <Widget>[
          _SplitSummaryPill(
            label: 'Błędy',
            value: '$_errors',
            tint: widget.accent,
          ),
          _SplitSummaryPill(
            label: 'Śr. reakcja',
            value: _averageReactionMs == 0 ? '--' : '$_averageReactionMs ms',
            tint: widget.accent,
          ),
          _SplitSummaryPill(
            label: 'Bodźce',
            value: '$_presented',
            tint: widget.accent,
          ),
          _SplitSummaryPill(
            label: 'Naj. seria',
            value: '$_bestStreak',
            tint: widget.accent,
          ),
        ];
        final playfield = GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTap: _handleTap,
          child: AnimatedContainer(
            duration: const Duration(milliseconds: 120),
            width: double.infinity,
            height: widget.immersiveLayout ? null : playfieldMinHeight,
            clipBehavior: Clip.antiAlias,
            constraints: BoxConstraints(minHeight: playfieldMinHeight),
            decoration: BoxDecoration(
              gradient: const LinearGradient(
                begin: Alignment.topLeft,
                end: Alignment.bottomRight,
                colors: <Color>[
                  Color(0xFF0E1721),
                  Color(0xFF183048),
                  Color(0xFF101D28),
                ],
              ),
              borderRadius: BorderRadius.circular(28),
              border: Border.all(
                color: _feedbackTint.withValues(alpha: 0.34),
                width: 2,
              ),
              boxShadow: <BoxShadow>[
                BoxShadow(
                  color: _feedbackTint.withValues(alpha: 0.16),
                  blurRadius: 24,
                  offset: const Offset(0, 14),
                ),
              ],
            ),
            child: Stack(
              children: <Widget>[
                Positioned.fill(
                  child: Padding(
                    padding: hideSupportInfo
                        ? EdgeInsets.fromLTRB(
                            18,
                            immersiveContentTopInset,
                            18,
                            18,
                          )
                        : EdgeInsets.zero,
                    child: Align(
                      alignment: Alignment.center,
                      child: AnimatedSwitcher(
                        duration: const Duration(milliseconds: 130),
                        child: _showRuleOverlay || showImmersiveWaitingState
                            ? const SizedBox.shrink()
                            : _buildStimulusDisplay(theme),
                      ),
                    ),
                  ),
                ),
                if (hideSupportInfo)
                  Positioned(
                    top: 18,
                    left: 18,
                    right: 18,
                    child: Center(
                      child: AnimatedSwitcher(
                        duration: const Duration(milliseconds: 160),
                        child: _showRuleOverlay
                            ? ConstrainedBox(
                                key: const ValueKey<String>(
                                  'split-rule-overlay',
                                ),
                                constraints: const BoxConstraints(
                                  maxWidth: 280,
                                ),
                                child: _buildRuleOverlay(theme),
                              )
                            : _buildCompactRuleHud(theme),
                      ),
                    ),
                  ),
              ],
            ),
          ),
        );
        if (!widget.showLauncherPreview && !widget.immersiveLayout) {
          return Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              Row(
                children: <Widget>[
                  Expanded(
                    child: _SplitTopStat(
                      label: 'Czas',
                      value: '${_remainingSeconds}s',
                      tint: widget.accent,
                      compact: compactWidth,
                    ),
                  ),
                  SizedBox(width: statSpacing),
                  Expanded(
                    child: _SplitTopStat(
                      label: 'Punkty',
                      value: '$_points',
                      tint: widget.accent,
                      compact: compactWidth,
                    ),
                  ),
                ],
              ),
              SizedBox(height: sectionGap),
              playfield,
              if (!_running &&
                  !_isCountingDown &&
                  !showAutoExitFinishView) ...<Widget>[
                SizedBox(height: sectionGap),
                Center(
                  child: ConstrainedBox(
                    constraints: const BoxConstraints(maxWidth: 240),
                    child: SizedBox(
                      width: double.infinity,
                      child: FilledButton(
                        onPressed: _handleStartAction,
                        child: Text(
                          _finished ? 'Zagraj ponownie' : 'Start sesji',
                        ),
                      ),
                    ),
                  ),
                ),
              ],
            ],
          );
        }
        final ruleCard = Container(
          width: double.infinity,
          padding: ruleCardPadding,
          decoration: BoxDecoration(
            color: widget.accent.withValues(alpha: 0.1),
            borderRadius: BorderRadius.circular(20),
          ),
          child: compactWidth
              ? Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: <Widget>[
                    Text(
                      'Aktualna zasada',
                      style: theme.textTheme.labelLarge?.copyWith(
                        color: const Color(0xFF4A5761),
                        fontWeight: FontWeight.w800,
                        letterSpacing: 0.8,
                      ),
                    ),
                    const SizedBox(height: 6),
                    Text(
                      _activeRule.label,
                      style: theme.textTheme.titleLarge?.copyWith(
                        color: const Color(0xFF16212B),
                        fontWeight: FontWeight.w800,
                      ),
                    ),
                    const SizedBox(height: 12),
                    ruleTag,
                  ],
                )
              : Row(
                  children: <Widget>[
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: <Widget>[
                          Text(
                            'Aktualna zasada',
                            style: theme.textTheme.labelLarge?.copyWith(
                              color: const Color(0xFF4A5761),
                              fontWeight: FontWeight.w800,
                              letterSpacing: 0.8,
                            ),
                          ),
                          const SizedBox(height: 6),
                          Text(
                            _activeRule.label,
                            style: theme.textTheme.titleLarge?.copyWith(
                              color: const Color(0xFF16212B),
                              fontWeight: FontWeight.w800,
                            ),
                          ),
                        ],
                      ),
                    ),
                    const SizedBox(width: 12),
                    ruleTag,
                  ],
                ),
        );
        final panel = Container(
          width: double.infinity,
          clipBehavior: Clip.antiAlias,
          padding: EdgeInsets.all(panelPadding),
          decoration: BoxDecoration(
            color: const Color(0xFFF9F5EF),
            borderRadius: BorderRadius.circular(26),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              if (launcherPreview)
                _buildLauncherPreview(theme, compactWidth)
              else ...<Widget>[
                if (showSupportInfo) ...<Widget>[
                  ruleCard,
                  SizedBox(height: sectionGap),
                ],
                if (widget.immersiveLayout)
                  Expanded(child: playfield)
                else
                  playfield,
                if (showSupportInfo) ...<Widget>[
                  SizedBox(height: sectionGap),
                  Text(
                    _feedback,
                    style: theme.textTheme.bodyLarge?.copyWith(
                      color: const Color(0xFF24303A),
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                  const SizedBox(height: 8),
                  Text(
                    _running
                        ? 'Tapnij ekran tylko wtedy, gdy bodziec spełnia aktualną regułę. Skuteczność liczy też poprawne odpuszczenia.'
                        : _isCountingDown
                        ? 'Za chwilę rusza runda. Poczekaj na pierwszy bodziec i dopiero wtedy reaguj.'
                        : _finished
                        ? 'Wynik tej rundy został zapisany i zostanie po ponownym uruchomieniu aplikacji.'
                        : 'Reguła zmienia się co 12 sekund, a na wyższych levelach bodźce lecą szybciej.',
                    style: theme.textTheme.bodyMedium?.copyWith(
                      color: const Color(0xFF63717C),
                    ),
                  ),
                  const SizedBox(height: 16),
                  Wrap(spacing: 10, runSpacing: 10, children: summaryPills),
                ],
              ],
            ],
          ),
        );

        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            Row(
              children: <Widget>[
                Expanded(
                  child: _SplitTopStat(
                    label: 'Czas',
                    value: '${_remainingSeconds}s',
                    tint: widget.accent,
                    compact: compactWidth,
                  ),
                ),
                SizedBox(width: statSpacing),
                Expanded(
                  child: _SplitTopStat(
                    label: 'Punkty',
                    value: '$_points',
                    tint: widget.accent,
                    compact: compactWidth,
                  ),
                ),
              ],
            ),
            SizedBox(height: sectionGap),
            if (widget.immersiveLayout) Expanded(child: panel) else panel,
            if (!_running &&
                !launcherPreview &&
                !_isCountingDown &&
                !showAutoExitFinishView) ...<Widget>[
              SizedBox(height: sectionGap),
              Center(
                child: ConstrainedBox(
                  constraints: const BoxConstraints(maxWidth: 240),
                  child: SizedBox(
                    width: double.infinity,
                    child: FilledButton(
                      onPressed: _handleStartAction,
                      child: Text(
                        _finished ? 'Zagraj ponownie' : 'Start sesji',
                      ),
                    ),
                  ),
                ),
              ),
            ],
            if (widget.showLauncherPreview &&
                !_running &&
                !launcherPreview &&
                (!widget.immersiveLayout || _finished) &&
                !showAutoExitFinishView) ...<Widget>[
              SizedBox(height: sectionGap),
              _buildDailyBestPanel(theme),
            ],
          ],
        );
      },
    );
  }
}

enum _SplitRuleKind { tapRed, skipBlue, tapTriangle, skipCircle, tapEven }

enum _SplitStimulusKind { color, shape, number }

class _SplitRule {
  const _SplitRule({required this.kind, required this.label});

  final _SplitRuleKind kind;
  final String label;

  bool matches(_SplitStimulus stimulus) {
    return switch (kind) {
      _SplitRuleKind.tapRed => stimulus.colorToken == _SplitColorToken.red,
      _SplitRuleKind.skipBlue => stimulus.colorToken != _SplitColorToken.blue,
      _SplitRuleKind.tapTriangle =>
        stimulus.shapeToken == _SplitShapeToken.triangle,
      _SplitRuleKind.skipCircle =>
        stimulus.shapeToken != _SplitShapeToken.circle,
      _SplitRuleKind.tapEven => (stimulus.number ?? 1).isEven,
    };
  }
}

const List<_SplitRule> _splitRules = <_SplitRule>[
  _SplitRule(kind: _SplitRuleKind.tapRed, label: 'Klikaj tylko czerwone'),
  _SplitRule(kind: _SplitRuleKind.skipBlue, label: 'Nie klikaj niebieskiego'),
  _SplitRule(kind: _SplitRuleKind.tapTriangle, label: 'Klikaj tylko trójkąty'),
  _SplitRule(kind: _SplitRuleKind.skipCircle, label: 'Nie klikaj kół'),
  _SplitRule(
    kind: _SplitRuleKind.tapEven,
    label: 'Klikaj tylko liczby parzyste',
  ),
];

int _splitDecisionGlobalLevelIndex = 0;

class _SplitLevelDefinition {
  const _SplitLevelDefinition({
    required this.level,
    required this.polishName,
    required this.title,
    required this.goal,
    required this.settings,
    required this.effects,
    required this.note,
    required this.unlockLabel,
    required this.tempoLabel,
    required this.ruleLabel,
    required this.stimulusStartMs,
    required this.stimulusEndMs,
    required this.gapStartMs,
    required this.gapEndMs,
    required this.ruleWindowStartSeconds,
    required this.ruleWindowEndSeconds,
    required this.allowedRuleKinds,
    required this.color,
  });

  final int level;
  final String polishName;
  final String title;
  final String goal;
  final List<String> settings;
  final List<String> effects;
  final String note;
  final String unlockLabel;
  final String tempoLabel;
  final String ruleLabel;
  final int stimulusStartMs;
  final int stimulusEndMs;
  final int gapStartMs;
  final int gapEndMs;
  final int ruleWindowStartSeconds;
  final int ruleWindowEndSeconds;
  final List<_SplitRuleKind> allowedRuleKinds;
  final Color color;

  String get levelLabel => 'Level $level';
}

const List<_SplitLevelDefinition>
_splitLevelDefinitions = <_SplitLevelDefinition>[
  _SplitLevelDefinition(
    level: 1,
    polishName: 'Stabilność',
    title: 'Beginner',
    goal: 'Nauczyć mózg zasad, kontroli impulsu i podstawowej reakcji.',
    settings: <String>[
      'Tempo: 700-900 ms',
      'Jedna prosta zasada naraz',
      'Zmiana zasad co 12 s',
    ],
    effects: <String>[
      'Łapiesz system i budujesz kontrolę',
      'Bez tego fundamentu wszystko rozpadnie się później',
    ],
    note: 'Foundation pod czyste wejście w trening.',
    unlockLabel: 'Awans: accuracy > 85% i streak > 20',
    tempoLabel: '700-900 ms',
    ruleLabel: '12 s',
    stimulusStartMs: 900,
    stimulusEndMs: 700,
    gapStartMs: 180,
    gapEndMs: 140,
    ruleWindowStartSeconds: 12,
    ruleWindowEndSeconds: 12,
    allowedRuleKinds: <_SplitRuleKind>[
      _SplitRuleKind.tapRed,
      _SplitRuleKind.tapTriangle,
    ],
    color: Color(0xFF4C9B8F),
  ),
  _SplitLevelDefinition(
    level: 2,
    polishName: 'Płynność',
    title: 'Focused',
    goal: 'Wejść w rytm i pierwsze przyspieszenie bez gubienia reguły.',
    settings: <String>[
      'Tempo: 500-700 ms',
      'Zmiana zasad co 12 s',
      'Dochodzi prosta negacja: nie klikaj X',
    ],
    effects: <String>[
      'Mózg przestaje się zastanawiać',
      'Zaczyna reagować szybciej i płynniej',
    ],
    note: 'Tu zaczyna się flow.',
    unlockLabel: 'Awans: accuracy >= 86%, mało błędów, reakcja <= 560 ms',
    tempoLabel: '500-700 ms',
    ruleLabel: '12 s',
    stimulusStartMs: 700,
    stimulusEndMs: 500,
    gapStartMs: 150,
    gapEndMs: 110,
    ruleWindowStartSeconds: 12,
    ruleWindowEndSeconds: 12,
    allowedRuleKinds: <_SplitRuleKind>[
      _SplitRuleKind.tapRed,
      _SplitRuleKind.tapTriangle,
      _SplitRuleKind.skipBlue,
      _SplitRuleKind.skipCircle,
    ],
    color: Color(0xFFE1A94A),
  ),
  _SplitLevelDefinition(
    level: 3,
    polishName: 'Adaptacja',
    title: 'Fast Thinker',
    goal: 'Szybko przełączać się między regułami i utrzymać kontekst.',
    settings: <String>[
      'Tempo: 400-600 ms',
      'Zmiana zasad co 12 s',
      'Miks koloru, kształtu i liczb',
    ],
    effects: <String>[
      'Rośnie elastyczność uwagi',
      'Zmiana kontekstu przestaje wybijać z rytmu',
    ],
    note: 'To jest moment prawdziwego upgrade.',
    unlockLabel: 'Awans: accuracy >= 88% i stabilna zmiana zasad',
    tempoLabel: '400-600 ms',
    ruleLabel: '12 s',
    stimulusStartMs: 600,
    stimulusEndMs: 400,
    gapStartMs: 110,
    gapEndMs: 90,
    ruleWindowStartSeconds: 12,
    ruleWindowEndSeconds: 12,
    allowedRuleKinds: <_SplitRuleKind>[
      _SplitRuleKind.tapRed,
      _SplitRuleKind.tapTriangle,
      _SplitRuleKind.skipBlue,
      _SplitRuleKind.skipCircle,
      _SplitRuleKind.tapEven,
    ],
    color: Color(0xFFD46C4E),
  ),
  _SplitLevelDefinition(
    level: 4,
    polishName: 'Przeciążenie',
    title: 'Edge Runner',
    goal: 'Wejść w granicę możliwości i utrzymać decyzję bez namysłu.',
    settings: <String>[
      'Tempo: 250-400 ms',
      'Zmiana zasad co 12 s',
      'Negacje i szybkie odwrócenie logiki',
    ],
    effects: <String>[
      'Mózg pracuje na max',
      'Nie ma miejsca na wolne myślenie',
    ],
    note: 'Tu pojawia się realne przyspieszenie.',
    unlockLabel:
        'Awans: accuracy >= 90%, reakcja <= 320 ms, niski chaos błędów',
    tempoLabel: '250-400 ms',
    ruleLabel: '12 s',
    stimulusStartMs: 400,
    stimulusEndMs: 250,
    gapStartMs: 90,
    gapEndMs: 70,
    ruleWindowStartSeconds: 12,
    ruleWindowEndSeconds: 12,
    allowedRuleKinds: <_SplitRuleKind>[
      _SplitRuleKind.tapRed,
      _SplitRuleKind.tapTriangle,
      _SplitRuleKind.skipBlue,
      _SplitRuleKind.skipCircle,
      _SplitRuleKind.tapEven,
    ],
    color: Color(0xFFC55454),
  ),
  _SplitLevelDefinition(
    level: 5,
    polishName: 'Mastery',
    title: 'Overclocked',
    goal: 'Osiągnąć automatyczną wysoką wydajność bez przeciążenia systemu.',
    settings: <String>[
      'Tempo: 200-300 ms',
      'Zmiana zasad co 12 s',
      'Chaos kontrolowany z całego zestawu',
    ],
    effects: <String>[
      'Działasz intuicyjnie i bez wysiłku',
      'Pełna obecność i szybkie decyzje',
    ],
    note: 'High performance mode.',
    unlockLabel:
        'Top level: gra utrzymuje tu tylko wtedy, gdy wyniki dalej są wysokie',
    tempoLabel: '200-300 ms',
    ruleLabel: '12 s',
    stimulusStartMs: 300,
    stimulusEndMs: 200,
    gapStartMs: 70,
    gapEndMs: 50,
    ruleWindowStartSeconds: 12,
    ruleWindowEndSeconds: 12,
    allowedRuleKinds: <_SplitRuleKind>[
      _SplitRuleKind.tapRed,
      _SplitRuleKind.tapTriangle,
      _SplitRuleKind.skipBlue,
      _SplitRuleKind.skipCircle,
      _SplitRuleKind.tapEven,
    ],
    color: Color(0xFF24303A),
  ),
];

Color _splitLevelColorForLevel(int level) {
  for (final definition in _splitLevelDefinitions) {
    if (definition.level == level) {
      return definition.color;
    }
  }

  return _splitLevelDefinitions.first.color;
}

class _SplitStimulus {
  const _SplitStimulus.color({required _SplitColorToken token})
    : kind = _SplitStimulusKind.color,
      colorToken = token,
      shapeToken = null,
      number = null;

  const _SplitStimulus.shape({required _SplitShapeToken token})
    : kind = _SplitStimulusKind.shape,
      colorToken = null,
      shapeToken = token,
      number = null;

  const _SplitStimulus.number({required int value})
    : kind = _SplitStimulusKind.number,
      colorToken = null,
      shapeToken = null,
      number = value;

  final _SplitStimulusKind kind;
  final _SplitColorToken? colorToken;
  final _SplitShapeToken? shapeToken;
  final int? number;
}

class _SplitLaunchStep extends StatelessWidget {
  const _SplitLaunchStep({required this.label});

  final String label;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: const Color(0xFFD6DEE5)),
      ),
      child: Text(
        label,
        style: Theme.of(context).textTheme.bodyMedium?.copyWith(
          color: const Color(0xFF24303A),
          fontWeight: FontWeight.w700,
        ),
      ),
    );
  }
}

enum _SplitColorToken { red, blue, green, amber }

extension on _SplitColorToken {
  String get label => switch (this) {
    _SplitColorToken.red => 'CZERWONY',
    _SplitColorToken.blue => 'NIEBIESKI',
    _SplitColorToken.green => 'ZIELONY',
    _SplitColorToken.amber => 'ZŁOTY',
  };

  Color get color => switch (this) {
    _SplitColorToken.red => const Color(0xFFD35757),
    _SplitColorToken.blue => const Color(0xFF4370C7),
    _SplitColorToken.green => const Color(0xFF3B8F5E),
    _SplitColorToken.amber => const Color(0xFFC68A1F),
  };
}

enum _SplitShapeToken { circle, triangle, square, star }

extension on _SplitShapeToken {
  String get label => switch (this) {
    _SplitShapeToken.circle => 'KOŁO',
    _SplitShapeToken.triangle => 'TRÓJKĄT',
    _SplitShapeToken.square => 'KWADRAT',
    _SplitShapeToken.star => 'GWIAZDA',
  };

  IconData get icon => switch (this) {
    _SplitShapeToken.circle => Icons.circle,
    _SplitShapeToken.triangle => Icons.change_history_rounded,
    _SplitShapeToken.square => Icons.check_box_outline_blank_rounded,
    _SplitShapeToken.star => Icons.star_rounded,
  };
}

class _SplitSummaryPill extends StatelessWidget {
  const _SplitSummaryPill({
    required this.label,
    required this.value,
    required this.tint,
  });

  final String label;
  final String value;
  final Color tint;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(18),
        border: Border.all(color: tint.withValues(alpha: 0.16)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Text(
            label.toUpperCase(),
            style: theme.textTheme.labelLarge?.copyWith(
              color: tint,
              fontWeight: FontWeight.w800,
              letterSpacing: 0.8,
            ),
          ),
          const SizedBox(height: 6),
          Text(
            value,
            style: theme.textTheme.titleMedium?.copyWith(
              color: const Color(0xFF16212B),
              fontWeight: FontWeight.w800,
            ),
          ),
        ],
      ),
    );
  }
}

class _SplitTopStat extends StatelessWidget {
  const _SplitTopStat({
    required this.label,
    required this.value,
    required this.tint,
    required this.compact,
  });

  final String label;
  final String value;
  final Color tint;
  final bool compact;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final palette = context.appPalette;
    return SizedBox(
      height: compact ? 68 : 74,
      child: Container(
        width: double.infinity,
        padding: EdgeInsets.symmetric(
          horizontal: compact ? 10 : 12,
          vertical: compact ? 10 : 12,
        ),
        decoration: BoxDecoration(
          color: palette.surface.withValues(alpha: 0.92),
          borderRadius: BorderRadius.circular(18),
          border: Border.all(color: tint.withValues(alpha: 0.18)),
          boxShadow: <BoxShadow>[
            BoxShadow(
              color: palette.shadowColor.withValues(alpha: 0.45),
              blurRadius: 14,
              offset: const Offset(0, 6),
            ),
          ],
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisAlignment: MainAxisAlignment.center,
          children: <Widget>[
            FittedBox(
              fit: BoxFit.scaleDown,
              alignment: Alignment.centerLeft,
              child: Text(
                label.toUpperCase(),
                maxLines: 1,
                style: theme.textTheme.labelSmall?.copyWith(
                  color: tint,
                  fontWeight: FontWeight.w800,
                  letterSpacing: 0.9,
                ),
              ),
            ),
            const SizedBox(height: 4),
            Expanded(
              child: Align(
                alignment: Alignment.centerLeft,
                child: FittedBox(
                  fit: BoxFit.scaleDown,
                  alignment: Alignment.centerLeft,
                  child: Text(
                    value,
                    maxLines: 1,
                    style: theme.textTheme.titleMedium?.copyWith(
                      color: palette.primaryText,
                      fontWeight: FontWeight.w800,
                    ),
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

bool _isBetterSessionRecord(
  _SplitSessionRecord candidate,
  _SplitSessionRecord current,
) {
  if (candidate.accuracyPercent != current.accuracyPercent) {
    return candidate.accuracyPercent > current.accuracyPercent;
  }

  if (candidate.level != current.level) {
    return candidate.level > current.level;
  }

  if (candidate.correctDecisions != current.correctDecisions) {
    return candidate.correctDecisions > current.correctDecisions;
  }

  if (candidate.errors != current.errors) {
    return candidate.errors < current.errors;
  }

  final candidateReaction = candidate.averageReactionMs == 0
      ? 99999
      : candidate.averageReactionMs;
  final currentReaction = current.averageReactionMs == 0
      ? 99999
      : current.averageReactionMs;
  if (candidateReaction != currentReaction) {
    return candidateReaction < currentReaction;
  }

  if (candidate.bestStreak != current.bestStreak) {
    return candidate.bestStreak > current.bestStreak;
  }

  return candidate.completedAtIso.compareTo(current.completedAtIso) > 0;
}

const List<String> _flowMonthLabels = <String>[
  'styczeń',
  'luty',
  'marzec',
  'kwiecień',
  'maj',
  'czerwiec',
  'lipiec',
  'sierpień',
  'wrzesień',
  'październik',
  'listopad',
  'grudzień',
];

const List<String> _flowMonthLabelsGenitive = <String>[
  'stycznia',
  'lutego',
  'marca',
  'kwietnia',
  'maja',
  'czerwca',
  'lipca',
  'sierpnia',
  'września',
  'października',
  'listopada',
  'grudnia',
];

const List<String> _flowWeekdayLabels = <String>[
  'pon',
  'wt',
  'śr',
  'czw',
  'pt',
  'sob',
  'niedz',
];

List<DateTime?> _buildCalendarDays(DateTime visibleMonth) {
  final firstDay = DateTime(visibleMonth.year, visibleMonth.month, 1);
  final daysInMonth = DateTime(
    visibleMonth.year,
    visibleMonth.month + 1,
    0,
  ).day;
  final leadingEmptySlots = firstDay.weekday - 1;
  final days = <DateTime?>[
    for (var i = 0; i < leadingEmptySlots; i++) null,
    for (var day = 1; day <= daysInMonth; day++)
      DateTime(visibleMonth.year, visibleMonth.month, day),
  ];

  while (days.length % 7 != 0) {
    days.add(null);
  }

  return days;
}

String _dateKeyFor(DateTime value) {
  final year = value.year.toString().padLeft(4, '0');
  final month = value.month.toString().padLeft(2, '0');
  final day = value.day.toString().padLeft(2, '0');
  return '$year-$month-$day';
}

DateTime? _parseDateKey(String dateKey) {
  final parts = dateKey.split('-');
  if (parts.length != 3) {
    return null;
  }

  final year = int.tryParse(parts[0]);
  final month = int.tryParse(parts[1]);
  final day = int.tryParse(parts[2]);
  if (year == null || month == null || day == null) {
    return null;
  }

  return DateTime(year, month, day);
}

String _formatFlowMonthYearLabel(DateTime value) {
  return '${_flowMonthLabels[value.month - 1]} ${value.year}';
}

String _formatFlowLongDateLabel(String dateKey) {
  final date = _parseDateKey(dateKey);
  if (date == null) {
    return dateKey;
  }

  return '${date.day} ${_flowMonthLabelsGenitive[date.month - 1]} ${date.year}';
}

String _formatSessionDateLabel(String dateKey) {
  final parts = dateKey.split('-');
  if (parts.length != 3) {
    return dateKey;
  }
  return '${parts[2]}.${parts[1]}.${parts[0]}';
}

String _formatSessionTimeLabel(String completedAtIso) {
  try {
    final completedAt = DateTime.parse(completedAtIso).toLocal();
    final hour = completedAt.hour.toString().padLeft(2, '0');
    final minute = completedAt.minute.toString().padLeft(2, '0');
    return '$hour:$minute';
  } on FormatException {
    return '--:--';
  }
}

String _formatSessionDateTimeLabel(String completedAtIso) {
  try {
    final completedAt = DateTime.parse(completedAtIso).toLocal();
    return '${_formatSessionDateLabel(_dateKeyFor(completedAt))} • ${_formatSessionTimeLabel(completedAtIso)}';
  } on FormatException {
    return completedAtIso;
  }
}

String _formatLevelCountLabel(int count) {
  if (count == 1) {
    return '1 poziom';
  }
  if (count >= 2 && count <= 4) {
    return '$count poziomy';
  }
  return '$count poziomów';
}

String _formatFlowProgressCountLabel(int count) {
  final units = count % 10;
  final lastTwoDigits = count % 100;

  if (count == 1) {
    return 'progres';
  }
  if (units >= 2 && units <= 4 && (lastTwoDigits < 12 || lastTwoDigits > 14)) {
    return 'progresy';
  }
  return 'progresów';
}

String _formatFlowCalendarEntryCountLabel(int count) {
  final units = count % 10;
  final lastTwoDigits = count % 100;

  if (count == 1) {
    return 'wpis';
  }
  if (units >= 2 && units <= 4 && (lastTwoDigits < 12 || lastTwoDigits > 14)) {
    return 'wpisy';
  }
  return 'wpisów';
}

String _buildSessionActionSummary(_SplitSessionRecord record) {
  if (record.tapHits == null || record.tapOpportunities == null) {
    return 'decyzje ${record.correctDecisions}/${record.presented}';
  }
  return 'trafienia ${record.tapHits}/${record.tapOpportunities}';
}

String _buildSessionActionChipLabel(_SplitSessionRecord record) {
  if (record.tapHits == null || record.tapOpportunities == null) {
    return 'Decyzje: ${record.correctDecisions}/${record.presented}';
  }
  return 'Trafione: ${record.tapHits}/${record.tapOpportunities}';
}

class _FlowProgressSnapshot {
  const _FlowProgressSnapshot({
    required this.activeDateKey,
    required this.completedKinds,
    required this.currentCycleRecordId,
    required this.entries,
  });

  factory _FlowProgressSnapshot.fromJson(Map<String, dynamic> json) {
    final activeDateKey =
        json['activeDateKey'] as String? ?? _dateKeyFor(DateTime.now());
    final currentCycleRecordId = json['currentCycleRecordId'] as String?;
    final completedKinds = <ExerciseKind>{};
    final completedKindsJson = json['completedKinds'];
    if (completedKindsJson is List) {
      for (final rawKind in completedKindsJson) {
        if (rawKind is! String) {
          continue;
        }
        try {
          completedKinds.add(ExerciseKind.values.byName(rawKind));
        } on ArgumentError {
          continue;
        }
      }
    }

    final entries = <_FlowProgressEntry>[];
    final entriesJson = json['entries'];
    if (entriesJson is List) {
      for (final rawEntry in entriesJson) {
        if (rawEntry is! Map) {
          continue;
        }
        try {
          entries.add(
            _FlowProgressEntry.fromJson(rawEntry.cast<String, dynamic>()),
          );
        } on FormatException {
          continue;
        }
      }
    }

    return _FlowProgressSnapshot(
      activeDateKey: activeDateKey,
      completedKinds: completedKinds,
      currentCycleRecordId: currentCycleRecordId,
      entries: entries,
    );
  }

  final String activeDateKey;
  final Set<ExerciseKind> completedKinds;
  final String? currentCycleRecordId;
  final List<_FlowProgressEntry> entries;

  Map<String, dynamic> toJson() {
    return <String, dynamic>{
      'activeDateKey': activeDateKey,
      'completedKinds': completedKinds.map((kind) => kind.name).toList(),
      'currentCycleRecordId': currentCycleRecordId,
      'entries': entries.map((entry) => entry.toJson()).toList(),
    };
  }
}

enum _FlowProgressEntryType { cycle, memory, vibration, training }

_FlowProgressEntryType _flowProgressEntryTypeFromValue(Object? rawType) {
  if (rawType is! String) {
    return _FlowProgressEntryType.cycle;
  }

  for (final type in _FlowProgressEntryType.values) {
    if (type.name == rawType) {
      return type;
    }
  }
  return _FlowProgressEntryType.cycle;
}

class _FlowProgressEntry {
  const _FlowProgressEntry({
    required this.id,
    required this.dateKey,
    required this.completedAtIso,
    required this.type,
  });

  factory _FlowProgressEntry.fromJson(Map<String, dynamic> json) {
    final id = json['id'];
    final dateKey = json['dateKey'];
    final completedAtIso = json['completedAtIso'];
    if (id is! String || dateKey is! String || completedAtIso is! String) {
      throw const FormatException('Invalid flow progress entry');
    }

    return _FlowProgressEntry(
      id: id,
      dateKey: dateKey,
      completedAtIso: completedAtIso,
      type: _flowProgressEntryTypeFromValue(json['type']),
    );
  }

  final String id;
  final String dateKey;
  final String completedAtIso;
  final _FlowProgressEntryType type;

  String get calendarLabel {
    switch (type) {
      case _FlowProgressEntryType.cycle:
        return 'Ukończono Progres';
      case _FlowProgressEntryType.memory:
        return 'Ukończono Pamięć';
      case _FlowProgressEntryType.vibration:
        return 'Ukończono Wibrację';
      case _FlowProgressEntryType.training:
        return 'Ukończono Trening';
    }
  }

  Map<String, dynamic> toJson() {
    return <String, dynamic>{
      'id': id,
      'dateKey': dateKey,
      'completedAtIso': completedAtIso,
      'type': type.name,
    };
  }
}

bool _sameFlowProgressEntries(
  List<_FlowProgressEntry> left,
  List<_FlowProgressEntry> right,
) {
  if (left.length != right.length) {
    return false;
  }

  for (var index = 0; index < left.length; index += 1) {
    final leftEntry = left[index];
    final rightEntry = right[index];
    if (leftEntry.id != rightEntry.id ||
        leftEntry.dateKey != rightEntry.dateKey ||
        leftEntry.completedAtIso != rightEntry.completedAtIso ||
        leftEntry.type != rightEntry.type) {
      return false;
    }
  }

  return true;
}

class _SplitSessionRecord {
  const _SplitSessionRecord({
    required this.dateKey,
    required this.completedAtIso,
    required this.level,
    required this.accuracyPercent,
    required this.averageReactionMs,
    required this.bestStreak,
    required this.correctDecisions,
    this.tapHits,
    this.tapOpportunities,
    required this.errors,
    required this.presented,
  });

  factory _SplitSessionRecord.fromJson(Map<String, dynamic> json) {
    final dateKey = json['dateKey'];
    final completedAtIso = json['completedAtIso'];
    if (dateKey is! String || completedAtIso is! String) {
      throw const FormatException('Invalid session record');
    }

    return _SplitSessionRecord(
      dateKey: dateKey,
      completedAtIso: completedAtIso,
      level: (json['level'] as num?)?.toInt() ?? 1,
      accuracyPercent: (json['accuracyPercent'] as num?)?.toInt() ?? 0,
      averageReactionMs: (json['averageReactionMs'] as num?)?.toInt() ?? 0,
      bestStreak: (json['bestStreak'] as num?)?.toInt() ?? 0,
      correctDecisions: (json['correctDecisions'] as num?)?.toInt() ?? 0,
      tapHits: (json['tapHits'] as num?)?.toInt(),
      tapOpportunities: (json['tapOpportunities'] as num?)?.toInt(),
      errors: (json['errors'] as num?)?.toInt() ?? 0,
      presented: (json['presented'] as num?)?.toInt() ?? 0,
    );
  }

  final String dateKey;
  final String completedAtIso;
  final int level;
  final int accuracyPercent;
  final int averageReactionMs;
  final int bestStreak;
  final int correctDecisions;
  final int? tapHits;
  final int? tapOpportunities;
  final int errors;
  final int presented;

  Map<String, dynamic> toJson() {
    return <String, dynamic>{
      'dateKey': dateKey,
      'completedAtIso': completedAtIso,
      'level': level,
      'accuracyPercent': accuracyPercent,
      'averageReactionMs': averageReactionMs,
      'bestStreak': bestStreak,
      'correctDecisions': correctDecisions,
      'tapHits': tapHits,
      'tapOpportunities': tapOpportunities,
      'errors': errors,
      'presented': presented,
    };
  }
}

class _SplitLevelPickerButton extends StatelessWidget {
  const _SplitLevelPickerButton({
    required this.level,
    required this.selected,
    required this.compact,
    this.onTap,
  });

  final _SplitLevelDefinition level;
  final bool selected;
  final bool compact;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final numberSize = compact ? 42.0 : 46.0;

    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(22),
        child: Ink(
          width: double.infinity,
          padding: const EdgeInsets.all(16),
          decoration: BoxDecoration(
            color: selected
                ? Colors.white.withValues(alpha: 0.86)
                : Colors.white.withValues(alpha: 0.54),
            borderRadius: BorderRadius.circular(22),
            border: Border.all(
              color: selected ? level.color : const Color(0xFFD6DDE2),
              width: selected ? 1.4 : 1,
            ),
          ),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              Container(
                width: numberSize,
                height: numberSize,
                decoration: BoxDecoration(
                  color: level.color.withValues(alpha: selected ? 0.18 : 0.1),
                  borderRadius: BorderRadius.circular(16),
                ),
                alignment: Alignment.center,
                child: Text(
                  '${level.level}',
                  style: theme.textTheme.titleMedium?.copyWith(
                    color: level.color,
                    fontWeight: FontWeight.w900,
                  ),
                ),
              ),
              const SizedBox(width: 14),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: <Widget>[
                    Text(
                      'Poziom ${level.level}',
                      style: theme.textTheme.labelLarge?.copyWith(
                        color: selected ? level.color : const Color(0xFF63717C),
                        fontWeight: FontWeight.w800,
                        letterSpacing: 0.4,
                      ),
                    ),
                    const SizedBox(height: 4),
                    Text(
                      '${level.polishName} • ${level.title}',
                      style: theme.textTheme.titleMedium?.copyWith(
                        color: const Color(0xFF16212B),
                        fontWeight: FontWeight.w900,
                      ),
                    ),
                    const SizedBox(height: 6),
                    Text(
                      level.goal,
                      style: theme.textTheme.bodyMedium?.copyWith(
                        color: const Color(0xFF4A5761),
                        height: 1.4,
                      ),
                    ),
                    const SizedBox(height: 8),
                    Text(
                      'Tempo ${level.tempoLabel} • Zasady ${level.ruleLabel}',
                      style: theme.textTheme.labelLarge?.copyWith(
                        color: selected ? level.color : const Color(0xFF63717C),
                        fontWeight: FontWeight.w800,
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(width: 12),
              Icon(
                selected
                    ? Icons.check_circle_rounded
                    : Icons.chevron_right_rounded,
                color: selected ? level.color : const Color(0xFF92A0AA),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _SplitSessionDayGroup {
  const _SplitSessionDayGroup({required this.dateKey, required this.records});

  final String dateKey;
  final List<_SplitSessionRecord> records;
}

class _SplitDailyBestGroupCard extends StatelessWidget {
  const _SplitDailyBestGroupCard({
    required this.group,
    required this.highlight,
    required this.onLongPressRecord,
  });

  final _SplitSessionDayGroup group;
  final bool highlight;
  final Future<void> Function(_SplitSessionRecord record) onLongPressRecord;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final palette = context.appPalette;
    final accent = highlight ? palette.primaryButton : palette.tertiaryText;
    final levelCountLabel = _formatLevelCountLabel(group.records.length);

    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: highlight ? palette.surfaceMuted : palette.surfaceStrong,
        borderRadius: BorderRadius.circular(20),
        border: Border.all(
          color: highlight
              ? palette.primaryButton.withValues(alpha: 0.2)
              : palette.surfaceBorder,
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Center(
            child: Text(
              _formatSessionDateLabel(group.dateKey),
              maxLines: 1,
              softWrap: false,
              overflow: TextOverflow.fade,
              textAlign: TextAlign.center,
              style: theme.textTheme.titleMedium?.copyWith(
                color: palette.primaryText,
                fontWeight: FontWeight.w800,
              ),
            ),
          ),
          const SizedBox(height: 8),
          Center(
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
              decoration: BoxDecoration(
                color: palette.surface,
                borderRadius: BorderRadius.circular(999),
                border: Border.all(color: accent.withValues(alpha: 0.16)),
              ),
              child: Text(
                highlight ? 'Dzisiaj • $levelCountLabel' : levelCountLabel,
                maxLines: 1,
                softWrap: false,
                overflow: TextOverflow.fade,
                style: theme.textTheme.labelMedium?.copyWith(
                  color: accent,
                  fontWeight: FontWeight.w800,
                ),
              ),
            ),
          ),
          const SizedBox(height: 12),
          LayoutBuilder(
            builder: (BuildContext context, BoxConstraints constraints) {
              final cardWidth = constraints.maxWidth > 540
                  ? (constraints.maxWidth - 10) / 2
                  : constraints.maxWidth;

              return Wrap(
                spacing: 10,
                runSpacing: 10,
                children: group.records
                    .map(
                      (_SplitSessionRecord record) => SizedBox(
                        width: cardWidth,
                        child: _SplitDailyBestLevelCard(
                          record: record,
                          accent: accent,
                          highlight: highlight,
                          onLongPress: () => onLongPressRecord(record),
                        ),
                      ),
                    )
                    .toList(),
              );
            },
          ),
        ],
      ),
    );
  }
}

class _SplitDailyBestLevelCard extends StatelessWidget {
  const _SplitDailyBestLevelCard({
    required this.record,
    required this.accent,
    required this.highlight,
    required this.onLongPress,
  });

  final _SplitSessionRecord record;
  final Color accent;
  final bool highlight;
  final VoidCallback onLongPress;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final levelColor = _splitLevelColorForLevel(record.level);
    final palette = context.appPalette;
    final levelTextColor =
        ThemeData.estimateBrightnessForColor(levelColor) == Brightness.dark
        ? Colors.white
        : palette.primaryText;

    return Material(
      color: Colors.transparent,
      child: InkWell(
        onLongPress: onLongPress,
        borderRadius: BorderRadius.circular(18),
        child: Ink(
          width: double.infinity,
          padding: const EdgeInsets.all(14),
          decoration: BoxDecoration(
            color: palette.surface,
            borderRadius: BorderRadius.circular(18),
            border: Border.all(
              color: accent.withValues(alpha: highlight ? 0.22 : 0.12),
            ),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              Container(
                width: double.infinity,
                padding: const EdgeInsets.symmetric(
                  horizontal: 12,
                  vertical: 12,
                ),
                decoration: BoxDecoration(
                  color: levelColor,
                  borderRadius: BorderRadius.circular(14),
                ),
                child: Text(
                  'Poziom ${record.level}',
                  textAlign: TextAlign.center,
                  style: theme.textTheme.labelLarge?.copyWith(
                    color: levelTextColor,
                    fontWeight: FontWeight.w900,
                    letterSpacing: 0.4,
                  ),
                ),
              ),
              const SizedBox(height: 10),
              _SplitBestMetricChip(
                label:
                    'Zapis ${_formatSessionTimeLabel(record.completedAtIso)}',
                tint: accent,
                fillColor: highlight
                    ? palette.surfaceMuted
                    : palette.surfaceStrong,
                textColor: accent,
              ),
              const SizedBox(height: 8),
              _SplitBestMetricChip(
                label: _buildSessionActionChipLabel(record),
                tint: accent,
              ),
              const SizedBox(height: 8),
              _SplitBestMetricChip(
                label: 'Błędy: ${record.errors}',
                tint: accent,
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _SplitBestMetricChip extends StatelessWidget {
  const _SplitBestMetricChip({
    required this.label,
    required this.tint,
    this.fillColor,
    this.textColor,
  });

  final String label;
  final Color tint;
  final Color? fillColor;
  final Color? textColor;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final palette = context.appPalette;
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      decoration: BoxDecoration(
        color: fillColor ?? palette.surface,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: tint.withValues(alpha: 0.14)),
      ),
      child: Text(
        label,
        textAlign: TextAlign.center,
        style: theme.textTheme.bodySmall?.copyWith(
          color: textColor ?? palette.primaryText,
          fontWeight: FontWeight.w700,
        ),
      ),
    );
  }
}

class _SplitLevelCard extends StatelessWidget {
  const _SplitLevelCard({required this.level, required this.active});

  final _SplitLevelDefinition level;
  final bool active;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final palette = context.appPalette;

    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(18),
      decoration: BoxDecoration(
        color: active
            ? Color.lerp(level.color, palette.surfaceStrong, 0.86)
            : palette.surface,
        borderRadius: BorderRadius.circular(22),
        border: Border.all(
          color: active
              ? level.color.withValues(alpha: 0.38)
              : level.color.withValues(alpha: 0.14),
          width: active ? 1.6 : 1,
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Row(
            children: <Widget>[
              Container(
                padding: const EdgeInsets.symmetric(
                  horizontal: 12,
                  vertical: 8,
                ),
                decoration: BoxDecoration(
                  color: level.color.withValues(alpha: 0.14),
                  borderRadius: BorderRadius.circular(999),
                ),
                child: Text(
                  'POZIOM ${level.level}',
                  style: theme.textTheme.labelLarge?.copyWith(
                    color: level.color,
                    fontWeight: FontWeight.w900,
                    letterSpacing: 0.8,
                  ),
                ),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: Text(
                  '${level.polishName} • ${level.title}',
                  style: theme.textTheme.titleMedium?.copyWith(
                    color: palette.primaryText,
                    fontWeight: FontWeight.w800,
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 12),
          Text(
            level.goal,
            style: theme.textTheme.bodyMedium?.copyWith(
              color: palette.primaryText,
              fontWeight: FontWeight.w700,
              height: 1.45,
            ),
          ),
          const SizedBox(height: 12),
          Text(
            'Ustawienia',
            style: theme.textTheme.labelLarge?.copyWith(
              color: level.color,
              fontWeight: FontWeight.w800,
              letterSpacing: 0.8,
            ),
          ),
          const SizedBox(height: 8),
          for (final item in level.settings) ...<Widget>[
            _SplitRoadmapLine(text: item),
            const SizedBox(height: 6),
          ],
          const SizedBox(height: 4),
          Text(
            'Co się dzieje',
            style: theme.textTheme.labelLarge?.copyWith(
              color: level.color,
              fontWeight: FontWeight.w800,
              letterSpacing: 0.8,
            ),
          ),
          const SizedBox(height: 8),
          for (final item in level.effects) ...<Widget>[
            _SplitRoadmapLine(text: item),
            const SizedBox(height: 6),
          ],
          const SizedBox(height: 4),
          Text(
            level.note,
            style: theme.textTheme.bodyMedium?.copyWith(
              color: palette.secondaryText,
              fontStyle: FontStyle.italic,
            ),
          ),
          const SizedBox(height: 10),
          Text(
            level.unlockLabel,
            style: theme.textTheme.bodySmall?.copyWith(
              color: palette.secondaryText,
              fontWeight: FontWeight.w700,
              height: 1.4,
            ),
          ),
        ],
      ),
    );
  }
}

class _SplitRoadmapLine extends StatelessWidget {
  const _SplitRoadmapLine({required this.text});

  final String text;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final palette = context.appPalette;
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        Container(
          width: 6,
          height: 6,
          margin: const EdgeInsets.only(top: 7),
          decoration: BoxDecoration(
            color: palette.primaryText,
            shape: BoxShape.circle,
          ),
        ),
        const SizedBox(width: 10),
        Expanded(
          child: Text(
            text,
            style: theme.textTheme.bodyMedium?.copyWith(
              color: palette.primaryText,
              height: 1.4,
            ),
          ),
        ),
      ],
    );
  }
}

enum SpeedReadCategory { polish, english, german }

enum SpeedReadLevel { one, two, three, four, five }

class _SpeedReadLevelDefinition {
  const _SpeedReadLevelDefinition({
    required this.level,
    required this.label,
    required this.accentText,
    required this.preview,
    required this.defaultWordsPerMinute,
    required this.segmentCount,
  });

  final SpeedReadLevel level;
  final String label;
  final String accentText;
  final String preview;
  final int defaultWordsPerMinute;
  final int segmentCount;
}

class _SpeedReadCategoryDefinition {
  const _SpeedReadCategoryDefinition({
    required this.category,
    required this.label,
    required this.flag,
    required this.preview,
    required this.seriesUnitLabel,
    required this.levels,
  });

  final SpeedReadCategory category;
  final String label;
  final String flag;
  final String preview;
  final String seriesUnitLabel;
  final List<_SpeedReadLevelDefinition> levels;
}

class _SpeedReadTheme {
  const _SpeedReadTheme(this.segments);

  final List<String> segments;
}

const List<_SpeedReadLevelDefinition> _speedReadPolishLevels =
    <_SpeedReadLevelDefinition>[
      _SpeedReadLevelDefinition(
        level: SpeedReadLevel.one,
        label: 'Poziom 1',
        accentText: 'Spokojny start',
        preview: 'Krótsze teksty i spokojne wejście w rytm.',
        defaultWordsPerMinute: 400,
        segmentCount: 1,
      ),
      _SpeedReadLevelDefinition(
        level: SpeedReadLevel.two,
        label: 'Poziom 2',
        accentText: 'Płynne wejście',
        preview: 'Więcej treści, nadal czysty i spokojny fokus.',
        defaultWordsPerMinute: 550,
        segmentCount: 2,
      ),
      _SpeedReadLevelDefinition(
        level: SpeedReadLevel.three,
        label: 'Poziom 3',
        accentText: 'Mocny środek',
        preview: 'Gęstsze zdania i mocniejszy napęd mentalny.',
        defaultWordsPerMinute: 700,
        segmentCount: 3,
      ),
      _SpeedReadLevelDefinition(
        level: SpeedReadLevel.four,
        label: 'Poziom 4',
        accentText: 'Gęsty przelot',
        preview: 'Dłuższy przekaz i mniej miejsca na rozproszenie.',
        defaultWordsPerMinute: 850,
        segmentCount: 4,
      ),
      _SpeedReadLevelDefinition(
        level: SpeedReadLevel.five,
        label: 'Poziom 5',
        accentText: 'Pełny sprint',
        preview: 'Najdłuższe teksty i pełne obciążenie uwagi.',
        defaultWordsPerMinute: 1000,
        segmentCount: 5,
      ),
    ];

const List<_SpeedReadCategoryDefinition> _speedReadCategories =
    <_SpeedReadCategoryDefinition>[
      _SpeedReadCategoryDefinition(
        category: SpeedReadCategory.polish,
        label: 'Polski',
        flag: '🇵🇱',
        preview: '20 tekstów do wejścia w rytm czytania i koncentracji.',
        seriesUnitLabel: 'tekstów',
        levels: _speedReadPolishLevels,
      ),
      _SpeedReadCategoryDefinition(
        category: SpeedReadCategory.english,
        label: 'Angielski',
        flag: '🇬🇧',
        preview: '20 tekstów jak w polskim, tylko w wersji angielskiej.',
        seriesUnitLabel: 'tekstów',
        levels: _speedReadPolishLevels,
      ),
      _SpeedReadCategoryDefinition(
        category: SpeedReadCategory.german,
        label: 'Niemiecki',
        flag: '🇩🇪',
        preview: '20 tekstów jak w polskim, tylko w wersji niemieckiej.',
        seriesUnitLabel: 'tekstów',
        levels: _speedReadPolishLevels,
      ),
    ];

const int _speedReadMinWordsPerMinute = 400;
const int _speedReadMaxWordsPerMinute = 1000;
const int _speedReadWordsPerMinuteStep = 50;
const int _speedReadDefaultWordsPerMinute = 550;

const List<_SpeedReadTheme> _speedReadPolishThemes = <_SpeedReadTheme>[
  _SpeedReadTheme(<String>[
    'Kiedy oddech zwalnia, mózg przestaje gubić energię na szumie.',
    'W jednej spokojnej sekundzie odzyskujesz więcej mocy niż w minucie chaotycznego zaczynania.',
    'Koncentracja zaczyna wtedy pracować jak silnik, który napędza następny ruch bez dodatkowego wysiłku.',
    'Im dłużej trzymasz ten rytm, tym wyraźniej czujesz, że motywacja nie spada, ale układa się w stabilny prąd.',
    'Energia nie kończy się po pierwszym zadaniu, bo karmisz ją klarownym kierunkiem, a nie przypadkowymi impulsami.',
  ]),
  _SpeedReadTheme(<String>[
    'Jedna jasna myśl potrafi uspokoić cały wewnętrzny hałas.',
    'Gdy wybierasz jeden kierunek, mózg przestaje skakać i zaczyna oddawać pełną moc temu, co naprawdę ważne.',
    'Właśnie wtedy pojawia się lekkość działania, jakby kolejne kroki uruchamiały się same.',
    'To nie magia, tylko dobrze poprowadzona uwaga, która zamienia napięcie w energię do ruchu.',
    'Im mniej rozproszeń karmisz, tym mocniej rośnie poczucie, że twoja energia może płynąć długo i bez końca.',
  ]),
  _SpeedReadTheme(<String>[
    'Skupienie nie zabiera energii, tylko przestaje ją rozlewać.',
    'Kiedy patrzysz prosto w cel, każda sekunda pracuje na ciebie zamiast uciekać bokiem.',
    'Mózg lubi ten porządek, bo w jasnej strukturze szybciej budzi motywację i gotowość do działania.',
    'Po chwili czujesz, że nie musisz się zmuszać, bo ruch rodzi następny ruch, a zadanie samo przyciąga uwagę.',
    'Tak buduje się wrażenie nieskończonej energii: nie przez presję, lecz przez prosty, spokojny i konsekwentny kierunek.',
  ]),
  _SpeedReadTheme(<String>[
    'Każdy uporządkowany tekst uczy mózg, że chaos nie musi prowadzić dnia.',
    'Gdy czytasz z rytmem, odzyskujesz kontrolę nad wzrokiem, myślą i tempem reakcji.',
    'To daje zastrzyk czystej energii, bo przestajesz walczyć z własnym rozproszeniem.',
    'W miejsce szarpania pojawia się płynność, a płynność bardzo szybko zamienia się w motywację.',
    'Z czasem zaczynasz czuć, że energia nie jest czymś kruchym, lecz zasobem, który rośnie pod wpływem skupienia.',
  ]),
  _SpeedReadTheme(<String>[
    'Mocny dzień nie zaczyna się od presji, ale od jednego dobrze ustawionego kroku.',
    'Kiedy robisz go świadomie, mózg odbiera sygnał bezpieczeństwa i otwiera więcej miejsca na jasne decyzje.',
    'Z tego miejsca łatwiej wejść w działanie, które niesie cię dalej bez ciągłego przekonywania samego siebie.',
    'Motywacja przestaje być kaprysem, bo zamienia się w rytm wspierany przez ciało, wzrok i kierunek.',
    'Im spokojniejszy start, tym większy zapas energii zostaje na głęboką pracę, naukę i odważne ruchy.',
  ]),
  _SpeedReadTheme(<String>[
    'Wewnętrzna energia rośnie szybciej, gdy przestajesz ją wydawać na wątpliwości.',
    'Jedno skupione czytanie porządkuje myśli i pokazuje mózgowi, że warto zostać w zadaniu dłużej.',
    'Z każdą kolejną sekundą maleje opór, a rośnie poczucie sprawczości, które napędza dalszy wysiłek.',
    'To właśnie sprawczość daje najmocniejszy impuls motywacyjny, bo przypomina ci, że potrafisz utrzymać kierunek.',
    'Gdy kierunek jest stabilny, energia nie urywa się po chwili, tylko płynie szerzej i pewniej niż wcześniej.',
  ]),
  _SpeedReadTheme(<String>[
    'Mózg kocha moment, w którym przestajesz szarpać uwagę i zaczynasz ją prowadzić.',
    'Wtedy nawet trudniejsze zdania nie męczą tak bardzo, bo zamiast chaosu pojawia się przewidywalny rytm.',
    'Ten rytm buduje zaufanie do własnych możliwości i daje krótkie, ale wyraźne uderzenie energii.',
    'Zaufanie uruchamia motywację głębszą niż chwilowy zapał, bo opiera się na realnym doświadczeniu postępu.',
    'Im częściej wracasz do takiej pracy, tym mocniej czujesz, że twoja energia potrafi odnawiać się w ruchu.',
  ]),
  _SpeedReadTheme(<String>[
    'Każda świadomie przeczytana linia wzmacnia zdolność trzymania jednego celu.',
    'To proste ćwiczenie uczy mózg, że nie musi reagować na każdy bodziec, by pozostać czujnym.',
    'W tej oszczędności reakcji rodzi się dodatkowa energia, którą można przekierować na naukę, pracę i tworzenie.',
    'Nagle okazuje się, że motywacja nie potrzebuje wielkich haseł, kiedy ma pod sobą spokojną i mocną uwagę.',
    'Stabilna uwaga jest jak źródło, z którego możesz czerpać długo, bo nie marnujesz energii na wewnętrzne szarpanie.',
  ]),
  _SpeedReadTheme(<String>[
    'Kiedy czytasz odważnie i bez cofania, uczysz mózg ufać własnemu tempu.',
    'To zaufanie oszczędza mnóstwo siły, którą wcześniej zabierało ciągłe kontrolowanie każdego szczegółu.',
    'Wolna energia wraca wtedy do obiegu i zaczyna zasilać koncentrację, pamięć oraz poczucie ruchu do przodu.',
    'Z tego miejsca dużo łatwiej podtrzymać motywację, bo działanie przestaje być ciężarem, a staje się przepływem.',
    'Przepływ pokazuje, że energia nie jest ograniczonym zapasem, jeśli przestajesz ją rozpraszać na tysiąc kierunków.',
  ]),
  _SpeedReadTheme(<String>[
    'Silny umysł nie musi być głośny, wystarczy że jest ustawiony.',
    'Gdy ustawiasz go na jeden tekst, ciało i wzrok zaczynają pracować po tej samej stronie.',
    'Ta zgodność daje szybki zastrzyk świeżości, bo układ nerwowy przestaje walczyć sam ze sobą.',
    'W takiej spójności motywacja staje się bardziej fizyczna niż mentalna i łatwiej ją utrzymać przez kolejne zadania.',
    'Wtedy czujesz, że energia nie bierze się z napięcia, ale z porządku, który świadomie budujesz w środku.',
  ]),
  _SpeedReadTheme(<String>[
    'Każda chwila pełnej obecności ładuje mózg lepiej niż kolejne bezrefleksyjne bodźce.',
    'Zamiast szukać nowości, uczysz się wydobywać moc z tego, co jest już przed tobą.',
    'To przesunięcie zmienia wszystko, bo koncentracja przestaje być walką, a staje się źródłem wewnętrznej energii.',
    'Kiedy energia zaczyna płynąć z obecności, motywacja nie musi być wymuszana, tylko naturalnie wraca do gry.',
    'Właśnie dlatego głębokie skupienie daje wrażenie niewyczerpanego paliwa, które odnawia się wraz z klarownym działaniem.',
  ]),
  _SpeedReadTheme(<String>[
    'Czytanie w rytmie to trening dla wzroku, ale jeszcze bardziej dla odwagi utrzymania kierunku.',
    'Każdy kolejny tekst przypomina ci, że możesz wejść głębiej bez cofania się do starych nawyków.',
    'Ta odwaga budzi energię, bo mózg lubi doświadczać ruchu, który ma sens i nie rozpada się po chwili.',
    'Z takiego doświadczenia rodzi się motywacja dojrzalsza niż ekscytacja, bo oparta na spokoju i powtarzalności.',
    'Powtarzalność nie usypia, tylko wzmacnia, gdy prowadzi do coraz większej jasności, mocy i poczucia ciągłego wzrostu.',
  ]),
  _SpeedReadTheme(<String>[
    'Im bardziej klarowny cel, tym mniej energii potrzeba na ruszenie.',
    'Jedno skupione zdanie potrafi ustawić mózg lepiej niż długi wewnętrzny monolog o tym, że trzeba się zebrać.',
    'Kiedy cel i działanie spotykają się w jednej chwili, pojawia się lekka fala napędu, która niesie dalej.',
    'Taki napęd szybko zamienia się w motywację trwałą, bo widzisz efekt w samym rytmie pracy, a nie tylko w wyniku końcowym.',
    'Dzięki temu energia może wydawać się nieskończona, bo odnawia się za każdym razem, gdy wracasz do prostego celu.',
  ]),
  _SpeedReadTheme(<String>[
    'Wszystko staje się łatwiejsze, gdy wzrok przestaje błądzić i znajduje jeden środek ciężkości.',
    'Mózg natychmiast odczytuje to jako porządek i oddaje więcej zasobów na rozumienie zamiast na szukanie bodźców.',
    'Odzyskane zasoby czujesz jak świeży przypływ energii, który podnosi tempo myślenia bez sztucznego napięcia.',
    'To właśnie ten rodzaj energii najlepiej wspiera motywację, bo nie wypala, tylko wzmacnia z każdą minutą.',
    'Jeśli utrzymasz taki sposób pracy, odkryjesz, że siła skupienia może rosnąć niemal bez końca.',
  ]),
  _SpeedReadTheme(<String>[
    'Krótkie wejście w tekst potrafi obudzić mózg szybciej niż długa walka z odkładaniem.',
    'Wystarczy kilka sekund prawdziwego skupienia, by układ nerwowy przestawił się z oporu na gotowość.',
    'Gotowość od razu uwalnia energię, która wcześniej była zablokowana w napięciu i zwlekaniu.',
    'Gdy poczujesz ten przepływ, motywacja przestaje być obietnicą na później i zaczyna działać tu, teraz, w ciele.',
    'W tym stanie łatwiej uwierzyć, że energia może być stale odnawialna, jeśli wracasz do uważnego ruchu.',
  ]),
  _SpeedReadTheme(<String>[
    'Nie potrzebujesz perfekcyjnego nastroju, żeby uruchomić mocny tryb pracy.',
    'Potrzebujesz jednego wyraźnego sygnału dla mózgu, że teraz liczy się ten kierunek i nic poza nim.',
    'Kiedy taki sygnał pojawia się regularnie, rośnie energia, ponieważ maleje koszt ciągłego podejmowania decyzji.',
    'Mniej tarcia oznacza więcej miejsca na motywację, która nie jest już walką, tylko naturalnym skutkiem uporządkowania.',
    'W uporządkowaniu ukrywa się siła większa, niż wydaje się na początku, bo potrafi nieść cię znacznie dłużej niż chwilowy zapał.',
  ]),
  _SpeedReadTheme(<String>[
    'Każdy tekst w tej serii przypomina, że koncentracja jest źródłem mocy, a nie tylko narzędziem do wykonania zadania.',
    'Gdy trzymasz uwagę w jednym miejscu, mózg szybciej buduje poczucie sensu i przestaje marnować energię na skanowanie wszystkiego.',
    'To poczucie sensu wzmacnia chęć działania, bo widzisz, że każdy następny ruch naprawdę coś porządkuje.',
    'Uporządkowany ruch daje stabilną motywację, która nie gaśnie po pierwszym sukcesie, tylko buduje kolejną falę napędu.',
    'Wtedy zaczynasz rozumieć, że energia może wydawać się nieskończona, gdy chronisz ją przed chaosem i karmisz jasnym kierunkiem.',
  ]),
  _SpeedReadTheme(<String>[
    'Spokojne czytanie w rytmie otwiera przestrzeń, w której myśli stają się ostrzejsze i lżejsze jednocześnie.',
    'To połączenie ostrości i lekkości jest jednym z najlepszych znaków, że mózg pracuje ekonomicznie.',
    'Ekonomiczna praca daje więcej energii na dalsze zadania, bo mniej tracisz na walkę z samym sobą.',
    'Z takiego miejsca motywacja wzmacnia się sama, bo ciało i umysł przestają wysyłać sprzeczne sygnały.',
    'Im dłużej utrzymujesz tę spójność, tym bardziej realne staje się poczucie niekończącego się zapasu wewnętrznej mocy.',
  ]),
  _SpeedReadTheme(<String>[
    'Twoja uwaga rośnie tam, gdzie regularnie ją prowadzisz.',
    'Każdy dobrze przeczytany tekst zostawia po sobie ślad większej pewności, że potrafisz wejść głęboko i zostać tam dłużej.',
    'Ta pewność karmi energię, bo zmniejsza lęk przed wysiłkiem i pozwala iść naprzód bez wewnętrznego hamulca.',
    'Gdy hamulec słabnie, motywacja staje się bardziej stabilna, dojrzała i gotowa na długie odcinki pracy.',
    'Na tym właśnie polega siła treningu: budujesz w sobie źródło energii, które nie zależy wyłącznie od chwilowego nastroju.',
  ]),
  _SpeedReadTheme(<String>[
    'Im spokojniej wchodzisz w zadanie, tym mocniej możesz później przyspieszyć.',
    'To paradoks, który mózg rozumie bardzo dobrze, bo najwięcej mocy oddaje wtedy, gdy czuje jasność i brak chaosu.',
    'W jasności rodzi się świeża energia, która unosi uwagę, pamięć i chęć działania na wyższy poziom.',
    'Kiedy kilka razy poczujesz taki stan, motywacja przestaje być przypadkiem i staje się umiejętnością powrotu do mocy.',
    'Wtedy nawet trudniejsze wyzwania zaczynają wyglądać jak przestrzeń do uruchomienia energii, która nie ma szybkiego końca.',
  ]),
];

const List<_SpeedReadTheme> _speedReadEnglishThemes = <_SpeedReadTheme>[
  _SpeedReadTheme(<String>[
    'When the breath slows down, the brain stops losing energy to noise.',
    'In one calm second, you regain more power than in a minute of chaotic starting.',
    'Concentration begins to work like an engine that drives the next move without extra effort.',
    'The longer you hold this rhythm, the more clearly you feel that motivation is not dropping, but settling into a steady current.',
    'Energy does not end after the first task, because you feed it with a clear direction instead of random impulses.',
  ]),
  _SpeedReadTheme(<String>[
    'One clear thought can calm all the inner noise.',
    'When you choose one direction, the brain stops jumping around and starts giving its full power to what truly matters.',
    'That is when a lightness of action appears, as if the next steps were starting on their own.',
    'It is not magic, just well-directed attention that turns tension into energy for movement.',
    'The fewer distractions you feed, the more strongly you feel that your energy can flow for a long time.',
  ]),
  _SpeedReadTheme(<String>[
    'Focus does not take energy away, it only stops spilling it.',
    'When you look straight at the goal, every second works for you instead of slipping away sideways.',
    'The brain likes this order, because in a clear structure it wakes motivation and readiness faster.',
    'After a moment you feel that you do not have to force yourself, because motion creates the next motion and the task starts pulling your attention.',
    'This is how the feeling of endless energy is built: not through pressure, but through a simple, calm and steady direction.',
  ]),
  _SpeedReadTheme(<String>[
    'Every well-ordered text teaches the brain that chaos does not have to lead the day.',
    'When you read with rhythm, you regain control over your eyes, your thoughts and the pace of reaction.',
    'That gives you a shot of clean energy, because you stop fighting your own distraction.',
    'In place of jerking, flow appears, and flow very quickly turns into motivation.',
    'With time you start to feel that energy is not something fragile, but a resource that grows under focus.',
  ]),
  _SpeedReadTheme(<String>[
    'A strong day does not begin with pressure, but with one well-set step.',
    'When you take it consciously, the brain receives a signal of safety and opens more space for clear decisions.',
    'From this place it is easier to enter action that carries you forward without constantly persuading yourself.',
    'Motivation stops being a whim, because it turns into a rhythm supported by the body, the eyes and the direction.',
    'The calmer the start, the more energy remains for deep work, study and bold moves.',
  ]),
  _SpeedReadTheme(<String>[
    'Inner energy grows faster when you stop spending it on doubts.',
    'One focused reading session organizes your thoughts and shows the brain that it is worth staying in the task longer.',
    'With every next second resistance gets smaller and a sense of agency grows, driving further effort.',
    'That sense of agency gives the strongest motivational impulse, because it reminds you that you can hold your direction.',
    'When the direction is stable, energy does not break off after a moment, it flows wider and more confidently than before.',
  ]),
  _SpeedReadTheme(<String>[
    'The brain loves the moment when you stop jerking attention around and start guiding it.',
    'Then even harder sentences do not tire you as much, because chaos is replaced by a predictable rhythm.',
    'That rhythm builds trust in your own abilities and gives a short but clear hit of energy.',
    'Trust triggers a deeper motivation than a temporary burst of enthusiasm, because it is based on real experience of progress.',
    'The more often you return to this kind of work, the more strongly you feel that your energy can renew itself in motion.',
  ]),
  _SpeedReadTheme(<String>[
    'Every line read with awareness strengthens your ability to hold one goal.',
    'This simple exercise teaches the brain that it does not have to react to every stimulus to stay alert.',
    'In this saving of reactions, extra energy is born, and it can be redirected to learning, work and creating.',
    'Suddenly it turns out that motivation does not need big slogans when calm and strong attention is underneath it.',
    'Stable attention is like a source you can draw from for a long time, because you do not waste energy on inner pulling.',
  ]),
  _SpeedReadTheme(<String>[
    'When you read boldly and without going back, you teach the brain to trust its own pace.',
    'That trust saves a great deal of strength that used to be taken by constant checking of every detail.',
    'Free energy returns to circulation and starts feeding concentration, memory and the sense of moving forward.',
    'From this point it is much easier to keep motivation, because action stops feeling like a burden and becomes a flow.',
    'Flow shows that energy is not a limited reserve if you stop scattering it into a thousand directions.',
  ]),
  _SpeedReadTheme(<String>[
    'A strong mind does not have to be loud, it only has to be aligned.',
    'When you set it on one text, the body and the eyes start working on the same side.',
    'This alignment gives a quick surge of freshness, because the nervous system stops fighting with itself.',
    'In such coherence, motivation becomes more physical than mental and easier to keep through the next tasks.',
    'Then you feel that energy does not come from tension, but from the order you consciously build inside.',
  ]),
  _SpeedReadTheme(<String>[
    'Every moment of full presence charges the brain better than more thoughtless stimuli.',
    'Instead of searching for novelty, you learn to draw strength from what is already in front of you.',
    'This shift changes everything, because concentration stops being a struggle and becomes a source of inner energy.',
    'When energy starts flowing from presence, motivation does not have to be forced, it naturally returns to the game.',
    'That is exactly why deep focus gives the feeling of inexhaustible fuel that renews itself through clear action.',
  ]),
  _SpeedReadTheme(<String>[
    'Reading in rhythm is training for the eyes, but even more for the courage to hold direction.',
    'Each next text reminds you that you can go deeper without going back to old habits.',
    'That courage awakens energy, because the brain likes to feel movement that makes sense and does not fall apart after a moment.',
    'From this kind of experience grows a more mature motivation than excitement, because it is built on calm and repetition.',
    'Repetition does not put you to sleep, it makes you stronger when it leads to more clarity, power and a sense of constant growth.',
  ]),
  _SpeedReadTheme(<String>[
    'The clearer the goal, the less energy is needed to begin.',
    'One focused sentence can set the brain better than a long inner monologue about needing to get yourself together.',
    'When goal and action meet in one moment, a light wave of drive appears and carries you further.',
    'Such drive quickly turns into lasting motivation, because you see the effect in the rhythm of work itself and not only in the final result.',
    'Because of this, energy can seem endless, because it renews itself every time you return to a simple goal.',
  ]),
  _SpeedReadTheme(<String>[
    'Everything becomes easier when the eyes stop wandering and find one center of gravity.',
    'The brain reads this immediately as order and gives more resources to understanding instead of searching for stimuli.',
    'You feel those recovered resources as a fresh influx of energy that raises the pace of thinking without artificial tension.',
    'This is exactly the kind of energy that supports motivation best, because it does not burn out, it grows stronger with each minute.',
    'If you keep this way of working, you will discover that the power of focus can grow almost without end.',
  ]),
  _SpeedReadTheme(<String>[
    'A short entry into a text can wake the brain faster than a long fight with procrastination.',
    'A few seconds of real focus are enough for the nervous system to switch from resistance to readiness.',
    'Readiness immediately releases energy that had been blocked in tension and delay.',
    'When you feel this flow, motivation stops being a promise for later and starts acting here and now in the body.',
    'In this state it is easier to believe that energy can renew itself if you keep returning to mindful movement.',
  ]),
  _SpeedReadTheme(<String>[
    'You do not need the perfect mood to start a strong work mode.',
    'You need one clear signal for the brain that this direction matters now and nothing else.',
    'When such a signal appears regularly, energy grows because the cost of constant decision-making falls.',
    'Less friction means more space for motivation that is no longer a fight, but a natural result of order.',
    'There is more strength hidden in order than it seems at first, because it can carry you much longer than a momentary burst of enthusiasm.',
  ]),
  _SpeedReadTheme(<String>[
    'Every text in this series reminds you that concentration is a source of power, not only a tool for getting a task done.',
    'When you hold attention in one place, the brain builds a sense of meaning faster and stops wasting energy on scanning everything.',
    'That sense of meaning strengthens the willingness to act, because you can see that every next move truly puts something in order.',
    'Ordered movement gives stable motivation that does not fade after the first success, but builds another wave of drive.',
    'Then you begin to understand that energy can seem endless when you protect it from chaos and feed it with a clear direction.',
  ]),
  _SpeedReadTheme(<String>[
    'Calm reading in rhythm opens a space in which thoughts become sharper and lighter at the same time.',
    'This combination of sharpness and lightness is one of the best signs that the brain is working economically.',
    'Economical work leaves more energy for the next tasks, because less is lost in fighting yourself.',
    'From such a place motivation strengthens on its own, because the body and the mind stop sending opposing signals.',
    'The longer you keep this coherence, the more real the feeling of an endless reserve of inner power becomes.',
  ]),
  _SpeedReadTheme(<String>[
    'Your attention grows where you regularly lead it.',
    'Every well-read text leaves a trace of greater confidence that you can go deep and stay there longer.',
    'This confidence feeds energy, because it reduces fear of effort and lets you move forward without an inner brake.',
    'As the brake gets weaker, motivation becomes more stable, mature and ready for long stretches of work.',
    'This is the power of training: you build within yourself a source of energy that does not depend only on a passing mood.',
  ]),
  _SpeedReadTheme(<String>[
    'The calmer you enter a task, the more strongly you can speed up later.',
    'It is a paradox that the brain understands very well, because it gives the most power when it feels clarity and no chaos.',
    'In clarity, fresh energy is born that lifts attention, memory and willingness to act to a higher level.',
    'When you feel such a state a few times, motivation stops being an accident and becomes the skill of returning to power.',
    'Then even harder challenges start to look like a space for releasing energy that does not end quickly.',
  ]),
];

const List<_SpeedReadTheme> _speedReadGermanThemes = <_SpeedReadTheme>[
  _SpeedReadTheme(<String>[
    'Wenn der Atem langsamer wird, verliert das Gehirn keine Energie mehr im Lärm.',
    'In einer ruhigen Sekunde gewinnst du mehr Kraft zurück als in einer Minute chaotischen Anfangens.',
    'Die Konzentration beginnt dann wie ein Motor zu arbeiten, der den nächsten Schritt ohne zusätzlichen Aufwand antreibt.',
    'Je länger du diesen Rhythmus hältst, desto deutlicher spürst du, dass die Motivation nicht sinkt, sondern sich zu einem stabilen Strom ordnet.',
    'Die Energie endet nicht nach der ersten Aufgabe, weil du sie mit einer klaren Richtung nährst und nicht mit zufälligen Impulsen.',
  ]),
  _SpeedReadTheme(<String>[
    'Ein klarer Gedanke kann den ganzen inneren Lärm beruhigen.',
    'Wenn du eine Richtung wählst, hört das Gehirn auf zu springen und gibt seine ganze Kraft dem, was wirklich wichtig ist.',
    'Genau dann entsteht eine Leichtigkeit im Handeln, als würden die nächsten Schritte von selbst anlaufen.',
    'Das ist keine Magie, sondern gut geführte Aufmerksamkeit, die Spannung in Energie für Bewegung verwandelt.',
    'Je weniger du Ablenkungen fütterst, desto stärker wächst das Gefühl, dass deine Energie lange fließen kann.',
  ]),
  _SpeedReadTheme(<String>[
    'Fokus nimmt keine Energie weg, er hört nur auf, sie zu verstreuen.',
    'Wenn du direkt auf das Ziel schaust, arbeitet jede Sekunde für dich, statt seitlich zu entgleiten.',
    'Das Gehirn mag diese Ordnung, weil in einer klaren Struktur Motivation und Bereitschaft schneller aufwachen.',
    'Nach einer Weile spürst du, dass du dich nicht zwingen musst, weil Bewegung die nächste Bewegung erzeugt und die Aufgabe deine Aufmerksamkeit anzieht.',
    'So entsteht das Gefühl unendlicher Energie: nicht durch Druck, sondern durch eine einfache, ruhige und konstante Richtung.',
  ]),
  _SpeedReadTheme(<String>[
    'Jeder geordnete Text lehrt das Gehirn, dass Chaos nicht den Tag führen muss.',
    'Wenn du im Rhythmus liest, gewinnst du die Kontrolle über deinen Blick, deine Gedanken und das Reaktionstempo zurück.',
    'Das gibt dir einen Schub klarer Energie, weil du aufhörst, gegen deine eigene Ablenkung zu kämpfen.',
    'An die Stelle des Ruckelns tritt Fluss, und Fluss verwandelt sich sehr schnell in Motivation.',
    'Mit der Zeit spürst du, dass Energie nichts Zerbrechliches ist, sondern eine Ressource, die unter Konzentration wächst.',
  ]),
  _SpeedReadTheme(<String>[
    'Ein starker Tag beginnt nicht mit Druck, sondern mit einem gut gesetzten Schritt.',
    'Wenn du ihn bewusst machst, empfängt das Gehirn ein Signal von Sicherheit und öffnet mehr Raum für klare Entscheidungen.',
    'Aus diesem Zustand fällt es leichter, in ein Handeln zu kommen, das dich weiterträgt, ohne dass du dich ständig selbst überzeugen musst.',
    'Motivation ist dann keine Laune mehr, weil sie zu einem Rhythmus wird, der von Körper, Blick und Richtung getragen wird.',
    'Je ruhiger der Start, desto mehr Energie bleibt für tiefe Arbeit, Lernen und mutige Schritte.',
  ]),
  _SpeedReadTheme(<String>[
    'Innere Energie wächst schneller, wenn du aufhörst, sie für Zweifel auszugeben.',
    'Eine fokussierte Lesesession ordnet deine Gedanken und zeigt dem Gehirn, dass es sich lohnt, länger bei der Aufgabe zu bleiben.',
    'Mit jeder weiteren Sekunde wird der Widerstand kleiner und das Gefühl von Wirksamkeit wächst und treibt den nächsten Einsatz an.',
    'Genau dieses Gefühl von Wirksamkeit gibt den stärksten Motivationsimpuls, weil es dich daran erinnert, dass du deine Richtung halten kannst.',
    'Wenn die Richtung stabil ist, bricht die Energie nicht nach einem Moment ab, sondern fließt breiter und sicherer als zuvor.',
  ]),
  _SpeedReadTheme(<String>[
    'Das Gehirn liebt den Moment, in dem du aufhörst, deine Aufmerksamkeit zu zerreißen, und beginnst, sie zu führen.',
    'Dann ermüden selbst schwierigere Sätze nicht so sehr, weil an die Stelle des Chaos ein vorhersagbarer Rhythmus tritt.',
    'Dieser Rhythmus baut Vertrauen in deine eigenen Fähigkeiten auf und gibt einen kurzen, aber klaren Energieschub.',
    'Vertrauen löst eine tiefere Motivation aus als ein kurzer Enthusiasmus, weil es auf echter Erfahrung von Fortschritt beruht.',
    'Je öfter du zu dieser Art von Arbeit zurückkehrst, desto stärker spürst du, dass sich deine Energie in Bewegung erneuern kann.',
  ]),
  _SpeedReadTheme(<String>[
    'Jede bewusst gelesene Zeile stärkt die Fähigkeit, ein Ziel zu halten.',
    'Diese einfache Übung lehrt das Gehirn, dass es nicht auf jeden Reiz reagieren muss, um wach zu bleiben.',
    'In dieser Ersparnis von Reaktionen entsteht zusätzliche Energie, die du auf Lernen, Arbeit und Schaffen lenken kannst.',
    'Plötzlich zeigt sich, dass Motivation keine großen Slogans braucht, wenn ruhige und starke Aufmerksamkeit darunterliegt.',
    'Stabile Aufmerksamkeit ist wie eine Quelle, aus der du lange schöpfen kannst, weil du keine Energie an inneres Ziehen verlierst.',
  ]),
  _SpeedReadTheme(<String>[
    'Wenn du mutig und ohne Zurückgehen liest, lehrst du das Gehirn, seinem eigenen Tempo zu vertrauen.',
    'Dieses Vertrauen spart sehr viel Kraft, die früher durch das ständige Prüfen jedes Details verloren ging.',
    'Freie Energie kehrt in den Kreislauf zurück und beginnt, Konzentration, Gedächtnis und das Gefühl des Vorwärtsgehens zu nähren.',
    'Von hier aus ist es viel leichter, Motivation zu halten, weil Handeln nicht mehr wie Last wirkt, sondern wie Fluss.',
    'Fluss zeigt dir, dass Energie kein begrenzter Vorrat ist, wenn du aufhörst, sie in tausend Richtungen zu zerstreuen.',
  ]),
  _SpeedReadTheme(<String>[
    'Ein starker Geist muss nicht laut sein, er muss nur ausgerichtet sein.',
    'Wenn du ihn auf einen Text einstellst, beginnen Körper und Blick auf derselben Seite zu arbeiten.',
    'Diese Übereinstimmung gibt einen schnellen Schub von Frische, weil das Nervensystem aufhört, gegen sich selbst zu kämpfen.',
    'In solcher Stimmigkeit wird Motivation körperlicher als mental und lässt sich durch die nächsten Aufgaben leichter halten.',
    'Dann spürst du, dass Energie nicht aus Spannung kommt, sondern aus der Ordnung, die du bewusst in dir aufbaust.',
  ]),
  _SpeedReadTheme(<String>[
    'Jeder Moment voller Präsenz lädt das Gehirn besser auf als weitere gedankenlose Reize.',
    'Statt nach Neuheit zu suchen, lernst du, Kraft aus dem zu ziehen, was schon vor dir liegt.',
    'Diese Verschiebung verändert alles, weil Konzentration kein Kampf mehr ist, sondern zu einer Quelle innerer Energie wird.',
    'Wenn Energie aus Präsenz zu fließen beginnt, muss Motivation nicht erzwungen werden, sie kehrt von selbst zurück.',
    'Genau deshalb vermittelt tiefer Fokus das Gefühl von unerschöpflichem Treibstoff, der sich durch klares Handeln erneuert.',
  ]),
  _SpeedReadTheme(<String>[
    'Lesen im Rhythmus ist Training für die Augen, aber noch mehr für den Mut, die Richtung zu halten.',
    'Jeder nächste Text erinnert dich daran, dass du tiefer gehen kannst, ohne zu alten Gewohnheiten zurückzukehren.',
    'Dieser Mut weckt Energie, weil das Gehirn Bewegung mag, die Sinn hat und nicht nach einem Moment zerfällt.',
    'Aus solcher Erfahrung wächst eine reifere Motivation als bloße Aufregung, weil sie auf Ruhe und Wiederholung aufbaut.',
    'Wiederholung macht nicht schläfrig, sie macht stärker, wenn sie zu mehr Klarheit, Kraft und dem Gefühl ständigen Wachstums führt.',
  ]),
  _SpeedReadTheme(<String>[
    'Je klarer das Ziel, desto weniger Energie wird für den Anfang gebraucht.',
    'Ein fokussierter Satz kann das Gehirn besser ausrichten als ein langer innerer Monolog darüber, dass du dich endlich sammeln musst.',
    'Wenn Ziel und Handlung sich in einem Moment treffen, entsteht eine leichte Welle von Antrieb, die dich weiterträgt.',
    'Dieser Antrieb wird schnell zu dauerhafter Motivation, weil du die Wirkung im Rhythmus der Arbeit selbst siehst und nicht nur im Endergebnis.',
    'Dadurch kann Energie endlos wirken, weil sie sich jedes Mal erneuert, wenn du zu einem einfachen Ziel zurückkehrst.',
  ]),
  _SpeedReadTheme(<String>[
    'Alles wird leichter, wenn der Blick aufhört zu wandern und einen Schwerpunkt findet.',
    'Das Gehirn liest das sofort als Ordnung und gibt mehr Ressourcen an das Verstehen statt an die Suche nach Reizen.',
    'Diese zurückgewonnenen Ressourcen fühlst du als frischen Zufluss von Energie, der das Denken ohne künstliche Spannung beschleunigt.',
    'Genau diese Art von Energie unterstützt Motivation am besten, weil sie nicht ausbrennt, sondern mit jeder Minute stärker wird.',
    'Wenn du diese Arbeitsweise hältst, wirst du entdecken, dass die Kraft der Konzentration fast ohne Ende wachsen kann.',
  ]),
  _SpeedReadTheme(<String>[
    'Ein kurzer Einstieg in einen Text kann das Gehirn schneller wecken als ein langer Kampf mit dem Aufschieben.',
    'Ein paar Sekunden echter Konzentration reichen aus, damit das Nervensystem von Widerstand auf Bereitschaft umschaltet.',
    'Bereitschaft setzt sofort Energie frei, die vorher in Spannung und Verzögerung blockiert war.',
    'Wenn du diesen Fluss spürst, ist Motivation kein Versprechen für später mehr, sondern handelt hier und jetzt im Körper.',
    'In diesem Zustand fällt es leichter zu glauben, dass Energie sich erneuern kann, wenn du immer wieder zu bewusster Bewegung zurückkehrst.',
  ]),
  _SpeedReadTheme(<String>[
    'Du brauchst keine perfekte Stimmung, um in einen starken Arbeitsmodus zu starten.',
    'Du brauchst ein klares Signal für das Gehirn, dass jetzt diese Richtung zählt und nichts anderes.',
    'Wenn ein solches Signal regelmäßig auftaucht, wächst die Energie, weil die Kosten ständiger Entscheidungen sinken.',
    'Weniger Reibung bedeutet mehr Raum für Motivation, die kein Kampf mehr ist, sondern eine natürliche Folge von Ordnung.',
    'In Ordnung steckt mehr Kraft, als es am Anfang scheint, weil sie dich viel länger tragen kann als ein kurzer Begeisterungsschub.',
  ]),
  _SpeedReadTheme(<String>[
    'Jeder Text in dieser Serie erinnert dich daran, dass Konzentration eine Quelle von Kraft ist und nicht nur ein Werkzeug zum Erledigen einer Aufgabe.',
    'Wenn du Aufmerksamkeit an einem Ort hältst, baut das Gehirn schneller ein Gefühl von Sinn auf und hört auf, Energie beim Abscannen von allem zu verlieren.',
    'Dieses Gefühl von Sinn stärkt die Lust zu handeln, weil du siehst, dass jeder nächste Schritt wirklich etwas ordnet.',
    'Geordnete Bewegung gibt stabile Motivation, die nach dem ersten Erfolg nicht verschwindet, sondern eine weitere Welle von Antrieb aufbaut.',
    'Dann beginnst du zu verstehen, dass Energie endlos wirken kann, wenn du sie vor Chaos schützt und mit klarer Richtung nährst.',
  ]),
  _SpeedReadTheme(<String>[
    'Ruhiges Lesen im Rhythmus öffnet einen Raum, in dem Gedanken zugleich schärfer und leichter werden.',
    'Diese Verbindung von Schärfe und Leichtigkeit ist eines der besten Zeichen dafür, dass das Gehirn ökonomisch arbeitet.',
    'Ökonomisches Arbeiten lässt mehr Energie für die nächsten Aufgaben, weil im Kampf mit dir selbst weniger verloren geht.',
    'Aus einem solchen Zustand heraus stärkt sich Motivation von selbst, weil Körper und Geist keine gegensätzlichen Signale mehr senden.',
    'Je länger du diese Stimmigkeit hältst, desto realer wird das Gefühl einer endlosen Reserve innerer Kraft.',
  ]),
  _SpeedReadTheme(<String>[
    'Deine Aufmerksamkeit wächst dort, wo du sie regelmäßig hinführst.',
    'Jeder gut gelesene Text hinterlässt eine Spur größerer Sicherheit, dass du tief hineingehen und länger dort bleiben kannst.',
    'Diese Sicherheit nährt Energie, weil sie die Angst vor Anstrengung kleiner macht und dich ohne innere Bremse vorwärtsgehen lässt.',
    'Wenn die Bremse schwächer wird, wird Motivation stabiler, reifer und bereit für lange Abschnitte von Arbeit.',
    'Genau darin liegt die Kraft des Trainings: Du baust in dir eine Energiequelle auf, die nicht nur von einer vorübergehenden Stimmung abhängt.',
  ]),
  _SpeedReadTheme(<String>[
    'Je ruhiger du in eine Aufgabe einsteigst, desto stärker kannst du später beschleunigen.',
    'Das ist ein Paradox, das das Gehirn sehr gut versteht, weil es die meiste Kraft gibt, wenn es Klarheit und kein Chaos spürt.',
    'In Klarheit entsteht frische Energie, die Aufmerksamkeit, Gedächtnis und Handlungswillen auf ein höheres Niveau hebt.',
    'Wenn du einen solchen Zustand ein paarmal spürst, ist Motivation kein Zufall mehr, sondern die Fähigkeit, zur Kraft zurückzukehren.',
    'Dann sehen selbst schwierigere Herausforderungen wie ein Raum aus, in dem Energie freigesetzt werden kann, die nicht schnell endet.',
  ]),
];

_SpeedReadCategoryDefinition _speedReadCategoryDefinition(
  SpeedReadCategory category,
) {
  return _speedReadCategories.firstWhere(
    (_SpeedReadCategoryDefinition definition) =>
        definition.category == category,
  );
}

List<_SpeedReadLevelDefinition> _speedReadLevelsForCategory(
  SpeedReadCategory category,
) {
  return _speedReadCategoryDefinition(category).levels;
}

int _speedReadPassageCountForCategory(SpeedReadCategory category) {
  return _speedReadThemesForCategory(category).length;
}

String _speedReadSeriesValue(SpeedReadCategory category) {
  final categoryDefinition = _speedReadCategoryDefinition(category);
  return '${_speedReadPassageCountForCategory(category)} ${categoryDefinition.seriesUnitLabel}';
}

List<_SpeedReadTheme> _speedReadThemesForCategory(SpeedReadCategory category) {
  return switch (category) {
    SpeedReadCategory.polish => _speedReadPolishThemes,
    SpeedReadCategory.english => _speedReadEnglishThemes,
    SpeedReadCategory.german => _speedReadGermanThemes,
  };
}

List<String> _speedReadPassagesForSelection({
  required SpeedReadCategory category,
  required SpeedReadLevel level,
}) {
  final segmentsToUse = _speedReadLevelsForCategory(category)
      .firstWhere(
        (_SpeedReadLevelDefinition definition) => definition.level == level,
      )
      .segmentCount;

  return _speedReadThemesForCategory(category)
      .map(
        (_SpeedReadTheme theme) => theme.segments
            .take(min(segmentsToUse, theme.segments.length))
            .join(' '),
      )
      .toList(growable: false);
}

List<String> _speedReadWordsForPassage(String passage) {
  return passage
      .split(RegExp(r'\s+'))
      .where((String word) => word.trim().isNotEmpty)
      .toList(growable: false);
}

class _SpeedReadLevelSelectorCard extends StatefulWidget {
  const _SpeedReadLevelSelectorCard({
    required this.accent,
    required this.selectedLevel,
    required this.onLevelChanged,
  });

  final Color accent;
  final SpeedReadLevel selectedLevel;
  final ValueChanged<SpeedReadLevel> onLevelChanged;

  @override
  State<_SpeedReadLevelSelectorCard> createState() =>
      _SpeedReadLevelSelectorCardState();
}

class _SpeedReadLevelSelectorCardState
    extends State<_SpeedReadLevelSelectorCard> {
  late final PageController _pageController;

  @override
  void initState() {
    super.initState();
    _pageController = PageController(initialPage: widget.selectedLevel.index);
  }

  @override
  void didUpdateWidget(covariant _SpeedReadLevelSelectorCard oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.selectedLevel == oldWidget.selectedLevel ||
        !_pageController.hasClients) {
      return;
    }

    _pageController.animateToPage(
      widget.selectedLevel.index,
      duration: const Duration(milliseconds: 220),
      curve: Curves.easeOutCubic,
    );
  }

  @override
  void dispose() {
    _pageController.dispose();
    super.dispose();
  }

  void _handleLevelTap(SpeedReadLevel level) {
    if (widget.selectedLevel == level) {
      return;
    }

    widget.onLevelChanged(level);
  }

  void _handlePageChanged(int index) {
    final nextLevel = _speedReadPolishLevels[index].level;
    if (nextLevel == widget.selectedLevel) {
      return;
    }

    widget.onLevelChanged(nextLevel);
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final palette = context.appPalette;
    final selectedIndex = widget.selectedLevel.index;

    return SurfaceCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          const SectionHeader(eyebrow: 'Poziomy', title: 'Poziomy gry'),
          const SizedBox(height: 18),
          Container(
            width: double.infinity,
            height: 170,
            padding: const EdgeInsets.fromLTRB(18, 16, 18, 14),
            decoration: BoxDecoration(
              gradient: LinearGradient(
                begin: Alignment.topLeft,
                end: Alignment.bottomRight,
                colors: <Color>[
                  widget.accent.withValues(alpha: 0.16),
                  palette.surfaceStrong,
                ],
              ),
              borderRadius: BorderRadius.circular(26),
              border: Border.all(color: widget.accent.withValues(alpha: 0.18)),
            ),
            child: Column(
              children: <Widget>[
                Expanded(
                  child: PageView.builder(
                    controller: _pageController,
                    itemCount: _speedReadPolishLevels.length,
                    physics: const BouncingScrollPhysics(),
                    onPageChanged: _handlePageChanged,
                    itemBuilder: (BuildContext context, int index) {
                      final level = _speedReadPolishLevels[index];
                      final isSelected = index == selectedIndex;

                      return GestureDetector(
                        onTap: () => _handleLevelTap(level.level),
                        child: Container(
                          key: ValueKey<String>(
                            'speed-read-level-card-${level.level.name}',
                          ),
                          width: double.infinity,
                          padding: const EdgeInsets.all(18),
                          decoration: BoxDecoration(
                            color: palette.surface.withValues(alpha: 0.92),
                            borderRadius: BorderRadius.circular(22),
                            border: Border.all(
                              color: isSelected
                                  ? widget.accent.withValues(alpha: 0.42)
                                  : widget.accent.withValues(alpha: 0.24),
                            ),
                          ),
                          child: Center(
                            child: Text(
                              level.label,
                              textAlign: TextAlign.center,
                              style: theme.textTheme.titleLarge?.copyWith(
                                color: palette.primaryText,
                                fontWeight: FontWeight.w900,
                              ),
                            ),
                          ),
                        ),
                      );
                    },
                  ),
                ),
                const SizedBox(height: 12),
                Row(
                  mainAxisSize: MainAxisSize.min,
                  children: List<Widget>.generate(
                    _speedReadPolishLevels.length,
                    (int index) {
                      final bool selected = index == selectedIndex;
                      return AnimatedContainer(
                        duration: const Duration(milliseconds: 180),
                        margin: EdgeInsets.only(left: index == 0 ? 0 : 6),
                        width: selected ? 18 : 8,
                        height: 8,
                        decoration: BoxDecoration(
                          color: selected
                              ? widget.accent
                              : widget.accent.withValues(alpha: 0.24),
                          borderRadius: BorderRadius.circular(999),
                        ),
                      );
                    },
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class SpeedReadTrainer extends StatefulWidget {
  const SpeedReadTrainer({
    super.key,
    required this.accent,
    this.fullscreenOnStart = false,
    this.initialLevel = SpeedReadLevel.one,
    this.showLevelSelector = true,
    this.onSessionStarted,
  });

  final Color accent;
  final bool fullscreenOnStart;
  final SpeedReadLevel initialLevel;
  final bool showLevelSelector;
  final VoidCallback? onSessionStarted;

  @override
  State<SpeedReadTrainer> createState() => _SpeedReadTrainerState();
}

class _SpeedReadTrainerState extends State<SpeedReadTrainer> {
  late SpeedReadLevel _selectedLevel;
  late int _selectedWordsPerMinute;

  static const SpeedReadCategory _fixedCategory = SpeedReadCategory.polish;

  @override
  void initState() {
    super.initState();
    final initialLevels = _speedReadLevelsForCategory(_fixedCategory);
    _selectedLevel =
        initialLevels.any(
          (_SpeedReadLevelDefinition level) =>
              level.level == widget.initialLevel,
        )
        ? widget.initialLevel
        : initialLevels.first.level;
    _selectedWordsPerMinute = _currentLevel.defaultWordsPerMinute;
  }

  List<_SpeedReadLevelDefinition> get _availableLevels =>
      _speedReadLevelsForCategory(_fixedCategory);

  _SpeedReadLevelDefinition get _currentLevel => _availableLevels.firstWhere(
    (_SpeedReadLevelDefinition level) => level.level == _selectedLevel,
    orElse: () => _availableLevels.first,
  );

  @override
  void didUpdateWidget(covariant SpeedReadTrainer oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.initialLevel == oldWidget.initialLevel) {
      return;
    }

    final levelDefinition = _availableLevels.firstWhere(
      (_SpeedReadLevelDefinition entry) => entry.level == widget.initialLevel,
      orElse: () => _availableLevels.first,
    );
    setState(() {
      _selectedLevel = levelDefinition.level;
      _selectedWordsPerMinute = levelDefinition.defaultWordsPerMinute;
    });
  }

  void _selectLevel(SpeedReadLevel level) {
    final levelDefinition = _availableLevels.firstWhere(
      (_SpeedReadLevelDefinition entry) => entry.level == level,
    );
    setState(() {
      _selectedLevel = level;
      _selectedWordsPerMinute = levelDefinition.defaultWordsPerMinute;
    });
  }

  void _setWordsPerMinute(double value) {
    setState(() {
      _selectedWordsPerMinute = value.round();
    });
  }

  Future<void> _openSession() {
    widget.onSessionStarted?.call();

    final session = SpeedReadSessionView(
      accent: widget.accent,
      category: _fixedCategory,
      level: _selectedLevel,
      wordsPerMinute: _selectedWordsPerMinute,
      autoStart: true,
      autoExitOnFinish: true,
    );

    const routeTitle = 'Sprint Czytania';

    final route = widget.fullscreenOnStart
        ? _buildExerciseSessionRoute<void>(
            builder: (BuildContext context) {
              return FullscreenTrainerPage(
                title: routeTitle,
                accent: widget.accent,
                expandBody: true,
                child: session,
              );
            },
          )
        : MaterialPageRoute<void>(
            builder: (BuildContext context) {
              return Scaffold(
                appBar: AppBar(title: Text(routeTitle)),
                body: SafeArea(
                  child: Padding(
                    padding: const EdgeInsets.all(20),
                    child: session,
                  ),
                ),
              );
            },
          );

    return Navigator.of(context).push<void>(route);
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final rhythmLabel = '$_selectedWordsPerMinute sł/min • rytm 2, 1, START';
    final seriesValue = _speedReadSeriesValue(_fixedCategory);

    if (!widget.showLevelSelector) {
      return Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Row(
            children: <Widget>[
              Expanded(
                child: StatStrip(
                  label: 'Zakres',
                  value:
                      '$_speedReadMinWordsPerMinute-$_speedReadMaxWordsPerMinute',
                  tint: widget.accent,
                ),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: StatStrip(
                  label: 'Seria',
                  value: seriesValue,
                  tint: widget.accent,
                ),
              ),
            ],
          ),
          const SizedBox(height: 18),
          Container(
            width: double.infinity,
            padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 16),
            decoration: BoxDecoration(
              color: Colors.white,
              borderRadius: BorderRadius.circular(22),
              border: Border.all(color: widget.accent.withValues(alpha: 0.16)),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                Row(
                  children: <Widget>[
                    Text(
                      'Tempo',
                      style: theme.textTheme.titleMedium?.copyWith(
                        color: const Color(0xFF16212B),
                        fontWeight: FontWeight.w800,
                      ),
                    ),
                    const Spacer(),
                    Text(
                      '$_selectedWordsPerMinute sł/min',
                      style: theme.textTheme.bodyMedium?.copyWith(
                        color: widget.accent,
                        fontWeight: FontWeight.w800,
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 10),
                SliderTheme(
                  data: SliderTheme.of(context).copyWith(
                    activeTrackColor: widget.accent,
                    inactiveTrackColor: const Color(0xFFD9DFE4),
                    thumbColor: widget.accent,
                    overlayColor: widget.accent.withValues(alpha: 0.14),
                    trackHeight: 6,
                    thumbShape: const RoundSliderThumbShape(
                      enabledThumbRadius: 9,
                    ),
                  ),
                  child: Slider(
                    key: const ValueKey<String>('speed-read-speed-slider'),
                    min: _speedReadMinWordsPerMinute.toDouble(),
                    max: _speedReadMaxWordsPerMinute.toDouble(),
                    divisions:
                        (_speedReadMaxWordsPerMinute -
                            _speedReadMinWordsPerMinute) ~/
                        _speedReadWordsPerMinuteStep,
                    value: _selectedWordsPerMinute.toDouble(),
                    label: '$_selectedWordsPerMinute sł/min',
                    onChanged: _setWordsPerMinute,
                  ),
                ),
                Row(
                  children: <Widget>[
                    Text(
                      '$_speedReadMinWordsPerMinute',
                      style: theme.textTheme.labelMedium?.copyWith(
                        color: const Color(0xFF7A8791),
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                    const Spacer(),
                    Text(
                      '$_speedReadMaxWordsPerMinute sł/min',
                      style: theme.textTheme.labelMedium?.copyWith(
                        color: const Color(0xFF7A8791),
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                  ],
                ),
              ],
            ),
          ),
          const SizedBox(height: 18),
          Center(
            child: ConstrainedBox(
              constraints: const BoxConstraints(minWidth: 220, maxWidth: 280),
              child: FilledButton(
                onPressed: _openSession,
                child: const Text('Start sesji'),
              ),
            ),
          ),
        ],
      );
    }

    final content = Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        Row(
          children: <Widget>[
            Expanded(
              child: StatStrip(
                label: 'Zakres',
                value:
                    '$_speedReadMinWordsPerMinute-$_speedReadMaxWordsPerMinute',
                tint: widget.accent,
              ),
            ),
            const SizedBox(width: 10),
            Expanded(
              child: StatStrip(
                label: 'Seria',
                value: seriesValue,
                tint: widget.accent,
              ),
            ),
          ],
        ),
        const SizedBox(height: 18),
        _SpeedReadLevelSelectorCard(
          accent: widget.accent,
          selectedLevel: _selectedLevel,
          onLevelChanged: _selectLevel,
        ),
        const SizedBox(height: 18),
        Container(
          width: double.infinity,
          padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 16),
          decoration: BoxDecoration(
            color: Colors.white,
            borderRadius: BorderRadius.circular(22),
            border: Border.all(color: widget.accent.withValues(alpha: 0.16)),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              Row(
                children: <Widget>[
                  Text(
                    'Tempo',
                    style: theme.textTheme.titleMedium?.copyWith(
                      color: const Color(0xFF16212B),
                      fontWeight: FontWeight.w800,
                    ),
                  ),
                  const Spacer(),
                  Text(
                    '$_selectedWordsPerMinute sł/min',
                    style: theme.textTheme.bodyMedium?.copyWith(
                      color: widget.accent,
                      fontWeight: FontWeight.w800,
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 10),
              SliderTheme(
                data: SliderTheme.of(context).copyWith(
                  activeTrackColor: widget.accent,
                  inactiveTrackColor: const Color(0xFFD9DFE4),
                  thumbColor: widget.accent,
                  overlayColor: widget.accent.withValues(alpha: 0.14),
                  trackHeight: 6,
                  thumbShape: const RoundSliderThumbShape(
                    enabledThumbRadius: 9,
                  ),
                ),
                child: Slider(
                  key: const ValueKey<String>('speed-read-speed-slider'),
                  min: _speedReadMinWordsPerMinute.toDouble(),
                  max: _speedReadMaxWordsPerMinute.toDouble(),
                  divisions:
                      (_speedReadMaxWordsPerMinute -
                          _speedReadMinWordsPerMinute) ~/
                      _speedReadWordsPerMinuteStep,
                  value: _selectedWordsPerMinute.toDouble(),
                  label: '$_selectedWordsPerMinute sł/min',
                  onChanged: _setWordsPerMinute,
                ),
              ),
              Row(
                children: <Widget>[
                  Text(
                    '$_speedReadMinWordsPerMinute',
                    style: theme.textTheme.labelMedium?.copyWith(
                      color: const Color(0xFF7A8791),
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                  const Spacer(),
                  Text(
                    '$_speedReadMaxWordsPerMinute sł/min',
                    style: theme.textTheme.labelMedium?.copyWith(
                      color: const Color(0xFF7A8791),
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                ],
              ),
            ],
          ),
        ),
        const SizedBox(height: 18),
        Container(
          width: double.infinity,
          padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 24),
          decoration: BoxDecoration(
            color: const Color(0xFFF9F5EF),
            borderRadius: BorderRadius.circular(26),
          ),
          child: Column(
            children: <Widget>[
              Text(
                _currentLevel.label,
                textAlign: TextAlign.center,
                style: theme.textTheme.titleMedium?.copyWith(
                  color: const Color(0xFF16212B),
                  fontWeight: FontWeight.w800,
                ),
              ),
              const SizedBox(height: 16),
              Container(
                padding: const EdgeInsets.symmetric(
                  horizontal: 14,
                  vertical: 10,
                ),
                decoration: BoxDecoration(
                  color: widget.accent.withValues(alpha: 0.12),
                  borderRadius: BorderRadius.circular(18),
                ),
                child: Text(
                  rhythmLabel,
                  style: theme.textTheme.bodyMedium?.copyWith(
                    color: const Color(0xFF16212B),
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ),
            ],
          ),
        ),
        const SizedBox(height: 20),
        Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(minWidth: 220, maxWidth: 280),
            child: FilledButton(
              onPressed: _openSession,
              child: const Text('Start sesji'),
            ),
          ),
        ),
      ],
    );

    return LayoutBuilder(
      builder: (BuildContext context, BoxConstraints constraints) {
        if (!constraints.hasBoundedHeight) {
          return content;
        }

        return SingleChildScrollView(
          child: ConstrainedBox(
            constraints: BoxConstraints(minHeight: constraints.maxHeight),
            child: content,
          ),
        );
      },
    );
  }
}

class SpeedReadSessionView extends StatefulWidget {
  const SpeedReadSessionView({
    super.key,
    required this.accent,
    required this.category,
    required this.level,
    this.autoStart = false,
    this.initialPassageIndex = 0,
    this.wordsPerMinute = _speedReadDefaultWordsPerMinute,
    this.autoExitOnFinish = false,
  });

  final Color accent;
  final SpeedReadCategory category;
  final SpeedReadLevel level;
  final bool autoStart;
  final int initialPassageIndex;
  final int wordsPerMinute;
  final bool autoExitOnFinish;

  @override
  State<SpeedReadSessionView> createState() => _SpeedReadSessionViewState();
}

class _SpeedReadSessionViewState extends State<SpeedReadSessionView> {
  static const int _initialCountdownSeconds = 3;
  static const int _betweenPassagesCountdownSeconds = 2;

  Timer? _countdownTimer;
  Timer? _wordTimer;
  Timer? _finishExitTimer;
  late final List<String> _passages;
  late List<String> _currentWords;
  late int _currentPassageIndex;
  int _currentWordIndex = 0;
  int? _countdownValue;
  bool _finished = false;
  bool _reading = false;
  bool _countdownToNextPassage = false;

  @override
  void initState() {
    super.initState();
    _passages = _speedReadPassagesForSelection(
      category: widget.category,
      level: widget.level,
    );
    _currentPassageIndex = widget.initialPassageIndex.clamp(
      0,
      _passages.length - 1,
    );
    _currentWords = _speedReadWordsForPassage(_passages[_currentPassageIndex]);

    if (widget.autoStart) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) {
          _startSession();
        }
      });
    }
  }

  bool get _isCountingDown => _countdownValue != null;

  String get _countdownLabel {
    final value = _countdownValue;
    if (value == null) {
      return '';
    }
    return value == 0 ? 'START' : '$value';
  }

  double get _progress {
    if (_finished) {
      return 1.0;
    }

    if (_reading) {
      final wordFraction = _currentWords.isEmpty
          ? 1.0
          : (_currentWordIndex + 1) / _currentWords.length;
      return ((_currentPassageIndex + wordFraction) / _passages.length).clamp(
        0.0,
        1.0,
      );
    }

    if (_countdownToNextPassage) {
      return ((_currentPassageIndex + 1) / _passages.length).clamp(0.0, 1.0);
    }

    return 0.0;
  }

  int get _wordDisplayMilliseconds {
    return max(60, (60000 / widget.wordsPerMinute).round());
  }

  void _prepareCurrentWords() {
    final words = _speedReadWordsForPassage(_passages[_currentPassageIndex]);
    _currentWords = words.isEmpty ? <String>['...'] : words;
    _currentWordIndex = 0;
  }

  void _startSession() {
    _finishExitTimer?.cancel();
    _countdownTimer?.cancel();
    _wordTimer?.cancel();

    setState(() {
      _finished = false;
      _reading = false;
      _countdownToNextPassage = false;
      _currentPassageIndex = widget.initialPassageIndex.clamp(
        0,
        _passages.length - 1,
      );
    });
    _prepareCurrentWords();

    _startCountdown(
      seconds: _initialCountdownSeconds,
      countdownToNextPassage: false,
      onComplete: _beginCurrentPassage,
    );
  }

  void _startCountdown({
    required int seconds,
    required bool countdownToNextPassage,
    required VoidCallback onComplete,
  }) {
    _finishExitTimer?.cancel();
    _countdownTimer?.cancel();
    _wordTimer?.cancel();

    setState(() {
      _reading = false;
      _countdownToNextPassage = countdownToNextPassage;
      _countdownValue = seconds;
    });

    _countdownTimer = Timer.periodic(const Duration(seconds: 1), (Timer timer) {
      if (!mounted) {
        timer.cancel();
        return;
      }

      final current = _countdownValue;
      if (current == null) {
        timer.cancel();
        return;
      }

      if (current <= 0) {
        timer.cancel();
        onComplete();
        return;
      }

      setState(() {
        _countdownValue = current - 1;
      });
    });
  }

  void _beginCurrentPassage() {
    _countdownTimer?.cancel();
    _wordTimer?.cancel();
    _prepareCurrentWords();

    setState(() {
      _countdownValue = null;
      _countdownToNextPassage = false;
      _reading = true;
    });

    _wordTimer = Timer.periodic(
      Duration(milliseconds: _wordDisplayMilliseconds),
      (Timer timer) {
        if (!mounted) {
          timer.cancel();
          return;
        }

        if (_currentWordIndex >= _currentWords.length - 1) {
          timer.cancel();
          if (_currentPassageIndex >= _passages.length - 1) {
            _finishSession();
          } else {
            _startCountdown(
              seconds: _betweenPassagesCountdownSeconds,
              countdownToNextPassage: true,
              onComplete: _advanceToNextPassage,
            );
          }
          return;
        }

        setState(() {
          _currentWordIndex += 1;
        });
      },
    );
  }

  void _advanceToNextPassage() {
    setState(() {
      _currentPassageIndex += 1;
    });
    _beginCurrentPassage();
  }

  void _finishSession() {
    _finishExitTimer?.cancel();
    _countdownTimer?.cancel();
    _wordTimer?.cancel();

    setState(() {
      _finished = true;
      _reading = false;
      _countdownToNextPassage = false;
      _countdownValue = null;
    });

    if (!widget.autoExitOnFinish) {
      return;
    }

    _finishExitTimer = Timer(const Duration(seconds: 2), () {
      if (!mounted) {
        return;
      }
      Navigator.of(context).maybePop();
    });
  }

  @override
  void dispose() {
    _finishExitTimer?.cancel();
    _countdownTimer?.cancel();
    _wordTimer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return Padding(
      padding: const EdgeInsets.all(24),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          ClipRRect(
            borderRadius: BorderRadius.circular(999),
            child: LinearProgressIndicator(
              minHeight: 10,
              value: _progress,
              backgroundColor: widget.accent.withValues(alpha: 0.14),
              valueColor: AlwaysStoppedAnimation<Color>(widget.accent),
            ),
          ),
          const SizedBox(height: 20),
          Expanded(
            child: AnimatedSwitcher(
              duration: const Duration(milliseconds: 220),
              child: _finished
                  ? Container(
                      key: const ValueKey<String>('speed-read-finished'),
                      padding: const EdgeInsets.all(28),
                      decoration: BoxDecoration(
                        color: const Color(0xFFF9F5EF),
                        borderRadius: BorderRadius.circular(28),
                      ),
                      child: Column(
                        mainAxisAlignment: MainAxisAlignment.center,
                        children: <Widget>[
                          Text(
                            'Koniec serii',
                            textAlign: TextAlign.center,
                            style: theme.textTheme.headlineMedium?.copyWith(
                              color: const Color(0xFF16212B),
                              fontWeight: FontWeight.w900,
                            ),
                          ),
                          const SizedBox(height: 14),
                          Text(
                            'Masz za sobą ${_speedReadSeriesValue(widget.category)}. Zatrzymaj na chwilę sens i rytm, które zostały w głowie.',
                            textAlign: TextAlign.center,
                            style: theme.textTheme.bodyLarge?.copyWith(
                              color: const Color(0xFF4F5C67),
                              height: 1.5,
                            ),
                          ),
                        ],
                      ),
                    )
                  : _isCountingDown
                  ? Container(
                      key: const ValueKey<String>('speed-read-countdown-card'),
                      padding: const EdgeInsets.all(28),
                      decoration: BoxDecoration(
                        color: const Color(0xFF16212B),
                        borderRadius: BorderRadius.circular(28),
                      ),
                      child: Center(
                        child: Text(
                          _countdownLabel,
                          key: ValueKey<String>(
                            'speed-read-countdown-$_countdownLabel',
                          ),
                          textAlign: TextAlign.center,
                          style: theme.textTheme.displayLarge?.copyWith(
                            color: Colors.white,
                            fontWeight: FontWeight.w900,
                            letterSpacing: _countdownLabel == 'START' ? 1.2 : 0,
                          ),
                        ),
                      ),
                    )
                  : Container(
                      key: ValueKey<String>(
                        'speed-read-passage-${_currentPassageIndex + 1}',
                      ),
                      padding: const EdgeInsets.all(28),
                      decoration: BoxDecoration(
                        color: const Color(0xFFF9F5EF),
                        borderRadius: BorderRadius.circular(28),
                      ),
                      child: Center(
                        child: Padding(
                          padding: const EdgeInsets.symmetric(horizontal: 12),
                          child: SizedBox(
                            width: double.infinity,
                            child: FittedBox(
                              fit: BoxFit.scaleDown,
                              child: AnimatedSwitcher(
                                duration: const Duration(milliseconds: 110),
                                child: Text(
                                  _currentWords[_currentWordIndex],
                                  key: ValueKey<String>(
                                    'speed-read-word-${_currentPassageIndex + 1}-${_currentWordIndex + 1}',
                                  ),
                                  textAlign: TextAlign.center,
                                  maxLines: 1,
                                  softWrap: false,
                                  style: theme.textTheme.displayLarge?.copyWith(
                                    color: const Color(0xFF16212B),
                                    fontWeight: FontWeight.w900,
                                    letterSpacing: 0.2,
                                  ),
                                ),
                              ),
                            ),
                          ),
                        ),
                      ),
                    ),
            ),
          ),
        ],
      ),
    );
  }
}

enum _FocusGameKind { anchor, pursuit, peripheral }

class _FocusGameDefinition {
  const _FocusGameDefinition({
    required this.kind,
    required this.label,
    required this.title,
    required this.summary,
    required this.focusLabel,
    required this.difficultyLabel,
    required this.icon,
  });

  final _FocusGameKind kind;
  final String label;
  final String title;
  final String summary;
  final String focusLabel;
  final String difficultyLabel;
  final IconData icon;
}

const List<_FocusGameDefinition> _focusGameDefinitions = <_FocusGameDefinition>[
  _FocusGameDefinition(
    kind: _FocusGameKind.anchor,
    label: 'Punkt',
    title: 'Punkt Stały',
    summary:
        'Jeden spokojny punkt w centrum. Trening prostego utrzymania wzroku i powrotu do środka.',
    focusLabel: 'Fiksacja',
    difficultyLabel: '2-10 min',
    icon: Icons.radio_button_checked_rounded,
  ),
  _FocusGameDefinition(
    kind: _FocusGameKind.pursuit,
    label: 'Płynny pościg',
    title: 'Płynny Pościg',
    summary:
        'Kropka płynie po różnych torach i trzeba śledzić ją samym wzrokiem, bez wyprzedzania ruchem głowy.',
    focusLabel: 'Śledzenie oka',
    difficultyLabel: 'Koło • 8 • zygzak',
    icon: Icons.gesture_rounded,
  ),
  _FocusGameDefinition(
    kind: _FocusGameKind.peripheral,
    label: 'Centrum i peryferia',
    title: 'Centrum i Peryferia',
    summary:
        'Wzrok zostaje w środku, a reakcja wchodzi tylko wtedy, gdy po bokach mignie właściwy sygnał.',
    focusLabel: 'Uwaga peryferyjna',
    difficultyLabel: 'Tap na bodziec',
    icon: Icons.blur_on_rounded,
  ),
];

enum _PursuitTrackPattern { circle, figureEight, zigzag }

const Duration _pursuitPatternDuration = Duration(seconds: 7);

_PursuitTrackPattern _pursuitPatternForElapsed(Duration elapsed) {
  final int patternIndex =
      (elapsed.inMilliseconds ~/ _pursuitPatternDuration.inMilliseconds) %
      _PursuitTrackPattern.values.length;
  return _PursuitTrackPattern.values[patternIndex];
}

double _pursuitPatternProgress(Duration elapsed) {
  final int elapsedInPattern =
      elapsed.inMilliseconds % _pursuitPatternDuration.inMilliseconds;
  return elapsedInPattern / _pursuitPatternDuration.inMilliseconds;
}

double _triangleWave(double progress) {
  final phase = progress % 1.0;
  return phase < 0.5 ? (-1 + (4 * phase)) : (3 - (4 * phase));
}

Alignment _pursuitAlignmentForElapsed(Duration elapsed) {
  final pattern = _pursuitPatternForElapsed(elapsed);
  final progress = _pursuitPatternProgress(elapsed);

  return switch (pattern) {
    _PursuitTrackPattern.circle => Alignment(
      0.72 * cos(progress * 2 * pi),
      0.52 * sin(progress * 2 * pi),
    ),
    _PursuitTrackPattern.figureEight => Alignment(
      0.76 * sin(progress * 2 * pi),
      0.38 * sin(progress * 4 * pi),
    ),
    _PursuitTrackPattern.zigzag => Alignment(
      0.74 * _triangleWave(progress),
      progress < 0.25
          ? -0.46
          : progress < 0.5
          ? 0.46
          : progress < 0.75
          ? -0.46
          : 0.46,
    ),
  };
}

enum _PeripheralCueSlot {
  up(Alignment(0, -0.82)),
  right(Alignment(0.82, 0)),
  down(Alignment(0, 0.82)),
  left(Alignment(-0.82, 0));

  const _PeripheralCueSlot(this.alignment);

  final Alignment alignment;
}

enum _FlowRunnerEntityKind { obstacle, bonus }

enum _FlowRunnerPlayerSkin { orb, star, triangle, cylinder, waterBottle }

extension _FlowRunnerPlayerSkinPresentation on _FlowRunnerPlayerSkin {
  String get id => name;

  String get label => switch (this) {
    _FlowRunnerPlayerSkin.orb => 'Kula',
    _FlowRunnerPlayerSkin.star => 'Gwiazda',
    _FlowRunnerPlayerSkin.triangle => 'Trójkąt',
    _FlowRunnerPlayerSkin.cylinder => 'Walec',
    _FlowRunnerPlayerSkin.waterBottle => 'Browar',
  };

  int get cost => switch (this) {
    _FlowRunnerPlayerSkin.orb => 0,
    _FlowRunnerPlayerSkin.star => 50,
    _FlowRunnerPlayerSkin.triangle => 25,
    _FlowRunnerPlayerSkin.cylinder => 100,
    _FlowRunnerPlayerSkin.waterBottle => 5,
  };
}

const List<_FlowRunnerPlayerSkin> _flowRunnerUnlockableSkins =
    <_FlowRunnerPlayerSkin>[
      _FlowRunnerPlayerSkin.orb,
      _FlowRunnerPlayerSkin.waterBottle,
      _FlowRunnerPlayerSkin.triangle,
      _FlowRunnerPlayerSkin.star,
      _FlowRunnerPlayerSkin.cylinder,
    ];

_FlowRunnerPlayerSkin _flowRunnerPlayerSkinFromId(String? id) {
  return _FlowRunnerPlayerSkin.values.firstWhere(
    (_FlowRunnerPlayerSkin skin) => skin.id == id,
    orElse: () => _FlowRunnerPlayerSkin.orb,
  );
}

class _FlowRunnerEntity {
  const _FlowRunnerEntity({
    required this.id,
    required this.kind,
    required this.trackX,
    required this.y,
    required this.speedFactor,
    this.obstacleColor,
    this.scored = false,
  });

  final int id;
  final _FlowRunnerEntityKind kind;
  final double trackX;
  final double y;
  final double speedFactor;
  final Color? obstacleColor;
  final bool scored;

  _FlowRunnerEntity copyWith({
    int? id,
    _FlowRunnerEntityKind? kind,
    double? trackX,
    double? y,
    double? speedFactor,
    Color? obstacleColor,
    bool? scored,
  }) {
    return _FlowRunnerEntity(
      id: id ?? this.id,
      kind: kind ?? this.kind,
      trackX: trackX ?? this.trackX,
      y: y ?? this.y,
      speedFactor: speedFactor ?? this.speedFactor,
      obstacleColor: obstacleColor ?? this.obstacleColor,
      scored: scored ?? this.scored,
    );
  }
}

class _FlowRunnerSessionResult {
  const _FlowRunnerSessionResult({
    required this.completed,
    required this.diamondsCollected,
  });

  final bool completed;
  final int diamondsCollected;
}

const double _flowRunnerPlayerTrackMinX = 0.18;
const double _flowRunnerPlayerTrackMaxX = 0.82;
const int _flowRunnerGoldenTempoPercentThreshold = 500;
const Color _flowRunnerGoldColor = Color(0xFFFFD24A);
const List<Color> _flowRunnerObstacleColors = <Color>[
  Color(0xFFF8F6F1),
  Color(0xFFFF8A3D),
  Color(0xFF3C7DFF),
  Color(0xFFFFD43B),
  Color(0xFF33C46E),
  Color(0xFF7A4A21),
  Color(0xFF121212),
  Color(0xFFFF5FC8),
];

class FlowRunnerTrainer extends StatefulWidget {
  const FlowRunnerTrainer({
    super.key,
    required this.accent,
    this.fullscreenOnStart = false,
    this.onSessionStarted,
  });

  final Color accent;
  final bool fullscreenOnStart;
  final VoidCallback? onSessionStarted;

  @override
  State<FlowRunnerTrainer> createState() => _FlowRunnerTrainerState();
}

class _FlowRunnerTrainerState extends State<FlowRunnerTrainer> {
  static const String _totalDiamondsPrefsKey = 'flow_runner_total_diamonds_v1';
  static const String _diamondBalancePrefsKey =
      'flow_runner_diamond_balance_v1';
  static const String _ownedSkinsPrefsKey = 'flow_runner_owned_skins_v1';
  static const String _selectedSkinPrefsKey = 'flow_runner_selected_skin_v1';

  bool _finished = false;
  int _totalDiamonds = 0;
  int _diamondBalance = 0;
  Set<_FlowRunnerPlayerSkin> _ownedSkins = <_FlowRunnerPlayerSkin>{};
  _FlowRunnerPlayerSkin _selectedSkin = _FlowRunnerPlayerSkin.orb;

  _FlowRunnerLevelDefinition get _currentLevel =>
      _flowRunnerLevelDefinitions.first;

  @override
  void initState() {
    super.initState();
    _loadCustomizationState();
  }

  Future<void> _loadCustomizationState() async {
    final prefs = await SharedPreferences.getInstance();
    final int storedTotalDiamonds = prefs.getInt(_totalDiamondsPrefsKey) ?? 0;
    final int storedDiamondBalance =
        prefs.getInt(_diamondBalancePrefsKey) ?? storedTotalDiamonds;
    final Set<_FlowRunnerPlayerSkin> ownedSkins =
        prefs
            .getStringList(_ownedSkinsPrefsKey)
            ?.map(_flowRunnerPlayerSkinFromId)
            .where(
              (_FlowRunnerPlayerSkin skin) => skin != _FlowRunnerPlayerSkin.orb,
            )
            .toSet() ??
        <_FlowRunnerPlayerSkin>{};
    final _FlowRunnerPlayerSkin nextSelectedSkin = _flowRunnerPlayerSkinFromId(
      prefs.getString(_selectedSkinPrefsKey),
    );
    final _FlowRunnerPlayerSkin resolvedSelectedSkin =
        nextSelectedSkin == _FlowRunnerPlayerSkin.orb ||
            ownedSkins.contains(nextSelectedSkin)
        ? nextSelectedSkin
        : _FlowRunnerPlayerSkin.orb;

    if (!mounted) {
      return;
    }

    setState(() {
      _totalDiamonds = storedTotalDiamonds;
      _diamondBalance = storedDiamondBalance;
      _ownedSkins = ownedSkins;
      _selectedSkin = resolvedSelectedSkin;
    });
  }

  Future<void> _buySkin(_FlowRunnerPlayerSkin skin) async {
    if (_ownedSkins.contains(skin) || _diamondBalance < skin.cost) {
      return;
    }

    final Set<_FlowRunnerPlayerSkin> nextOwnedSkins = <_FlowRunnerPlayerSkin>{
      ..._ownedSkins,
      skin,
    };
    final int nextDiamondBalance = _diamondBalance - skin.cost;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setInt(_diamondBalancePrefsKey, nextDiamondBalance);
    await prefs.setStringList(
      _ownedSkinsPrefsKey,
      nextOwnedSkins
          .map((_FlowRunnerPlayerSkin item) => item.id)
          .toList(growable: false),
    );

    if (!mounted) {
      return;
    }

    setState(() {
      _diamondBalance = nextDiamondBalance;
      _ownedSkins = nextOwnedSkins;
    });

    HapticFeedback.mediumImpact();
  }

  Future<void> _selectSkin(_FlowRunnerPlayerSkin skin) async {
    if (skin != _FlowRunnerPlayerSkin.orb && !_ownedSkins.contains(skin)) {
      return;
    }

    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_selectedSkinPrefsKey, skin.id);

    if (!mounted) {
      return;
    }

    setState(() {
      _selectedSkin = skin;
    });

    HapticFeedback.selectionClick();
  }

  Future<void> _start() async {
    widget.onSessionStarted?.call();

    final result = await Navigator.of(context).push<_FlowRunnerSessionResult>(
      _buildExerciseSessionRoute<_FlowRunnerSessionResult>(
        builder: (BuildContext context) {
          return FlowRunnerSessionPage(
            accent: widget.accent,
            selectedSkin: _selectedSkin,
          );
        },
      ),
    );

    if (!mounted || result == null) {
      return;
    }

    final int earnedDiamonds = result.completed ? result.diamondsCollected : 0;
    final prefs = await SharedPreferences.getInstance();
    final int storedTotalDiamonds =
        prefs.getInt(_totalDiamondsPrefsKey) ?? _totalDiamonds;
    final int storedDiamondBalance =
        prefs.getInt(_diamondBalancePrefsKey) ?? _diamondBalance;
    final int nextTotalDiamonds = storedTotalDiamonds + earnedDiamonds;
    final int nextDiamondBalance = storedDiamondBalance + earnedDiamonds;

    if (!mounted) {
      return;
    }

    setState(() {
      _finished = result.completed;
      _totalDiamonds = nextTotalDiamonds;
      _diamondBalance = nextDiamondBalance;
    });

    await prefs.setInt(_totalDiamondsPrefsKey, nextTotalDiamonds);
    await prefs.setInt(_diamondBalancePrefsKey, nextDiamondBalance);
  }

  Widget _buildSkinStoreCard(_FlowRunnerPlayerSkin skin) {
    final theme = Theme.of(context);
    final palette = context.appPalette;
    final bool isDefaultFreeSkin = skin == _FlowRunnerPlayerSkin.orb;
    final bool isOwned = isDefaultFreeSkin || _ownedSkins.contains(skin);
    final bool isSelected = _selectedSkin == skin;
    final bool canAfford = isDefaultFreeSkin || _diamondBalance >= skin.cost;
    final VoidCallback? onPressed = isSelected
        ? null
        : isOwned
        ? () => _selectSkin(skin)
        : canAfford
        ? () => _buySkin(skin)
        : null;
    final String buttonLabel = isSelected
        ? 'Aktywna'
        : isOwned
        ? 'Użyj'
        : 'Kup';
    final String helperLabel = isSelected
        ? 'Aktywna animacja w grze'
        : isDefaultFreeSkin
        ? 'Darmowa animacja startowa'
        : isOwned
        ? 'Kupiona i gotowa do użycia'
        : 'Odblokuj za diamenty';

    return AnimatedContainer(
      duration: const Duration(milliseconds: 180),
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: palette.surfaceStrong,
        borderRadius: BorderRadius.circular(22),
        border: Border.all(
          color: isSelected
              ? widget.accent.withValues(alpha: 0.58)
              : isOwned
              ? const Color(0xFF2FD675).withValues(alpha: 0.42)
              : palette.outlinedButtonBorder.withValues(alpha: 0.18),
          width: isSelected ? 1.8 : 1.2,
        ),
      ),
      child: Row(
        children: <Widget>[
          SizedBox(
            width: 56,
            height: 56,
            child: Center(
              child: _FlowRunnerPlayer(
                accent: widget.accent,
                pulse: isSelected,
                skin: skin,
                size: 42,
              ),
            ),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                Text(
                  skin.label,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: theme.textTheme.titleSmall?.copyWith(
                    fontSize: 14,
                    height: 1.08,
                    color: palette.primaryText,
                    fontWeight: FontWeight.w800,
                  ),
                ),
                const SizedBox(height: 6),
                Row(
                  children: <Widget>[
                    const _FlowRunnerDiamondGlyph(size: 10),
                    const SizedBox(width: 6),
                    Flexible(
                      child: Text(
                        '${skin.cost} diamentów',
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: theme.textTheme.bodySmall?.copyWith(
                          fontSize: 12,
                          color: palette.secondaryText,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 6),
                Text(
                  !isOwned && !canAfford ? 'Za mało diamentów' : helperLabel,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: theme.textTheme.labelSmall?.copyWith(
                    fontSize: 11,
                    height: 1.1,
                    color: !isOwned && !canAfford
                        ? const Color(0xFFE16A5C)
                        : palette.tertiaryText,
                    fontWeight: FontWeight.w800,
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(width: 10),
          SizedBox(
            width: 78,
            child: isOwned
                ? OutlinedButton(
                    onPressed: onPressed,
                    style: OutlinedButton.styleFrom(
                      minimumSize: const Size(78, 38),
                      padding: const EdgeInsets.symmetric(
                        horizontal: 8,
                        vertical: 10,
                      ),
                      side: BorderSide(
                        color: isSelected
                            ? widget.accent.withValues(alpha: 0.42)
                            : widget.accent.withValues(alpha: 0.22),
                      ),
                    ),
                    child: Text(
                      buttonLabel,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: theme.textTheme.labelLarge?.copyWith(
                        fontSize: 12,
                        fontWeight: FontWeight.w800,
                      ),
                    ),
                  )
                : FilledButton(
                    onPressed: onPressed,
                    style: FilledButton.styleFrom(
                      minimumSize: const Size(78, 38),
                      padding: const EdgeInsets.symmetric(
                        horizontal: 8,
                        vertical: 10,
                      ),
                    ),
                    child: Text(
                      buttonLabel,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: theme.textTheme.labelLarge?.copyWith(
                        fontSize: 12,
                        fontWeight: FontWeight.w800,
                      ),
                    ),
                  ),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final palette = context.appPalette;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        Row(
          children: <Widget>[
            Expanded(
              child: StatStrip(
                label: 'Tempo',
                value: _currentLevel.tempoLabel,
                tint: widget.accent,
              ),
            ),
            const SizedBox(width: 10),
            Expanded(
              child: StatStrip(
                label: 'Tryb',
                value: 'Flow',
                tint: widget.accent,
              ),
            ),
            const SizedBox(width: 10),
            Expanded(
              child: StatStrip(
                label: 'Gra',
                value: _finished ? 'Sesja zrobiona' : 'Bez limitu',
                tint: widget.accent,
              ),
            ),
          ],
        ),
        const SizedBox(height: 18),
        SurfaceCard(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              const SectionHeader(
                eyebrow: 'Animacje',
                title: 'Ilość diamentów zebranych przez użytkownika',
              ),
              const SizedBox(height: 14),
              Center(
                child: ConstrainedBox(
                  constraints: const BoxConstraints(maxWidth: 240),
                  child: Container(
                    width: double.infinity,
                    padding: const EdgeInsets.symmetric(
                      horizontal: 18,
                      vertical: 16,
                    ),
                    decoration: BoxDecoration(
                      color: const Color(0xFF2FD675).withValues(alpha: 0.1),
                      borderRadius: BorderRadius.circular(22),
                      border: Border.all(
                        color: const Color(0xFF2FD675).withValues(alpha: 0.24),
                      ),
                    ),
                    child: Column(
                      children: <Widget>[
                        Text(
                          'Diamenty',
                          textAlign: TextAlign.center,
                          style: theme.textTheme.labelLarge?.copyWith(
                            color: const Color(0xFF2FD675),
                            fontWeight: FontWeight.w800,
                            letterSpacing: 0.6,
                          ),
                        ),
                        const SizedBox(height: 10),
                        Text(
                          '$_diamondBalance',
                          textAlign: TextAlign.center,
                          style: theme.textTheme.headlineMedium?.copyWith(
                            color: palette.primaryText,
                            fontWeight: FontWeight.w900,
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
              const SizedBox(height: 12),
              Center(
                child: Text(
                  'Aktywne: ${_selectedSkin.label}',
                  textAlign: TextAlign.center,
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: palette.secondaryText,
                    height: 1.35,
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ),
              const SizedBox(height: 18),
              Column(
                children: _flowRunnerUnlockableSkins
                    .map(
                      (_FlowRunnerPlayerSkin skin) => Padding(
                        padding: EdgeInsets.only(
                          bottom: skin == _flowRunnerUnlockableSkins.last
                              ? 0
                              : 12,
                        ),
                        child: _buildSkinStoreCard(skin),
                      ),
                    )
                    .toList(growable: false),
              ),
            ],
          ),
        ),
        const SizedBox(height: 18),
        Container(
          width: double.infinity,
          padding: const EdgeInsets.all(18),
          decoration: BoxDecoration(
            color: palette.surfaceStrong,
            borderRadius: BorderRadius.circular(26),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              Text(
                _currentLevel.title,
                style: theme.textTheme.titleLarge?.copyWith(
                  color: palette.primaryText,
                  fontWeight: FontWeight.w900,
                ),
              ),
              const SizedBox(height: 8),
              Text(
                _currentLevel.summary,
                style: theme.textTheme.bodyMedium?.copyWith(
                  color: palette.secondaryText,
                  height: 1.45,
                ),
              ),
              const SizedBox(height: 18),
              SizedBox(
                width: double.infinity,
                height: 280,
                child: _FlowRunnerPreviewArena(selectedSkin: _selectedSkin),
              ),
              const SizedBox(height: 16),
              Text(
                'Przesuwaj palcem w lewo i w prawo po ekranie. Kulka płynnie podąża za ruchem, a arena stopniowo podkręca tempo.',
                style: theme.textTheme.bodyMedium?.copyWith(
                  color: palette.tertiaryText,
                  height: 1.45,
                ),
              ),
            ],
          ),
        ),
        const SizedBox(height: 18),
        Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(minWidth: 220, maxWidth: 280),
            child: FilledButton(
              onPressed: _start,
              child: const Text('Start sesji'),
            ),
          ),
        ),
      ],
    );
  }
}

class FlowRunnerSessionPage extends StatefulWidget {
  const FlowRunnerSessionPage({
    super.key,
    required this.accent,
    required this.selectedSkin,
  });

  final Color accent;
  final _FlowRunnerPlayerSkin selectedSkin;

  @override
  State<FlowRunnerSessionPage> createState() => _FlowRunnerSessionPageState();
}

class _FlowRunnerSessionPageState extends State<FlowRunnerSessionPage> {
  static const int _sessionStartCountdownSeconds = 3;
  static const int _maxSessionDiamonds = 5;
  static const double _playerY = 0.82;
  static const double _entityHitThresholdX = 0.11;

  final Random _random = Random();
  Timer? _countdownTimer;
  Timer? _gameLoopTimer;
  Timer? _finishExitTimer;
  int? _countdownValue;
  bool _running = false;
  bool _finished = false;
  double _playerTrackX = 0.5;
  int _elapsedMilliseconds = 0;
  int _score = 0;
  int _streak = 0;
  int _bestStreak = 0;
  int _diamondsCollected = 0;
  int _energy = 0;
  int _hitFlashFrames = 0;
  int _entityIdCounter = 0;
  int _lastDiamondTierSpawned = 0;
  double _spawnCooldownSeconds = 0.0;
  DateTime? _lastFrameAt;
  List<_FlowRunnerEntity> _entities = <_FlowRunnerEntity>[];

  _FlowRunnerLevelDefinition get _levelDefinition =>
      _flowRunnerLevelDefinitions.first;

  @override
  void initState() {
    super.initState();
    _energy = _levelDefinition.maxEnergy;

    WidgetsBinding.instance.addPostFrameCallback((_) {
      _enterFullscreenSessionMode();
      if (mounted) {
        _startCountdown();
      }
    });
  }

  bool get _isCountingDown => _countdownValue != null;

  String get _countdownLabel {
    final value = _countdownValue;
    if (value == null) {
      return '';
    }
    return value == 0 ? 'START' : '$value';
  }

  double get _rawTempoProgress {
    final total = _levelDefinition.speedRampSeconds * 1000;
    if (total <= 0) {
      return 1;
    }
    return _elapsedMilliseconds / total;
  }

  double _speedForProgress(double rawProgress) {
    final double cappedProgress = rawProgress.clamp(0, 1).toDouble();
    final double speedRange =
        _levelDefinition.maxSpeed - _levelDefinition.baseSpeed;
    final double overflowProgress = max(0, rawProgress - 1);

    return _levelDefinition.baseSpeed +
        (speedRange * cappedProgress) +
        (speedRange * 0.35 * overflowProgress);
  }

  double get _currentSpeed => _speedForProgress(_rawTempoProgress);

  int get _tempoPercent => max(1, (_rawTempoProgress * 100).round());

  int _tempoTierForProgress(double rawProgress) {
    final int percent = max(1, (rawProgress * 100).round());
    return percent ~/ 50;
  }

  int _diamondTierForProgress(double rawProgress) {
    final int percent = max(1, (rawProgress * 100).round());
    return percent ~/ 25;
  }

  bool get _isGoldenTempoPhase =>
      _tempoPercent >= _flowRunnerGoldenTempoPercentThreshold;

  Color _obstacleColorForProgress(double rawProgress) {
    if ((rawProgress * 100).round() >= _flowRunnerGoldenTempoPercentThreshold) {
      return _flowRunnerGoldColor;
    }
    final int index = min(
      _flowRunnerObstacleColors.length - 1,
      _tempoTierForProgress(rawProgress),
    );
    return _flowRunnerObstacleColors[index];
  }

  void _startCountdown() {
    if (_running || _isCountingDown) {
      return;
    }

    _cancelTimers();

    setState(() {
      _countdownValue = _sessionStartCountdownSeconds;
      _running = false;
      _finished = false;
      _playerTrackX = 0.5;
      _elapsedMilliseconds = 0;
      _score = 0;
      _streak = 0;
      _bestStreak = 0;
      _diamondsCollected = 0;
      _energy = _levelDefinition.maxEnergy;
      _hitFlashFrames = 0;
      _entityIdCounter = 0;
      _lastDiamondTierSpawned = 0;
      _spawnCooldownSeconds = 0.72;
      _entities = <_FlowRunnerEntity>[];
      _lastFrameAt = null;
    });

    HapticFeedback.selectionClick();

    _countdownTimer = Timer.periodic(const Duration(seconds: 1), (Timer timer) {
      if (!mounted) {
        timer.cancel();
        return;
      }

      final currentCountdown = _countdownValue;
      if (currentCountdown == null) {
        timer.cancel();
        return;
      }

      if (currentCountdown <= 0) {
        timer.cancel();
        _startSession();
        return;
      }

      setState(() {
        _countdownValue = currentCountdown - 1;
      });

      if (_countdownValue == 0) {
        HapticFeedback.mediumImpact();
      } else {
        HapticFeedback.selectionClick();
      }
    });
  }

  void _startSession() {
    _cancelTimers();

    setState(() {
      _countdownValue = null;
      _running = true;
      _finished = false;
      _lastFrameAt = DateTime.now();
    });

    _gameLoopTimer = Timer.periodic(
      const Duration(milliseconds: 16),
      _handleGameFrame,
    );
  }

  void _handleGameFrame(Timer timer) {
    if (!mounted || !_running) {
      timer.cancel();
      return;
    }

    final DateTime now = DateTime.now();
    final DateTime previousFrame = _lastFrameAt ?? now;
    final int rawDeltaMs = now.difference(previousFrame).inMilliseconds;
    final int deltaMilliseconds = max(
      12,
      min(32, rawDeltaMs == 0 ? 16 : rawDeltaMs),
    );
    _lastFrameAt = now;

    final int totalMilliseconds = _levelDefinition.speedRampSeconds * 1000;
    final int nextElapsedMilliseconds =
        _elapsedMilliseconds + deltaMilliseconds;
    final double nextRawProgress = totalMilliseconds <= 0
        ? 1
        : nextElapsedMilliseconds / totalMilliseconds;
    final double currentSpeed = _speedForProgress(nextRawProgress);
    final double deltaSeconds = deltaMilliseconds / 1000;
    double nextSpawnCooldown = _spawnCooldownSeconds - deltaSeconds;
    int nextEnergy = _energy;
    int nextScore = _score;
    int nextStreak = _streak;
    int nextBestStreak = _bestStreak;
    int nextDiamondsCollected = _diamondsCollected;
    int nextDiamondTierSpawned = _lastDiamondTierSpawned;
    int nextHitFlashFrames = max(0, _hitFlashFrames - 1);
    bool triggerHitHaptic = false;
    bool triggerBonusHaptic = false;
    bool triggerStreakHaptic = false;

    final List<_FlowRunnerEntity> activeEntities = List<_FlowRunnerEntity>.of(
      _entities,
    );

    while (nextSpawnCooldown <= 0) {
      activeEntities.add(_spawnEntity(activeEntities, nextRawProgress));
      nextSpawnCooldown += _spawnIntervalForProgress(nextRawProgress);
    }

    final bool hasActiveDiamond = activeEntities.any(
      (_FlowRunnerEntity entity) => entity.kind == _FlowRunnerEntityKind.bonus,
    );
    final int currentDiamondTier = _diamondTierForProgress(nextRawProgress);
    if (!hasActiveDiamond &&
        nextDiamondTierSpawned < _maxSessionDiamonds &&
        currentDiamondTier > nextDiamondTierSpawned) {
      nextDiamondTierSpawned += 1;
      activeEntities.add(_spawnDiamondEntity(activeEntities));
    }

    final List<_FlowRunnerEntity> nextEntities = <_FlowRunnerEntity>[];
    for (final _FlowRunnerEntity entity in activeEntities) {
      _FlowRunnerEntity updated = entity.copyWith(
        y: entity.y + (currentSpeed * entity.speedFactor * deltaSeconds),
      );
      final double distanceToPlayer = (updated.y - _playerY).abs();
      final bool intersectsPlayer =
          (updated.trackX - _playerTrackX).abs() <= _entityHitThresholdX;

      if (intersectsPlayer && distanceToPlayer <= 0.07) {
        if (updated.kind == _FlowRunnerEntityKind.bonus) {
          nextDiamondsCollected += 1;
          nextEnergy = min(_levelDefinition.maxEnergy, nextEnergy + 1);
          triggerBonusHaptic = true;
        } else {
          nextEnergy -= 1;
          nextStreak = 0;
          nextScore = max(0, nextScore - 1);
          nextHitFlashFrames = 8;
          triggerHitHaptic = true;
        }
        continue;
      }

      if (!updated.scored && updated.kind == _FlowRunnerEntityKind.obstacle) {
        if (updated.y > _playerY + 0.08) {
          nextScore += 1;
          nextStreak += 1;
          nextBestStreak = max(nextBestStreak, nextStreak);
          updated = updated.copyWith(scored: true);
          if (nextStreak % 5 == 0) {
            triggerStreakHaptic = true;
          }
        }
      }

      if (updated.y <= 1.18) {
        nextEntities.add(updated);
      }
    }

    setState(() {
      _elapsedMilliseconds = nextElapsedMilliseconds;
      _spawnCooldownSeconds = nextSpawnCooldown;
      _entities = nextEntities;
      _score = nextScore;
      _streak = nextStreak;
      _bestStreak = nextBestStreak;
      _diamondsCollected = nextDiamondsCollected;
      _energy = nextEnergy;
      _hitFlashFrames = nextHitFlashFrames;
      _lastDiamondTierSpawned = nextDiamondTierSpawned;
    });

    if (triggerHitHaptic) {
      HapticFeedback.heavyImpact();
    } else if (triggerBonusHaptic) {
      HapticFeedback.mediumImpact();
    } else if (triggerStreakHaptic) {
      HapticFeedback.selectionClick();
    }

    if (nextEnergy <= 0) {
      _finishSession(overloaded: true);
    }
  }

  double _spawnIntervalForProgress(double progress) {
    final double normalized = progress.clamp(0, 1).toDouble();
    final double milliseconds =
        _levelDefinition.spawnStartMs +
        ((_levelDefinition.spawnEndMs - _levelDefinition.spawnStartMs) *
            normalized);
    final int tempoTier = _tempoTierForProgress(progress);
    final double densityMultiplier = max(0.48, 1 - (tempoTier * 0.08));
    return (milliseconds * densityMultiplier) / 1000;
  }

  double _randomTrackX() {
    final double range =
        _flowRunnerPlayerTrackMaxX - _flowRunnerPlayerTrackMinX;
    return _flowRunnerPlayerTrackMinX + (_random.nextDouble() * range);
  }

  bool _isTrackXBlocked(List<_FlowRunnerEntity> activeEntities, double trackX) {
    return activeEntities.any(
      (_FlowRunnerEntity entity) =>
          entity.y < 0.26 && (entity.trackX - trackX).abs() < 0.14,
    );
  }

  double _pickSpawnTrackX(
    List<_FlowRunnerEntity> activeEntities, {
    bool pressurePlayer = false,
  }) {
    final double range =
        _flowRunnerPlayerTrackMaxX - _flowRunnerPlayerTrackMinX;
    final double playerPressureChance = pressurePlayer ? 0.68 : 0.32;
    double candidate = _randomTrackX();

    for (int attempt = 0; attempt < 10; attempt += 1) {
      final bool targetPlayerLine = _random.nextDouble() < playerPressureChance;
      if (targetPlayerLine) {
        final double jitter = (_random.nextDouble() - 0.5) * range * 0.3;
        candidate = (_playerTrackX + jitter)
            .clamp(_flowRunnerPlayerTrackMinX, _flowRunnerPlayerTrackMaxX)
            .toDouble();
      } else {
        candidate = _randomTrackX();
      }

      if (!_isTrackXBlocked(activeEntities, candidate)) {
        return candidate;
      }
    }

    return candidate;
  }

  _FlowRunnerEntity _spawnEntity(
    List<_FlowRunnerEntity> activeEntities,
    double rawProgress,
  ) {
    _entityIdCounter += 1;
    return _FlowRunnerEntity(
      id: _entityIdCounter,
      kind: _FlowRunnerEntityKind.obstacle,
      trackX: _pickSpawnTrackX(activeEntities, pressurePlayer: true),
      y: -0.16,
      speedFactor: 1.0,
      obstacleColor: _obstacleColorForProgress(rawProgress),
    );
  }

  _FlowRunnerEntity _spawnDiamondEntity(
    List<_FlowRunnerEntity> activeEntities,
  ) {
    _entityIdCounter += 1;
    return _FlowRunnerEntity(
      id: _entityIdCounter,
      kind: _FlowRunnerEntityKind.bonus,
      trackX: _pickSpawnTrackX(activeEntities),
      y: -0.18,
      speedFactor: 0.96,
    );
  }

  void _updatePlayerTrackFromGlobalX(double globalX) {
    if (_finished) {
      return;
    }

    final double availableWidth = max(1, MediaQuery.sizeOf(context).width - 36);
    final double progress = ((globalX - 18) / availableWidth).clamp(0, 1);
    final double nextTrackX =
        _flowRunnerPlayerTrackMinX +
        ((_flowRunnerPlayerTrackMaxX - _flowRunnerPlayerTrackMinX) *
            progress.toDouble());
    if ((_playerTrackX - nextTrackX).abs() < 0.003) {
      return;
    }

    setState(() {
      _playerTrackX = nextTrackX;
    });
  }

  void _handlePanStart(DragStartDetails details) {
    _updatePlayerTrackFromGlobalX(details.globalPosition.dx);
  }

  void _handlePanUpdate(DragUpdateDetails details) {
    _updatePlayerTrackFromGlobalX(details.globalPosition.dx);
  }

  void _finishSession({bool overloaded = false}) {
    if (_finished) {
      return;
    }

    _cancelTimers();

    setState(() {
      _running = false;
      _finished = true;
      _countdownValue = null;
    });

    _finishExitTimer = Timer(const Duration(seconds: 2), () {
      if (!mounted) {
        return;
      }
      Navigator.of(context).pop(
        _FlowRunnerSessionResult(
          completed: true,
          diamondsCollected: _diamondsCollected,
        ),
      );
    });
  }

  void _cancelTimers() {
    _countdownTimer?.cancel();
    _gameLoopTimer?.cancel();
    _finishExitTimer?.cancel();
  }

  @override
  void dispose() {
    _cancelTimers();
    _exitFullscreenSessionMode();
    super.dispose();
  }

  Widget _buildTopBadge({
    required String label,
    required String value,
    required ThemeData theme,
    Color? tint,
    Widget? leading,
  }) {
    final Color effectiveTint = tint ?? widget.accent;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 10),
      decoration: BoxDecoration(
        color: effectiveTint.withValues(alpha: 0.16),
        borderRadius: BorderRadius.circular(18),
        border: Border.all(color: effectiveTint.withValues(alpha: 0.22)),
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          SizedBox(
            width: double.infinity,
            child: FittedBox(
              fit: BoxFit.scaleDown,
              alignment: Alignment.centerLeft,
              child: Text(
                label,
                maxLines: 1,
                style: theme.textTheme.labelSmall?.copyWith(
                  color: Colors.white.withValues(alpha: 0.72),
                  fontWeight: FontWeight.w800,
                  letterSpacing: 0.2,
                ),
              ),
            ),
          ),
          const SizedBox(height: 2),
          Row(
            mainAxisSize: MainAxisSize.min,
            children: <Widget>[
              if (leading != null) ...<Widget>[
                leading,
                const SizedBox(width: 5),
              ],
              Flexible(
                child: Text(
                  value,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: theme.textTheme.titleMedium?.copyWith(
                    color: Colors.white,
                    fontWeight: FontWeight.w900,
                  ),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return Scaffold(
      body: GestureDetector(
        behavior: HitTestBehavior.translucent,
        onPanStart: _handlePanStart,
        onPanUpdate: _handlePanUpdate,
        child: DecoratedBox(
          decoration: BoxDecoration(
            gradient: LinearGradient(
              begin: Alignment.topLeft,
              end: Alignment.bottomRight,
              colors: <Color>[
                const Color(0xFF06111A),
                const Color(0xFF0B1E29),
                widget.accent.withValues(alpha: 0.38),
              ],
            ),
          ),
          child: SafeArea(
            child: Padding(
              padding: const EdgeInsets.fromLTRB(18, 12, 18, 20),
              child: Column(
                children: <Widget>[
                  const SizedBox(height: 6),
                  Row(
                    children: <Widget>[
                      Expanded(
                        child: _buildTopBadge(
                          label: 'Punkty',
                          value: '$_score',
                          theme: theme,
                        ),
                      ),
                      const SizedBox(width: 10),
                      Expanded(
                        child: _buildTopBadge(
                          label: 'Diamenty',
                          value: '$_diamondsCollected',
                          theme: theme,
                          tint: const Color(0xFF2FD675),
                          leading: const _FlowRunnerDiamondGlyph(size: 11),
                        ),
                      ),
                      const SizedBox(width: 10),
                      Expanded(
                        child: _buildTopBadge(
                          label: 'Energia',
                          value: '$_energy/${_levelDefinition.maxEnergy}',
                          theme: theme,
                          tint: _energy <= 1
                              ? const Color(0xFFE16A5C)
                              : widget.accent,
                        ),
                      ),
                      const SizedBox(width: 10),
                      Expanded(
                        child: _buildTopBadge(
                          label: 'Tempo',
                          value: '$_tempoPercent%',
                          theme: theme,
                          tint: _levelDefinition.tint,
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 18),
                  Expanded(
                    child: _FlowRunnerArena(
                      accent: widget.accent,
                      playerTrackX: _playerTrackX,
                      playerPulse: _running
                          ? (_elapsedMilliseconds ~/ 140).isEven
                          : false,
                      playerSkin: widget.selectedSkin,
                      goldenPhase: _isGoldenTempoPhase,
                      entities: _entities,
                      scenePhase: _elapsedMilliseconds / 1000,
                      showHitFlash: _hitFlashFrames > 0,
                      countdownLabel: _isCountingDown ? _countdownLabel : null,
                      summaryTitle: _finished ? 'Koniec' : null,
                      summarySubtitle: _finished ? 'Punkty $_score' : null,
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _FlowRunnerDiamondGlyph extends StatelessWidget {
  const _FlowRunnerDiamondGlyph({this.size = 14});

  final double size;

  @override
  Widget build(BuildContext context) {
    return Transform.rotate(
      angle: pi / 4,
      child: Container(
        width: size,
        height: size,
        decoration: BoxDecoration(
          gradient: const LinearGradient(
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
            colors: <Color>[Color(0xFF58F29A), Color(0xFF0A8D44)],
          ),
          borderRadius: BorderRadius.circular(size * 0.18),
          border: Border.all(color: Colors.white.withValues(alpha: 0.28)),
          boxShadow: <BoxShadow>[
            BoxShadow(
              color: const Color(0xFF3BDC7F).withValues(alpha: 0.24),
              blurRadius: size,
              spreadRadius: 1,
            ),
          ],
        ),
      ),
    );
  }
}

class _FlowRunnerArena extends StatelessWidget {
  const _FlowRunnerArena({
    required this.accent,
    required this.playerTrackX,
    required this.playerPulse,
    this.playerSkin = _FlowRunnerPlayerSkin.orb,
    required this.entities,
    required this.scenePhase,
    this.goldenPhase = false,
    this.showHitFlash = false,
    this.countdownLabel,
    this.summaryTitle,
    this.summarySubtitle,
  });

  final Color accent;
  final double playerTrackX;
  final bool playerPulse;
  final _FlowRunnerPlayerSkin playerSkin;
  final List<_FlowRunnerEntity> entities;
  final double scenePhase;
  final bool goldenPhase;
  final bool showHitFlash;
  final String? countdownLabel;
  final String? summaryTitle;
  final String? summarySubtitle;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return Container(
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(30),
        color: const Color(0xFF0D1D28),
        border: Border.all(color: accent.withValues(alpha: 0.18)),
        boxShadow: <BoxShadow>[
          BoxShadow(
            color: accent.withValues(alpha: 0.14),
            blurRadius: 28,
            offset: const Offset(0, 18),
          ),
        ],
      ),
      clipBehavior: Clip.antiAlias,
      child: LayoutBuilder(
        builder: (BuildContext context, BoxConstraints constraints) {
          final double playerCenterY = constraints.maxHeight * 0.82;
          final double playerCenterX = constraints.maxWidth * playerTrackX;
          final bool showOverlay =
              countdownLabel != null || summaryTitle != null;

          return Stack(
            children: <Widget>[
              Positioned.fill(
                child: CustomPaint(
                  painter: _FlowRunnerTrackPainter(
                    accent: accent,
                    phase: scenePhase,
                    showHitFlash: showHitFlash,
                  ),
                ),
              ),
              for (final _FlowRunnerEntity entity in entities)
                Positioned(
                  left: (constraints.maxWidth * entity.trackX) - 28,
                  top: (constraints.maxHeight * entity.y) - 22,
                  child: _FlowRunnerEntityVisual(
                    kind: entity.kind,
                    accent: accent,
                    obstacleColor: goldenPhase
                        ? _flowRunnerGoldColor
                        : entity.obstacleColor,
                  ),
                ),
              Positioned(
                left: playerCenterX - 20,
                top: playerCenterY - 20,
                child: _FlowRunnerPlayer(
                  accent: accent,
                  pulse: playerPulse,
                  skin: playerSkin,
                  goldenPhase: goldenPhase,
                ),
              ),
              if (showOverlay)
                Positioned.fill(
                  child: Center(
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: <Widget>[
                        if (countdownLabel != null)
                          Text(
                            countdownLabel!,
                            key: ValueKey<String>(
                              'flow-runner-countdown-$countdownLabel',
                            ),
                            style: theme.textTheme.displaySmall?.copyWith(
                              color: Colors.white,
                              fontWeight: FontWeight.w900,
                              letterSpacing: countdownLabel == 'START'
                                  ? 1.2
                                  : 0,
                            ),
                          ),
                        if (summaryTitle != null) ...<Widget>[
                          Text(
                            summaryTitle!,
                            style: theme.textTheme.headlineMedium?.copyWith(
                              color: Colors.white,
                              fontWeight: FontWeight.w900,
                            ),
                          ),
                          if (summarySubtitle != null) ...<Widget>[
                            const SizedBox(height: 10),
                            Text(
                              summarySubtitle!,
                              textAlign: TextAlign.center,
                              style: theme.textTheme.bodyLarge?.copyWith(
                                color: Colors.white.withValues(alpha: 0.82),
                                fontWeight: FontWeight.w700,
                              ),
                            ),
                          ],
                        ],
                      ],
                    ),
                  ),
                ),
            ],
          );
        },
      ),
    );
  }
}

class _FlowRunnerPreviewArena extends StatefulWidget {
  const _FlowRunnerPreviewArena({required this.selectedSkin});

  final _FlowRunnerPlayerSkin selectedSkin;

  @override
  State<_FlowRunnerPreviewArena> createState() =>
      _FlowRunnerPreviewArenaState();
}

class _FlowRunnerPreviewArenaState extends State<_FlowRunnerPreviewArena> {
  Timer? _timer;
  int _step = 0;

  @override
  void initState() {
    super.initState();
    _timer = Timer.periodic(const Duration(milliseconds: 70), (Timer timer) {
      if (!mounted) {
        timer.cancel();
        return;
      }
      setState(() {
        _step += 1;
      });
    });
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final double playerTrackX =
        0.5 + (sin(_step / 14) * (_flowRunnerPlayerTrackMaxX - 0.5));
    final double phase = _step / 18;
    final List<_FlowRunnerEntity> previewEntities = <_FlowRunnerEntity>[
      _FlowRunnerEntity(
        id: 1,
        kind: _FlowRunnerEntityKind.obstacle,
        trackX: 0.26,
        y: ((_step * 0.038) % 1.3) - 0.18,
        speedFactor: 1,
        obstacleColor: _flowRunnerObstacleColors[0],
      ),
      _FlowRunnerEntity(
        id: 2,
        kind: _FlowRunnerEntityKind.bonus,
        trackX: 0.5 + (sin(_step / 13) * 0.12),
        y: (((_step + 10) * 0.034) % 1.3) - 0.22,
        speedFactor: 0.94,
      ),
      _FlowRunnerEntity(
        id: 3,
        kind: _FlowRunnerEntityKind.obstacle,
        trackX: 0.74,
        y: (((_step + 20) * 0.036) % 1.3) - 0.26,
        speedFactor: 1,
        obstacleColor:
            _flowRunnerObstacleColors[min(1 + ((_step ~/ 16) % 7), 7)],
      ),
    ];

    return _FlowRunnerArena(
      accent: const Color(0xFF2E9E89),
      playerTrackX: playerTrackX,
      playerPulse: _step.isEven,
      playerSkin: widget.selectedSkin,
      entities: previewEntities,
      scenePhase: phase,
    );
  }
}

class _FlowRunnerPlayer extends StatelessWidget {
  const _FlowRunnerPlayer({
    required this.accent,
    required this.pulse,
    this.skin = _FlowRunnerPlayerSkin.orb,
    this.goldenPhase = false,
    this.size = 40,
  });

  final Color accent;
  final bool pulse;
  final _FlowRunnerPlayerSkin skin;
  final bool goldenPhase;
  final double size;

  @override
  Widget build(BuildContext context) {
    final List<Color> baseFillColors = switch (skin) {
      _FlowRunnerPlayerSkin.orb => <Color>[
        Colors.white,
        accent.withValues(alpha: 0.94),
      ],
      _FlowRunnerPlayerSkin.star => const <Color>[
        Color(0xFFFFE08A),
        Color(0xFFFFC328),
      ],
      _FlowRunnerPlayerSkin.triangle => const <Color>[
        Color(0xFFD7DCE4),
        Color(0xFF8E97A4),
      ],
      _FlowRunnerPlayerSkin.waterBottle => const <Color>[
        Color(0xFFFFB261),
        Color(0xFFFF7B1F),
      ],
      _FlowRunnerPlayerSkin.cylinder => const <Color>[
        Color(0xFF181117),
        Color(0xFFFF5FC8),
      ],
    };
    final List<Color> fillColors = goldenPhase
        ? const <Color>[Color(0xFFFFFFFF), Color(0xFFF1F5F8)]
        : baseFillColors;
    final Color glowColor = goldenPhase
        ? Colors.white.withValues(alpha: 0.32)
        : switch (skin) {
            _FlowRunnerPlayerSkin.orb => accent.withValues(alpha: 0.36),
            _FlowRunnerPlayerSkin.star => const Color(
              0xFFFFC328,
            ).withValues(alpha: 0.38),
            _FlowRunnerPlayerSkin.triangle => const Color(
              0xFFA2AAB6,
            ).withValues(alpha: 0.32),
            _FlowRunnerPlayerSkin.waterBottle => const Color(
              0xFFFF7B1F,
            ).withValues(alpha: 0.34),
            _FlowRunnerPlayerSkin.cylinder => const Color(
              0xFFFF5FC8,
            ).withValues(alpha: 0.34),
          };
    final Color edgeColor = Colors.white.withValues(alpha: 0.42);
    final Color solidFill = fillColors.last;
    final Widget shape = switch (skin) {
      _FlowRunnerPlayerSkin.orb => Container(
        width: size,
        height: size,
        decoration: BoxDecoration(
          shape: BoxShape.circle,
          gradient: RadialGradient(colors: fillColors),
          boxShadow: <BoxShadow>[
            BoxShadow(color: glowColor, blurRadius: 24, spreadRadius: 4),
          ],
          border: Border.all(color: edgeColor),
        ),
      ),
      _FlowRunnerPlayerSkin.star => Icon(
        Icons.star_rounded,
        size: size * 0.98,
        color: solidFill,
        shadows: <Shadow>[Shadow(color: glowColor, blurRadius: size * 0.48)],
      ),
      _FlowRunnerPlayerSkin.triangle => Icon(
        Icons.change_history_rounded,
        size: size * 0.96,
        color: solidFill,
        shadows: <Shadow>[Shadow(color: glowColor, blurRadius: size * 0.42)],
      ),
      _FlowRunnerPlayerSkin.waterBottle => Icon(
        Icons.sports_bar_rounded,
        size: size * 0.92,
        color: solidFill,
        shadows: <Shadow>[Shadow(color: glowColor, blurRadius: size * 0.4)],
      ),
      _FlowRunnerPlayerSkin.cylinder => Container(
        width: size * 0.72,
        height: size,
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(size),
          gradient: LinearGradient(
            begin: Alignment.topCenter,
            end: Alignment.bottomCenter,
            colors: fillColors,
          ),
          border: Border.all(color: edgeColor),
          boxShadow: <BoxShadow>[
            BoxShadow(color: glowColor, blurRadius: 24, spreadRadius: 3),
          ],
        ),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: <Widget>[
            Container(
              margin: EdgeInsets.only(top: size * 0.16),
              width: size * 0.38,
              height: size * 0.08,
              decoration: BoxDecoration(
                color: Colors.white.withValues(alpha: 0.34),
                borderRadius: BorderRadius.circular(999),
              ),
            ),
            Container(
              margin: EdgeInsets.only(bottom: size * 0.16),
              width: size * 0.38,
              height: size * 0.08,
              decoration: BoxDecoration(
                color: Colors.black.withValues(alpha: 0.16),
                borderRadius: BorderRadius.circular(999),
              ),
            ),
          ],
        ),
      ),
    };
    final double rotationTurns = switch (skin) {
      _FlowRunnerPlayerSkin.star => pulse ? 0.02 : -0.02,
      _FlowRunnerPlayerSkin.triangle => pulse ? -0.015 : 0.015,
      _FlowRunnerPlayerSkin.waterBottle => pulse ? 0.012 : -0.012,
      _FlowRunnerPlayerSkin.cylinder => pulse ? 0.008 : -0.008,
      _FlowRunnerPlayerSkin.orb => 0,
    };
    final double scale = pulse ? 1.04 : 0.94;

    return AnimatedRotation(
      duration: const Duration(milliseconds: 120),
      turns: rotationTurns,
      child: AnimatedScale(
        duration: const Duration(milliseconds: 120),
        scale: scale,
        child: SizedBox(
          width: size,
          height: size,
          child: Center(child: shape),
        ),
      ),
    );
  }
}

class _FlowRunnerEntityVisual extends StatelessWidget {
  const _FlowRunnerEntityVisual({
    required this.kind,
    required this.accent,
    this.obstacleColor,
  });

  final _FlowRunnerEntityKind kind;
  final Color accent;
  final Color? obstacleColor;

  @override
  Widget build(BuildContext context) {
    if (kind == _FlowRunnerEntityKind.bonus) {
      return Transform.rotate(
        angle: pi / 4,
        child: Container(
          width: 24,
          height: 24,
          decoration: BoxDecoration(
            gradient: const LinearGradient(
              begin: Alignment.topLeft,
              end: Alignment.bottomRight,
              colors: <Color>[Color(0xFF58F29A), Color(0xFF0A8D44)],
            ),
            borderRadius: BorderRadius.circular(6),
            boxShadow: <BoxShadow>[
              BoxShadow(
                color: const Color(0xFF3BDC7F).withValues(alpha: 0.34),
                blurRadius: 18,
                spreadRadius: 1,
              ),
            ],
            border: Border.all(color: Colors.white.withValues(alpha: 0.24)),
          ),
        ),
      );
    }

    return Transform.rotate(
      angle: 0.08,
      child: Container(
        width: 56,
        height: 34,
        decoration: BoxDecoration(
          gradient: LinearGradient(
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
            colors: <Color>[
              (obstacleColor ?? _flowRunnerObstacleColors.first).withValues(
                alpha: 0.98,
              ),
              Color.lerp(
                    obstacleColor ?? _flowRunnerObstacleColors.first,
                    Colors.black,
                    0.36,
                  ) ??
                  (obstacleColor ?? _flowRunnerObstacleColors.first),
            ],
          ),
          borderRadius: BorderRadius.circular(14),
          boxShadow: <BoxShadow>[
            BoxShadow(
              color: (obstacleColor ?? _flowRunnerObstacleColors.first)
                  .withValues(alpha: 0.3),
              blurRadius: 18,
              offset: const Offset(0, 8),
            ),
          ],
          border: Border.all(
            color:
                (obstacleColor ?? _flowRunnerObstacleColors.first)
                        .computeLuminance() <
                    0.2
                ? Colors.white.withValues(alpha: 0.24)
                : Colors.black.withValues(alpha: 0.14),
          ),
        ),
        child: Center(
          child: Container(
            width: 18,
            height: 6,
            decoration: BoxDecoration(
              color:
                  (obstacleColor ?? _flowRunnerObstacleColors.first)
                          .computeLuminance() <
                      0.2
                  ? Colors.white.withValues(alpha: 0.8)
                  : Colors.black.withValues(alpha: 0.46),
              borderRadius: BorderRadius.circular(999),
            ),
          ),
        ),
      ),
    );
  }
}

class _FlowRunnerTrackPainter extends CustomPainter {
  const _FlowRunnerTrackPainter({
    required this.accent,
    required this.phase,
    required this.showHitFlash,
  });

  final Color accent;
  final double phase;
  final bool showHitFlash;

  @override
  void paint(Canvas canvas, Size size) {
    final Paint lanePaint = Paint()
      ..color = Colors.white.withValues(alpha: 0.12)
      ..strokeWidth = 1.4
      ..style = PaintingStyle.stroke;
    final Paint stripePaint = Paint()
      ..color = accent.withValues(alpha: 0.22)
      ..style = PaintingStyle.fill;

    final List<double> laneXs = <double>[
      size.width * 0.14,
      size.width * 0.36,
      size.width * 0.64,
      size.width * 0.86,
    ];
    for (final double laneX in laneXs) {
      canvas.drawLine(Offset(laneX, 0), Offset(laneX, size.height), lanePaint);
    }

    for (int index = 0; index < 9; index += 1) {
      final double progress = ((index / 9) + (phase * 0.42)) % 1;
      final double y = size.height * progress;
      final double width = size.width * (0.18 + (progress * 0.62));
      final double left = (size.width - width) / 2;
      final RRect stripe = RRect.fromRectAndRadius(
        Rect.fromLTWH(left, y, width, 3),
        const Radius.circular(999),
      );
      canvas.drawRRect(stripe, stripePaint);
    }

    if (showHitFlash) {
      final Paint flashPaint = Paint()
        ..color = const Color(0xFFE65B57).withValues(alpha: 0.18);
      canvas.drawRect(Offset.zero & size, flashPaint);
    }
  }

  @override
  bool shouldRepaint(covariant _FlowRunnerTrackPainter oldDelegate) {
    return oldDelegate.accent != accent ||
        oldDelegate.phase != phase ||
        oldDelegate.showHitFlash != showHitFlash;
  }
}

class FocusDotTrainer extends StatefulWidget {
  const FocusDotTrainer({
    super.key,
    required this.accent,
    this.onSessionStarted,
  });

  final Color accent;
  final VoidCallback? onSessionStarted;

  @override
  State<FocusDotTrainer> createState() => _FocusDotTrainerState();
}

class _FocusDotTrainerState extends State<FocusDotTrainer> {
  _FocusGameKind _selectedGame = _FocusGameKind.anchor;
  late final PageController _gamePageController;

  @override
  void initState() {
    super.initState();
    _gamePageController = PageController(initialPage: _selectedGame.index);
  }

  @override
  void dispose() {
    _gamePageController.dispose();
    super.dispose();
  }

  void _handleGamePageChanged(int index) {
    final nextGame = _focusGameDefinitions[index].kind;
    if (_selectedGame == nextGame) {
      return;
    }

    setState(() {
      _selectedGame = nextGame;
    });
  }

  Widget _buildTrainer() {
    return switch (_selectedGame) {
      _FocusGameKind.anchor => _FocusAnchorTrainer(
        key: const ValueKey<String>('focus-trainer-anchor'),
        accent: widget.accent,
        onSessionStarted: widget.onSessionStarted,
      ),
      _FocusGameKind.pursuit => _SmoothPursuitTrainer(
        key: const ValueKey<String>('focus-trainer-pursuit'),
        accent: widget.accent,
        onSessionStarted: widget.onSessionStarted,
      ),
      _FocusGameKind.peripheral => _PeripheralFocusTrainer(
        key: const ValueKey<String>('focus-trainer-peripheral'),
        accent: widget.accent,
        onSessionStarted: widget.onSessionStarted,
      ),
    };
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final selectedGameIndex = _selectedGame.index;
    final content = Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        Container(
          width: double.infinity,
          height: 170,
          padding: const EdgeInsets.fromLTRB(18, 16, 18, 14),
          decoration: BoxDecoration(
            gradient: LinearGradient(
              begin: Alignment.topLeft,
              end: Alignment.bottomRight,
              colors: <Color>[
                widget.accent.withValues(alpha: 0.16),
                const Color(0xFFF7F1E7),
              ],
            ),
            borderRadius: BorderRadius.circular(26),
            border: Border.all(color: widget.accent.withValues(alpha: 0.18)),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.center,
            children: <Widget>[
              Center(
                child: Text(
                  'Tryby gry',
                  textAlign: TextAlign.center,
                  style: theme.textTheme.labelLarge?.copyWith(
                    color: const Color(0xFF63717C),
                    fontWeight: FontWeight.w800,
                    letterSpacing: 0.4,
                  ),
                ),
              ),
              const SizedBox(height: 10),
              Expanded(
                child: PageView.builder(
                  controller: _gamePageController,
                  itemCount: _focusGameDefinitions.length,
                  onPageChanged: _handleGamePageChanged,
                  itemBuilder: (BuildContext context, int index) {
                    final game = _focusGameDefinitions[index];
                    return Container(
                      key: ValueKey<String>('focus-mode-${game.kind.name}'),
                      width: double.infinity,
                      padding: const EdgeInsets.all(18),
                      decoration: BoxDecoration(
                        color: Colors.white.withValues(alpha: 0.82),
                        borderRadius: BorderRadius.circular(22),
                        border: Border.all(
                          color: widget.accent.withValues(alpha: 0.32),
                        ),
                      ),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.center,
                        mainAxisAlignment: MainAxisAlignment.center,
                        children: <Widget>[
                          Text(
                            game.title,
                            textAlign: TextAlign.center,
                            style: theme.textTheme.titleLarge?.copyWith(
                              color: const Color(0xFF16212B),
                            ),
                          ),
                          const SizedBox(height: 10),
                          Text(
                            'Po co: ${game.focusLabel}',
                            textAlign: TextAlign.center,
                            style: theme.textTheme.bodyLarge?.copyWith(
                              color: const Color(0xFF24303A),
                            ),
                          ),
                          const SizedBox(height: 6),
                          Text(
                            game.difficultyLabel,
                            textAlign: TextAlign.center,
                            style: theme.textTheme.bodyMedium?.copyWith(
                              color: const Color(0xFF63717C),
                              fontWeight: FontWeight.w700,
                            ),
                          ),
                        ],
                      ),
                    );
                  },
                ),
              ),
              const SizedBox(height: 12),
              Center(
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: List<Widget>.generate(
                    _focusGameDefinitions.length,
                    (int index) {
                      final bool selected = index == selectedGameIndex;
                      return AnimatedContainer(
                        duration: const Duration(milliseconds: 180),
                        margin: EdgeInsets.only(left: index == 0 ? 0 : 6),
                        width: selected ? 18 : 8,
                        height: 8,
                        decoration: BoxDecoration(
                          color: selected
                              ? widget.accent
                              : widget.accent.withValues(alpha: 0.24),
                          borderRadius: BorderRadius.circular(999),
                        ),
                      );
                    },
                  ),
                ),
              ),
            ],
          ),
        ),
        const SizedBox(height: 18),
        AnimatedSwitcher(
          duration: const Duration(milliseconds: 220),
          child: _buildTrainer(),
        ),
      ],
    );

    return LayoutBuilder(
      builder: (BuildContext context, BoxConstraints constraints) {
        if (!constraints.hasBoundedHeight) {
          return content;
        }

        return SingleChildScrollView(
          child: ConstrainedBox(
            constraints: BoxConstraints(minHeight: constraints.maxHeight),
            child: content,
          ),
        );
      },
    );
  }
}

class _FocusDurationSelector extends StatelessWidget {
  const _FocusDurationSelector({
    required this.selectedMinutes,
    required this.accent,
    required this.onSelected,
  });

  final int selectedMinutes;
  final Color accent;
  final ValueChanged<int> onSelected;

  @override
  Widget build(BuildContext context) {
    return Wrap(
      spacing: 10,
      runSpacing: 10,
      children: <int>[2, 5, 10].map((int minutes) {
        final bool selected = selectedMinutes == minutes;
        return ChoiceChip(
          label: Text('$minutes min'),
          selected: selected,
          onSelected: (_) => onSelected(minutes),
          selectedColor: accent.withValues(alpha: 0.2),
          labelStyle: TextStyle(
            color: selected ? accent : const Color(0xFF24303A),
            fontWeight: FontWeight.w800,
          ),
          side: BorderSide(color: selected ? accent : const Color(0xFFCFD6DC)),
        );
      }).toList(),
    );
  }
}

enum FocusDotColorMode { light, dark, alert, ocean, solar, grid3d }

class _FocusDotColorDefinition {
  const _FocusDotColorDefinition({
    required this.mode,
    required this.label,
    required this.description,
    required this.backgroundColor,
    required this.dotColor,
    this.backgroundGradient,
    this.orbGradient,
    this.showPerspectiveGrid = false,
    this.gridColor,
  });

  final FocusDotColorMode mode;
  final String label;
  final String description;
  final Color backgroundColor;
  final Color dotColor;
  final Gradient? backgroundGradient;
  final Gradient? orbGradient;
  final bool showPerspectiveGrid;
  final Color? gridColor;

  bool get usesDarkForeground => backgroundColor.computeLuminance() < 0.45;

  bool get hasOrbGradient => orbGradient != null;

  Color get accentColor => gridColor ?? dotColor;

  Color get foregroundColor =>
      usesDarkForeground ? Colors.white : const Color(0xFF16212B);

  Color get chromeFillColor => usesDarkForeground
      ? Colors.white.withValues(alpha: 0.08)
      : Colors.black.withValues(alpha: 0.05);

  Color get chromeBorderColor => usesDarkForeground
      ? Colors.white.withValues(alpha: 0.12)
      : Colors.black.withValues(alpha: 0.08);

  Color get dotGlowColor => accentColor.withValues(
    alpha: showPerspectiveGrid
        ? 0.54
        : usesDarkForeground
        ? 0.46
        : 0.18,
  );
}

const List<_FocusDotColorDefinition>
_focusDotColorDefinitions = <_FocusDotColorDefinition>[
  _FocusDotColorDefinition(
    mode: FocusDotColorMode.light,
    label: 'Jasny',
    description: 'Białe tło i czarna kropka',
    backgroundColor: Colors.white,
    dotColor: Color(0xFF101010),
  ),
  _FocusDotColorDefinition(
    mode: FocusDotColorMode.dark,
    label: 'Klasyczny',
    description: 'Czarne tło i biała kropka',
    backgroundColor: Colors.black,
    dotColor: Color(0xFFF7F4ED),
  ),
  _FocusDotColorDefinition(
    mode: FocusDotColorMode.alert,
    label: 'Czerwony',
    description: 'Czarne tło i czerwona kropka',
    backgroundColor: Colors.black,
    dotColor: Color(0xFFE04444),
  ),
  _FocusDotColorDefinition(
    mode: FocusDotColorMode.ocean,
    label: 'Ocean',
    description: 'Granatowe tło i turkusowa kulka',
    backgroundColor: Color(0xFF07161E),
    dotColor: Color(0xFF66E8F8),
    backgroundGradient: LinearGradient(
      begin: Alignment.topLeft,
      end: Alignment.bottomRight,
      colors: <Color>[Color(0xFF040A10), Color(0xFF0B2733), Color(0xFF125060)],
    ),
    orbGradient: RadialGradient(
      center: Alignment(-0.28, -0.32),
      radius: 0.92,
      colors: <Color>[
        Color(0xFFFFFFFF),
        Color(0xFFC6FBFF),
        Color(0xFF66E8F8),
        Color(0xFF0C6170),
      ],
      stops: <double>[0, 0.16, 0.5, 1],
    ),
  ),
  _FocusDotColorDefinition(
    mode: FocusDotColorMode.solar,
    label: 'Solar',
    description: 'Ciepłe tło i bursztynowa kulka',
    backgroundColor: Color(0xFFF8E3BC),
    dotColor: Color(0xFFB95A28),
    backgroundGradient: LinearGradient(
      begin: Alignment.topLeft,
      end: Alignment.bottomRight,
      colors: <Color>[Color(0xFFFFF6E4), Color(0xFFF1D39A), Color(0xFFE3A660)],
    ),
    orbGradient: RadialGradient(
      center: Alignment(-0.32, -0.34),
      radius: 0.94,
      colors: <Color>[
        Color(0xFFFFFFFF),
        Color(0xFFFFE0A5),
        Color(0xFFD67A39),
        Color(0xFF7A2614),
      ],
      stops: <double>[0, 0.18, 0.54, 1],
    ),
  ),
  _FocusDotColorDefinition(
    mode: FocusDotColorMode.grid3d,
    label: 'Grid 3D',
    description: 'Przestrzenna siatka i kulka 3D',
    backgroundColor: Color(0xFF030811),
    dotColor: Color(0xFF67E8FF),
    backgroundGradient: LinearGradient(
      begin: Alignment.topCenter,
      end: Alignment.bottomCenter,
      colors: <Color>[Color(0xFF050C15), Color(0xFF0A1E2D), Color(0xFF02060B)],
    ),
    orbGradient: RadialGradient(
      center: Alignment(-0.28, -0.32),
      radius: 0.95,
      colors: <Color>[
        Color(0xFFFFFFFF),
        Color(0xFFD7FBFF),
        Color(0xFF67E8FF),
        Color(0xFF0B486A),
      ],
      stops: <double>[0, 0.18, 0.52, 1],
    ),
    showPerspectiveGrid: true,
    gridColor: Color(0xFF4ED9FF),
  ),
];

class _FocusDotSceneBackdrop extends StatelessWidget {
  const _FocusDotSceneBackdrop({required this.definition});

  final _FocusDotColorDefinition definition;

  @override
  Widget build(BuildContext context) {
    return Stack(
      fit: StackFit.expand,
      children: <Widget>[
        DecoratedBox(
          decoration: BoxDecoration(
            color: definition.backgroundGradient == null
                ? definition.backgroundColor
                : null,
            gradient: definition.backgroundGradient,
          ),
        ),
        if (definition.showPerspectiveGrid)
          IgnorePointer(
            child: CustomPaint(
              painter: _FocusDotPerspectiveGridPainter(
                gridColor: definition.gridColor ?? definition.dotColor,
              ),
            ),
          ),
        Positioned.fill(
          child: DecoratedBox(
            decoration: BoxDecoration(
              gradient: RadialGradient(
                center: Alignment.center,
                radius: definition.showPerspectiveGrid ? 1.18 : 1.06,
                colors: <Color>[
                  Colors.transparent,
                  Colors.black.withValues(
                    alpha: definition.usesDarkForeground ? 0.18 : 0.08,
                  ),
                ],
              ),
            ),
          ),
        ),
      ],
    );
  }
}

class _FocusDotPerspectiveGridPainter extends CustomPainter {
  const _FocusDotPerspectiveGridPainter({required this.gridColor});

  final Color gridColor;

  @override
  void paint(Canvas canvas, Size size) {
    final double horizonY = size.height * 0.46;
    final Paint glowPaint = Paint()
      ..shader =
          LinearGradient(
            begin: Alignment.topCenter,
            end: Alignment.bottomCenter,
            colors: <Color>[
              gridColor.withValues(alpha: 0.22),
              gridColor.withValues(alpha: 0.06),
              Colors.transparent,
            ],
            stops: const <double>[0, 0.34, 1],
          ).createShader(
            Rect.fromLTWH(
              0,
              horizonY - 28,
              size.width,
              size.height - horizonY + 28,
            ),
          );
    final Paint linePaint = Paint()
      ..color = gridColor.withValues(alpha: 0.38)
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1;
    final Paint horizonPaint = Paint()
      ..color = gridColor.withValues(alpha: 0.48)
      ..strokeWidth = 1.4;

    canvas.drawRect(
      Rect.fromLTWH(0, horizonY - 24, size.width, size.height - horizonY + 24),
      glowPaint,
    );
    canvas.drawLine(
      Offset(0, horizonY),
      Offset(size.width, horizonY),
      horizonPaint,
    );

    for (int i = 1; i <= 7; i += 1) {
      final double t = i / 7;
      final double curve = t * t;
      final double y = horizonY + ((size.height - horizonY) * curve);
      canvas.drawLine(Offset(0, y), Offset(size.width, y), linePaint);
    }

    for (int i = -6; i <= 6; i += 1) {
      final double fraction = i / 6;
      final double topX = (size.width / 2) + (size.width * 0.08 * fraction);
      final double bottomX = (size.width / 2) + (size.width * 0.82 * fraction);
      canvas.drawLine(
        Offset(topX, horizonY),
        Offset(bottomX, size.height + 8),
        linePaint,
      );
    }
  }

  @override
  bool shouldRepaint(covariant _FocusDotPerspectiveGridPainter oldDelegate) {
    return oldDelegate.gridColor != gridColor;
  }
}

class _FocusDotOrb extends StatelessWidget {
  const _FocusDotOrb({
    required this.definition,
    required this.size,
    this.expanded = false,
  });

  final _FocusDotColorDefinition definition;
  final double size;
  final bool expanded;

  @override
  Widget build(BuildContext context) {
    final double highlightSize = size * 0.28;

    return AnimatedContainer(
      duration: const Duration(milliseconds: 280),
      width: expanded ? size * 1.4 : size,
      height: expanded ? size * 1.4 : size,
      curve: Curves.easeOutCubic,
      child: Stack(
        clipBehavior: Clip.none,
        children: <Widget>[
          Positioned.fill(
            child: DecoratedBox(
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: definition.hasOrbGradient ? null : definition.dotColor,
                gradient: definition.orbGradient,
                border: definition.hasOrbGradient
                    ? Border.all(
                        color: Colors.white.withValues(
                          alpha: definition.usesDarkForeground ? 0.16 : 0.28,
                        ),
                      )
                    : null,
                boxShadow: <BoxShadow>[
                  BoxShadow(
                    color: definition.dotGlowColor,
                    blurRadius: definition.showPerspectiveGrid ? 34 : 18,
                    spreadRadius: definition.showPerspectiveGrid ? 7 : 4,
                  ),
                ],
              ),
            ),
          ),
          if (definition.hasOrbGradient)
            Positioned(
              left: size * 0.18,
              top: size * 0.14,
              child: Container(
                width: highlightSize,
                height: highlightSize,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  color: Colors.white.withValues(
                    alpha: definition.showPerspectiveGrid ? 0.62 : 0.46,
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }
}

class _FocusAnchorTrainer extends StatefulWidget {
  const _FocusAnchorTrainer({
    super.key,
    required this.accent,
    this.onSessionStarted,
  });

  final Color accent;
  final VoidCallback? onSessionStarted;

  @override
  State<_FocusAnchorTrainer> createState() => _FocusAnchorTrainerState();
}

class _FocusAnchorTrainerState extends State<_FocusAnchorTrainer> {
  int _selectedMinutes = 2;
  FocusDotColorMode _selectedColorMode = FocusDotColorMode.dark;
  bool _finished = false;
  late final PageController _colorPageController;

  _FocusDotColorDefinition get _selectedColorDefinition =>
      _focusDotColorDefinitions.firstWhere(
        (_FocusDotColorDefinition definition) =>
            definition.mode == _selectedColorMode,
      );

  int get _selectedColorIndex => _focusDotColorDefinitions.indexWhere(
    (_FocusDotColorDefinition definition) =>
        definition.mode == _selectedColorMode,
  );

  @override
  void initState() {
    super.initState();
    _colorPageController = PageController(
      initialPage: _selectedColorIndex,
      viewportFraction: 0.74,
    );
  }

  @override
  void dispose() {
    _colorPageController.dispose();
    super.dispose();
  }

  void _selectMinutes(int minutes) {
    setState(() {
      _selectedMinutes = minutes;
      _finished = false;
    });
  }

  void _selectColorMode(FocusDotColorMode mode) {
    if (_selectedColorMode == mode) {
      return;
    }

    setState(() {
      _selectedColorMode = mode;
      _finished = false;
    });

    HapticFeedback.selectionClick();
  }

  void _handleColorPageChanged(int index) {
    _selectColorMode(_focusDotColorDefinitions[index].mode);
  }

  Future<void> _animateToColorPage(int index) async {
    if (!_colorPageController.hasClients || index == _selectedColorIndex) {
      return;
    }

    await _colorPageController.animateToPage(
      index,
      duration: const Duration(milliseconds: 240),
      curve: Curves.easeOutCubic,
    );
  }

  Future<void> _start() async {
    widget.onSessionStarted?.call();
    setState(() {
      _finished = false;
    });

    final completed = await Navigator.of(context).push<bool>(
      _buildExerciseSessionRoute<bool>(
        builder: (BuildContext context) {
          return FocusDotSessionPage(
            accent: widget.accent,
            minutes: _selectedMinutes,
            colorMode: _selectedColorMode,
          );
        },
      ),
    );

    if (!mounted) {
      return;
    }

    setState(() {
      _finished = completed ?? false;
    });
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final selectedColor = _selectedColorDefinition;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        Row(
          children: <Widget>[
            Expanded(
              child: StatStrip(
                label: 'Czas',
                value: '$_selectedMinutes min',
                tint: widget.accent,
              ),
            ),
            const SizedBox(width: 10),
            Expanded(
              child: StatStrip(
                label: 'Cel',
                value: _finished ? 'Sesja zrobiona' : 'Spokój centrum',
                tint: widget.accent,
              ),
            ),
          ],
        ),
        const SizedBox(height: 18),
        _FocusDurationSelector(
          selectedMinutes: _selectedMinutes,
          accent: widget.accent,
          onSelected: _selectMinutes,
        ),
        const SizedBox(height: 18),
        Container(
          width: double.infinity,
          height: 300,
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(26),
            border: Border.all(color: selectedColor.chromeBorderColor),
          ),
          clipBehavior: Clip.antiAlias,
          child: Stack(
            fit: StackFit.expand,
            children: <Widget>[
              Positioned.fill(
                child: _FocusDotSceneBackdrop(definition: selectedColor),
              ),
              Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: <Widget>[
                  _FocusDotOrb(
                    definition: selectedColor,
                    size: selectedColor.showPerspectiveGrid ? 28 : 18,
                  ),
                  const SizedBox(height: 26),
                  Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 24),
                    child: Text(
                      'Patrz w punkt. Jeśli myśli odpłyną, wróć do środka bez oceniania.',
                      textAlign: TextAlign.center,
                      style: theme.textTheme.bodyLarge?.copyWith(
                        color: selectedColor.foregroundColor.withValues(
                          alpha: 0.88,
                        ),
                      ),
                    ),
                  ),
                ],
              ),
            ],
          ),
        ),
        const SizedBox(height: 18),
        Center(
          child: Text(
            'Wybierz wygląd punktu',
            textAlign: TextAlign.center,
            style: theme.textTheme.titleMedium?.copyWith(
              color: const Color(0xFF16212B),
              fontWeight: FontWeight.w900,
            ),
          ),
        ),
        const SizedBox(height: 12),
        SizedBox(
          height: 200,
          child: PageView.builder(
            controller: _colorPageController,
            itemCount: _focusDotColorDefinitions.length,
            onPageChanged: _handleColorPageChanged,
            itemBuilder: (BuildContext context, int index) {
              final _FocusDotColorDefinition definition =
                  _focusDotColorDefinitions[index];
              final bool selected = index == _selectedColorIndex;

              return AnimatedContainer(
                duration: const Duration(milliseconds: 220),
                curve: Curves.easeOutCubic,
                margin: EdgeInsets.fromLTRB(6, selected ? 0 : 10, 6, 0),
                child: Material(
                  color: Colors.transparent,
                  child: InkWell(
                    onTap: () => _animateToColorPage(index),
                    borderRadius: BorderRadius.circular(20),
                    child: Ink(
                      padding: const EdgeInsets.all(12),
                      decoration: BoxDecoration(
                        color: selected
                            ? widget.accent.withValues(alpha: 0.1)
                            : Colors.white,
                        borderRadius: BorderRadius.circular(20),
                        border: Border.all(
                          color: selected
                              ? widget.accent
                              : const Color(0xFFD6DDE2),
                          width: selected ? 1.4 : 1,
                        ),
                        boxShadow: selected
                            ? <BoxShadow>[
                                BoxShadow(
                                  color: widget.accent.withValues(alpha: 0.12),
                                  blurRadius: 20,
                                  offset: const Offset(0, 12),
                                ),
                              ]
                            : null,
                      ),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.center,
                        children: <Widget>[
                          Container(
                            width: double.infinity,
                            height: 76,
                            decoration: BoxDecoration(
                              borderRadius: BorderRadius.circular(16),
                              border: Border.all(
                                color: definition.chromeBorderColor,
                              ),
                            ),
                            clipBehavior: Clip.antiAlias,
                            child: Stack(
                              fit: StackFit.expand,
                              children: <Widget>[
                                Positioned.fill(
                                  child: _FocusDotSceneBackdrop(
                                    definition: definition,
                                  ),
                                ),
                                Center(
                                  child: _FocusDotOrb(
                                    definition: definition,
                                    size: definition.showPerspectiveGrid
                                        ? 18
                                        : 14,
                                  ),
                                ),
                              ],
                            ),
                          ),
                          const SizedBox(height: 10),
                          Text(
                            definition.label,
                            textAlign: TextAlign.center,
                            style: theme.textTheme.titleSmall?.copyWith(
                              color: const Color(0xFF16212B),
                              fontWeight: FontWeight.w900,
                            ),
                          ),
                          const SizedBox(height: 4),
                          Text(
                            definition.description,
                            textAlign: TextAlign.center,
                            style: theme.textTheme.bodySmall?.copyWith(
                              color: const Color(0xFF4A5761),
                              height: 1.35,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
              );
            },
          ),
        ),
        const SizedBox(height: 12),
        Center(
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: List<Widget>.generate(_focusDotColorDefinitions.length, (
              int index,
            ) {
              final bool selected = index == _selectedColorIndex;
              return AnimatedContainer(
                duration: const Duration(milliseconds: 180),
                margin: EdgeInsets.only(left: index == 0 ? 0 : 6),
                width: selected ? 18 : 8,
                height: 8,
                decoration: BoxDecoration(
                  color: selected
                      ? widget.accent
                      : widget.accent.withValues(alpha: 0.24),
                  borderRadius: BorderRadius.circular(999),
                ),
              );
            }),
          ),
        ),
        const SizedBox(height: 18),
        Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(minWidth: 220, maxWidth: 280),
            child: FilledButton(
              onPressed: _start,
              child: const Text('Start sesji'),
            ),
          ),
        ),
      ],
    );
  }
}

class _SmoothPursuitTrainer extends StatefulWidget {
  const _SmoothPursuitTrainer({
    super.key,
    required this.accent,
    this.onSessionStarted,
  });

  final Color accent;
  final VoidCallback? onSessionStarted;

  @override
  State<_SmoothPursuitTrainer> createState() => _SmoothPursuitTrainerState();
}

class _SmoothPursuitTrainerState extends State<_SmoothPursuitTrainer> {
  int _selectedMinutes = 2;
  bool _finished = false;

  void _selectMinutes(int minutes) {
    setState(() {
      _selectedMinutes = minutes;
      _finished = false;
    });
  }

  Future<void> _start() async {
    widget.onSessionStarted?.call();
    setState(() {
      _finished = false;
    });

    final completed = await Navigator.of(context).push<bool>(
      _buildExerciseSessionRoute<bool>(
        builder: (BuildContext context) {
          return SmoothPursuitSessionPage(
            accent: widget.accent,
            minutes: _selectedMinutes,
          );
        },
      ),
    );

    if (!mounted) {
      return;
    }

    setState(() {
      _finished = completed ?? false;
    });
  }

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        Row(
          children: <Widget>[
            Expanded(
              child: StatStrip(
                label: 'Czas',
                value: '$_selectedMinutes min',
                tint: widget.accent,
              ),
            ),
            const SizedBox(width: 10),
            Expanded(
              child: StatStrip(
                label: 'Tor',
                value: _finished ? 'Sesja zrobiona' : 'Mix 3',
                tint: widget.accent,
              ),
            ),
          ],
        ),
        const SizedBox(height: 18),
        _FocusDurationSelector(
          selectedMinutes: _selectedMinutes,
          accent: widget.accent,
          onSelected: _selectMinutes,
        ),
        const SizedBox(height: 18),
        SizedBox(
          width: double.infinity,
          height: 300,
          child: _PursuitArena(
            accent: widget.accent,
            elapsed: Duration.zero,
            animateInternally: true,
          ),
        ),
        const SizedBox(height: 18),
        Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(minWidth: 220, maxWidth: 280),
            child: FilledButton(
              onPressed: _start,
              child: const Text('Start sesji'),
            ),
          ),
        ),
      ],
    );
  }
}

class _PursuitArena extends StatefulWidget {
  const _PursuitArena({
    required this.accent,
    required this.elapsed,
    this.animateInternally = false,
    this.countdownLabel,
  });

  final Color accent;
  final Duration elapsed;
  final bool animateInternally;
  final String? countdownLabel;

  @override
  State<_PursuitArena> createState() => _PursuitArenaState();
}

class _PursuitArenaState extends State<_PursuitArena> {
  Timer? _previewTimer;
  Duration _previewElapsed = Duration.zero;

  bool get _useInternalPreview => widget.animateInternally;

  Duration get _effectiveElapsed =>
      _useInternalPreview ? _previewElapsed : widget.elapsed;

  @override
  void initState() {
    super.initState();
    if (_useInternalPreview) {
      _startPreview();
    }
  }

  @override
  void didUpdateWidget(covariant _PursuitArena oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (_useInternalPreview && _previewTimer == null) {
      _startPreview();
    } else if (!_useInternalPreview && _previewTimer != null) {
      _previewTimer?.cancel();
      _previewTimer = null;
    }
  }

  void _startPreview() {
    _previewTimer?.cancel();
    _previewTimer = Timer.periodic(const Duration(milliseconds: 30), (
      Timer timer,
    ) {
      if (!mounted) {
        timer.cancel();
        return;
      }
      setState(() {
        _previewElapsed += const Duration(milliseconds: 30);
      });
    });
  }

  @override
  void dispose() {
    _previewTimer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final alignment = _pursuitAlignmentForElapsed(_effectiveElapsed);

    return Container(
      decoration: BoxDecoration(
        gradient: const LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: <Color>[Color(0xFF10202E), Color(0xFF050B11)],
        ),
        borderRadius: BorderRadius.circular(26),
      ),
      child: LayoutBuilder(
        builder: (BuildContext context, BoxConstraints constraints) {
          final double arenaWidth = min(constraints.maxWidth * 0.76, 320);
          final double arenaHeight = min(constraints.maxHeight * 0.52, 200);

          return Stack(
            children: <Widget>[
              Center(
                child: SizedBox(
                  width: arenaWidth,
                  height: arenaHeight,
                  child: Stack(
                    children: <Widget>[
                      Center(
                        child: Container(
                          width: 10,
                          height: 10,
                          decoration: BoxDecoration(
                            shape: BoxShape.circle,
                            color: Colors.white.withValues(alpha: 0.18),
                            border: Border.all(
                              color: Colors.white.withValues(alpha: 0.22),
                            ),
                          ),
                        ),
                      ),
                      Align(
                        alignment: alignment,
                        child: Container(
                          width: 22,
                          height: 22,
                          decoration: BoxDecoration(
                            shape: BoxShape.circle,
                            color: const Color(0xFFF7F4ED),
                            boxShadow: <BoxShadow>[
                              BoxShadow(
                                color: widget.accent.withValues(alpha: 0.54),
                                blurRadius: 26,
                                spreadRadius: 6,
                              ),
                            ],
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
              if (widget.countdownLabel != null)
                Positioned(
                  left: 0,
                  right: 0,
                  bottom: 28,
                  child: Center(
                    child: Text(
                      widget.countdownLabel!,
                      key: ValueKey<String>(
                        'smooth-pursuit-countdown-${widget.countdownLabel!}',
                      ),
                      style: theme.textTheme.displaySmall?.copyWith(
                        color: Colors.white,
                        fontWeight: FontWeight.w900,
                        letterSpacing: widget.countdownLabel == 'START'
                            ? 1.3
                            : 0,
                      ),
                    ),
                  ),
                ),
            ],
          );
        },
      ),
    );
  }
}

class _PeripheralFocusTrainer extends StatefulWidget {
  const _PeripheralFocusTrainer({
    super.key,
    required this.accent,
    this.onSessionStarted,
  });

  final Color accent;
  final VoidCallback? onSessionStarted;

  @override
  State<_PeripheralFocusTrainer> createState() =>
      _PeripheralFocusTrainerState();
}

class _PeripheralFocusTrainerState extends State<_PeripheralFocusTrainer> {
  int _selectedMinutes = 2;
  bool _finished = false;

  void _selectMinutes(int minutes) {
    setState(() {
      _selectedMinutes = minutes;
      _finished = false;
    });
  }

  Future<void> _start() async {
    widget.onSessionStarted?.call();
    setState(() {
      _finished = false;
    });

    final completed = await Navigator.of(context).push<bool>(
      _buildExerciseSessionRoute<bool>(
        builder: (BuildContext context) {
          return PeripheralFocusSessionPage(
            accent: widget.accent,
            minutes: _selectedMinutes,
          );
        },
      ),
    );

    if (!mounted) {
      return;
    }

    setState(() {
      _finished = completed ?? false;
    });
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        Row(
          children: <Widget>[
            Expanded(
              child: StatStrip(
                label: 'Czas',
                value: '$_selectedMinutes min',
                tint: widget.accent,
              ),
            ),
            const SizedBox(width: 10),
            Expanded(
              child: StatStrip(
                label: 'Reguła',
                value: _finished ? 'Sesja zrobiona' : 'Tap tylko na jasny',
                tint: widget.accent,
              ),
            ),
          ],
        ),
        const SizedBox(height: 18),
        _FocusDurationSelector(
          selectedMinutes: _selectedMinutes,
          accent: widget.accent,
          onSelected: _selectMinutes,
        ),
        const SizedBox(height: 18),
        SizedBox(
          width: double.infinity,
          height: 300,
          child: _PeripheralArena(
            accent: widget.accent,
            activeSlot: _PeripheralCueSlot.up,
            activeTarget: true,
            animateInternally: true,
          ),
        ),
        const SizedBox(height: 16),
        Text(
          'Trzymaj wzrok w środku. Tapnij tylko wtedy, gdy po boku mignie jasny sygnał i od razu wracaj uwagą do centrum.',
          style: theme.textTheme.bodyMedium?.copyWith(
            color: const Color(0xFF4A5761),
            height: 1.45,
          ),
        ),
        const SizedBox(height: 18),
        Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(minWidth: 220, maxWidth: 280),
            child: FilledButton(
              onPressed: _start,
              child: const Text('Start sesji'),
            ),
          ),
        ),
      ],
    );
  }
}

class _PeripheralArena extends StatefulWidget {
  const _PeripheralArena({
    required this.accent,
    required this.activeSlot,
    required this.activeTarget,
    this.animateInternally = false,
    this.countdownLabel,
  });

  final Color accent;
  final _PeripheralCueSlot? activeSlot;
  final bool activeTarget;
  final bool animateInternally;
  final String? countdownLabel;

  @override
  State<_PeripheralArena> createState() => _PeripheralArenaState();
}

class _PeripheralArenaState extends State<_PeripheralArena> {
  Timer? _previewTimer;
  int _previewStep = 0;

  bool get _useInternalPreview => widget.animateInternally;

  _PeripheralCueSlot? get _effectiveSlot => _useInternalPreview
      ? _PeripheralCueSlot.values[_previewStep %
            _PeripheralCueSlot.values.length]
      : widget.activeSlot;

  bool get _effectiveTarget =>
      _useInternalPreview ? _previewStep.isEven : widget.activeTarget;

  @override
  void initState() {
    super.initState();
    if (_useInternalPreview) {
      _startPreview();
    }
  }

  @override
  void didUpdateWidget(covariant _PeripheralArena oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (_useInternalPreview && _previewTimer == null) {
      _startPreview();
    } else if (!_useInternalPreview && _previewTimer != null) {
      _previewTimer?.cancel();
      _previewTimer = null;
    }
  }

  void _startPreview() {
    _previewTimer?.cancel();
    _previewTimer = Timer.periodic(const Duration(milliseconds: 900), (
      Timer timer,
    ) {
      if (!mounted) {
        timer.cancel();
        return;
      }
      setState(() {
        _previewStep += 1;
      });
    });
  }

  @override
  void dispose() {
    _previewTimer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return Container(
      decoration: BoxDecoration(
        gradient: const LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: <Color>[Color(0xFF0F2030), Color(0xFF050B11)],
        ),
        borderRadius: BorderRadius.circular(26),
      ),
      child: Stack(
        children: <Widget>[
          Center(
            child: SizedBox(
              width: 260,
              height: 260,
              child: Stack(
                children: <Widget>[
                  Center(
                    child: Container(
                      width: 124,
                      height: 124,
                      decoration: BoxDecoration(
                        shape: BoxShape.circle,
                        border: Border.all(
                          color: Colors.white.withValues(alpha: 0.1),
                        ),
                      ),
                    ),
                  ),
                  ..._PeripheralCueSlot.values.map((_PeripheralCueSlot slot) {
                    final bool active = slot == _effectiveSlot;
                    final Color color = active
                        ? (_effectiveTarget
                              ? const Color(0xFFF7F4ED)
                              : const Color(0xFFF0C38A))
                        : Colors.white.withValues(alpha: 0.18);
                    final BoxShadow shadow = BoxShadow(
                      color: active
                          ? (_effectiveTarget
                                ? widget.accent.withValues(alpha: 0.5)
                                : const Color(
                                    0xFFF0C38A,
                                  ).withValues(alpha: 0.38))
                          : Colors.transparent,
                      blurRadius: active ? 22 : 0,
                      spreadRadius: active ? 4 : 0,
                    );

                    return Align(
                      alignment: slot.alignment,
                      child: AnimatedScale(
                        duration: const Duration(milliseconds: 180),
                        scale: active ? 1.22 : 1,
                        child: Container(
                          key: active
                              ? ValueKey<String>(
                                  'peripheral-focus-stimulus-${slot.name}-${_effectiveTarget ? 'target' : 'decoy'}',
                                )
                              : null,
                          width: active ? 20 : 14,
                          height: active ? 20 : 14,
                          decoration: BoxDecoration(
                            shape: BoxShape.circle,
                            color: color,
                            boxShadow: <BoxShadow>[shadow],
                          ),
                        ),
                      ),
                    );
                  }),
                  Center(
                    child: Container(
                      width: 18,
                      height: 18,
                      decoration: BoxDecoration(
                        shape: BoxShape.circle,
                        color: const Color(0xFFF7F4ED),
                        boxShadow: <BoxShadow>[
                          BoxShadow(
                            color: widget.accent.withValues(alpha: 0.42),
                            blurRadius: 18,
                            spreadRadius: 4,
                          ),
                        ],
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
          if (widget.countdownLabel != null)
            Positioned(
              left: 0,
              right: 0,
              bottom: 28,
              child: Center(
                child: Text(
                  widget.countdownLabel!,
                  key: ValueKey<String>(
                    'peripheral-focus-countdown-${widget.countdownLabel!}',
                  ),
                  style: theme.textTheme.displaySmall?.copyWith(
                    color: Colors.white,
                    fontWeight: FontWeight.w900,
                    letterSpacing: widget.countdownLabel == 'START' ? 1.3 : 0,
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }
}

class FocusDotSessionPage extends StatefulWidget {
  const FocusDotSessionPage({
    super.key,
    required this.accent,
    required this.minutes,
    this.colorMode = FocusDotColorMode.dark,
  });

  final Color accent;
  final int minutes;
  final FocusDotColorMode colorMode;

  @override
  State<FocusDotSessionPage> createState() => _FocusDotSessionPageState();
}

class _FocusDotSessionPageState extends State<FocusDotSessionPage> {
  static const int _sessionStartCountdownSeconds = 3;

  Timer? _startCountdownTimer;
  Timer? _countdownTimer;
  Timer? _dotPulseTimer;
  Timer? _finishExitTimer;
  late int _remainingSeconds;
  int? _startCountdownValue;
  bool _running = false;
  bool _finished = false;
  bool _dotExpanded = false;

  _FocusDotColorDefinition get _colorDefinition =>
      _focusDotColorDefinitions.firstWhere(
        (_FocusDotColorDefinition definition) =>
            definition.mode == widget.colorMode,
      );

  @override
  void initState() {
    super.initState();
    _remainingSeconds = widget.minutes * 60;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _enterFullscreenSessionMode();
      if (mounted) {
        _start();
      }
    });
  }

  bool get _isCountingDown => _startCountdownValue != null;

  String get _countdownLabel {
    final value = _startCountdownValue;
    if (value == null) {
      return '';
    }
    return value == 0 ? 'START' : '$value';
  }

  void _start() {
    if (_running || _isCountingDown) {
      return;
    }

    _finishExitTimer?.cancel();
    _startCountdownTimer?.cancel();
    _countdownTimer?.cancel();
    _dotPulseTimer?.cancel();

    if (_finished || _remainingSeconds <= 0) {
      _remainingSeconds = widget.minutes * 60;
    }

    setState(() {
      _finished = false;
      _dotExpanded = false;
      _startCountdownValue = _sessionStartCountdownSeconds;
    });

    HapticFeedback.selectionClick();

    _startCountdownTimer = Timer.periodic(const Duration(seconds: 1), (
      Timer timer,
    ) {
      if (!mounted) {
        timer.cancel();
        return;
      }

      final currentCountdown = _startCountdownValue;
      if (currentCountdown == null) {
        timer.cancel();
        return;
      }

      if (currentCountdown <= 0) {
        timer.cancel();
        _beginSession();
        return;
      }

      setState(() {
        _startCountdownValue = currentCountdown - 1;
      });

      if (_startCountdownValue == 0) {
        HapticFeedback.mediumImpact();
      } else {
        HapticFeedback.selectionClick();
      }
    });
  }

  void _beginSession() {
    _finishExitTimer?.cancel();
    _startCountdownTimer?.cancel();
    _countdownTimer?.cancel();
    _dotPulseTimer?.cancel();

    setState(() {
      _startCountdownValue = null;
      _running = true;
      _finished = false;
    });

    _countdownTimer = Timer.periodic(const Duration(seconds: 1), (Timer timer) {
      if (!mounted) {
        return;
      }

      if (_remainingSeconds <= 1) {
        timer.cancel();
        _finishSession();
      } else {
        setState(() {
          _remainingSeconds -= 1;
        });
      }
    });

    _dotPulseTimer = Timer.periodic(const Duration(milliseconds: 900), (
      Timer timer,
    ) {
      if (!mounted) {
        return;
      }

      setState(() {
        _dotExpanded = !_dotExpanded;
      });
    });
  }

  void _finishSession() {
    _finishExitTimer?.cancel();
    _startCountdownTimer?.cancel();
    _countdownTimer?.cancel();
    _dotPulseTimer?.cancel();

    setState(() {
      _remainingSeconds = 0;
      _running = false;
      _finished = true;
      _dotExpanded = false;
      _startCountdownValue = null;
    });

    _finishExitTimer = Timer(const Duration(seconds: 2), () {
      if (!mounted) {
        return;
      }
      _closeSession();
    });
  }

  void _closeSession() {
    _finishExitTimer?.cancel();
    Navigator.of(context).pop(_finished);
  }

  String _formatClock(int seconds) {
    final minutes = (seconds ~/ 60).toString().padLeft(2, '0');
    final rest = (seconds % 60).toString().padLeft(2, '0');
    return '$minutes:$rest';
  }

  @override
  void dispose() {
    _finishExitTimer?.cancel();
    _startCountdownTimer?.cancel();
    _countdownTimer?.cancel();
    _dotPulseTimer?.cancel();
    _exitFullscreenSessionMode();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colorDefinition = _colorDefinition;
    final palette = context.appPalette;

    return Scaffold(
      body: Stack(
        children: <Widget>[
          Positioned.fill(
            child: DecoratedBox(
              decoration: BoxDecoration(
                gradient: LinearGradient(
                  begin: Alignment.topLeft,
                  end: Alignment.bottomRight,
                  colors: <Color>[
                    palette.fullscreenStart,
                    palette.fullscreenMiddle,
                    palette.fullscreenEnd,
                  ],
                ),
              ),
              child: _FocusDotSceneBackdrop(definition: colorDefinition),
            ),
          ),
          SafeArea(
            child: Stack(
              children: <Widget>[
                Positioned(
                  top: 12,
                  left: 20,
                  right: 20,
                  child: Row(
                    children: <Widget>[
                      Container(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 14,
                          vertical: 10,
                        ),
                        decoration: BoxDecoration(
                          color: colorDefinition.chromeFillColor,
                          borderRadius: BorderRadius.circular(18),
                          border: Border.all(
                            color: colorDefinition.chromeBorderColor,
                          ),
                        ),
                        child: Text(
                          _formatClock(_remainingSeconds),
                          style: theme.textTheme.titleMedium?.copyWith(
                            color: colorDefinition.foregroundColor,
                            fontWeight: FontWeight.w800,
                          ),
                        ),
                      ),
                      const Spacer(),
                      Container(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 14,
                          vertical: 10,
                        ),
                        decoration: BoxDecoration(
                          color: colorDefinition.dotColor.withValues(
                            alpha: colorDefinition.usesDarkForeground
                                ? 0.18
                                : 0.1,
                          ),
                          borderRadius: BorderRadius.circular(18),
                          border: Border.all(
                            color: colorDefinition.dotColor.withValues(
                              alpha: colorDefinition.usesDarkForeground
                                  ? 0.22
                                  : 0.14,
                            ),
                          ),
                        ),
                        child: Text(
                          _finished
                              ? 'Koniec'
                              : _isCountingDown
                              ? 'Start'
                              : _running
                              ? 'Skupienie'
                              : 'Pauza',
                          style: theme.textTheme.labelLarge?.copyWith(
                            color: colorDefinition.foregroundColor,
                            fontWeight: FontWeight.w800,
                            letterSpacing: 0.8,
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
                Center(
                  child: AnimatedSwitcher(
                    duration: const Duration(milliseconds: 220),
                    child: _finished
                        ? Container(
                            key: const ValueKey<String>('focus-dot-finished'),
                            padding: const EdgeInsets.symmetric(
                              horizontal: 34,
                              vertical: 22,
                            ),
                            decoration: BoxDecoration(
                              color: colorDefinition.chromeFillColor,
                              borderRadius: BorderRadius.circular(26),
                              border: Border.all(
                                color: colorDefinition.chromeBorderColor,
                              ),
                            ),
                            child: Text(
                              'Koniec',
                              style: theme.textTheme.headlineMedium?.copyWith(
                                color: colorDefinition.foregroundColor,
                                fontWeight: FontWeight.w900,
                                letterSpacing: 1.0,
                              ),
                            ),
                          )
                        : Stack(
                            key: const ValueKey<String>('focus-dot-active'),
                            alignment: Alignment.center,
                            children: <Widget>[
                              _FocusDotOrb(
                                definition: colorDefinition,
                                size: colorDefinition.showPerspectiveGrid
                                    ? 30
                                    : 20,
                                expanded: _dotExpanded,
                              ),
                              if (_isCountingDown)
                                Transform.translate(
                                  offset: const Offset(0, 110),
                                  child: AnimatedSwitcher(
                                    duration: const Duration(milliseconds: 220),
                                    child: Text(
                                      _countdownLabel,
                                      key: ValueKey<String>(
                                        'focus-dot-countdown-$_countdownLabel',
                                      ),
                                      style: theme.textTheme.displaySmall
                                          ?.copyWith(
                                            color:
                                                colorDefinition.foregroundColor,
                                            fontWeight: FontWeight.w900,
                                            letterSpacing:
                                                _countdownLabel == 'START'
                                                ? 1.4
                                                : 0.0,
                                          ),
                                    ),
                                  ),
                                ),
                            ],
                          ),
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class SmoothPursuitSessionPage extends StatefulWidget {
  const SmoothPursuitSessionPage({
    super.key,
    required this.accent,
    required this.minutes,
  });

  final Color accent;
  final int minutes;

  @override
  State<SmoothPursuitSessionPage> createState() =>
      _SmoothPursuitSessionPageState();
}

class _SmoothPursuitSessionPageState extends State<SmoothPursuitSessionPage> {
  static const int _sessionStartCountdownSeconds = 3;

  Timer? _startCountdownTimer;
  Timer? _countdownTimer;
  Timer? _motionTimer;
  Timer? _finishExitTimer;
  late int _remainingSeconds;
  int? _startCountdownValue;
  bool _running = false;
  bool _finished = false;
  Duration _motionElapsed = Duration.zero;

  @override
  void initState() {
    super.initState();
    _remainingSeconds = widget.minutes * 60;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _enterFullscreenSessionMode();
      if (mounted) {
        _start();
      }
    });
  }

  bool get _isCountingDown => _startCountdownValue != null;

  String get _countdownLabel {
    final value = _startCountdownValue;
    if (value == null) {
      return '';
    }
    return value == 0 ? 'START' : '$value';
  }

  String _formatClock(int seconds) {
    final minutes = (seconds ~/ 60).toString().padLeft(2, '0');
    final rest = (seconds % 60).toString().padLeft(2, '0');
    return '$minutes:$rest';
  }

  void _start() {
    if (_running || _isCountingDown) {
      return;
    }

    _finishExitTimer?.cancel();
    _startCountdownTimer?.cancel();
    _countdownTimer?.cancel();
    _motionTimer?.cancel();

    if (_finished || _remainingSeconds <= 0) {
      _remainingSeconds = widget.minutes * 60;
    }

    setState(() {
      _finished = false;
      _motionElapsed = Duration.zero;
      _startCountdownValue = _sessionStartCountdownSeconds;
    });

    HapticFeedback.selectionClick();

    _startCountdownTimer = Timer.periodic(const Duration(seconds: 1), (
      Timer timer,
    ) {
      if (!mounted) {
        timer.cancel();
        return;
      }

      final currentCountdown = _startCountdownValue;
      if (currentCountdown == null) {
        timer.cancel();
        return;
      }

      if (currentCountdown <= 0) {
        timer.cancel();
        _beginSession();
        return;
      }

      setState(() {
        _startCountdownValue = currentCountdown - 1;
      });

      if (_startCountdownValue == 0) {
        HapticFeedback.mediumImpact();
      } else {
        HapticFeedback.selectionClick();
      }
    });
  }

  void _beginSession() {
    _finishExitTimer?.cancel();
    _startCountdownTimer?.cancel();
    _countdownTimer?.cancel();
    _motionTimer?.cancel();

    setState(() {
      _startCountdownValue = null;
      _running = true;
      _finished = false;
    });

    _countdownTimer = Timer.periodic(const Duration(seconds: 1), (Timer timer) {
      if (!mounted) {
        timer.cancel();
        return;
      }

      if (_remainingSeconds <= 1) {
        timer.cancel();
        _finishSession();
      } else {
        setState(() {
          _remainingSeconds -= 1;
        });
      }
    });

    _motionTimer = Timer.periodic(const Duration(milliseconds: 24), (
      Timer timer,
    ) {
      if (!mounted) {
        timer.cancel();
        return;
      }

      setState(() {
        _motionElapsed += const Duration(milliseconds: 24);
      });
    });
  }

  void _finishSession() {
    _finishExitTimer?.cancel();
    _startCountdownTimer?.cancel();
    _countdownTimer?.cancel();
    _motionTimer?.cancel();

    setState(() {
      _remainingSeconds = 0;
      _running = false;
      _finished = true;
      _startCountdownValue = null;
    });

    _finishExitTimer = Timer(const Duration(seconds: 2), () {
      if (!mounted) {
        return;
      }
      Navigator.of(context).pop(true);
    });
  }

  @override
  void dispose() {
    _finishExitTimer?.cancel();
    _startCountdownTimer?.cancel();
    _countdownTimer?.cancel();
    _motionTimer?.cancel();
    _exitFullscreenSessionMode();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final palette = context.appPalette;

    return Scaffold(
      body: DecoratedBox(
        decoration: BoxDecoration(
          gradient: RadialGradient(
            center: Alignment.center,
            radius: 1.14,
            colors: <Color>[palette.fullscreenMiddle, palette.fullscreenStart],
          ),
        ),
        child: SafeArea(
          child: Stack(
            children: <Widget>[
              Positioned(
                top: 12,
                left: 20,
                right: 20,
                child: Row(
                  children: <Widget>[
                    Container(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 14,
                        vertical: 10,
                      ),
                      decoration: BoxDecoration(
                        color: Colors.white.withValues(alpha: 0.08),
                        borderRadius: BorderRadius.circular(18),
                        border: Border.all(
                          color: Colors.white.withValues(alpha: 0.12),
                        ),
                      ),
                      child: Text(
                        _formatClock(_remainingSeconds),
                        style: theme.textTheme.titleMedium?.copyWith(
                          color: Colors.white,
                          fontWeight: FontWeight.w800,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
              Center(
                child: AnimatedSwitcher(
                  duration: const Duration(milliseconds: 220),
                  child: _finished
                      ? Container(
                          key: const ValueKey<String>(
                            'smooth-pursuit-finished',
                          ),
                          padding: const EdgeInsets.symmetric(
                            horizontal: 34,
                            vertical: 22,
                          ),
                          decoration: BoxDecoration(
                            color: Colors.white.withValues(alpha: 0.1),
                            borderRadius: BorderRadius.circular(26),
                            border: Border.all(
                              color: Colors.white.withValues(alpha: 0.14),
                            ),
                          ),
                          child: Text(
                            'Koniec',
                            style: theme.textTheme.headlineMedium?.copyWith(
                              color: Colors.white,
                              fontWeight: FontWeight.w900,
                              letterSpacing: 1.0,
                            ),
                          ),
                        )
                      : Column(
                          key: const ValueKey<String>('smooth-pursuit-active'),
                          mainAxisAlignment: MainAxisAlignment.center,
                          children: <Widget>[
                            SizedBox(
                              width: min(
                                MediaQuery.sizeOf(context).width - 40,
                                460,
                              ),
                              height: min(
                                MediaQuery.sizeOf(context).height * 0.54,
                                360,
                              ),
                              child: _PursuitArena(
                                accent: widget.accent,
                                elapsed: _motionElapsed,
                                countdownLabel: _isCountingDown
                                    ? _countdownLabel
                                    : null,
                              ),
                            ),
                          ],
                        ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class PeripheralFocusSessionPage extends StatefulWidget {
  const PeripheralFocusSessionPage({
    super.key,
    required this.accent,
    required this.minutes,
  });

  final Color accent;
  final int minutes;

  @override
  State<PeripheralFocusSessionPage> createState() =>
      _PeripheralFocusSessionPageState();
}

class _PeripheralFocusSessionPageState
    extends State<PeripheralFocusSessionPage> {
  static const int _sessionStartCountdownSeconds = 3;

  Timer? _startCountdownTimer;
  Timer? _countdownTimer;
  Timer? _stimulusTimer;
  Timer? _stimulusHideTimer;
  Timer? _finishExitTimer;
  late int _remainingSeconds;
  int? _startCountdownValue;
  bool _running = false;
  bool _finished = false;
  _PeripheralCueSlot? _activeSlot;
  bool _activeTarget = true;
  bool _canRespond = false;
  int _stimulusIndex = 0;
  int _score = 0;
  int _hits = 0;
  int _misses = 0;
  int _errors = 0;
  String _status = 'Trzymaj wzrok w środku.';

  @override
  void initState() {
    super.initState();
    _remainingSeconds = widget.minutes * 60;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _enterFullscreenSessionMode();
      if (mounted) {
        _start();
      }
    });
  }

  bool get _isCountingDown => _startCountdownValue != null;

  String get _countdownLabel {
    final value = _startCountdownValue;
    if (value == null) {
      return '';
    }
    return value == 0 ? 'START' : '$value';
  }

  String _formatClock(int seconds) {
    final minutes = (seconds ~/ 60).toString().padLeft(2, '0');
    final rest = (seconds % 60).toString().padLeft(2, '0');
    return '$minutes:$rest';
  }

  Duration get _stimulusDuration {
    return Duration(milliseconds: max(180, 320 - ((_score ~/ 5) * 20)));
  }

  Duration get _stimulusPause {
    return Duration(milliseconds: max(700, 1020 - ((_score ~/ 6) * 40)));
  }

  void _start() {
    if (_running || _isCountingDown) {
      return;
    }

    _finishExitTimer?.cancel();
    _startCountdownTimer?.cancel();
    _countdownTimer?.cancel();
    _stimulusTimer?.cancel();
    _stimulusHideTimer?.cancel();

    if (_finished || _remainingSeconds <= 0) {
      _remainingSeconds = widget.minutes * 60;
    }

    setState(() {
      _finished = false;
      _activeSlot = null;
      _activeTarget = true;
      _canRespond = false;
      _stimulusIndex = 0;
      _score = 0;
      _hits = 0;
      _misses = 0;
      _errors = 0;
      _status = 'Trzymaj wzrok w środku.';
      _startCountdownValue = _sessionStartCountdownSeconds;
    });

    HapticFeedback.selectionClick();

    _startCountdownTimer = Timer.periodic(const Duration(seconds: 1), (
      Timer timer,
    ) {
      if (!mounted) {
        timer.cancel();
        return;
      }

      final currentCountdown = _startCountdownValue;
      if (currentCountdown == null) {
        timer.cancel();
        return;
      }

      if (currentCountdown <= 0) {
        timer.cancel();
        _beginSession();
        return;
      }

      setState(() {
        _startCountdownValue = currentCountdown - 1;
      });

      if (_startCountdownValue == 0) {
        HapticFeedback.mediumImpact();
      } else {
        HapticFeedback.selectionClick();
      }
    });
  }

  void _beginSession() {
    _finishExitTimer?.cancel();
    _startCountdownTimer?.cancel();
    _countdownTimer?.cancel();
    _stimulusTimer?.cancel();
    _stimulusHideTimer?.cancel();

    setState(() {
      _startCountdownValue = null;
      _running = true;
      _finished = false;
      _status = 'Tapnij tylko przy jasnym błysku.';
    });

    _countdownTimer = Timer.periodic(const Duration(seconds: 1), (Timer timer) {
      if (!mounted) {
        timer.cancel();
        return;
      }

      if (_remainingSeconds <= 1) {
        timer.cancel();
        _finishSession();
      } else {
        setState(() {
          _remainingSeconds -= 1;
        });
      }
    });

    _scheduleNextStimulus(const Duration(milliseconds: 320));
  }

  void _scheduleNextStimulus(Duration delay) {
    _stimulusTimer?.cancel();
    if (!_running) {
      return;
    }
    _stimulusTimer = Timer(delay, _presentStimulus);
  }

  void _presentStimulus() {
    if (!mounted || !_running) {
      return;
    }

    final int slotIndex =
        ((_stimulusIndex * 3) + 1) % _PeripheralCueSlot.values.length;
    final _PeripheralCueSlot slot = _PeripheralCueSlot.values[slotIndex];
    final bool target = _stimulusIndex.isEven;

    setState(() {
      _activeSlot = slot;
      _activeTarget = target;
      _canRespond = true;
      _status = target
          ? 'Jasny błysk. Tapnij.'
          : 'Wabik. Ignoruj i trzymaj środek.';
    });

    _stimulusIndex += 1;
    _stimulusHideTimer?.cancel();
    _stimulusHideTimer = Timer(_stimulusDuration, _resolveStimulusTimeout);
  }

  void _resolveStimulusTimeout() {
    if (!mounted || !_running) {
      return;
    }

    final bool missedTarget = _canRespond && _activeTarget;

    setState(() {
      if (missedTarget) {
        _misses += 1;
        _status = 'Za późno. Wróć do środka.';
      } else {
        _status = 'Wróć uwagą do centrum.';
      }
      _activeSlot = null;
      _canRespond = false;
    });

    _scheduleNextStimulus(_stimulusPause);
  }

  void _handleTap() {
    if (!_running || !_canRespond || _activeSlot == null) {
      return;
    }

    _stimulusHideTimer?.cancel();

    if (_activeTarget) {
      HapticFeedback.mediumImpact();
      setState(() {
        _score += 1;
        _hits += 1;
        _status = 'Dobrze. Wracaj do centrum.';
        _activeSlot = null;
        _canRespond = false;
      });
    } else {
      HapticFeedback.lightImpact();
      setState(() {
        _score = max(0, _score - 1);
        _errors += 1;
        _status = 'To był wabik. Trzymaj środek.';
        _activeSlot = null;
        _canRespond = false;
      });
    }

    _scheduleNextStimulus(_stimulusPause);
  }

  void _finishSession() {
    _finishExitTimer?.cancel();
    _startCountdownTimer?.cancel();
    _countdownTimer?.cancel();
    _stimulusTimer?.cancel();
    _stimulusHideTimer?.cancel();

    setState(() {
      _remainingSeconds = 0;
      _running = false;
      _finished = true;
      _activeSlot = null;
      _canRespond = false;
      _startCountdownValue = null;
    });

    _finishExitTimer = Timer(const Duration(seconds: 2), () {
      if (!mounted) {
        return;
      }
      Navigator.of(context).pop(true);
    });
  }

  @override
  void dispose() {
    _finishExitTimer?.cancel();
    _startCountdownTimer?.cancel();
    _countdownTimer?.cancel();
    _stimulusTimer?.cancel();
    _stimulusHideTimer?.cancel();
    _exitFullscreenSessionMode();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final palette = context.appPalette;

    return Scaffold(
      body: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: _handleTap,
        child: DecoratedBox(
          decoration: BoxDecoration(
            gradient: RadialGradient(
              center: Alignment.center,
              radius: 1.14,
              colors: <Color>[
                palette.fullscreenMiddle,
                palette.fullscreenStart,
              ],
            ),
          ),
          child: SafeArea(
            child: Stack(
              children: <Widget>[
                Positioned(
                  top: 12,
                  left: 20,
                  right: 20,
                  child: Row(
                    children: <Widget>[
                      Container(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 14,
                          vertical: 10,
                        ),
                        decoration: BoxDecoration(
                          color: Colors.white.withValues(alpha: 0.08),
                          borderRadius: BorderRadius.circular(18),
                          border: Border.all(
                            color: Colors.white.withValues(alpha: 0.12),
                          ),
                        ),
                        child: Text(
                          _formatClock(_remainingSeconds),
                          style: theme.textTheme.titleMedium?.copyWith(
                            color: Colors.white,
                            fontWeight: FontWeight.w800,
                          ),
                        ),
                      ),
                      const Spacer(),
                      Container(
                        key: const ValueKey<String>('peripheral-focus-score'),
                        padding: const EdgeInsets.symmetric(
                          horizontal: 14,
                          vertical: 10,
                        ),
                        decoration: BoxDecoration(
                          color: widget.accent.withValues(alpha: 0.16),
                          borderRadius: BorderRadius.circular(18),
                        ),
                        child: Text(
                          'Punkty $_score',
                          style: theme.textTheme.labelLarge?.copyWith(
                            color: Colors.white,
                            fontWeight: FontWeight.w800,
                            letterSpacing: 0.6,
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
                Center(
                  child: AnimatedSwitcher(
                    duration: const Duration(milliseconds: 220),
                    child: _finished
                        ? Container(
                            key: const ValueKey<String>(
                              'peripheral-focus-finished',
                            ),
                            padding: const EdgeInsets.symmetric(
                              horizontal: 30,
                              vertical: 24,
                            ),
                            decoration: BoxDecoration(
                              color: Colors.white.withValues(alpha: 0.1),
                              borderRadius: BorderRadius.circular(26),
                              border: Border.all(
                                color: Colors.white.withValues(alpha: 0.14),
                              ),
                            ),
                            child: Column(
                              mainAxisSize: MainAxisSize.min,
                              children: <Widget>[
                                Text(
                                  'Koniec',
                                  style: theme.textTheme.headlineMedium
                                      ?.copyWith(
                                        color: Colors.white,
                                        fontWeight: FontWeight.w900,
                                        letterSpacing: 1.0,
                                      ),
                                ),
                                const SizedBox(height: 12),
                                Text(
                                  'Punkty $_score • trafione $_hits • pominięte $_misses • błędy $_errors',
                                  textAlign: TextAlign.center,
                                  style: theme.textTheme.bodyLarge?.copyWith(
                                    color: Colors.white.withValues(alpha: 0.86),
                                    height: 1.45,
                                  ),
                                ),
                              ],
                            ),
                          )
                        : Column(
                            key: const ValueKey<String>(
                              'peripheral-focus-active',
                            ),
                            mainAxisAlignment: MainAxisAlignment.center,
                            children: <Widget>[
                              SizedBox(
                                width: min(
                                  MediaQuery.sizeOf(context).width - 40,
                                  460,
                                ),
                                height: min(
                                  MediaQuery.sizeOf(context).height * 0.54,
                                  360,
                                ),
                                child: _PeripheralArena(
                                  accent: widget.accent,
                                  activeSlot: _activeSlot,
                                  activeTarget: _activeTarget,
                                  countdownLabel: _isCountingDown
                                      ? _countdownLabel
                                      : null,
                                ),
                              ),
                              const SizedBox(height: 18),
                              Text(
                                _isCountingDown
                                    ? 'Ustaw wzrok w centrum. Za chwilę zaczną wpadać bodźce z boków.'
                                    : _status,
                                textAlign: TextAlign.center,
                                style: theme.textTheme.bodyLarge?.copyWith(
                                  color: Colors.white.withValues(alpha: 0.86),
                                  height: 1.45,
                                ),
                              ),
                            ],
                          ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

enum _MemoryGameKind { chain, digits, words }

class _MemoryGameDefinition {
  const _MemoryGameDefinition({
    required this.kind,
    required this.label,
    required this.title,
    required this.summary,
    required this.focusLabel,
    required this.difficultyLabel,
    required this.icon,
  });

  final _MemoryGameKind kind;
  final String label;
  final String title;
  final String summary;
  final String focusLabel;
  final String difficultyLabel;
  final IconData icon;
}

const List<_MemoryGameDefinition>
_memoryGameDefinitions = <_MemoryGameDefinition>[
  _MemoryGameDefinition(
    kind: _MemoryGameKind.chain,
    label: 'Ruchy',
    title: 'Ścieżka Ruchów',
    summary:
        'Podświetlane strzałki tworzą trasę, którą trzeba odtworzyć bez cofania uwagi.',
    focusLabel: 'Pamięć sekwencji',
    difficultyLabel: 'Rytm + kierunek',
    icon: Icons.route_rounded,
  ),
  _MemoryGameDefinition(
    kind: _MemoryGameKind.digits,
    label: 'Kod cyfr',
    title: 'Kod Cyfr',
    summary:
        'Cyfry pojawiają się tylko na moment, znikają i trzeba wpisać je z czystej pamięci.',
    focusLabel: 'Pamięć liczbowa',
    difficultyLabel: '3-10 cyfr',
    icon: Icons.pin_outlined,
  ),
  _MemoryGameDefinition(
    kind: _MemoryGameKind.words,
    label: 'Półka słów',
    title: 'Półka Słów',
    summary:
        'Kilka konkretnych słów wpada na półkę, a po zniknięciu trzeba rozpoznać dokładnie te same.',
    focusLabel: 'Pamięć werbalna',
    difficultyLabel: 'Selekcja słów',
    icon: Icons.inventory_2_outlined,
  ),
];

const List<String> _memoryWordPool = <String>[
  'las',
  'klucz',
  'kubek',
  'most',
  'kamień',
  'sok',
  'okno',
  'zegar',
  'rower',
  'świeca',
  'wiatr',
  'lampka',
  'płomień',
  'wazon',
  'ogród',
  'notes',
  'plecak',
  'jezioro',
  'kasztan',
  'drabina',
  'sznur',
  'pióro',
  'księga',
  'lustro',
  'kołdra',
  'fotel',
  'słoik',
  'żagiel',
  'kompas',
  'strumień',
  'chmura',
  'gwiazda',
  'ścieżka',
  'parasol',
  'moneta',
  'gałąź',
  'walizka',
  'miska',
  'krzesło',
  'szuflada',
  'kaktus',
  'torba',
  'mapa',
  'tunel',
  'mewa',
  'muszla',
  'latarnia',
  'żyrandol',
  'piasek',
  'młotek',
  'igła',
  'ramka',
  'obraz',
  'gitara',
  'radio',
  'apteczka',
  'zamek',
  'kapturek',
  'pagórek',
  'termos',
  'dzwonek',
  'serweta',
  'brama',
  'ławka',
  'talerz',
  'widelec',
  'łyżka',
  'czajnik',
  'komin',
  'piwnica',
  'balkon',
  'chodnik',
  'planeta',
  'rakieta',
  'satelita',
  'jaskinia',
  'wstążka',
  'korona',
  'kotwica',
  'peron',
  'wagon',
  'tramwaj',
  'kiosk',
  'skwer',
  'cytryna',
  'gruszka',
  'śliwka',
  'malina',
  'jagoda',
  'marchew',
  'ogórek',
  'papryka',
  'cebula',
  'bazylia',
  'mięta',
  'lawenda',
  'burza',
  'tęcza',
  'śnieg',
  'mróz',
  'deszcz',
  'błyskawica',
  'wyspa',
  'zatoka',
  'rafa',
  'dolina',
  'skała',
  'klif',
  'pustynia',
  'wydma',
  'mech',
  'szyszka',
  'kora',
  'liść',
  'firanka',
  'dywan',
  'zasłona',
  'świecznik',
  'półka',
  'spinacz',
  'zszywacz',
  'folder',
  'koperta',
  'pieczątka',
  'klips',
  'magnes',
  'wieszak',
  'szczotka',
  'grzebień',
  'mydło',
  'ręcznik',
  'fartuch',
  'koszyk',
  'donica',
];

String _memoryPluralLabel(
  int count, {
  required String singular,
  required String paucal,
  required String plural,
}) {
  final mod10 = count % 10;
  final mod100 = count % 100;

  if (count == 1) {
    return singular;
  }
  if (mod10 >= 2 && mod10 <= 4 && (mod100 < 12 || mod100 > 14)) {
    return paucal;
  }
  return plural;
}

String _digitCountLabel(int count) {
  return '$count ${_memoryPluralLabel(count, singular: 'cyfra', paucal: 'cyfry', plural: 'cyfr')}';
}

String _memoryElementCountLabel(int count) {
  return '$count ${_memoryPluralLabel(count, singular: 'element', paucal: 'elementy', plural: 'elementów')}';
}

String _wordCountLabel(int count) {
  return '$count ${_memoryPluralLabel(count, singular: 'słowo', paucal: 'słowa', plural: 'słów')}';
}

const Color _memorySuccessColor = Color(0xFF2FA866);
const Color _memoryFailureColor = Color(0xFFD35757);

class _MemoryGameSelectorCard extends StatefulWidget {
  const _MemoryGameSelectorCard({
    required this.accent,
    required this.selectedGame,
    required this.onGameChanged,
  });

  final Color accent;
  final _MemoryGameKind selectedGame;
  final ValueChanged<_MemoryGameKind> onGameChanged;

  @override
  State<_MemoryGameSelectorCard> createState() =>
      _MemoryGameSelectorCardState();
}

class _MemoryGameSelectorCardState extends State<_MemoryGameSelectorCard> {
  late final PageController _pageController;

  @override
  void initState() {
    super.initState();
    _pageController = PageController(initialPage: widget.selectedGame.index);
  }

  @override
  void didUpdateWidget(covariant _MemoryGameSelectorCard oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.selectedGame == oldWidget.selectedGame ||
        !_pageController.hasClients) {
      return;
    }

    _pageController.animateToPage(
      widget.selectedGame.index,
      duration: const Duration(milliseconds: 220),
      curve: Curves.easeOutCubic,
    );
  }

  @override
  void dispose() {
    _pageController.dispose();
    super.dispose();
  }

  void _handleGameTap(_MemoryGameKind kind) {
    if (widget.selectedGame == kind) {
      return;
    }

    widget.onGameChanged(kind);
  }

  void _handlePageChanged(int index) {
    final nextGame = _memoryGameDefinitions[index].kind;
    if (nextGame == widget.selectedGame) {
      return;
    }

    widget.onGameChanged(nextGame);
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final palette = context.appPalette;
    final selectedIndex = widget.selectedGame.index;

    return SurfaceCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          const SectionHeader(eyebrow: 'Gry', title: 'Tryby gry'),
          const SizedBox(height: 18),
          Container(
            width: double.infinity,
            height: 170,
            padding: const EdgeInsets.fromLTRB(18, 16, 18, 14),
            decoration: BoxDecoration(
              gradient: LinearGradient(
                begin: Alignment.topLeft,
                end: Alignment.bottomRight,
                colors: <Color>[
                  widget.accent.withValues(alpha: 0.16),
                  palette.surfaceStrong,
                ],
              ),
              borderRadius: BorderRadius.circular(26),
              border: Border.all(color: widget.accent.withValues(alpha: 0.18)),
            ),
            child: Column(
              children: <Widget>[
                Expanded(
                  child: PageView.builder(
                    controller: _pageController,
                    itemCount: _memoryGameDefinitions.length,
                    physics: const BouncingScrollPhysics(),
                    onPageChanged: _handlePageChanged,
                    itemBuilder: (BuildContext context, int index) {
                      final game = _memoryGameDefinitions[index];
                      final isSelected = index == selectedIndex;

                      return GestureDetector(
                        onTap: () => _handleGameTap(game.kind),
                        child: Container(
                          key: ValueKey<String>(
                            'memory-game-card-${game.kind.name}',
                          ),
                          width: double.infinity,
                          padding: const EdgeInsets.all(18),
                          decoration: BoxDecoration(
                            color: palette.surface.withValues(alpha: 0.92),
                            borderRadius: BorderRadius.circular(22),
                            border: Border.all(
                              color: isSelected
                                  ? widget.accent.withValues(alpha: 0.42)
                                  : widget.accent.withValues(alpha: 0.24),
                            ),
                          ),
                          child: Center(
                            child: Text(
                              game.title,
                              textAlign: TextAlign.center,
                              style: theme.textTheme.titleLarge?.copyWith(
                                color: palette.primaryText,
                                fontWeight: FontWeight.w900,
                              ),
                            ),
                          ),
                        ),
                      );
                    },
                  ),
                ),
                const SizedBox(height: 12),
                Row(
                  mainAxisSize: MainAxisSize.min,
                  children: List<Widget>.generate(
                    _memoryGameDefinitions.length,
                    (int index) {
                      final bool selected = index == selectedIndex;
                      return AnimatedContainer(
                        duration: const Duration(milliseconds: 180),
                        margin: EdgeInsets.only(left: index == 0 ? 0 : 6),
                        width: selected ? 18 : 8,
                        height: 8,
                        decoration: BoxDecoration(
                          color: selected
                              ? widget.accent
                              : widget.accent.withValues(alpha: 0.24),
                          borderRadius: BorderRadius.circular(999),
                        ),
                      );
                    },
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class MemoryArcadeTrainer extends StatefulWidget {
  const MemoryArcadeTrainer({
    super.key,
    required this.accent,
    this.initialGameIndex = 0,
    this.showGameSelector = true,
    this.onSessionStarted,
  });

  final Color accent;
  final int initialGameIndex;
  final bool showGameSelector;
  final VoidCallback? onSessionStarted;

  @override
  State<MemoryArcadeTrainer> createState() => _MemoryArcadeTrainerState();
}

class _MemoryArcadeTrainerState extends State<MemoryArcadeTrainer> {
  late _MemoryGameKind _selectedGame;

  @override
  void initState() {
    super.initState();
    _selectedGame = _gameFromIndex(widget.initialGameIndex);
  }

  @override
  void didUpdateWidget(covariant MemoryArcadeTrainer oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.initialGameIndex == oldWidget.initialGameIndex) {
      return;
    }

    setState(() {
      _selectedGame = _gameFromIndex(widget.initialGameIndex);
    });
  }

  _MemoryGameKind _gameFromIndex(int index) {
    final normalizedIndex = max(
      0,
      min(index, _MemoryGameKind.values.length - 1),
    );
    return _MemoryGameKind.values[normalizedIndex];
  }

  void _selectGame(_MemoryGameKind kind) {
    if (_selectedGame == kind) {
      return;
    }
    setState(() {
      _selectedGame = kind;
    });
  }

  Widget _buildTrainer() {
    return switch (_selectedGame) {
      _MemoryGameKind.chain => MemoryChainTrainer(
        key: const ValueKey<String>('memory-trainer-chain'),
        accent: widget.accent,
        fullscreenOnStart: true,
        onSessionStarted: widget.onSessionStarted,
      ),
      _MemoryGameKind.digits => DigitSpanTrainer(
        key: const ValueKey<String>('memory-trainer-digits'),
        accent: widget.accent,
        fullscreenOnStart: true,
        onSessionStarted: widget.onSessionStarted,
      ),
      _MemoryGameKind.words => WordShelfTrainer(
        key: const ValueKey<String>('memory-trainer-words'),
        accent: widget.accent,
        fullscreenOnStart: true,
        onSessionStarted: widget.onSessionStarted,
      ),
    };
  }

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        if (widget.showGameSelector) ...<Widget>[
          _MemoryGameSelectorCard(
            accent: widget.accent,
            selectedGame: _selectedGame,
            onGameChanged: _selectGame,
          ),
          const SizedBox(height: 18),
        ],
        AnimatedSwitcher(
          duration: const Duration(milliseconds: 220),
          child: _buildTrainer(),
        ),
      ],
    );
  }
}

class _MemoryStatsRow extends StatelessWidget {
  const _MemoryStatsRow({
    required this.accent,
    required this.points,
    required this.level,
  });

  final Color accent;
  final String points;
  final String level;

  @override
  Widget build(BuildContext context) {
    return Row(
      children: <Widget>[
        Expanded(
          child: StatStrip(label: 'Punkty', value: points, tint: accent),
        ),
        const SizedBox(width: 10),
        Expanded(
          child: StatStrip(label: 'Lvl', value: level, tint: accent),
        ),
      ],
    );
  }
}

class _MemoryCountdownDisplay extends StatelessWidget {
  const _MemoryCountdownDisplay({
    required this.label,
    required this.accent,
    required this.valueKeyPrefix,
  });

  final String label;
  final Color accent;
  final String valueKeyPrefix;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return Column(
      key: ValueKey<String>('$valueKeyPrefix-$label'),
      mainAxisAlignment: MainAxisAlignment.center,
      children: <Widget>[
        Text(
          label,
          style: theme.textTheme.displayMedium?.copyWith(
            color: accent,
            fontWeight: FontWeight.w900,
            letterSpacing: label == 'Start' ? 0.4 : 0,
          ),
        ),
      ],
    );
  }
}

class _MemoryRoundFeedbackBadge extends StatelessWidget {
  const _MemoryRoundFeedbackBadge({
    super.key,
    required this.success,
    required this.successIcon,
    required this.failureIcon,
  });

  final bool success;
  final IconData successIcon;
  final IconData failureIcon;

  @override
  Widget build(BuildContext context) {
    final color = success ? _memorySuccessColor : _memoryFailureColor;

    return Container(
      width: 88,
      height: 88,
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.14),
        shape: BoxShape.circle,
      ),
      alignment: Alignment.center,
      child: Icon(success ? successIcon : failureIcon, color: color, size: 42),
    );
  }
}

class DigitSpanTrainer extends StatefulWidget {
  const DigitSpanTrainer({
    super.key,
    required this.accent,
    this.autoStart = false,
    this.fullscreenOnStart = false,
    this.autoExitOnFinish = false,
    this.onSessionStarted,
  });

  final Color accent;
  final bool autoStart;
  final bool fullscreenOnStart;
  final bool autoExitOnFinish;
  final VoidCallback? onSessionStarted;

  @override
  State<DigitSpanTrainer> createState() => _DigitSpanTrainerState();
}

class _DigitSpanTrainerState extends State<DigitSpanTrainer> {
  static const int _sessionStartCountdownSeconds = 3;
  static const int _maxDigits = 10;

  final Random _random = Random();
  final TextEditingController _answerController = TextEditingController();

  Timer? _startCountdownTimer;
  Timer? _fadeTimer;
  Timer? _hidePromptTimer;
  Timer? _roundAdvanceTimer;
  Timer? _finishExitTimer;

  int _digitCount = 3;
  int _successPoints = 0;
  int _mistakes = 0;
  int _points = 0;
  int? _countdownValue;
  bool _hasSessionStarted = false;
  bool _finished = false;
  bool _showingDigits = false;
  bool _digitsFading = false;
  bool _awaitingAnswer = false;
  bool _roundResolved = false;
  bool _lastAnswerCorrect = false;
  String _currentDigits = '';
  String _status = 'Naciśnij Start sesji i złap kod cyfr.';

  bool get _isCountingDown => _countdownValue != null;
  int get _requiredSuccesses => _digitCount >= 5 ? 3 : 2;
  bool get _canSubmit => _answerController.text.trim().length == _digitCount;

  String get _countdownLabel {
    final value = _countdownValue;
    if (value == null) {
      return '';
    }
    return value == 0 ? 'Start' : '$value';
  }

  String _withMistakeStatus(String message) {
    if (_mistakes <= 0) {
      return message;
    }
    return '$message Błędy $_mistakes/2.';
  }

  String get _phaseHint {
    if (_finished) {
      return widget.autoExitOnFinish
          ? 'Sesja zakończona po dwóch błędach. Za moment wrócisz do wyboru gry.'
          : 'Sesja zakończona po dwóch błędach. Możesz uruchomić ją ponownie.';
    }
    if (_isCountingDown) {
      return 'Najpierw zobaczysz kod, potem cyfry zaczną miękko znikać i trzeba będzie wpisać je z pamięci.';
    }
    if (_showingDigits) {
      return 'Patrz spokojnie na cały ciąg. Nie próbuj go powtarzać na głos.';
    }
    if (_awaitingAnswer) {
      return 'Wpisz dokładnie ten sam układ cyfr. Druga pomyłka kończy sesję.';
    }
    if (_roundResolved && _lastAnswerCorrect) {
      return 'Dobra odpowiedź buduje serię. Gdy zamkniesz serię, długość kodu wzrośnie.';
    }
    if (_roundResolved) {
      return 'Jedna pomyłka jeszcze zostawia ci ruch. Druga zamyka sesję.';
    }
    return 'Zaczynasz od 3 cyfr i możesz dojść aż do 10.';
  }

  @override
  void initState() {
    super.initState();
    if (widget.autoStart) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) {
          _startGame();
        }
      });
    }
  }

  void _cancelRoundTimers() {
    _startCountdownTimer?.cancel();
    _fadeTimer?.cancel();
    _hidePromptTimer?.cancel();
    _roundAdvanceTimer?.cancel();
    _finishExitTimer?.cancel();
  }

  Future<void> _startGame() async {
    if (_isCountingDown) {
      return;
    }

    widget.onSessionStarted?.call();
    _cancelRoundTimers();
    _answerController.clear();

    setState(() {
      _digitCount = 3;
      _successPoints = 0;
      _mistakes = 0;
      _points = 0;
      _countdownValue = _sessionStartCountdownSeconds;
      _hasSessionStarted = true;
      _finished = false;
      _showingDigits = false;
      _digitsFading = false;
      _awaitingAnswer = false;
      _roundResolved = false;
      _lastAnswerCorrect = false;
      _currentDigits = '';
      _status = 'Gra startuje. Złap kod.';
    });

    HapticFeedback.selectionClick();

    _startCountdownTimer = Timer.periodic(const Duration(seconds: 1), (
      Timer timer,
    ) {
      if (!mounted) {
        timer.cancel();
        return;
      }

      final currentCountdown = _countdownValue;
      if (currentCountdown == null) {
        timer.cancel();
        return;
      }

      if (currentCountdown <= 0) {
        timer.cancel();
        setState(() {
          _countdownValue = null;
        });
        _beginRound();
        return;
      }

      setState(() {
        _countdownValue = currentCountdown - 1;
      });

      if (_countdownValue == 0) {
        HapticFeedback.mediumImpact();
      } else {
        HapticFeedback.selectionClick();
      }
    });
  }

  void _beginRound() {
    if (_finished) {
      return;
    }

    _cancelRoundTimers();
    _answerController.clear();

    final digits = List<String>.generate(
      _digitCount,
      (_) => '${_random.nextInt(10)}',
    );

    setState(() {
      _currentDigits = digits.join();
      _showingDigits = true;
      _digitsFading = false;
      _awaitingAnswer = false;
      _roundResolved = false;
      _lastAnswerCorrect = false;
      _status = 'Zapamiętaj ${_digitCountLabel(_digitCount)}.';
    });

    _fadeTimer = Timer(const Duration(milliseconds: 1200), () {
      if (!mounted) {
        return;
      }
      setState(() {
        _digitsFading = true;
      });
    });

    _hidePromptTimer = Timer(const Duration(milliseconds: 2200), () {
      if (!mounted) {
        return;
      }
      setState(() {
        _showingDigits = false;
        _digitsFading = false;
        _awaitingAnswer = true;
        _status = 'Wpisz kod z pamięci.';
      });
    });
  }

  void _finishSession() {
    _cancelRoundTimers();
    _answerController.clear();

    setState(() {
      _mistakes = 2;
      _finished = true;
      _countdownValue = null;
      _showingDigits = false;
      _digitsFading = false;
      _awaitingAnswer = false;
      _roundResolved = false;
      _lastAnswerCorrect = false;
      _currentDigits = '';
      _status = 'Koniec';
    });

    if (!widget.autoExitOnFinish) {
      return;
    }

    _finishExitTimer = Timer(const Duration(seconds: 2), () {
      if (!mounted) {
        return;
      }
      Navigator.of(context).maybePop();
    });
  }

  void _handleSubmit() {
    if (_finished || !_awaitingAnswer || !_canSubmit) {
      return;
    }

    final answer = _answerController.text.replaceAll(RegExp(r'\D'), '');
    final correct = answer == _currentDigits;

    if (correct) {
      final earnedPoints = _digitCount;
      final nextProgress = _successPoints + 1;
      final completedSeries = nextProgress >= _requiredSuccesses;
      final reachedCap = _digitCount >= _maxDigits;

      HapticFeedback.mediumImpact();
      setState(() {
        _awaitingAnswer = false;
        _roundResolved = true;
        _lastAnswerCorrect = true;
        _points += earnedPoints;

        if (completedSeries && !reachedCap) {
          _digitCount += 1;
          _successPoints = 0;
          _status = _withMistakeStatus(
            'Pełna seria. Wchodzisz na ${_digitCountLabel(_digitCount)}.',
          );
        } else if (completedSeries) {
          _successPoints = _requiredSuccesses;
          _status = _withMistakeStatus(
            'Maksimum osiągnięte. Trzymasz ${_digitCountLabel(_digitCount)}.',
          );
        } else {
          _successPoints = nextProgress;
          _status = _withMistakeStatus(
            'Dobrze. Seria $_successPoints/$_requiredSuccesses na tym poziomie.',
          );
        }
      });

      _roundAdvanceTimer = Timer(const Duration(milliseconds: 1500), () {
        if (!mounted || _finished) {
          return;
        }
        _beginRound();
      });
      return;
    }

    final nextMistakes = _mistakes + 1;
    final nextProgress = max(0, _successPoints - 1);

    if (nextMistakes >= 2) {
      HapticFeedback.mediumImpact();
      _finishSession();
      return;
    }

    HapticFeedback.lightImpact();
    setState(() {
      _awaitingAnswer = false;
      _roundResolved = true;
      _lastAnswerCorrect = false;
      _successPoints = nextProgress;
      _mistakes = nextMistakes;
      _status =
          'To nie ten kod. Postęp $_successPoints/$_requiredSuccesses, błędy $_mistakes/2.';
    });
  }

  Future<void> _openFullscreenSession() {
    return Navigator.of(context).push<void>(
      _buildExerciseSessionRoute<void>(
        builder: (BuildContext context) {
          return FullscreenTrainerPage(
            title: 'Drabina Pamięci • Kod Cyfr',
            accent: widget.accent,
            child: DigitSpanTrainer(
              accent: widget.accent,
              autoStart: true,
              autoExitOnFinish: true,
            ),
          );
        },
      ),
    );
  }

  Future<void> _handleStartAction() async {
    if (widget.fullscreenOnStart) {
      widget.onSessionStarted?.call();
      await _openFullscreenSession();
      return;
    }

    await _startGame();
  }

  @override
  void dispose() {
    _cancelRoundTimers();
    _answerController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        _hasSessionStarted
            ? _MemoryStatsRow(
                accent: widget.accent,
                points: '$_points',
                level: '$_digitCount',
              )
            : Container(
                width: double.infinity,
                padding: const EdgeInsets.all(18),
                decoration: BoxDecoration(
                  color: widget.accent.withValues(alpha: 0.1),
                  borderRadius: BorderRadius.circular(24),
                  border: Border.all(
                    color: widget.accent.withValues(alpha: 0.18),
                  ),
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: <Widget>[
                    Text(
                      _status,
                      style: theme.textTheme.titleMedium?.copyWith(
                        color: const Color(0xFF16212B),
                        fontWeight: FontWeight.w800,
                      ),
                    ),
                    const SizedBox(height: 8),
                    Text(
                      _phaseHint,
                      style: theme.textTheme.bodyMedium?.copyWith(
                        color: const Color(0xFF4A5761),
                        height: 1.5,
                      ),
                    ),
                  ],
                ),
              ),
        const SizedBox(height: 18),
        Container(
          width: double.infinity,
          constraints: const BoxConstraints(minHeight: 320),
          padding: const EdgeInsets.all(24),
          decoration: BoxDecoration(
            color: const Color(0xFFF9F5EF),
            borderRadius: BorderRadius.circular(26),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              Center(
                child: AnimatedSwitcher(
                  duration: const Duration(milliseconds: 220),
                  child: _isCountingDown
                      ? _MemoryCountdownDisplay(
                          label: _countdownLabel,
                          accent: widget.accent,
                          valueKeyPrefix: 'digit-span-countdown',
                        )
                      : _finished
                      ? Container(
                          key: const ValueKey<String>('digit-span-finished'),
                          padding: const EdgeInsets.symmetric(
                            horizontal: 34,
                            vertical: 22,
                          ),
                          decoration: BoxDecoration(
                            color: widget.accent.withValues(alpha: 0.12),
                            borderRadius: BorderRadius.circular(26),
                          ),
                          child: Text(
                            'Koniec',
                            style: theme.textTheme.headlineMedium?.copyWith(
                              color: const Color(0xFF16212B),
                              fontWeight: FontWeight.w900,
                              letterSpacing: 1.0,
                            ),
                          ),
                        )
                      : _showingDigits
                      ? AnimatedOpacity(
                          key: const ValueKey<String>('digit-span-prompt'),
                          opacity: _digitsFading ? 0 : 1,
                          duration: const Duration(milliseconds: 850),
                          child: SizedBox(
                            width: double.infinity,
                            child: FittedBox(
                              fit: BoxFit.scaleDown,
                              child: Text(
                                _currentDigits.split('').join(' '),
                                maxLines: 1,
                                softWrap: false,
                                textAlign: TextAlign.center,
                                style: theme.textTheme.displaySmall?.copyWith(
                                  color: const Color(0xFF16212B),
                                  fontWeight: FontWeight.w900,
                                  letterSpacing: 2.0,
                                ),
                              ),
                            ),
                          ),
                        )
                      : _awaitingAnswer
                      ? ConstrainedBox(
                          key: const ValueKey<String>('digit-span-answer'),
                          constraints: const BoxConstraints(maxWidth: 320),
                          child: Column(
                            mainAxisSize: MainAxisSize.min,
                            children: <Widget>[
                              TextField(
                                key: const ValueKey<String>(
                                  'digit-span-answer-field',
                                ),
                                controller: _answerController,
                                autofocus: widget.autoStart,
                                textAlign: TextAlign.center,
                                keyboardType: TextInputType.number,
                                inputFormatters: <TextInputFormatter>[
                                  FilteringTextInputFormatter.digitsOnly,
                                  LengthLimitingTextInputFormatter(_digitCount),
                                ],
                                style: theme.textTheme.headlineMedium?.copyWith(
                                  color: const Color(0xFF16212B),
                                  fontWeight: FontWeight.w900,
                                  letterSpacing: 2,
                                ),
                                decoration: InputDecoration(
                                  hintText: 'Wpisz kod',
                                  counterText: '',
                                  filled: true,
                                  fillColor: Colors.white,
                                  border: OutlineInputBorder(
                                    borderRadius: BorderRadius.circular(22),
                                    borderSide: BorderSide(
                                      color: widget.accent.withValues(
                                        alpha: 0.2,
                                      ),
                                    ),
                                  ),
                                  enabledBorder: OutlineInputBorder(
                                    borderRadius: BorderRadius.circular(22),
                                    borderSide: BorderSide(
                                      color: widget.accent.withValues(
                                        alpha: 0.2,
                                      ),
                                    ),
                                  ),
                                  focusedBorder: OutlineInputBorder(
                                    borderRadius: BorderRadius.circular(22),
                                    borderSide: BorderSide(
                                      color: widget.accent,
                                      width: 1.6,
                                    ),
                                  ),
                                ),
                                onChanged: (String value) {
                                  setState(() {});
                                  if (_awaitingAnswer &&
                                      value.length == _digitCount) {
                                    _handleSubmit();
                                  }
                                },
                                onSubmitted: (_) => _handleSubmit(),
                              ),
                            ],
                          ),
                        )
                      : _roundResolved
                      ? _MemoryRoundFeedbackBadge(
                          key: ValueKey<String>(
                            'digit-span-feedback-${_lastAnswerCorrect ? 'ok' : 'fail'}',
                          ),
                          success: _lastAnswerCorrect,
                          successIcon: Icons.verified_rounded,
                          failureIcon: Icons.refresh_rounded,
                        )
                      : Column(
                          key: const ValueKey<String>('digit-span-idle'),
                          mainAxisAlignment: MainAxisAlignment.center,
                          children: <Widget>[
                            Icon(
                              Icons.pin_outlined,
                              size: 44,
                              color: widget.accent,
                            ),
                            const SizedBox(height: 12),
                            Text(
                              'Kod pojawi się tylko na moment',
                              style: theme.textTheme.titleLarge?.copyWith(
                                color: const Color(0xFF16212B),
                                fontWeight: FontWeight.w900,
                              ),
                            ),
                          ],
                        ),
                ),
              ),
            ],
          ),
        ),
        const SizedBox(height: 18),
        SizedBox(
          width: double.infinity,
          child: switch ((
            _finished,
            _isCountingDown,
            _showingDigits,
            _awaitingAnswer,
            _roundResolved,
            _currentDigits.isEmpty,
          )) {
            (true, _, _, _, _, _) =>
              widget.autoExitOnFinish
                  ? const SizedBox.shrink()
                  : FilledButton(
                      onPressed: _handleStartAction,
                      child: const Text('Start sesji'),
                    ),
            (_, true, _, _, _, _) => const SizedBox.shrink(),
            (_, _, true, _, _, _) => const SizedBox.shrink(),
            (_, _, _, true, _, _) => const SizedBox.shrink(),
            (_, _, _, _, true, _) => FilledButton(
              onPressed: _beginRound,
              child: const Text('Następny kod'),
            ),
            (_, _, _, _, _, true) => FilledButton(
              onPressed: _handleStartAction,
              child: const Text('Start sesji'),
            ),
            _ => FilledButton(
              onPressed: _beginRound,
              child: const Text('Nowy kod'),
            ),
          },
        ),
      ],
    );
  }
}

class WordShelfTrainer extends StatefulWidget {
  const WordShelfTrainer({
    super.key,
    required this.accent,
    this.autoStart = false,
    this.fullscreenOnStart = false,
    this.onSessionStarted,
  });

  final Color accent;
  final bool autoStart;
  final bool fullscreenOnStart;
  final VoidCallback? onSessionStarted;

  @override
  State<WordShelfTrainer> createState() => _WordShelfTrainerState();
}

class _WordShelfTrainerState extends State<WordShelfTrainer> {
  static const int _sessionStartCountdownSeconds = 3;
  static const int _maxWords = 8;

  final Random _random = Random();

  Timer? _startCountdownTimer;
  Timer? _fadeTimer;
  Timer? _hideShelfTimer;
  Timer? _roundAdvanceTimer;

  int _wordCount = 3;
  int _successPoints = 0;
  int _mistakes = 0;
  int _points = 0;
  int? _countdownValue;
  bool _hasSessionStarted = false;
  bool _showingWords = false;
  bool _wordsFading = false;
  bool _awaitingSelection = false;
  bool _roundResolved = false;
  bool _lastAnswerCorrect = false;
  List<String> _sessionWordBag = <String>[];
  Set<String> _recentRoundWords = <String>{};
  List<String> _currentWords = <String>[];
  List<String> _options = <String>[];
  Set<String> _selectedWords = <String>{};
  String _status = 'Naciśnij Start sesji i zapamiętaj półkę słów.';

  bool get _isCountingDown => _countdownValue != null;
  int get _requiredSuccesses => _wordCount >= 5 ? 3 : 2;
  bool get _canSubmit => _selectedWords.length == _wordCount;

  String get _countdownLabel {
    final value = _countdownValue;
    if (value == null) {
      return '';
    }
    return value == 0 ? 'Start' : '$value';
  }

  String get _phaseHint {
    if (_isCountingDown) {
      return 'Za moment zobaczysz półkę. Słowa znikną i trzeba będzie wskazać dokładnie te same.';
    }
    if (_showingWords) {
      return 'Chwytaj obrazy słów, nie czytaj ich za wolno jedno po drugim.';
    }
    if (_awaitingSelection) {
      return 'Wybierz dokładnie tyle słów, ile było na półce. Dwie pomyłki na poziomie cofają o jeden krok.';
    }
    if (_roundResolved && _lastAnswerCorrect) {
      return 'Dobra odpowiedź zalicza się automatycznie. Zielone potwierdzenie zniknie i za chwilę ruszy następna półka.';
    }
    if (_roundResolved) {
      return 'Pomyłka cofa postęp. Przy dwóch błędach na poziomie liczba słów spada.';
    }
    return 'Zaczynasz od 3 słów i możesz dojść do 8.';
  }

  @override
  void initState() {
    super.initState();
    if (widget.autoStart) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) {
          _startGame();
        }
      });
    }
  }

  void _cancelRoundTimers() {
    _startCountdownTimer?.cancel();
    _fadeTimer?.cancel();
    _hideShelfTimer?.cancel();
    _roundAdvanceTimer?.cancel();
  }

  List<String> _buildSessionWordBag({Set<String> defer = const <String>{}}) {
    final freshWords =
        _memoryWordPool.where((String word) => !defer.contains(word)).toList()
          ..shuffle(_random);
    final deferredWords =
        _memoryWordPool.where((String word) => defer.contains(word)).toList()
          ..shuffle(_random);
    return <String>[...freshWords, ...deferredWords];
  }

  void _resetSessionWordBag({Set<String> defer = const <String>{}}) {
    _sessionWordBag = _buildSessionWordBag(defer: defer);
  }

  List<String> _takeSessionWords(int count) {
    final picked = _sessionWordBag.take(count).toList();
    _sessionWordBag = _sessionWordBag.skip(count).toList();
    return picked;
  }

  Future<void> _startGame() async {
    if (_isCountingDown) {
      return;
    }

    widget.onSessionStarted?.call();
    _cancelRoundTimers();

    setState(() {
      _wordCount = 3;
      _successPoints = 0;
      _mistakes = 0;
      _points = 0;
      _countdownValue = _sessionStartCountdownSeconds;
      _hasSessionStarted = true;
      _showingWords = false;
      _wordsFading = false;
      _awaitingSelection = false;
      _roundResolved = false;
      _lastAnswerCorrect = false;
      _sessionWordBag = _buildSessionWordBag();
      _recentRoundWords = <String>{};
      _currentWords = <String>[];
      _options = <String>[];
      _selectedWords = <String>{};
      _status = 'Gra startuje. Złap półkę.';
    });

    HapticFeedback.selectionClick();

    _startCountdownTimer = Timer.periodic(const Duration(seconds: 1), (
      Timer timer,
    ) {
      if (!mounted) {
        timer.cancel();
        return;
      }

      final currentCountdown = _countdownValue;
      if (currentCountdown == null) {
        timer.cancel();
        return;
      }

      if (currentCountdown <= 0) {
        timer.cancel();
        setState(() {
          _countdownValue = null;
        });
        _beginRound();
        return;
      }

      setState(() {
        _countdownValue = currentCountdown - 1;
      });

      if (_countdownValue == 0) {
        HapticFeedback.mediumImpact();
      } else {
        HapticFeedback.selectionClick();
      }
    });
  }

  void _beginRound() {
    _cancelRoundTimers();

    final distractorCount = min(4, max(3, _wordCount - 1));
    final totalWordsNeeded = _wordCount + distractorCount;
    final recentRoundWords = Set<String>.from(_recentRoundWords);

    if (_sessionWordBag.length < totalWordsNeeded) {
      _resetSessionWordBag(defer: recentRoundWords);
    }

    final words = _takeSessionWords(_wordCount);
    final distractors = _takeSessionWords(distractorCount);
    final options = <String>[...words, ...distractors]..shuffle(_random);

    setState(() {
      _recentRoundWords = options.toSet();
      _currentWords = words;
      _options = options;
      _selectedWords = <String>{};
      _showingWords = true;
      _wordsFading = false;
      _awaitingSelection = false;
      _roundResolved = false;
      _status = 'Zapamiętaj ${_wordCountLabel(_wordCount)}.';
    });

    _fadeTimer = Timer(const Duration(milliseconds: 1600), () {
      if (!mounted) {
        return;
      }
      setState(() {
        _wordsFading = true;
      });
    });

    _hideShelfTimer = Timer(const Duration(milliseconds: 2900), () {
      if (!mounted) {
        return;
      }
      setState(() {
        _showingWords = false;
        _wordsFading = false;
        _awaitingSelection = true;
        _status = 'Wybierz słowa, które były na półce.';
      });
    });
  }

  void _toggleWord(String word, bool selected) {
    if (!_awaitingSelection) {
      return;
    }

    late final Set<String> nextSelectedWords;
    setState(() {
      nextSelectedWords = selected
          ? <String>{..._selectedWords, word}
          : <String>{..._selectedWords.where((String item) => item != word)};
      _selectedWords = nextSelectedWords;
    });

    if (nextSelectedWords.length == _wordCount) {
      _handleSubmit();
    }
  }

  void _handleSubmit() {
    if (!_awaitingSelection || !_canSubmit) {
      return;
    }

    final expected = _currentWords.toSet();
    final correct =
        _selectedWords.length == expected.length &&
        _selectedWords.containsAll(expected);

    if (correct) {
      final earnedPoints = _wordCount;
      final nextProgress = _successPoints + 1;
      final completedSeries = nextProgress >= _requiredSuccesses;
      final reachedCap = _wordCount >= _maxWords;

      HapticFeedback.mediumImpact();
      setState(() {
        _awaitingSelection = false;
        _roundResolved = true;
        _lastAnswerCorrect = true;
        _mistakes = 0;
        _points += earnedPoints;

        if (completedSeries && !reachedCap) {
          _wordCount += 1;
          _successPoints = 0;
          _status =
              'Półka rośnie. Wchodzisz na ${_wordCountLabel(_wordCount)} i za chwilę leci następna.';
        } else if (completedSeries) {
          _successPoints = _requiredSuccesses;
          _status =
              'Maksimum osiągnięte. Trzymasz ${_wordCountLabel(_wordCount)} i za chwilę leci następna półka.';
        } else {
          _successPoints = nextProgress;
          _status =
              'Dobrze. Seria $_successPoints/$_requiredSuccesses na tym poziomie, następna półka za chwilę.';
        }
      });

      _roundAdvanceTimer = Timer(const Duration(seconds: 2), () {
        if (!mounted) {
          return;
        }
        _beginRound();
      });
      return;
    }

    final nextMistakes = _mistakes + 1;
    final nextProgress = max(0, _successPoints - 1);
    final shouldDrop = nextMistakes >= 2 && _wordCount > 3;

    HapticFeedback.lightImpact();
    setState(() {
      _awaitingSelection = false;
      _roundResolved = true;
      _lastAnswerCorrect = false;

      if (shouldDrop) {
        _wordCount -= 1;
        _successPoints = 0;
        _mistakes = 0;
        _status = 'Dwie pomyłki. Wracasz do ${_wordCountLabel(_wordCount)}.';
      } else {
        _successPoints = nextProgress;
        _mistakes = nextMistakes;
        _status =
            'To nie był ten zestaw. Postęp $_successPoints/$_requiredSuccesses, błędy $_mistakes/2.';
      }
    });
  }

  Future<void> _openFullscreenSession() {
    return Navigator.of(context).push<void>(
      _buildExerciseSessionRoute<void>(
        builder: (BuildContext context) {
          return FullscreenTrainerPage(
            title: 'Drabina Pamięci • Półka Słów',
            accent: widget.accent,
            child: WordShelfTrainer(accent: widget.accent, autoStart: true),
          );
        },
      ),
    );
  }

  Future<void> _handleStartAction() async {
    if (widget.fullscreenOnStart) {
      widget.onSessionStarted?.call();
      await _openFullscreenSession();
      return;
    }

    await _startGame();
  }

  @override
  void dispose() {
    _cancelRoundTimers();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        _hasSessionStarted
            ? _MemoryStatsRow(
                accent: widget.accent,
                points: '$_points',
                level: '$_wordCount',
              )
            : Container(
                width: double.infinity,
                padding: const EdgeInsets.all(18),
                decoration: BoxDecoration(
                  color: widget.accent.withValues(alpha: 0.1),
                  borderRadius: BorderRadius.circular(24),
                  border: Border.all(
                    color: widget.accent.withValues(alpha: 0.18),
                  ),
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: <Widget>[
                    Text(
                      _status,
                      style: theme.textTheme.titleMedium?.copyWith(
                        color: const Color(0xFF16212B),
                        fontWeight: FontWeight.w800,
                      ),
                    ),
                    const SizedBox(height: 8),
                    Text(
                      _phaseHint,
                      style: theme.textTheme.bodyMedium?.copyWith(
                        color: const Color(0xFF4A5761),
                        height: 1.5,
                      ),
                    ),
                  ],
                ),
              ),
        const SizedBox(height: 18),
        Container(
          width: double.infinity,
          constraints: const BoxConstraints(minHeight: 320),
          padding: const EdgeInsets.all(24),
          decoration: BoxDecoration(
            color: const Color(0xFFF9F5EF),
            borderRadius: BorderRadius.circular(26),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              Center(
                child: AnimatedSwitcher(
                  duration: const Duration(milliseconds: 220),
                  child: _isCountingDown
                      ? _MemoryCountdownDisplay(
                          label: _countdownLabel,
                          accent: widget.accent,
                          valueKeyPrefix: 'word-shelf-countdown',
                        )
                      : _showingWords
                      ? AnimatedOpacity(
                          key: const ValueKey<String>('word-shelf-prompt'),
                          opacity: _wordsFading ? 0 : 1,
                          duration: const Duration(milliseconds: 950),
                          child: Wrap(
                            alignment: WrapAlignment.center,
                            spacing: 12,
                            runSpacing: 12,
                            children: _currentWords.map((String word) {
                              return Container(
                                padding: const EdgeInsets.symmetric(
                                  horizontal: 16,
                                  vertical: 14,
                                ),
                                decoration: BoxDecoration(
                                  color: Colors.white,
                                  borderRadius: BorderRadius.circular(18),
                                  border: Border.all(
                                    color: widget.accent.withValues(
                                      alpha: 0.16,
                                    ),
                                  ),
                                ),
                                child: Text(
                                  word,
                                  style: theme.textTheme.titleMedium?.copyWith(
                                    color: const Color(0xFF16212B),
                                    fontWeight: FontWeight.w800,
                                  ),
                                ),
                              );
                            }).toList(),
                          ),
                        )
                      : _awaitingSelection
                      ? ConstrainedBox(
                          key: const ValueKey<String>('word-shelf-answer'),
                          constraints: const BoxConstraints(maxWidth: 480),
                          child: Column(
                            mainAxisSize: MainAxisSize.min,
                            children: <Widget>[
                              Wrap(
                                alignment: WrapAlignment.center,
                                spacing: 10,
                                runSpacing: 10,
                                children: _options.map((String word) {
                                  final selected = _selectedWords.contains(
                                    word,
                                  );
                                  return FilterChip(
                                    key: ValueKey<String>(
                                      'word-shelf-option-$word',
                                    ),
                                    label: Text(word),
                                    selected: selected,
                                    onSelected: (bool value) =>
                                        _toggleWord(word, value),
                                    selectedColor: widget.accent.withValues(
                                      alpha: 0.18,
                                    ),
                                    checkmarkColor: widget.accent,
                                    labelStyle: TextStyle(
                                      color: selected
                                          ? widget.accent
                                          : const Color(0xFF24303A),
                                      fontWeight: FontWeight.w800,
                                    ),
                                    side: BorderSide(
                                      color: selected
                                          ? widget.accent
                                          : const Color(0xFFD2D8DE),
                                    ),
                                  );
                                }).toList(),
                              ),
                            ],
                          ),
                        )
                      : _roundResolved
                      ? _MemoryRoundFeedbackBadge(
                          key: ValueKey<String>(
                            'word-shelf-feedback-${_lastAnswerCorrect ? 'ok' : 'fail'}',
                          ),
                          success: _lastAnswerCorrect,
                          successIcon: Icons.local_library_outlined,
                          failureIcon: Icons.replay_circle_filled_rounded,
                        )
                      : Column(
                          key: const ValueKey<String>('word-shelf-idle'),
                          mainAxisAlignment: MainAxisAlignment.center,
                          children: <Widget>[
                            Icon(
                              Icons.inventory_2_outlined,
                              size: 44,
                              color: widget.accent,
                            ),
                            const SizedBox(height: 12),
                            Text(
                              'Słowa pojawią się tylko na chwilę',
                              style: theme.textTheme.titleLarge?.copyWith(
                                color: const Color(0xFF16212B),
                                fontWeight: FontWeight.w900,
                              ),
                            ),
                          ],
                        ),
                ),
              ),
            ],
          ),
        ),
        const SizedBox(height: 18),
        SizedBox(
          width: double.infinity,
          child: switch ((
            _isCountingDown,
            _showingWords,
            _awaitingSelection,
            _roundResolved,
            _lastAnswerCorrect,
            _currentWords.isEmpty,
          )) {
            (true, _, _, _, _, _) => const SizedBox.shrink(),
            (_, true, _, _, _, _) => const SizedBox.shrink(),
            (_, _, true, _, _, _) => const SizedBox.shrink(),
            (_, _, _, true, true, _) => const SizedBox.shrink(),
            (_, _, _, true, false, _) => FilledButton(
              onPressed: _beginRound,
              child: const Text('Następna półka'),
            ),
            (_, _, _, _, _, true) => FilledButton(
              onPressed: _handleStartAction,
              child: const Text('Start sesji'),
            ),
            _ => FilledButton(
              onPressed: _beginRound,
              child: const Text('Nowa półka'),
            ),
          },
        ),
      ],
    );
  }
}

class MemoryChainTrainer extends StatefulWidget {
  const MemoryChainTrainer({
    super.key,
    required this.accent,
    this.autoStart = false,
    this.fullscreenOnStart = false,
    this.onSessionStarted,
  });

  final Color accent;
  final bool autoStart;
  final bool fullscreenOnStart;
  final VoidCallback? onSessionStarted;

  @override
  State<MemoryChainTrainer> createState() => _MemoryChainTrainerState();
}

class _MemoryChainTrainerState extends State<MemoryChainTrainer> {
  static const int _sessionStartCountdownSeconds = 3;

  final Random _random = Random();
  Timer? _startCountdownTimer;
  Timer? _tapFlashTimer;
  Timer? _roundAdvanceTimer;
  List<_DirectionStep> _sequence = <_DirectionStep>[];
  List<_DirectionStep> _input = <_DirectionStep>[];
  int _level = 1;
  int _bestLevel = 0;
  int _points = 0;
  bool _hasSessionStarted = false;
  bool _showingSequence = false;
  bool _awaitingInput = false;
  bool _roundCompleted = false;
  bool _gameOver = false;
  _DirectionStep? _highlighted;
  _DirectionStep? _pressedStep;
  int? _countdownValue;
  Color _pressedColor = const Color(0xFF4C9B8F);
  String _status = 'Naciśnij Start sesji i zapamiętaj sekwencję.';

  bool get _isCountingDown => _countdownValue != null;

  String get _countdownLabel {
    final value = _countdownValue;
    if (value == null) {
      return '';
    }
    return value == 0 ? 'Start' : '$value';
  }

  String get _phaseHint {
    if (_isCountingDown) {
      return 'Za chwilę zobaczysz sekwencję strzałek. Zapamiętaj ją i odtwórz bez pomyłki.';
    }
    if (_showingSequence) {
      return 'Patrz na podświetlenia i nie dotykaj planszy, dopóki pokaz się nie skończy.';
    }
    if (_awaitingInput) {
      return 'Klikaj strzałki dokładnie w tej kolejności, w jakiej zostały pokazane.';
    }
    if (_roundCompleted) {
      return 'Runda zaliczona. Zielone potwierdzenie zniknie i za chwilę wejdziesz poziom wyżej.';
    }
    if (_gameOver) {
      return 'Błędny ruch kończy rundę, więc zacznij od nowa i utrzymaj koncentrację.';
    }
    return 'Uruchom grę, obejrzyj układ i odtwórz go bez pośpiechu.';
  }

  @override
  void initState() {
    super.initState();
    if (widget.autoStart) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) {
          _startGame();
        }
      });
    }
  }

  Future<void> _startGame() async {
    if (_isCountingDown) {
      return;
    }

    widget.onSessionStarted?.call();
    _startCountdownTimer?.cancel();
    _tapFlashTimer?.cancel();
    _roundAdvanceTimer?.cancel();

    setState(() {
      _level = 1;
      _bestLevel = max(_bestLevel, 0);
      _points = 0;
      _hasSessionStarted = true;
      _sequence = <_DirectionStep>[];
      _input = <_DirectionStep>[];
      _showingSequence = false;
      _awaitingInput = false;
      _gameOver = false;
      _roundCompleted = false;
      _highlighted = null;
      _pressedStep = null;
      _countdownValue = _sessionStartCountdownSeconds;
      _status = 'Gra startuje za chwilę.';
    });

    HapticFeedback.selectionClick();

    _startCountdownTimer = Timer.periodic(const Duration(seconds: 1), (
      Timer timer,
    ) {
      if (!mounted) {
        timer.cancel();
        return;
      }

      final currentCountdown = _countdownValue;
      if (currentCountdown == null) {
        timer.cancel();
        return;
      }

      if (currentCountdown <= 0) {
        timer.cancel();
        setState(() {
          _countdownValue = null;
        });
        unawaited(_prepareRound());
        return;
      }

      setState(() {
        _countdownValue = currentCountdown - 1;
      });

      if (_countdownValue == 0) {
        HapticFeedback.mediumImpact();
      } else {
        HapticFeedback.selectionClick();
      }
    });
  }

  Future<void> _prepareRound() async {
    final sequenceLength = _level + 2;
    setState(() {
      _sequence = List<_DirectionStep>.generate(
        sequenceLength,
        (_) =>
            _DirectionStep.values[_random.nextInt(
              _DirectionStep.values.length,
            )],
      );
      _input = <_DirectionStep>[];
      _showingSequence = true;
      _awaitingInput = false;
      _roundCompleted = false;
      _highlighted = null;
      _pressedStep = null;
      _status = 'Patrz i zapamiętuj.';
    });

    await Future<void>.delayed(const Duration(milliseconds: 350));

    for (final step in _sequence) {
      if (!mounted) {
        return;
      }
      setState(() {
        _highlighted = step;
      });
      await Future<void>.delayed(const Duration(milliseconds: 520));
      if (!mounted) {
        return;
      }
      setState(() {
        _highlighted = null;
      });
      await Future<void>.delayed(const Duration(milliseconds: 180));
    }

    if (!mounted) {
      return;
    }

    setState(() {
      _showingSequence = false;
      _awaitingInput = true;
      _status = 'Odtwórz sekwencję w tej samej kolejności.';
    });
  }

  void _flashTap(_DirectionStep step, Color color) {
    _tapFlashTimer?.cancel();
    setState(() {
      _pressedStep = step;
      _pressedColor = color;
    });

    _tapFlashTimer = Timer(const Duration(milliseconds: 180), () {
      if (!mounted) {
        return;
      }
      setState(() {
        _pressedStep = null;
      });
    });
  }

  void _handleTap(_DirectionStep step) {
    if (!_awaitingInput || _showingSequence) {
      return;
    }

    final expected = _sequence[_input.length];
    if (step != expected) {
      _flashTap(step, _memoryFailureColor);
      HapticFeedback.lightImpact();
      setState(() {
        _awaitingInput = false;
        _gameOver = true;
        _roundCompleted = false;
        _bestLevel = max(_bestLevel, _level - 1);
        _status = 'Pomyłka. Spróbuj jeszcze raz od początku.';
      });
      return;
    }

    _flashTap(step, _memorySuccessColor);
    HapticFeedback.selectionClick();
    setState(() {
      _input = <_DirectionStep>[..._input, step];
    });

    if (_input.length == _sequence.length) {
      final earnedPoints = _level;
      HapticFeedback.mediumImpact();
      setState(() {
        _awaitingInput = false;
        _roundCompleted = true;
        _bestLevel = max(_bestLevel, _level);
        _points += earnedPoints;
        _status = 'Dobra runda. Za chwilę wejdziesz poziom wyżej.';
      });

      _roundAdvanceTimer = Timer(const Duration(seconds: 2), () {
        if (!mounted || _gameOver) {
          return;
        }
        unawaited(_nextLevel());
      });
    }
  }

  Future<void> _nextLevel() async {
    setState(() {
      _level += 1;
    });
    await _prepareRound();
  }

  Future<void> _openFullscreenSession() {
    return Navigator.of(context).push<void>(
      _buildExerciseSessionRoute<void>(
        builder: (BuildContext context) {
          return FullscreenTrainerPage(
            title: 'Drabina Pamięci',
            accent: widget.accent,
            child: MemoryChainTrainer(accent: widget.accent, autoStart: true),
          );
        },
      ),
    );
  }

  Future<void> _handleStartAction() async {
    if (widget.fullscreenOnStart) {
      widget.onSessionStarted?.call();
      await _openFullscreenSession();
      return;
    }

    await _startGame();
  }

  @override
  void dispose() {
    _startCountdownTimer?.cancel();
    _tapFlashTimer?.cancel();
    _roundAdvanceTimer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        _hasSessionStarted
            ? _MemoryStatsRow(
                accent: widget.accent,
                points: '$_points',
                level: '$_level',
              )
            : Container(
                width: double.infinity,
                padding: const EdgeInsets.all(18),
                decoration: BoxDecoration(
                  color: widget.accent.withValues(alpha: 0.1),
                  borderRadius: BorderRadius.circular(24),
                  border: Border.all(
                    color: widget.accent.withValues(alpha: 0.18),
                  ),
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: <Widget>[
                    Text(
                      _status,
                      style: theme.textTheme.titleMedium?.copyWith(
                        color: const Color(0xFF16212B),
                        fontWeight: FontWeight.w800,
                      ),
                    ),
                    const SizedBox(height: 8),
                    Text(
                      _phaseHint,
                      style: theme.textTheme.bodyMedium?.copyWith(
                        color: const Color(0xFF4A5761),
                        height: 1.5,
                      ),
                    ),
                  ],
                ),
              ),
        const SizedBox(height: 18),
        Container(
          width: double.infinity,
          constraints: const BoxConstraints(minHeight: 300),
          padding: const EdgeInsets.all(24),
          decoration: BoxDecoration(
            color: const Color(0xFFF9F5EF),
            borderRadius: BorderRadius.circular(26),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              Center(
                child: AnimatedSwitcher(
                  duration: const Duration(milliseconds: 220),
                  child: _isCountingDown
                      ? Column(
                          key: ValueKey<String>(
                            'memory-chain-countdown-$_countdownLabel',
                          ),
                          mainAxisAlignment: MainAxisAlignment.center,
                          children: <Widget>[
                            Text(
                              _countdownLabel,
                              style: theme.textTheme.displayMedium?.copyWith(
                                color: widget.accent,
                                fontWeight: FontWeight.w900,
                                letterSpacing: _countdownLabel == 'Start'
                                    ? 0.4
                                    : 0,
                              ),
                            ),
                          ],
                        )
                      : _roundCompleted
                      ? _MemoryRoundFeedbackBadge(
                          key: const ValueKey<String>(
                            'memory-chain-feedback-ok',
                          ),
                          success: true,
                          successIcon: Icons.verified_rounded,
                          failureIcon: Icons.refresh_rounded,
                        )
                      : _gameOver
                      ? _MemoryRoundFeedbackBadge(
                          key: const ValueKey<String>(
                            'memory-chain-feedback-fail',
                          ),
                          success: false,
                          successIcon: Icons.verified_rounded,
                          failureIcon: Icons.refresh_rounded,
                        )
                      : ConstrainedBox(
                          key: const ValueKey<String>('memory-chain-pad'),
                          constraints: const BoxConstraints(maxWidth: 280),
                          child: Column(
                            mainAxisAlignment: MainAxisAlignment.center,
                            children: <Widget>[
                              _DirectionPadButton(
                                step: _DirectionStep.up,
                                accent: widget.accent,
                                isHighlighted:
                                    _highlighted == _DirectionStep.up,
                                isPressed: _pressedStep == _DirectionStep.up,
                                pressedColor: _pressedColor,
                                enabled: _awaitingInput,
                                onTap: _handleTap,
                              ),
                              const SizedBox(height: 14),
                              Row(
                                mainAxisAlignment: MainAxisAlignment.center,
                                children: <Widget>[
                                  _DirectionPadButton(
                                    step: _DirectionStep.left,
                                    accent: widget.accent,
                                    isHighlighted:
                                        _highlighted == _DirectionStep.left,
                                    isPressed:
                                        _pressedStep == _DirectionStep.left,
                                    pressedColor: _pressedColor,
                                    enabled: _awaitingInput,
                                    onTap: _handleTap,
                                  ),
                                  const SizedBox(width: 14),
                                  _DirectionPadButton(
                                    step: _DirectionStep.right,
                                    accent: widget.accent,
                                    isHighlighted:
                                        _highlighted == _DirectionStep.right,
                                    isPressed:
                                        _pressedStep == _DirectionStep.right,
                                    pressedColor: _pressedColor,
                                    enabled: _awaitingInput,
                                    onTap: _handleTap,
                                  ),
                                ],
                              ),
                              const SizedBox(height: 14),
                              _DirectionPadButton(
                                step: _DirectionStep.down,
                                accent: widget.accent,
                                isHighlighted:
                                    _highlighted == _DirectionStep.down,
                                isPressed: _pressedStep == _DirectionStep.down,
                                pressedColor: _pressedColor,
                                enabled: _awaitingInput,
                                onTap: _handleTap,
                              ),
                            ],
                          ),
                        ),
                ),
              ),
            ],
          ),
        ),
        const SizedBox(height: 18),
        SizedBox(
          width: double.infinity,
          child: switch ((
            _isCountingDown,
            _roundCompleted,
            _showingSequence,
            _gameOver,
            _sequence.isEmpty,
          )) {
            (true, _, _, _, _) => const SizedBox.shrink(),
            (_, true, _, _, _) => const SizedBox.shrink(),
            (_, _, true, _, _) => const SizedBox.shrink(),
            (_, _, _, true, _) || (_, _, _, _, true) => FilledButton(
              onPressed: _handleStartAction,
              child: Text(_gameOver ? 'Zacznij od nowa' : 'Start sesji'),
            ),
            _ => const SizedBox.shrink(),
          },
        ),
      ],
    );
  }
}

enum _DirectionStep {
  up(Icons.keyboard_arrow_up_rounded, 'Góra'),
  left(Icons.keyboard_arrow_left_rounded, 'Lewo'),
  right(Icons.keyboard_arrow_right_rounded, 'Prawo'),
  down(Icons.keyboard_arrow_down_rounded, 'Dół');

  const _DirectionStep(this.icon, this.label);

  final IconData icon;
  final String label;
}

class _DirectionPadButton extends StatelessWidget {
  const _DirectionPadButton({
    required this.step,
    required this.accent,
    required this.isHighlighted,
    required this.isPressed,
    required this.pressedColor,
    required this.enabled,
    required this.onTap,
  });

  final _DirectionStep step;
  final Color accent;
  final bool isHighlighted;
  final bool isPressed;
  final Color pressedColor;
  final bool enabled;
  final ValueChanged<_DirectionStep> onTap;

  @override
  Widget build(BuildContext context) {
    final background = isPressed
        ? pressedColor
        : isHighlighted
        ? accent.withValues(alpha: 0.86)
        : enabled
        ? Colors.white
        : Colors.white.withValues(alpha: 0.58);

    final foreground = isPressed || isHighlighted
        ? Colors.white
        : const Color(0xFF16212B);

    return GestureDetector(
      onTap: enabled ? () => onTap(step) : null,
      child: AnimatedScale(
        duration: const Duration(milliseconds: 120),
        scale: isPressed ? 0.94 : 1,
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 180),
          width: 82,
          height: 82,
          decoration: BoxDecoration(
            color: background,
            borderRadius: BorderRadius.circular(24),
            boxShadow: <BoxShadow>[
              BoxShadow(
                color: Colors.black.withValues(alpha: 0.06),
                blurRadius: 18,
                offset: const Offset(0, 8),
              ),
            ],
          ),
          child: Icon(step.icon, color: foreground, size: 40),
        ),
      ),
    );
  }
}

class StatStrip extends StatelessWidget {
  const StatStrip({
    super.key,
    required this.label,
    required this.value,
    required this.tint,
  });

  final String label;
  final String value;
  final Color tint;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final palette = context.appPalette;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 16),
      decoration: BoxDecoration(
        color: palette.surface.withValues(alpha: 0.92),
        borderRadius: BorderRadius.circular(20),
        border: Border.all(color: tint.withValues(alpha: 0.2)),
        boxShadow: <BoxShadow>[
          BoxShadow(
            color: palette.shadowColor.withValues(alpha: 0.45),
            blurRadius: 16,
            offset: const Offset(0, 6),
          ),
        ],
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          SizedBox(
            width: double.infinity,
            child: FittedBox(
              fit: BoxFit.scaleDown,
              alignment: Alignment.centerLeft,
              child: Text(
                label.toUpperCase(),
                maxLines: 1,
                softWrap: false,
                style: theme.textTheme.labelLarge?.copyWith(
                  color: tint,
                  fontWeight: FontWeight.w800,
                  letterSpacing: 1.0,
                ),
              ),
            ),
          ),
          const SizedBox(height: 6),
          SizedBox(
            width: double.infinity,
            child: FittedBox(
              fit: BoxFit.scaleDown,
              alignment: Alignment.centerLeft,
              child: Text(
                value,
                maxLines: 1,
                softWrap: false,
                style: theme.textTheme.titleMedium?.copyWith(
                  color: palette.primaryText,
                  fontWeight: FontWeight.w800,
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

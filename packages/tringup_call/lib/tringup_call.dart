/// TringupCall — drop-in call package for Flutter chat apps.
///
/// Usage:
/// ```dart
/// TringupCallWidget(
///   config: TringupCallConfig(
///     serverUrl:   'https://call.example.com',
///     tenantId:    'your-tenant-id',
///     token:       callJwtFromYourBackend,
///     userId:      currentUser.id,
///     phoneNumber: currentUser.phone,
///   ),
///   controller: TringupCallController(),
///   child: YourChatApp(),
/// )
/// ```
library tringup_call;

export 'src/conference_call_screen.dart';
export 'src/conference_video_grid.dart';
export 'src/tringup_call_config.dart';
export 'src/tringup_call_theme.dart';
export 'src/tringup_call_contact.dart';
export 'src/tringup_call_controller.dart';
export 'src/tringup_call_history.dart';
export 'src/tringup_call_overlay.dart';
export 'src/tringup_call_pull.dart';
export 'src/tringup_call_screen_api.dart';
export 'src/tringup_call_widget.dart';
export 'src/tringup_call_shell.dart';
export 'src/tringup_call_background_handler.dart';
export 'src/tringup_audio_call_banner.dart';
export 'src/pip/tringup_pip_manager.dart';
export 'package:webtrit_callkeep/webtrit_callkeep.dart'
    show CallkeepPushNotificationSyncStatus, CallKeepPushNotificationSyncStatusHandle;
export 'src/tringup_call_status.dart';
export 'src/tringup_call_status_stream.dart';
export 'src/tringup_call_diagnostics.dart';

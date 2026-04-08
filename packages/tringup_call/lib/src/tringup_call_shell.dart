import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:livekit_client/livekit_client.dart' as lk;
import 'package:webtrit_callkeep/webtrit_callkeep.dart';
import 'package:webtrit_phone/extensions/extensions.dart';
import 'package:webtrit_phone/features/call/call.dart';
import 'package:webtrit_phone/features/call/view/call_active_thumbnail.dart';
import 'package:webtrit_phone/models/models.dart';
import 'package:webtrit_phone/utils/view_params/presence_view_params.dart';
import 'package:webtrit_phone/widgets/widgets.dart';

// conference_call_screen.dart removed — all calls use TringupDefaultCallScreen
import 'default_call_screen.dart';
import 'pip/tringup_pip_manager.dart';
import 'tringup_call_config.dart';
import 'tringup_call_diagnostics.dart';
import 'tringup_call_screen_api.dart';
import 'tringup_call_theme.dart';
import 'tringup_call_status.dart';
import 'tringup_call_status_stream.dart';
const _tag = '[TringupCallShell]';

/// Replaces the auto_route–based [CallShell] for the package context.
///
/// Listens to [CallBloc] state changes and:
/// - Shows a full-screen call screen as an [Overlay] entry when
///   [CallDisplay.screen] is active (no router required).
/// - Shows a draggable thumbnail overlay when [CallDisplay.overlay] is active.
/// - Manages native PiP lifecycle via [TringupPiPManager] for video calls.
/// - Cleans up all overlays when the call ends.
class TringupCallShell extends StatefulWidget {
  const TringupCallShell({
    super.key,
    this.stickyPadding = const EdgeInsets.symmetric(horizontal: kMinInteractiveDimension / 4),
    required this.child,
    this.overlayKey,
    this.callScreenBuilder,
    this.callTheme,
    this.onCallEnded,
    this.onCallEndedWithCDR,
    this.participantsProvider,
    this.contactInfoProvider,
    this.localUserProvider,
    this.chatIdResolver,
    this.nameResolver,
    this.photoPathResolver,
  });

  final EdgeInsets stickyPadding;
  final Widget child;

  /// When provided, overlay entries are inserted into this key's [OverlayState]
  /// instead of using [Overlay.of(context)]. Required when [TringupCallShell]
  /// is placed above a [MaterialApp] (where the Navigator's Overlay is a
  /// descendant, not an ancestor).
  final GlobalKey<OverlayState>? overlayKey;

  /// Optional custom call-screen builder.
  final TringupCallScreenBuilder? callScreenBuilder;

  /// Optional theme applied to the built-in [CallActiveScaffold].
  final TringupCallTheme? callTheme;

  /// Called once after every call ends and all call-UI overlays have been
  /// removed from the screen.
  ///
  /// Use this to restore any system-level UI state that the call screen may
  /// have overridden — most commonly [SystemChrome.setSystemUIOverlayStyle]:
  ///
  /// ```dart
  /// TringupCallShell(
  ///   onCallEnded: () {
  ///     SystemChrome.setSystemUIOverlayStyle(const SystemUiOverlayStyle(
  ///       statusBarColor: Colors.transparent,
  ///       statusBarIconBrightness: Brightness.dark,
  ///     ));
  ///   },
  ///   child: ...,
  /// )
  /// ```
  final VoidCallback? onCallEnded;

  /// Called immediately when any call ends, providing a [TringupCallCDR] with
  /// the full call record.  Use this to display the call in chat history or
  /// to save a CDR to a remote server.
  ///
  /// Fired before [onCallEnded].
  final void Function(TringupCallCDR cdr)? onCallEndedWithCDR;

  /// Optional provider for the current user's own phone number.
  /// Used to correctly identify "self" in the group members panel when the
  /// local user's entry in `conferenceParticipants` is keyed by phone number
  /// rather than by the LiveKit server identity.
  ///
  /// Example:
  /// ```dart
  /// localUserProvider: () => AuthService.instance.currentUserPhone,
  /// ```
  final String? Function()? localUserProvider;

  /// Optional resolver that maps a [callId] to the host-app chat thread ID.
  ///
  /// Called by [TringupCallStatusStream] when [ActiveCall.chatId] is null —
  /// which happens for outgoing 1:1 calls because [CallControlEvent.started]
  /// does not carry a chatId in the signalling layer.
  ///
  /// Should return `getChatIdForCall(callId) ?? pendingChatId` so that the
  /// stream always has the correct chatId even at the very first state change
  /// (before the pending mapping has been persisted):
  ///
  /// ```dart
  /// chatIdResolver: (callId) {
  ///   final ctrl = Get.find<TringupCallGetxController>();
  ///   return ctrl.getChatIdForCall(callId) ?? ctrl.pendingChatId;
  /// },
  /// ```
  final String? Function(String callId)? chatIdResolver;

  /// Optional async resolver for a contact's display name by phone number.
  /// Passed through to [TringupDefaultCallScreen] for on-demand name lookup.
  final TringupNameResolver? nameResolver;

  /// Optional async resolver for a contact's photo file path by phone number.
  /// Passed through to [TringupDefaultCallScreen] for on-demand photo lookup.
  final TringupPhotoPathResolver? photoPathResolver;

  /// Optional provider for the list of participants that can be added to the
  /// active call.  Receives the current [callId] and returns a list of
  /// [TringupParticipant]s (e.g. the other members of the linked chat).
  ///
  /// If omitted, [TringupCallInfo.addableParticipants] will be empty and the
  /// default call screen will show an empty list when "Add" is tapped.
  final Future<List<TringupParticipant>> Function(String callId)? participantsProvider;

  /// Optional synchronous provider for the remote party's contact info
  /// (display name and profile photo).
  ///
  /// Called for every active call with the remote phone number.  Return the
  /// host-app contact's [displayName], [photoPath] (local file, preferred),
  /// and/or [photoUrl] (network URL).  All fields are optional — supply only
  /// what is available.
  ///
  /// When [displayName] is non-empty it overrides the server-provided name in
  /// both the call-screen UI and the native CallKeep notification.
  ///
  /// Example (host app wiring):
  /// ```dart
  /// contactInfoProvider: (phone) {
  ///   final c = ContactsDataService.instance.getContactByPhone(phone);
  ///   return (displayName: c?.name, photoPath: c?.photoPath, photoUrl: c?.photoUrl);
  /// },
  /// ```
  final ({String? displayName, String? photoPath, String? photoUrl})
      Function(String phoneNumber)? contactInfoProvider;

  @override
  State<TringupCallShell> createState() => _TringupCallShellState();
}

class _TringupCallShellState extends State<TringupCallShell>
    with WidgetsBindingObserver {
  OverlayEntry? _callScreenEntry;
  _ThumbnailOverlay? _thumbnail;

  // Controls call-screen overlay visibility WITHOUT removing it from the
  // Overlay — so RTCVideoRenderers are never torn down during in-app PiP.
  final _callScreenVisible = ValueNotifier<bool>(true);

  // Controls thumbnail overlay visibility WITHOUT removing it from the
  // Overlay — mirrors the same pattern as _callScreenVisible.  The thumbnail
  // is pre-inserted (hidden) while still on the full-screen call so that
  // lk.VideoTrackRenderer initialises in the background; on the first minimize
  // we just flip this to true — no native texture creation delay.
  final _thumbnailVisible = ValueNotifier<bool>(false);

  // Tracks the active LiveKit room so the thumbnail OverlayEntry can react
  // to room-connect events instantly (without waiting for a BLoC emission).
  // Updated by _videoPiPListener the moment getLiveKitRoom returns non-null.
  final _thumbnailLkRoom = ValueNotifier<lk.Room?>(null);

  // Snapshot of the previous active-calls list, used by the CDR listener to
  // identify which calls have just ended.
  List<ActiveCall> _prevActiveCalls = const [];

  // ── Native PiP ────────────────────────────────────────────────────────────
  final _pip             = TringupPiPManager();
  bool  _videoCallActive = false;
  String? _remoteStreamId;
  StreamSubscription<bool>? _pipNativeSub;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _pip.checkSupport();
    // Subscribe to native PiP mode changes once, for the lifetime of the shell.
    // The subscription survives across successive calls because TringupPiPManager
    // no longer closes its broadcast controller between calls.
    _pipNativeSub = _pip.pipModeStream.listen(_onNativePiPChanged);
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _pipNativeSub?.cancel();
    _pipNativeSub = null;
    _callScreenVisible.dispose();
    _thumbnailVisible.dispose();
    _thumbnailLkRoom.dispose();
    _pip.dispose();
    _removeCallScreen();
    _removeThumbnail();
    super.dispose();
  }

  /// Called by the OS when the app lifecycle changes.
  /// On iOS we explicitly request PiP when the app goes inactive during a
  /// video call. On Android the native [onUserLeaveHint] handles it.
  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (_videoCallActive && state == AppLifecycleState.inactive) {
      // Pre-show the call screen so the OS PiP snapshot captures a real video
      // frame instead of a blank frame (which happens when the call screen is
      // Offstaged during overlay/thumbnail mode).
      if (_callScreenEntry != null) _callScreenVisible.value = true;
      if (Platform.isIOS) _pip.enterPiP();
    }
    if (state == AppLifecycleState.resumed) {
      if (_pip.isInPiP) _pip.exitPiP();
      // Restore the correct visibility state after returning from background.
      // If we were in overlay mode and pre-showed the call screen on inactive,
      // we need to hide it again and re-show the thumbnail.
      if (_callScreenEntry != null && !_pip.isInPiP) {
        final display = context.read<CallBloc>().state.display;
        if (display == CallDisplay.overlay) {
          _callScreenVisible.value = false;
          if (_thumbnail != null) _thumbnailVisible.value = true;
        }
      }
    }
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (kDebugMode) {
      try {
        final bloc = context.read<CallBloc>();
        debugPrint('$_tag didChangeDependencies — CallBloc found: $bloc '
            'display=${bloc.state.display} status=${bloc.state.status}');
      } catch (e) {
        debugPrint('$_tag didChangeDependencies — CallBloc NOT FOUND in context: $e');
      }
      final overlay = Overlay.maybeOf(context);
      debugPrint('$_tag didChangeDependencies — Overlay: ${overlay != null ? "FOUND" : "NOT FOUND"}');
    }
  }

  @override
  Widget build(BuildContext context) {
    if (kDebugMode) debugPrint('$_tag build');
    return MultiBlocListener(
      listeners: [
        // Log EVERY state change for debugging + update diagnostics.
        BlocListener<CallBloc, CallState>(
          listener: (context, state) {
            final svc = state.callServiceState;
            // ignore: avoid_print
            print('$_tag [STATE] display=${state.display} '
                'status=${state.status} '
                'signalingStatus=${svc.signalingClientStatus} '
                'handshake=${state.isHandshakeEstablished} '
                'lines=${state.linesCount} '
                'activeCalls=${state.activeCalls.length} '
                'registration=${svc.registration?.status}');
            final err = svc.lastSignalingClientDisconnectError;
            if (err != null) {
              // ignore: avoid_print
              print('$_tag [SIGNALING ERROR] $err');
            }

            // Feed live status into TringupCallDiagnostics for host-app inspection.
            TringupCallDiagnostics.instance.updateFromShell(
              TringupCallDiagnosticsStatus(
                isSignalingConnected: state.isSignalingEstablished,
                isUserRegistered:
                    svc.registration?.status?.isRegistered == true,
                signalingStatusLabel:
                    _signalingLabel(svc.signalingClientStatus),
                registrationStatusLabel:
                    _registrationLabel(svc.registration?.status),
                callTokenPresent:
                    TringupCallDiagnostics.instance.status.callTokenPresent,
              ),
            );
          },
        ),
        if (kDebugMode)
          BlocListener<CallBloc, CallState>(
            listenWhen: (prev, curr) => prev.activeCalls.length != curr.activeCalls.length,
            listener: (context, state) {
              final summary = state.activeCalls.map((c) {
                final id = c.callId.substring(0, c.callId.length.clamp(0, 8));
                final dir = c.isIncoming ? 'IN' : 'OUT';
                return '$id dir=$dir accepted=${c.wasAccepted}';
              }).toList();
              debugPrint('$_tag [ACTIVE CALLS] count=${state.activeCalls.length} calls=$summary');
            },
          ),
        _callDisplayListener(),
        _lockscreenListener(),
        _videoPiPListener(),
        _cdrListener(), // always needed — also pushes ended to TringupCallStatusStream
        _statusListener(),
      ],
      child: widget.child,
    );
  }

  // -------------------------------------------------------------------------
  // Native PiP mode handler
  // -------------------------------------------------------------------------

  /// Called by [TringupPiPManager] when the OS enters or exits native PiP.
  ///
  /// **Entering PiP** (`inPiP = true`):
  ///   - Make the call-screen overlay visible (even if it was hidden during
  ///     in-app overlay mode) so the OS captures only the video UI, not the
  ///     chat page + thumbnail.
  ///   - Temporarily hide the draggable thumbnail (it would look wrong inside
  ///     the small native PiP window) while keeping its [_ThumbnailOverlay]
  ///     object alive so it can be re-inserted when PiP exits.
  ///
  /// **Exiting PiP** (`inPiP = false`):
  ///   - If the BloC is still in [CallDisplay.overlay] mode, restore the
  ///     previous in-app PiP state: hide the call screen and re-insert the
  ///     thumbnail.
  ///   - If the BloC is in [CallDisplay.screen], leave the call screen visible
  ///     (the user tapped the PiP window to return to full screen).
  void _onNativePiPChanged(bool inPiP) {
    if (!mounted) return;
    if (inPiP) {
      // Show video-only call screen before the OS snapshots the PiP frame.
      if (_callScreenEntry != null) {
        _callScreenVisible.value = true;
      }
      // Hide thumbnail while native PiP is active so it doesn't appear in
      // the OS PiP snapshot.  The overlay entry stays in the tree so the
      // VideoTrackRenderer remains warm.
      _thumbnailVisible.value = false;
    } else {
      // Native PiP exited — restore the state that was active before PiP.
      final display = context.read<CallBloc>().state.display;
      if (display == CallDisplay.overlay && _callScreenEntry != null) {
        // We were in video overlay mode: hide call screen again and
        // re-show the video thumbnail.
        _callScreenVisible.value = false;
        if (_thumbnail != null) _thumbnailVisible.value = true;
      }
      // If display == CallDisplay.screen the call screen is already visible;
      // nothing to restore.
    }
  }

  // -------------------------------------------------------------------------
  // Listeners
  // -------------------------------------------------------------------------

  BlocListener<CallBloc, CallState> _callDisplayListener() {
    return BlocListener<CallBloc, CallState>(
      listenWhen: (prev, curr) => prev.display != curr.display,
      listener: (context, state) {
        if (kDebugMode) {
          debugPrint('$_tag CallDisplay changed → ${state.display} '
              'status=${state.status} '
              'signalingEstablished=${state.isSignalingEstablished}');
        }
        final callBloc = context.read<CallBloc>();

        switch (state.display) {
          case CallDisplay.screen:
            // Hide the thumbnail but keep it in the overlay tree — the
            // VideoTrackRenderer stays warm so the next minimize is instant.
            _thumbnailVisible.value = false;
            if (_callScreenEntry == null) {
              // ignore: avoid_print
              print('$_tag inserting full-screen call overlay');
              _showCallScreen(context, callBloc);
              // Pre-insert the thumbnail now (hidden) so its VideoTrackRenderer
              // finishes initialising in the background.  When the user first
              // presses minimize we just flip _thumbnailVisible → no delay.
              final isVideo = state.activeCalls.isNotEmpty &&
                  state.activeCalls.current.video;
              // ignore: avoid_print
              print('$_tag [THUMB] screen→new: isVideo=$isVideo thumbnail=${_thumbnail != null ? "exists" : "null"}');
              if (isVideo) {
                if (kDebugMode) debugPrint('$_tag pre-warming thumbnail overlay');
                _showThumbnail(context, state);
              }
            } else {
              // Overlay already exists — just make it visible + interactive.
              // Renderers were kept alive; no teardown occurred.
              // ignore: avoid_print
              print('$_tag restoring full-screen call overlay (was hidden)');
              _callScreenVisible.value = true;
            }

          case CallDisplay.overlay:
            // HIDE the call screen overlay instead of removing it.
            // This keeps the RTCVideoRenderers alive so video continues
            // without a black-frame rebuild when returning to full screen.
            if (_callScreenEntry != null) {
              _callScreenVisible.value = false;
              if (kDebugMode) debugPrint('$_tag hiding call screen (in-app PiP)');
            }

            final isVideo = state.activeCalls.isNotEmpty &&
                state.activeCalls.current.video;
            // ignore: avoid_print
            print('$_tag [THUMB] overlay: isVideo=$isVideo thumbnail=${_thumbnail != null ? "exists" : "null"} thumbnailVisible=${_thumbnailVisible.value}');

            if (isVideo) {
              // Insert thumbnail if not yet in the tree (cold path: call
              // started as audio then camera turned on).
              if (_thumbnail == null) {
                if (kDebugMode) debugPrint('$_tag inserting video thumbnail overlay (cold)');
                _showThumbnail(context, state);
              }
              // Reveal the (pre-warmed) thumbnail — instant, no renderer init.
              // ignore: avoid_print
              print('$_tag [THUMB] setting thumbnailVisible=true');
              _thumbnailVisible.value = true;
            }
            // Audio call → no overlay inserted by the shell.
            // The host app places [TringupAudioCallBanner] wherever it wants
            // in its own widget tree; that widget reacts to CallBloc state.

          case CallDisplay.noneScreen:
          case CallDisplay.none:
            if (kDebugMode) debugPrint('$_tag removing all overlays (display=${state.display})');
            _removeCallScreen();
            _removeThumbnail();
            widget.onCallEnded?.call();
        }
      },
    );
  }

  BlocListener<CallBloc, CallState> _lockscreenListener() {
    return BlocListener<CallBloc, CallState>(
      listenWhen: (prev, curr) =>
          prev.display != curr.display &&
          (prev.display == CallDisplay.screen || curr.display == CallDisplay.screen),
      listener: (context, state) {
        final isCallScreen = state.display == CallDisplay.screen;
        if (isCallScreen) {
          AndroidCallkeepUtils.activityControl.showOverLockscreen();
          AndroidCallkeepUtils.activityControl.wakeScreenOnShow();
        } else {
          AndroidCallkeepUtils.activityControl.showOverLockscreen(false);
          AndroidCallkeepUtils.activityControl.wakeScreenOnShow(false);
        }
      },
    );
  }

  /// Tracks the remote video stream and arms/tears-down native PiP accordingly.
  BlocListener<CallBloc, CallState> _videoPiPListener() {
    return BlocListener<CallBloc, CallState>(
      listenWhen: (prev, curr) {
        final p = prev.activeCalls.isEmpty ? null : prev.activeCalls.current;
        final c = curr.activeCalls.isEmpty ? null : curr.activeCalls.current;
        return prev.activeCalls.length != curr.activeCalls.length
            || p?.video != c?.video
            || p?.callId != c?.callId
            || p?.remoteStream?.id != c?.remoteStream?.id
            || p?.wasAccepted != c?.wasAccepted
            || p?.frontCamera != c?.frontCamera
            || p?.processingStatus != c?.processingStatus;
      },
      listener: (context, state) async {
        if (state.activeCalls.isEmpty) {
          // Call ended — tear down PiP and reset the thumbnail room notifier.
          _videoCallActive = false;
          _remoteStreamId  = null;
          _thumbnailLkRoom.value = null;
          await _pip.dispose();
          // Re-check support so the next call can use PiP again.
          await _pip.checkSupport();
          return;
        }

        final activeCall = state.activeCalls.current;

        // For LiveKit calls there is no remoteStream — use callId as the
        // stream identifier so native PiP can still be set up.
        final lkRoom = context.read<CallBloc>().getLiveKitRoom(activeCall.callId);

        // Push the LiveKit room to the thumbnail notifier the moment it becomes
        // available.  The pre-warmed thumbnail OverlayEntry uses this notifier
        // to swap in _LkVideoThumbnail (with real VideoTrackRenderer) while
        // still hidden (Opacity=0), so the first minimize is instant.
        if (lkRoom != null && _thumbnailLkRoom.value != lkRoom) {
          _thumbnailLkRoom.value = lkRoom;
          // ignore: avoid_print
          print('$_tag [THUMB] _thumbnailLkRoom updated → lkRoom present (remotes=${lkRoom.remoteParticipants.length})');
        }

        final streamId = activeCall.remoteStream?.id ??
            (lkRoom != null && activeCall.video && activeCall.wasAccepted
                ? activeCall.callId
                : null);

        if (!activeCall.video || streamId == null) {
          _videoCallActive = false;
          return;
        }

        // Video call active with a remote stream (or LiveKit room) — arm PiP.
        if (!_videoCallActive || streamId != _remoteStreamId) {
          _videoCallActive = true;
          _remoteStreamId  = streamId;
          await _pip.setup(
            remoteStreamId: streamId,
            aspectRatioX: 9,
            aspectRatioY: 16,
          );
          debugPrint('$_tag PiP armed for streamId=$streamId (livekit=${lkRoom != null})');
        }
      },
    );
  }

  // -------------------------------------------------------------------------
  // CDR listener — fires when a call disappears from activeCalls
  // -------------------------------------------------------------------------

  BlocListener<CallBloc, CallState> _cdrListener() {
    return BlocListener<CallBloc, CallState>(
      // Fire when call count changes (call ended) OR when any call's
      // acceptedTime transitions null→non-null, so _prevActiveCalls always
      // carries the most recent acceptedTime before the call is removed.
        listenWhen: (prev, curr) {
          if (prev.activeCalls.length != curr.activeCalls.length) return true;
          if (curr.activeCalls.isEmpty) return false;
          final p = prev.activeCalls.current;
          final c = curr.activeCalls.current;
          return p.callId                          != c.callId                          ||
              p.processingStatus               != c.processingStatus               ||
              p.acceptedTime                   != c.acceptedTime                   ||
              p.chatId                         != c.chatId                         ||
              p.groupName                      != c.groupName                      || // NEW
              p.conferenceParticipants.length  != c.conferenceParticipants.length;    // NEW
        },
      listener: (context, state) {
        final onCdr = widget.onCallEndedWithCDR;
        final currIds = state.activeCalls.map((c) => c.callId).toSet();

        for (final ended in _prevActiveCalls) {
          if (!currIds.contains(ended.callId)) {
            // Resolve chatId: set directly for group/incoming calls; for
            // outgoing 1:1 calls fall back to chatIdResolver which checks
            // getChatIdForCall AND pendingChatId.
            final resolvedChatId = ended.chatId ??
                widget.chatIdResolver?.call(ended.callId) ??
                '';

            final cdr = TringupCallCDR(
              callId:      ended.callId,
              number:      ended.handle.value,
              displayName: ended.displayName,
              callerId: ended.fromNumber ??
                  (ended.isIncoming
                      ? ended.handle.value
                      : widget.localUserProvider?.call()),
              chatId:      resolvedChatId.isEmpty ? null : resolvedChatId,
              groupName:   ended.groupName,
              participants: ended.conferenceParticipants
                  .map((cp) => TringupParticipant(
                        userId:      cp.userId,
                        displayName: cp.displayName,
                      ))
                  .toList(),
              createdAt:   ended.createdTime,
              connectedAt: ended.acceptedTime,
              endedAt:     ended.hungUpTime ?? DateTime.now(),
              isIncoming:  ended.isIncoming,
              isVideo:     ended.video,
              endReason:   _resolveEndReason(ended),
            );

            onCdr?.call(cdr);

            // Push ended snapshot to TringupCallStatusStream so any
            // subscriber (e.g. a chat screen) can show "Call ended / Rejoin".
            TringupCallStatusStream.instance.push(TringupCallStatus(
              chatId:      resolvedChatId,
              phase:       TringupCallPhase.ended,
              callId:      ended.callId,
              remoteNumber: ended.handle.value,
              displayName: ended.displayName,
              isGroupCall: ended.groupName != null,
              groupName:   ended.groupName,
              connectedAt: ended.acceptedTime,
              endedCdr:    cdr,
            ));
          }
        }

        _prevActiveCalls = state.activeCalls.toList();
      },
    );
  }

  /// Feeds [TringupCallStatusStream] on every meaningful call-state transition.
  BlocListener<CallBloc, CallState> _statusListener() {
    return BlocListener<CallBloc, CallState>(
      listenWhen: (prev, curr) {
        // Call count changed (start / end)
        if (prev.activeCalls.length != curr.activeCalls.length) return true;
        if (curr.activeCalls.isEmpty) return false;
        // Any phase-relevant field changed on the current call
        final p = prev.activeCalls.current;
        final c = curr.activeCalls.current;
        return p.callId            != c.callId            ||
            p.processingStatus  != c.processingStatus  ||
            p.acceptedTime      != c.acceptedTime      ||
            p.chatId            != c.chatId;
      },
      listener: (context, state) {
        final stream = TringupCallStatusStream.instance;
        //print('TTTTTTTTTTTTTT${state.status}');
        if (state.activeCalls.isEmpty) {
          // No active call — nothing to push; CDR listener handles the
          // 'ended' snapshot when the count drops.
          return;
        }

        final call = state.activeCalls.current;
        // call.chatId is set for group calls; for outgoing 1:1 calls it is null
        // so fall back to chatIdResolver.  At the moment this listener fires
        // (before _pendingChatIdSub has run), getChatIdForCall returns null but
        // pendingChatId is still set — so the resolver must check both.
        final chatId = call.chatId ??
            widget.chatIdResolver?.call(call.callId) ??
            '';
        stream.push(TringupCallStatus(
          chatId:       chatId,
          phase:        _mapPhase(call),
          callId:       call.callId,
          remoteNumber: call.handle.value,
          displayName:  call.displayName,
          isGroupCall:  call.groupName != null,
          groupName:    call.groupName,
          connectedAt:  call.acceptedTime,
        ));
      },
    );
  }


  String _resolveEndReason(ActiveCall call) {
    if (call.wasAccepted) return 'normal_clearing';
    if (call.wasHungUp && !call.isIncoming) return 'cancelled';
    return call.isIncoming ? 'missed' : 'no_answer';
  }

  // -------------------------------------------------------------------------
  // Call screen overlay (full-screen)
  // -------------------------------------------------------------------------

  void _showCallScreen(BuildContext context, CallBloc callBloc) {
    final overlay = widget.overlayKey?.currentState ?? Overlay.maybeOf(context);
    if (kDebugMode) {
      debugPrint('$_tag _showCallScreen — overlayKey=${widget.overlayKey?.currentState != null ? "FOUND" : "NULL"} '
          'Overlay.maybeOf=${Overlay.maybeOf(context) != null ? "FOUND" : "NULL"} '
          'using=${overlay != null ? "OK" : "NONE ← PROBLEM"}');
    }
    if (overlay == null) {
      // ignore: avoid_print
      print('$_tag _showCallScreen ERROR — no Overlay found!');
      return;
    }
    // ignore: avoid_print
    print('$_tag _showCallScreen — using overlay=$overlay');
    final customBuilder = widget.callScreenBuilder;
    _callScreenVisible.value = true;
    final entry = OverlayEntry(
      builder: (entryCtx) {
        // ValueListenableBuilder rebuilds only the thin Offstage+IgnorePointer
        // wrapper when visibility changes.  The heavy child (BlocProvider +
        // _CallScreenOverlayContent) is passed as `child` so it is NOT rebuilt
        // on visibility changes — RTCVideoRenderers survive in-app PiP transitions.
        return ValueListenableBuilder<bool>(
          valueListenable: _callScreenVisible,
          builder: (_, visible, child) => IgnorePointer(
            ignoring: !visible,
            child: Offstage(offstage: !visible, child: child),
          ),
          child: BlocProvider<CallBloc>.value(
            value: callBloc,
            child: _CallScreenOverlayContent(
              callBloc:             callBloc,
              onMinimise:           () => callBloc.add(const CallScreenEvent.didPop()),
              customBuilder:        customBuilder,
              callTheme:            widget.callTheme,
              pipManager:           _pip,
              participantsProvider: widget.participantsProvider,
              contactInfoProvider:  widget.contactInfoProvider,
              localUserProvider:    widget.localUserProvider,
              nameResolver:         widget.nameResolver,
              photoPathResolver:    widget.photoPathResolver,
            ),
          ),
        );
      },
    );
    _callScreenEntry = entry;
    overlay.insert(entry);
    if (kDebugMode) debugPrint('$_tag _showCallScreen — OverlayEntry inserted');
    // Initialise _prevActiveCalls so the CDR listener has a baseline.
    _prevActiveCalls = callBloc.state.activeCalls.toList();
  }

  void _removeCallScreen() {
    if (_callScreenEntry == null) return;
    if (kDebugMode) debugPrint('$_tag _removeCallScreen');
    _callScreenEntry!.remove();
    _callScreenEntry = null;
    // Immediately reset the system-UI style.
    //
    // The call screen applied SystemUiOverlayStyle.light which sets
    // statusBarIconBrightness = Brightness.light (WHITE icons).  Without an
    // explicit reset those white icons persist on the host app's light-
    // background screens, making the status bar appear invisible until a hot-
    // reload forces a full AnnotatedRegion re-evaluation.
    //
    // We reset to dark icons (the safe default for light-theme apps).  If the
    // host app uses a dark theme it should override this via [onCallEnded].
    SystemChrome.setSystemUIOverlayStyle(const SystemUiOverlayStyle(
      statusBarColor:            Colors.transparent,
      statusBarIconBrightness:   Brightness.dark,  // Android: dark icons
      statusBarBrightness:       Brightness.light, // iOS: light bg → dark icons
    ));
    // _callScreenVisible is intentionally NOT reset here.
    // _showCallScreen() sets it to true at the start of the next call,
    // which is the earliest safe point.  Resetting it here would briefly
    // un-offstage the call screen widget during its removal frame, which
    // could re-apply SystemUiOverlayStyle.light for one frame.
  }

  // -------------------------------------------------------------------------
  // Thumbnail overlay (draggable minimised state)
  // -------------------------------------------------------------------------

  void _showThumbnail(BuildContext context, CallState state) {
    final callBloc = context.read<CallBloc>();
    // Obtain the LiveKit room so the thumbnail can render live video tracks
    // without rebinding streams.  Null for legacy (non-LiveKit) calls.
    final lkRoom = state.activeCalls.isNotEmpty
        ? callBloc.getLiveKitRoom(state.activeCalls.current.callId)
        : null;
    final callId = state.activeCalls.isNotEmpty ? state.activeCalls.current.callId : 'none';
    // ignore: avoid_print
    print('$_tag [THUMB] _showThumbnail callId=$callId lkRoom=${lkRoom != null ? "present(remotes=${lkRoom.remoteParticipants.length})" : "NULL"} thumbnailVisible=${_thumbnailVisible.value}');
    final thumbnail = _ThumbnailOverlay(
      stickyPadding: widget.stickyPadding,
      lkRoom: lkRoom,
      lkRoomNotifier: _thumbnailLkRoom,
      visibilityNotifier: _thumbnailVisible,
      onTap: () {
        if (state.activeCalls.isNotEmpty) {
          callBloc.add(const CallScreenEvent.didPush());
        }
      },
    );
    _thumbnail = thumbnail;
    thumbnail.insert(
      context,
      state,
      stickyPadding: widget.stickyPadding,
      overlayState: widget.overlayKey?.currentState,
    );
  }

  void _removeThumbnail() {
    _thumbnailVisible.value = false;
    _thumbnailLkRoom.value = null;
    if (_thumbnail?.inserted == true) _thumbnail?.remove();
    _thumbnail = null;
  }

  TringupCallPhase _mapPhase(ActiveCall call) {
    print("**************${call.processingStatus}");
    return switch (call.processingStatus) {
    // ── Incoming ─────────────────────────────────────────────────────────
      CallProcessingStatus.incomingFromPush    ||
      CallProcessingStatus.incomingFromOffer   ||
      CallProcessingStatus.conferenceInvitePending => TringupCallPhase.ringing,

      CallProcessingStatus.incomingSubmittedAnswer  ||
      CallProcessingStatus.incomingPerformingStarted ||
      CallProcessingStatus.incomingInitializingMedia ||
      CallProcessingStatus.incomingAnswering         => TringupCallPhase.connecting,

    // ── Outgoing ─────────────────────────────────────────────────────────
      CallProcessingStatus.outgoingCreated              ||
      CallProcessingStatus.outgoingCreatedFromRefer     ||
      CallProcessingStatus.outgoingConnectingToSignaling ||
      CallProcessingStatus.outgoingInitializingMedia    ||
      CallProcessingStatus.outgoingOfferPreparing       ||
      CallProcessingStatus.outgoingOfferSent             => TringupCallPhase.calling,

    // Remote device is ringing
      CallProcessingStatus.outgoingRinging => TringupCallPhase.ringing,

    // ── Connected ────────────────────────────────────────────────────────
      CallProcessingStatus.conferenceActive ||
      CallProcessingStatus.connected         => TringupCallPhase.connected,

    // call ended
      CallProcessingStatus.disconnecting => TringupCallPhase.ended,

      _ => TringupCallPhase.calling,
    };
  }
}

// ---------------------------------------------------------------------------
// _CallScreenOverlayContent — lifecycle wrapper + builder bridge
// ---------------------------------------------------------------------------

class _CallScreenOverlayContent extends StatefulWidget {
  const _CallScreenOverlayContent({
    required this.callBloc,
    required this.onMinimise,
    this.customBuilder,
    this.callTheme,
    this.pipManager,
    this.participantsProvider,
    this.contactInfoProvider,
    this.localUserProvider,
    this.nameResolver,
    this.photoPathResolver,
  });

  final CallBloc callBloc;
  final VoidCallback onMinimise;
  final TringupCallScreenBuilder? customBuilder;
  final TringupCallTheme? callTheme;
  final TringupPiPManager? pipManager;
  final Future<List<TringupParticipant>> Function(String callId)? participantsProvider;
  final ({String? displayName, String? photoPath, String? photoUrl})
      Function(String phoneNumber)? contactInfoProvider;
  final String? Function()? localUserProvider;
  final TringupNameResolver? nameResolver;
  final TringupPhotoPathResolver? photoPathResolver;

  @override
  State<_CallScreenOverlayContent> createState() => _CallScreenOverlayContentState();
}

class _CallScreenOverlayContentState extends State<_CallScreenOverlayContent> {
  List<TringupParticipant> _addableParticipants = const [];
  String? _lastLoadedCallId;

  // Track which callId we've already pushed a host-app display-name update for
  // so we only call callkeep.reportUpdateCall once per call (not every build).
  String? _lastDisplayNameCallId;

  void _loadAddableParticipants(String callId) {
    if (_lastLoadedCallId == callId) return;
    _lastLoadedCallId = callId;
    widget.participantsProvider?.call(callId).then((list) {
      if (mounted) setState(() => _addableParticipants = list);
    });
  }

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) widget.callBloc.add(const CallScreenEvent.didPush());
    });
  }

  @override
  void dispose() {
    widget.callBloc.add(const CallScreenEvent.didPop());
    super.dispose();
  }

  TringupAudioOutput _mapAudio(CallAudioDevice? device) {
    switch (device?.type) {
      case CallAudioDeviceType.speaker:
        return TringupAudioOutput.speaker;
      case CallAudioDeviceType.bluetooth:
        return TringupAudioOutput.bluetooth;
      case CallAudioDeviceType.wiredHeadset:
        return TringupAudioOutput.wired;
      default:
        return TringupAudioOutput.earpiece;
    }
  }

  @override
  Widget build(BuildContext context) {
    return PopScope(
      canPop: false,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) widget.onMinimise();
      },
      child: AnnotatedRegion<SystemUiOverlayStyle>(
        value: SystemUiOverlayStyle.light,
        child: BlocBuilder<CallBloc, CallState>(
          bloc: widget.callBloc,
          // Only rebuild when fields the call screen actually renders change.
          // Suppresses rebuilds from signaling/status events that don't affect
          // video, which previously caused RTCStreamView didUpdateWidget calls.
          buildWhen: (prev, curr) {
            if (prev.activeCalls.length != curr.activeCalls.length) return true;
            if (prev.activeCalls.isEmpty) return false;
            final p = prev.activeCalls.current;
            final c = curr.activeCalls.current;
            // Also rebuild when conference participants change.
            final prevParts = widget.callBloc.getConferenceParticipants(p.callId);
            final currParts = widget.callBloc.getConferenceParticipants(c.callId);
            return p.callId         != c.callId         ||
                   p.wasAccepted    != c.wasAccepted     ||
                   p.muted          != c.muted           ||
                   p.held           != c.held            ||
                   p.video          != c.video           ||
                   p.cameraEnabled  != c.cameraEnabled   ||
                   p.localStream    != c.localStream     ||
                   p.remoteStream   != c.remoteStream    ||
                   p.localVideo     != c.localVideo      ||
                   p.remoteVideo    != c.remoteVideo     ||
                   p.acceptedTime      != c.acceptedTime      ||
                   p.isIncoming        != c.isIncoming        ||
                   p.processingStatus  != c.processingStatus  ||
                   p.frontCamera       != c.frontCamera       ||
                   p.updating          != c.updating          ||
                   prev.audioDevice != curr.audioDevice  ||
                   prev.availableAudioDevices != curr.availableAudioDevices ||
                   prevParts.length != currParts.length;
          },
          builder: (context, state) {
            if (!state.isActive) {
              return const ColoredBox(
                color: Color(0xFF0A1520),
                child: Center(
                  child: CircularProgressIndicator(color: Colors.white54),
                ),
              );
            }

            final activeCall  = state.activeCalls.current;
            final groupEnabled = widget.callBloc.groupCallEnabled;

            final rawParticipants =
                widget.callBloc.getConferenceParticipants(activeCall.callId);
            // Build a userId→addable map for O(1) photo/name lookup.
            final addableMap = {
              for (final a in _addableParticipants) a.userId: a
            };
            final participants = rawParticipants
                .map((p) {
                  final addable = addableMap[p.userId];
                  // Resolve name + photo from host-app contacts.
                  // When userId is a server ID (user_XXXX), use the stored
                  // phoneNumber for contact lookup so names resolve correctly.
                  final lookupKey = p.phoneNumber ?? p.userId;
                  final contactInfo = widget.contactInfoProvider?.call(lookupKey);
                  return TringupParticipant(
                    userId:      p.userId,
                    displayName: (contactInfo?.displayName?.isNotEmpty == true)
                        ? contactInfo!.displayName
                        : (p.displayName ?? addable?.displayName),
                    photoUrl:    contactInfo?.photoUrl ?? addable?.photoUrl,
                    photoPath:   contactInfo?.photoPath ?? addable?.photoPath,
                    phoneNumber: p.phoneNumber,
                  );
                })
                .toList();

            // Trigger async load of addable participants for this callId.
            _loadAddableParticipants(activeCall.callId);

            // For group calls, groupName is the authoritative display name —
            // skip contact resolution so the first callee's contact name
            // does not overwrite the group name.
            print('PPPPPPPPPPPPPPPPPPP${activeCall.groupName}');
            final isGroupCall = activeCall.groupName != null;
            final contactInfo = isGroupCall
                ? null
                : widget.contactInfoProvider?.call(activeCall.handle.value);

            // Prefer the host-app's local contact name; fall back to the
            // server-provided display name that is already on ActiveCall.
            // For group calls, always use groupName directly.
            final resolvedName = isGroupCall
            // Prefer explicit groupName; fall back to displayName so the header
            // always shows a meaningful label even during the brief window before
            // groupName is set by the BLoC.
                ? (activeCall.groupName?.isNotEmpty == true
                ? activeCall.groupName
                : activeCall.displayName)
                : (contactInfo?.displayName?.isNotEmpty == true)
                ? contactInfo!.displayName
                : activeCall.displayName;

            // Push the resolved name into ActiveCall + CallKeep notification
            // once per call (not on every rebuild). Skip for group calls since
            // groupName is already correct and must not be replaced.
            if (!isGroupCall &&
                resolvedName != null &&
                resolvedName.isNotEmpty &&
                resolvedName != activeCall.displayName &&
                _lastDisplayNameCallId != activeCall.callId) {
              _lastDisplayNameCallId = activeCall.callId;
              widget.callBloc.updateCallDisplayName(activeCall.callId, resolvedName, avatarFilePath: contactInfo?.photoPath);
            }

            final info = TringupCallInfo(
              callId:               activeCall.callId,
              number:               activeCall.handle.value,
              displayName:          resolvedName,
              photoUrl:             contactInfo?.photoUrl,
              photoPath:            contactInfo?.photoPath,
              isIncoming:           activeCall.isIncoming,
              isConnected:          activeCall.wasAccepted,
              isRinging:            activeCall.processingStatus == CallProcessingStatus.outgoingRinging,
              busySignal:           activeCall.processingStatus == CallProcessingStatus.busySignal,
              isMuted:              activeCall.muted,
              isOnHold:             activeCall.held,
              connectedAt:          activeCall.acceptedTime,
              audioOutput:          _mapAudio(state.audioDevice),
              isGroupCallEnabled:   groupEnabled,
              isVideoCall:          activeCall.video,
              isCameraEnabled:      activeCall.cameraEnabled,
              participants:         participants,
              isGroupCall:          isGroupCall,
              addableParticipants:  _addableParticipants,
              ringingUserIds:       const {},
              localUserNumber:      widget.localUserProvider?.call(),
              participantPhoneMap:  widget.callBloc.getParticipantPhoneMap(activeCall.callId),
            );

            final actions = TringupCallActions(
              hangUp: () => widget.callBloc.add(
                CallControlEvent.ended(activeCall.callId),
              ),
              setMuted: (muted) => widget.callBloc.add(
                CallControlEvent.setMuted(activeCall.callId, muted),
              ),
              setSpeaker: (speakerOn) {
                if (state.availableAudioDevices.isEmpty) return;
                final target = speakerOn
                    ? state.availableAudioDevices.firstWhere(
                        (d) => d.type == CallAudioDeviceType.speaker,
                        orElse: () => state.availableAudioDevices.first,
                      )
                    : state.availableAudioDevices.firstWhere(
                        (d) => d.type == CallAudioDeviceType.earpiece,
                        orElse: () => state.availableAudioDevices.first,
                      );
                widget.callBloc.add(
                  CallControlEvent.audioDeviceSet(activeCall.callId, target),
                );
              },
              setHeld: (onHold) => widget.callBloc.add(
                CallControlEvent.setHeld(activeCall.callId, onHold),
              ),
              switchCamera: () => widget.callBloc.add(
                CallControlEvent.cameraSwitched(activeCall.callId),
              ),
              setCameraEnabled: (enabled) => widget.callBloc.add(
                CallControlEvent.cameraEnabled(activeCall.callId, enabled),
              ),
              minimize: widget.onMinimise,
              answer: activeCall.isIncoming && !activeCall.wasAccepted
                  ? () => widget.callBloc.add(
                      CallControlEvent.answered(activeCall.callId),
                    )
                  : null,
              addParticipant: groupEnabled && activeCall.wasAccepted
                  ? (number) => widget.callBloc.add(
                      CallControlEvent.addParticipant(activeCall.callId, number),
                    )
                  : null,
            );

            if (widget.customBuilder != null) {
              return widget.customBuilder!(context, info, actions);
            }
            final lkRoom = widget.callBloc.getLiveKitRoom(activeCall.callId);

            // All calls (1:1 and group) use TringupDefaultCallScreen.
            // Rebuild info with corrected isCameraEnabled when in LiveKit mode.
            final infoFinal = lkRoom != null
                ? TringupCallInfo(
                    callId:             info.callId,
                    number:             info.number,
                    displayName:        info.displayName,
                    photoUrl:           info.photoUrl,
                    photoPath:          info.photoPath,
                    isIncoming:         info.isIncoming,
                    isConnected:        info.isConnected,
                    isRinging:          info.isRinging,
                    isMuted:            info.isMuted,
                    isOnHold:           info.isOnHold,
                    connectedAt:        info.connectedAt,
                    audioOutput:        info.audioOutput,
                    isGroupCallEnabled: info.isGroupCallEnabled,
                    isVideoCall:        info.isVideoCall,
                    // For LiveKit, cameraEnabled is a computed getter that
                    // reads localStream which is always null in LiveKit mode.
                    // The BLoC uses frontCamera as the camera-active signal:
                    //   false        → camera disabled
                    //   null / true  → camera enabled
                    isCameraEnabled:    activeCall.frontCamera != false,
                    participants:       info.participants,
                    isGroupCall:        info.isGroupCall,
                    addableParticipants: info.addableParticipants,
                    ringingUserIds:       info.ringingUserIds,
                    localUserNumber:      info.localUserNumber,
                    participantPhoneMap:  info.participantPhoneMap,
                    busySignal:           info.busySignal,
                  )
                : info;
            final scaffold = TringupDefaultCallScreen(
              info:              infoFinal,
              actions:           actions,
              localStream:       activeCall.localStream,
              localVideo:        activeCall.localVideo,
              remoteStream:      activeCall.remoteStream,
              remoteVideo:       activeCall.remoteVideo,
              livekitRoom:       lkRoom,
              pipManager:        widget.pipManager,
              nameResolver:      widget.nameResolver,
              photoPathResolver: widget.photoPathResolver,
            );

            final theme = widget.callTheme;
            return theme != null ? theme.wrap(context, scaffold) : scaffold;
          },
        ),
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// _ThumbnailOverlay — draggable minimised call thumbnail
// ---------------------------------------------------------------------------

class _ThumbnailOverlay {
  _ThumbnailOverlay({
    required this.stickyPadding,
    required this.lkRoom,
    required this.lkRoomNotifier,
    required this.visibilityNotifier,
    this.onTap,
  });

  final EdgeInsets stickyPadding;
  final lk.Room? lkRoom;
  // Receives eager room updates from _videoPiPListener so _LkVideoThumbnail
  // (and its VideoTrackRenderer) is created while still hidden (pre-warm),
  // making the first minimize instant.
  final ValueNotifier<lk.Room?> lkRoomNotifier;
  // Shared with _TringupCallShellState so the shell can toggle visibility
  // without removing/re-inserting the entry (keeps VideoTrackRenderer warm).
  final ValueNotifier<bool> visibilityNotifier;
  final VoidCallback? onTap;

  Offset? _offset;
  OverlayEntry? _entry;

  bool get inserted => _entry != null;

  void insert(
    BuildContext context,
    CallState state, {
    required EdgeInsets stickyPadding,
    OverlayState? overlayState,
  }) {
    assert(_entry == null);
    final callBloc = context.read<CallBloc>();

    final entry = OverlayEntry(
      builder: (_) => BlocProvider<CallBloc>.value(
        value: callBloc,
        child: PresenceViewParams(
          viewSource: PresenceViewSource.contactInfo,
          // _DraggableThumbnail (→ AnimatedPositioned) MUST be a direct
          // non-RenderObject descendant of the Overlay's Stack.  Wrapping it
          // in Opacity / Offstage / IgnorePointer inserts a RenderObject that
          // breaks the Positioned parent-data chain ("Positioned inside Opacity"
          // error).  So BlocBuilder + Opacity live INSIDE the child of
          // _DraggableThumbnail — inside the GestureDetector — where they are
          // safe.  Opacity(0) also makes RenderOpacity.hitTest return false, so
          // the GestureDetector won't fire during the hidden pre-warm phase.
          child: _DraggableThumbnail(
            stickyPadding:  stickyPadding,
            initialOffset:  _offset,
            onOffsetUpdate: (offset) => _offset = offset,
            onTap:          onTap,
            child: BlocBuilder<CallBloc, CallState>(
              bloc: callBloc,
              builder: (_, callState) {
                if (callState.activeCalls.isEmpty) {
                  // ignore: avoid_print
                  print('[THUMB][BlocBuilder] activeCalls empty → shrink');
                  return const SizedBox.shrink();
                }
                final freshCall = callState.activeCalls.current;
                // ignore: avoid_print
                print('[THUMB][BlocBuilder] callId=${freshCall.callId} video=${freshCall.video}');
                // Use ValueListenableBuilder so the thumbnail reacts to the
                // room becoming available (pushed by _videoPiPListener) without
                // waiting for a full BLoC state emission.  This is what makes
                // _LkVideoThumbnail (and its VideoTrackRenderer) initialise
                // while still hidden (Opacity=0), so the first minimize is
                // instant instead of 2-4 seconds.
                return ValueListenableBuilder<lk.Room?>(
                  valueListenable: lkRoomNotifier,
                  builder: (_, lkRoom, __) {
                    // Prefer the eagerly-pushed room; fall back to BLoC query
                    // in case the notifier hasn't been updated yet.
                    final freshRoom = lkRoom ?? callBloc.getLiveKitRoom(freshCall.callId);
                    // ignore: avoid_print
                    print('[THUMB][RoomNotifier] lkRoom=${freshRoom != null ? "present(remotes=${freshRoom.remoteParticipants.length})" : "NULL"}');
                    return ValueListenableBuilder<bool>(
                      valueListenable: visibilityNotifier,
                      builder: (_, visible, __) {
                        // ignore: avoid_print
                        print('[THUMB][Visibility] visible=$visible');
                        return Opacity(
                          opacity: visible ? 1.0 : 0.0,
                          child: _VideoAwareThumbnail(
                            activeCall: freshCall,
                            lkRoom:     freshRoom,
                          ),
                        );
                      },
                    );
                  },
                );
              },
            ),
          ),
        ),
      ),
    );
    _entry = entry;
    (overlayState ?? Overlay.of(context)).insert(entry);
  }

  void remove() {
    assert(_entry != null);
    _entry!.remove();
    _entry = null;
  }
}

// ---------------------------------------------------------------------------
// _VideoAwareThumbnail — wraps CallActiveThumbnail and adds a local-video
// corner overlay when the minimised call is an active video call.
// ---------------------------------------------------------------------------

class _VideoAwareThumbnail extends StatelessWidget {
  const _VideoAwareThumbnail({required this.activeCall, this.lkRoom});

  final ActiveCall activeCall;
  final lk.Room? lkRoom;

  @override
  Widget build(BuildContext context) {
    // ignore: avoid_print
    print('[THUMB][VideoAware] lkRoom=${lkRoom != null ? "present(remotes=${lkRoom!.remoteParticipants.length})" : "NULL"} localVideo=${activeCall.localVideo} remoteVideo=${activeCall.remoteVideo}');
    // LiveKit call: use VideoTrackRenderer to reuse the already-subscribed
    // track.  Avoids creating a new MediaStream binding and never flashes.
    if (lkRoom != null && lkRoom!.remoteParticipants.isNotEmpty) {
      // ignore: avoid_print
      print('[THUMB][VideoAware] → _LkVideoThumbnail');
      return _LkVideoThumbnail(lkRoom: lkRoom!, activeCall: activeCall);
    }
    // ignore: avoid_print
    print('[THUMB][VideoAware] → CallActiveThumbnail (legacy/audio fallback)');

    // Legacy / audio-only call: keep existing behaviour.
    final hasLocal = activeCall.localVideo && activeCall.localStream != null;
    return Stack(
      clipBehavior: Clip.none,
      children: [
        CallActiveThumbnail(activeCall: activeCall),
        // Small local-video pip in the bottom-right corner of the thumbnail.
        if (hasLocal)
          Positioned(
            right: 4,
            bottom: 4,
            child: ClipRRect(
              borderRadius: BorderRadius.circular(4),
              child: SizedBox(
                width: 36,
                height: 50,
                child: RTCStreamView(
                  stream: activeCall.localStream,
                  mirror: true,
                ),
              ),
            ),
          ),
      ],
    );
  }
}

// ---------------------------------------------------------------------------
// Diagnostics helpers — map internal enum values to human-readable labels.
// ---------------------------------------------------------------------------

String _signalingLabel(SignalingClientStatus status) {
  // Uses the enum name but maps the internal name 'connect' → 'connected'
  // and 'disconnect' → 'disconnected' for readability.
  switch (status) {
    case SignalingClientStatus.connect:
      return 'connected';
    case SignalingClientStatus.disconnect:
      return 'disconnected';
    case SignalingClientStatus.failure:
      return 'failed';
    default:
      return status.name; // 'connecting', 'disconnecting'
  }
}

// RegistrationStatus is from webtrit_signaling — accessed via .name to avoid
// importing the transitive package directly into tringup_call.
String _registrationLabel(Object? status) {
  if (status == null) return '—';
  final name = status is Enum ? status.name : status.toString();
  // Normalise the internal 'registration_failed' name.
  if (name == 'registration_failed') return 'failed';
  return name;
}

// ---------------------------------------------------------------------------
// _LkVideoThumbnail — WhatsApp-style PiP thumbnail for LiveKit calls.
//
// Renders the remote video (full frame) with a local self-view corner pip.
// Both use lk.VideoTrackRenderer which attaches a second native texture to
// the already-subscribed track — the full-screen renderers sitting in the
// Offstage call screen are completely unaffected.
// ---------------------------------------------------------------------------

class _LkVideoThumbnail extends StatefulWidget {
  const _LkVideoThumbnail({
    required this.lkRoom,
    required this.activeCall,
  });

  final lk.Room lkRoom;
  final ActiveCall activeCall;

  @override
  State<_LkVideoThumbnail> createState() => _LkVideoThumbnailState();
}

class _LkVideoThumbnailState extends State<_LkVideoThumbnail> {
  static const double _w      = 90.0;
  static const double _h      = 160.0;
  static const double _localW = 36.0;
  static const double _localH = 52.0;

  @override
  void initState() {
    super.initState();
    widget.lkRoom.addListener(_onRoomChanged);
    // ignore: avoid_print
    print('[THUMB][LkVideoThumbnail] initState remotes=${widget.lkRoom.remoteParticipants.length} localParticipant=${widget.lkRoom.localParticipant?.identity}');
  }

  @override
  void didUpdateWidget(_LkVideoThumbnail old) {
    super.didUpdateWidget(old);
    if (old.lkRoom != widget.lkRoom) {
      old.lkRoom.removeListener(_onRoomChanged);
      widget.lkRoom.addListener(_onRoomChanged);
    }
  }

  @override
  void dispose() {
    widget.lkRoom.removeListener(_onRoomChanged);
    super.dispose();
  }

  void _onRoomChanged() {
    if (mounted) setState(() {});
  }

  /// Pick the "best" remote participant to show as the main tile.
  /// Priority: active speaker → first participant with video → first participant.
  lk.RemoteParticipant? _mainParticipant() {
    final remotes = widget.lkRoom.remoteParticipants.values.toList();
    if (remotes.isEmpty) return null;

    final speaker = remotes
        .where((p) => p.isSpeaking)
        .fold<lk.RemoteParticipant?>(null, (best, p) {
      if (best == null) return p;
      return p.audioLevel > best.audioLevel ? p : best;
    });
    if (speaker != null) return speaker;

    return remotes.firstWhere(
      (p) => p.videoTrackPublications.any((pub) => pub.subscribed && pub.track != null),
      orElse: () => remotes.first,
    );
  }

  lk.VideoTrack? _remoteVideoTrack(lk.RemoteParticipant? p) {
    if (p == null) return null;
    for (final pub in p.videoTrackPublications) {
      if (pub.subscribed && pub.track != null) return pub.track as lk.VideoTrack;
    }
    return null;
  }

  lk.LocalVideoTrack? _localVideoTrack() {
    for (final pub in widget.lkRoom.localParticipant?.videoTrackPublications ?? []) {
      if (pub.track != null) return pub.track as lk.LocalVideoTrack;
    }
    return null;
  }

  @override
  Widget build(BuildContext context) {
    final mainParticipant  = _mainParticipant();
    final remoteTrack      = _remoteVideoTrack(mainParticipant);
    final localTrack       = _localVideoTrack();
    final cameraEnabled    = widget.activeCall.frontCamera != false;
    final hasLocalVideo    = localTrack != null && cameraEnabled;
    final remoteCount      = widget.lkRoom.remoteParticipants.length;
    // ignore: avoid_print
    print('[THUMB][LkVideoThumbnail] build remotes=$remoteCount mainParticipant=${mainParticipant?.identity} remoteTrack=${remoteTrack != null ? "present" : "NULL"} localTrack=${localTrack != null ? "present" : "NULL"} hasLocalVideo=$hasLocalVideo');

    return ClipRRect(
      borderRadius: BorderRadius.circular(12),
      child: SizedBox(
        width: _w,
        height: _h,
        child: Stack(
          fit: StackFit.expand,
          children: [
            // ── Remote video (full frame) or dark fallback ─────────────────
            if (remoteTrack != null)
              lk.VideoTrackRenderer(
                remoteTrack,
                fit: lk.VideoViewFit.cover,
              )
            else
              Container(
                color: const Color(0xFF0D1F2D),
                child: Center(
                  child: Icon(
                    mainParticipant != null ? Icons.person : Icons.phone_in_talk,
                    color: Colors.white38,
                    size: 32,
                  ),
                ),
              ),

            // ── +N badge when more than one remote participant ─────────────
            if (remoteCount >= 2)
              Positioned(
                top: 6,
                left: 6,
                child: Container(
                  padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 2),
                  decoration: BoxDecoration(
                    color: Colors.black54,
                    borderRadius: BorderRadius.circular(8),
                  ),
                  child: Text(
                    '+${remoteCount - 1}',
                    style: const TextStyle(
                      color: Colors.white,
                      fontSize: 10,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ),
              ),

            // ── Local self-view pip (bottom-right corner) ─────────────────
            Positioned(
              right: 4,
              bottom: 4,
              child: ClipRRect(
                borderRadius: BorderRadius.circular(6),
                child: SizedBox(
                  width: _localW,
                  height: _localH,
                  child: hasLocalVideo
                      ? lk.VideoTrackRenderer(
                          localTrack!,
                          fit: lk.VideoViewFit.cover,
                          mirrorMode: widget.activeCall.frontCamera != false
                              ? lk.VideoViewMirrorMode.mirror
                              : lk.VideoViewMirrorMode.off,
                        )
                      : Container(
                          color: const Color(0xFF071015),
                          child: const Icon(
                            Icons.videocam_off,
                            color: Colors.white38,
                            size: 14,
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

// ---------------------------------------------------------------------------
// _DraggableThumbnail
// ---------------------------------------------------------------------------

enum _StickySide { left, right }

class _DraggableThumbnail extends StatefulWidget {
  const _DraggableThumbnail({
    required this.child,
    required this.stickyPadding,
    // ignore: unused_element_parameter
    this.initialStickySide = _StickySide.right,
    this.initialOffset,
    this.onOffsetUpdate,
    this.onTap,
  });

  final Widget child;
  final EdgeInsets stickyPadding;
  final _StickySide initialStickySide;
  final Offset? initialOffset;
  final void Function(Offset offset)? onOffsetUpdate;
  final VoidCallback? onTap;

  @override
  State<_DraggableThumbnail> createState() => _DraggableThumbnailState();
}

class _DraggableThumbnailState extends State<_DraggableThumbnail> {
  final _key = GlobalKey();
  bool _panning = false;

  late EdgeInsets _mqPadding;
  late Size _mqSize;
  late Rect _activeRect;
  late Rect _stickyRect;
  _StickySide? _lastSide;
  Offset? _offset;

  @override
  void initState() {
    super.initState();
    _offset = widget.initialOffset;
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _mqPadding = MediaQuery.paddingOf(context);
    _mqSize    = MediaQuery.sizeOf(context);
    _activeRect = _mqPadding.deflateRect(Offset.zero & _mqSize);
    _stickyRect = widget.stickyPadding.deflateRect(_activeRect);

    if (_offset != null && !_panning) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        final cardRect = _cardRect();
        final tx = _lastStickyTranslateX(_stickyRect, cardRect);
        final ty = _boundY(_stickyRect, cardRect);
        final offset = cardRect.translate(tx, ty).topLeft;
        if (_offset != offset) {
          widget.onOffsetUpdate?.call(offset);
          setState(() => _offset = offset);
        }
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    double? left, top, right;
    final offset = _offset;
    if (offset == null) {
      final padding = widget.stickyPadding + _mqPadding;
      switch (widget.initialStickySide) {
        case _StickySide.left:
          left = padding.left;
          top  = padding.top;
        case _StickySide.right:
          right = padding.right;
          top   = padding.top;
      }
    } else {
      left = offset.dx;
      top  = offset.dy;
    }

    return AnimatedPositioned(
      key: _key,
      left: left,
      top: top,
      right: right,
      curve: Curves.ease,
      duration: _panning ? Duration.zero : kRadialReactionDuration,
      child: GestureDetector(
        onTap: widget.onTap,
        onPanStart: (_) => setState(() => _panning = true),
        onPanUpdate: (d) {
          final r = _cardRect(d.delta);
          final o = _cardRect(d.delta)
              .translate(_boundX(_activeRect, r), _boundY(_activeRect, r))
              .topLeft;
          widget.onOffsetUpdate?.call(o);
          setState(() => _offset = o);
        },
        onPanEnd: (_) {
          final r = _cardRect();
          final o = r
              .translate(_stickyTranslateX(_stickyRect, r), _boundY(_stickyRect, r))
              .topLeft;
          widget.onOffsetUpdate?.call(o);
          setState(() {
            _offset  = o;
            _panning = false;
          });
        },
        child: widget.child,
      ),
    );
  }

  Rect _cardRect([Offset delta = Offset.zero]) {
    final rb = _key.currentContext?.findRenderObject() as RenderBox?;
    if (rb == null || !rb.hasSize) return Rect.zero;
    return Rect.fromLTWH(
      rb.localToGlobal(Offset.zero).dx + delta.dx,
      rb.localToGlobal(Offset.zero).dy + delta.dy,
      rb.size.width,
      rb.size.height,
    );
  }

  double _stickyTranslateX(Rect sticky, Rect card) {
    if (card.center.dx < sticky.center.dx) {
      _lastSide = _StickySide.left;
      return sticky.left - card.left;
    } else {
      _lastSide = _StickySide.right;
      return sticky.right - card.right;
    }
  }

  double _lastStickyTranslateX(Rect sticky, Rect card) {
    return switch (_lastSide) {
      _StickySide.left  => sticky.left - card.left,
      _StickySide.right => sticky.right - card.right,
      null              => 0,
    };
  }

  double _boundX(Rect bound, Rect card) {
    if (bound.left > card.left) return bound.left - card.left;
    if (bound.right < card.right) return bound.right - card.right;
    return 0;
  }

  double _boundY(Rect bound, Rect card) {
    if (bound.top > card.top) return bound.top - card.top;
    if (bound.bottom < card.bottom) return bound.bottom - card.bottom;
    return 0;
  }
}


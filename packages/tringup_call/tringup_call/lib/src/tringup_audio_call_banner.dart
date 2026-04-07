import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:webtrit_phone/features/call/call.dart';

import 'tringup_call_screen_api.dart';

// ─────────────────────────────────────────────────────────────────────────────
// TringupAudioCallBannerScope
// ─────────────────────────────────────────────────────────────────────────────

/// Wraps the host app's root content so that [TringupAudioCallBanner] is
/// displayed at the top (below the system status bar) whenever an audio call
/// is in overlay mode, without covering the host app's [AppBar].
///
/// **Why use this instead of placing [TringupAudioCallBanner] directly?**
///
/// When the banner is visible it must account for the system status-bar inset.
/// Simply wrapping the banner with [SafeArea] would permanently consume
/// `MediaQuery.padding.top`, causing every [Scaffold] below to add a second
/// copy of that inset (visible as a blank gap between the banner and the
/// app's [AppBar]).  This widget solves that by:
///
/// 1. Rendering the banner with its own top safe-area padding.
/// 2. Removing `MediaQuery.padding.top` from the child's [MediaQuery] while
///    the banner is visible, so [Scaffold] widgets below do not double-count
///    the status-bar inset.
/// 3. Restoring the full [MediaQuery] when the banner is hidden, so [Scaffold]
///    widgets behave exactly as before.
///
/// ## Usage in `GetMaterialApp.builder`
///
/// ```dart
/// builder: (context, child) {
///   return Stack(
///     children: [
///       TringupCallShell(
///         overlayKey: TringupCallOverlay.key,
///         child: AppLockWrapper(
///           child: TringupAudioCallBannerScope(    // ← add this
///             child: Stack(
///               children: [
///                 child ?? const SizedBox.shrink(),
///                 const GlobalLoader(),
///               ],
///             ),
///           ),
///         ),
///       ),
///       Positioned.fill(
///         child: Overlay(key: TringupCallOverlay.key, initialEntries: const []),
///       ),
///     ],
///   );
/// },
/// ```
///
/// [TringupCallWidget] (or a manually provided [CallBloc]) must be an ancestor.
class TringupAudioCallBannerScope extends StatelessWidget {
  const TringupAudioCallBannerScope({
    super.key,
    required this.child,
    this.bannerBuilder,
    this.extraTopPadding = 0,
  });

  /// The host app content placed below the banner.
  final Widget child;

  /// Optional custom builder for the banner content; forwarded to
  /// [TringupAudioCallBanner.builder].
  final TringupAudioCallOverlayBuilder? bannerBuilder;

  /// Extra pixels added on top of the system status-bar inset.
  ///
  /// Use this to fine-tune the banner's vertical position, for example when
  /// your app has a navigation bar or custom top chrome that shifts the
  /// effective safe area.  Defaults to 0 (only system inset is used).
  final double extraTopPadding;

  /// Returns true when the audio-call banner should be shown.
  static bool _isBannerActive(CallState state) =>
      state.display == CallDisplay.overlay &&
      state.activeCalls.isNotEmpty &&
      !state.activeCalls.current.video;

  @override
  Widget build(BuildContext context) {
    return BlocBuilder<CallBloc, CallState>(
      // Only rebuild when banner visibility could change.
      buildWhen: (prev, curr) {
        final wasBanner = _isBannerActive(prev);
        final isBanner  = _isBannerActive(curr);
        return wasBanner != isBanner;
      },
      builder: (context, state) {
        final active = _isBannerActive(state);

        // When the banner is visible:
        //   • The banner itself includes the top safe-area inset as padding.
        //   • The child's MediaQuery has that inset removed so that Scaffold
        //     widgets below do not add a second copy of it.
        // When the banner is hidden:
        //   • SizedBox.shrink() → zero height, no inset consumed.
        //   • Child receives the unmodified MediaQuery (normal Scaffold behaviour).
        return Column(
          children: [
            TringupAudioCallBanner(
              builder:         bannerBuilder,
              topSafeArea:     active,
              extraTopPadding: extraTopPadding,
            ),
            Expanded(
              child: active
                  ? MediaQuery.removePadding(
                      context: context,
                      removeTop: true,
                      child: child,
                    )
                  : child,
            ),
          ],
        );
      },
    );
  }
}

/// A self-contained widget that shows an audio-call status banner whenever an
/// audio (non-video) call is minimised to [CallDisplay.overlay] mode.
///
/// **The host app is responsible for placing this widget** in its own widget
/// tree — for example below the [AppBar], inside a [Column], or as the
/// [AppBar.bottom].  The widget occupies zero height when no audio call is
/// active in overlay mode, so it is safe to include it unconditionally in a
/// layout.
///
/// ## Typical usage
///
/// ```dart
/// Scaffold(
///   appBar: AppBar(title: Text('Chat')),
///   body: Column(
///     children: [
///       TringupAudioCallBanner(),       // appears only during overlay mode
///       Expanded(child: ChatMessageList()),
///     ],
///   ),
/// )
/// ```
///
/// ## Custom content
///
/// Provide [builder] to replace the built-in dark banner with your own widget:
///
/// ```dart
/// TringupAudioCallBanner(
///   builder: (context, info, actions) => Container(
///     color: Theme.of(context).colorScheme.primaryContainer,
///     padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
///     child: Row(
///       children: [
///         Text(info.callerLabel),
///         const Spacer(),
///         IconButton(
///           icon: const Icon(Icons.call_end, color: Colors.red),
///           onPressed: actions.hangUp,
///         ),
///       ],
///     ),
///   ),
/// )
/// ```
///
/// The [builder] receives:
/// - [TringupCallInfo]    — read-only snapshot of the current call.
/// - [TringupCallActions] — action callbacks (`hangUp`, `setMuted`,
///   `minimize` to restore the full call screen, `answer` for ringing calls).
///
/// [TringupCallWidget] (or a manually provided [CallBloc]) must be an ancestor
/// of this widget in the widget tree.
class TringupAudioCallBanner extends StatefulWidget {
  const TringupAudioCallBanner({
    super.key,
    this.builder,
    this.topSafeArea = false,
    this.extraTopPadding = 0,
  });

  /// Optional custom builder for the banner content.
  ///
  /// When null the built-in dark banner is used (caller name + elapsed timer +
  /// mute toggle + hang-up button).
  final TringupAudioCallOverlayBuilder? builder;

  /// When true, adds the system status-bar inset as top padding so the banner
  /// renders correctly when placed at y = 0 of the screen.
  ///
  /// Set this manually only if you place [TringupAudioCallBanner] at the very
  /// top of the screen yourself.  When using [TringupAudioCallBannerScope]
  /// (recommended), this is handled automatically — leave it false.
  final bool topSafeArea;

  /// Extra pixels added on top of the system status-bar inset (when
  /// [topSafeArea] is true) or as a standalone top offset (when false).
  /// Useful for fine-tuning the banner's vertical position.
  final double extraTopPadding;

  @override
  State<TringupAudioCallBanner> createState() => _TringupAudioCallBannerState();
}

class _TringupAudioCallBannerState extends State<TringupAudioCallBanner> {
  // Ticks every second so the elapsed-time label refreshes.
  Timer? _timer;

  @override
  void initState() {
    super.initState();
    _timer = Timer.periodic(const Duration(seconds: 1), (_) {
      if (mounted) setState(() {});
    });
  }

  @override
  void dispose() {
    _timer?.cancel();
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
    return BlocBuilder<CallBloc, CallState>(
      // Rebuild only on fields that actually affect the banner UI.
      buildWhen: (prev, curr) {
        if (prev.display != curr.display) return true;
        if (prev.activeCalls.length != curr.activeCalls.length) return true;
        if (prev.activeCalls.isEmpty) return false;
        final p = prev.activeCalls.current;
        final c = curr.activeCalls.current;
        return p.callId        != c.callId        ||
               p.wasAccepted   != c.wasAccepted    ||
               p.muted         != c.muted          ||
               p.held          != c.held           ||
               p.isIncoming    != c.isIncoming     ||
               p.acceptedTime  != c.acceptedTime   ||
               p.video         != c.video          ||
               prev.audioDevice != curr.audioDevice;
      },
      builder: (context, state) {
        // Only visible during overlay mode with an active audio call.
        if (state.display != CallDisplay.overlay ||
            state.activeCalls.isEmpty ||
            state.activeCalls.current.video) {
          return const SizedBox.shrink();
        }

        final activeCall = state.activeCalls.current;
        final callBloc   = context.read<CallBloc>();

        final info = TringupCallInfo(
          callId:      activeCall.callId,
          number:      activeCall.handle.value,
          displayName: activeCall.displayName,
          isIncoming:  activeCall.isIncoming,
          isConnected: activeCall.wasAccepted,
          isMuted:     activeCall.muted,
          isOnHold:    activeCall.held,
          connectedAt: activeCall.acceptedTime,
          audioOutput: _mapAudio(state.audioDevice),
          isVideoCall: false,
        );

        final actions = TringupCallActions(
          hangUp: () => callBloc.add(
            CallControlEvent.ended(activeCall.callId),
          ),
          setMuted: (muted) => callBloc.add(
            CallControlEvent.setMuted(activeCall.callId, muted),
          ),
          setSpeaker: (speakerOn) {
            final target = speakerOn
                ? state.availableAudioDevices.firstWhere(
                    (d) => d.type == CallAudioDeviceType.speaker,
                    orElse: () => state.availableAudioDevices.first,
                  )
                : state.availableAudioDevices.firstWhere(
                    (d) => d.type == CallAudioDeviceType.earpiece,
                    orElse: () => state.availableAudioDevices.first,
                  );
            callBloc.add(
              CallControlEvent.audioDeviceSet(activeCall.callId, target),
            );
          },
          setHeld: (onHold) => callBloc.add(
            CallControlEvent.setHeld(activeCall.callId, onHold),
          ),
          switchCamera:     () {},
          setCameraEnabled: (_) {},
          // Restores the full call screen.
          minimize: () => callBloc.add(const CallScreenEvent.didPush()),
          answer: activeCall.isIncoming && !activeCall.wasAccepted
              ? () => callBloc.add(CallControlEvent.answered(activeCall.callId))
              : null,
        );

        Widget banner = widget.builder != null
            ? widget.builder!(context, info, actions)
            : _DefaultAudioBanner(info: info, actions: actions);

        // When placed at y=0 in the screen (via TringupAudioCallBannerScope),
        // add the status-bar height as top padding so banner content appears
        // below the system status bar, not behind it.  extraTopPadding adds
        // additional offset on top of the system inset.
        final topInset = widget.topSafeArea
            ? MediaQuery.of(context).padding.top
            : 0.0;
        final totalTop = topInset + widget.extraTopPadding;
        if (totalTop > 0) {
          banner = Padding(
            padding: EdgeInsets.only(top: totalTop),
            child: banner,
          );
        }
        return banner;
      },
    );
  }
}

// ---------------------------------------------------------------------------
// _DefaultAudioBanner — built-in dark banner
// ---------------------------------------------------------------------------

class _DefaultAudioBanner extends StatelessWidget {
  const _DefaultAudioBanner({required this.info, required this.actions});

  final TringupCallInfo    info;
  final TringupCallActions actions;

  String get _statusLabel {
    if (info.isConnected && info.connectedAt != null) {
      final elapsed = DateTime.now().difference(info.connectedAt!);
      final h = elapsed.inHours;
      final m = elapsed.inMinutes.remainder(60).toString().padLeft(2, '0');
      final s = elapsed.inSeconds.remainder(60).toString().padLeft(2, '0');
      return h > 0 ? '$h:$m:$s' : '$m:$s';
    }
    if (info.isIncoming && !info.isConnected) return 'Incoming call';
    return 'Calling…';
  }

  @override
  Widget build(BuildContext context) {
    return Material(
      color: const Color(0xFF0D1F2D),
      child: InkWell(
        onTap: actions.minimize,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
          child: Row(
            children: [
              const Icon(Icons.phone_in_talk,
                  color: Colors.greenAccent, size: 20),
              const SizedBox(width: 10),

              // Caller name + status / timer
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      info.callerLabel,
                      style: const TextStyle(
                        color: Colors.white,
                        fontSize: 14,
                        fontWeight: FontWeight.w600,
                      ),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                    Text(
                      _statusLabel,
                      style: TextStyle(
                        color: info.isConnected
                            ? Colors.greenAccent
                            : Colors.white54,
                        fontSize: 12,
                      ),
                    ),
                  ],
                ),
              ),

              // Answer (incoming ringing only)
              if (actions.answer != null)
                IconButton(
                  icon: const Icon(Icons.call, color: Colors.green, size: 20),
                  onPressed: actions.answer,
                  visualDensity: VisualDensity.compact,
                ),

              // Mute (connected only)
              if (info.isConnected)
                IconButton(
                  icon: Icon(
                    info.isMuted ? Icons.mic_off : Icons.mic,
                    color: info.isMuted ? Colors.white : Colors.white70,
                    size: 20,
                  ),
                  onPressed: () => actions.setMuted(!info.isMuted),
                  visualDensity: VisualDensity.compact,
                ),

              // Hang-up
              IconButton(
                icon: const Icon(Icons.call_end, color: Colors.red, size: 20),
                onPressed: actions.hangUp,
                visualDensity: VisualDensity.compact,
              ),
            ],
          ),
        ),
      ),
    );
  }
}

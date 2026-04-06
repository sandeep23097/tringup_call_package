import 'package:flutter/material.dart';

import 'package:flutter_bloc/flutter_bloc.dart';

import 'package:webtrit_phone/app/keys.dart';
import 'package:webtrit_phone/models/models.dart';
import 'package:webtrit_phone/theme/theme.dart';
import 'package:webtrit_phone/widgets/widgets.dart';

import '../call.dart';

class CallActiveScaffold extends StatefulWidget {
  const CallActiveScaffold({
    super.key,
    required this.callStatus,
    required this.activeCalls,
    required this.audioDevice,
    required this.availableAudioDevices,
    required this.callConfig,
    required this.localePlaceholderBuilder,
    required this.remotePlaceholderBuilder,
  });

  final CallStatus callStatus;
  final List<ActiveCall> activeCalls;
  final CallAudioDevice? audioDevice;
  final List<CallAudioDevice> availableAudioDevices;
  final CallConfig callConfig;
  final WidgetBuilder? localePlaceholderBuilder;
  final WidgetBuilder? remotePlaceholderBuilder;

  @override
  CallActiveScaffoldState createState() => CallActiveScaffoldState();
}

class CallActiveScaffoldState extends State<CallActiveScaffold> {
  bool compact = false;

  @override
  Widget build(BuildContext context) {
    final activeCalls = widget.activeCalls;
    final activeCall = activeCalls.current;
    final heldCalls = activeCalls.nonCurrent;

    final activeTransfer = activeCall.transfer;

    final themeData = Theme.of(context);
    final Gradients? gradients = themeData.extension<Gradients>();
    final onTabGradient = themeData.colorScheme.surface;
    final textTheme = themeData.textTheme;
    final switchCameraIconSize = textTheme.titleMedium!.fontSize!;
    final MediaQueryData mediaQueryData = MediaQuery.of(context);

    final style = themeData.extension<CallScreenStyles>()?.primary;

    // ── Conference / group call detection ─────────────────────────────────────
    final callBloc = context.read<CallBloc>();
    // For unified-flow calls participants live on activeCall directly;
    // for legacy conference calls fall back to the BLoC getter.
    final conferenceParticipants = activeCall.conferenceParticipants.isNotEmpty
        ? activeCall.conferenceParticipants
        : callBloc.getConferenceParticipants(activeCall.callId);
    // Show audio group UI when this is a group call AND neither side has video active
    // yet. Once the local camera is enabled the UI automatically transitions to
    // the regular video layout.
    final isAudioGroupCall = conferenceParticipants.isNotEmpty && !activeCall.remoteVideo && !activeCall.cameraEnabled;

    // ── Shared CallActions builder (used in both layouts) ─────────────────────
    // Defined as a local function so it captures all the local variables from
    // this build() call without needing to duplicate 25+ parameter list twice.
    Widget buildCallActions() => CallActions(
      style: style?.actions,
      enableInteractions: widget.callStatus == CallStatus.ready,
      isIncoming: activeCall.isIncoming,
      remoteVideo: activeCall.remoteVideo,
      wasAccepted: activeCall.wasAccepted,
      wasHungUp: activeCall.wasHungUp,
      cameraValue: activeCall.cameraEnabled,
      inviteToAttendedTransfer: activeTransfer is InviteToAttendedTransfer,
      onCameraChanged: widget.callConfig.isVideoCallEnabled
          ? (bool value) {
              context.read<CallBloc>().add(CallControlEvent.cameraEnabled(activeCall.callId, value));
              setState(() {});
            }
          : null,
      mutedValue: activeCall.muted,
      onMutedChanged: (bool value) {
        context.read<CallBloc>().add(CallControlEvent.setMuted(activeCall.callId, value));
        setState(() {});
      },
      audioDevice: widget.audioDevice,
      availableAudioDevices: widget.availableAudioDevices,
      onAudioDeviceChanged: (CallAudioDevice device) {
        context.read<CallBloc>().add(CallControlEvent.audioDeviceSet(activeCall.callId, device));
      },
      transferableCalls: heldCalls,
      onBlindTransferInitiated: widget.callConfig.isBlindTransferEnabled
          ? (!activeCall.wasAccepted || activeTransfer != null
                ? null
                : () {
                    context.read<CallBloc>().add(CallControlEvent.blindTransferInitiated(activeCall.callId));
                  })
          : null,
      onAttendedTransferInitiated: widget.callConfig.isAttendedTransferEnabled
          ? (!activeCall.wasAccepted || activeTransfer != null
                ? null
                : () {
                    context.read<CallBloc>().add(CallControlEvent.attendedTransferInitiated(activeCall.callId));
                  })
          : null,
      onAttendedTransferSubmitted: widget.callConfig.isAttendedTransferEnabled
          ? (!activeCall.wasAccepted || activeTransfer != null
                ? null
                : (ActiveCall referorCall) {
                    context.read<CallBloc>().add(
                      CallControlEvent.attendedTransferSubmitted(referorCall: referorCall, replaceCall: activeCall),
                    );
                  })
          : null,
      heldValue: activeCall.held,
      onHeldChanged: (bool value) {
        context.read<CallBloc>().add(CallControlEvent.setHeld(activeCall.callId, value));
      },
      onSwapPressed: activeCalls.length == 2
          ? () {
              context.read<CallBloc>().add(CallControlEvent.setHeld(activeCall.callId, true));
              for (final otherActiveCall in activeCalls) {
                if (otherActiveCall.callId != activeCall.callId) {
                  context.read<CallBloc>().add(CallControlEvent.setHeld(otherActiveCall.callId, false));
                }
              }
            }
          : null,
      onHangupPressed: () {
        context.read<CallBloc>().add(CallControlEvent.ended(activeCall.callId));
      },
      onHangupAndAcceptPressed: activeCalls.length > 1
          ? () {
              for (final otherActiveCall in activeCalls) {
                if (otherActiveCall.callId != activeCall.callId) {
                  context.read<CallBloc>().add(CallControlEvent.ended(otherActiveCall.callId));
                }
              }
              context.read<CallBloc>().add(CallControlEvent.answered(activeCall.callId));
            }
          : null,
      onHoldAndAcceptPressed: activeCalls.length > 1
          ? () {
              for (final otherActiveCall in activeCalls) {
                if (otherActiveCall.callId != activeCall.callId) {
                  context.read<CallBloc>().add(CallControlEvent.setHeld(otherActiveCall.callId, true));
                }
              }
              context.read<CallBloc>().add(CallControlEvent.answered(activeCall.callId));
            }
          : null,
      onAcceptPressed: () {
        context.read<CallBloc>().add(CallControlEvent.answered(activeCall.callId));
      },
      onApproveTransferPressed: activeTransfer is AttendedTransferConfirmationRequested
          ? () {
              context.read<CallBloc>().add(
                CallControlEvent.attendedRequestApproved(
                  referId: activeTransfer.referId,
                  referTo: activeTransfer.referTo,
                ),
              );
            }
          : null,
      onDeclineTransferPressed: activeTransfer is AttendedTransferConfirmationRequested
          ? () {
              context.read<CallBloc>().add(
                CallControlEvent.attendedRequestDeclined(callId: activeCall.callId, referId: activeTransfer.referId),
              );
            }
          : null,
      onKeyPressed: (value) {
        context.read<CallBloc>().add(CallControlEvent.sentDTMF(activeCall.callId, value));
      },
      groupCallEnabled: callBloc.groupCallEnabled,
      onAddParticipantPressed: activeCall.wasAccepted
          ? () => _showAddParticipantDialog(context, activeCall.callId)
          : null,
    );

    return Scaffold(
      body: OrientationBuilder(
        builder: (context, orientation) {
          return Container(
            decoration: BoxDecoration(gradient: gradients?.tab),
            child: Stack(
              children: [
                // ── Remote video (full-screen, video calls only) ──────────────
                if (activeCall.remoteVideo)
                  Positioned(
                    left: 0,
                    right: 0,
                    top: 0,
                    bottom: 0,
                    child: GestureDetector(
                      onTap: activeCall.wasAccepted ? _compactSwitched : null,
                      behavior: HitTestBehavior.translucent,
                      child: SizedBox(
                        width: mediaQueryData.size.width,
                        height: mediaQueryData.size.height,
                        child: RTCStreamView(
                          stream: activeCall.remoteStream,
                          placeholderBuilder: widget.remotePlaceholderBuilder,
                        ),
                      ),
                    ),
                  ),
                // ── Local camera PiP (video calls only) ──────────────────────
                if (activeCall.localVideo)
                  AnimatedPositioned(
                    right: 10 + mediaQueryData.padding.right,
                    top: 10 + mediaQueryData.padding.top + (compact ? 0 : 100),

                    duration: kThemeChangeDuration,
                    child: GestureDetector(
                      onTap: activeCall.frontCamera == null
                          ? null
                          : () {
                              context.read<CallBloc>().add(CallControlEvent.cameraSwitched(activeCall.callId));
                            },
                      child: Stack(
                        children: [
                          Builder(
                            builder: (context) {
                              final videoTrack = activeCall.localStream?.getVideoTracks().first;
                              final videoWidth = videoTrack?.getSettings()['width'] ?? 1080;
                              final videoHeight = videoTrack?.getSettings()['height'] ?? 720;

                              final aspectRatio = videoWidth / videoHeight;
                              const smallerSide = 90.0;
                              final biggerSide = smallerSide * aspectRatio;

                              final frameWidth = orientation == Orientation.portrait ? smallerSide : biggerSide;
                              final frameHeight = orientation == Orientation.portrait ? biggerSide : smallerSide;

                              return Container(
                                decoration: BoxDecoration(color: onTabGradient.withValues(alpha: 0.3)),
                                width: frameWidth,
                                height: frameHeight,
                                child: activeCall.frontCamera == null
                                    ? null
                                    : RTCStreamView(
                                        key: callFrontCameraPreviewKey,
                                        stream: activeCall.localStream,
                                        mirror: activeCall.frontCamera!,
                                        placeholderBuilder: widget.localePlaceholderBuilder,
                                      ),
                              );
                            },
                          ),
                          Positioned(
                            left: 0,
                            right: 0,
                            bottom: 1,
                            child: activeCall.frontCamera == null
                                ? SizedCircularProgressIndicator(
                                    size: switchCameraIconSize - 2.0,
                                    outerSize: switchCameraIconSize,
                                    color: onTabGradient,
                                    strokeWidth: 2.0,
                                  )
                                : Icon(Icons.switch_camera, size: switchCameraIconSize, color: onTabGradient),
                          ),
                        ],
                      ),
                    ),
                  ),

                // ── Overlay UI (hidden when compact / full-screen video tapped) ──
                if (!compact)
                  Positioned.fill(
                    left: mediaQueryData.padding.left,
                    right: mediaQueryData.padding.right,
                    top: mediaQueryData.padding.top,
                    bottom: mediaQueryData.padding.bottom,
                    child: Column(
                      children: [
                        AppBar(
                          leading: style?.appBar?.showBackButton == false ? null : const ExtBackButton(),
                          backgroundColor: style?.appBar?.backgroundColor,
                          foregroundColor: style?.appBar?.foregroundColor,
                          primary: style?.appBar?.primary ?? false,
                        ),

                        // ── Audio group call: participant grid layout ─────────
                        if (isAudioGroupCall) ...[
                          Expanded(
                            child: Column(
                              children: [
                                // Compact call-info header: group name or handle + timer
                                CallInfo(
                                  transfering: activeTransfer is Transfering,
                                  requestToAttendedTransfer: false,
                                  inviteToAttendedTransfer: activeTransfer is InviteToAttendedTransfer,
                                  isIncoming: activeCall.isIncoming,
                                  held: activeCall.held,
                                  number: activeCall.handle.value,
                                  username:
                                      callBloc.getConferenceGroupName(activeCall.callId) ?? activeCall.displayName,
                                  acceptedTime: activeCall.acceptedTime,
                                  style: style?.callInfo,
                                  processingStatus: activeCall.processingStatus,
                                  callStatus: widget.callStatus,
                                ),
                                // Participant tiles
                                Expanded(child: _GroupAudioParticipantGrid(participants: conferenceParticipants)),
                              ],
                            ),
                          ),
                          // Controls sit outside the Expanded so they don't get squished
                          buildCallActions(),
                          const SizedBox(height: 20),
                        ]
                        // ── Video call / regular 1-on-1 audio call layout ─────
                        else ...[
                          Expanded(
                            child: LayoutBuilder(
                              builder: (context, constraints) {
                                return FittedBox(
                                  child: ConstrainedBox(
                                    constraints: BoxConstraints(
                                      maxWidth: constraints.maxWidth,
                                      minHeight: constraints.minHeight,
                                    ),
                                    child: Column(
                                      mainAxisAlignment: MainAxisAlignment.spaceBetween,
                                      children: [
                                        for (final ac in activeCalls)
                                          CallInfo(
                                            transfering: activeTransfer is Transfering,
                                            requestToAttendedTransfer: false,
                                            inviteToAttendedTransfer: activeTransfer is InviteToAttendedTransfer,
                                            isIncoming: ac.isIncoming,
                                            held: ac.held,
                                            number: ac.handle.value,
                                            username: ac.displayName,
                                            acceptedTime: ac.acceptedTime,
                                            style: style?.callInfo,
                                            processingStatus: ac.processingStatus,
                                            callStatus: widget.callStatus,
                                          ),
                                        if (activeTransfer is AttendedTransferConfirmationRequested)
                                          CallInfo(
                                            transfering: false,
                                            requestToAttendedTransfer: true,
                                            inviteToAttendedTransfer: false,
                                            isIncoming: false,
                                            held: false,
                                            number: activeCall.handle.value,
                                            username: activeCall.displayName,
                                            style: style?.callInfo,
                                            callStatus: widget.callStatus,
                                          ),
                                        buildCallActions(),
                                      ],
                                    ),
                                  ),
                                );
                              },
                            ),
                          ),
                          const SizedBox(height: 20),
                        ],
                      ],
                    ),
                  ),
              ],
            ),
          );
        },
      ),
    );
  }

  void _compactSwitched() {
    setState(() {
      compact = !compact;
    });
  }

  Future<void> _showAddParticipantDialog(BuildContext context, String callId) async {
    final number = await showDialog<String>(context: context, builder: (ctx) => const _AddParticipantDialog());
    if (number != null && number.isNotEmpty && context.mounted) {
      context.read<CallBloc>().add(CallControlEvent.addParticipant(callId, number));
    }
  }
}

// ── Group audio participant grid ───────────────────────────────────────────────

class _GroupAudioParticipantGrid extends StatelessWidget {
  const _GroupAudioParticipantGrid({required this.participants});

  final List<ConferenceParticipant> participants;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 16),
        child: Wrap(
          spacing: 28,
          runSpacing: 28,
          alignment: WrapAlignment.center,
          crossAxisAlignment: WrapCrossAlignment.center,
          children: [
            for (final p in participants) _ParticipantTile(participant: p),
            // "You" tile for the local user
            const _ParticipantTile(isLocal: true),
          ],
        ),
      ),
    );
  }
}

class _ParticipantTile extends StatelessWidget {
  const _ParticipantTile({this.participant, this.isLocal = false});

  final ConferenceParticipant? participant;
  final bool isLocal;

  @override
  Widget build(BuildContext context) {
    final name = isLocal ? 'You' : (participant!.displayName ?? participant!.userId);
    final initials = _initials(name);
    final color = _avatarColor(isLocal ? 'local' : participant!.userId);

    return SizedBox(
      width: 80,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(
            width: 64,
            height: 64,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              color: color,
              border: isLocal ? Border.all(color: Colors.white.withValues(alpha: 0.6), width: 2) : null,
            ),
            child: Center(
              child: Text(
                initials,
                style: const TextStyle(color: Colors.white, fontSize: 22, fontWeight: FontWeight.bold),
              ),
            ),
          ),
          const SizedBox(height: 8),
          Text(
            name,
            style: TextStyle(
              color: Colors.white.withValues(alpha: isLocal ? 0.7 : 1.0),
              fontSize: 12,
              fontStyle: isLocal ? FontStyle.italic : FontStyle.normal,
            ),
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            textAlign: TextAlign.center,
          ),
        ],
      ),
    );
  }

  static String _initials(String name) {
    final parts = name.trim().split(RegExp(r'\s+'));
    if (parts.length >= 2) return '${parts[0][0]}${parts[1][0]}'.toUpperCase();
    if (parts[0].length >= 2) return '${parts[0][0]}${parts[0][1]}'.toUpperCase();
    return parts[0][0].toUpperCase();
  }

  static Color _avatarColor(String id) {
    const colors = [
      Color(0xFF1565C0),
      Color(0xFF6A1B9A),
      Color(0xFF00695C),
      Color(0xFF4E342E),
      Color(0xFF37474F),
      Color(0xFF880E4F),
    ];
    return colors[id.hashCode.abs() % colors.length];
  }
}

// ── Add participant dialog ─────────────────────────────────────────────────────

/// Dialog that owns its own [TextEditingController] so disposal happens
/// after the dismiss animation fully completes (via [State.dispose]).
class _AddParticipantDialog extends StatefulWidget {
  const _AddParticipantDialog();

  @override
  State<_AddParticipantDialog> createState() => _AddParticipantDialogState();
}

class _AddParticipantDialogState extends State<_AddParticipantDialog> {
  late final TextEditingController _controller = TextEditingController();

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('Add participant'),
      content: TextField(
        controller: _controller,
        keyboardType: TextInputType.phone,
        autofocus: true,
        decoration: const InputDecoration(hintText: 'Phone number or extension'),
        onSubmitted: (value) => Navigator.of(context).pop(value.trim()),
      ),
      actions: [
        TextButton(onPressed: () => Navigator.of(context).pop(null), child: const Text('Cancel')),
        TextButton(onPressed: () => Navigator.of(context).pop(_controller.text.trim()), child: const Text('Add')),
      ],
    );
  }
}

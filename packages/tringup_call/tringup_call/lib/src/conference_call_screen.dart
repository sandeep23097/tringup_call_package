import 'dart:async';
import 'dart:io';
import 'dart:math' as math;
import 'dart:ui' show ImageFilter;

import 'package:flutter/material.dart';
import 'package:livekit_client/livekit_client.dart' as lk;

import 'conference_video_grid.dart';
import 'tringup_call_screen_api.dart';

// ── Helpers ───────────────────────────────────────────────────────────────────

/// Returns a deterministic accent color for an avatar based on the seed string.
Color _avatarColor(String seed) {
  const palette = [
    Color(0xFF5C6BC0), // indigo
    Color(0xFF26A69A), // teal
    Color(0xFF7E57C2), // purple
    Color(0xFF42A5F5), // blue
    Color(0xFFEC407A), // pink
    Color(0xFF66BB6A), // green
    Color(0xFFFF7043), // orange
    Color(0xFF26C6DA), // cyan
  ];
  return palette[seed.hashCode.abs() % palette.length];
}

// ── Main screen ───────────────────────────────────────────────────────────────

/// Full-screen group call UI.
///
/// Handles both audio-only and video group calls. The UI adapts:
/// - Audio: dark gradient background, large participant cards, always-visible controls.
/// - Video: black background, full-screen video grid, auto-hiding header/controls.
class ConferenceCallScreen extends StatefulWidget {
  const ConferenceCallScreen({
    super.key,
    required this.info,
    required this.actions,
    this.room,
  });

  final TringupCallInfo info;
  final TringupCallActions actions;

  /// LiveKit room — null until connected.
  final lk.Room? room;

  @override
  State<ConferenceCallScreen> createState() => _ConferenceCallScreenState();
}

class _ConferenceCallScreenState extends State<ConferenceCallScreen>
    with SingleTickerProviderStateMixin {
  Timer? _durationTimer;
  Duration _elapsed = Duration.zero;

  // For video calls: auto-hide controls after a few seconds of inactivity.
  bool _controlsVisible = true;
  Timer? _hideTimer;

  // Shared pulse animation (used in connecting state, ringing avatars).
  late AnimationController _pulseCtrl;

  @override
  void initState() {
    super.initState();
    _pulseCtrl = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1400),
    )..repeat(reverse: true);

    _startDurationTimer();
    if (_isVideoMode) _scheduleHideControls();
  }

  @override
  void didUpdateWidget(ConferenceCallScreen old) {
    super.didUpdateWidget(old);
    if (widget.info.connectedAt != old.info.connectedAt &&
        widget.info.connectedAt != null) {
      _startDurationTimer();
    }
  }

  // Use the LiveKit room as the single source of truth.
  // widget.info.isVideoCall can be false on the receiver side when the
  // conference_invite event doesn't carry the video flag, even though the
  // room is active and participants are sending video.  Whenever the room
  // is connected, route to ConferenceVideoGrid (which shows avatars when
  // cameras are off — correct for audio group calls too).
  bool get _isVideoMode => widget.room != null;

  void _startDurationTimer() {
    _durationTimer?.cancel();
    final connected = widget.info.connectedAt;
    if (connected != null) {
      _elapsed = DateTime.now().difference(connected);
      _durationTimer = Timer.periodic(const Duration(seconds: 1), (_) {
        if (mounted) {
          setState(() {
            _elapsed = DateTime.now().difference(widget.info.connectedAt!);
          });
        }
      });
    }
  }

  void _scheduleHideControls() {
    _hideTimer?.cancel();
    _hideTimer = Timer(const Duration(seconds: 4), () {
      if (mounted) setState(() => _controlsVisible = false);
    });
  }

  void _onScreenTap() {
    if (!_isVideoMode) return;
    setState(() => _controlsVisible = !_controlsVisible);
    if (_controlsVisible) _scheduleHideControls();
  }

  @override
  void dispose() {
    _durationTimer?.cancel();
    _hideTimer?.cancel();
    _pulseCtrl.dispose();
    super.dispose();
  }

  String get _durationLabel {
    final h = _elapsed.inHours;
    final m = _elapsed.inMinutes.remainder(60).toString().padLeft(2, '0');
    final s = _elapsed.inSeconds.remainder(60).toString().padLeft(2, '0');
    return h > 0 ? '$h:$m:$s' : '$m:$s';
  }

  @override
  Widget build(BuildContext context) {
    const groupName = 'Group Call';
    const String? groupPhotoUrl = null;
    final remoteCount = widget.room?.remoteParticipants.length ?? 0;
    final participantCount = remoteCount + 1; // include self

    Widget body;
    if (_isVideoMode) {
      print("cccccccccc1");
      body = ConferenceVideoGrid(
        room: widget.room!,
        localVideoEnabled: widget.info.isCameraEnabled,
        participants: widget.info.participants,
        onSwitchCamera: widget.actions.switchCamera,
        callType: widget.info.isVideoCall ? CallType.video : CallType.audio,

      );
    } else {
      print("cccccccccc2");
      body = _AudioBody(
        participants: widget.info.participants,
        ringingUserIds: widget.info.ringingUserIds,
        groupName: groupName,
        groupPhotoUrl: groupPhotoUrl,
        isConnected: widget.info.isConnected,
        pulseCtrl: _pulseCtrl,
      );
    }

    return Scaffold(
      backgroundColor: Colors.black,
      body: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: _onScreenTap,
        child: Stack(
          fit: StackFit.expand,
          children: [
            // Background — gradient for audio, pure black for video
            if (!_isVideoMode) const _GradientBackground(),

            SafeArea(
              child: Column(
                children: [
                  // ── Header ──────────────────────────────────────────────
                  _AnimatedOverlay(
                    visible: !_isVideoMode || _controlsVisible,
                    child: _Header(
                      groupName: groupName,
                      groupPhotoUrl: groupPhotoUrl,
                      durationLabel: widget.info.isConnected ? _durationLabel : null,
                      participantCount: participantCount,
                      isConnected: widget.info.isConnected,
                      onMinimize: widget.actions.minimize,
                      pulseCtrl: _pulseCtrl,
                    ),
                  ),

                  // ── Body ────────────────────────────────────────────────
                  Expanded(child: body),

                  // ── Controls ────────────────────────────────────────────
                  _AnimatedOverlay(
                    visible: !_isVideoMode || _controlsVisible,
                    child: _Controls(
                      info: widget.info,
                      actions: widget.actions,
                      isVideoMode: _isVideoMode,
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

// ── Animated overlay (fade in/out) ────────────────────────────────────────────

class _AnimatedOverlay extends StatelessWidget {
  const _AnimatedOverlay({required this.visible, required this.child});
  final bool visible;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    return AnimatedOpacity(
      opacity: visible ? 1.0 : 0.0,
      duration: const Duration(milliseconds: 280),
      child: IgnorePointer(ignoring: !visible, child: child),
    );
  }
}

// ── Gradient background ───────────────────────────────────────────────────────

class _GradientBackground extends StatelessWidget {
  const _GradientBackground();

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: const BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [Color(0xFF0D1B2A), Color(0xFF172032), Color(0xFF0A1520)],
          stops: [0.0, 0.55, 1.0],
        ),
      ),
    );
  }
}

// ── Header ────────────────────────────────────────────────────────────────────

class _Header extends StatelessWidget {
  const _Header({
    required this.groupName,
    required this.groupPhotoUrl,
    required this.durationLabel,
    required this.participantCount,
    required this.isConnected,
    required this.onMinimize,
    required this.pulseCtrl,
  });

  final String groupName;
  final String? groupPhotoUrl;
  final String? durationLabel;
  final int participantCount;
  final bool isConnected;
  final VoidCallback onMinimize;
  final AnimationController pulseCtrl;

  @override
  Widget build(BuildContext context) {
    return ClipRect(
      child: BackdropFilter(
        filter: ImageFilter.blur(sigmaX: 12, sigmaY: 12),
        child: Container(
          padding: const EdgeInsets.fromLTRB(4, 6, 16, 12),
          decoration: BoxDecoration(
            gradient: LinearGradient(
              begin: Alignment.topCenter,
              end: Alignment.bottomCenter,
              colors: [
                Colors.black.withOpacity(0.75),
                Colors.black.withOpacity(0.3),
              ],
            ),
          ),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.center,
            children: [
              // Minimize button
              Material(
                color: Colors.transparent,
                child: InkWell(
                  onTap: onMinimize,
                  borderRadius: BorderRadius.circular(24),
                  child: const Padding(
                    padding: EdgeInsets.all(10),
                    child: Icon(
                      Icons.keyboard_arrow_down_rounded,
                      color: Colors.white,
                      size: 26,
                    ),
                  ),
                ),
              ),

              const SizedBox(width: 4),

              // Group info
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      groupName,
                      style: const TextStyle(
                        color: Colors.white,
                        fontSize: 17,
                        fontWeight: FontWeight.w700,
                        letterSpacing: -0.3,
                      ),
                      overflow: TextOverflow.ellipsis,
                    ),
                    const SizedBox(height: 3),
                    _HeaderSubtitle(
                      isConnected: isConnected,
                      participantCount: participantCount,
                      durationLabel: durationLabel,
                      pulseCtrl: pulseCtrl,
                    ),
                  ],
                ),
              ),

              const SizedBox(width: 12),

              // Group avatar
              _GroupAvatar(
                photoUrl: groupPhotoUrl,
                name: groupName,
                radius: 21,
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _HeaderSubtitle extends StatelessWidget {
  const _HeaderSubtitle({
    required this.isConnected,
    required this.participantCount,
    required this.durationLabel,
    required this.pulseCtrl,
  });

  final bool isConnected;
  final int participantCount;
  final String? durationLabel;
  final AnimationController pulseCtrl;

  @override
  Widget build(BuildContext context) {
    if (!isConnected) {
      return AnimatedBuilder(
        animation: pulseCtrl,
        builder: (_, __) => Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              width: 6,
              height: 6,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: const Color(0xFFFFD60A)
                    .withOpacity(0.45 + 0.55 * pulseCtrl.value),
              ),
            ),
            const SizedBox(width: 6),
            const Text(
              'Connecting…',
              style: TextStyle(color: Colors.white54, fontSize: 12),
            ),
          ],
        ),
      );
    }

    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        const Icon(Icons.people_outline_rounded,
            color: Colors.white38, size: 13),
        const SizedBox(width: 3),
        Text(
          '$participantCount',
          style: const TextStyle(color: Colors.white54, fontSize: 12),
        ),
        const SizedBox(width: 8),
        const Icon(Icons.access_time_rounded, color: Colors.white38, size: 13),
        const SizedBox(width: 3),
        Text(
          durationLabel ?? '00:00',
          style: const TextStyle(
            color: Colors.white70,
            fontSize: 12,
          ),
        ),
      ],
    );
  }
}

// ── Group avatar (photo or initials) ─────────────────────────────────────────

class _GroupAvatar extends StatelessWidget {
  const _GroupAvatar({
    required this.photoUrl,
    required this.name,
    required this.radius,
  });

  final String? photoUrl;
  final String name;
  final double radius;

  @override
  Widget build(BuildContext context) {
    return CircleAvatar(
      radius: radius,
      backgroundColor: const Color(0xFF2A3A4A),
      backgroundImage: photoUrl != null ? NetworkImage(photoUrl!) : null,
      child: photoUrl == null
          ? Icon(
              Icons.group_rounded,
              color: Colors.white70,
              size: radius * 0.9,
            )
          : null,
    );
  }
}

// ── Audio body ────────────────────────────────────────────────────────────────

class _AudioBody extends StatelessWidget {
  const _AudioBody({
    required this.participants,
    required this.ringingUserIds,
    required this.groupName,
    required this.groupPhotoUrl,
    required this.isConnected,
    required this.pulseCtrl,
  });

  final List<TringupParticipant> participants;
  final Set<String> ringingUserIds;
  final String groupName;
  final String? groupPhotoUrl;
  final bool isConnected;
  final AnimationController pulseCtrl;

  @override
  Widget build(BuildContext context) {
    if (!isConnected) {
      return _CallingState(
        groupName: groupName,
        groupPhotoUrl: groupPhotoUrl,
        participants: participants,
        ringingUserIds: ringingUserIds,
        pulseCtrl: pulseCtrl,
      );
    }
    if (participants.isEmpty) {
      return _WaitingState(
        groupPhotoUrl: groupPhotoUrl,
        groupName: groupName,
        pulseCtrl: pulseCtrl,
      );
    }
    return _ParticipantGrid(
      participants: participants,
      ringingUserIds: ringingUserIds,
    );
  }
}

// ── Calling state (pre-connect) ───────────────────────────────────────────────

class _CallingState extends StatelessWidget {
  const _CallingState({
    required this.groupName,
    required this.groupPhotoUrl,
    required this.participants,
    required this.ringingUserIds,
    required this.pulseCtrl,
  });

  final String groupName;
  final String? groupPhotoUrl;
  final List<TringupParticipant> participants;
  final Set<String> ringingUserIds;
  final AnimationController pulseCtrl;

  @override
  Widget build(BuildContext context) {
    final names = participants.isNotEmpty
        ? participants.map((p) => p.label).take(3).join(', ') +
            (participants.length > 3 ? '…' : '')
        : null;

    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          // Pulsing rings + large group avatar
          AnimatedBuilder(
            animation: pulseCtrl,
            builder: (_, child) {
              return SizedBox(
                width: 180,
                height: 180,
                child: Stack(
                  alignment: Alignment.center,
                  children: [
                    // Outermost ring
                    Transform.scale(
                      scale: 1.0 + 0.22 * pulseCtrl.value,
                      child: Container(
                        width: 110,
                        height: 110,
                        decoration: BoxDecoration(
                          shape: BoxShape.circle,
                          color: Colors.white.withOpacity(
                            0.04 * (1 - pulseCtrl.value),
                          ),
                        ),
                      ),
                    ),
                    // Middle ring
                    Transform.scale(
                      scale: 1.0 + 0.12 * pulseCtrl.value,
                      child: Container(
                        width: 110,
                        height: 110,
                        decoration: BoxDecoration(
                          shape: BoxShape.circle,
                          color: Colors.white.withOpacity(
                            0.07 * (1 - pulseCtrl.value * 0.6),
                          ),
                        ),
                      ),
                    ),
                    child!,
                  ],
                ),
              );
            },
            child: _GroupAvatar(
              photoUrl: groupPhotoUrl,
              name: groupName,
              radius: 55,
            ),
          ),

          const SizedBox(height: 28),

          Text(
            groupName,
            style: const TextStyle(
              color: Colors.white,
              fontSize: 26,
              fontWeight: FontWeight.w700,
              letterSpacing: -0.5,
            ),
            textAlign: TextAlign.center,
          ),

          const SizedBox(height: 8),

          Text(
            names != null ? 'Calling $names' : 'Calling…',
            style: const TextStyle(
              color: Colors.white54,
              fontSize: 15,
            ),
            textAlign: TextAlign.center,
          ),

          // Small avatar strip of who is ringing
          if (participants.isNotEmpty) ...[
            const SizedBox(height: 48),
            _MiniParticipantStrip(
              participants: participants,
              ringingUserIds: ringingUserIds,
            ),
          ],
        ],
      ),
    );
  }
}

// ── Waiting state (connected but no one joined yet) ───────────────────────────

class _WaitingState extends StatelessWidget {
  const _WaitingState({
    required this.groupPhotoUrl,
    required this.groupName,
    required this.pulseCtrl,
  });

  final String? groupPhotoUrl;
  final String groupName;
  final AnimationController pulseCtrl;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          _GroupAvatar(photoUrl: groupPhotoUrl, name: groupName, radius: 44),
          const SizedBox(height: 20),
          const Text(
            'Waiting for others to join…',
            style: TextStyle(color: Colors.white54, fontSize: 15),
          ),
          const SizedBox(height: 8),
          AnimatedBuilder(
            animation: pulseCtrl,
            builder: (_, __) => Row(
              mainAxisSize: MainAxisSize.min,
              children: List.generate(3, (i) {
                final delay = i / 3;
                final v = (pulseCtrl.value - delay).clamp(0.0, 1.0);
                return Container(
                  margin: const EdgeInsets.symmetric(horizontal: 3),
                  width: 7,
                  height: 7,
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    color: Colors.white.withOpacity(0.2 + 0.6 * v),
                  ),
                );
              }),
            ),
          ),
        ],
      ),
    );
  }
}

// ── Participant grid (connected, audio) ───────────────────────────────────────

class _ParticipantGrid extends StatelessWidget {
  const _ParticipantGrid({
    required this.participants,
    required this.ringingUserIds,
  });

  final List<TringupParticipant> participants;
  final Set<String> ringingUserIds;

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final w = constraints.maxWidth;
        final count = participants.length;

        // Adaptive column count
        final cols = count == 1
            ? 1
            : count <= 4
                ? 2
                : 3;
        final spacing = 12.0;
        final padding = 16.0;
        final tileWidth =
            (w - padding * 2 - spacing * (cols - 1)) / cols;

        // Single participant: show centered and a bit larger
        if (count == 1) {
          return Center(
            child: SizedBox(
              width: math.min(tileWidth, 220),
              child: _AudioParticipantCard(
                participant: participants.first,
                isRinging: ringingUserIds.contains(participants.first.userId),
              ),
            ),
          );
        }

        return SingleChildScrollView(
          padding: EdgeInsets.all(padding),
          child: Wrap(
            spacing: spacing,
            runSpacing: spacing,
            alignment: WrapAlignment.center,
            children: [
              for (final p in participants)
                SizedBox(
                  width: tileWidth,
                  child: _AudioParticipantCard(
                    participant: p,
                    isRinging: ringingUserIds.contains(p.userId),
                  ),
                ),
            ],
          ),
        );
      },
    );
  }
}

// ── Audio participant card ────────────────────────────────────────────────────

class _AudioParticipantCard extends StatefulWidget {
  const _AudioParticipantCard({
    required this.participant,
    required this.isRinging,
  });

  final TringupParticipant participant;
  final bool isRinging;

  @override
  State<_AudioParticipantCard> createState() => _AudioParticipantCardState();
}

class _AudioParticipantCardState extends State<_AudioParticipantCard>
    with SingleTickerProviderStateMixin {
  late AnimationController _ringCtrl;

  @override
  void initState() {
    super.initState();
    _ringCtrl = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1100),
    );
    if (widget.isRinging) _ringCtrl.repeat(reverse: true);
  }

  @override
  void didUpdateWidget(_AudioParticipantCard old) {
    super.didUpdateWidget(old);
    if (widget.isRinging != old.isRinging) {
      if (widget.isRinging) {
        _ringCtrl.repeat(reverse: true);
      } else {
        _ringCtrl
          ..stop()
          ..reset();
      }
    }
  }

  @override
  void dispose() {
    _ringCtrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final p = widget.participant;
    ImageProvider? photo;
    if (p.photoPath != null && p.photoPath!.isNotEmpty) {
      photo = FileImage(File(p.photoPath!));
    } else if (p.photoUrl != null && p.photoUrl!.isNotEmpty) {
      photo = NetworkImage(p.photoUrl!);
    }
    final name = p.label;
    final bgColor = _avatarColor(p.userId);
    final initial = name.isNotEmpty ? name[0].toUpperCase() : '?';

    return Container(
      padding: const EdgeInsets.symmetric(vertical: 20, horizontal: 10),
      decoration: BoxDecoration(
        color: Colors.white.withOpacity(0.06),
        borderRadius: BorderRadius.circular(20),
        border: Border.all(
          color: Colors.white.withOpacity(0.1),
          width: 1,
        ),
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          // Avatar with optional ringing pulse
          AnimatedBuilder(
            animation: _ringCtrl,
            builder: (_, child) {
              return Stack(
                alignment: Alignment.center,
                children: [
                  if (widget.isRinging) ...[
                    // Outer pulse ring
                    Container(
                      width: 72 * (1 + 0.35 * _ringCtrl.value),
                      height: 72 * (1 + 0.35 * _ringCtrl.value),
                      decoration: BoxDecoration(
                        shape: BoxShape.circle,
                        color: Colors.blueAccent.withOpacity(
                          0.12 * (1 - _ringCtrl.value),
                        ),
                      ),
                    ),
                    // Inner pulse ring
                    Container(
                      width: 72 * (1 + 0.18 * _ringCtrl.value),
                      height: 72 * (1 + 0.18 * _ringCtrl.value),
                      decoration: BoxDecoration(
                        shape: BoxShape.circle,
                        color: Colors.blueAccent.withOpacity(
                          0.2 * (1 - _ringCtrl.value * 0.7),
                        ),
                      ),
                    ),
                  ],
                  child!,
                ],
              );
            },
            child: CircleAvatar(
              radius: 36,
              backgroundColor: bgColor,
              backgroundImage: photo,
              child: photo == null
                  ? Text(
                      initial,
                      style: const TextStyle(
                        color: Colors.white,
                        fontSize: 26,
                        fontWeight: FontWeight.w600,
                      ),
                    )
                  : null,
            ),
          ),

          const SizedBox(height: 12),

          // Name
          Text(
            name,
            style: const TextStyle(
              color: Colors.white,
              fontSize: 13,
              fontWeight: FontWeight.w500,
            ),
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
            textAlign: TextAlign.center,
          ),

          const SizedBox(height: 6),

          // Status chip
          _ParticipantStatus(isRinging: widget.isRinging),
        ],
      ),
    );
  }
}

class _ParticipantStatus extends StatelessWidget {
  const _ParticipantStatus({required this.isRinging});
  final bool isRinging;

  @override
  Widget build(BuildContext context) {
    final color = isRinging ? const Color(0xFF4FA3E0) : const Color(0xFF34C759);
    final label = isRinging ? 'Ringing' : 'Connected';

    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Container(
          width: 5,
          height: 5,
          decoration: BoxDecoration(shape: BoxShape.circle, color: color),
        ),
        const SizedBox(width: 5),
        Text(label, style: TextStyle(color: color, fontSize: 11)),
      ],
    );
  }
}

// ── Mini participant strip (calling state) ────────────────────────────────────

class _MiniParticipantStrip extends StatelessWidget {
  const _MiniParticipantStrip({
    required this.participants,
    required this.ringingUserIds,
  });

  final List<TringupParticipant> participants;
  final Set<String> ringingUserIds;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      height: 80,
      child: ListView.builder(
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.symmetric(horizontal: 24),
        itemCount: participants.length,
        itemBuilder: (_, i) {
          final p = participants[i];
          ImageProvider? photo;
          if (p.photoPath != null && p.photoPath!.isNotEmpty) {
            photo = FileImage(File(p.photoPath!));
          } else if (p.photoUrl != null && p.photoUrl!.isNotEmpty) {
            photo = NetworkImage(p.photoUrl!);
          }
          final isRinging = ringingUserIds.contains(p.userId);
          final initial =
              p.label.isNotEmpty ? p.label[0].toUpperCase() : '?';

          return Padding(
            padding: const EdgeInsets.symmetric(horizontal: 10),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Stack(
                  alignment: Alignment.center,
                  children: [
                    CircleAvatar(
                      radius: 24,
                      backgroundColor: _avatarColor(p.userId),
                      backgroundImage: photo,
                      child: photo == null
                          ? Text(
                              initial,
                              style: const TextStyle(
                                color: Colors.white,
                                fontSize: 16,
                                fontWeight: FontWeight.w600,
                              ),
                            )
                          : null,
                    ),
                    if (isRinging)
                      Positioned(
                        bottom: 0,
                        right: 0,
                        child: Container(
                          width: 14,
                          height: 14,
                          decoration: BoxDecoration(
                            shape: BoxShape.circle,
                            color: const Color(0xFF4FA3E0),
                            border: Border.all(
                              color: const Color(0xFF0D1B2A),
                              width: 1.5,
                            ),
                          ),
                          child: const Icon(
                            Icons.phone_in_talk_rounded,
                            size: 8,
                            color: Colors.white,
                          ),
                        ),
                      ),
                  ],
                ),
                const SizedBox(height: 5),
                SizedBox(
                  width: 56,
                  child: Text(
                    p.label,
                    style: const TextStyle(color: Colors.white54, fontSize: 10),
                    overflow: TextOverflow.ellipsis,
                    textAlign: TextAlign.center,
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

// ── Bottom controls ───────────────────────────────────────────────────────────

class _Controls extends StatelessWidget {
  const _Controls({
    required this.info,
    required this.actions,
    required this.isVideoMode,
  });

  final TringupCallInfo info;
  final TringupCallActions actions;
  final bool isVideoMode;

  @override
  Widget build(BuildContext context) {
    final isSpeaker = info.audioOutput == TringupAudioOutput.speaker;

    return ClipRect(
      child: BackdropFilter(
        filter: ImageFilter.blur(sigmaX: 12, sigmaY: 12),
        child: Container(
          padding: const EdgeInsets.fromLTRB(8, 16, 8, 20),
          decoration: BoxDecoration(
            gradient: LinearGradient(
              begin: Alignment.bottomCenter,
              end: Alignment.topCenter,
              colors: [
                Colors.black.withOpacity(0.85),
                Colors.black.withOpacity(0.4),
              ],
            ),
          ),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.spaceEvenly,
            children: [
              // Mute
              _ControlButton(
                icon: info.isMuted
                    ? Icons.mic_off_rounded
                    : Icons.mic_rounded,
                label: info.isMuted ? 'Unmute' : 'Mute',
                active: info.isMuted,
                activeColor: const Color(0xFFFF453A),
                onTap: () => actions.setMuted(!info.isMuted),
              ),

              // Speaker
              _ControlButton(
                icon: _speakerIcon(info.audioOutput),
                label: 'Speaker',
                active: isSpeaker,
                activeColor: const Color(0xFF30D158),
                onTap: () => actions.setSpeaker(!isSpeaker),
              ),

              // Camera toggle (video only)
              if (isVideoMode)
                _ControlButton(
                  icon: info.isCameraEnabled
                      ? Icons.videocam_rounded
                      : Icons.videocam_off_rounded,
                  label: info.isCameraEnabled ? 'Camera' : 'Cam Off',
                  active: !info.isCameraEnabled,
                  activeColor: const Color(0xFFFF453A),
                  onTap: () =>
                      actions.setCameraEnabled(!info.isCameraEnabled),
                ),

              // Switch camera (video only)
              if (isVideoMode && info.isCameraEnabled)
                _ControlButton(
                  icon: Icons.flip_camera_ios_rounded,
                  label: 'Flip',
                  onTap: actions.switchCamera,
                ),

              // Add participant
              if (info.isGroupCallEnabled && actions.addParticipant != null)
                _ControlButton(
                  icon: Icons.person_add_rounded,
                  label: 'Add',
                  onTap: () => _showAddParticipantSheet(context),
                ),

              // End call
              _ControlButton(
                icon: Icons.call_end_rounded,
                label: 'Leave',
                backgroundColor: const Color(0xFFE03131),
                onTap: actions.hangUp,
              ),
            ],
          ),
        ),
      ),
    );
  }

  IconData _speakerIcon(TringupAudioOutput output) {
    switch (output) {
      case TringupAudioOutput.bluetooth:
        return Icons.bluetooth_audio_rounded;
      case TringupAudioOutput.wired:
        return Icons.headset_rounded;
      case TringupAudioOutput.speaker:
        return Icons.volume_up_rounded;
      case TringupAudioOutput.earpiece:
        return Icons.phone_in_talk_rounded;
    }
  }

  void _showAddParticipantSheet(BuildContext context) {
    showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (ctx) => _AddParticipantSheet(
        addableParticipants: info.addableParticipants,
        onAdd: actions.addParticipant!,
      ),
    );
  }
}

// ── Control button ─────────────────────────────────────────────────────────────

class _ControlButton extends StatelessWidget {
  const _ControlButton({
    required this.icon,
    required this.label,
    required this.onTap,
    this.active = false,
    this.activeColor,
    this.backgroundColor,
  });

  final IconData icon;
  final String label;
  final VoidCallback onTap;
  final bool active;
  final Color? activeColor;
  final Color? backgroundColor;

  @override
  Widget build(BuildContext context) {
    final resolvedBg = backgroundColor ??
        (active
            ? (activeColor ?? Colors.white).withOpacity(0.2)
            : Colors.white.withOpacity(0.12));

    final iconColor = backgroundColor != null
        ? Colors.white
        : (active ? (activeColor ?? Colors.white) : Colors.white);

    return GestureDetector(
      onTap: onTap,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          AnimatedContainer(
            duration: const Duration(milliseconds: 200),
            width: 54,
            height: 54,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              color: resolvedBg,
              border: Border.all(
                color: backgroundColor != null
                    ? Colors.transparent
                    : Colors.white.withOpacity(active ? 0.3 : 0.1),
                width: 1,
              ),
              boxShadow: backgroundColor != null
                  ? [
                      BoxShadow(
                        color: backgroundColor!.withOpacity(0.4),
                        blurRadius: 12,
                        offset: const Offset(0, 4),
                      ),
                    ]
                  : null,
            ),
            child: Icon(icon, color: iconColor, size: 24),
          ),
          const SizedBox(height: 6),
          Text(
            label,
            style: TextStyle(
              color: backgroundColor != null
                  ? Colors.white
                  : (active ? (activeColor ?? Colors.white) : Colors.white70),
              fontSize: 11,
              fontWeight:
                  active ? FontWeight.w600 : FontWeight.normal,
            ),
          ),
        ],
      ),
    );
  }
}

// ── Add participant bottom sheet ──────────────────────────────────────────────

class _AddParticipantSheet extends StatefulWidget {
  const _AddParticipantSheet({
    required this.addableParticipants,
    required this.onAdd,
  });

  final List<TringupParticipant> addableParticipants;
  final void Function(String number) onAdd;

  @override
  State<_AddParticipantSheet> createState() => _AddParticipantSheetState();
}

class _AddParticipantSheetState extends State<_AddParticipantSheet> {
  final _controller = TextEditingController();
  String _query = '';

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  List<TringupParticipant> get _filtered {
    if (_query.isEmpty) return widget.addableParticipants;
    final q = _query.toLowerCase();
    return widget.addableParticipants
        .where((p) =>
            p.label.toLowerCase().contains(q) ||
            (p.phoneNumber?.contains(q) ?? false))
        .toList();
  }

  @override
  Widget build(BuildContext context) {
    final bottomInset = MediaQuery.of(context).viewInsets.bottom;
    final showContactList = widget.addableParticipants.isNotEmpty;

    return Container(
      margin: EdgeInsets.only(bottom: bottomInset),
      decoration: const BoxDecoration(
        color: Color(0xFF1C2333),
        borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          // Handle
          const SizedBox(height: 10),
          Container(
            width: 36,
            height: 4,
            decoration: BoxDecoration(
              color: Colors.white24,
              borderRadius: BorderRadius.circular(2),
            ),
          ),
          const SizedBox(height: 16),

          // Title
          const Padding(
            padding: EdgeInsets.symmetric(horizontal: 20),
            child: Row(
              children: [
                Icon(Icons.person_add_rounded,
                    color: Colors.white70, size: 20),
                SizedBox(width: 10),
                Text(
                  'Add Participant',
                  style: TextStyle(
                    color: Colors.white,
                    fontSize: 18,
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: 16),

          // Search / phone number input
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16),
            child: TextField(
              controller: _controller,
              autofocus: !showContactList,
              keyboardType: showContactList
                  ? TextInputType.text
                  : TextInputType.phone,
              style: const TextStyle(color: Colors.white, fontSize: 15),
              onChanged: (v) => setState(() => _query = v),
              decoration: InputDecoration(
                hintText: showContactList
                    ? 'Search contacts…'
                    : 'Enter phone number',
                hintStyle: const TextStyle(color: Colors.white38),
                prefixIcon: const Icon(Icons.search_rounded,
                    color: Colors.white38, size: 20),
                filled: true,
                fillColor: Colors.white.withOpacity(0.08),
                contentPadding: const EdgeInsets.symmetric(
                    vertical: 12, horizontal: 12),
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(14),
                  borderSide: BorderSide.none,
                ),
              ),
            ),
          ),

          const SizedBox(height: 12),

          // Contact list or direct dial button
          if (showContactList) ...[
            ConstrainedBox(
              constraints: const BoxConstraints(maxHeight: 300),
              child: _filtered.isEmpty
                  ? const Padding(
                      padding: EdgeInsets.all(24),
                      child: Text(
                        'No contacts found',
                        style: TextStyle(color: Colors.white38),
                        textAlign: TextAlign.center,
                      ),
                    )
                  : ListView.builder(
                      shrinkWrap: true,
                      itemCount: _filtered.length,
                      itemBuilder: (_, i) {
                        final p = _filtered[i];
                        final photoUrl = p.photoUrl;
                        final initial = p.label.isNotEmpty
                            ? p.label[0].toUpperCase()
                            : '?';

                        return ListTile(
                          contentPadding: const EdgeInsets.symmetric(
                              horizontal: 20, vertical: 2),
                          leading: CircleAvatar(
                            radius: 20,
                            backgroundColor: _avatarColor(p.userId),
                            backgroundImage: photoUrl != null
                                ? NetworkImage(photoUrl)
                                : null,
                            child: photoUrl == null
                                ? Text(
                                    initial,
                                    style: const TextStyle(
                                      color: Colors.white,
                                      fontSize: 14,
                                      fontWeight: FontWeight.w600,
                                    ),
                                  )
                                : null,
                          ),
                          title: Text(
                            p.label,
                            style: const TextStyle(
                              color: Colors.white,
                              fontSize: 15,
                              fontWeight: FontWeight.w500,
                            ),
                          ),
                          subtitle: p.phoneNumber != null
                              ? Text(
                                  p.phoneNumber!,
                                  style: const TextStyle(
                                      color: Colors.white38, fontSize: 12),
                                )
                              : null,
                          trailing: Container(
                            width: 36,
                            height: 36,
                            decoration: const BoxDecoration(
                              shape: BoxShape.circle,
                              color: Color(0xFF30D158),
                            ),
                            child: const Icon(Icons.phone_rounded,
                                color: Colors.white, size: 18),
                          ),
                          onTap: () {
                            final number = p.phoneNumber ?? p.userId;
                            widget.onAdd(number);
                            Navigator.pop(context);
                          },
                        );
                      },
                    ),
            ),

            // Also allow manual entry if search looks like a number
            if (_query.isNotEmpty && _query.contains(RegExp(r'[0-9+]')))
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 8, 16, 16),
                child: _InviteButton(
                  label: 'Call "$_query"',
                  onTap: () {
                    widget.onAdd(_query.trim());
                    Navigator.pop(context);
                  },
                ),
              )
            else
              const SizedBox(height: 16),
          ] else ...[
            // No addable participants — just a dial button
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 4, 16, 20),
              child: _InviteButton(
                label: 'Invite',
                onTap: () {
                  final number = _controller.text.trim();
                  if (number.isNotEmpty) {
                    widget.onAdd(number);
                  }
                  Navigator.pop(context);
                },
              ),
            ),
          ],
        ],
      ),
    );
  }
}

class _InviteButton extends StatelessWidget {
  const _InviteButton({required this.label, required this.onTap});
  final String label;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: double.infinity,
      child: ElevatedButton.icon(
        style: ElevatedButton.styleFrom(
          backgroundColor: const Color(0xFF30D158),
          foregroundColor: Colors.white,
          padding: const EdgeInsets.symmetric(vertical: 14),
          shape:
              RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
          elevation: 0,
        ),
        icon: const Icon(Icons.call_rounded, size: 18),
        label: Text(
          label,
          style: const TextStyle(
              fontSize: 15, fontWeight: FontWeight.w600),
        ),
        onPressed: onTap,
      ),
    );
  }
}

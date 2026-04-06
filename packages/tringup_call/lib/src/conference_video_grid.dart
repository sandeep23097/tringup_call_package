import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:livekit_client/livekit_client.dart' as lk;

import 'tringup_call_config.dart';
import 'tringup_call_contact.dart';
import 'tringup_call_screen_api.dart';

// ── Conference video grid ─────────────────────────────────────────────────────

/// Multi-party video grid for group calls.
///
/// - 1 remote participant: full-screen tile.
/// - 2 remotes: stacked vertically (full height, side by side).
/// - 3+ remotes: 2-column grid.
/// - Local self-view: draggable PiP in the corner with a flip-camera button.
/// - Camera off: shows the participant's profile photo or initials.
/// - Active speaker: animated green border glow.
/// - Muted: mic-off badge on the tile.
enum CallType { audio, video }

class ConferenceVideoGrid extends StatefulWidget {
  const ConferenceVideoGrid({
    super.key,
    required this.room,
    this.localVideoEnabled = false,
    this.participants = const [],
    this.onSwitchCamera,
    required this.callType,
    this.nameResolver,
    this.photoPathResolver,
  });

  final lk.Room room;
  final bool localVideoEnabled;
  final CallType callType;
  /// Participant list from CallBloc — used for resolving display names and photos.
  final List<TringupParticipant> participants;

  /// Called when the user taps the flip-camera button on the self-view.
  final VoidCallback? onSwitchCamera;

  final TringupNameResolver? nameResolver;
  final TringupPhotoPathResolver? photoPathResolver;

  @override
  State<ConferenceVideoGrid> createState() => _ConferenceVideoGridState();
}

class _ConferenceVideoGridState extends State<ConferenceVideoGrid> {
  // PiP drag state — offset from bottom-right corner
  Offset _pipOffset = const Offset(16, 16);

  // GlobalKeys keyed by participant identity.
  // Preserves _RemoteParticipantTileState (and its VideoTrackRenderer) when
  // the grid layout changes (e.g. 1-tile fullscreen → 2-tile Column), preventing
  // the brief video flash that would occur if the tile were recreated from scratch.
  final _tileKeys = <String, GlobalKey>{};

  // Cache: phone → resolved display name (from nameResolver callback)
  final _resolvedNames = <String, String>{};
  // Cache: phone → resolved photo file path (from photoPathResolver callback)
  final _resolvedPhotoPaths = <String, String>{};
  // Tracks phones currently being resolved to avoid duplicate async calls.
  final _resolvingPhones = <String>{};

  GlobalKey _keyFor(String identity) =>
      _tileKeys.putIfAbsent(identity, () => GlobalKey());

  Future<String?> _resolveName(String? number) async {
    if (number == null || number.isEmpty) return null;
    return widget.nameResolver?.call(
      TringupCallContact(userId: '', phoneNumber: number),
    );
  }

  Future<String?> _resolvePhotoPath(String? number) async {
    if (number == null || number.isEmpty) return null;
    return widget.photoPathResolver?.call(
      TringupCallContact(userId: '', phoneNumber: number),
    );
  }

  /// Triggers async resolution for [phone] if not already cached or in-flight.
  /// Calls setState when results arrive so the tile rebuilds with resolved data.
  void _prefetchPhone(String phone) {
    if (_resolvingPhones.contains(phone)) return;
    _resolvingPhones.add(phone);

    _resolveName(phone).then((name) {
      if (!mounted) return;
      if (name != null && name.isNotEmpty) {
        setState(() => _resolvedNames[phone] = name);
      }
    });

    _resolvePhotoPath(phone).then((path) {
      if (!mounted) return;
      if (path != null && path.isNotEmpty) {
        setState(() => _resolvedPhotoPaths[phone] = path);
      }
    });
  }

  @override
  void initState() {
    super.initState();
    widget.room.addListener(_onRoomChanged);
  }

  @override
  void didUpdateWidget(ConferenceVideoGrid old) {
    super.didUpdateWidget(old);
    if (old.room != widget.room) {
      old.room.removeListener(_onRoomChanged);
      widget.room.addListener(_onRoomChanged);
    }
  }

  @override
  void dispose() {
    widget.room.removeListener(_onRoomChanged);
    super.dispose();
  }

  void _onRoomChanged() => setState(() {});

  /// Build a phone → display-name map from [TringupParticipant] list,
  /// merged with async-resolved names from [nameResolver].
  Map<String, String> get _nameMap {
    final map = {for (final p in widget.participants) p.userId: p.label};
    // Overlay resolver results (only fill gaps — don't override BLoC-resolved names)
    for (final entry in _resolvedNames.entries) {
      map.putIfAbsent(entry.key, () => entry.value);
    }
    return map;
  }

  /// Build a phone → ImageProvider map from [TringupParticipant] list,
  /// merged with async-resolved photo paths from [photoPathResolver].
  Map<String, ImageProvider> get _photoMap {
    final map = <String, ImageProvider>{};
    for (final p in widget.participants) {
      if (p.photoPath != null && p.photoPath!.isNotEmpty) {
        map[p.userId] = FileImage(File(p.photoPath!));
      } else if (p.photoUrl != null && p.photoUrl!.isNotEmpty) {
        map[p.userId] = NetworkImage(p.photoUrl!);
      }
    }
    // Fill gaps with resolver results
    for (final entry in _resolvedPhotoPaths.entries) {
      map.putIfAbsent(entry.key, () => FileImage(File(entry.value)));
    }
    return map;
  }

  @override
  Widget build(BuildContext context) {
    final remotes = widget.room.remoteParticipants.values.toList();

    // Trigger async resolution for any phone not yet cached.
    for (final p in remotes) {
      final meta = p.metadata != null ? jsonDecode(p.metadata!) : null;
      final phone = meta?['phone_number'] as String?;
      if (phone != null && phone.isNotEmpty) _prefetchPhone(phone);
    }

    final nameMap = _nameMap;
    final photoMap = _photoMap;

    return LayoutBuilder(
      builder: (context, constraints) {
        print("*******************wwwwwwwwww${widget.callType}");
        return Stack(
          fit: StackFit.expand,

          children: [
            // ── Remote participant tiles ──────────────────────────────────
            _buildGrid(remotes, nameMap, photoMap, constraints),

            // ── Local self-view PiP ───────────────────────────────────────
            // if (widget.callType == CallType.video)  Positioned(
            //   bottom: _pipOffset.dy,
            //   right: _pipOffset.dx,
            //   child: GestureDetector(
            //     onPanUpdate: (d) {
            //       setState(() {
            //         // Keep PiP inside the screen bounds
            //         final maxRight = constraints.maxWidth - _kPipWidth - 8;
            //         final maxBottom = constraints.maxHeight - _kPipHeight - 8;
            //         _pipOffset = Offset(
            //           (_pipOffset.dx - d.delta.dx).clamp(8.0, maxRight),
            //           (_pipOffset.dy - d.delta.dy).clamp(8.0, maxBottom),
            //         );
            //       });
            //     },
            //     child: _LocalSelfView(
            //       room: widget.room,
            //       videoEnabled: widget.localVideoEnabled,
            //       onSwitchCamera: widget.onSwitchCamera,
            //     ),
            //   ),
            // ),
          ],
        );
      },
    );
  }

  Widget _buildGrid(
      List<lk.RemoteParticipant> remotes,
      Map<String, String> nameMap,
      Map<String, ImageProvider> photoMap,
      BoxConstraints constraints,
      ) {
    final local = widget.room.localParticipant;

    // 👉 Merge local + remote
    final allParticipants = <dynamic>[
      if (local != null) local,
      ...remotes,
    ];

    if (allParticipants.isEmpty) {
      return const _WaitingForOthers();
    }

    // 👉 Helper to build tile (local + remote)
    Widget buildTile(dynamic participant, {bool fill = false}) {
      final isLocal = participant is lk.LocalParticipant;

      if (isLocal) {
        return _LocalParticipantTile(
          participant: participant,
          nameMap: nameMap,
          photoMap: photoMap,
          fill: fill,
            onSwitchCamera: widget.onSwitchCamera
        );
      } else {
        return _RemoteParticipantTile(
          key: _keyFor(participant.identity),
          participant: participant,
          photoMap: photoMap,
          nameMap: nameMap,
          fill: fill,
        );
      }
    }

    // 🔹 1 participant (only self OR 1 remote)
    if (allParticipants.length == 1) {
      return buildTile(allParticipants.first, fill: true);
    }

    // 🔹 2 participants
    if (allParticipants.length == 2) {
      return Column(
        children: allParticipants
            .map((p) => Expanded(child: buildTile(p)))
            .toList(),
      );
    }

    // 🔹 3–4 participants
    if (allParticipants.length <= 4) {
      return GridView.builder(
        physics: const NeverScrollableScrollPhysics(),
        gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
          crossAxisCount: 2,
          childAspectRatio: 3 / 4,
          crossAxisSpacing: 2,
          mainAxisSpacing: 2,
        ),
        itemCount: allParticipants.length,
        itemBuilder: (_, i) => buildTile(allParticipants[i]),
      );
    }

    // 🔹 5+ participants
    return GridView.builder(
      physics: const BouncingScrollPhysics(),
      gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
        crossAxisCount: 2,
        childAspectRatio: 3 / 4,
        crossAxisSpacing: 2,
        mainAxisSpacing: 2,
      ),
      itemCount: allParticipants.length,
      itemBuilder: (_, i) => buildTile(allParticipants[i]),
    );
  }
}

class _LocalParticipantTile extends StatelessWidget {
  const _LocalParticipantTile({
    required this.participant,
    required this.nameMap,
    required this.photoMap,
    this.fill = false,
    this.onSwitchCamera,
  });

  final lk.LocalParticipant participant;
  final Map<String, String> nameMap;
  final Map<String, ImageProvider> photoMap;
  final bool fill;
  final VoidCallback? onSwitchCamera;

  lk.LocalVideoTrack? _videoTrack() {
    for (final pub in participant.videoTrackPublications) {
      if (!pub.muted && pub.track != null) {
        return pub.track as lk.LocalVideoTrack;
      }
    }
    return null;
  }

  @override
  Widget build(BuildContext context) {
    final videoTrack = _videoTrack();
    final id = participant.identity;

    final name = nameMap[id] ?? "You";
    final photo = photoMap[id];
    final initial = name.isNotEmpty ? name[0].toUpperCase() : '?';

    return Container(
      color: Colors.black,
      child: Stack(
        fit: fill ? StackFit.expand : StackFit.passthrough,
        children: [
          if (videoTrack != null)
            lk.VideoTrackRenderer(
              videoTrack,
              mirrorMode: lk.VideoViewMirrorMode.mirror,
              fit: lk.VideoViewFit.cover,
            )
          else
            _AvatarFallback(
              name: name,
              initial: initial,
              photo: photo,
            ),
          if (onSwitchCamera != null && videoTrack != null)
            Positioned(
              bottom: 10,
              left: 55,
              child: GestureDetector(
                onTap: onSwitchCamera,
                child: Container(
                  width: 26,
                  height: 26,
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    color: Colors.black.withOpacity(0.55),
                  ),
                  child: const Icon(
                    Icons.flip_camera_ios_rounded,
                    color: Colors.white,
                    size: 14,
                  ),
                ),
              ),
            ),
          // "You" label
          Positioned(
            bottom: 10,
            left: 10,
            child: Container(
              padding: const EdgeInsets.symmetric(
                horizontal: 8,
                vertical: 4,
              ),
              decoration: BoxDecoration(
                color: Colors.black.withOpacity(0.6),
                borderRadius: BorderRadius.circular(8),
              ),
              child: const Text(
                "You",
                style: TextStyle(color: Colors.white),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

const double _kPipWidth = 88;
const double _kPipHeight = 140;

// ── Waiting state ─────────────────────────────────────────────────────────────

class _WaitingForOthers extends StatelessWidget {
  const _WaitingForOthers();

  @override
  Widget build(BuildContext context) {
    return Container(
      color: const Color(0xFF0A0E17),
      child: const Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.groups_rounded, color: Colors.white24, size: 64),
            SizedBox(height: 16),
            Text(
              'Waiting for others to join…',
              style: TextStyle(color: Colors.white38, fontSize: 15),
            ),
          ],
        ),
      ),
    );
  }
}

// ── Remote participant tile ───────────────────────────────────────────────────

class _RemoteParticipantTile extends StatefulWidget {
  const _RemoteParticipantTile({
    super.key,
    required this.participant,
    required this.photoMap,
    required this.nameMap,
    this.fill = false,
  });

  final lk.RemoteParticipant participant;

  /// identity → ImageProvider — used when camera is off.
  final Map<String, ImageProvider> photoMap;

  /// identity → display name resolved from the host app's contact list.
  final Map<String, String> nameMap;
  final bool fill;

  @override
  State<_RemoteParticipantTile> createState() => _RemoteParticipantTileState();
}

class _RemoteParticipantTileState extends State<_RemoteParticipantTile>
    with SingleTickerProviderStateMixin {
  // late AnimationController _speakingCtrl;
  bool isSpeaking = false;

  @override
  void initState() {
    super.initState();
    // _speakingCtrl = AnimationController(
    //   vsync: this,
    //   duration: const Duration(milliseconds: 600),
    // );
    widget.participant.addListener(_onChange);
  }

  @override
  void dispose() {
    widget.participant.removeListener(_onChange);
    // _speakingCtrl.dispose();
    super.dispose();
  }

  void _onChange() {
    if (!mounted) return;
    setState(() {});
    if (widget.participant.isSpeaking) {
      isSpeaking = true;
    } else {
      isSpeaking = false;
    }
  }

  lk.RemoteVideoTrack? _videoTrack() {
    for (final pub in widget.participant.videoTrackPublications) {
      if (pub.subscribed && !pub.muted && pub.track != null) {
        return pub.track as lk.RemoteVideoTrack;
      }
    }
    return null;
  }

  bool get _isMuted {
    for (final pub in widget.participant.audioTrackPublications) {
      if (pub.muted) return true;
    }
    return false;
  }

  @override
  Widget build(BuildContext context) {
    final videoTrack = _videoTrack();
    final identity = widget.participant.identity;
   var metadata =  widget.participant.metadata != null ? jsonDecode(widget.participant.metadata!) : null;
    print("UUUUUUUUUUUUUUUUUUUUUUUUUUU${metadata}SSSSSSSSSSS${widget.participant}");
   String phone = metadata != null ? metadata['phone_number'] : null;
    final photo = widget.photoMap[phone];


    // Prefer host-app resolved name, then LiveKit name, then identity
    final name =
        widget.nameMap[phone] ??
            phone;

    final initial = name.isNotEmpty ? name[0].toUpperCase() : '?';


    return Container(
      color: Colors.black,
      child: Stack(
        fit: widget.fill ? StackFit.expand : StackFit.passthrough,
        children: [
          // Video stream or avatar fallback
          if (videoTrack != null)
            lk.VideoTrackRenderer(videoTrack)
          else
            _AvatarFallback(
              name: name,
              initial: initial,
              photo: photo,
            ),

          // Speaking glow border
          // if (widget.participant.isSpeaking)
          Positioned.fill(
            child: Container(
              decoration: BoxDecoration(
                border: Border.all(
                  color: !isSpeaking ? Colors.green : Colors.transparent,
                  width: 2 + (widget.participant.audioLevel * 3),
                ),
              ),
            ),
          ),

          // Name label (bottom-left)
          Positioned(
            bottom: 10,
            left: 10,
            right: 50,
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 8,
                    vertical: 4,
                  ),
                  decoration: BoxDecoration(
                    color: Colors.black.withOpacity(0.6),
                    borderRadius: BorderRadius.circular(8),
                  ),
                  child: Text(
                    name,
                    style: const TextStyle(
                      color: Colors.white,
                      fontSize: 12,
                      fontWeight: FontWeight.w500,
                    ),
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
              ],
            ),
          ),

          // Muted badge (bottom-right)
          if (_isMuted)
            Positioned(
              bottom: 10,
              right: 10,
              child: Container(
                width: 28,
                height: 28,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  color: Colors.black.withOpacity(0.65),
                ),
                child: const Icon(
                  Icons.mic_off_rounded,
                  color: Color(0xFFFF453A),
                  size: 16,
                ),
              ),
            ),
        ],
      ),
    );

  }
}

// ── Avatar fallback (camera off) ──────────────────────────────────────────────

class _AvatarFallback extends StatelessWidget {
  const _AvatarFallback({
    required this.name,
    required this.initial,
    required this.photo,
  });

  final String name;
  final String initial;
  final ImageProvider? photo;

  Color get _bg {
    const palette = [
      Color(0xFF3A4A6B),
      Color(0xFF2A5A5A),
      Color(0xFF4A3A6B),
      Color(0xFF2A4A6B),
      Color(0xFF6B3A4A),
    ];
    return palette[name.hashCode.abs() % palette.length];
  }

  @override
  Widget build(BuildContext context) {
    return Container(
      color: _bg,
      child: Center(
        child: photo != null
            ? CircleAvatar(
          radius: 44,
          backgroundImage: photo,
          onBackgroundImageError: (_, __) {},
        )
            : Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            CircleAvatar(
              radius: 44,
              backgroundColor: Colors.white.withOpacity(0.12),
              child: Text(
                initial,
                style: const TextStyle(
                  color: Colors.white,
                  fontSize: 36,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ),
            const SizedBox(height: 10),
            Text(
              name,
              style: const TextStyle(color: Colors.white60, fontSize: 14),
              overflow: TextOverflow.ellipsis,
            ),
          ],
        ),
      ),
    );
  }
}

// ── Local self-view PiP ───────────────────────────────────────────────────────

class _LocalSelfView extends StatefulWidget {
  const _LocalSelfView({
    required this.room,
    required this.videoEnabled,
    this.onSwitchCamera,
  });

  final lk.Room room;
  final bool videoEnabled;
  final VoidCallback? onSwitchCamera;

  @override
  State<_LocalSelfView> createState() => _LocalSelfViewState();
}

class _LocalSelfViewState extends State<_LocalSelfView> {
  @override
  void initState() {
    super.initState();
    // Listen to the Room (covers connect, participant join, track publication).
    // localParticipant may be null at this point if the room hasn't fully
    // connected yet, so we can't rely solely on participant-level listeners.
    widget.room.addListener(_onChange);
  }

  @override
  void didUpdateWidget(_LocalSelfView old) {
    super.didUpdateWidget(old);
    if (old.room != widget.room) {
      old.room.removeListener(_onChange);
      widget.room.addListener(_onChange);
    }
  }

  @override
  void dispose() {
    widget.room.removeListener(_onChange);
    super.dispose();
  }

  void _onChange() => setState(() {});

  lk.LocalVideoTrack? _videoTrack() {
    final local = widget.room.localParticipant;
    if (local == null) return null;
    for (final pub in local.videoTrackPublications) {
      if (!pub.muted && pub.track != null) {
        return pub.track as lk.LocalVideoTrack;
      }
    }
    return null;
  }

  @override
  Widget build(BuildContext context) {
    // Always try to get the actual track — don't gate on widget.videoEnabled,
    // which can be false when activeCall.video wasn't set on the receiver side
    // even though the camera IS published.
    final videoTrack = _videoTrack();

    return SizedBox(
      width: _kPipWidth + 30,
      height: _kPipHeight+30,
      child: ClipRRect(
        borderRadius: BorderRadius.circular(12),
        child: Container(
          decoration: BoxDecoration(
            color: const Color(0xFF1A2233),
            border: Border.all(
              color: Colors.white.withOpacity(0.2),
              width: 1.5,
            ),
            borderRadius: BorderRadius.circular(12),
            boxShadow: [
              BoxShadow(
                color: Colors.black.withOpacity(0.5),
                blurRadius: 8,
                offset: const Offset(0, 4),
              ),
            ],
          ),
          child: Stack(
            // fit: StackFit.expand,
            children: [
              // Video or placeholder.
              // IgnorePointer lets drag events pass through to the outer
              // GestureDetector — VideoTrackRenderer otherwise absorbs them,
              // which stops the PiP from being dragged once a track is live.
              IgnorePointer(
                child: videoTrack != null
                    ? lk.VideoTrackRenderer(
                  videoTrack,
                  mirrorMode: lk.VideoViewMirrorMode.mirror,
                  fit: lk.VideoViewFit.cover,
                )
                    : const Center(
                  child: Icon(
                    Icons.videocam_off_rounded,
                    color: Colors.white30,
                    size: 28,
                  ),
                ),
              ),

              // "You" label
              Positioned(
                bottom: 6,
                left: 6,
                child: Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 5,
                    vertical: 2,
                  ),
                  decoration: BoxDecoration(
                    color: Colors.black.withOpacity(0.55),
                    borderRadius: BorderRadius.circular(5),
                  ),
                  child: const Text(
                    'You',
                    style: TextStyle(color: Colors.white70, fontSize: 10),
                  ),
                ),
              ),

              // Switch camera button (top-right)
              if (widget.onSwitchCamera != null && videoTrack != null)
                Positioned(
                  top: 6,
                  right: 6,
                  child: GestureDetector(
                    onTap: widget.onSwitchCamera,
                    child: Container(
                      width: 26,
                      height: 26,
                      decoration: BoxDecoration(
                        shape: BoxShape.circle,
                        color: Colors.black.withOpacity(0.55),
                      ),
                      child: const Icon(
                        Icons.flip_camera_ios_rounded,
                        color: Colors.white,
                        size: 14,
                      ),
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

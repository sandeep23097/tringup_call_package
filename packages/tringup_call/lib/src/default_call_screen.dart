import 'dart:async';
import 'dart:io';
import 'dart:math' as math;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart' show MediaStream;
import 'package:livekit_client/livekit_client.dart' as lk;
import 'package:webtrit_phone/features/call/call.dart';
import 'conference_video_grid.dart';
import 'pip/tringup_pip_manager.dart';
import 'tringup_call_config.dart';
import 'tringup_call_contact.dart';
import 'tringup_call_screen_api.dart';

// ── Design tokens ─────────────────────────────────────────────────────────────

const _kGreen = Color(0xFF25D366);
const _kTeal = Color(0xFF128C7E);
const _kRed = Color(0xFFE53935);
const _kBgDeep = Color(0xFF071015);
const _kBgMid = Color(0xFF0D1F2D);
const _kBgSurface = Color(0xFF0F2132);
const _kControlBg = Color(0x1FFFFFFF);
const _kControlActive = Color(0x47FFFFFF);
const _kTextSecondary = Color(0xA6FFFFFF);

// ── Invite state tracking ─────────────────────────────────────────────────────

enum _InviteState { calling, ringing, failed }

class _PendingInvite {
  _PendingInvite({required this.participant, required this.state, this.timer});

  final TringupParticipant participant;
  final _InviteState state;
  final Timer? timer;

  _PendingInvite withState(_InviteState s) =>
      _PendingInvite(participant: participant, state: s, timer: timer);
}

// ── Main widget ───────────────────────────────────────────────────────────────

/// Modern production-grade call screen inspired by WhatsApp.
/// Supports audio/video and 1:1/group calls with a unified control bar.
class TringupDefaultCallScreen extends StatefulWidget {
  const TringupDefaultCallScreen({
    super.key,
    required this.info,
    required this.actions,
    this.localStream,
    this.localVideo = false,
    this.mirrorLocalVideo = true,
    this.remoteStream,
    this.remoteVideo = false,
    this.livekitRoom,
    this.pipManager,
    this.nameResolver,
    this.photoPathResolver,
  });

  final TringupCallInfo info;
  final TringupCallActions actions;
  final MediaStream? localStream;
  final bool localVideo;
  final bool mirrorLocalVideo;
  final MediaStream? remoteStream;
  final bool remoteVideo;
  final lk.Room? livekitRoom;
  final TringupPiPManager? pipManager;
  final TringupNameResolver? nameResolver;
  final TringupPhotoPathResolver? photoPathResolver;

  @override
  State<TringupDefaultCallScreen> createState() =>
      _TringupDefaultCallScreenState();
}

class _TringupDefaultCallScreenState extends State<TringupDefaultCallScreen>
    with TickerProviderStateMixin {
  // ── Existing fields ───────────────────────────────────────────────────────
  Timer? _timer;
  StreamSubscription<bool>? _pipSub;
  bool _isInPiP = false;
  Offset _pipOffset = Offset.zero;
  bool _pipPositioned = false;
  bool _showAddPanel = false;
  bool _showMembersPanel = false;
  final Map<String, _PendingInvite> _pendingInvites = {};
  lk.Room? _attachedRoom;

  // ── New fields (P3–P5) ────────────────────────────────────────────────────
  String? _activeSpeakerId;

  // Tracks remote participants who have left the call so the panel can show
  // "Left call" instead of having them silently disappear.
  // Key = LiveKit identity (server userId).
  final Map<String, TringupParticipant> _leftParticipants = {};

  // Known remote participants by identity → display name, cached before
  // LiveKit removes them on disconnect.
  final Map<String, String> _knownRemoteNames = {};

  // Previous remote participant identity set, used to detect join/leave diffs.
  Set<String> _prevRemoteIds = {};

  // Tracks when each server-invited participant first appeared in waitingToJoin.
  // Key = participant userId (phone number from conferenceParticipants).
  // Used to show "No answer" after a timeout for participants who never joined.
  final Map<String, DateTime> _invitedAt = {};

  // PiP snap animation
  late final AnimationController _pipSnapCtrl;
  Offset _pipSnapStart = Offset.zero;
  Offset _pipSnapTarget = Offset.zero;

  // ── Lifecycle ─────────────────────────────────────────────────────────────

  @override
  void initState() {
    super.initState();
    _attachRoom(widget.livekitRoom);
    _timer = Timer.periodic(const Duration(seconds: 1), (_) {
      if (mounted) setState(() {});
    });
    _pipSub = widget.pipManager?.pipModeStream.listen((inPiP) {
      if (mounted && inPiP != _isInPiP) setState(() => _isInPiP = inPiP);
    });
    _pipSnapCtrl = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 320),
    );
    _pipSnapCtrl.addListener(() {
      if (!mounted) return;
      final t = Curves.easeOutCubic.transform(_pipSnapCtrl.value);
      setState(() => _pipOffset = Offset.lerp(_pipSnapStart, _pipSnapTarget, t)!);
    });
  }

  // ── Resolver helpers ──────────────────────────────────────────────────────

  /// Resolves the display name for a phone [number] using the host-app's
  /// [TringupCallConfig.nameResolver] callback. Returns null when no resolver
  /// is configured or the resolver returns null.
  Future<String?> _resolveName(String? number) async {
    if (number == null || number.isEmpty) return null;
    return widget.nameResolver?.call(
      TringupCallContact(userId: '', phoneNumber: number),
    );
  }

  /// Resolves the local file path of a contact photo for a phone [number]
  /// using the host-app's [TringupCallConfig.photoPathResolver] callback.
  /// Returns null when no resolver is configured or the resolver returns null.
  Future<String?> _resolvePhotoPath(String? number) async {
    if (number == null || number.isEmpty) return null;
    return widget.photoPathResolver?.call(
      TringupCallContact(userId: '', phoneNumber: number),
    );
  }

  @override
  void didUpdateWidget(TringupDefaultCallScreen old) {
    super.didUpdateWidget(old);
    if (old.livekitRoom != widget.livekitRoom) _attachRoom(widget.livekitRoom);

    // Detect participants removed from conferenceParticipants by a signaling
    // participant_left event.  This captures ringing users who declined or
    // hung up — they are removed from info.participants but were never in the
    // LiveKit room, so _onRoomChanged would not capture them in _leftParticipants.
    final oldIds = old.info.participants.map((p) => p.userId).toSet();
    final newIds = widget.info.participants.map((p) => p.userId).toSet();
    final removed = oldIds.difference(newIds);
    if (removed.isNotEmpty) {
      bool changed = false;
      for (final uid in removed) {
        if (_leftParticipants.containsKey(uid)) continue;
        final isSelf = uid == (widget.livekitRoom?.localParticipant?.identity) ||
            (widget.info.localUserNumber != null && uid == widget.info.localUserNumber);
        if (isSelf) continue;
        final oldP = old.info.participants.where((p) => p.userId == uid).firstOrNull;
        final resolvedName = oldP?.displayName ?? oldP?.userId ?? uid;
        _leftParticipants[uid] = TringupParticipant(userId: uid, displayName: resolvedName);
        changed = true;
      }
      if (changed) setState(() {});
    }
  }

  @override
  void dispose() {
    _attachedRoom?.removeListener(_onRoomChanged);
    for (final inv in _pendingInvites.values) inv.timer?.cancel();
    _pipSub?.cancel();
    _timer?.cancel();
    _pipSnapCtrl.dispose();
    super.dispose();
  }

  void _attachRoom(lk.Room? room) {
    if (_attachedRoom == room) return;
    _attachedRoom?.removeListener(_onRoomChanged);
    _attachedRoom = room;
    // Reset per-call tracking whenever the room changes.
    _prevRemoteIds = {};
    _leftParticipants.clear();
    _knownRemoteNames.clear();
    _invitedAt.clear();
    room?.addListener(_onRoomChanged);
  }

  void _onRoomChanged() {
    if (!mounted) return;
    final room = _attachedRoom;

    if (room != null) {
      final currentIds = room.remoteParticipants.keys.toSet();

      // Cache every currently-present participant's display name BEFORE they
      // might disappear, so we still have info when they leave.
      for (final lkP in room.remoteParticipants.values) {
        _knownRemoteNames[lkP.identity] =
            lkP.name.isNotEmpty ? lkP.name : lkP.identity;
      }

      // Detect newly joined participants: try to clean up matching _pendingInvites.
      // Matches by lkIdentity (works if server uses phone number as identity)
      // or by lkP.name (works if server sets name = phone/display name).
      for (final lkP in room.remoteParticipants.values) {
        if (!_prevRemoteIds.contains(lkP.identity)) {
          _pendingInvites.removeWhere((key, inv) {
            final isMatch = key == lkP.identity ||
                key == lkP.name ||
                inv.participant.phoneNumber == lkP.identity ||
                inv.participant.phoneNumber == lkP.name;
            if (isMatch) inv.timer?.cancel();
            return isMatch;
          });
        }
      }

      // Detect departed participants: record them for "Left call" display.
      // Issue 5 fix: prefer contact-resolved name from conferenceParticipants
      // (still present at this point, before BLoC processes participant_left).
      for (final id in _prevRemoteIds) {
        if (!currentIds.contains(id) && !_leftParticipants.containsKey(id)) {
          final known = widget.info.participants.where((p) => p.userId == id);
          final resolvedName = known.isNotEmpty
              ? (known.first.displayName ?? known.first.userId)
              : (_knownRemoteNames[id] ?? id);
          _leftParticipants[id] =
              TringupParticipant(userId: id, displayName: resolvedName);
        }
      }

      _prevRemoteIds = currentIds;
    }

    final speaker = room?.activeSpeakers.firstOrNull;
    setState(() => _activeSpeakerId = speaker?.identity);
  }

  // ── Invite helpers ────────────────────────────────────────────────────────

  void _inviteParticipant(TringupParticipant p) {
    _pendingInvites[p.userId]?.timer?.cancel();
    final timer = Timer(const Duration(seconds: 45), () {
      if (mounted) {
        setState(() {
          final inv = _pendingInvites[p.userId];
          if (inv != null) _pendingInvites[p.userId] = inv.withState(_InviteState.failed);
        });
      }
    });
    setState(() {
      _pendingInvites[p.userId] =
          _PendingInvite(participant: p, state: _InviteState.calling, timer: timer);
      _showAddPanel = false;
    });
    widget.actions.addParticipant?.call(p.phoneNumber ?? p.userId);
  }

  // ── PiP helpers ───────────────────────────────────────────────────────────

  void _onPipDragUpdate(DragUpdateDetails d, Size screen) {
    setState(() {
      const w = 108.0;
      const h = 152.0;
      // Reserve space for top header (~90dp) and bottom control bar (~180dp).
      const topMin = 90.0;
      const botClear = 180.0;
      _pipOffset = Offset(
        (_pipOffset.dx + d.delta.dx).clamp(8.0, screen.width - w - 8.0),
        (_pipOffset.dy + d.delta.dy).clamp(topMin, screen.height - h - botClear),
      );
    });
  }

  void _onPipDragEnd(DragEndDetails _, Size screen) {
    const w = 108.0;
    const h = 152.0;
    const m = 12.0;
    const top = 90.0;
    const bot = 180.0;

    final corners = [
      Offset(m, top),
      Offset(screen.width - w - m, top),
      Offset(m, screen.height - h - bot),
      Offset(screen.width - w - m, screen.height - h - bot),
    ];

    Offset nearest = corners.first;
    double minDist = double.infinity;
    for (final c in corners) {
      final d = (_pipOffset - c).distance;
      if (d < minDist) {
        minDist = d;
        nearest = c;
      }
    }
    _pipSnapStart = _pipOffset;
    _pipSnapTarget = nearest;
    _pipSnapCtrl.forward(from: 0);
  }

  // ── Build ─────────────────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    if (!_pipPositioned) {
      _pipPositioned = true;
      final size = MediaQuery.of(context).size;
      _pipOffset = Offset(size.width - 108 - 16, size.height - 152 - 200);
    }

    final info = widget.info;
    final actions = widget.actions;
    final lkRoom = widget.livekitRoom;

    // Resolve video tracks
    lk.VideoTrack? remoteVideoTrack;
    lk.VideoTrack? localVideoTrack;
    if (lkRoom != null) {
      final remotePub =
          lkRoom.remoteParticipants.values.firstOrNull?.videoTrackPublications.firstOrNull;
      if (remotePub != null && remotePub.subscribed) remoteVideoTrack = remotePub.track;
      localVideoTrack = lkRoom.localParticipant?.videoTrackPublications.firstOrNull?.track;
    }

    final hasRemoteVideo = lkRoom != null
        ? remoteVideoTrack != null
        : (widget.remoteVideo && widget.remoteStream != null);
    final hasLocalVideo = lkRoom != null
        ? localVideoTrack != null
        : (widget.localVideo && widget.localStream != null);

    // Use ConferenceVideoGrid whenever the LiveKit room has any remote participant.
    // This prevents the structural widget switch (VideoTrackRenderer → ConferenceVideoGrid)
    // that causes all videos to flash when the 3rd user joins.
    final isGroupVideoActive =
        lkRoom != null &&
            lkRoom.remoteParticipants.isNotEmpty &&
            (info.isGroupCall || lkRoom.remoteParticipants.length >= 2);
    print("**********************${isGroupVideoActive}");
    // Sync pending invites — remove entries for participants who have joined.
    // Check both conferenceParticipants userId AND lkRoom identity, because
    // the _pendingInvites key (phone number) may differ from the server userId.
    final joinedIds = info.participants.map((p) => p.userId).toSet();
    final lkJoinedIds = lkRoom?.remoteParticipants.keys.toSet() ?? {};
    _pendingInvites.removeWhere((userId, inv) {
      final joined = joinedIds.contains(userId) || lkJoinedIds.contains(userId);
      if (joined) inv.timer?.cancel();
      return joined;
    });
    for (final userId in info.ringingUserIds) {
      final inv = _pendingInvites[userId];
      if (inv != null && inv.state == _InviteState.calling) {
        _pendingInvites[userId] = inv.withState(_InviteState.ringing);
      }
    }

    // Issue 2 fix: record when each server-invited participant first appeared
    // in the waiting-to-join bucket so the panel can show "No answer" after
    // the timeout expires.
    if (info.isGroupCall) {
      final lkConnectedIds = lkRoom?.remoteParticipants.keys.toSet() ?? {};
      // Build phone→serverUserId reverse map for cross-namespace connected check.
      final phoneToServerId = <String, String>{};
      for (final entry in info.participantPhoneMap.entries) {
        phoneToServerId[entry.value] = entry.key;
      }
      bool isConnectedInLk(TringupParticipant p) {
        if (lkConnectedIds.contains(p.userId)) return true;
        final serverId = phoneToServerId[p.userId] ??
            (p.phoneNumber != null ? phoneToServerId[p.phoneNumber!] : null);
        return serverId != null && lkConnectedIds.contains(serverId);
      }
      final pendingIds = _pendingInvites.keys.toSet();
      final selfPhoneNumber = info.localUserNumber;
      final selfLkId = lkRoom?.localParticipant?.identity;
      for (final p in info.participants) {
        final isSelf = p.userId == selfLkId ||
            p.userId == selfPhoneNumber ||
            (selfPhoneNumber != null && p.phoneNumber == selfPhoneNumber);
        final isPending = pendingIds.contains(p.userId);
        if (!isSelf && !isConnectedInLk(p) && !isPending) {
          _invitedAt.putIfAbsent(p.userId, () => DateTime.now());
        }
      }
    }

    final isSpeaker = info.audioOutput == TringupAudioOutput.speaker ||
        info.audioOutput == TringupAudioOutput.bluetooth;
    final isBluetooth = info.audioOutput == TringupAudioOutput.bluetooth;

    return AnnotatedRegion<SystemUiOverlayStyle>(
      value: SystemUiOverlayStyle.light,
      child: Scaffold(
        backgroundColor: _kBgDeep,
        body: Stack(
          fit: StackFit.expand,
          children: [
            // ── [0] Background ─────────────────────────────────────────────
            isGroupVideoActive
                ? ConferenceVideoGrid(
                    room: lkRoom!,
                    localVideoEnabled: info.isCameraEnabled,
                    participants: info.participants,
                    onSwitchCamera: info.isVideoCall ? actions.switchCamera : null,
                    callType: info.isVideoCall ? CallType.video : CallType.audio,
                    nameResolver: widget.nameResolver,
                    photoPathResolver: widget.photoPathResolver,
                  )
                : hasRemoteVideo
                    ? Positioned.fill(
                        child: remoteVideoTrack != null
                            ? lk.VideoTrackRenderer(remoteVideoTrack,
                                fit: lk.VideoViewFit.cover)
                            : RTCStreamView(stream: widget.remoteStream),
                      )
                    : Container(
                        decoration: const BoxDecoration(
                          gradient: LinearGradient(
                            begin: Alignment.topCenter,
                            end: Alignment.bottomCenter,
                            colors: [_kBgMid, _kBgDeep],
                          ),
                        ),
                      ),

            // ── [1] Scrim ──────────────────────────────────────────────────
            IgnorePointer(
              child: AnimatedOpacity(
                duration: const Duration(milliseconds: 200),
                opacity: ((hasRemoteVideo || isGroupVideoActive) && !_isInPiP) ? 1.0 : 0.0,
                child: Container(color: Colors.black38),
              ),
            ),

            // ── [2] Local PiP draggable (full-screen mode, 1:1 video) ──────
            Positioned(
              left: _pipOffset.dx,
              top: _pipOffset.dy,
              child: Offstage(
                offstage: !hasLocalVideo || _isInPiP || isGroupVideoActive,
                child: GestureDetector(
                  onPanUpdate: (d) =>
                      _onPipDragUpdate(d, MediaQuery.of(context).size),
                  onPanEnd: (d) =>
                      _onPipDragEnd(d, MediaQuery.of(context).size),
                  child: _PipWindow(
                    width: 108,
                    height: 152,
                    localVideoTrack: localVideoTrack,
                    localStream: widget.localStream,
                    mirrorLocalVideo: widget.mirrorLocalVideo,
                    onSwitchCamera: actions.switchCamera,
                  ),
                ),
              ),
            ),

            // ── [3] Local PiP corner (native PiP window mode) ─────────────
            Positioned(
              right: 8,
              bottom: 8,
              child: Offstage(
                offstage: !hasLocalVideo || !_isInPiP,
                child: _PipWindow(
                  width: 72,
                  height: 100,
                  localVideoTrack: localVideoTrack,
                  localStream: widget.localStream,
                  mirrorLocalVideo: widget.mirrorLocalVideo,
                  borderRadius: 8,
                  onSwitchCamera: actions.switchCamera,
                ),
              ),
            ),

            // ── [4] Chrome (header + content + control bar) ───────────────
            // Rendered before panels so panels always draw on top.
            Offstage(
              offstage: _isInPiP,
              child: Column(
                children: [
                  // Header with SafeArea for status bar
                  SafeArea(
                    bottom: false,
                    child: _CallHeader(
                      info: info,
                      showMembersPanel: _showMembersPanel,
                      showAddPanel: _showAddPanel,
                      hasAddAction: actions.addParticipant != null,
                      onMinimize: actions.minimize,
                      onToggleMembers: () => setState(() {
                        _showMembersPanel = !_showMembersPanel;
                        _showAddPanel = false;
                      }),
                      onToggleAdd: () => setState(() {
                        _showAddPanel = !_showAddPanel;
                        _showMembersPanel = false;
                      }),
                    ),
                  ),

                  // Center content — bounded above the control bar
                  Expanded(
                    child: _buildCenterContent(
                      info: info,
                      lkRoom: lkRoom,
                      hasRemoteVideo: hasRemoteVideo,
                      isGroupVideoActive: isGroupVideoActive,
                    ),
                  ),

                  // Control bar section: dark background so video/content
                  // never bleeds through — gives the "proper scaffold" feel.
                  Container(
                    decoration: BoxDecoration(
                      gradient: LinearGradient(
                        begin: Alignment.topCenter,
                        end: Alignment.bottomCenter,
                        colors: [
                          Colors.transparent,
                          _kBgDeep.withOpacity(0.92),
                          _kBgDeep,
                        ],
                        stops: const [0.0, 0.35, 1.0],
                      ),
                    ),
                    child: SafeArea(
                      top: false,
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          // Invite status banner
                          if (_pendingInvites.isNotEmpty && info.isConnected)
                            Padding(
                              padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
                              child: _InviteStatusBanner(
                                invites: _pendingInvites,
                                onRetry: _inviteParticipant,
                              ),
                            ),

                          _ControlBar(
                            info: info,
                            actions: actions,
                            isSpeaker: isSpeaker,
                            isBluetooth: isBluetooth,
                          ),

                          const SizedBox(height: 8),
                        ],
                      ),
                    ),
                  ),
                ],
              ),
            ),

            // ── [5] Add-participant panel — on top of chrome/controls ──────
            AnimatedPositioned(
              duration: const Duration(milliseconds: 300),
              curve: Curves.easeOutCubic,
              left: 0, right: 0,
              bottom: _showAddPanel ? 0 : -520,
              child: _AddParticipantPanel(
                participants: info.addableParticipants,
                alreadyJoined: info.participants,
                pendingInvites: _pendingInvites,
                onAdd: _inviteParticipant,
                onRetry: _inviteParticipant,
                onClose: () => setState(() => _showAddPanel = false),
              ),
            ),

            // ── [6] Group members panel — on top of chrome/controls ────────
            AnimatedPositioned(
              duration: const Duration(milliseconds: 300),
              curve: Curves.easeOutCubic,
              left: 0, right: 0,
              bottom: _showMembersPanel ? 0 : -520,
              child: _GroupMembersPanel(
                allInvited: info.participants,
                pendingInvites: _pendingInvites,
                lkRoom: lkRoom,
                selfUserId: lkRoom?.localParticipant?.identity,
                selfPhoneNumber: info.localUserNumber,
                leftParticipants: _leftParticipants,
                invitedAt: _invitedAt,
                participantPhoneMap: info.participantPhoneMap,
                onClose: () => setState(() => _showMembersPanel = false),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildCenterContent({
    required TringupCallInfo info,
    required lk.Room? lkRoom,
    required bool hasRemoteVideo,
    required bool isGroupVideoActive,
  }) {
    // Pre-connect (incoming or outgoing): always show the simple avatar center.
    // For incoming group calls the receiver should see caller info + Decline/Answer,
    // not a participant grid (there are no joined members yet anyway).
    if (!info.isConnected) {
      return _AudioOneOnOneCenter(info: info);
    }
    // Busy signal — remote party is in another call; auto-dismisses after 2s
    if (info.busySignal) {
      return _BusySignalView(displayName: info.displayName ?? info.number);
    }
    // Group video: grid is in background, chrome overlay is transparent
    if (isGroupVideoActive) return const SizedBox.shrink();

    // 1:1 video: remote video fills background
    if (hasRemoteVideo && !info.isGroupCall) return const SizedBox.shrink();

    // Audio group call — only switch to the grid once the LiveKit room has
    // actual remote participants. info.participants is pre-populated from the
    // invite payload before acceptance, so it cannot be used as the gate.
    if (info.isGroupCall &&
        lkRoom != null &&
        lkRoom.remoteParticipants.isNotEmpty) {
      // Prefer contact-resolved participants from info; fall back to LiveKit
      // identities so names always appear even if conference state is stale.
      final gridParticipants = info.participants.isNotEmpty
          ? info.participants
          : lkRoom.remoteParticipants.values
              .map((rp) => TringupParticipant(
                    userId: rp.identity,
                    displayName: rp.name.isNotEmpty ? rp.name : null,
                  ))
              .toList();
      return _AudioGroupGrid(
        participants: gridParticipants,
        activeSpeakerId: _activeSpeakerId,
        livekitRoom: lkRoom,
      );
    }

    // Audio 1:1, or group call waiting for LiveKit remote participants (P3)
    return _AudioOneOnOneCenter(info: info);
  }
}

// ═════════════════════════════════════════════════════════════════════════════
// P2 — Top header
// ═════════════════════════════════════════════════════════════════════════════

class _CallHeader extends StatelessWidget {
  const _CallHeader({
    required this.info,
    required this.showMembersPanel,
    required this.showAddPanel,
    required this.hasAddAction,
    required this.onMinimize,
    required this.onToggleMembers,
    required this.onToggleAdd,
  });

  final TringupCallInfo info;
  final bool showMembersPanel;
  final bool showAddPanel;
  final bool hasAddAction;
  final VoidCallback onMinimize;
  final VoidCallback onToggleMembers;
  final VoidCallback onToggleAdd;

  String _statusLabel() {
    if (info.isConnected && info.connectedAt != null) {
      final elapsed = DateTime.now().difference(info.connectedAt!);
      final h = elapsed.inHours;
      final m = elapsed.inMinutes.remainder(60).toString().padLeft(2, '0');
      final s = elapsed.inSeconds.remainder(60).toString().padLeft(2, '0');
      return h > 0 ? '$h:$m:$s' : '$m:$s';
    }
    if (info.isIncoming && !info.isConnected) return 'Incoming call';
    if (!info.isIncoming && !info.isConnected && info.isRinging) return 'Ringing…';
    return 'Calling…';
  }

  @override
  Widget build(BuildContext context) {
    final hasRightAction = info.isGroupCall || hasAddAction;
    final rightActive = info.isGroupCall ? showMembersPanel : showAddPanel;

    return Padding(
      padding: const EdgeInsets.fromLTRB(4, 4, 8, 0),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          // Minimize
          IconButton(
            icon: const Icon(Icons.keyboard_arrow_down_rounded,
                color: Colors.white70, size: 32),
            onPressed: onMinimize,
            tooltip: 'Minimize',
          ),

          // Title block
          Expanded(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  info.callerLabel,
                  style: const TextStyle(
                    color: Colors.white,
                    fontSize: 18,
                    fontWeight: FontWeight.w600,
                    letterSpacing: 0.2,
                  ),
                  textAlign: TextAlign.center,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
                const SizedBox(height: 2),
                Text(
                  _statusLabel(),
                  style: TextStyle(
                    color: info.isConnected ? _kGreen : _kTextSecondary,
                    fontSize: 13,
                  ),
                  textAlign: TextAlign.center,
                ),
                const SizedBox(height: 3),
                Row(
                  mainAxisSize: MainAxisSize.min,
                  children: const [
                    Icon(Icons.lock_rounded, color: Colors.white38, size: 10),
                    SizedBox(width: 3),
                    Text('End-to-end encrypted',
                        style: TextStyle(color: Colors.white38, fontSize: 10)),
                  ],
                ),
              ],
            ),
          ),

          // Right action: Members / Add
          if (hasRightAction)
            GestureDetector(
              onTap: info.isGroupCall ? onToggleMembers : onToggleAdd,
              child: AnimatedContainer(
                duration: const Duration(milliseconds: 150),
                width: 40,
                height: 40,
                margin: const EdgeInsets.only(right: 4),
                decoration: BoxDecoration(
                  color: rightActive ? _kControlActive : _kControlBg,
                  borderRadius: BorderRadius.circular(12),
                ),
                child: Icon(
                  info.isGroupCall ? Icons.group_rounded : Icons.person_add_rounded,
                  color: Colors.white,
                  size: 20,
                ),
              ),
            )
          else
            const SizedBox(width: 48),
        ],
      ),
    );
  }
}

// ═════════════════════════════════════════════════════════════════════════════
// P3 — Audio 1:1 center content
// ═════════════════════════════════════════════════════════════════════════════

class _AudioOneOnOneCenter extends StatelessWidget {
  const _AudioOneOnOneCenter({required this.info});

  final TringupCallInfo info;

  @override
  Widget build(BuildContext context) {
    return Column(
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        // Avatar with speaking pulse rings
        SizedBox(
          width: 220,
          height: 220,
          child: Stack(
            alignment: Alignment.center,
            children: [
              _SpeakingPulse(
                active: info.isConnected,
                radius: 52,
                color: _kGreen,
              ),
              _CallerAvatar(info: info, radius: 52),
            ],
          ),
        ),
        const SizedBox(height: 20),
        // Name
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 32),
          child: Text(
            info.callerLabel,
            style: const TextStyle(
              color: Colors.white,
              fontSize: 26,
              fontWeight: FontWeight.w600,
              letterSpacing: 0.3,
            ),
            textAlign: TextAlign.center,
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
          ),
        ),
        // Phone number (if different from display name)
        if (info.displayName != null && info.displayName!.isNotEmpty) ...[
          const SizedBox(height: 6),
          Text(
            info.number,
            style: const TextStyle(color: Colors.white54, fontSize: 14),
            textAlign: TextAlign.center,
          ),
        ],
      ],
    );
  }
}

// ── Speaking pulse (3 expanding rings) ───────────────────────────────────────

class _SpeakingPulse extends StatefulWidget {
  const _SpeakingPulse({
    required this.active,
    required this.radius,
    required this.color,
  });

  final bool active;
  final double radius;
  final Color color;

  @override
  State<_SpeakingPulse> createState() => _SpeakingPulseState();
}

class _SpeakingPulseState extends State<_SpeakingPulse>
    with SingleTickerProviderStateMixin {
  late AnimationController _ctrl;

  @override
  void initState() {
    super.initState();
    _ctrl = AnimationController(
        vsync: this, duration: const Duration(milliseconds: 1800));
    if (widget.active) _ctrl.repeat();
  }

  @override
  void didUpdateWidget(_SpeakingPulse old) {
    super.didUpdateWidget(old);
    if (widget.active != old.active) {
      if (widget.active) {
        _ctrl.repeat();
      } else {
        _ctrl.stop();
        _ctrl.value = 0;
      }
    }
  }

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (!widget.active) return const SizedBox.shrink();
    return AnimatedBuilder(
      animation: _ctrl,
      builder: (_, __) {
        return SizedBox(
          width: (widget.radius + 68) * 2,
          height: (widget.radius + 68) * 2,
          child: Stack(
            alignment: Alignment.center,
            children: List.generate(3, (i) {
              final startT = i / 3.0;
              double t = (_ctrl.value - startT) % 1.0;
              if (t < 0) t += 1.0;
              final scale = 1.0 + Curves.easeOutCubic.transform(t) * 0.65;
              final opacity = (1.0 - Curves.easeOut.transform(t)) * 0.45;
              if (opacity < 0.01) return const SizedBox.shrink();
              return Transform.scale(
                scale: scale,
                child: Container(
                  width: widget.radius * 2,
                  height: widget.radius * 2,
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    border: Border.all(
                      color: widget.color.withOpacity(opacity),
                      width: 2,
                    ),
                  ),
                ),
              );
            }),
          ),
        );
      },
    );
  }
}

// ═════════════════════════════════════════════════════════════════════════════
// P4 — Audio group grid
// ═════════════════════════════════════════════════════════════════════════════

class _AudioGroupGrid extends StatelessWidget {
  const _AudioGroupGrid({
    required this.participants,
    required this.activeSpeakerId,
    this.livekitRoom,
  });

  final List<TringupParticipant> participants;
  final String? activeSpeakerId;
  final lk.Room? livekitRoom;

  bool _isMuted(String userId) {
    final remote = livekitRoom?.remoteParticipants[userId];
    if (remote == null) return false;
    return remote.audioTrackPublications.any((p) => p.muted);
  }

  @override
  Widget build(BuildContext context) {
    if (participants.isEmpty) {
      return const Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.groups_rounded, color: Colors.white24, size: 64),
            SizedBox(height: 16),
            Text('Waiting for others to join…',
                style: TextStyle(color: Colors.white38, fontSize: 15)),
          ],
        ),
      );
    }

    return GridView.builder(
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 8),
      physics: const BouncingScrollPhysics(),
      gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
        crossAxisCount: 2,
        childAspectRatio: 1.0,
        crossAxisSpacing: 12,
        mainAxisSpacing: 12,
      ),
      itemCount: participants.length,
      itemBuilder: (_, i) {
        final p = participants[i];
        return _AudioParticipantTile(
          participant: p,
          isSpeaking: activeSpeakerId == p.userId,
          isMuted: _isMuted(p.userId),
        );
      },
    );
  }
}

// ── Audio participant tile ────────────────────────────────────────────────────

class _AudioParticipantTile extends StatelessWidget {
  const _AudioParticipantTile({
    required this.participant,
    required this.isSpeaking,
    required this.isMuted,
  });

  final TringupParticipant participant;
  final bool isSpeaking;
  final bool isMuted;

  @override
  Widget build(BuildContext context) {
    return AnimatedContainer(
      duration: const Duration(milliseconds: 300),
      decoration: BoxDecoration(
        color: _kBgSurface,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(
          color: isSpeaking ? _kGreen.withOpacity(0.8) : Colors.transparent,
          width: 2.5,
        ),
        boxShadow: isSpeaking
            ? [
                BoxShadow(
                    color: _kGreen.withOpacity(0.28),
                    blurRadius: 14,
                    spreadRadius: 2)
              ]
            : [],
      ),
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Stack(
            children: [
              _ParticipantAvatar(participant: participant, radius: 28),
              if (isMuted)
                Positioned(
                  right: 0,
                  bottom: 0,
                  child: Container(
                    width: 18,
                    height: 18,
                    decoration: const BoxDecoration(
                        shape: BoxShape.circle, color: _kRed),
                    child: const Icon(Icons.mic_off_rounded,
                        color: Colors.white, size: 11),
                  ),
                ),
            ],
          ),
          const SizedBox(height: 10),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 8),
            child: Text(
              participant.label,
              style: const TextStyle(
                  color: Colors.white,
                  fontSize: 13,
                  fontWeight: FontWeight.w500),
              textAlign: TextAlign.center,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
            ),
          ),
          if (isSpeaking) ...[
            const SizedBox(height: 8),
            const _SpeakingWave(),
          ],
        ],
      ),
    );
  }
}

// ── Animated speaking wave bars ───────────────────────────────────────────────

class _SpeakingWave extends StatefulWidget {
  const _SpeakingWave();

  @override
  State<_SpeakingWave> createState() => _SpeakingWaveState();
}

class _SpeakingWaveState extends State<_SpeakingWave>
    with SingleTickerProviderStateMixin {
  late AnimationController _ctrl;

  @override
  void initState() {
    super.initState();
    _ctrl = AnimationController(
        vsync: this, duration: const Duration(milliseconds: 700))
      ..repeat();
  }

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: _ctrl,
      builder: (_, __) {
        return Row(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.end,
          children: List.generate(4, (i) {
            final t = (_ctrl.value + i * 0.25) % 1.0;
            final h = 4.0 + math.sin(t * math.pi) * 10.0;
            return Container(
              width: 3,
              height: h,
              margin: const EdgeInsets.symmetric(horizontal: 1.5),
              decoration: BoxDecoration(
                color: _kGreen,
                borderRadius: BorderRadius.circular(2),
              ),
            );
          }),
        );
      },
    );
  }
}

// ═════════════════════════════════════════════════════════════════════════════
// P1 — Unified control bar
// ═════════════════════════════════════════════════════════════════════════════

class _ControlBar extends StatelessWidget {
  const _ControlBar({
    required this.info,
    required this.actions,
    required this.isSpeaker,
    required this.isBluetooth,
  });

  final TringupCallInfo info;
  final TringupCallActions actions;
  final bool isSpeaker;
  final bool isBluetooth;

  @override
  Widget build(BuildContext context) {
    // Incoming: Decline + Answer
    if (!info.isConnected && info.isIncoming) {
      return _buildIncomingBar();
    }
    // Connected
    if (info.isConnected) {
      return info.isVideoCall ? _buildVideoBar() : _buildAudioBar();
    }
    // Outgoing pre-connect
    return _buildOutgoingBar();
  }

  // ── Incoming ──────────────────────────────────────────────────────────────
  Widget _buildIncomingBar() {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 48, vertical: 8),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceEvenly,
        children: [
          _LabelledButton(
            button: _PrimaryButton(
              icon: Icons.call_end_rounded,
              color: _kRed,
              onTap: actions.hangUp,
            ),
            label: 'Decline',
          ),
          _LabelledButton(
            button: _PrimaryButton(
              icon: Icons.call_rounded,
              color: _kGreen,
              onTap: actions.answer!,
            ),
            label: 'Answer',
          ),
        ],
      ),
    );
  }

  // ── Outgoing pre-connect ──────────────────────────────────────────────────
  Widget _buildOutgoingBar() {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 8),
      child: Center(
        child: _LabelledButton(
          button: _PrimaryButton(
            icon: Icons.call_end_rounded,
            color: _kRed,
            onTap: actions.hangUp,
          ),
          label: 'End',
        ),
      ),
    );
  }

  // ── Connected audio ───────────────────────────────────────────────────────
  Widget _buildAudioBar() {
    final speakerIcon = isBluetooth
        ? Icons.bluetooth_audio_rounded
        : (isSpeaker ? Icons.volume_up_rounded : Icons.volume_down_rounded);

    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 8),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceEvenly,
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          _SquircleButton(
            icon: speakerIcon,
            label: 'Speaker',
            active: isSpeaker,
            activeColor: _kTeal.withOpacity(0.45),
            onTap: () => actions.setSpeaker(!isSpeaker),
          ),
          _SquircleButton(
            icon: info.isMuted ? Icons.mic_off_rounded : Icons.mic_rounded,
            label: info.isMuted ? 'Unmute' : 'Mute',
            active: info.isMuted,
            activeColor: _kRed.withOpacity(0.35),
            onTap: () => actions.setMuted(!info.isMuted),
          ),
          _LabelledButton(
            button: _PrimaryButton(
              icon: Icons.call_end_rounded,
              color: _kRed,
              onTap: actions.hangUp,
            ),
            label: '',
          ),
          // Upgrade audio → video call. The CallBloc sets call.video=true on
          // first camera activation, which flips isVideoCall and switches the
          // control bar to _buildVideoBar() where camera on/off is handled.
          _SquircleButton(
            icon: Icons.videocam_rounded,
            label: 'Switch to video',
            active: false,
            onTap: () => actions.setCameraEnabled(true),
          ),
        ],
      ),
    );
  }

  // ── Connected video ───────────────────────────────────────────────────────
  Widget _buildVideoBar() {
    final speakerIcon = isBluetooth
        ? Icons.bluetooth_audio_rounded
        : (isSpeaker ? Icons.volume_up_rounded : Icons.volume_down_rounded);

    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceEvenly,
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          _SquircleButton(
            icon: speakerIcon,
            label: 'Speaker',
            active: isSpeaker,
            activeColor: _kTeal.withOpacity(0.45),
            onTap: () => actions.setSpeaker(!isSpeaker),
          ),
          _SquircleButton(
            icon: info.isMuted ? Icons.mic_off_rounded : Icons.mic_rounded,
            label: info.isMuted ? 'Unmute' : 'Mute',
            active: info.isMuted,
            activeColor: _kRed.withOpacity(0.35),
            onTap: () => actions.setMuted(!info.isMuted),
          ),
          _LabelledButton(
            button: _PrimaryButton(
              icon: Icons.call_end_rounded,
              color: _kRed,
              onTap: actions.hangUp,
            ),
            label: '',
          ),
          _SquircleButton(
            icon: info.isCameraEnabled
                ? Icons.videocam_rounded
                : Icons.videocam_off_rounded,
            label: info.isCameraEnabled ? 'Cam off' : 'Cam on',
            active: !info.isCameraEnabled,
            onTap: () => actions.setCameraEnabled(!info.isCameraEnabled),
          ),
        ],
      ),
    );
  }
}

// ── Labelled button wrapper (adds label below any widget) ────────────────────

class _LabelledButton extends StatelessWidget {
  const _LabelledButton({required this.button, required this.label});
  final Widget button;
  final String label;

  @override
  Widget build(BuildContext context) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        button,
        if (label.isNotEmpty) ...[
          const SizedBox(height: 6),
          Text(label,
              style: const TextStyle(color: _kTextSecondary, fontSize: 12)),
        ] else
          const SizedBox(height: 20),
      ],
    );
  }
}

// ═════════════════════════════════════════════════════════════════════════════
// P1 — Reusable buttons
// ═════════════════════════════════════════════════════════════════════════════

/// Squircle (rounded-rect) secondary control button with press-scale animation.
class _SquircleButton extends StatefulWidget {
  const _SquircleButton({
    required this.icon,
    required this.label,
    this.active = false,
    this.activeColor,
    this.iconColor,
    this.onTap,
  });

  final IconData icon;
  final String label;
  final bool active;
  final Color? activeColor;
  final Color? iconColor;
  final VoidCallback? onTap;

  @override
  State<_SquircleButton> createState() => _SquircleButtonState();
}

class _SquircleButtonState extends State<_SquircleButton>
    with SingleTickerProviderStateMixin {
  late AnimationController _ctrl;
  late Animation<double> _scale;

  @override
  void initState() {
    super.initState();
    _ctrl = AnimationController(
        vsync: this, duration: const Duration(milliseconds: 80));
    _scale = Tween<double>(begin: 1.0, end: 0.92)
        .animate(CurvedAnimation(parent: _ctrl, curve: Curves.easeIn));
  }

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final enabled = widget.onTap != null;
    final bg = widget.active
        ? (widget.activeColor ?? _kControlActive)
        : _kControlBg;

    return GestureDetector(
      onTapDown: enabled ? (_) => _ctrl.forward() : null,
      onTapUp: enabled
          ? (_) {
              _ctrl.reverse();
              widget.onTap!();
            }
          : null,
      onTapCancel: () => _ctrl.reverse(),
      child: AnimatedBuilder(
        animation: _scale,
        builder: (_, child) =>
            Transform.scale(scale: _scale.value, child: child),
        child: Opacity(
          opacity: enabled ? 1.0 : 0.38,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              AnimatedContainer(
                duration: const Duration(milliseconds: 150),
                width: 56,
                height: 56,
                decoration: BoxDecoration(
                  color: bg,
                  borderRadius: BorderRadius.circular(16),
                ),
                child: Icon(
                  widget.icon,
                  color: widget.iconColor ?? Colors.white,
                  size: 24,
                ),
              ),
              const SizedBox(height: 6),
              Text(
                widget.label,
                style: const TextStyle(color: _kTextSecondary, fontSize: 11),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// Large circular primary button (end call / answer) with press-scale + glow.
class _PrimaryButton extends StatefulWidget {
  const _PrimaryButton({
    required this.icon,
    required this.color,
    required this.onTap,
    this.size = 68,
  });

  final IconData icon;
  final Color color;
  final VoidCallback onTap;
  final double size;

  @override
  State<_PrimaryButton> createState() => _PrimaryButtonState();
}

class _PrimaryButtonState extends State<_PrimaryButton>
    with SingleTickerProviderStateMixin {
  late AnimationController _ctrl;
  late Animation<double> _scale;

  @override
  void initState() {
    super.initState();
    _ctrl = AnimationController(
        vsync: this, duration: const Duration(milliseconds: 80));
    _scale = Tween<double>(begin: 1.0, end: 0.91)
        .animate(CurvedAnimation(parent: _ctrl, curve: Curves.easeIn));
  }

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTapDown: (_) => _ctrl.forward(),
      onTapUp: (_) {
        _ctrl.reverse();
        widget.onTap();
      },
      onTapCancel: () => _ctrl.reverse(),
      child: AnimatedBuilder(
        animation: _scale,
        builder: (_, child) =>
            Transform.scale(scale: _scale.value, child: child),
        child: Container(
          width: widget.size,
          height: widget.size,
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            color: widget.color,
            boxShadow: [
              BoxShadow(
                color: widget.color.withOpacity(0.45),
                blurRadius: 20,
                spreadRadius: 2,
              ),
            ],
          ),
          child: Icon(widget.icon,
              color: Colors.white, size: widget.size * 0.44),
        ),
      ),
    );
  }
}

// ═════════════════════════════════════════════════════════════════════════════
// P5 — PiP window widget
// ═════════════════════════════════════════════════════════════════════════════

class _PipWindow extends StatelessWidget {
  const _PipWindow({
    required this.width,
    required this.height,
    required this.localVideoTrack,
    required this.localStream,
    required this.mirrorLocalVideo,
    required this.onSwitchCamera,
    this.borderRadius = 14,
  });

  final double width;
  final double height;
  final lk.VideoTrack? localVideoTrack;
  final MediaStream? localStream;
  final bool mirrorLocalVideo;
  final double borderRadius;
  final VoidCallback? onSwitchCamera;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: width,
      height: height,
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(borderRadius),
        border: Border.all(color: Colors.white30, width: 2),
        boxShadow: [
          BoxShadow(
              color: Colors.black.withOpacity(0.5),
              blurRadius: 16,
              offset: const Offset(0, 4)),
        ],
      ),
      child: Stack(
        children: [
          ClipRRect(
            borderRadius: BorderRadius.circular(borderRadius - 1),
            // IgnorePointer prevents flutter_webrtc from invoking setFocusPoint /
            // setExposurePoint on tap, which crashes when no camera track is active.
            child: IgnorePointer(
              child: localVideoTrack != null
                  ? lk.VideoTrackRenderer(
                      localVideoTrack!,
                      fit: lk.VideoViewFit.cover,
                      mirrorMode: mirrorLocalVideo
                          ? lk.VideoViewMirrorMode.mirror
                          : lk.VideoViewMirrorMode.off,
                    )
                  : localStream != null
                      ? RTCStreamView(
                          stream: localStream,
                          mirror: mirrorLocalVideo,
                        )
                      : const ColoredBox(
                          color: Color(0xFF1A2233),
                          child: Center(
                            child: Icon(Icons.videocam_off_rounded,
                                color: Colors.white30, size: 28),
                          ),
                        ),
            ),
          ),
          if (onSwitchCamera != null && localVideoTrack != null)
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
        ],
      ),
    );
  }
}

// ═════════════════════════════════════════════════════════════════════════════
// P6 — Sliding panels (refreshed visuals, same logic)
// ═════════════════════════════════════════════════════════════════════════════

class _AddParticipantPanel extends StatelessWidget {
  const _AddParticipantPanel({
    required this.participants,
    required this.alreadyJoined,
    required this.pendingInvites,
    required this.onAdd,
    required this.onRetry,
    required this.onClose,
  });

  final List<TringupParticipant> participants;
  final List<TringupParticipant> alreadyJoined;
  final Map<String, _PendingInvite> pendingInvites;
  final void Function(TringupParticipant) onAdd;
  final void Function(TringupParticipant) onRetry;
  final VoidCallback onClose;

  @override
  Widget build(BuildContext context) {
    final joinedIds = alreadyJoined.map((p) => p.userId).toSet();
    final calling = participants
        .where((p) => pendingInvites[p.userId]?.state == _InviteState.calling)
        .toList();
    final ringing = participants
        .where((p) => pendingInvites[p.userId]?.state == _InviteState.ringing)
        .toList();
    final failed = participants
        .where((p) => pendingInvites[p.userId]?.state == _InviteState.failed)
        .toList();
    final available = participants
        .where((p) =>
            !joinedIds.contains(p.userId) &&
            !pendingInvites.containsKey(p.userId))
        .toList();

    return Container(
      decoration: BoxDecoration(
        color: _kBgSurface,
        borderRadius: const BorderRadius.vertical(top: Radius.circular(24)),
        border: const Border(
            top: BorderSide(color: Colors.white12, width: 1)),
      ),
      child: SafeArea(
        top: false,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            _PanelHandle(),
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 8, 8, 4),
              child: Row(children: [
                const Expanded(
                    child: Text('Add to call',
                        style: TextStyle(
                            color: Colors.white,
                            fontSize: 16,
                            fontWeight: FontWeight.w600))),
                IconButton(
                    icon: const Icon(Icons.close,
                        color: Colors.white54, size: 20),
                    onPressed: onClose),
              ]),
            ),
            const Divider(color: Colors.white12, height: 1),
            ConstrainedBox(
              constraints: const BoxConstraints(maxHeight: 360),
              child: (calling.isEmpty &&
                      ringing.isEmpty &&
                      failed.isEmpty &&
                      available.isEmpty)
                  ? const Padding(
                      padding: EdgeInsets.symmetric(vertical: 28),
                      child: Text('No contacts available to add',
                          style: TextStyle(
                              color: Colors.white38, fontSize: 14)),
                    )
                  : ListView(shrinkWrap: true, children: [
                      if (calling.isNotEmpty) _PanelSectionHeader('Calling…'),
                      ...calling.map((p) => _PanelTile(
                            participant: p,
                            subtitleText: 'Calling…',
                            subtitleColor: Colors.white38,
                            trailing: const _SpinnerIndicator(
                                color: Colors.white38),
                          )),
                      if (ringing.isNotEmpty) _PanelSectionHeader('Ringing…'),
                      ...ringing.map((p) => _PanelTile(
                            participant: p,
                            subtitleText: 'Ringing…',
                            subtitleColor: _kGreen,
                            trailing:
                                const _SpinnerIndicator(color: _kGreen),
                          )),
                      if (failed.isNotEmpty) _PanelSectionHeader('Failed'),
                      ...failed.map((p) => _PanelTile(
                            participant: p,
                            subtitleText: 'Call failed',
                            subtitleColor: Colors.redAccent,
                            trailing: IconButton(
                              icon: const Icon(Icons.refresh,
                                  color: Colors.redAccent, size: 22),
                              onPressed: () => onRetry(p),
                            ),
                          )),
                      if (available.isNotEmpty &&
                          (calling.isNotEmpty || failed.isNotEmpty))
                        _PanelSectionHeader('Contacts'),
                      ...available.map((p) => _PanelTile(
                            participant: p,
                            subtitleText: p.phoneNumber,
                            subtitleColor: Colors.white38,
                            trailing: IconButton(
                              icon: const Icon(Icons.add_call,
                                  color: _kGreen, size: 22),
                              onPressed: () => onAdd(p),
                            ),
                          )),
                    ]),
            ),
            const SizedBox(height: 8),
          ],
        ),
      ),
    );
  }
}

class _GroupMembersPanel extends StatelessWidget {
  const _GroupMembersPanel({
    required this.allInvited,
    required this.pendingInvites,
    required this.onClose,
    this.lkRoom,
    this.selfUserId,
    this.selfPhoneNumber,
    this.leftParticipants = const {},
    this.invitedAt = const {},
    this.participantPhoneMap = const {},
  });

  /// All invited participants (from conferenceParticipants via BLoC).
  /// Populated on BOTH sides from the server's call_invite payload.
  final List<TringupParticipant> allInvited;

  /// LiveKit room — used to determine who has actually connected.
  final lk.Room? lkRoom;

  /// Caller-side explicit invites (via the "Add" button).  Empty on receiver.
  final Map<String, _PendingInvite> pendingInvites;
  final VoidCallback onClose;

  /// The local user's LiveKit identity — used to show "You | In call" entry
  /// and exclude self from the Ringing/Connected buckets.
  final String? selfUserId;

  /// The local user's own phone number — used when allInvited stores phone
  /// numbers as userId (as on the receiver side) instead of server identities.
  final String? selfPhoneNumber;

  /// Participants who were in the call but have since left.
  /// Key = LiveKit identity; value = participant info for display.
  final Map<String, TringupParticipant> leftParticipants;

  /// Timestamps when server-invited participants first appeared in waitingToJoin.
  /// Used to detect no-answer timeouts.
  final Map<String, DateTime> invitedAt;

  /// serverUserId → phoneNumber mapping from BLoC.
  /// Enables cross-namespace matching when caller pre-populates with phone
  /// numbers but LiveKit uses server IDs.
  final Map<String, String> participantPhoneMap;

  @override
  Widget build(BuildContext context) {
    final lkConnectedIds = lkRoom?.remoteParticipants.keys.toSet() ?? {};
    final pendingIds = pendingInvites.keys.toSet();

    String normalize(String id) => id.trim();

    // Build reverse map: phoneNumber → serverUserId for cross-namespace matching.
    // participantPhoneMap: serverUserId → phoneNumber
    final phoneToServerId = <String, String>{};
    for (final entry in participantPhoneMap.entries) {
      phoneToServerId[entry.value] = entry.key;
    }

    bool isSelf(TringupParticipant p) {
      final uid = normalize(p.userId);
      if (uid == selfUserId) return true;
      if (uid == selfPhoneNumber) return true;
      if (selfPhoneNumber != null && p.phoneNumber == selfPhoneNumber) return true;
      return false;
    }

    bool isConnectedInLk(TringupParticipant p) {
      final uid = normalize(p.userId);
      if (lkConnectedIds.contains(uid)) return true;
      // userId may be a phone number — look up the server ID via the reverse map.
      final serverId = phoneToServerId[uid] ??
          (p.phoneNumber != null ? phoneToServerId[p.phoneNumber!] : null);
      return serverId != null && lkConnectedIds.contains(serverId);
    }

    const inviteTimeout = Duration(seconds: 60);
    final now = DateTime.now();

    final List<TringupParticipant> connected = [];
    final List<TringupParticipant> ringing = [];
    final List<TringupParticipant> invited = [];
    final List<TringupParticipant> timedOut = [];

    TringupParticipant? selfParticipant;

    for (final p in allInvited) {
      final uid = normalize(p.userId);

      if (isSelf(p)) {
        selfParticipant = TringupParticipant(
          userId: uid,
          displayName: 'You',
          photoUrl: p.photoUrl,
          photoPath: p.photoPath,
        );
        continue;
      }

      if (pendingIds.contains(uid)) continue;

      final isConnected = isConnectedInLk(p);

      if (isConnected) {
        connected.add(p);
        continue;
      }

      final inviteTime = invitedAt[uid];

      if (inviteTime == null) {
        invited.add(p);
        continue;
      }

      final diff = now.difference(inviteTime);

      if (diff >= inviteTimeout) {
        timedOut.add(p);
      } else {
        ringing.add(p);
      }
    }

    final calling = pendingInvites.values
        .where((i) => i.state == _InviteState.calling)
        .toList();

    final ringingExplicit = pendingInvites.values
        .where((i) => i.state == _InviteState.ringing)
        .toList();

    final failed = pendingInvites.values
        .where((i) => i.state == _InviteState.failed)
        .toList();

    final allRinging = [
      ...ringing,
      ...ringingExplicit.map((e) => e.participant),
    ];

    int sortFn(TringupParticipant a, TringupParticipant b) =>
        (a.displayName ?? '').compareTo(b.displayName ?? '');

    connected.sort(sortFn);
    allRinging.sort(sortFn);
    invited.sort(sortFn);
    timedOut.sort(sortFn);

    // ─────────────────────────────────────────────────────────────
    // DEBUG LOGGING (VERY IMPORTANT)
    // ─────────────────────────────────────────────────────────────

    String listToString(List<TringupParticipant> list) =>
        list.map((e) => "${e.userId}(${e.displayName})").join(", ");

    // debugPrint("══════════ GROUP PANEL DEBUG ══════════");
    //
    // debugPrint("ALL INVITED:");
    // debugPrint(listToString(allInvited));
    //
    // debugPrint("CONNECTED (${connected.length}):");
    // debugPrint(listToString(connected));
    //
    // debugPrint("RINGING (server + explicit) (${allRinging.length}):");
    // debugPrint(listToString(allRinging));
    //
    // debugPrint("INVITED (${invited.length}):");
    // debugPrint(listToString(invited));
    //
    // debugPrint("TIMEOUT (${timedOut.length}):");
    // debugPrint(listToString(timedOut));
    //
    // debugPrint("CALLING (${calling.length}):");
    // debugPrint(calling
    //     .map((e) => "${e.participant.userId}(${e.participant.displayName})")
    //     .join(", "));
    //
    // debugPrint("FAILED (${failed.length}):");
    // debugPrint(failed
    //     .map((e) => "${e.participant.userId}(${e.participant.displayName})")
    //     .join(", "));
    //
    // debugPrint("SELF:");
    // debugPrint(selfParticipant?.userId ?? "NULL");
    //
    // debugPrint("LIVEKIT CONNECTED IDS:");
    // debugPrint(lkConnectedIds.join(", "));
    //
    // debugPrint("PENDING IDS:");
    // debugPrint(pendingIds.join(", "));
    //
    // debugPrint("PARTICIPANT PHONE MAP (serverId→phone):");
    // debugPrint(participantPhoneMap.entries.map((e) => "${e.key}→${e.value}").join(", "));
    //
    // debugPrint("selfUserId: $selfUserId | selfPhoneNumber: $selfPhoneNumber");
    //
    // debugPrint("════════════════════════════════════════");

    final totalKnown = (selfParticipant != null ? 1 : 0) +
        connected.length +
        allRinging.length +
        invited.length +
        timedOut.length +
        calling.length +
        failed.length;

    final isEmpty = totalKnown == 0;

    return Container(
      decoration: BoxDecoration(
        color: _kBgSurface,
        borderRadius: const BorderRadius.vertical(top: Radius.circular(24)),
        border: const Border(top: BorderSide(color: Colors.white12, width: 1)),
      ),
      child: SafeArea(
        top: false,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            _PanelHandle(),

            Padding(
              padding: const EdgeInsets.fromLTRB(16, 8, 8, 4),
              child: Row(children: [
                Expanded(
                  child: Text(
                    totalKnown > 0
                        ? 'Group members ($totalKnown)'
                        : 'Group members',
                    style: const TextStyle(
                        color: Colors.white,
                        fontSize: 16,
                        fontWeight: FontWeight.w600),
                  ),
                ),
                IconButton(
                  icon: const Icon(Icons.close,
                      color: Colors.white54, size: 20),
                  onPressed: onClose,
                ),
              ]),
            ),

            const Divider(color: Colors.white12, height: 1),

            ConstrainedBox(
              constraints: const BoxConstraints(maxHeight: 360),
              child: isEmpty
                  ? const Padding(
                padding: EdgeInsets.symmetric(vertical: 28),
                child: Center(
                  child: Text(
                    'Waiting for members to join…',
                    style: TextStyle(color: Colors.white38),
                  ),
                ),
              )
                  : ListView(
                shrinkWrap: true,
                children: [
                  if (selfParticipant != null) ...[
                    _PanelSectionHeader('You'),
                    _PanelTile(
                      participant: selfParticipant,
                      subtitleText: 'In call',
                      subtitleColor: _kGreen,
                      trailing: _StatusChip(
                          label: 'Connected', color: _kGreen),
                    ),
                  ],

                  if (connected.isNotEmpty)
                    _PanelSectionHeader('Connected'),
                  ...connected.map((p) => _PanelTile(
                    participant: p,
                    subtitleText: 'In call',
                    subtitleColor: _kGreen,
                    trailing: _StatusChip(
                        label: 'Connected', color: _kGreen),
                  )),

                  if (allRinging.isNotEmpty)
                    _PanelSectionHeader('Ringing'),
                  ...allRinging.map((p) => _PanelTile(
                    participant: p,
                    subtitleText: 'Phone is ringing…',
                    subtitleColor: _kGreen,
                    trailing:
                    const _SpinnerIndicator(color: _kGreen),
                  )),

                  if (invited.isNotEmpty)
                    _PanelSectionHeader('Invited'),
                  ...invited.map((p) => _PanelTile(
                    participant: p,
                    subtitleText: 'Waiting for response…',
                    subtitleColor: Colors.white38,
                    trailing: const _SpinnerIndicator(
                        color: Colors.white38),
                  )),

                  if (timedOut.isNotEmpty)
                    _PanelSectionHeader('Not picked up'),
                  ...timedOut.map((p) => _PanelTile(
                    participant: p,
                    subtitleText: 'Did not answer',
                    subtitleColor: Colors.redAccent,
                    trailing: _StatusChip(
                        label: 'No answer',
                        color: Colors.redAccent),
                  )),

                  if (calling.isNotEmpty)
                    _PanelSectionHeader('Calling…'),
                  ...calling.map((inv) => _PanelTile(
                    participant: inv.participant,
                    subtitleText: 'Dialling…',
                    subtitleColor: Colors.white38,
                    trailing: const _SpinnerIndicator(
                        color: Colors.white38),
                  )),

                  if (failed.isNotEmpty)
                    _PanelSectionHeader('Not picked up'),
                  ...failed.map((inv) => _PanelTile(
                    participant: inv.participant,
                    subtitleText: 'Did not answer',
                    subtitleColor: Colors.redAccent,
                    trailing: _StatusChip(
                        label: 'No answer',
                        color: Colors.redAccent),
                  )),
                ],
              ),
            ),
            const SizedBox(height: 8),
          ],
        ),
      ),
    );
  }
}

// ── Panel shared components ───────────────────────────────────────────────────

class _PanelHandle extends StatelessWidget {
  @override
  Widget build(BuildContext context) => Container(
        margin: const EdgeInsets.only(top: 10),
        width: 40,
        height: 4,
        decoration: BoxDecoration(
          color: Colors.white24,
          borderRadius: BorderRadius.circular(2),
        ),
      );
}

class _SpinnerIndicator extends StatelessWidget {
  const _SpinnerIndicator({required this.color});
  final Color color;

  @override
  Widget build(BuildContext context) => SizedBox(
        width: 20,
        height: 20,
        child: CircularProgressIndicator(strokeWidth: 2, color: color),
      );
}

class _StatusChip extends StatelessWidget {
  const _StatusChip({required this.label, required this.color});
  final String label;
  final Color color;

  @override
  Widget build(BuildContext context) => Container(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
        decoration: BoxDecoration(
          color: color.withOpacity(0.13),
          borderRadius: BorderRadius.circular(8),
        ),
        child: Text(
          label,
          style: TextStyle(
              color: color, fontSize: 11, fontWeight: FontWeight.w600),
        ),
      );
}

class _PanelSectionHeader extends StatelessWidget {
  const _PanelSectionHeader(this.title);
  final String title;

  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
        child: Text(
          title.toUpperCase(),
          style: const TextStyle(
            color: Colors.white38,
            fontSize: 11,
            fontWeight: FontWeight.w600,
            letterSpacing: 0.8,
          ),
        ),
      );
}

class _PanelTile extends StatelessWidget {
  const _PanelTile({
    required this.participant,
    required this.trailing,
    this.subtitleText,
    this.subtitleColor,
  });

  final TringupParticipant participant;
  final Widget trailing;
  final String? subtitleText;
  final Color? subtitleColor;

  @override
  Widget build(BuildContext context) => ListTile(
        leading: _ParticipantAvatar(participant: participant, radius: 22),
        title: Text(participant.label,
            style: const TextStyle(color: Colors.white, fontSize: 15)),
        subtitle: subtitleText != null
            ? Text(subtitleText!,
                style: TextStyle(
                    color: subtitleColor ?? Colors.white38, fontSize: 12))
            : null,
        trailing: trailing,
        contentPadding: const EdgeInsets.symmetric(horizontal: 16),
      );
}

// ═════════════════════════════════════════════════════════════════════════════
// Shared avatar widgets (kept + upgraded)
// ═════════════════════════════════════════════════════════════════════════════

class _CallerAvatar extends StatelessWidget {
  const _CallerAvatar({required this.info, this.radius = 52});

  final TringupCallInfo info;
  final double radius;

  static const _palette = [
    Color(0xFF1E3A5F),
    Color(0xFF1A4A45),
    Color(0xFF3A2A5A),
    Color(0xFF1E3D55),
    Color(0xFF4A2A35),
  ];

  Color get _bg {
    final label = info.callerLabel;
    return _palette[label.hashCode.abs() % _palette.length];
  }

  @override
  Widget build(BuildContext context) {
    final label = info.callerLabel;
    final initial = label.isNotEmpty ? label[0].toUpperCase() : '?';

    ImageProvider? image;
    if (info.photoPath != null && info.photoPath!.isNotEmpty) {
      image = FileImage(File(info.photoPath!));
    } else if (info.photoUrl != null && info.photoUrl!.isNotEmpty) {
      image = NetworkImage(info.photoUrl!);
    }

    return Container(
      width: radius * 2,
      height: radius * 2,
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        color: image != null ? Colors.transparent : _bg,
        boxShadow: [
          BoxShadow(
              color: _kTeal.withOpacity(0.2),
              blurRadius: 40,
              spreadRadius: 6),
        ],
      ),
      child: ClipOval(
        child: image != null
            ? Image(
                image: image,
                fit: BoxFit.cover,
                errorBuilder: (_, __, ___) => _initials(initial),
              )
            : _initials(initial),
      ),
    );
  }

  Widget _initials(String initial) => Center(
        child: Text(
          initial,
          style: TextStyle(
            color: Colors.white,
            fontSize: radius * 0.8,
            fontWeight: FontWeight.w300,
          ),
        ),
      );
}

class _ParticipantAvatar extends StatelessWidget {
  const _ParticipantAvatar({required this.participant, this.radius = 20});

  final TringupParticipant participant;
  final double radius;

  static const _palette = [
    Color(0xFF1E3A5F),
    Color(0xFF1A4A45),
    Color(0xFF3A2A5A),
    Color(0xFF1E3D55),
    Color(0xFF4A2A35),
  ];

  Color get _bg {
    final label = participant.label;
    return _palette[label.hashCode.abs() % _palette.length];
  }

  @override
  Widget build(BuildContext context) {
    final initial =
        participant.label.isNotEmpty ? participant.label[0].toUpperCase() : '?';

    ImageProvider? image;
    if (participant.photoPath != null && participant.photoPath!.isNotEmpty) {
      image = FileImage(File(participant.photoPath!));
    } else if (participant.photoUrl != null && participant.photoUrl!.isNotEmpty) {
      image = NetworkImage(participant.photoUrl!);
    }

    return CircleAvatar(
      radius: radius,
      backgroundColor: _bg,
      backgroundImage: image,
      child: image == null
          ? Text(
              initial,
              style: TextStyle(
                color: Colors.white,
                fontSize: radius * 0.75,
                fontWeight: FontWeight.w500,
              ),
            )
          : null,
    );
  }
}

// ═════════════════════════════════════════════════════════════════════════════
// Invite status banner (shown above control bar when active invites exist)
// ═════════════════════════════════════════════════════════════════════════════

class _InviteStatusBanner extends StatelessWidget {
  const _InviteStatusBanner(
      {required this.invites, required this.onRetry});

  final Map<String, _PendingInvite> invites;
  final void Function(TringupParticipant) onRetry;

  @override
  Widget build(BuildContext context) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: invites.values
          .map((inv) => _InviteStatusRow(inv: inv, onRetry: onRetry))
          .toList(),
    );
  }
}

class _InviteStatusRow extends StatefulWidget {
  const _InviteStatusRow({required this.inv, required this.onRetry});
  final _PendingInvite inv;
  final void Function(TringupParticipant) onRetry;

  @override
  State<_InviteStatusRow> createState() => _InviteStatusRowState();
}

class _InviteStatusRowState extends State<_InviteStatusRow>
    with SingleTickerProviderStateMixin {
  late AnimationController _pulse;
  late Animation<double> _opacity;

  @override
  void initState() {
    super.initState();
    _pulse = AnimationController(
        vsync: this, duration: const Duration(milliseconds: 900))
      ..repeat(reverse: true);
    _opacity = Tween<double>(begin: 0.4, end: 1.0).animate(_pulse);
  }

  @override
  void dispose() {
    _pulse.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final inv = widget.inv;
    final isFailed = inv.state == _InviteState.failed;
    final isRinging = inv.state == _InviteState.ringing;

    return Container(
      margin: const EdgeInsets.only(bottom: 6),
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      decoration: BoxDecoration(
        color: isFailed
            ? Colors.red.withOpacity(0.12)
            : isRinging
                ? _kGreen.withOpacity(0.08)
                : Colors.white.withOpacity(0.07),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(
          color: isFailed
              ? Colors.redAccent.withOpacity(0.4)
              : isRinging
                  ? _kGreen.withOpacity(0.4)
                  : Colors.white12,
        ),
      ),
      child: Row(
        children: [
          _ParticipantAvatar(participant: inv.participant, radius: 18),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(inv.participant.label,
                    style: const TextStyle(
                        color: Colors.white,
                        fontSize: 14,
                        fontWeight: FontWeight.w500),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis),
                const SizedBox(height: 2),
                if (isFailed)
                  const Text('Call failed — tap to retry',
                      style:
                          TextStyle(color: Colors.redAccent, fontSize: 12))
                else
                  FadeTransition(
                    opacity: _opacity,
                    child: Text(
                      isRinging ? 'Ringing…' : 'Calling…',
                      style: TextStyle(
                          color: isRinging ? _kGreen : Colors.white54,
                          fontSize: 12),
                    ),
                  ),
              ],
            ),
          ),
          const SizedBox(width: 8),
          if (isFailed)
            GestureDetector(
              onTap: () => widget.onRetry(inv.participant),
              child: Container(
                padding: const EdgeInsets.all(6),
                decoration: BoxDecoration(
                    color: Colors.red.withOpacity(0.2),
                    shape: BoxShape.circle),
                child: const Icon(Icons.refresh,
                    color: Colors.redAccent, size: 18),
              ),
            )
          else
            SizedBox(
              width: 18,
              height: 18,
              child: CircularProgressIndicator(
                strokeWidth: 2,
                valueColor: AlwaysStoppedAnimation<Color>(
                    isRinging ? _kGreen : Colors.white54),
              ),
            ),
        ],
      ),
    );
  }
}
class _BusySignalView extends StatefulWidget {
  const _BusySignalView({required this.displayName});
  final String displayName;

  @override
  State<_BusySignalView> createState() => _BusySignalViewState();
}

class _BusySignalViewState extends State<_BusySignalView>
    with SingleTickerProviderStateMixin {
  late AnimationController _pulse;

  @override
  void initState() {
    super.initState();
    _pulse = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 800),
    )..repeat(reverse: true);
  }

  @override
  void dispose() {
    _pulse.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          AnimatedBuilder(
            animation: _pulse,
            builder: (_, __) => Container(
              width: 88,
              height: 88,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: Color.lerp(
                  const Color(0xFF8B1A1A),
                  const Color(0xFFCC3333),
                  _pulse.value,
                ),
              ),
              child: const Icon(
                Icons.phone_disabled_rounded,
                color: Colors.white,
                size: 40,
              ),
            ),
          ),
          const SizedBox(height: 20),
          Text(
            widget.displayName,
            style: const TextStyle(
              color: Colors.white,
              fontSize: 22,
              fontWeight: FontWeight.w600,
            ),
          ),
          const SizedBox(height: 8),
          const Text(
            'User is busy',
            style: TextStyle(
              color: Color(0xFFFF6B6B),
              fontSize: 16,
            ),
          ),
          const SizedBox(height: 4),
          const Text(
            'Call will end automatically',
            style: TextStyle(color: Colors.white38, fontSize: 13),
          ),
        ],
      ),
    );
  }
}

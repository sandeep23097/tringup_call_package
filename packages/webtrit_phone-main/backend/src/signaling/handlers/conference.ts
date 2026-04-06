/**
 * Conference (group call) signaling handlers.
 *
 * Uses the Janus AudioBridge plugin for server-side audio mixing.
 * One Janus handle per participant, one PeerConnection per client.
 */

import { sendEvent }   from '../phoenix';
import { cm }          from '../connection-manager';
import { db }          from '../../db/connection';
import { activeCalls } from './call-state';
import {
  activeConferences,
  ConferenceInfo,
  ConferenceParticipant,
  getOrCreateConference,
} from './conference-state';
import {
  createAudioBridgeHandle,
  createRoom,
  destroyRoom,
  joinRoom,
  leaveRoom,
} from '../../janus/audiobridge';

// ── routing ───────────────────────────────────────────────────────────────────

export async function handleConference(
  type: string,
  userId: string,
  msg: Record<string, any>,
): Promise<void> {
  try {
    switch (type) {
      case 'add_to_call':       await handleAddToCall(userId, msg);       break;
      case 'conference_join':   await handleConferenceJoin(userId, msg);  break;
      case 'conference_accept': await handleConferenceAccept(userId, msg); break;
      case 'conference_decline': handleConferenceDecline(userId, msg);    break;
      default:
        console.warn(`[Conference] unknown type "${type}"`);
    }
  } catch (err: any) {
    console.error(`[Conference] handleConference type=${type} userId=${userId}:`, err?.message ?? err);
  }
}

// ── add_to_call ───────────────────────────────────────────────────────────────

/**
 * An existing participant wants to add a new user to the call.
 *
 * 1. Find or create an AudioBridge room for this callId.
 * 2. If newly created, send `conference_upgrade` to both existing participants
 *    so they tear down the VideoCall PeerConnection and reconnect via AudioBridge.
 * 3. Look up the target user in the DB and send `conference_invite`.
 */
async function handleAddToCall(userId: string, msg: Record<string, any>): Promise<void> {
  const { call_id, number } = msg;

  const callInfo = activeCalls.get(call_id);
  if (!callInfo) {
    console.warn(`[Conference] add_to_call: no active call for call_id=${call_id}`);
    return;
  }

  // ── find or create conference ──────────────────────────────────────────────
  let isNew = false;
  let conf = activeConferences.get(call_id);
  if (!conf) {
    isNew = true;
    // Simple room ID: current timestamp modulo 1 000 000 (fits AudioBridge int)
    const roomId = Date.now() % 1_000_000;

    // Create the Janus AudioBridge room using a temporary handle
    const adminHandle = await createAudioBridgeHandle();
    await createRoom(adminHandle, roomId);
    // Destroy admin handle (room persists on Janus until explicitly destroyed)
    await leaveRoom(adminHandle, roomId);

    conf = getOrCreateConference(call_id, roomId);
  }

  const { roomId } = conf;

  // ── upgrade existing participants to AudioBridge ───────────────────────────
  if (isNew) {
    const upgradeMsg = {
      line:    0,
      call_id,
      room_id: roomId,
    };
    const callerConn = cm.get(callInfo.callerUserId);
    const calleeConn = cm.get(callInfo.calleeUserId);
    if (callerConn) sendEvent(callerConn.ws, 'conference_upgrade', upgradeMsg);
    if (calleeConn) sendEvent(calleeConn.ws, 'conference_upgrade', upgradeMsg);
    console.log(`[Conference] upgrade sent for call_id=${call_id} room_id=${roomId}`);
  }

  // ── look up the invited user ───────────────────────────────────────────────
  const [rows] = await db.query(
    `SELECT id, phone_main, first_name, last_name FROM users
     WHERE (phone_main = ? OR ext = ? OR sip_username = ? OR email = ?) AND status = 'active'`,
    [number, number, number, number],
  );
  const invitee = (rows as any[])[0];
  if (!invitee) {
    console.warn(`[Conference] add_to_call: user not found for number="${number}"`);
    return;
  }

  // Caller display name
  const [callerRows] = await db.query(
    `SELECT first_name, last_name FROM users WHERE id = ?`, [userId],
  );
  const callerInfo = (callerRows as any[])[0];
  const inviterDisplayName = callerInfo
    ? `${callerInfo.first_name || ''} ${callerInfo.last_name || ''}`.trim()
    : userId;

  // ── send conference_invite ─────────────────────────────────────────────────
  const inviteeConn = cm.get(invitee.id);
  if (inviteeConn) {
    sendEvent(inviteeConn.ws, 'conference_invite', {
      line:                 0,
      call_id,
      room_id:              roomId,
      inviter:              userId,
      inviter_display_name: inviterDisplayName,
    });
    console.log(`[Conference] invite sent to userId=${invitee.id} for room_id=${roomId}`);
  } else {
    console.warn(`[Conference] invitee userId=${invitee.id} is not connected`);
  }
}

// ── conference_join ───────────────────────────────────────────────────────────

/**
 * An existing call participant (caller or callee) is upgrading their connection
 * to AudioBridge after receiving `conference_upgrade`.
 */
async function handleConferenceJoin(userId: string, msg: Record<string, any>): Promise<void> {
  const { call_id, room_id, jsep } = msg;

  const conf = activeConferences.get(call_id);
  if (!conf) {
    console.warn(`[Conference] conference_join: no conference for call_id=${call_id}`);
    return;
  }

  await joinParticipant(userId, call_id, room_id, jsep, conf);
}

// ── conference_accept ─────────────────────────────────────────────────────────

/**
 * A freshly invited participant accepts the conference invite and sends their
 * SDP offer for the AudioBridge connection.
 */
async function handleConferenceAccept(userId: string, msg: Record<string, any>): Promise<void> {
  const { call_id, room_id, jsep } = msg;

  const conf = activeConferences.get(call_id);
  if (!conf) {
    console.warn(`[Conference] conference_accept: no conference for call_id=${call_id}`);
    return;
  }

  await joinParticipant(userId, call_id, room_id, jsep, conf);
}

// ── conference_decline ────────────────────────────────────────────────────────

/**
 * An invited participant declines the conference invite.
 */
function handleConferenceDecline(userId: string, msg: Record<string, any>): void {
  const { call_id } = msg;
  console.log(`[Conference] userId=${userId} declined conference invite for call_id=${call_id}`);
  // No further action needed — the inviter is already in the room.
}

// ── shared join logic ─────────────────────────────────────────────────────────

async function joinParticipant(
  userId:  string,
  callId:  string,
  roomId:  number,
  jsep:    any,
  conf:    ConferenceInfo,
): Promise<void> {
  // Retrieve display name
  const [rows] = await db.query(
    `SELECT first_name, last_name FROM users WHERE id = ?`, [userId],
  );
  const userInfo = (rows as any[])[0];
  const displayName = userInfo
    ? `${userInfo.first_name || ''} ${userInfo.last_name || ''}`.trim()
    : userId;

  // Create a unique Janus handle for this participant
  const handle = await createAudioBridgeHandle();

  // Join the AudioBridge room and get the SDP answer
  let answerJsep: any;
  try {
    answerJsep = await joinRoom(handle, roomId, userId, displayName, jsep);
  } catch (err) {
    console.error(`[Conference] joinRoom failed for userId=${userId}:`, err);
    await leaveRoom(handle, roomId).catch(() => {});
    return;
  }

  // Register participant
  const participant: ConferenceParticipant = {
    userId,
    displayName,
    handle,
    stopPolling: false,
  };
  conf.participants.set(userId, participant);

  // Send `conference_join_answer` to the joining client
  const userConn = cm.get(userId);
  if (userConn) {
    sendEvent(userConn.ws, 'conference_join_answer', {
      line:    0,
      call_id: callId,
      room_id: roomId,
      jsep:    answerJsep,
    });
    console.log(`[Conference] join_answer sent to userId=${userId} room_id=${roomId}`);
  }

  // Broadcast `conference_participant_joined` to all other participants
  for (const [otherId] of conf.participants) {
    if (otherId === userId) continue;
    const otherConn = cm.get(otherId);
    if (otherConn) {
      sendEvent(otherConn.ws, 'conference_participant_joined', {
        line:         0,
        call_id:      callId,
        room_id:      roomId,
        user_id:      userId,
        display_name: displayName,
      });
    }
  }

  // Also notify the joiner about existing participants
  if (userConn) {
    for (const [otherId, other] of conf.participants) {
      if (otherId === userId) continue;
      sendEvent(userConn.ws, 'conference_participant_joined', {
        line:         0,
        call_id:      callId,
        room_id:      roomId,
        user_id:      otherId,
        display_name: other.displayName,
      });
    }
  }
}

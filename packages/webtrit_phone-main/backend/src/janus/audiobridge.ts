/**
 * Janus AudioBridge plugin integration.
 *
 * Used for group calls (conferences). The AudioBridge plugin performs
 * server-side audio mixing, so each participant only needs one PeerConnection
 * to the Janus server instead of N-1 connections.
 */

import { janus, JanusHandle } from './client';

const PLUGIN = 'janus.plugin.audiobridge';

// ── helpers ───────────────────────────────────────────────────────────────────

/**
 * Create a Janus session and attach the AudioBridge plugin, returning the handle.
 */
export async function createAudioBridgeHandle(): Promise<JanusHandle> {
  const sessionId = await janus.createSession();
  const handleId  = await janus.attachPlugin(sessionId, PLUGIN);
  return { sessionId, handleId };
}

// ── room management ───────────────────────────────────────────────────────────

/**
 * Create an AudioBridge room with the given numeric roomId.
 */
export async function createRoom(handle: JanusHandle, roomId: number): Promise<void> {
  const resp = await janus.sendMessage(handle, {
    request:    'create',
    room:       roomId,
    audiocodec: 'opus',
    record:     false,
    permanent:  false,
  });

  const data = resp?.plugindata?.data;
  if (data?.audiobridge !== 'created' && data?.audiobridge !== 'event') {
    // Some Janus builds return 'event' with error_code when room already exists
    if (data?.error_code) {
      throw new Error(`AudioBridge createRoom error ${data.error_code}: ${data.error}`);
    }
  }
  console.log(`[AudioBridge] room ${roomId} created`);
}

/**
 * Destroy an AudioBridge room.
 */
export async function destroyRoom(handle: JanusHandle, roomId: number): Promise<void> {
  try {
    await janus.sendMessage(handle, { request: 'destroy', room: roomId });
    console.log(`[AudioBridge] room ${roomId} destroyed`);
  } catch { /* best-effort */ }
}

// ── participant management ────────────────────────────────────────────────────

/**
 * Join an AudioBridge room with an SDP offer.
 * Returns the SDP answer from Janus (polling until the answer is received).
 *
 * @param handle      The Janus handle for this participant (unique per participant).
 * @param roomId      AudioBridge room to join.
 * @param userId      Used as the `display` label in Janus.
 * @param displayName Human-readable display name.
 * @param offerJsep   The WebRTC SDP offer from the client.
 * @returns           The SDP answer jsep object from AudioBridge.
 */
export async function joinRoom(
  handle: JanusHandle,
  roomId: number,
  userId: string,
  displayName: string,
  offerJsep: any,
): Promise<any> {
  // Send join request with the offer SDP
  await janus.sendMessage(
    handle,
    { request: 'join', room: roomId, display: displayName || userId },
    offerJsep,
  );

  // Poll for the AudioBridge answer (the joined event contains a jsep answer)
  const answerJsep = await pollForAnswer(handle, roomId);
  return answerJsep;
}

/**
 * Poll the Janus session until we receive an AudioBridge "joined" event that
 * carries an SDP answer, or until we time out.
 */
async function pollForAnswer(handle: JanusHandle, roomId: number): Promise<any> {
  const maxAttempts = 20;   // 20 × ~500 ms ≈ 10 s max
  const delayMs     = 500;

  for (let attempt = 0; attempt < maxAttempts; attempt++) {
    const events = await janus.pollOnce(handle.sessionId);

    for (const ev of events) {
      const data = ev?.plugindata?.data;
      const jsep = ev?.jsep;

      if (data?.audiobridge === 'joined' && jsep?.type === 'answer') {
        console.log(`[AudioBridge] received answer for room ${roomId}`);
        return jsep;
      }

      // Log but ignore other events during join (e.g. "talking", "event")
      if (data?.audiobridge) {
        console.log(`[AudioBridge] poll event during join: ${data.audiobridge}`);
      }
    }

    // Short sleep between polls when no events arrived
    if (events.length === 0) {
      await sleep(delayMs);
    }
  }

  throw new Error(`[AudioBridge] timeout waiting for answer in room ${roomId}`);
}

// ── leave ─────────────────────────────────────────────────────────────────────

/**
 * Leave an AudioBridge room and destroy the Janus session for this participant.
 */
export async function leaveRoom(handle: JanusHandle, roomId: number): Promise<void> {
  try {
    await janus.sendMessage(handle, { request: 'leave', room: roomId });
  } catch { /* best-effort */ }
  await janus.destroySession(handle.sessionId);
}

// ── util ──────────────────────────────────────────────────────────────────────

function sleep(ms: number): Promise<void> {
  return new Promise(resolve => setTimeout(resolve, ms));
}

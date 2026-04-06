/**
 * Janus VideoCall plugin integration.
 *
 * For each active call the backend maintains TWO Janus handles – one for the
 * caller and one for the callee.  Both are registered with the VideoCall
 * plugin using the user's database id as the username.  The backend drives
 * the offer/answer exchange on behalf of both clients.
 */

import { janus, JanusHandle } from './client';
import { sendEvent }          from '../signaling/phoenix';
import { cm }                 from '../signaling/connection-manager';
import {
  activeCalls, CallInfo, cleanupCall, storeCallerJsep,
} from '../signaling/handlers/call-state';

const PLUGIN = 'janus.plugin.videocall';

// ── per-call Janus state ──────────────────────────────────────────────────

interface JanusCallState {
  callerHandle: JanusHandle;
  calleeHandle: JanusHandle;
  stopPolling:  boolean;
}

const janusState = new Map<string, JanusCallState>(); // callId → state

// ── helpers ───────────────────────────────────────────────────────────────

async function createHandle(username: string): Promise<JanusHandle> {
  const sessionId = await janus.createSession();
  const handleId  = await janus.attachPlugin(sessionId, PLUGIN);
  const h: JanusHandle = { sessionId, handleId };

  // Register username so Janus can route calls to this handle
  await janus.sendMessage(h, { request: 'register', username });
  return h;
}

async function cleanupJanus(callId: string) {
  const js = janusState.get(callId);
  if (!js) return;
  js.stopPolling = true;
  janusState.delete(callId);
  await janus.destroySession(js.callerHandle.sessionId);
  await janus.destroySession(js.calleeHandle.sessionId);
}

// ── event polling loop ────────────────────────────────────────────────────

/**
 * Poll a Janus session forever (until stopPolling), routing plugin events to
 * the appropriate WebRTC client.
 */
function startPolling(js: JanusCallState, callId: string, role: 'caller' | 'callee') {
  const handle = role === 'caller' ? js.callerHandle : js.calleeHandle;

  (async () => {
    while (!js.stopPolling) {
      const events = await janus.pollOnce(handle.sessionId);

      for (const ev of events) {
        if (js.stopPolling) break;
        await handleJanusEvent(ev, callId, role, js);
      }
    }
  })().catch(err => console.error(`[Janus] polling error callId=${callId} role=${role}:`, err));
}

async function handleJanusEvent(
  ev: any, callId: string, role: 'caller' | 'callee', js: JanusCallState,
) {
  const plugindata = ev?.plugindata?.data;
  const jsep       = ev?.jsep;
  const evType     = plugindata?.videocall;

  const info = activeCalls.get(callId);
  if (!info) return;

  console.log(`[Janus] event role=${role} type=${evType} callId=${callId}`);

  if (role === 'callee' && evType === 'event') {
    const result = plugindata?.result;

    // ── incomingcall: forward to client B ──────────────────────────────
    if (result?.event === 'incomingcall') {
      // Always store jsep — callee may be offline (push scenario) and connect later
      if (jsep) storeCallerJsep(callId, jsep);

      const calleeConn = cm.get(info.calleeUserId);
      if (calleeConn) {
        // Callee is online — send incoming_call event with the offer
        sendEvent(calleeConn.ws, 'incoming_call', {
          line:                0,
          call_id:             callId,
          caller:              info.callerNumber  || info.callerUserId,
          callee:              info.calleeNumber  || info.calleeUserId,
          caller_display_name: info.callerName    || info.callerNumber || info.callerUserId,
          referred_by:         null,
          replace_call_id:     null,
          is_focus:            false,
          jsep:                jsep ?? null,
        });
      }
    }

    // ── accepted on callee side: nothing extra needed ──────────────────
  }

  if (role === 'caller' && evType === 'event') {
    const result = plugindata?.result;

    // ── accepted: forward Janus answer SDP to caller ───────────────────
    if (result?.event === 'accepted' && jsep) {
      const callerConn = cm.get(info.callerUserId);
      if (callerConn) {
        sendEvent(callerConn.ws, 'accepted', {
          line:    info.callerLine,
          call_id: callId,
          callee:  null,
          is_focus: false,
          jsep,
        });
      }
    }

    // ── hangup from remote ─────────────────────────────────────────────
    if (result?.event === 'hangup') {
      const callerConn = cm.get(info.callerUserId);
      if (callerConn) {
        sendEvent(callerConn.ws, 'hangup', {
          line: info.callerLine, call_id: callId, code: 200, reason: 'normal',
        });
      }
      cleanupCall(callId);
      cleanupJanus(callId);
    }
  }

  // ── media/webrtcup events ─────────────────────────────────────────────
  if (evType === 'webrtcup') {
    console.log(`[Janus] WebRTC UP callId=${callId} role=${role}`);
  }
}

// ── public API ────────────────────────────────────────────────────────────

/**
 * Initiate an outgoing call via Janus VideoCall.
 * Called after call state is registered.
 */
export async function janusInitiateCall(info: CallInfo, offer: any): Promise<void> {
  // Build Janus handles for both parties
  const callerHandle = await createHandle(info.callerUserId);
  const calleeHandle = await createHandle(info.calleeUserId);

  const js: JanusCallState = { callerHandle, calleeHandle, stopPolling: false };
  janusState.set(info.callId, js);

  // Start polling loops
  startPolling(js, info.callId, 'caller');
  startPolling(js, info.callId, 'callee');

  // Send the call with the caller's SDP offer
  await janus.sendMessage(callerHandle, { request: 'call', username: info.calleeUserId }, offer);
  console.log(`[Janus] call initiated callId=${info.callId}`);
}

/**
 * Accept the call: forward callee's SDP answer to Janus.
 */
export async function janusAcceptCall(callId: string, answer: any): Promise<void> {
  const js = janusState.get(callId);
  if (!js) { console.warn(`[Janus] accept: no state for callId=${callId}`); return; }
  await janus.sendMessage(js.calleeHandle, { request: 'accept' }, answer);
  console.log(`[Janus] accept sent callId=${callId}`);
}

/**
 * Trickle an ICE candidate from a client to their Janus handle.
 */
export async function janusTrickle(callId: string, userId: string, candidate: any): Promise<void> {
  const js   = janusState.get(callId);
  const info = activeCalls.get(callId);
  if (!js || !info) return;

  const handle = info.callerUserId === userId ? js.callerHandle : js.calleeHandle;
  await janus.trickle(handle, candidate);
}

/**
 * Trickle complete (null candidate) — signal ICE gathering is done.
 */
export async function janusTrickleComplete(callId: string, userId: string): Promise<void> {
  const js   = janusState.get(callId);
  const info = activeCalls.get(callId);
  if (!js || !info) return;

  const handle = info.callerUserId === userId ? js.callerHandle : js.calleeHandle;
  await janus.trickleComplete(handle);
}

/**
 * Hangup / decline: destroy Janus sessions.
 */
export async function janusHangup(callId: string): Promise<void> {
  const js   = janusState.get(callId);
  const info = activeCalls.get(callId);
  if (!js) return;

  // Notify Janus
  try {
    await janus.sendMessage(js.callerHandle, { request: 'hangup' });
    await janus.sendMessage(js.calleeHandle, { request: 'hangup' });
  } catch { /* best-effort */ }

  cleanupJanus(callId);
}

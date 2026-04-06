import { sendEvent }                    from '../phoenix';
import { cm }                           from '../connection-manager';
import { db }                           from '../../db/connection';
import axios                            from 'axios';
import { config }                       from '../../config';
import {
  CallInfo, activeCalls, lineIndex,
  registerCall, updateCalleeLine, cleanupCall,
} from './call-state';
import {
  janusInitiateCall,
  janusAcceptCall,
  janusHangup,
} from '../../janus/videocall';

// re-export so ICE handler can import lineIndex from here (backward compat)
export { lineIndex };

export async function handleCall(type: string, userId: string, msg: Record<string, any>) {
  switch (type) {

    case 'outgoing': {
      const { call_id, number, line, jsep, from } = msg;

      // Find callee by phone, ext, sip_username, or email
      const [calleeRows] = await db.query(
        `SELECT id, phone_main, first_name, last_name FROM users
         WHERE (phone_main = ? OR ext = ? OR sip_username = ? OR email = ?) AND status = 'active'`,
        [number, number, number, number],
      );
      const callee = (calleeRows as any[])[0];

      if (!callee) {
        const callerConn = cm.get(userId);
        if (callerConn) sendEvent(callerConn.ws, 'hangup', { line, call_id, code: 404, reason: 'not_found' });
        return;
      }

      // Get caller info
      const [callerRows] = await db.query(
        `SELECT phone_main, first_name, last_name FROM users WHERE id = ?`, [userId],
      );
      const caller = (callerRows as any[])[0];

      const callerNum  = from || caller?.phone_main || userId;
      const callerName = caller
        ? `${caller.first_name || ''} ${caller.last_name || ''}`.trim()
        : callerNum;

      // Register call state
      const info: CallInfo = {
        callerUserId: userId,
        calleeUserId: callee.id,
        callerLine:   line,
        calleeLine:   0,   // updated on accept
        callId:       call_id,
        callerNumber: callerNum,
        callerName,
        calleeNumber: callee.phone_main || number,
      };
      registerCall(info);

      // Tell caller the call is being set up
      const callerConn = cm.get(userId);
      if (callerConn) sendEvent(callerConn.ws, 'calling', { line, call_id });

      // Check if callee is online
      const calleeConn = cm.get(callee.id);
      if (calleeConn) {
        // Callee is connected — Janus will send incoming_call via event polling
        if (callerConn) sendEvent(callerConn.ws, 'ringing', { line, call_id });
      } else {
        // Callee offline — send push
        await sendCallPush(callee.id, call_id, callerNum, number, callerName);
        if (callerConn) sendEvent(callerConn.ws, 'proceeding', { line, call_id, code: 180 });
      }

      // Initiate call through Janus (async — Janus events are polled)
      janusInitiateCall(info, jsep).catch(err =>
        console.error('[Janus] initiate error:', err.message),
      );
      break;
    }

    case 'accept': {
      const { call_id, line, jsep } = msg;
      const info = activeCalls.get(call_id);
      if (!info) return;

      // Update callee line now that we know it
      updateCalleeLine(call_id, line);

      // Send accepted (with jsep=null) back to callee so UI transitions
      const calleeConn = cm.get(userId);
      if (calleeConn) {
        sendEvent(calleeConn.ws, 'accepted', {
          line,
          call_id,
          callee:   null,
          is_focus: false,
          jsep:     null,
        });
      }

      // Forward callee's answer to Janus — Janus will send accepted to caller via polling
      janusAcceptCall(call_id, jsep).catch(err =>
        console.error('[Janus] accept error:', err.message),
      );

      // Write CDR
      const [cRows]  = await db.query(`SELECT phone_main FROM users WHERE id = ?`, [info.callerUserId]);
      const [eeRows] = await db.query(`SELECT phone_main FROM users WHERE id = ?`, [userId]);
      await db.query(
        `INSERT IGNORE INTO call_records
         (id, call_id, caller_user_id, callee_user_id, caller, callee, direction, status, connect_time)
         VALUES (UUID(), ?, ?, ?, ?, ?, 'out', 'answered', NOW())`,
        [call_id, info.callerUserId, userId,
         (cRows  as any[])[0]?.phone_main || info.callerUserId,
         (eeRows as any[])[0]?.phone_main || userId],
      );
      break;
    }

    case 'decline': {
      const { call_id } = msg;
      const info = activeCalls.get(call_id);
      if (!info) return;

      const callerConn = cm.get(info.callerUserId);
      if (callerConn) {
        sendEvent(callerConn.ws, 'hangup', {
          line: info.callerLine, call_id, code: 603, reason: 'decline',
        });
      }

      const [cRows]  = await db.query(`SELECT phone_main FROM users WHERE id = ?`, [info.callerUserId]);
      const [eeRows] = await db.query(`SELECT phone_main FROM users WHERE id = ?`, [userId]);
      await db.query(
        `INSERT IGNORE INTO call_records
         (id, call_id, caller_user_id, callee_user_id, caller, callee, direction, status, disconnect_reason)
         VALUES (UUID(), ?, ?, ?, ?, ?, 'out', 'rejected', 'decline')`,
        [call_id, info.callerUserId, userId,
         (cRows  as any[])[0]?.phone_main || info.callerUserId,
         (eeRows as any[])[0]?.phone_main || userId],
      );

      janusHangup(call_id).catch(() => {});
      cleanupCall(call_id);
      break;
    }

    case 'hangup': {
      const { call_id } = msg;
      const info = activeCalls.get(call_id);
      if (!info) return;

      const otherUserId = info.callerUserId === userId ? info.calleeUserId : info.callerUserId;
      const otherConn   = cm.get(otherUserId);
      if (otherConn) {
        const otherLine = info.callerUserId === userId ? info.calleeLine : info.callerLine;
        sendEvent(otherConn.ws, 'hangup', { line: otherLine, call_id, code: 200, reason: 'normal' });
      }

      await db.query(
        `UPDATE call_records
         SET disconnect_time = NOW(),
             duration = TIMESTAMPDIFF(SECOND, connect_time, NOW()),
             disconnect_reason = 'normal'
         WHERE call_id = ?`,
        [call_id],
      );

      janusHangup(call_id).catch(() => {});
      cleanupCall(call_id);
      break;
    }

    case 'hold': {
      const { call_id, line } = msg;
      const info = activeCalls.get(call_id);
      if (info) {
        const otherUserId = info.callerUserId === userId ? info.calleeUserId : info.callerUserId;
        const otherConn   = cm.get(otherUserId);
        const otherLine   = info.callerUserId === userId ? info.calleeLine : info.callerLine;
        if (otherConn) sendEvent(otherConn.ws, 'holding', { line: otherLine, call_id });
      }
      const selfConn = cm.get(userId);
      if (selfConn) sendEvent(selfConn.ws, 'holding', { line, call_id });
      break;
    }

    case 'unhold': {
      const { call_id, line } = msg;
      const info = activeCalls.get(call_id);
      if (info) {
        const otherUserId = info.callerUserId === userId ? info.calleeUserId : info.callerUserId;
        const otherConn   = cm.get(otherUserId);
        const otherLine   = info.callerUserId === userId ? info.calleeLine : info.callerLine;
        if (otherConn) sendEvent(otherConn.ws, 'resuming', { line: otherLine, call_id });
      }
      const selfConn = cm.get(userId);
      if (selfConn) sendEvent(selfConn.ws, 'resuming', { line, call_id });
      break;
    }
  }
}

async function sendCallPush(
  calleeId: string, callId: string, caller: string, callee: string, callerName: string,
) {
  const [rows] = await db.query(
    `SELECT type, value FROM push_tokens WHERE user_id = ? ORDER BY updated_at DESC LIMIT 1`,
    [calleeId],
  );
  const token = (rows as any[])[0];
  if (!token) return;

  const platform = (token.type === 'fcm' || token.type === 'hms') ? 2 : 1;
  try {
    await axios.post(`${config.gorushUrl}/api/push`, {
      notifications: [{
        tokens:   [token.value],
        platform,
        priority: 'high',
        data:     { callId, handleValue: caller, displayName: callerName, hasVideo: 'false' },
        ...(token.type === 'apkvoip' ? { voip: true, content_available: true } : {}),
      }],
    });
  } catch { /* push is optional */ }
}

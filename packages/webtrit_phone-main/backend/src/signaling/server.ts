import WebSocket, { WebSocketServer } from 'ws';
import { IncomingMessage, Server as HttpServer } from 'http';
import jwt from 'jsonwebtoken';
import { config } from '../config';
import { sendAck, sendKeepaliveAck, sendState, UserActiveCallEntry } from './phoenix';
import { cm } from './connection-manager';
import { handleCall }       from './handlers/call';
import { handleIce }         from './handlers/ice';
import { handleConference }  from './handlers/conference';
import { activeCalls }       from './handlers/call-state';

export function startSignalingServer(httpServer: HttpServer) {
  const wss = new WebSocketServer({ server: httpServer, handleProtocols: () => 'webtrit-protocol' });

  wss.on('connection', (ws: WebSocket, req: IncomingMessage) => {
    const urlStr = req.url || '';
    const url    = new URL(urlStr, 'http://localhost');
    const token  = url.searchParams.get('token');
    const force  = url.searchParams.get('force') === 'true';

    // Strip tenant prefix: /tenant/{id}/signaling/v1 → /signaling/v1
    const path = url.pathname.replace(/^\/tenant\/[^/]+/, '');
    if (!path.startsWith('/signaling/v1')) {
      ws.close(4001, 'Invalid endpoint');
      return;
    }

    // Authenticate via JWT
    let userId: string;
    try {
      const payload = jwt.verify(token!, config.jwtSecret) as any;
      userId = payload.userId;
    } catch {
      ws.close(4401, 'Unauthorized');
      return;
    }

    // Replace existing session if force=true
    if (force) {
      const existing = cm.get(userId);
      if (existing) {
        existing.ws.close(4000, 'Replaced by new session');
        cm.remove(userId);
      }
    }

    // Register connection
    cm.add(userId, { ws, userId, topic: `user:${userId}`, joinRef: '' });

    // Build lines + user_active_calls for any pending incoming call for this user.
    // The background isolate (woken by push) checks handshake.lines — if a line
    // contains an incoming_call event it knows the call is still active and does NOT
    // fire releaseResources.
    const lines: Array<any> = Array(4).fill(null);
    const userActiveCalls: UserActiveCallEntry[] = [];

    for (const [, info] of activeCalls) {
      if (info.calleeUserId === userId) {
        // Populate line 0 with the pending incoming call + event log
        lines[0] = {
          call_id:   info.callId,
          call_logs: [[
            Date.now(),
            {
              event:               'incoming_call',
              caller:              info.callerNumber,
              callee:              info.calleeNumber,
              caller_display_name: info.callerName || info.callerNumber,
              referred_by:         null,
              replace_call_id:     null,
              is_focus:            false,
              jsep:                info.callerJsep ?? null,
            },
          ]],
        };

        // Also populate user_active_calls for completeness
        userActiveCalls.push({
          id:                  info.callId,
          state:               'early',
          call_id:             info.callId,
          direction:           'recipient',
          local_tag:           userId,
          remote_tag:          info.callerUserId,
          remote_number:       info.callerNumber,
          remote_display_name: info.callerName || null,
        });
        break;
      }
    }

    sendState(ws, 4, userActiveCalls, lines);

    console.log(`[WS] User ${userId} connected`);

    ws.on('message', (data: Buffer) => {
      let msg: Record<string, any>;
      try {
        msg = JSON.parse(data.toString());
      } catch {
        return;
      }

      const request   = msg['request']   as string | undefined;
      const handshake = msg['handshake'] as string | undefined;
      const transaction = msg['transaction'] as string | undefined;

      // Keepalive — client sends {handshake:'keepalive', transaction:'...'}
      if (handshake === 'keepalive') {
        if (transaction) sendKeepaliveAck(ws, transaction);
        return;
      }

      if (!request) return;

      // ICE trickle
      if (request === 'ice_trickle') {
        if (transaction) sendAck(ws, transaction);
        handleIce(userId, msg);
        return;
      }

      // Call-related requests — ACK immediately then handle
      if (transaction) sendAck(ws, transaction);

      switch (request) {
        case 'outgoing_call': handleCall('outgoing', userId, msg); break;
        case 'accept':        handleCall('accept',   userId, msg); break;
        case 'decline':       handleCall('decline',  userId, msg); break;
        case 'hangup':        handleCall('hangup',   userId, msg); break;
        case 'hold':          handleCall('hold',     userId, msg); break;
        case 'unhold':        handleCall('unhold',   userId, msg); break;

        // Group-call (conference) requests — only active when GROUP_CALL_ENABLED=true
        case 'add_to_call':
        case 'conference_join':
        case 'conference_accept':
        case 'conference_decline':
          if (config.groupCallEnabled) {
            handleConference(request, userId, msg);
          } else {
            console.log(`[WS] Group call disabled, ignoring "${request}" from ${userId}`);
          }
          break;

        default:
          console.log(`[WS] Unknown request "${request}" from ${userId}`);
      }
    });

    ws.on('close', () => {
      cm.remove(userId);
      console.log(`[WS] User ${userId} disconnected`);
    });

    ws.on('error', err => console.error(`[WS] Error for ${userId}:`, err.message));
  });

  console.log(`Signaling server attached to HTTP server`);
}

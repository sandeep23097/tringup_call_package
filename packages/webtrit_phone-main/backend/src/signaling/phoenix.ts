// WebtRit custom JSON signaling protocol helpers
// All messages are plain JSON objects (NOT Phoenix arrays)

export interface UserActiveCallEntry {
  id:                  string;
  state:               'proceeding' | 'early' | 'confirmed' | 'terminated' | 'unknown';
  call_id:             string;
  direction:           'initiator' | 'recipient';
  local_tag:           string;
  remote_tag:          string | null;
  remote_number:       string;
  remote_display_name: string | null;
}

export function sendAck(ws: { send: (d: string) => void }, transaction: string, extra: Record<string, any> = {}) {
  ws.send(JSON.stringify({ response: 'ack', transaction, ...extra }));
}

export function sendKeepaliveAck(ws: { send: (d: string) => void }, transaction: string) {
  ws.send(JSON.stringify({ handshake: 'keepalive', transaction }));
}

export function sendState(
  ws: { send: (d: string) => void },
  linesCount = 4,
  userActiveCalls: UserActiveCallEntry[] = [],
  lines?: Array<any>,
) {
  ws.send(JSON.stringify({
    handshake:              'state',
    keepalive_interval:     30000,
    timestamp:              Date.now(),
    registration:           { status: 'registered', code: null, reason: null },
    lines:                  lines ?? Array(linesCount).fill(null),
    user_active_calls:      userActiveCalls,
    presence_contacts_info: {},
    guest_line:             null,
  }));
}

export function sendEvent(ws: { send: (d: string) => void }, event: string, payload: Record<string, any>) {
  ws.send(JSON.stringify({ event, ...payload }));
}

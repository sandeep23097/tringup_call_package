import WebSocket from 'ws';

export interface UserConn {
  ws:       WebSocket;
  userId:   string;
  topic:    string;
  joinRef:  string;
}

const connections = new Map<string, UserConn>();

export const cm = {
  add(userId: string, conn: UserConn)           { connections.set(userId, conn); },
  remove(userId: string)                        { connections.delete(userId); },
  get(userId: string): UserConn | undefined     { return connections.get(userId); },
  isOpen(userId: string): boolean {
    const c = connections.get(userId);
    return !!c && c.ws.readyState === WebSocket.OPEN;
  },
  send(userId: string, msg: string): boolean {
    const c = connections.get(userId);
    if (c && c.ws.readyState === WebSocket.OPEN) { c.ws.send(msg); return true; }
    return false;
  },
};

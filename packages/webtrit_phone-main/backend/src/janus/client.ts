import axios from 'axios';
import { config } from '../config';

let _txSeq = 0;
function tx() { return `t${++_txSeq}_${Date.now()}`; }

export interface JanusHandle {
  sessionId: number;
  handleId:  number;
}

export class JanusClient {
  constructor(private baseUrl: string) {}

  // ── session ──────────────────────────────────────────────────────────────

  async createSession(): Promise<number> {
    const r = await axios.post(this.baseUrl, { janus: 'create', transaction: tx() });
    if (r.data.janus !== 'success') throw new Error(`Janus createSession: ${r.data.janus}`);
    return r.data.data.id as number;
  }

  async destroySession(sessionId: number): Promise<void> {
    try {
      await axios.post(`${this.baseUrl}/${sessionId}`, { janus: 'destroy', transaction: tx() });
    } catch { /* best-effort */ }
  }

  // ── handle ───────────────────────────────────────────────────────────────

  async attachPlugin(sessionId: number, plugin: string): Promise<number> {
    const r = await axios.post(`${this.baseUrl}/${sessionId}`, {
      janus: 'attach', plugin, transaction: tx(),
    });
    if (r.data.janus !== 'success') throw new Error(`Janus attach: ${r.data.janus}`);
    return r.data.data.id as number;
  }

  // ── messaging ─────────────────────────────────────────────────────────────

  async sendMessage(h: JanusHandle, body: any, jsep?: any): Promise<any> {
    const payload: any = { janus: 'message', body, transaction: tx() };
    if (jsep) payload.jsep = jsep;
    const r = await axios.post(`${this.baseUrl}/${h.sessionId}/${h.handleId}`, payload);
    return r.data;
  }

  // ── trickle ICE ──────────────────────────────────────────────────────────

  async trickle(h: JanusHandle, candidate: any): Promise<void> {
    await axios.post(`${this.baseUrl}/${h.sessionId}/${h.handleId}`, {
      janus: 'trickle', candidate, transaction: tx(),
    });
  }

  async trickleComplete(h: JanusHandle): Promise<void> {
    await this.trickle(h, { completed: true });
  }

  // ── event polling (long-poll) ─────────────────────────────────────────────

  async pollOnce(sessionId: number): Promise<any[]> {
    try {
      const r = await axios.get(`${this.baseUrl}/${sessionId}`, {
        params:  { maxev: 10, rid: Date.now() },
        timeout: 35_000,   // Janus keepalive is 30 s
      });
      if (Array.isArray(r.data)) return r.data;
      if (r.data)              return [r.data];
      return [];
    } catch {
      return [];
    }
  }
}

export const janus = new JanusClient(config.janusUrl);

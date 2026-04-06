/**
 * Shared in-memory call state used by the call handler and Janus integration.
 */

export interface CallInfo {
  callerUserId: string;
  calleeUserId: string;
  callerLine:   number;
  calleeLine:   number;
  callId:       string;
  callerNumber: string;   // e.g. phone_main of caller
  callerName:   string;   // display name of caller
  calleeNumber: string;   // phone_main of callee
  callerJsep?:  any;      // SDP offer from caller (stored for offline callee push scenario)
}

// callId → CallInfo
export const activeCalls = new Map<string, CallInfo>();

// "userId:line" → CallInfo  — used by ICE relay
export const lineIndex = new Map<string, CallInfo>();

export function registerCall(info: CallInfo) {
  activeCalls.set(info.callId, info);
  lineIndex.set(`${info.callerUserId}:${info.callerLine}`, info);
  lineIndex.set(`${info.calleeUserId}:${info.calleeLine}`, info);
}

export function storeCallerJsep(callId: string, jsep: any) {
  const info = activeCalls.get(callId);
  if (!info) return;
  activeCalls.set(callId, { ...info, callerJsep: jsep });
}

export function updateCalleeLine(callId: string, calleeLine: number) {
  const info = activeCalls.get(callId);
  if (!info) return;
  lineIndex.delete(`${info.calleeUserId}:${info.calleeLine}`);
  const updated = { ...info, calleeLine };
  activeCalls.set(callId, updated);
  lineIndex.set(`${updated.calleeUserId}:${calleeLine}`, updated);
}

export function cleanupCall(callId: string) {
  const info = activeCalls.get(callId);
  if (!info) return;
  activeCalls.delete(callId);
  lineIndex.delete(`${info.callerUserId}:${info.callerLine}`);
  lineIndex.delete(`${info.calleeUserId}:${info.calleeLine}`);
}

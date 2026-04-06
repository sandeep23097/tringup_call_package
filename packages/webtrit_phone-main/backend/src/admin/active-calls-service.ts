/**
 * Admin service for reading the in-memory active calls state.
 */

import { activeCalls, CallInfo } from '../signaling/handlers/call-state';

export interface ActiveCallEntry {
  callId:       string;
  callerUserId: string;
  calleeUserId: string;
  callerNumber: string;
  callerName:   string;
  calleeNumber: string;
  callerLine:   number;
  calleeLine:   number;
  startedAt:    string;   // ISO timestamp — injected when the admin module reads the map
}

// We augment CallInfo with a startedAt field tracked separately.
// This map stores the timestamp when each callId first appeared.
const callStartTimes = new Map<string, Date>();

/**
 * Call this whenever a new call is registered so we can track its start time.
 */
export function recordCallStart(callId: string): void {
  if (!callStartTimes.has(callId)) {
    callStartTimes.set(callId, new Date());
  }
}

/**
 * Call this whenever a call ends so we can clean up timestamps.
 */
export function removeCallStart(callId: string): void {
  callStartTimes.delete(callId);
}

/**
 * Returns the current list of active calls with enriched metadata.
 */
export function getActiveCalls(): ActiveCallEntry[] {
  const result: ActiveCallEntry[] = [];
  activeCalls.forEach((info: CallInfo, callId: string) => {
    // Auto-register start time if not yet tracked
    if (!callStartTimes.has(callId)) {
      callStartTimes.set(callId, new Date());
    }
    result.push({
      callId,
      callerUserId: info.callerUserId,
      calleeUserId: info.calleeUserId,
      callerNumber: info.callerNumber,
      callerName:   info.callerName,
      calleeNumber: info.calleeNumber,
      callerLine:   info.callerLine,
      calleeLine:   info.calleeLine,
      startedAt:    (callStartTimes.get(callId) as Date).toISOString(),
    });
  });
  return result;
}

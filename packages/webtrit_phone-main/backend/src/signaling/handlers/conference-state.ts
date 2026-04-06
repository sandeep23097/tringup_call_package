/**
 * Shared in-memory conference (group call) state.
 *
 * A conference is associated with the original 1-to-1 callId.
 * Each participant has their own Janus AudioBridge handle.
 */

import { JanusHandle } from '../../janus/client';

export interface ConferenceParticipant {
  userId:      string;
  displayName: string;
  handle:      JanusHandle;   // Janus AudioBridge handle for this participant
  stopPolling: boolean;
}

export interface ConferenceInfo {
  roomId:       number;
  callId:       string;                                    // original 1:1 call_id
  participants: Map<string, ConferenceParticipant>;        // userId → participant
}

/** callId → ConferenceInfo */
export const activeConferences = new Map<string, ConferenceInfo>();

export function getOrCreateConference(callId: string, roomId: number): ConferenceInfo {
  const existing = activeConferences.get(callId);
  if (existing) return existing;

  const conf: ConferenceInfo = {
    roomId,
    callId,
    participants: new Map(),
  };
  activeConferences.set(callId, conf);
  return conf;
}

export function cleanupConference(callId: string): void {
  activeConferences.delete(callId);
}

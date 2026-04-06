import { activeCalls } from './call-state';
import { janusTrickle, janusTrickleComplete } from '../../janus/videocall';

export async function handleIce(userId: string, msg: Record<string, any>) {
  const { call_id, line, candidate } = msg;

  // Resolve callId: ice_trickle may include call_id, or we find by line
  let callId = call_id as string | undefined;
  if (!callId) {
    // Fallback: find by userId:line (legacy path)
    for (const [id, info] of activeCalls) {
      if (
        (info.callerUserId === userId && info.callerLine === line) ||
        (info.calleeUserId === userId && info.calleeLine === line)
      ) {
        callId = id;
        break;
      }
    }
  }

  if (!callId) {
    console.log(`[ICE] no call found for userId=${userId} line=${line}`);
    return;
  }

  if (!candidate) {
    // null candidate = ICE gathering complete
    console.log(`[ICE] gathering complete userId=${userId} callId=${callId}`);
    janusTrickleComplete(callId, userId).catch(err =>
      console.error('[ICE] trickleComplete error:', err.message),
    );
    return;
  }

  console.log(`[ICE] trickle to Janus userId=${userId} callId=${callId} candidate=${JSON.stringify(candidate).substring(0, 60)}`);
  janusTrickle(callId, userId, candidate).catch(err =>
    console.error('[ICE] trickle error:', err.message),
  );
}

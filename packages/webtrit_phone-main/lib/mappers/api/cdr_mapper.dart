import 'package:collection/collection.dart';

import 'package:webtrit_api/webtrit_api.dart' as api;

import 'package:webtrit_phone/extensions/string.dart';
import 'package:webtrit_phone/models/models.dart';

mixin CdrApiMapper {
  CdrRecord cdrFromApi(api.CdrRecord cdrRecord) {
    return CdrRecord(
      callId: cdrRecord.callId,
      direction: _parseCallDirection(cdrRecord.direction),
      status: _parseCdrStatus(cdrRecord.status),
      callee: cdrRecord.callee,
      calleeNumber: cdrRecord.callee.extractNumber,
      caller: cdrRecord.caller,
      callerNumber: cdrRecord.caller.extractNumber,
      connectTime: cdrRecord.connectTime,
      disconnectTime: cdrRecord.disconnectTime,
      disconnectReason: cdrRecord.disconnectReason,
      duration: Duration(seconds: cdrRecord.duration),
      recordingId: cdrRecord.recordingId,
    );
  }

  // Handle both full enum names ('outgoing'/'incoming') and legacy short forms
  // ('out'/'in') that the custom backend may return.
  static CallDirection _parseCallDirection(String raw) => switch (raw) {
    'outgoing' || 'out' => CallDirection.outgoing,
    'incoming' || 'in'  => CallDirection.incoming,
    _                    => CallDirection.outgoing,
  };

  // Map backend status strings to CdrStatus enum values.
  // 'answered' → accepted, 'rejected' → declined (legacy backend values).
  static CdrStatus _parseCdrStatus(String raw) => switch (raw) {
    'accepted' || 'answered'  => CdrStatus.accepted,
    'declined' || 'rejected'  => CdrStatus.declined,
    'missed'                  => CdrStatus.missed,
    _                         => CdrStatus.error,
  };
}

enum CallProcessingStatus {
  incomingFromPush,
  incomingFromOffer,
  incomingSubmittedAnswer,
  conferenceInvitePending,
  conferenceActive,
  incomingPerformingStarted,
  incomingInitializingMedia,
  incomingAnswering,

  outgoingCreated,
  outgoingCreatedFromRefer,
  outgoingConnectingToSignaling,
  outgoingInitializingMedia,
  outgoingOfferPreparing,
  outgoingOfferSent,
  outgoingRinging,

  connected,
  disconnecting, busySignal,
}

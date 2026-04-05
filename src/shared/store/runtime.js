function createRuntimeState() {
  return {
    sessionId: null,
    connected: false,
    ws: null,
    actions: [],
    messages: [],
    console: [],
    queue: [],
    busy: false,
    sending: false,
    lastMessageId: '',
    seenMessageIds: {},
  };
}

export {
  createRuntimeState,
};

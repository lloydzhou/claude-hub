const MD_SYNTAX_RE = /[#*`|[>\-_~]|\n\n|^\d+\. |\n\d+\. /;

function nowIso() {
  return new Date().toISOString();
}

function normalizeTimestamp(value) {
  if (value == null || value === '') return nowIso();
  if (typeof value === 'number' && Number.isFinite(value)) {
    return new Date(value < 1e12 ? value * 1000 : value).toISOString();
  }
  if (value instanceof Date) return value.toISOString();
  if (typeof value === 'string') {
    const parsed = new Date(value);
    if (!Number.isNaN(parsed.getTime())) return parsed.toISOString();
    const asNumber = Number(value);
    if (Number.isFinite(asNumber)) {
      return new Date(asNumber < 1e12 ? asNumber * 1000 : asNumber).toISOString();
    }
  }
  return nowIso();
}

function extractTextValue(value) {
  if (value == null) return '';
  if (typeof value === 'string') return value;
  if (typeof value === 'number' || typeof value === 'boolean') return String(value);
  if (Array.isArray(value)) return value.map(extractTextValue).filter(Boolean).join('');
  if (typeof value === 'object') {
    const parts = [];
    if (typeof value.text === 'string') parts.push(value.text);
    if (typeof value.content === 'string') parts.push(value.content);
    if (Array.isArray(value.content)) parts.push(extractTextValue(value.content));
    if (typeof value.delta === 'string') parts.push(value.delta);
    if (value.delta && typeof value.delta === 'object') parts.push(extractTextValue(value.delta));
    if (typeof value.result === 'string') parts.push(value.result);
    if (typeof value.error === 'string') parts.push(value.error);
    if (typeof value.message === 'object') parts.push(extractTextValue(value.message));
    return parts.filter(Boolean).join('');
  }
  return '';
}

function normalizeAction(payload, source = 'remote') {
  if (!payload || typeof payload !== 'object') {
    return {
      type: 'assistant',
      content: typeof payload === 'string' ? payload : String(payload || ''),
      timestamp: nowIso(),
      source,
      raw: payload,
    };
  }
  return {
    ...payload,
    type: payload.type || 'assistant',
    subtype: payload.subtype,
    content: payload.content,
    error: payload.error,
    result: payload.result,
    session_id: payload.session_id,
    pid: payload.pid,
    is_error: payload.is_error,
    timestamp: normalizeTimestamp(payload.timestamp),
    source,
    raw: payload,
  };
}

function actionText(action) {
  if (!action || typeof action !== 'object') return '';
  if (action.type === 'assistant' && Array.isArray(action.content)) {
    const textParts = [];
    for (const block of action.content) {
      if (block && block.type === 'text' && typeof block.text === 'string') {
        textParts.push(block.text);
      }
    }
    if (textParts.length) return textParts.join('');
  }
  const direct = extractTextValue(action.content);
  if (direct) return direct;
  if (action.type === 'result') return extractTextValue(action.result);
  if (action.type === 'system') return extractTextValue(action.error) || extractTextValue(action.content);
  if (action.message) return extractTextValue(action.message);
  return '';
}

function isLikelyJsonText(text) {
  const value = String(text || '').trim();
  if (!value) return false;
  if (!(value.startsWith('{') || value.startsWith('['))) return false;
  try {
    JSON.parse(value);
    return true;
  } catch {
    return false;
  }
}

function isLikelyToolCall(action, text) {
  const value = String(text || '').trim();
  if (!value) return false;
  if (action && action.type === 'assistant') {
    if (isLikelyJsonText(value)) return true;
    if (/^\{.*\}$/.test(value) && /query|search|tool/i.test(value)) return true;
  }
  return false;
}

function isLikelyToolResult(action, text) {
  const value = String(text || '').trim();
  if (!value) return false;
  if (action && action.type === 'user') {
    if (/^Web search results for query:/i.test(value)) return true;
    if (/^Tool (result|output):/i.test(value)) return true;
    if (/^Search results:/i.test(value)) return true;
  }
  return false;
}

function isAssistantBoundary(action) {
  if (!action || typeof action !== 'object') return false;
  if (action.type === 'result') return true;
  if (action.type !== 'assistant') return false;
  const subtype = String(action.subtype || '').toLowerCase();
  return subtype.includes('stop') || subtype.includes('done') || subtype.includes('complete') || subtype.includes('final');
}

function normalizeSessionList(value) {
  if (Array.isArray(value)) {
    return value;
  }
  if (value == null) {
    return [];
  }
  if (typeof value === 'object') {
    return Object.keys(value).length ? Object.values(value) : [];
  }
  return [];
}

function reduceTranscriptActions(actions) {
  const extractStreamEvent = (action) => {
    if (!action || typeof action !== 'object') return null;
    if (action.raw && typeof action.raw === 'object' && action.raw.event) return action.raw.event;
    if (action.event && typeof action.event === 'object') return action.event;
    if (action.content && typeof action.content === 'object' && action.content.event) return action.content.event;
    return null;
  };

  const messages = [];
  let assistantDraft = null;
  const hasStreamEvent = actions.some((action) => !!extractStreamEvent(action));

  const pushMessage = (message) => {
    messages.push(message);
    return message;
  };

  const startAssistant = (timestamp) => {
    if (assistantDraft) return assistantDraft;
    assistantDraft = pushMessage({
      id: `assistant-${messages.length}-${Date.now()}`,
      role: 'assistant',
      content: '',
      timestamp: timestamp || nowIso(),
      pending: true,
    });
    return assistantDraft;
  };

  const appendAssistantText = (text, timestamp) => {
    if (!text) return;
    const assistant = startAssistant(timestamp);
    assistant.content += text;
    assistant.timestamp = timestamp || assistant.timestamp || nowIso();
    assistant.pending = true;
  };

  const finalizeAssistant = () => {
    if (assistantDraft) {
      if (!String(assistantDraft.content || '').trim()) {
        messages.pop();
      } else {
        assistantDraft.pending = false;
      }
      assistantDraft = null;
    }
  };

  for (const action of actions) {
    if (!action || typeof action !== 'object') continue;

    if (action.type === 'user') {
      const text = actionText(action);
      if (!text) continue;
      finalizeAssistant();
      pushMessage({
        id: `user-${messages.length}-${Date.now()}`,
        role: 'user',
        content: text,
        timestamp: action.timestamp || nowIso(),
      });
      continue;
    }

    const ev = extractStreamEvent(action);
    if (ev) {
      const stamp = action.timestamp || nowIso();
      if (ev.type === 'content_block_delta' && ev.delta) {
        if (typeof ev.delta.text === 'string') {
          appendAssistantText(ev.delta.text, stamp);
          continue;
        }
        if (typeof ev.delta.partial_json === 'string') {
          appendAssistantText(ev.delta.partial_json, stamp);
          continue;
        }
      }
      if (ev.type === 'message_delta' && ev.delta) {
        if (typeof ev.delta.text === 'string') appendAssistantText(ev.delta.text, stamp);
        continue;
      }
      if (ev.type === 'text_delta' && typeof ev.text === 'string') {
        appendAssistantText(ev.text, stamp);
        continue;
      }
      if (ev.type === 'content_block_stop' || ev.type === 'message_stop') {
        finalizeAssistant();
        continue;
      }
    }

    if (action.type === 'assistant') {
      if (hasStreamEvent) continue;
      const text = actionText(action);
      if (text) appendAssistantText(text, action.timestamp || nowIso());
      continue;
    }

    if (action.type === 'result') {
      finalizeAssistant();
      continue;
    }

    if (action.type === 'stderr') {
      finalizeAssistant();
      messages.push({
        id: `stderr-${messages.length}-${Date.now()}`,
        role: 'error',
        kind: 'stderr',
        content: actionText(action) || 'stderr',
        timestamp: action.timestamp || nowIso(),
      });
      continue;
    }

    if (action.type === 'system') {
      if (action.subtype === 'init') continue;
    }
  }

  return messages;
}

function formatShortId(id) {
  return id ? id.slice(0, 8) : '--------';
}

function formatStamp(iso) {
  const d = new Date(iso);
  if (Number.isNaN(d.getTime())) return '';
  return d.toLocaleTimeString([], { hour12: false });
}

function describeSystemEvent(msg) {
  if (msg.subtype === 'init') return `init session=${msg.session_id || 'unknown'}`;
  if (msg.type === 'result') return msg.is_error ? `result error: ${msg.result || 'unknown'}` : (msg.result || 'completed');
  return msg.content || 'system event';
}

function parseWsPayload(raw) {
  if (typeof raw !== 'string') {
    return { meta: null, payload: raw };
  }
  if (!raw.startsWith('id:') && !raw.startsWith('content-type:')) {
    return { meta: null, payload: raw };
  }
  const parts = raw.split(/\r?\n\r?\n/);
  const head = parts.shift() || '';
  const body = parts.join('\n\n');
  const meta = {};
  head.split(/\r?\n/).forEach((line) => {
    const idx = line.indexOf(':');
    if (idx < 0) return;
    const key = line.slice(0, idx).trim();
    const value = line.slice(idx + 1).trim();
    if (key) meta[key] = value;
  });
  return { meta, payload: body };
}

export {
  actionText,
  describeSystemEvent,
  extractTextValue,
  formatShortId,
  formatStamp,
  isAssistantBoundary,
  isLikelyJsonText,
  isLikelyToolCall,
  isLikelyToolResult,
  normalizeAction,
  normalizeSessionList,
  normalizeTimestamp,
  parseWsPayload,
  reduceTranscriptActions,
};

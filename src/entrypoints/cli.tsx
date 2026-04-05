#!/usr/bin/env bun
import React, { useEffect, useMemo, useState } from 'react';
import { render, Box, Text, useApp, useInput } from 'ink';
import { createRemoteSessionClient } from '../runtime/remote-session.js';
import { formatShortId, formatStamp } from '../shared/stream.js';

function parseArgs(argv) {
  const args = [...argv];
  const result = { _: [] };
  while (args.length) {
    const arg = args.shift();
    if (arg === 'list') {
      result.command = 'list';
      continue;
    }
    if (arg === '--session-id') {
      result.sessionId = args.shift() || '';
      continue;
    }
    if (arg === '--base-url') {
      result.baseUrl = args.shift() || '';
      continue;
    }
    if (arg === '--help' || arg === '-h') {
      result.help = true;
      continue;
    }
    result._.push(arg);
  }
  return result;
}

async function listSessions(baseUrl = '') {
  const res = await fetch(`${baseUrl}/api/sessions`);
  const data = await res.json();
  const sessions = (data.sessions || []).slice().sort((a, b) => (b.created_at || 0) - (a.created_at || 0));
  if (!sessions.length) {
    process.stdout.write('No sessions yet.\n');
    return;
  }
  process.stdout.write('SESSION ID        STATUS   TURNS  SUMMARY\n');
  process.stdout.write('----------------  -------  -----  --------------------------------\n');
  for (const s of sessions) {
    const summary = s.last_user_text || s.last_result || (typeof s.turn_count === 'number' ? `${s.turn_count} turn${s.turn_count === 1 ? '' : 's'}` : '');
    process.stdout.write(`${formatShortId(s.session_id).padEnd(16)}  ${(s.status || 'idle').padEnd(7)}  ${String(s.turn_count || 0).padEnd(5)}  ${String(summary).slice(0, 40)}\n`);
  }
}

function MessageLine({ message }) {
  const role = message.role || 'system';
  const color = role === 'user' ? 'green' : role === 'assistant' ? 'cyan' : role === 'error' ? 'red' : 'gray';
  return (
    <Box flexDirection="column" marginBottom={1}>
      <Text color={color} bold>
        {role.toUpperCase()} {message.pending ? '(pending)' : ''}
      </Text>
      <Text>
        {String(message.content || '').trim() || '<empty>'}
      </Text>
    </Box>
  );
}

function InputController({ value, setValue, onSubmit, onExit }) {
  useInput((inputChar, key) => {
    if (key.ctrl && inputChar === 'c') {
      onExit();
      return;
    }
    if (key.return) {
      const next = value.trim();
      if (!next) return;
      setValue('');
      onSubmit(next);
      return;
    }
    if (key.backspace || key.delete) {
      setValue((prev) => prev.slice(0, -1));
      return;
    }
    if (key.escape) {
      setValue('');
      return;
    }
    if (inputChar && !key.ctrl && !key.meta) {
      setValue((prev) => prev + inputChar);
    }
  });

  return null;
}

function SessionTui({ sessionId, baseUrl = '' }) {
  const { exit } = useApp();
  const client = useMemo(() => createRemoteSessionClient({ apiBase: baseUrl, sessionId }), [baseUrl, sessionId]);
  const [state, setState] = useState(client.getState());
  const [input, setInput] = useState('');
  const inputEnabled = !!process.stdin.isTTY && !!process.stdout.isTTY;

  useEffect(() => client.subscribe(setState), [client]);

  useEffect(() => {
    client.ensureConnected().catch((err) => {
      // eslint-disable-next-line no-console
      console.error(err);
    });
    return () => client.disconnect();
  }, [client]);

  const session = client.getCurrentSummary() || { id: sessionId };
  const messages = state.messages || [];
  const queue = state.queue || [];

  return (
    <Box flexDirection="column">
      {inputEnabled ? (
        <InputController
          value={input}
          setValue={setInput}
          onSubmit={(text) => client.sendTurn(text).catch(() => {})}
          onExit={exit}
        />
      ) : null}
      <Box flexDirection="column" marginBottom={1}>
        <Text color="yellow" bold>
          claude_remote
        </Text>
        <Text>
          session_id={session.id} status={session.status || 'loading'} connected={state.connected ? 'yes' : 'no'} busy={state.busy ? 'yes' : 'no'} queue={queue.length}
        </Text>
      </Box>
      <Box flexDirection="column" borderStyle="single" paddingX={1} marginBottom={1}>
        <Text color="cyan" bold>Transcript</Text>
        {messages.length ? messages.map((m) => <MessageLine key={m.id} message={m} />) : <Text dimColor>No transcript yet.</Text>}
      </Box>
      <Box borderStyle="single" paddingX={1}>
        <Text color="green">&gt; </Text>
        <Text>{input || 'Ask Claude... Enter to send, Ctrl+C to exit'}</Text>
      </Box>
      {!inputEnabled ? (
        <Text dimColor>
          Raw mode is unavailable in this environment; TUI input is disabled.
        </Text>
      ) : null}
    </Box>
  );
}

async function main() {
  const argv = parseArgs(process.argv.slice(2));
  const baseUrl = argv.baseUrl || process.env.CLAUDE_REMOTE_URL || 'http://127.0.0.1:8080';

  if (argv.help) {
    process.stdout.write(`claude_remote\n\n`);
    process.stdout.write(`Usage:\n`);
    process.stdout.write(`  claude_remote list\n`);
    process.stdout.write(`  claude_remote --session-id <id>\n`);
    process.stdout.write(`  claude_remote --session-id <id> --base-url http://127.0.0.1:8080\n`);
    return;
  }

  if (argv.command === 'list') {
    await listSessions(baseUrl);
    return;
  }

  if (!argv.sessionId) {
    process.stderr.write('Missing --session-id. Try `claude_remote list` first.\n');
    process.exitCode = 1;
    return;
  }

  render(<SessionTui sessionId={argv.sessionId} baseUrl={baseUrl} />);
}

if (import.meta.main) {
  main().catch((err) => {
    // eslint-disable-next-line no-console
    console.error(err);
    process.exitCode = 1;
  });
}

export { main };

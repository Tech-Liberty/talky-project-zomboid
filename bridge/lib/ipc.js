// File exchange with the mod, inside <user>/Zomboid/Lua/ (the only folder PZ's Lua can read).
//   inbox  (we write)  : pending jobs, one JSON per line, rewritten atomically
//   ack    (mod writes): "S" or "S s1 s2 ..." -> we drop the jobs up to S, and s1, s2... (see parseAck)
//   outbox (mod writes): game events, one JSON per line -> we rename, read, delete.
//                        talky_outbox.txt since 0.4.0: the game (42.20.1+) only lets mods write
//                        .ini/.cfg/.txt/.log/.json files. talky_outbox.jsonl (0.3.0) is still read.

'use strict';

const crypto = require('crypto');
const fs = require('fs');
const path = require('path');

const sleep = (ms) => new Promise((r) => setTimeout(r, ms));

// Windows refuses to replace/rename a file the game has open for a few ms: retry.
async function retry(fn, tries = 20) {
  for (let i = 0; ; i++) {
    try {
      return fn();
    } catch (err) {
      if (i >= tries || !['EPERM', 'EBUSY', 'EACCES'].includes(err.code)) throw err;
      await sleep(25 + i * 10);
    }
  }
}

// Extra seqs read from one ack line, at most.
const MAX_ACK_EXTRAS = 1000;

// Gap left above every seq still on disk when bridge-state.json is lost (see start).
const LOST_STATE_SEQ_MARGIN = 1000;

// talky_ack.txt: "S" (0.3.0 mod) or "S s1 s2 ..." (0.4.0 mod).
//   S       : every job up to S is taken by the game (or expired);
//   s1 s2...: jobs above S the game also took, out of order (an answer from the server can
//             arrive before the one of an older job).
// A 0.3.0 bridge reads S only (parseInt), so both versions agree on S.
// The last number counts only when a space or a line end follows it: a file read while the
// game writes it can end in the middle of a number ("12 13" out of "12 134"). It is taken on a
// later read, or when S goes past it.
// Returns { mark: S, extra: [sorted seqs above S] }; anything unreadable counts as 0.
function parseAck(text) {
  const s = String(text ?? '');
  const tokens = s.split(/\s+/).filter(Boolean);
  const head = /^\s*(\d+)/.exec(s);
  const first = head ? Number(head[1]) : 0;
  const mark = Number.isSafeInteger(first) ? first : 0;
  // Extra seqs only after a clean S, 0 included ("0 3": job 1 still waits for an answer).
  // "x 12 13" or a huge S is not a line the mod wrote.
  if (!/^\d+$/.test(tokens[0] || '') || !Number.isSafeInteger(Number(tokens[0]))) return { mark, extra: [] };
  const complete = /\s$/.test(s);
  const extra = new Set();
  const last = complete ? tokens.length : tokens.length - 1;
  for (let i = 1; i < last && extra.size < MAX_ACK_EXTRAS; i++) {
    if (!/^\d+$/.test(tokens[i])) continue;
    const n = Number(tokens[i]);
    if (Number.isSafeInteger(n) && n > mark) extra.add(n);
  }
  return { mark, extra: [...extra].sort((a, b) => a - b) };
}

class GameLink {
  constructor({ luaDir, stateFile, jobTtlSeconds = 900, log = console.log }) {
    this.luaDir = luaDir;
    this.inbox = path.join(luaDir, 'talky_inbox.jsonl');
    this.ack = path.join(luaDir, 'talky_ack.txt');
    this.outbox = path.join(luaDir, 'talky_outbox.txt');
    this.legacyOutbox = path.join(luaDir, 'talky_outbox.jsonl'); // mod 0.3.0
    this.stateFile = stateFile;
    this.ttlMs = jobTtlSeconds * 1000;
    this.log = log;
    this.state = { seq: 0, pending: [] };
    this.lastAck = 0;
    this.ackedAbove = [];
    this.ackRead = false;
    this.writing = Promise.resolve();
  }

  start(onGameEvent) {
    fs.mkdirSync(this.luaDir, { recursive: true });
    let stateRead = false;
    try {
      const saved = JSON.parse(fs.readFileSync(this.stateFile, 'utf8'));
      if (saved && typeof saved === 'object' && !Array.isArray(saved)) {
        this.state = { ...this.state, ...saved };
        stateRead = true;
      }
    } catch { /* first run, or state lost */ }
    if (!Number.isSafeInteger(this.state.seq) || this.state.seq < 0) this.state.seq = 0;
    if (!Array.isArray(this.state.pending)) this.state.pending = [];
    // Random id kept in the state file. A new one means the state was lost and seqs may
    // start again from the ack file: the game can then forget the seqs it already saw.
    if (typeof this.state.session !== 'string' || !/^[0-9a-f]{16}$/.test(this.state.session)) {
      this.state.session = crypto.randomBytes(8).toString('hex');
    }
    // Never reuse a seq the game acknowledged or may still answer for: the ones of the ack
    // file and of the inbox left on disk (a crash between the inbox and the state writes
    // leaves a seq the state file does not know).
    const { mark, extra } = this.readAck();
    const seen = Math.max(mark, ...extra, this.inboxMaxSeq());
    // State lost: a late server answer for an old job acks its seq, so a reused seq drops the new job.
    const lost = !stateRead && (fs.existsSync(this.inbox) || fs.existsSync(this.ack));
    const floor = lost ? seen + LOST_STATE_SEQ_MARGIN : seen;
    if (lost) this.log(`${path.basename(this.stateFile)} missing or unreadable: job numbers start after #${floor}, above the ones the game may still answer for`);
    this.state.seq = Math.max(this.state.seq, floor);
    this.applyAck();
    this.flush();
    this.timer = setInterval(() => {
      this.applyAck();
      this.drainOutbox(onGameEvent).catch((e) => this.log('outbox error:', e.message));
    }, 500);
  }

  stop() {
    clearInterval(this.timer);
  }

  readAck() {
    try {
      return parseAck(fs.readFileSync(this.ack, 'utf8'));
    } catch {
      return { mark: 0, extra: [] };
    }
  }

  // Largest seq of the inbox file on disk (0 when none or unreadable): the jobs the previous
  // run of the bridge wrote and the game may have read.
  inboxMaxSeq() {
    let text;
    try {
      text = fs.readFileSync(this.inbox, 'utf8');
    } catch {
      return 0;
    }
    let max = 0;
    for (const line of text.split('\n')) {
      if (!line.trim()) continue;
      try {
        const { seq } = JSON.parse(line) || {};
        if (Number.isSafeInteger(seq) && seq > max) max = seq;
      } catch { /* a broken line is not a seq */ }
    }
    return max;
  }

  applyAck() {
    const { mark, extra } = this.readAck();
    const acked = new Set(extra);
    const now = Date.now();
    const before = this.state.pending.length;
    this.state.pending = this.state.pending.filter((j) => j.seq > mark && !acked.has(j.seq) && j.expiresAt > now);
    const known = new Set(this.ackedAbove);
    const fresh = extra.filter((s) => !known.has(s));
    // Nothing logged for the file found at startup
    if (this.ackRead && (mark > this.lastAck || fresh.length)) {
      const ahead = fresh.length ? `, and ${fresh.map((s) => `#${s}`).join(', ')}` : '';
      this.log(`game accepted the jobs up to #${mark}${ahead}`);
    }
    this.ackRead = true;
    this.lastAck = mark;
    this.ackedAbove = extra;
    if (this.state.pending.length !== before) this.flush();
  }

  push(workflow, steps, meta = {}) {
    const job = {
      seq: ++this.state.seq,
      workflow,
      steps,
      createdAt: Date.now(),
      expiresAt: Date.now() + this.ttlMs,
      ...meta,
    };
    this.state.pending.push(job);
    this.flush();
    return job;
  }

  // Serialised so two flushes never race on the temp file.
  flush() {
    this.writing = this.writing.then(() => this.writeFiles()).catch((e) => this.log('write error:', e.message));
    return this.writing;
  }

  async writeFiles() {
    const body = this.state.pending.map((j) => JSON.stringify(j)).join('\n') + (this.state.pending.length ? '\n' : '');
    const tmp = this.inbox + '.tmp';
    fs.writeFileSync(tmp, body, 'utf8');
    await retry(() => fs.renameSync(tmp, this.inbox));
    fs.writeFileSync(this.stateFile, JSON.stringify(this.state, null, 2));
  }

  // Both outbox files are drained the same way: the 0.4.0 one, then the 0.3.0 one.
  async drainOutbox(onGameEvent) {
    await this.drainFile(this.outbox, onGameEvent);
    await this.drainFile(this.legacyOutbox, onGameEvent);
  }

  async drainFile(file, onGameEvent) {
    if (!fs.existsSync(file)) return;
    const taken = `${file}.${Date.now()}.reading`;
    try {
      fs.renameSync(file, taken);
    } catch (err) {
      if (['EPERM', 'EBUSY', 'EACCES', 'ENOENT'].includes(err.code)) return; // game is writing, next tick
      throw err;
    }
    const lines = fs.readFileSync(taken, 'utf8').split('\n').map((l) => l.replace(/\r$/, '')).filter(Boolean);
    fs.unlinkSync(taken);
    for (const line of lines) {
      let evt;
      try {
        evt = JSON.parse(line);
      } catch {
        this.log('bad outbox line:', line);
        continue;
      }
      // The file is already deleted: an event that fails must not lose the next ones.
      try {
        await onGameEvent(evt);
      } catch (e) {
        this.log(`[game] ${evt && evt.event} failed:`, e.message);
      }
    }
  }
}

module.exports = { GameLink, parseAck, MAX_ACK_EXTRAS, LOST_STATE_SEQ_MARGIN };

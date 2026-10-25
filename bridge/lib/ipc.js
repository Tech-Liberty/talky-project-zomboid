// File exchange with the mod, inside <user>/Zomboid/Lua/ (the only folder PZ's Lua can read).
//   inbox  (we write)  : pending jobs, one JSON per line, rewritten atomically
//   ack    (mod writes): last executed seq -> we drop those jobs
//   outbox (mod writes): game events, one JSON per line -> we rename, read, delete

'use strict';

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

class GameLink {
  constructor({ luaDir, stateFile, jobTtlSeconds = 900, log = console.log }) {
    this.luaDir = luaDir;
    this.inbox = path.join(luaDir, 'talky_inbox.jsonl');
    this.ack = path.join(luaDir, 'talky_ack.txt');
    this.outbox = path.join(luaDir, 'talky_outbox.jsonl');
    this.stateFile = stateFile;
    this.ttlMs = jobTtlSeconds * 1000;
    this.log = log;
    this.state = { seq: 0, pending: [] };
    this.lastAck = 0;
    this.writing = Promise.resolve();
  }

  start(onGameEvent) {
    fs.mkdirSync(this.luaDir, { recursive: true });
    try {
      this.state = { ...this.state, ...JSON.parse(fs.readFileSync(this.stateFile, 'utf8')) };
    } catch { /* first run */ }
    // If the bridge state was lost, never reuse seqs the game already acknowledged.
    this.state.seq = Math.max(this.state.seq, this.readAck());
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
      return parseInt(fs.readFileSync(this.ack, 'utf8'), 10) || 0;
    } catch {
      return 0;
    }
  }

  applyAck() {
    const ack = this.readAck();
    const now = Date.now();
    const before = this.state.pending.length;
    this.state.pending = this.state.pending.filter((j) => j.seq > ack && j.expiresAt > now);
    if (ack !== this.lastAck) {
      if (ack > this.lastAck && this.lastAck !== 0) this.log(`game executed up to job #${ack}`);
      this.lastAck = ack;
    }
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

  async drainOutbox(onGameEvent) {
    if (!fs.existsSync(this.outbox)) return;
    const taken = `${this.outbox}.${Date.now()}.reading`;
    try {
      fs.renameSync(this.outbox, taken);
    } catch (err) {
      if (['EPERM', 'EBUSY', 'EACCES', 'ENOENT'].includes(err.code)) return; // game is writing, next tick
      throw err;
    }
    const lines = fs.readFileSync(taken, 'utf8').split('\n').filter(Boolean);
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

module.exports = { GameLink };

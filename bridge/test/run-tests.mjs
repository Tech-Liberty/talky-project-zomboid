// Talky bridge tests, no dependencies: node test/run-tests.mjs (or npm test).
//
// Unit tests on lib/*, then real bridge processes on free ports with a temporary
// "Zomboid/Lua" folder: authentication, 404 after authentication, double slash,
// numeric fields, http host list, caps, inbox / ack ("S s1 s2 ...") / outbox (.txt and the
// 0.3.0 .jsonl) files, first-run seeding, "Test now" right after a save and its testNonce,
// job_rejected, errors of game workflows, UTF-8 bodies, ~ in messages,
// config.json created on the first start (token never printed, never replaced), startup
// warnings. Secrets stay in config.json: no token in talky_status.json, dedicated webhook
// tokens from "hookTokens" only, http secrets from "httpTargets", CLI url / new-token. TALKY_TEST_TMP=<dir> chooses where the temporary folders go (default:
// os.tmpdir()). The tests never touch the clipboard (TALKY_NO_CLIPBOARD).

import assert from 'node:assert/strict';
import { spawn } from 'node:child_process';
import crypto from 'node:crypto';
import fs from 'node:fs';
import http from 'node:http';
import net from 'node:net';
import os from 'node:os';
import path from 'node:path';
import { createRequire } from 'node:module';
import { fileURLToPath } from 'node:url';

const require = createRequire(import.meta.url);
const here = path.dirname(fileURLToPath(import.meta.url));
const bridgeDir = path.resolve(here, '..');
const bridgeJs = path.join(bridgeDir, 'bridge.js');

const engine = require('../lib/engine.js');
const hosts = require('../lib/hosts.js');
const examples = require('../lib/examples.js');
const { GameLink, parseAck, MAX_ACK_EXTRAS, LOST_STATE_SEQ_MARGIN } = require('../lib/ipc.js');
const bridgeModule = require('../bridge.js');
const pkg = require('../package.json');

const tmpBase = process.env.TALKY_TEST_TMP || os.tmpdir();
// The bridges started below must not overwrite the clipboard of the developer (Windows)
process.env.TALKY_NO_CLIPBOARD = '1';

// ------------------------------------------------------------------ harness

const results = [];
async function t(name, fn) {
  try {
    await fn();
    results.push({ name, ok: true });
    console.log(`  ok    ${name}`);
  } catch (e) {
    results.push({ name, ok: false, error: e });
    console.log(`  FAIL  ${name}\n        ${String(e.stack || e).split('\n').slice(0, 4).join('\n        ')}`);
  }
}

const sleep = (ms) => new Promise((r) => setTimeout(r, ms));

async function waitFor(fn, timeoutMs = 4000, what = 'condition') {
  const end = Date.now() + timeoutMs;
  let last;
  while (Date.now() < end) {
    try {
      last = await fn();
      if (last) return last;
    } catch { /* retry */ }
    await sleep(50);
  }
  throw new Error(`timeout waiting for ${what}`);
}

function freePort() {
  return new Promise((resolve, reject) => {
    const srv = net.createServer();
    srv.unref();
    srv.on('error', reject);
    srv.listen(0, '127.0.0.1', () => {
      const { port } = srv.address();
      srv.close(() => resolve(port));
    });
  });
}

// Raw request: keeps the path exactly as given (fetch would not send "//hooks/x" reliably).
function request(port, method, rawPath, { headers = {}, body } = {}) {
  return new Promise((resolve, reject) => {
    const req = http.request({ host: '127.0.0.1', port, method, path: rawPath, headers }, (res) => {
      let data = '';
      res.on('data', (c) => { data += c; });
      res.on('end', () => {
        let json = null;
        try { json = JSON.parse(data); } catch { /* not JSON */ }
        resolve({ status: res.statusCode, json, text: data });
      });
    });
    req.on('error', reject);
    if (body !== undefined) req.write(typeof body === 'string' ? body : JSON.stringify(body));
    req.end();
  });
}

function readJobs(luaDir) {
  const file = path.join(luaDir, 'talky_inbox.jsonl');
  if (!fs.existsSync(file)) return [];
  return fs.readFileSync(file, 'utf8').split('\n').filter(Boolean).map((l) => JSON.parse(l));
}

// process.env plus overrides. Windows names are case-insensitive (Path / PATH): an
// overridden name replaces the inherited one whatever its case.
function mergeEnv(extra) {
  const env = { ...process.env };
  if (process.platform === 'win32') {
    const names = Object.keys(extra).map((k) => k.toLowerCase());
    for (const k of Object.keys(env)) if (names.includes(k.toLowerCase())) delete env[k];
  }
  return { ...env, ...extra };
}

function startBridge(configPath, extraEnv = {}) {
  const child = spawn(process.execPath, [bridgeJs], {
    env: mergeEnv({ LT_BRIDGE_CONFIG: configPath, ...extraEnv }),
    stdio: ['ignore', 'pipe', 'pipe'],
  });
  const proc = { child, out: '' };
  child.stdout.on('data', (c) => { proc.out += c; });
  child.stderr.on('data', (c) => { proc.out += c; });
  return proc;
}

async function stopBridge(proc) {
  if (!proc || proc.child.exitCode !== null) return;
  proc.child.kill();
  await new Promise((r) => proc.child.once('exit', r));
}

// Runs the bridge until it exits by itself (configuration errors).
function runBridgeToExit(env, args = []) {
  return new Promise((resolve) => {
    const child = spawn(process.execPath, [bridgeJs, ...args], { env: mergeEnv(env), stdio: ['ignore', 'pipe', 'pipe'] });
    let out = '';
    child.stdout.on('data', (c) => { out += c; });
    child.stderr.on('data', (c) => { out += c; });
    child.once('exit', (code) => resolve({ code, out }));
  });
}

// POST whose body is sent in several pieces, a pause between each (the server reads
// them as separate chunks).
function requestInChunks(port, rawPath, headers, parts) {
  return new Promise((resolve, reject) => {
    const req = http.request({ host: '127.0.0.1', port, method: 'POST', path: rawPath, headers }, (res) => {
      let data = '';
      res.on('data', (c) => { data += c; });
      res.on('end', () => {
        let json = null;
        try { json = JSON.parse(data); } catch { /* not JSON */ }
        resolve({ status: res.statusCode, json, text: data });
      });
    });
    req.on('error', reject);
    (async () => {
      for (const part of parts) {
        req.write(part);
        await sleep(80);
      }
      req.end();
    })();
  });
}

// console.log lines written while fn runs (the bridge logs through console.log).
async function captureLog(fn) {
  const lines = [];
  const original = console.log;
  console.log = (...args) => { lines.push(args.join(' ')); };
  try {
    await fn();
  } finally {
    console.log = original;
  }
  return lines.join('\n');
}

// ------------------------------------------------------------------ unit tests

console.log('unit');

await t('version is 0.4.0 everywhere in the bridge, file protocol 2', () => {
  assert.equal(pkg.version, '0.4.0');
  assert.equal(bridgeModule.VERSION, '0.4.0');
  assert.equal(bridgeModule.PROTOCOL, 2);
  assert.equal(pkg.name, 'talky-bridge');
  assert.equal(pkg.engines.node, '>=18');
});

await t('ack line: "S" or "S s1 s2 ..."; the last number counts once a space or a line end follows it', () => {
  assert.deepEqual(parseAck('12'), { mark: 12, extra: [] });
  assert.deepEqual(parseAck('12\n'), { mark: 12, extra: [] });
  assert.deepEqual(parseAck(' 7\r\n'), { mark: 7, extra: [] });
  assert.deepEqual(parseAck('12 15 17\n'), { mark: 12, extra: [15, 17] });
  assert.deepEqual(parseAck('12 17 15 '), { mark: 12, extra: [15, 17] }, 'sorted');
  assert.deepEqual(parseAck('12\t15\r\n17\n'), { mark: 12, extra: [15, 17] }, 'any blank separates');
  assert.deepEqual(parseAck('12 15 17'), { mark: 12, extra: [15] }, 'no line end: "17" may be the start of "170"');
  assert.deepEqual(parseAck('0 3 5\n'), { mark: 0, extra: [3, 5] }, 'job 1 still waiting, 3 and 5 answered');
  assert.deepEqual(parseAck('12 15 15 9 12 x -3 1e3 16.5 18\n'), { mark: 12, extra: [15, 18] }, 'duplicates, seqs <= S and junk ignored');
  for (const bad of ['', '   ', 'abc', '-4', 'x 12 13\n', '99999999999999999999 5\n', null, undefined]) {
    assert.deepEqual(parseAck(bad), { mark: 0, extra: [] }, String(bad));
  }
  // A 0.3.0 bridge (parseInt) reads the same S from every line a 0.4.0 mod writes
  for (const text of ['12', '12\n', '12 15 17\n', '0 3 5\n']) assert.equal(parseInt(text, 10), parseAck(text).mark, text);
  const many = `1 ${Array.from({ length: 5000 }, (_, i) => i + 2).join(' ')}\n`;
  assert.equal(parseAck(many).extra.length, MAX_ACK_EXTRAS, 'bounded');
});

await t('parseNumeric accepts plain numbers sent as strings', () => {
  assert.equal(engine.parseNumeric('500'), 500);
  assert.equal(engine.parseNumeric(' 1000 '), 1000);
  assert.equal(engine.parseNumeric('4.50'), 4.5);
  assert.equal(engine.parseNumeric('4,50'), 4.5);
  assert.equal(engine.parseNumeric('1 000'), 1000);
  assert.equal(engine.parseNumeric('1,000'), 1000);
  assert.equal(engine.parseNumeric('-3'), -3);
  assert.equal(engine.parseNumeric(12), 12);
  assert.equal(engine.parseNumeric('abc'), undefined);
  assert.equal(engine.parseNumeric('12abc'), undefined);
  assert.equal(engine.parseNumeric(''), undefined);
  assert.equal(engine.parseNumeric(null), undefined);
});

await t('numeric filters accept strings', () => {
  const vars = { a: '500', b: '4,50', c: '1 000', d: 'x' };
  assert.equal(engine.render('{{a | div:100 | floor}}', vars), 5);
  assert.equal(engine.render('{{b | mul:2}}', vars), 9);
  assert.equal(engine.render('{{c | add:1}}', vars), 1001);
  assert.equal(engine.render('{{d | add:1}}', vars), 1);
  assert.equal(engine.render('{{a | clamp:1:20}}', vars), 20);
  assert.equal(engine.render('{{a}} bits', vars), '500 bits');
});

await t('buildVars converts bits, viewers, total, amount and tier to numbers', () => {
  const v = engine.buildVars({ bits: '500', viewers: '12', total: '3', amount: '4,50', tier: '1000', message: '42', user_name: 'Bob' });
  assert.equal(v.bits, 500);
  assert.equal(v.viewers, 12);
  assert.equal(v.total, 3);
  assert.equal(v.amount, 4.5);
  assert.equal(v.tier, 1000);
  assert.equal(v.message, '42', 'other fields stay strings');
  assert.equal(v.user, 'Bob');
  assert.equal(v.payload.bits, '500', 'payload keeps the raw body');
  assert.equal(engine.buildVars({ tier: 'Prime' }).tier, 'Prime');
});

await t('conditions see converted numbers', () => {
  const v = engine.buildVars({ bits: '500', tier: '3000' });
  assert.equal(engine.test({ bits: { gte: 100 } }, v), true);
  assert.equal(engine.test({ bits: { lt: 100 } }, v), false);
  assert.equal(engine.test({ tier: '3000' }, v), true);
  assert.equal(engine.test({ tier: 3000 }, v), true);
  assert.equal(engine.test({ tier: ['2000', '3000'] }, v), true);
});

await t('anonymous name: Anonymous by default, configurable', () => {
  assert.equal(engine.buildVars({}).user, 'Anonymous');
  assert.equal(engine.buildVars({}, {}, { anonymousName: 'Anonyme' }).user, 'Anonyme');
  const tmp = os.tmpdir();
  const make = (settings) => new bridgeModule.Bridge({ zomboidLuaDir: tmp, token: 'x', settings });
  assert.equal(make({ language: 'en' }).anonymousName(), 'Anonymous');
  assert.equal(make({ language: 'fr' }).anonymousName(), 'Anonyme');
  assert.equal(make({ language: 'fr', anonymousName: ' Mystère ' }).anonymousName(), 'Mystère');
  assert.equal(make(undefined).anonymousName(), 'Anonymous');
  assert.equal(make({ language: 'fr' }).varsFor({ bits: '1' }).user, 'Anonyme');
});

await t('caps: wait <= 600 s, notify/say/halo text <= 200 characters', () => {
  const long = 'x'.repeat(500);
  const { game } = engine.expand([
    { action: 'wait', seconds: 99999 },
    { action: 'wait', seconds: '-5' },
    { action: 'notify', text: long, seconds: 999 },
    { action: 'say', text: long },
    { action: 'halo', text: `{{v}}${long}` },
    { action: 'spawn_zombie', name: long },
  ], { v: 'a' });
  assert.equal(game[0].seconds, 600);
  assert.equal(game[1].seconds, 0);
  assert.equal(game[2].text.length, 200);
  assert.equal(game[2].seconds, 60);
  assert.equal(game[3].text.length, 200);
  assert.equal(game[4].text.length, 200);
  assert.equal(game[5].name.length, 500, 'other fields untouched (the mod caps names itself)');
  const emoji = engine.clipText('😀'.repeat(300));
  assert.equal(Array.from(emoji).length, 200, 'counts characters, not UTF-16 units');
});

await t('repeat and job size have hard ceilings', () => {
  const one = engine.expand([{ repeat: 10000, max: 10000, steps: [{ action: 'noise' }] }], {});
  assert.equal(one.game.length, engine.LIMITS.repeatMax);
  assert.equal(one.truncated, false);
  const big = engine.expand([{ repeat: 100, max: 100, steps: [{ repeat: 100, max: 100, steps: [{ action: 'noise' }] }] }], {});
  assert.equal(big.game.length, engine.LIMITS.gameStepsPerJob);
  assert.ok(big.dropped > 0);
  assert.equal(big.truncated, true, '20 201 steps and loop turns: past the walk budget');
  assert.ok(big.visited <= engine.LIMITS.visitedStepsPerJob + 1);
  const httpSpam = engine.expand([{ repeat: 100, max: 100, steps: [{ action: 'log', message: 'x' }] }], {});
  assert.equal(httpSpam.bridge.length, engine.LIMITS.bridgeStepsPerJob);
  assert.equal(httpSpam.dropped, 100 - engine.LIMITS.bridgeStepsPerJob);
});

await t('nested repeats stop early: 4 and 5 levels of repeat 100 take less than 100 ms', () => {
  const nest = (levels, inner) => {
    let steps = inner;
    for (let l = 0; l < levels; l++) steps = [{ repeat: 100, max: 100, steps }];
    return steps;
  };
  for (const levels of [4, 5]) {
    const t0 = performance.now();
    const out = engine.expand(nest(levels, [{ action: 'noise' }]), {});
    const ms = performance.now() - t0;
    assert.ok(ms < 100, `${levels} levels took ${ms.toFixed(1)} ms`);
    assert.equal(out.game.length, engine.LIMITS.gameStepsPerJob);
    assert.equal(out.truncated, true);
    assert.ok(out.visited <= engine.LIMITS.visitedStepsPerJob + 1, `visited ${out.visited}`);
  }
  // Game and http/log lists both full: the walk stops right away, well before the budget
  const both = engine.expand(nest(5, [{ action: 'noise' }, { action: 'log', message: '{{i}}' }]), {});
  assert.equal(both.game.length, engine.LIMITS.gameStepsPerJob);
  assert.equal(both.bridge.length, engine.LIMITS.bridgeStepsPerJob);
  assert.equal(both.truncated, true);
  assert.ok(both.visited < 2000, `visited ${both.visited}`);
  // Loops with nothing inside count their turns too
  const t1 = performance.now();
  const empty = engine.expand(nest(5, []), {});
  assert.ok(performance.now() - t1 < 100);
  assert.equal(empty.truncated, true);
  // A usual workflow is not cut
  const usual = engine.expand([
    { repeat: 20, steps: [{ action: 'spawn_zombie', name: '{{i}}' }, { action: 'wait', seconds: 1 }] },
    { action: 'log', message: 'done' },
  ], {});
  assert.equal(usual.truncated, false);
  assert.equal(usual.game.length, 40);
  assert.equal(usual.game[38].name, 20);
  assert.equal(usual.bridge.length, 1);
});

await t('filters and operators: inherited names (constructor, toString, __proto__) are unknown', () => {
  assert.throws(() => engine.render('{{user | toString}}', { user: 'a' }), /unknown filter "toString"/);
  assert.throws(() => engine.render('{{user | constructor}}', { user: 'a' }), /unknown filter "constructor"/);
  assert.throws(() => engine.render('{{user | __proto__}}', { user: 'a' }), /unknown filter "__proto__"/);
  assert.throws(() => engine.test({ x: { constructor: 1 } }, { x: 'a' }), /unknown operator "constructor"/);
  assert.throws(() => engine.test({ x: { hasOwnProperty: 'x' } }, { x: 'a' }), /unknown operator "hasOwnProperty"/);
  assert.equal(engine.render('{{user | upper}}', { user: 'a' }), 'A');
  assert.equal(engine.test({ x: { contains: 'A' } }, { x: 'bab' }), true);
});

await t('hideHome replaces the user folder in any text', () => {
  const home = os.homedir();
  const msg = `ENOENT: no such file or directory, open '${path.join(home, 'Zomboid', 'Lua', 'talky_config.json')}'`;
  const out = bridgeModule.hideHome(msg);
  assert.ok(!out.includes(home), out);
  assert.match(out, /open '~[\\/]Zomboid[\\/]Lua[\\/]talky_config\.json'/);
  assert.equal(bridgeModule.hideHome(`${home.split(path.sep).join('/')}/Zomboid`), '~/Zomboid', 'with / separators too');
  assert.equal(bridgeModule.hideHome(`${home}2${path.sep}x`), `${home}2${path.sep}x`, 'a longer folder name is not cut');
  assert.equal(bridgeModule.hideHome('no path here'), 'no path here');
});

const unitTmp = fs.mkdtempSync(path.join(tmpBase, 'talky-unit-'));
const exampleConfig = () => JSON.parse(fs.readFileSync(path.join(bridgeDir, 'config.example.json'), 'utf8'));

await t('seed: a talky_config.json saved by F8 without webhooks or workflows gets the examples', async () => {
  const dir = path.join(unitTmp, 'seed-empty');
  fs.mkdirSync(dir);
  const file = path.join(dir, 'talky_config.json');
  // What the window writes when F8 > Save comes before the first launch of the bridge
  fs.writeFileSync(file, JSON.stringify({
    publicUrl: 'https://abc.trycloudflare.com', webhooks: {}, workflows: [], gameEvents: {},
    settings: { language: 'fr', toastSeconds: 7 },
  }));
  const example = exampleConfig();
  const b = new bridgeModule.Bridge({ ...example, token: 'x', zomboidLuaDir: dir });
  const out = await captureLog(() => b.seedGameConfig());
  assert.match(out, /talky_config\.json had no webhook and no workflow: examples added from config\.json \(fr: \d+ text\(s\) translated\)/);
  const game = JSON.parse(fs.readFileSync(file, 'utf8'));
  assert.deepEqual(Object.keys(game.webhooks).sort(), Object.keys(example.webhooks).sort());
  assert.deepEqual(Object.keys(game.workflows).sort(), Object.keys(example.workflows).sort());
  assert.equal(game.workflows.new_follower.steps[0].text, '{{user}} rejoint la horde !', 'language saved by F8 wins');
  assert.equal(game.publicUrl, 'https://abc.trycloudflare.com', 'public URL kept');
  assert.equal(game.settings.toastSeconds, 7, 'settings saved by F8 kept');
  assert.equal(game.settings.anonymousName, '', 'missing settings taken from config.json');
  assert.deepEqual(game.gameEvents, example.gameEvents);
  assert.equal(game.token, undefined);
  await captureLog(() => b.loadGameConfig());
  assert.equal(Object.keys(b.cfg.webhooks).length, Object.keys(example.webhooks).length);
  assert.equal(b.cfg.publicUrl, 'https://abc.trycloudflare.com');
});

await t('seed: a talky_config.json with webhooks, workflows or unreadable JSON is left alone', async () => {
  const example = exampleConfig();
  const cases = {
    'only-workflows': JSON.stringify({ webhooks: {}, workflows: { mine: { steps: [] } } }),
    'only-webhooks': JSON.stringify({ webhooks: { a: { workflow: 'x' } }, workflows: {} }),
    broken: '{ "webhooks": {',
  };
  for (const [name, content] of Object.entries(cases)) {
    const dir = path.join(unitTmp, `seed-${name}`);
    fs.mkdirSync(dir);
    const file = path.join(dir, 'talky_config.json');
    fs.writeFileSync(file, content);
    const b = new bridgeModule.Bridge({ ...example, token: 'x', zomboidLuaDir: dir });
    const out = await captureLog(() => b.seedGameConfig());
    assert.equal(fs.readFileSync(file, 'utf8'), content, `${name}: file unchanged`);
    assert.equal(out, '', `${name}: nothing logged`);
  }
  // Empty file but a config.json without examples either: nothing to add, nothing rewritten
  const bare = path.join(unitTmp, 'seed-bare');
  fs.mkdirSync(bare);
  const bareContent = JSON.stringify({ webhooks: {}, workflows: {}, settings: { language: 'fr' } });
  fs.writeFileSync(path.join(bare, 'talky_config.json'), bareContent);
  const bareOut = await captureLog(() => new bridgeModule.Bridge({ token: 'x', zomboidLuaDir: bare }).seedGameConfig());
  assert.equal(fs.readFileSync(path.join(bare, 'talky_config.json'), 'utf8'), bareContent);
  assert.equal(bareOut, '');
  // No file at all: created from config.json, as before
  const dir = path.join(unitTmp, 'seed-none');
  const b = new bridgeModule.Bridge({ ...example, token: 'x', zomboidLuaDir: dir });
  const out = await captureLog(() => b.seedGameConfig());
  assert.match(out, /created .*talky_config\.json from config\.json/);
  assert.ok(JSON.parse(fs.readFileSync(path.join(dir, 'talky_config.json'), 'utf8')).webhooks.follow);
});

await t('outbox: an event that throws does not lose the rest of the batch', async () => {
  const dir = path.join(unitTmp, 'outbox');
  fs.mkdirSync(dir);
  const logs = [];
  const link = new GameLink({ luaDir: dir, stateFile: path.join(dir, 'state.json'), log: (...a) => logs.push(a.join(' ')) });
  const outbox = path.join(dir, 'talky_outbox.jsonl');
  fs.writeFileSync(outbox, `${['{"event":"a"}', 'not json', '{"event":"boom"}', 'null', '{"event":"c"}'].join('\n')}\n`);
  const seen = [];
  await link.drainOutbox(async (evt) => {
    if (evt === null) throw new TypeError("Cannot read properties of null (reading 'event')");
    seen.push(evt.event);
    if (evt.event === 'boom') throw new Error('unknown filter "nope"');
  });
  assert.deepEqual(seen, ['a', 'boom', 'c']);
  assert.ok(logs.some((l) => /^\[game\] boom failed: unknown filter "nope"$/.test(l)), logs.join(' | '));
  assert.ok(logs.some((l) => /^bad outbox line: not json$/.test(l)));
  assert.equal(fs.existsSync(outbox), false);
});

await t('outbox: talky_outbox.txt (mod 0.4.0) and talky_outbox.jsonl (mod 0.3.0) are both read', async () => {
  const dir = path.join(unitTmp, 'outbox-both');
  fs.mkdirSync(dir);
  const link = new GameLink({ luaDir: dir, stateFile: path.join(dir, 'state.json'), log: () => {} });
  fs.writeFileSync(path.join(dir, 'talky_outbox.txt'), '{"event":"new1"}\r\n{"event":"new2","data":{"n":1}}\n');
  fs.writeFileSync(path.join(dir, 'talky_outbox.jsonl'), '{"event":"old1"}\n');
  const seen = [];
  await link.drainOutbox(async (evt) => { seen.push(evt.event); });
  assert.deepEqual(seen, ['new1', 'new2', 'old1']);
  assert.deepEqual(fs.readdirSync(dir), [], 'both files deleted, no .reading file left');
  // Only the new file, then only the old one
  fs.writeFileSync(path.join(dir, 'talky_outbox.txt'), '{"event":"a"}\n');
  await link.drainOutbox(async (evt) => { seen.push(evt.event); });
  fs.writeFileSync(path.join(dir, 'talky_outbox.jsonl'), '{"event":"b"}\n');
  await link.drainOutbox(async (evt) => { seen.push(evt.event); });
  assert.deepEqual(seen.slice(3), ['a', 'b']);
});

await t('ack: jobs acknowledged out of order leave the inbox, the others stay', async () => {
  const dir = path.join(unitTmp, 'ack-extra');
  fs.mkdirSync(dir);
  const logs = [];
  const link = new GameLink({ luaDir: dir, stateFile: path.join(dir, 'state.json'), log: (...a) => logs.push(a.join(' ')) });
  for (let i = 1; i <= 6; i++) link.push(`wf${i}`, [{ action: 'noise' }]);
  await link.writing;
  const inboxSeqs = () => fs.readFileSync(path.join(dir, 'talky_inbox.jsonl'), 'utf8').split('\n').filter(Boolean).map((l) => JSON.parse(l).seq);
  const ackFile = path.join(dir, 'talky_ack.txt');
  const ack = async (text) => {
    fs.writeFileSync(ackFile, text);
    link.applyAck();
    await link.writing;
  };
  assert.deepEqual(inboxSeqs(), [1, 2, 3, 4, 5, 6]);
  await ack('2\n');
  assert.deepEqual(inboxSeqs(), [3, 4, 5, 6]);
  assert.deepEqual(logs, [], 'the ack found at startup is not logged');
  await ack('2 4 6');
  assert.deepEqual(inboxSeqs(), [3, 5, 6], '6 is not followed by a line end yet');
  await ack('2 4 6\n');
  assert.deepEqual(inboxSeqs(), [3, 5]);
  assert.equal(link.lastAck, 2);
  assert.deepEqual(link.ackedAbove, [4, 6]);
  assert.deepEqual(logs, ['game accepted the jobs up to #2, and #4', 'game accepted the jobs up to #2, and #6']);
  // Job 3 answered: the mod moves S to 4 and keeps 6
  await ack('4 6\n');
  assert.deepEqual(inboxSeqs(), [5]);
  assert.equal(logs.length, 3);
  assert.equal(logs[2], 'game accepted the jobs up to #4');
  // A 0.3.0 mod writes S alone
  await ack('5');
  assert.deepEqual(inboxSeqs(), []);
  assert.deepEqual(link.ackedAbove, []);
});

await t('state: seqs continue above every acknowledged seq; the session id lives as long as the state file', async () => {
  const dir = path.join(unitTmp, 'state-session');
  fs.mkdirSync(dir);
  const stateFile = path.join(dir, 'state.json');
  fs.writeFileSync(path.join(dir, 'talky_ack.txt'), '3 9 7\n');
  const started = async () => {
    const link = new GameLink({ luaDir: dir, stateFile, log: () => {} });
    link.start(async () => {});
    link.stop();
    await link.writing;
    return link;
  };
  // A state file behind the ack file (seq 3): seqs go on above the ack
  fs.writeFileSync(stateFile, JSON.stringify({ seq: 3, pending: [] }));
  const a = await started();
  assert.match(a.state.session, /^[0-9a-f]{16}$/);
  assert.equal(a.push('x', [{ action: 'noise' }]).seq, 10, 'never a seq the game already acknowledged (9)');
  await a.writing;
  const b = await started();
  assert.equal(b.state.session, a.state.session, 'same state file: same session');
  assert.equal(b.push('x', [{ action: 'noise' }]).seq, 11);
  await b.writing;
  // State lost (deleted, other folder): a new session, and seqs far above the ones on disk
  // (inbox 10 and 11, ack 9)
  fs.unlinkSync(stateFile);
  const c = await started();
  assert.match(c.state.session, /^[0-9a-f]{16}$/);
  assert.notEqual(c.state.session, a.state.session);
  assert.equal(c.push('x', [{ action: 'noise' }]).seq, 11 + LOST_STATE_SEQ_MARGIN + 1);
  await c.writing;
  assert.equal(JSON.parse(fs.readFileSync(stateFile, 'utf8')).session, c.state.session, 'saved');
});

await t('state lost: the next seq is above every seq of the inbox and of the ack file, with a margin', async () => {
  const started = async (dir, stateFile, logs = []) => {
    const link = new GameLink({ luaDir: dir, stateFile, log: (...a) => logs.push(a.join(' ')) });
    link.start(async () => {});
    link.stop();
    await link.writing;
    return link;
  };
  const job = (seq) => JSON.stringify({ seq, workflow: 'w', steps: [{ action: 'noise' }], createdAt: Date.now(), expiresAt: Date.now() + 60000 });
  // The old bridge wrote jobs 40 and 41 (the game may have relayed them), the game acked up
  // to 12 and 30; its late answer for 41 must not ack a new job
  const dir = path.join(unitTmp, 'state-lost');
  fs.mkdirSync(dir);
  fs.writeFileSync(path.join(dir, 'talky_inbox.jsonl'), `${job(40)}\nnot json\n${job(41)}\n{"seq":"999"}\n{"seq":1e300}\n`);
  fs.writeFileSync(path.join(dir, 'talky_ack.txt'), '12 30\n');
  const logs = [];
  const a = await started(dir, path.join(dir, 'state.json'), logs);
  assert.equal(a.push('x', [{ action: 'noise' }]).seq, 41 + LOST_STATE_SEQ_MARGIN + 1, 'above 41, unreadable lines and seqs ignored');
  await a.writing;
  assert.deepEqual(logs, [`state.json missing or unreadable: job numbers start after #${41 + LOST_STATE_SEQ_MARGIN}, above the ones the game may still answer for`]);
  // An ack file alone counts too; an unreadable state file is a lost one
  const dir2 = path.join(unitTmp, 'state-broken');
  fs.mkdirSync(dir2);
  fs.writeFileSync(path.join(dir2, 'talky_ack.txt'), '3 7\n');
  fs.writeFileSync(path.join(dir2, 'state.json'), '{ broken');
  const b = await started(dir2, path.join(dir2, 'state.json'));
  assert.equal(b.push('x', [{ action: 'noise' }]).seq, 7 + LOST_STATE_SEQ_MARGIN + 1);
  await b.writing;
  // State kept but one write behind the inbox (stopped between the two writes): above the inbox, no margin
  const dir3 = path.join(unitTmp, 'state-behind');
  fs.mkdirSync(dir3);
  fs.writeFileSync(path.join(dir3, 'talky_inbox.jsonl'), `${job(5)}\n${job(6)}\n`);
  fs.writeFileSync(path.join(dir3, 'state.json'), JSON.stringify({ seq: 5, pending: [] }));
  const quiet = [];
  const c = await started(dir3, path.join(dir3, 'state.json'), quiet);
  assert.equal(c.push('x', [{ action: 'noise' }]).seq, 7);
  assert.deepEqual(quiet, []);
  await c.writing;
  // First start in an empty folder: from 1, nothing logged
  const dir4 = path.join(unitTmp, 'state-first');
  fs.mkdirSync(dir4);
  const firstLogs = [];
  const d = await started(dir4, path.join(dir4, 'state.json'), firstLogs);
  assert.equal(d.push('x', [{ action: 'noise' }]).seq, 1);
  assert.deepEqual(firstLogs, []);
  await d.writing;
});

// A Bridge that never listens, with its files in dir (its state file too, never in bridge/).
async function bridgeIn(dir, game, extra = {}) {
  fs.mkdirSync(dir, { recursive: true });
  if (game) fs.writeFileSync(path.join(dir, 'talky_config.json'), JSON.stringify(game));
  const b = new bridgeModule.Bridge({ token: 'x', port: 1234, zomboidLuaDir: dir, ...extra });
  b.link.stateFile = path.join(dir, 'bridge-state.json');
  if (game) await captureLog(() => b.loadGameConfig());
  return b;
}

await t('Test now: test_workflow runs only with the testNonce of this start; each refusal reason logged once', async () => {
  const dir = path.join(unitTmp, 'nonce');
  const b = await bridgeIn(dir, { workflows: { t1: { steps: [{ action: 'notify', text: 'hi {{user}}' }] } } });
  const other = await bridgeIn(path.join(unitTmp, 'nonce-other'));
  assert.match(b.testNonce, /^[0-9a-f]{32}$/);
  assert.notEqual(b.testNonce, other.testNonce, 'a new value for each bridge started');
  let res;
  // Mod 0.3.0: no nonce
  let out = await captureLog(async () => { res = await b.handleGameEvent({ event: 'test_workflow', data: { workflow: 't1', vars: { user: 'Tess' } } }); });
  assert.equal(res.skipped, 'no test code');
  assert.match(out, /\[test\] "Test now" refused: it carries no test code\. Talky mods older than 0\.4\.0 do not send it: update the mod \(the bridge and the mod go together\)\. Further refusals of this kind are not logged\./);
  for (const nonce of [undefined, '', 42, null]) {
    out = await captureLog(async () => { res = await b.handleGameEvent({ event: 'test_workflow', data: { workflow: 't1', nonce } }); });
    assert.equal(res.skipped, 'no test code', String(nonce));
    assert.equal(out, '', 'logged once');
  }
  // Wrong nonce: the one of another start
  out = await captureLog(async () => { res = await b.handleGameEvent({ event: 'test_workflow', data: { workflow: 't1', nonce: other.testNonce } }); });
  assert.equal(res.skipped, 'test code mismatch');
  assert.match(out, /"Test now" refused: its test code is not the one of this bridge .*press Test now again/);
  out = await captureLog(() => b.handleGameEvent({ event: 'test_workflow', data: { workflow: 't1', nonce: `${b.testNonce}0` } }));
  assert.equal(out, '', 'logged once');
  assert.equal(b.link.state.pending.length, 0, 'no job');
  const refusals = b.recent.filter((e) => e.source === 'test');
  assert.deepEqual(refusals.map((e) => e.error), ['Test now refused: test code mismatch, press Test now again', 'Test now refused: update the Talky mod to 0.4.0']);
  // "skipped": the reason the 0.4.0 window translates (UI_Talky_Skip_<reason, _ for spaces>)
  assert.deepEqual(refusals.map((e) => e.skipped), ['test code mismatch', 'no test code']);
  assert.equal(refusals[0].workflow, 't1');
  // Right nonce
  out = await captureLog(async () => { res = await b.handleGameEvent({ event: 'test_workflow', data: { workflow: 't1', vars: { user: 'Tess' }, nonce: b.testNonce } }); });
  assert.equal(typeof res.job, 'number', JSON.stringify(res));
  assert.equal(b.link.state.pending[0].steps[0].text, 'hi Tess');
  await b.link.writing;
});

await t('job_rejected / job_expired: console line and Status page entry, never a workflow', async () => {
  const dir = path.join(unitTmp, 'rejected');
  const b = await bridgeIn(dir, {
    workflows: { w: { steps: [{ action: 'notify', text: 'hello' }] }, on_rej: { steps: [{ action: 'notify', text: 'loop' }] } },
    gameEvents: { job_rejected: 'on_rej', job_expired: 'on_rej' },
  });
  await captureLog(() => b.runWorkflow('w', b.varsFor({ user_name: 'Viewer1' }), 'hook:follow'));
  const seq = b.link.state.pending[0].seq;
  let res;
  let out = await captureLog(async () => { res = await b.handleGameEvent({ event: 'job_rejected', data: { seq, workflow: 'forged', reason: 'not_allowed' } }); });
  assert.deepEqual(res, { event: 'job_rejected', job: seq, rejected: 'not_allowed' });
  assert.equal(out.split('\n').length, 1, out);
  assert.ok(out.includes(`[game] job #${seq} (w) refused by the server: not_allowed - this player may not use Talky on this server. A server admin adds the username to the sandbox option Talky.AllowedPlayers`), out);
  assert.deepEqual({ ...b.recent[0], at: undefined }, {
    at: undefined, source: 'game:job_rejected', workflow: 'w', user: 'Viewer1', job: seq, rejected: 'not_allowed',
    error: 'refused by the server: not_allowed',
  }, 'workflow and viewer as the bridge recorded them');
  // Odd text from the game: no control character reaches the console, unknown reasons stay codes
  out = await captureLog(() => b.handleGameEvent({ event: 'job_rejected', data: { seq: 999, workflow: 'a\nb', reason: 'Boom\n12:00:00 [Talky] fake' } }));
  assert.equal(out.split('\n').length, 1, out);
  assert.match(out, /job #999 \(a b\) refused by the server: unknown - see the \[Talky\] lines of the server console\./);
  assert.equal(b.recent[0].rejected, 'unknown');
  out = await captureLog(() => b.handleGameEvent({ event: 'job_rejected', data: { seq: 'x', reason: 'constructor' } }));
  assert.match(out, /\[game\] job refused by the server: constructor - see the \[Talky\] lines/, 'no hint from Object.prototype');
  assert.equal(b.recent[0].job, undefined);
  for (const r of ['not_allowed', 'invalid', 'duplicate', 'unknown_action', 'disabled', 'expired', 'too_large']) assert.equal(typeof bridgeModule.REJECT_HINTS[r], 'string', r);
  // too_large: refused by the game of this PC (it cannot be sent), not by the server
  out = await captureLog(() => b.handleGameEvent({ event: 'job_rejected', data: { seq, workflow: 'w', reason: 'too_large' } }));
  assert.equal(out.split('\n').length, 1, out);
  assert.ok(out.includes(`[game] job #${seq} (w) not sent to the server: too_large - the job is too large for one network message of the game, so the game on this PC did not send it to the server. Give the workflow fewer steps`), out);
  assert.equal(b.recent[0].rejected, 'too_large');
  assert.equal(b.recent[0].error, 'not sent to the server: too_large');
  // Expired
  out = await captureLog(async () => { res = await b.handleGameEvent({ event: 'job_expired', data: { seq, workflow: 'w' } }); });
  assert.equal(res.rejected, 'expired');
  assert.match(out, new RegExp(`\\[game\\] job #${seq} \\(w\\) expired - the job waited longer than its time to live`));
  assert.equal(b.recent[0].error, 'expired before it could start');
  assert.equal(b.recent[0].user, 'Viewer1');
  assert.equal(b.link.state.pending.length, 1, 'on_rej never ran');
  await b.link.writing;
});

await t('game events: no name, a name with control characters or a name over 64 characters is ignored', async () => {
  const dir = path.join(unitTmp, 'events');
  const b = await bridgeIn(dir, { workflows: { w: { steps: [{ action: 'notify', text: '{{name}}' }] } }, gameEvents: { zombie_killed: 'w' } });
  const out = await captureLog(async () => {
    for (const evt of [null, 'text', 42, [], {}, { event: '' }, { event: 5 }, { event: 'x'.repeat(65) }, { event: 'zombie_killed\n12:00:00 [hook:follow] fake' }]) {
      const res = await b.handleGameEvent(evt);
      assert.equal(res.skipped, 'bad event', JSON.stringify(evt));
    }
  });
  assert.equal(out.split('\n').length, 9, out);
  assert.ok(out.split('\n').every((l) => l.includes('[game] event ignored (no valid "event" name)')), out);
  assert.equal(b.link.state.pending.length, 0);
  // A valid event whose data is a list (empty Kahlua table) runs with no data
  const res = await captureLog(() => b.handleGameEvent({ event: 'zombie_killed', data: [] }));
  assert.match(res, /\[game\] zombie_killed \{\}/);
  assert.equal(b.link.state.pending.length, 1);
  await b.link.writing;
});

await t('talky_status.json: protocol, testNonce and session for the F8 window', async () => {
  const dir = path.join(unitTmp, 'status');
  const b = await bridgeIn(dir, {});
  b.link.state.session = '0123456789abcdef';
  b.writeStatus();
  const st = JSON.parse(fs.readFileSync(path.join(dir, 'talky_status.json'), 'utf8'));
  assert.equal(st.version, '0.4.0');
  assert.equal(st.protocol, 2);
  assert.equal(st.testNonce, b.testNonce);
  assert.equal(st.session, '0123456789abcdef');
  assert.equal(st.lastAck, 0);
  assert.equal(st.pending, 0);
  assert.equal(st.port, 1234);
  assert.equal(st.token, undefined, 'every mod running in the game can read this file');
  assert.deepEqual(st.hookTokens, []);
});

await t('stop: the last talky_status.json has no test code and shows the bridge offline (ts 0)', async () => {
  const dir = path.join(unitTmp, 'stop');
  fs.mkdirSync(dir, { recursive: true });
  const main = 'main-token-for-the-stop-test-0123';
  const dedicated = 'dedicated-token-for-the-stop-test';
  const b = new bridgeModule.Bridge({ token: main, port: await freePort(), zomboidLuaDir: dir, hookTokens: { a: dedicated } });
  b.link.stateFile = path.join(dir, 'bridge-state.json');
  await captureLog(async () => {
    b.start();
    await new Promise((r) => b.server.once('listening', r));
  });
  const statusFile = path.join(dir, 'talky_status.json');
  const running = JSON.parse(fs.readFileSync(statusFile, 'utf8'));
  assert.equal(running.testNonce, b.testNonce);
  assert.ok(running.ts > 0);
  assert.deepEqual(running.hookTokens, ['a'], 'ids only');
  const text = fs.readFileSync(statusFile, 'utf8');
  assert.ok(!text.includes(main) && !text.includes(dedicated), 'no token in the file');
  await captureLog(() => b.stop());
  const st = JSON.parse(fs.readFileSync(statusFile, 'utf8'));
  assert.equal(st.ts, 0);
  assert.equal(st.stopped, true);
  assert.equal(st.testNonce, undefined);
  assert.equal(st.version, '0.4.0');
  assert.equal(st.session, running.session);
  b.stop(); // twice: nothing written again, no error
  await b.link.writing;
});

await t('a webhook "token" in talky_config.json is ignored, one warning per webhook and per start; hookTokens of config.json count', async () => {
  const dir = path.join(unitTmp, 'planted');
  fs.mkdirSync(dir, { recursive: true });
  const planted = 'planted-by-a-mod-0123456789';
  const dedicated = 'dedicated-0123456789abcdef';
  fs.writeFileSync(path.join(dir, 'talky_config.json'), JSON.stringify({
    webhooks: { a: { workflow: 'w', token: planted }, 'b\nfake': { workflow: 'w', token: 'x' }, c: { workflow: 'w' }, d: { workflow: 'w', token: '' } },
  }));
  const b = new bridgeModule.Bridge({ token: 'main-token', port: 1, zomboidLuaDir: dir, hookTokens: { c: dedicated } });
  let out = await captureLog(() => b.loadGameConfig());
  assert.match(out, /warning: the "token" of webhook "a", "b fake" in talky_config\.json is ignored: every mod running in the game can write that file\. A dedicated webhook token is read from "hookTokens" in bridge\/config\.json only, for example "hookTokens": \{ "a": "<long random text>" \}; a webhook not listed there takes the bridge token\./);
  assert.ok(!out.includes(planted), 'the planted value is never printed');
  out = await captureLog(() => b.loadGameConfig());
  assert.doesNotMatch(out, /warning/, 'once per webhook and per start');
  const req = (token) => ({ headers: { 'x-bridge-token': token } });
  const u = new URL('http://localhost/hooks/a');
  assert.equal(b.authorized(req(planted), u, 'a'), false, 'a planted token opens nothing');
  assert.equal(b.authorized(req('main-token'), u, 'a'), true);
  assert.equal(b.authorized(req('main-token'), u, 'c'), false, 'a dedicated token replaces the bridge token');
  assert.equal(b.authorized(req(dedicated), u, 'c'), true);
  assert.equal(b.authorized(req(dedicated), u), false, '/fire and /health take the bridge token');
  assert.equal(b.authorized(req(dedicated), u, 'a'), false);
  assert.equal(b.authorized(req('main-token'), u, 'constructor'), true, 'no dedicated token from Object.prototype');
});

await t('http step with "target": address and secrets from httpTargets of config.json only, the url, headers and hmac of the step ignored', async () => {
  const b = await bridgeIn(path.join(unitTmp, 'targets'), null, {
    httpAllowedHosts: ['*.liberty-talk.com'],
    httpTargets: {
      lt: { url: 'https://api.liberty-talk.com/webhooks/workflow/abc123', headers: { 'X-Webhook-Secret': 's' }, hmacSecret: 'k', hmacHeader: 'X-Sig' },
      put: { url: 'https://api.liberty-talk.com/x', method: 'put' },
      unfilled: { url: 'https://api.liberty-talk.com/webhooks/workflow/PASTE_THE_TOKEN' },
      header_unfilled: { url: 'https://api.liberty-talk.com/x', headers: { 'X-Webhook-Secret': 'PASTE_THE_SECRET' } },
      outside: { url: 'https://evil.example/secret-path-123' },
      broken: { url: 'not a url secret-path-456' },
    },
  });
  let req;
  const out = await captureLog(() => {
    req = b.httpRequestFor({ action: 'http', target: 'lt', url: 'https://evil.example/x', headers: { 'X-Evil': '1' }, hmacSecret: 'mod', body: {} }, { workflow: 'w' });
    b.httpRequestFor({ action: 'http', target: 'lt', url: 'https://evil.example/x' }, { workflow: 'w' });
  });
  assert.equal(req.url.href, 'https://api.liberty-talk.com/webhooks/workflow/abc123');
  assert.deepEqual(req.headers, { 'X-Webhook-Secret': 's' });
  assert.equal(req.hmacSecret, 'k');
  assert.equal(req.hmacHeader, 'X-Sig');
  assert.equal(req.method, 'POST');
  assert.equal(out.split('\n').length, 1, `logged once: ${out}`);
  assert.match(out, /\[w\] http step: "url", "headers", "hmacSecret" ignored, the step has a "target" \("httpTargets" > "lt" of bridge\/config\.json gives the address and its secrets\)/);
  assert.equal(b.httpRequestFor({ action: 'http', target: 'put', method: 'GET' }, {}).method, 'PUT', 'the method of the target wins');
  assert.equal(b.httpRequestFor({ action: 'http', target: 'lt', method: 'patch' }, {}).method, 'PATCH');
  const refused = (target) => b.httpRequestFor({ action: 'http', target }, { workflow: 'w' }).refused;
  assert.equal(refused('nope'), 'unknown http target "nope": add it to "httpTargets" in bridge/config.json');
  assert.match(refused('constructor'), /^unknown http target "constructor"/);
  assert.match(refused('a\nb'), /^unknown http target "a b"/, 'no control character in the console');
  assert.equal(refused('unfilled'), 'fill "httpTargets" > "unfilled" in bridge/config.json first (it still holds a placeholder)');
  assert.match(refused('header_unfilled'), /^fill "httpTargets" > "header_unfilled"/);
  assert.equal(refused('outside'), 'host "evil.example" is not in httpAllowedHosts (bridge/config.json)');
  assert.equal(refused('broken'), '"httpTargets" > "broken" > "url" is not a valid URL');
});

await t('http step written in talky_config.json: hmacSecret refused, headers still sent with a warning once per workflow', async () => {
  const b = await bridgeIn(path.join(unitTmp, 'inline-http'), null, { httpAllowedHosts: ['*.liberty-talk.com'] });
  let res;
  let out = await captureLog(() => {
    res = b.httpRequestFor({ action: 'http', url: 'https://api.liberty-talk.com/x', hmacSecret: 'k', body: {} }, { workflow: 'w' });
  });
  assert.equal(res.refused, '"hmacSecret" written in the workflow: talky_config.json can be read by every mod running in the game. Put the address and the secret in "httpTargets" of bridge/config.json, and write "target": "<name>" in the step');
  assert.equal(out, '');
  out = await captureLog(() => {
    for (let i = 0; i < 3; i++) res = b.httpRequestFor({ action: 'http', url: 'https://api.liberty-talk.com/x', headers: { 'X-Webhook-Secret': 's' } }, { workflow: 'w' });
    b.httpRequestFor({ action: 'http', url: 'https://api.liberty-talk.com/x', headers: { a: 'b' } }, { workflow: 'other' });
    b.httpRequestFor({ action: 'http', url: 'https://api.liberty-talk.com/x', headers: {} }, { workflow: 'plain' });
    b.httpRequestFor({ action: 'http', url: 'https://api.liberty-talk.com/x' }, { workflow: 'plain' });
  });
  assert.deepEqual(res.headers, { 'X-Webhook-Secret': 's' }, 'still sent');
  assert.equal(res.url.href, 'https://api.liberty-talk.com/x');
  const lines = out.split('\n');
  assert.equal(lines.length, 2, out);
  assert.match(lines[0], /\[w\] warning: this http step has "headers" in talky_config\.json, a file every mod running in the game can read\. Move the address and its headers to "httpTargets" in bridge\/config\.json, and write "target": "<name>" in the step\./);
  assert.match(lines[1], /\[other\] warning: this http step has "headers"/);
  assert.equal(b.httpRequestFor({ action: 'http', url: 'https://evil.example/x' }, {}).refused, 'host "evil.example" is not in httpAllowedHosts (bridge/config.json)');
});

await t('config.json: httpTargets and hookTokens checked at start, their values never quoted', () => {
  const e1 = bridgeModule.httpTargetsError;
  const e2 = bridgeModule.hookTokensError;
  assert.equal(e1({}), null);
  assert.equal(e1({ 'lt_report.v-2': { url: 'https://a.liberty-talk.com/x', headers: { 'X-Webhook-Secret': 's' }, hmacSecret: 'k', hmacHeader: 'X-Sig', method: 'PUT' } }), null);
  for (const bad of [[], null, 'x']) assert.match(e1(bad), /^"httpTargets" in config\.json must be an object/);
  assert.match(e1({ 'bad name': { url: 'x' } }), /a target name is made of letters, digits/);
  assert.match(e1({ a: 'https://x' }), /^"httpTargets" > "a" in config\.json must be an object/);
  assert.match(e1({ a: {} }), /needs a "url"/);
  assert.match(e1({ a: { url: ' ' } }), /needs a "url"/);
  assert.match(e1({ a: { url: 'x', headers: [] } }), /"headers" must be an object of texts/);
  assert.match(e1({ a: { url: 'x', headers: { 'X-A': 5 } } }), /"headers" must be an object of texts/);
  assert.match(e1({ a: { url: 'x', headers: { 'bad header': 'v' } } }), /valid header names/);
  assert.match(e1({ a: { url: 'x', hmacSecret: 5 } }), /"hmacSecret" must be a text/);
  assert.match(e1({ a: { url: 'x', hmacHeader: 'a b' } }), /"hmacHeader" must be a header name/);
  assert.match(e1({ a: { url: 'x', method: 'GET /' } }), /"method" must be an http method/);
  assert.equal(e2({}), null);
  assert.equal(e2({ a: 'x'.repeat(16) }), null);
  for (const bad of [[], null, 'x']) assert.match(e2(bad), /^"hookTokens" in config\.json must be an object/);
  for (const bad of ['short-secret', 5, '', null, 'change-me-to-a-long-random-string']) {
    const msg = e2({ a: bad });
    assert.equal(msg, '"hookTokens" > "a" in config.json must be a long random text (16 characters or more).', String(bad));
  }
});

await t('seed: a webhook token of config.json is not copied to talky_config.json', async () => {
  const dir = path.join(unitTmp, 'seed-token');
  const secret = 'secret-0123456789abcdef';
  const b = new bridgeModule.Bridge({ token: 'x', zomboidLuaDir: dir, webhooks: { a: { workflow: 'w', token: secret } }, workflows: { w: { steps: [] } } });
  await captureLog(() => b.seedGameConfig());
  const text = fs.readFileSync(path.join(dir, 'talky_config.json'), 'utf8');
  assert.deepEqual(JSON.parse(text).webhooks, { a: { workflow: 'w' } });
  assert.ok(!text.includes(secret));
  assert.equal(b.base.webhooks.a.token, secret, 'config.json itself untouched');
});

await t('config.example.json: the LibertyTalk report goes through httpTargets, no secret in the workflows', async () => {
  const example = exampleConfig();
  assert.deepEqual(example.hookTokens, {});
  assert.equal(bridgeModule.httpTargetsError(example.httpTargets), null);
  assert.equal(bridgeModule.hookTokensError(example.hookTokens), null);
  assert.match(example.httpTargets.lt_report.url, /^https:\/\/api\.liberty-talk\.com\/webhooks\/workflow\/PASTE_/);
  assert.ok(example.httpTargets.lt_report.headers['X-Webhook-Secret']);
  const objects = (v) => (Array.isArray(v) ? v.flatMap(objects) : v && typeof v === 'object' ? [v, ...Object.values(v).flatMap(objects)] : []);
  for (const o of objects([example.workflows, example.webhooks, example.gameEvents])) {
    for (const k of ['headers', 'hmacSecret', 'url', 'token']) assert.equal(o[k], undefined, `"${k}" in a workflow or webhook of the example`);
  }
  const step = engine.expand(example.workflows.report_to_libertytalk.steps, engine.buildVars({ event: 'player_died' })).bridge[0];
  assert.equal(step.target, 'lt_report');
  const dir = path.join(unitTmp, 'example-target');
  const b = await bridgeIn(dir, null, { httpTargets: example.httpTargets, httpAllowedHosts: example.httpAllowedHosts });
  assert.equal(b.httpRequestFor(step, { workflow: 'report_to_libertytalk' }).refused, 'fill "httpTargets" > "lt_report" in bridge/config.json first (it still holds a placeholder)');
  const filled = { lt_report: { url: 'https://api.liberty-talk.com/webhooks/workflow/abc', headers: { 'X-Webhook-Secret': 's' } } };
  const ready = await bridgeIn(dir, null, { httpTargets: filled, httpAllowedHosts: example.httpAllowedHosts });
  const req = ready.httpRequestFor(step, { workflow: 'report_to_libertytalk' });
  assert.equal(req.url.href, 'https://api.liberty-talk.com/webhooks/workflow/abc');
  assert.deepEqual(req.headers, { 'X-Webhook-Secret': 's' });
});

await t('webhookUrl: public URL of the game file, dedicated token, masked form; no user:password, query or fragment', () => {
  const cfg = { port: 7420, token: 'main-token-0123456789', hookTokens: { b: 'dedicated-0123456789abcdef' }, webhooks: { seeded: {} } };
  const game = { publicUrl: 'https://abc.trycloudflare.com//', webhooks: { a: { workflow: 'w' }, b: { workflow: 'w' }, 'x y': { workflow: 'w' } } };
  const w = bridgeModule.webhookUrl;
  assert.equal(w(cfg, game, 'a').url, 'https://abc.trycloudflare.com/hooks/a?token=main-token-0123456789');
  assert.equal(w(cfg, game, 'a').masked, 'https://abc.trycloudflare.com/hooks/a?token=*****');
  assert.equal(w(cfg, game, 'a', { masked: true }).url, 'https://abc.trycloudflare.com/hooks/a?token=*****');
  assert.equal(w(cfg, game, 'a').from, 'talky_config.json');
  assert.equal(w(cfg, game, 'a').tokenName, '"token"');
  assert.equal(w(cfg, game, 'b').url, 'https://abc.trycloudflare.com/hooks/b?token=dedicated-0123456789abcdef');
  assert.equal(w(cfg, game, 'b').tokenName, '"hookTokens" > "b"');
  assert.equal(w(cfg, game, 'x y').url, 'https://abc.trycloudflare.com/hooks/x%20y?token=main-token-0123456789');
  assert.equal(w(cfg, game, 'a', { base: 'https://u:p@h.example:8443/p/?q=1#f' }).url, 'https://h.example:8443/p/hooks/a?token=main-token-0123456789');
  assert.equal(w({ ...cfg, publicUrl: 'https://cfg.example' }, {}, 'seeded').url, 'https://cfg.example/hooks/seeded?token=main-token-0123456789');
  assert.equal(w(cfg, {}, 'seeded').url, 'http://127.0.0.1:7420/hooks/seeded?token=main-token-0123456789', 'no game file: webhooks of config.json, local address');
  assert.equal(w(cfg, {}, 'seeded').from, 'local');
  assert.equal(w(cfg, game, 'seeded').error, 'Unknown webhook "seeded". Webhooks: a, b, x y');
  assert.match(w(cfg, game, 'constructor').error, /^Unknown webhook "constructor"/);
  assert.match(w(cfg, game, undefined).error, /^Usage: node bridge\.js url <webhook> \[--show\] \[--base <public URL>\]\. Webhooks: a, b, x y$/);
  assert.match(w(cfg, game, 'a', { base: 'nope' }).error, /^The public URL "nope" \(command line\) is not a URL/);
  assert.equal(w(cfg, game, 'a', { base: 'javascript:alert(1)' }).error, 'The public URL (command line) must start with https://.');
});

await t('jobTtl: missing = 900 s, above 900 s or not a number = 900 s with a warning (the mod drops a job 15 minutes after its creation)', () => {
  const { jobTtl, MAX_JOB_TTL_SECONDS } = bridgeModule;
  assert.equal(MAX_JOB_TTL_SECONDS, 900);
  assert.deepEqual(jobTtl(undefined), { seconds: 900 });
  assert.deepEqual(jobTtl(null), { seconds: 900 });
  assert.deepEqual(jobTtl(900), { seconds: 900 });
  assert.deepEqual(jobTtl(120), { seconds: 120 });
  assert.deepEqual(jobTtl('300'), { seconds: 300 }, 'a number written as text');
  const long = jobTtl(3600);
  assert.equal(long.seconds, 900);
  assert.equal(long.warning, '"jobTtlSeconds" in config.json is 3600: 900 is used. The game and the server drop a job 15 minutes after the bridge created it.');
  for (const bad of [0, -5, NaN, Infinity, 'abc', '1e9', true, {}, []]) {
    const r = jobTtl(bad);
    assert.equal(r.seconds, 900, String(bad));
    assert.match(r.warning, /^"jobTtlSeconds" in config\.json is not a number of seconds above 0: 900 is used\.$/, String(bad));
  }
});

await t('rotateToken: only the top-level "token" changes, even when another key holds the same text first', () => {
  const dir = path.join(unitTmp, 'rotate');
  fs.mkdirSync(dir, { recursive: true });
  const file = path.join(dir, 'config.json');
  fs.writeFileSync(file, '{\n  "webhooks": { "a": { "token": "same-0123456789abcdef" } },\n  "token": "same-0123456789abcdef"\n}\n');
  const token = bridgeModule.rotateToken(file);
  assert.match(token, /^[0-9a-f]{48}$/);
  const cfg = JSON.parse(fs.readFileSync(file, 'utf8'));
  assert.equal(cfg.token, token);
  assert.equal(cfg.webhooks.a.token, 'same-0123456789abcdef');
  // BOM (PowerShell), a quote in the old token: same layout
  fs.writeFileSync(file, '﻿{"port":1,"token":"a\\"b$&"}');
  const t2 = bridgeModule.rotateToken(file);
  assert.equal(fs.readFileSync(file, 'utf8'), `{"port":1,"token":"${t2}"}`);
  fs.writeFileSync(file, '{"port":1}');
  const t3 = bridgeModule.rotateToken(file);
  assert.deepEqual(JSON.parse(fs.readFileSync(file, 'utf8')), { port: 1, token: t3 }, 'no token yet: added');
  fs.writeFileSync(file, '[1]');
  assert.throws(() => bridgeModule.rotateToken(file), /not a JSON object/);
  assert.equal(fs.readFileSync(file, 'utf8'), '[1]', 'left as it was');
  assert.deepEqual(fs.readdirSync(dir), ['config.json'], 'no temporary file left');
});

await t('systemLanguage: fr for the fr locales, en for the others', () => {
  const s = bridgeModule.systemLanguage;
  for (const l of ['fr-FR', 'fr-CA', 'fr', 'FR-be', 'fr_FR']) assert.equal(s(l), 'fr', l);
  for (const l of ['en-US', 'de-DE', 'frr-DE', 'C', '', null]) assert.equal(s(l), 'en', String(l));
  assert.ok(['fr', 'en'].includes(s()), 'locale of this machine');
});

await t('newConfigText: token and language swapped in, the rest of config.example.json kept', () => {
  const exampleText = fs.readFileSync(path.join(bridgeDir, 'config.example.json'), 'utf8');
  const example = JSON.parse(exampleText);
  const token = 'ab'.repeat(24);
  const out = bridgeModule.newConfigText(exampleText, token, 'fr');
  const cfg = JSON.parse(out);
  assert.equal(cfg.token, token);
  assert.equal(cfg.settings.language, 'fr');
  assert.deepEqual({ ...cfg, token: example.token, settings: { ...cfg.settings, language: example.settings.language } }, example, 'nothing else changes');
  assert.equal(out.split('\n').length, exampleText.split('\n').length, 'layout of the example kept');
  assert.ok(!out.includes('change-me'));
  // An example without the placeholder nor the language line (and with a BOM): rebuilt
  const rebuilt = JSON.parse(bridgeModule.newConfigText('﻿{"port": 1, "settings": {"anonymousName": ""}}', token, 'en'));
  assert.deepEqual(rebuilt, { port: 1, token, settings: { anonymousName: '', language: 'en' } });
});

await t('createConfig: 48 hex characters, no BOM, an existing file is never replaced', () => {
  const dir = path.join(unitTmp, 'create');
  fs.mkdirSync(dir);
  const examplePath = path.join(bridgeDir, 'config.example.json');
  const target = path.join(dir, 'config.json');
  const made = bridgeModule.createConfig(target, examplePath, 'en');
  assert.match(made.token, /^[0-9a-f]{48}$/);
  const raw = fs.readFileSync(target);
  assert.equal(raw[0], 0x7b, 'starts with {, no BOM');
  assert.equal(JSON.parse(raw.toString('utf8')).token, made.token);
  assert.notEqual(bridgeModule.createConfig(path.join(dir, 'other.json'), examplePath, 'en').token, made.token, 'a new token each time');
  // config.json already there (created by hand, or by another bridge a moment before)
  fs.writeFileSync(target, '{"token":"mine"}');
  assert.equal(bridgeModule.createConfig(target, examplePath, 'fr'), null);
  assert.equal(fs.readFileSync(target, 'utf8'), '{"token":"mine"}');
  assert.deepEqual(fs.readdirSync(dir).sort(), ['config.json', 'other.json'], 'no temporary file left');
});

await t('startup warnings: cloudflared missing, Talky installed twice, bridge folder in Zomboid/mods', () => {
  const root = path.join(unitTmp, 'warn');
  const zomboid = path.join(root, 'Zomboid');
  const bin = path.join(root, 'bin');
  const steam = path.join(root, 'Steam');
  const library = path.join(root, 'SteamLibrary');
  fs.mkdirSync(path.join(zomboid, 'Lua'), { recursive: true });
  fs.mkdirSync(bin);
  const run = (opts = {}) => bridgeModule.startupWarnings({
    zomboidDir: zomboid, bridgeDirs: [path.join(root, 'Documents', 'Talky', 'bridge')],
    env: { PATH: bin }, platform: 'linux', steamRoots: [steam], ...opts,
  });
  let w = run();
  assert.equal(w.length, 1, w.join('\n'));
  assert.match(w[0], /^cloudflared is not in the PATH\..*"winget install --id Cloudflare\.cloudflared"/);
  assert.deepEqual(run({ needsTunnel: false }), [], 'the poll mode needs no tunnel');
  fs.writeFileSync(path.join(bin, 'cloudflared'), '');
  assert.deepEqual(run(), []);
  // Windows: cloudflared.exe found through PATHEXT (lower case here, so the result does not
  // depend on the case sensitivity of the test drive)
  const winBin = path.join(root, 'winbin');
  fs.mkdirSync(winBin);
  fs.writeFileSync(path.join(winBin, 'cloudflared.exe'), '');
  assert.equal(bridgeModule.findOnPath('cloudflared', { PATH: `"${winBin}"`, PATHEXT: '.com;.exe' }, 'win32'), path.join(winBin, 'cloudflared.exe'));
  assert.equal(bridgeModule.findOnPath('cloudflared', { PATH: winBin }, 'linux'), null);
  // A manual copy alone is fine (install without the Workshop)
  const manual = path.join(zomboid, 'mods', 'Talky');
  fs.mkdirSync(path.join(manual, '42'), { recursive: true });
  fs.writeFileSync(path.join(manual, '42', 'mod.info'), 'id=Talky\n');
  assert.deepEqual(run(), []);
  // ... but not with a Workshop copy, here in a second Steam library listed in libraryfolders.vdf
  fs.mkdirSync(path.join(steam, 'steamapps'), { recursive: true });
  fs.writeFileSync(path.join(steam, 'steamapps', 'libraryfolders.vdf'),
    `"libraryfolders"\n{\n\t"0"\n\t{\n\t\t"path"\t\t"${steam}"\n\t}\n\t"1"\n\t{\n\t\t"path"\t\t"${library}"\n\t}\n}\n`);
  assert.deepEqual(run(), []);
  const item = path.join(library, 'steamapps', 'workshop', 'content', '108600', '3141592653', 'mods', 'Talky');
  fs.mkdirSync(path.join(item, '42'), { recursive: true });
  assert.deepEqual(bridgeModule.workshopCopies([steam]), [item]);
  w = run();
  assert.equal(w.length, 1, w.join('\n'));
  assert.match(w[0], /^Talky is installed twice: .*Two mods with the id Talky confuse the game: delete the folder /);
  assert.ok(w[0].includes(bridgeModule.hideHome(item)), w[0]);
  // Bridge extracted into Zomboid/mods
  w = run({ bridgeDirs: [path.join(zomboid, 'mods', 'bridge')] });
  assert.equal(w.length, 2, w.join('\n'));
  assert.match(w[1], /^The bridge folder .* is inside .*mods, the folder of the game's mods: .*Documents\\Talky/);
  assert.equal(run({ bridgeDirs: [path.join(zomboid, 'mods-old', 'bridge')] }).length, 1, 'a sibling folder is not inside');
});

fs.rmSync(unitTmp, { recursive: true, force: true });

await t('normalizePath collapses repeated slashes', () => {
  const n = bridgeModule.normalizePath;
  assert.equal(n('//hooks/follow'), '/hooks/follow');
  assert.equal(n('/hooks//follow/'), '/hooks/follow');
  assert.equal(n('///hooks///follow?token=a//b'), '/hooks/follow?token=a//b');
  assert.equal(n('/'), '/');
  assert.equal(n(''), '/');
});

await t('httpAllowedHosts: exact hosts, *. jokers, ports', () => {
  const ok = (entry, url) => hosts.hostMatches(entry, new URL(url));
  assert.equal(ok('*.liberty-talk.com', 'https://api.liberty-talk.com/webhooks/workflow/x'), true);
  assert.equal(ok('*.liberty-talk.com', 'https://a.b.liberty-talk.com/'), true);
  assert.equal(ok('*.liberty-talk.com', 'https://API.Liberty-Talk.com./'), true);
  assert.equal(ok('*.liberty-talk.com', 'https://liberty-talk.com/'), false);
  assert.equal(ok('*.liberty-talk.com', 'https://evil-liberty-talk.com/'), false);
  assert.equal(ok('*.liberty-talk.com', 'https://liberty-talk.com.evil.com/'), false);
  assert.equal(ok('liberty-talk.com', 'https://liberty-talk.com/'), true);
  assert.equal(ok('127.0.0.1:8080', 'http://127.0.0.1:8080/x'), true);
  assert.equal(ok('127.0.0.1:8080', 'http://127.0.0.1:9090/x'), false);
  assert.equal(ok('example.com:443', 'https://example.com/'), true);
  assert.equal(ok('*', 'http://10.0.0.1/'), true);
  const def = (url) => hosts.checkHttpUrl(url, undefined).ok;
  assert.equal(def('https://api.liberty-talk.com/webhooks/workflow/abc'), true);
  assert.equal(def('http://127.0.0.1:7420/hooks/follow'), false);
  assert.equal(def('http://192.168.1.1/'), false);
  assert.equal(def('file:///etc/passwd'), false);
  assert.equal(def('data:text/plain,hello'), false);
  assert.equal(def('not a url'), false);
  assert.equal(hosts.checkHttpUrl('https://api.liberty-talk.com/', []).ok, false, 'an empty list allows nothing');
});

await t('activity feed items get the webhook field names (poll mode)', () => {
  const p = bridgeModule.activityToPayload;
  assert.equal(p({ type: 'cheer', actor_name: 'Bob', amount: 500 }).bits, 500);
  assert.equal(p({ type: 'raid', actor_name: 'Bob', amount: 12 }).viewers, 12);
  assert.equal(p({ type: 'subscribe_gift', actor_name: 'Bob', amount: 5 }).total, 5);
  assert.equal(p({ type: 'donation', actor_name: 'Bob', amount: 4.5, currency: 'EUR' }).formatted_amount, '4.5 EUR');
  assert.equal(p({ type: 'follow', actor_name: 'Bob' }).user_name, 'Bob');
});

await t('config.example.json and the French overlay stay in sync', () => {
  const example = JSON.parse(fs.readFileSync(path.join(bridgeDir, 'config.example.json'), 'utf8'));
  const overlay = examples.loadOverlay('fr');
  const entries = Object.entries(overlay).filter(([k]) => !k.startsWith('_'));
  assert.ok(entries.length > 10);
  for (const [dotPath, texts] of entries) {
    const found = examples.resolvePath(example, dotPath);
    assert.ok(found, `path missing in config.example.json: ${dotPath}`);
    assert.equal(found[0][found[1]], texts.en, `English text differs at ${dotPath}`);
    assert.equal(typeof texts.fr, 'string');
  }
  const copy = JSON.parse(JSON.stringify(example));
  assert.equal(examples.localizeExamples(copy, 'fr'), entries.length);
  assert.equal(copy.workflows.new_follower.steps[0].text, '{{user}} rejoint la horde !');
  assert.equal(examples.localizeExamples(JSON.parse(JSON.stringify(example)), 'en'), 0);
  // a text edited before the first run is kept
  const edited = JSON.parse(JSON.stringify(example));
  edited.workflows.new_follower.steps[0].text = 'custom';
  examples.localizeExamples(edited, 'fr');
  assert.equal(edited.workflows.new_follower.steps[0].text, 'custom');
});

await t('config.example.json defaults', () => {
  const example = JSON.parse(fs.readFileSync(path.join(bridgeDir, 'config.example.json'), 'utf8'));
  assert.deepEqual(example.httpAllowedHosts, ['*.liberty-talk.com']);
  assert.equal(example.host, '127.0.0.1');
  assert.equal(example.settings.language, 'en');
  assert.ok(example.poll.types.subscribe_gift);
  assert.ok(!example.poll.types.sub_gift);
  assert.ok(!example.poll.url.includes('/api/'));
  for (const wf of Object.values(example.workflows)) engine.expand(wf.steps, engine.buildVars({ bits: '500', viewers: '10', tier: '1000', total: '2' }));
});

// ------------------------------------------------------------------ bridge process

console.log('bridge process');

const tmpRoot = fs.mkdtempSync(path.join(tmpBase, 'talky-test-'));
const luaDir = path.join(tmpRoot, 'Lua');
fs.mkdirSync(luaDir, { recursive: true });

const port = await freePort();
const sinkPort = await freePort();
const TOKEN = 'test-token-0123456789abcdef0123456789abcdef';
const DEDICATED = 'dedicated-token-for-one-webhook-0123456789';
const PLANTED = 'token-planted-in-talky-config-by-a-mod-0123';

// Local server standing in for LibertyTalk's incoming webhook
const sinkHits = [];
const sink = http.createServer((req, res) => {
  let body = '';
  req.on('data', (c) => { body += c; });
  req.on('end', () => {
    sinkHits.push({ path: req.url, headers: req.headers, body });
    res.writeHead(202, { 'Content-Type': 'application/json' });
    res.end('{"ok":true}');
  });
});
await new Promise((r) => sink.listen(sinkPort, '127.0.0.1', r));

const configPath = path.join(tmpRoot, 'config.json');
fs.writeFileSync(configPath, JSON.stringify({
  port,
  token: TOKEN,
  zomboidLuaDir: luaDir,
  jobTtlSeconds: 900,
  httpAllowedHosts: ['*.liberty-talk.com', `127.0.0.1:${sinkPort}`],
  hookTokens: { secret: DEDICATED },
  httpTargets: {
    sink: { url: `http://127.0.0.1:${sinkPort}/target/hidden-path-7f3a`, headers: { 'X-Webhook-Secret': 'from-config' }, hmacSecret: 'hmac-key', hmacHeader: 'X-Talky-Signature' },
    outside: { url: `http://localhost:${sinkPort}/hidden-path-9b2c` },
  },
}, null, 2));

// talky_config.json already exists, as after a first run. Its own "httpAllowedHosts"
// (written by a hostile mod, say) must be ignored.
const gameConfigPath = path.join(luaDir, 'talky_config.json');
const outboxPath = path.join(luaDir, 'talky_outbox.txt');
const legacyOutboxPath = path.join(luaDir, 'talky_outbox.jsonl'); // mod 0.3.0
const statusOf = (dir) => waitFor(() => JSON.parse(fs.readFileSync(path.join(dir, 'talky_status.json'), 'utf8')), 3000, 'talky_status.json');
const gameConfig = {
  httpAllowedHosts: ['*'],
  // ... and so must "httpTargets" and "hookTokens" (only config.json counts)
  httpTargets: { sink: { url: `http://127.0.0.1:${sinkPort}/planted-target` } },
  hookTokens: { follow: PLANTED },
  publicUrl: 'https://abc.trycloudflare.com/',
  settings: { language: 'fr' },
  webhooks: {
    follow: { workflow: 'new_follower' },
    secret: { workflow: 'new_follower' },
    planted: { workflow: 'new_follower', token: PLANTED },
    bits: { workflow: 'bits_wf' },
    caps: { workflow: 'caps_wf' },
    http_ok: { workflow: 'http_ok' },
    http_bad: { workflow: 'http_bad' },
    http_target: { workflow: 'http_target' },
    http_hmac: { workflow: 'http_hmac' },
    http_outside: { workflow: 'http_outside' },
  },
  workflows: {
    new_follower: { steps: [{ action: 'notify', text: '{{user}} joins' }, { action: 'spawn_zombie', name: '{{user}}' }] },
    bits_wf: {
      when: { bits: { gte: 100 } },
      steps: [
        { action: 'spawn_zombie', name: '{{user}}', count: '{{bits | div:100}}' },
        { action: 'emit', event: 'types', data: { bits: '{{bits}}', viewers: '{{viewers}}', total: '{{total}}', amount: '{{amount}}', tier: '{{tier}}' } },
      ],
    },
    caps_wf: {
      steps: [
        { action: 'wait', seconds: 3600 },
        { action: 'notify', text: 'n'.repeat(400), seconds: 500 },
        { action: 'say', text: 's'.repeat(400) },
        { action: 'halo', text: 'h'.repeat(400) },
      ],
    },
    http_ok: {
      steps: [
        { action: 'http', url: `http://127.0.0.1:${sinkPort}/ok`, headers: { 'X-Webhook-Secret': 's3cret' }, body: { name: '{{user}}' } },
        { action: 'notify', text: 'sent' },
      ],
    },
    http_bad: {
      steps: [
        { action: 'http', url: `http://localhost:${sinkPort}/blocked`, body: { stolen: '{{user}}' } },
        { action: 'notify', text: 'still runs' },
      ],
    },
    // A step written by a mod cannot redirect a target, nor add its own secret header
    http_target: {
      steps: [{ action: 'http', target: 'sink', url: `http://127.0.0.1:${sinkPort}/from-step`, headers: { 'X-Webhook-Secret': 'from-mod' }, body: { name: '{{user}}' } }],
    },
    http_hmac: {
      steps: [
        { action: 'http', url: `http://127.0.0.1:${sinkPort}/inline-hmac`, hmacSecret: 'mod-secret-0123', body: { x: 1 } },
        { action: 'notify', text: 'still runs' },
      ],
    },
    http_outside: { steps: [{ action: 'http', target: 'outside', body: {} }] },
    on_kill: { steps: [{ action: 'notify', text: '{{name}} is down' }] },
    broken_wf: { steps: [{ action: 'notify', text: '{{hoursSurvived | nope}}' }] },
  },
  gameEvents: { zombie_killed: 'on_kill', player_died: 'broken_wf' },
};
fs.writeFileSync(gameConfigPath, JSON.stringify(gameConfig, null, 2));

const bridge = startBridge(configPath);
const auth = { 'X-Bridge-Token': TOKEN, 'Content-Type': 'application/json' };
let firstNonce; // testNonce of this bridge, compared with the next one started

try {
  await t('bridge starts', async () => {
    // Last line printed once listening (stdout may come in several pieces)
    await waitFor(() => bridge.out.includes('http steps allowed to'), 8000, 'bridge start');
    assert.match(bridge.out, /Talky bridge 0\.4\.0 listening on http:\/\/127\.0\.0\.1:\d+/);
    assert.match(bridge.out, /http steps allowed to: \*\.liberty-talk\.com, 127\.0\.0\.1:\d+/);
  });

  await t('GET /health: nothing without token, details with token', async () => {
    const anon = await request(port, 'GET', '/health');
    assert.equal(anon.status, 200);
    assert.deepEqual(anon.json, { ok: true });
    const full = await request(port, 'GET', `/health?token=${TOKEN}`);
    assert.equal(full.json.version, '0.4.0');
    assert.equal(full.json.protocol, 2);
    assert.equal(typeof full.json.pending, 'number');
    assert.deepEqual(full.json.ackedAbove, []);
    assert.equal(full.json.testNonce, undefined, 'the test code stays in talky_status.json');
  });

  await t('authentication: 401 without token, with a bad token', async () => {
    assert.equal((await request(port, 'POST', '/hooks/follow', { body: {} })).status, 401);
    assert.equal((await request(port, 'POST', '/hooks/follow', { headers: { 'X-Bridge-Token': 'nope' }, body: {} })).status, 401);
    assert.equal((await request(port, 'POST', '/hooks/follow?token=nope', { body: {} })).status, 401);
  });

  await t('unknown webhook: 401 without token (no enumeration), 404 after authentication', async () => {
    const anon = await request(port, 'POST', '/hooks/does-not-exist', { body: {} });
    assert.equal(anon.status, 401);
    const authed = await request(port, 'POST', '/hooks/does-not-exist', { headers: auth, body: {} });
    assert.equal(authed.status, 404);
    assert.match(authed.json.error, /unknown webhook/);
    const proto = await request(port, 'POST', '/hooks/constructor', { headers: auth, body: {} });
    assert.equal(proto.status, 404, 'Object prototype names are not webhooks');
  });

  await t('other routes: 404', async () => {
    assert.equal((await request(port, 'GET', '/hooks/follow', { headers: auth })).status, 404);
    assert.equal((await request(port, 'POST', '/hooks/follow/extra', { headers: auth, body: {} })).status, 404);
    assert.equal((await request(port, 'POST', '/nothing', { headers: auth, body: {} })).status, 404);
  });

  await t('valid token in header or query string: 200 and a job', async () => {
    const r1 = await request(port, 'POST', '/hooks/follow', { headers: auth, body: { user_name: 'Alice' } });
    assert.equal(r1.status, 200);
    assert.equal(typeof r1.json.results[0].job, 'number');
    const r2 = await request(port, 'POST', `/hooks/follow?token=${TOKEN}`, { headers: { 'Content-Type': 'application/json' }, body: { user_name: 'Bea' } });
    assert.equal(r2.status, 200);
    assert.equal(typeof r2.json.results[0].job, 'number');
  });

  await t('double slash: //hooks/follow and /hooks//follow/ reach the webhook', async () => {
    const r1 = await request(port, 'POST', '//hooks/follow', { headers: auth, body: { user_name: 'Slash1' } });
    assert.equal(r1.status, 200);
    assert.equal(r1.json.results[0].workflow, 'new_follower');
    const r2 = await request(port, 'POST', '/hooks//follow/', { headers: auth, body: { user_name: 'Slash2' } });
    assert.equal(r2.status, 200);
  });

  await t('dedicated webhook token (hookTokens of config.json): the global token is refused, the dedicated one works', async () => {
    assert.equal((await request(port, 'POST', '/hooks/secret', { headers: auth, body: {} })).status, 401);
    const ok = await request(port, 'POST', '/hooks/secret', { headers: { 'X-Bridge-Token': DEDICATED }, body: { user_name: 'Ded' } });
    assert.equal(ok.status, 200);
    assert.equal((await request(port, 'POST', `/hooks/secret?token=${DEDICATED}`, { body: {} })).status, 200);
    assert.equal((await request(port, 'POST', '/fire/new_follower', { headers: { 'X-Bridge-Token': DEDICATED }, body: {} })).status, 401, 'only its webhook');
    assert.equal((await request(port, 'POST', '/hooks/follow', { headers: { 'X-Bridge-Token': DEDICATED }, body: {} })).status, 401);
    assert.match(bridge.out, /webhook {2}POST \/hooks\/secret {2}\(dedicated token\)/);
    assert.ok(!bridge.out.includes(DEDICATED), 'never printed');
  });

  await t('tokens written in talky_config.json (webhook "token", "hookTokens") open nothing; one warning', async () => {
    for (const hookPath of ['/hooks/planted', '/hooks/follow', '/fire/new_follower']) {
      assert.equal((await request(port, 'POST', hookPath, { headers: { 'X-Bridge-Token': PLANTED }, body: {} })).status, 401, hookPath);
      assert.equal((await request(port, 'POST', `${hookPath}?token=${PLANTED}`, { body: {} })).status, 401, hookPath);
    }
    const ok = await request(port, 'POST', '/hooks/planted', { headers: auth, body: { user_name: 'Pl' } });
    assert.equal(ok.status, 200, 'the bridge token works for it');
    assert.match(bridge.out, /warning: the "token" of webhook "planted" in talky_config\.json is ignored: every mod running in the game can write that file\./);
    assert.ok(!bridge.out.includes(PLANTED), 'never printed');
  });

  await t('POST /fire/<workflow> with the global token', async () => {
    const r = await request(port, 'POST', '/fire/new_follower', { headers: auth, body: { user: 'Fired' } });
    assert.equal(r.status, 200);
    assert.equal(r.json.results[0].workflow, 'new_follower');
  });

  await t('numeric fields sent as strings become numbers before conditions and filters', async () => {
    const r = await request(port, 'POST', '/hooks/bits', {
      headers: auth,
      body: '{"user_name":"Bob","bits":"500","viewers":"12","total":"3","amount":"4.50","tier":"1000"}',
    });
    assert.equal(r.status, 200);
    const seq = r.json.results[0].job;
    assert.equal(typeof seq, 'number', JSON.stringify(r.json));
    const job = await waitFor(() => readJobs(luaDir).find((j) => j.seq === seq), 3000, 'bits job in inbox');
    assert.equal(job.steps[0].count, 5);
    const data = job.steps[1].data;
    assert.deepEqual(data, { bits: 500, viewers: 12, total: 3, amount: 4.5, tier: 1000 });
    const low = await request(port, 'POST', '/hooks/bits', { headers: auth, body: '{"user_name":"Bob","bits":"50"}' });
    assert.equal(low.json.results[0].skipped, 'condition');
  });

  await t('anonymous name follows settings.language (fr -> Anonyme)', async () => {
    const r = await request(port, 'POST', '/hooks/bits', { headers: auth, body: '{"bits":"300"}' });
    const seq = r.json.results[0].job;
    const job = await waitFor(() => readJobs(luaDir).find((j) => j.seq === seq), 3000, 'anonymous job');
    assert.equal(job.user, 'Anonyme');
    assert.equal(job.steps[0].name, 'Anonyme');
  });

  await t('broken JSON from LibertyTalk (unescaped quote) is still read', async () => {
    const r = await request(port, 'POST', '/hooks/bits', { headers: auth, body: '{"user_name":"Bo"b","bits":"200"}' });
    assert.equal(r.status, 200);
    assert.equal(typeof r.json.results[0].job, 'number');
  });

  await t('caps reach the inbox: wait 600 s, texts 200 characters, banner 60 s', async () => {
    const r = await request(port, 'POST', '/hooks/caps', { headers: auth, body: {} });
    const seq = r.json.results[0].job;
    const job = await waitFor(() => readJobs(luaDir).find((j) => j.seq === seq), 3000, 'caps job');
    assert.equal(job.steps[0].seconds, 600);
    assert.equal(job.steps[1].text.length, 200);
    assert.equal(job.steps[1].seconds, 60);
    assert.equal(job.steps[2].text.length, 200);
    assert.equal(job.steps[3].text.length, 200);
  });

  await t('http step to an allowed host is sent', async () => {
    const r = await request(port, 'POST', '/hooks/http_ok', { headers: auth, body: { user_name: 'Carl' } });
    assert.equal(r.status, 200);
    const hit = await waitFor(() => sinkHits.find((h) => h.path === '/ok'), 4000, 'sink /ok');
    assert.equal(hit.headers['x-webhook-secret'], 's3cret');
    assert.deepEqual(JSON.parse(hit.body), { name: 'Carl' });
    assert.match(bridge.out, /\[http_ok\] warning: this http step has "headers" in talky_config\.json, a file every mod running in the game can read\./);
    await request(port, 'POST', '/hooks/http_ok', { headers: auth, body: { user_name: 'Carl2' } });
    await waitFor(() => sinkHits.filter((h) => h.path === '/ok').length === 2, 4000, 'second /ok');
    assert.equal(bridge.out.match(/\[http_ok\] warning: this http step has "headers"/g).length, 1, 'warned once');
  });

  await t('http step with "target": address, headers and HMAC from httpTargets of config.json; the url and headers of the step ignored', async () => {
    const r = await request(port, 'POST', '/hooks/http_target', { headers: auth, body: { user_name: 'Tia' } });
    assert.equal(r.status, 200);
    const hit = await waitFor(() => sinkHits.find((h) => h.path === '/target/hidden-path-7f3a'), 4000, 'sink target');
    assert.equal(hit.headers['x-webhook-secret'], 'from-config');
    assert.equal(hit.body, JSON.stringify({ name: 'Tia' }));
    assert.equal(hit.headers['x-talky-signature'], crypto.createHmac('sha256', 'hmac-key').update(hit.body).digest('hex'));
    await sleep(200);
    assert.equal(sinkHits.filter((h) => h.path === '/from-step' || h.path === '/planted-target').length, 0);
    assert.match(bridge.out, /\[http_target\] http step: "url", "headers" ignored, the step has a "target"/);
    assert.match(bridge.out, /http targets: sink \(127\.0\.0\.1:\d+\), outside \(localhost:\d+\)/);
    assert.ok(!bridge.out.includes('hidden-path') && !bridge.out.includes('hmac-key') && !bridge.out.includes('from-config'), 'no path or secret of a target in the console');
  });

  await t('http step: hmacSecret written in talky_config.json refused; a target outside httpAllowedHosts refused without its path', async () => {
    const r = await request(port, 'POST', '/hooks/http_hmac', { headers: auth, body: {} });
    assert.equal(typeof r.json.results[0].job, 'number', 'the game steps still run');
    await waitFor(() => bridge.out.includes('[http_hmac] http step refused: "hmacSecret" written in the workflow'), 3000, 'hmac refusal');
    await request(port, 'POST', '/hooks/http_outside', { headers: auth, body: {} });
    await waitFor(() => /\[http_outside\] http step refused: host "localhost:\d+" is not in httpAllowedHosts/.test(bridge.out), 3000, 'target refusal');
    await sleep(200);
    assert.equal(sinkHits.filter((h) => h.path === '/inline-hmac' || h.path.includes('hidden-path-9b2c')).length, 0);
    assert.ok(!bridge.out.includes('hidden-path') && !bridge.out.includes('mod-secret-0123'));
    const health = await request(port, 'GET', `/health?token=${TOKEN}`);
    assert.ok(health.json.recent.some((e) => e.workflow === 'http_hmac' && /^http refused: "hmacSecret"/.test(e.error || '')));
  });

  await t('http step to a host outside httpAllowedHosts is refused and logged', async () => {
    const r = await request(port, 'POST', '/hooks/http_bad', { headers: auth, body: { user_name: 'Eve' } });
    assert.equal(r.status, 200);
    assert.equal(typeof r.json.results[0].job, 'number', 'the game steps still run');
    await waitFor(() => bridge.out.includes('http step refused'), 3000, 'refusal log');
    assert.match(bridge.out, /http step refused: host "localhost:\d+" is not in httpAllowedHosts/);
    await sleep(300);
    assert.equal(sinkHits.filter((h) => h.path === '/blocked').length, 0);
    const health = await request(port, 'GET', `/health?token=${TOKEN}`);
    assert.ok(health.json.recent.some((e) => e.workflow === 'http_bad' && /http refused/.test(e.error || '')));
  });

  await t('body over 64 KB: 413 (counted in bytes)', async () => {
    const r = await request(port, 'POST', '/hooks/follow', { headers: auth, body: JSON.stringify({ x: 'y'.repeat(70000) }) });
    assert.equal(r.status, 413);
    // 40 000 characters, 80 000 bytes
    const accents = await request(port, 'POST', '/hooks/follow', { headers: auth, body: JSON.stringify({ x: 'é'.repeat(40000) }) });
    assert.equal(accents.status, 413);
  });

  await t('UTF-8 character split between two chunks of the body stays whole', async () => {
    const body = Buffer.from('{"user_name":"Zoé"}', 'utf8');
    const cut = body.indexOf(0xc3) + 1; // between the two bytes of "é"
    const r = await requestInChunks(port, '/hooks/follow', auth, [body.subarray(0, cut), body.subarray(cut)]);
    assert.equal(r.status, 200, r.text);
    const seq = r.json.results[0].job;
    const job = await waitFor(() => readJobs(luaDir).find((j) => j.seq === seq), 3000, 'Zoé job');
    assert.equal(job.user, 'Zoé');
    assert.equal(job.steps[0].text, 'Zoé joins');
    assert.equal(job.steps[1].name, 'Zoé');
  });

  await t('inbox file: one JSON job per line, increasing seq, expiry set', async () => {
    const jobs = readJobs(luaDir);
    assert.ok(jobs.length >= 8, `only ${jobs.length} job(s)`);
    for (let i = 1; i < jobs.length; i++) assert.ok(jobs[i].seq > jobs[i - 1].seq);
    for (const j of jobs) {
      assert.ok(Array.isArray(j.steps) && j.steps.length > 0);
      assert.ok(j.expiresAt > j.createdAt);
      assert.equal(typeof j.workflow, 'string');
    }
  });

  await t('ack file: acknowledged jobs leave the inbox', async () => {
    const jobs = readJobs(luaDir);
    fs.writeFileSync(path.join(luaDir, 'talky_ack.txt'), String(jobs[jobs.length - 1].seq));
    await waitFor(() => readJobs(luaDir).length === 0, 3000, 'empty inbox');
  });

  await t('ack file "S s1 s2": jobs answered out of order leave the inbox, the one still waiting stays', async () => {
    const seqs = [];
    for (const name of ['Ack1', 'Ack2', 'Ack3']) {
      const r = await request(port, 'POST', '/hooks/follow', { headers: auth, body: { user_name: name } });
      seqs.push(r.json.results[0].job);
    }
    await waitFor(() => readJobs(luaDir).length === 3, 3000, 'three jobs');
    // The server answered #1 and #3, not #2 yet
    fs.writeFileSync(path.join(luaDir, 'talky_ack.txt'), `${seqs[0]} ${seqs[2]}\n`);
    await waitFor(() => readJobs(luaDir).length === 1, 3000, 'only the job still waiting');
    assert.equal(readJobs(luaDir)[0].seq, seqs[1]);
    const health = await request(port, 'GET', `/health?token=${TOKEN}`);
    assert.equal(health.json.lastAck, seqs[0]);
    assert.deepEqual(health.json.ackedAbove, [seqs[2]]);
    assert.match(bridge.out, new RegExp(`game accepted the jobs up to #${seqs[0]}, and #${seqs[2]}`));
    fs.writeFileSync(path.join(luaDir, 'talky_ack.txt'), `${seqs[2]}\n`);
    await waitFor(() => readJobs(luaDir).length === 0, 3000, 'empty inbox');
  });

  await t('outbox file talky_outbox.txt: a game event runs its workflow', async () => {
    fs.writeFileSync(outboxPath, `${JSON.stringify({ event: 'zombie_killed', data: { name: 'Bob', byPlayer: true }, ts: Date.now() })}\n`);
    const job = await waitFor(() => readJobs(luaDir).find((j) => j.workflow === 'on_kill'), 3000, 'on_kill job');
    assert.equal(job.steps[0].text, 'Bob is down');
    assert.equal(fs.existsSync(outboxPath), false);
  });

  await t('outbox file talky_outbox.jsonl (mod 0.3.0) is still read', async () => {
    fs.writeFileSync(legacyOutboxPath, `${JSON.stringify({ event: 'zombie_killed', data: { name: 'Old', byPlayer: false }, ts: Date.now() })}\n`);
    const job = await waitFor(() => readJobs(luaDir).find((j) => j.workflow === 'on_kill' && j.steps[0].text === 'Old is down'), 3000, 'on_kill job (legacy outbox)');
    assert.ok(job);
    assert.equal(fs.existsSync(legacyOutboxPath), false);
  });

  // What the F8 window does: it reads testNonce from talky_status.json and sends it back
  const testEvent = async (workflow, vars) => {
    const { testNonce } = await statusOf(luaDir);
    return JSON.stringify({ event: 'test_workflow', data: { workflow, vars, nonce: testNonce } });
  };

  await t('Test now right after a save: the bridge runs the version just written', async () => {
    // Same order as the window: talky_config.json, then the outbox line, in the same millisecond
    gameConfig.workflows.fresh_wf = { steps: [{ action: 'notify', text: 'fresh {{user}}' }] };
    const line = await testEvent('fresh_wf', { user: 'Tess' });
    fs.writeFileSync(gameConfigPath, JSON.stringify(gameConfig, null, 2));
    fs.writeFileSync(outboxPath, `${line}\n`);
    const job = await waitFor(() => readJobs(luaDir).find((j) => j.workflow === 'fresh_wf'), 3000, 'fresh_wf job');
    assert.equal(job.steps[0].text, 'fresh Tess');
    // A modified workflow runs in its new version
    gameConfig.workflows.fresh_wf.steps[0].text = 'v2 {{user}}';
    fs.writeFileSync(gameConfigPath, JSON.stringify(gameConfig, null, 2));
    fs.writeFileSync(outboxPath, `${line}\n`);
    const job2 = await waitFor(() => readJobs(luaDir).find((j) => j.workflow === 'fresh_wf' && j.seq > job.seq), 3000, 'fresh_wf v2 job');
    assert.equal(job2.steps[0].text, 'v2 Tess');
  });

  await t('Test now without the test code (mod 0.3.0) or with another one: refused, the message says to update the mod, "skipped" for the window', async () => {
    const before = readJobs(luaDir).length;
    fs.writeFileSync(outboxPath, `${[
      { event: 'test_workflow', data: { workflow: 'fresh_wf', vars: { user: 'NoCode' } } },
      { event: 'test_workflow', data: { workflow: 'fresh_wf', vars: { user: 'NoCode' } } },
      { event: 'test_workflow', data: { workflow: 'fresh_wf', vars: { user: 'Forged' }, nonce: 'f'.repeat(32) } },
    ].map((e) => JSON.stringify(e)).join('\n')}\n`);
    await waitFor(() => /test code is not the one of this bridge/.test(bridge.out), 3000, 'refusal log');
    assert.match(bridge.out, /\[test\] "Test now" refused: it carries no test code\. Talky mods older than 0\.4\.0 do not send it: update the mod/);
    assert.equal(bridge.out.match(/carries no test code/g).length, 1, 'logged once');
    await sleep(300);
    assert.equal(readJobs(luaDir).length, before, 'no job');
    assert.ok(!readJobs(luaDir).some((j) => j.user === 'NoCode' || j.user === 'Forged'));
    // Shown on the F8 Status page (talky_status.json is written every 2 s)
    const st = await waitFor(async () => {
      const s = await statusOf(luaDir);
      return s.recent.some((e) => e.source === 'test' && e.error === 'Test now refused: update the Talky mod to 0.4.0') && s;
    }, 4000, 'refusal in talky_status.json');
    const entries = st.recent.filter((e) => e.source === 'test' && e.error);
    assert.deepEqual(entries.map((e) => e.skipped).sort(), ['no test code', 'test code mismatch']);
  });

  await t('a game workflow that fails does not lose the other events of the batch', async () => {
    fs.writeFileSync(outboxPath, `${[
      JSON.stringify({ event: 'player_died', data: { hoursSurvived: 3 } }), // broken_wf: unknown filter
      await testEvent('broken_wf', { user: 'Tess' }),
      JSON.stringify({ event: 'zombie_killed', data: { name: 'Kim', byPlayer: true } }),
    ].join('\n')}\n`);
    await waitFor(() => readJobs(luaDir).find((j) => j.workflow === 'on_kill' && j.steps[0].text === 'Kim is down'), 3000, 'on_kill after a failure');
    assert.match(bridge.out, /\[game:player_died\] broken_wf failed: unknown filter "nope"/);
    assert.match(bridge.out, /\[test\] broken_wf failed: unknown filter "nope"/);
    const health = await request(port, 'GET', `/health?token=${TOKEN}`);
    const errors = health.json.recent.filter((e) => e.workflow === 'broken_wf' && /unknown filter/.test(e.error || ''));
    assert.deepEqual(errors.map((e) => e.source).sort(), ['game:player_died', 'test'], 'shown on the F8 Status page');
  });

  await t('job_rejected from the game: console line and F8 Status entry', async () => {
    const r = await request(port, 'POST', '/hooks/follow', { headers: auth, body: { user_name: 'Refused' } });
    const seq = r.json.results[0].job;
    // The mod acknowledges a job refused for good, then reports it
    fs.writeFileSync(path.join(luaDir, 'talky_ack.txt'), `${seq}\n`);
    fs.writeFileSync(outboxPath, `${JSON.stringify({ event: 'job_rejected', data: { seq, workflow: 'new_follower', reason: 'not_allowed' } })}\n`);
    await waitFor(() => bridge.out.includes(`job #${seq} (new_follower) refused by the server: not_allowed`), 3000, 'job_rejected log');
    assert.match(bridge.out, /refused by the server: not_allowed - this player may not use Talky on this server\. .*Talky\.AllowedPlayers/);
    const status = await waitFor(async () => {
      const st = await statusOf(luaDir);
      return st.recent.find((e) => e.source === 'game:job_rejected') && st;
    }, 4000, 'job_rejected in talky_status.json');
    const entry = status.recent.find((e) => e.source === 'game:job_rejected');
    assert.equal(entry.job, seq);
    assert.equal(entry.workflow, 'new_follower');
    assert.equal(entry.user, 'Refused');
    assert.equal(entry.rejected, 'not_allowed');
    assert.equal(entry.error, 'refused by the server: not_allowed');
    assert.ok(!readJobs(luaDir).some((j) => j.seq === seq), 'acknowledged, so gone from the inbox');
  });

  await t('status file for the in-game window: version, protocol 2, testNonce, session', async () => {
    const status = await statusOf(luaDir);
    assert.equal(status.version, '0.4.0');
    assert.equal(status.protocol, 2);
    assert.match(status.testNonce, /^[0-9a-f]{32}$/);
    assert.equal(status.session, JSON.parse(fs.readFileSync(path.join(tmpRoot, 'bridge-state.json'), 'utf8')).session);
    assert.match(status.session, /^[0-9a-f]{16}$/);
    assert.equal(status.port, port);
    assert.ok(status.webhooks.includes('follow'));
    assert.equal(status.token, undefined, 'no token: every mod running in the game can read this file');
    assert.deepEqual(status.hookTokens, ['secret'], 'ids only');
    const text = fs.readFileSync(path.join(luaDir, 'talky_status.json'), 'utf8');
    for (const secret of [TOKEN, DEDICATED, 'hmac-key', 'from-config', 'hidden-path']) assert.ok(!text.includes(secret), secret);
    firstNonce = status.testNonce;
  });

  await t('a bridge that exits (port taken) leaves a talky_status.json without test code, offline (ts 0)', async () => {
    const dir = path.join(tmpRoot, 'busy');
    const busyConfig = path.join(dir, 'config.json'); // its own bridge-state.json
    fs.mkdirSync(dir, { recursive: true });
    fs.writeFileSync(busyConfig, JSON.stringify({ port, token: TOKEN, zomboidLuaDir: path.join(dir, 'Lua') }));
    const r = await runBridgeToExit({ LT_BRIDGE_CONFIG: busyConfig });
    assert.equal(r.code, 1, r.out);
    assert.match(r.out, /Port \d+ is already used/);
    const st = JSON.parse(fs.readFileSync(path.join(dir, 'Lua', 'talky_status.json'), 'utf8'));
    assert.equal(st.stopped, true);
    assert.equal(st.ts, 0);
    assert.equal(st.testNonce, undefined);
    assert.equal(st.token, undefined);
  });

  await t('state file next to config.json, not in the bridge folder', () => {
    assert.ok(fs.existsSync(path.join(tmpRoot, 'bridge-state.json')));
  });
} finally {
  await stopBridge(bridge);
}

// ------------------------------------------------------------------ first run

console.log('first run');

const lua2 = path.join(tmpRoot, 'Lua2');
const port2 = await freePort();
const config2 = path.join(tmpRoot, 'config-first-run.json');
const example = JSON.parse(fs.readFileSync(path.join(bridgeDir, 'config.example.json'), 'utf8'));
example.token = TOKEN;
example.port = port2;
example.zomboidLuaDir = lua2;
example.settings.language = 'fr';
fs.writeFileSync(config2, `﻿${JSON.stringify(example, null, 2)}`); // with a BOM, like PowerShell 5.1
const bridge2 = startBridge(config2);
try {
  await t('first run: talky_config.json created from config.json, examples in French', async () => {
    await waitFor(() => bridge2.out.includes('listening on'), 8000, 'bridge 2 start');
    const game = JSON.parse(fs.readFileSync(path.join(lua2, 'talky_config.json'), 'utf8'));
    assert.equal(game.workflows.new_follower.steps[0].text, '{{user}} rejoint la horde !');
    assert.equal(game.webhooks.points.routes[0].when.reward_title.contains, 'hélico');
    assert.equal(game.settings.language, 'fr');
    assert.equal(game.httpAllowedHosts, undefined, 'the host list stays in config.json');
    assert.equal(game.token, undefined, 'the token stays in config.json');
    assert.equal(game.httpTargets, undefined, 'the http targets stay in config.json');
    assert.equal(game.hookTokens, undefined);
    assert.ok(!fs.readFileSync(path.join(lua2, 'talky_config.json'), 'utf8').includes('PASTE_THE_SECRET'), 'no http secret in the game folder');
    assert.deepEqual(game.workflows.report_to_libertytalk.steps[0].target, 'lt_report');
    assert.match(bridge2.out, /fr: \d+ text\(s\) translated/);
    await waitFor(() => bridge2.out.includes('http targets:'), 3000, 'http targets line');
    assert.match(bridge2.out, /http targets: lt_report \(not filled in\)/);
  });

  await t('another start, another testNonce', async () => {
    const status = await statusOf(lua2);
    assert.match(status.testNonce, /^[0-9a-f]{32}$/);
    assert.ok(firstNonce, 'nonce of the first bridge read');
    assert.notEqual(status.testNonce, firstNonce);
  });

  await t('first run: the example workflow "new_follower" answers on /hooks/follow', async () => {
    const r = await request(port2, 'POST', '/hooks/follow', { headers: auth, body: { user_name: 'Zed' } });
    assert.equal(r.status, 200);
    const seq = r.json.results[0].job;
    const job = await waitFor(() => readJobs(lua2).find((j) => j.seq === seq), 3000, 'example job');
    assert.equal(job.steps[0].text, 'Zed rejoint la horde !');
    assert.equal(job.steps[1].action, 'wait');
  });
} finally {
  await stopBridge(bridge2);
}

await t('CLI: node bridge.js version', async () => {
  const child = spawn(process.execPath, [bridgeJs, 'version'], { stdio: ['ignore', 'pipe', 'pipe'] });
  let out = '';
  child.stdout.on('data', (c) => { out += c; });
  await new Promise((r) => child.once('exit', r));
  assert.equal(out.trim(), '0.4.0');
});

// The config.json and talky_config.json of the "bridge process" tests (public URL
// https://abc.trycloudflare.com/, hookTokens { secret }); no clipboard (TALKY_NO_CLIPBOARD).
await t('CLI url: the full URL of a webhook only with --show, else masked; dedicated token, --base, unknown webhook', async () => {
  const env = { LT_BRIDGE_CONFIG: configPath };
  let r = await runBridgeToExit(env, ['url', 'follow', '--show']);
  assert.equal(r.code, 0, r.out);
  assert.equal(r.out.trim(), `https://abc.trycloudflare.com/hooks/follow?token=${TOKEN}`);
  r = await runBridgeToExit(env, ['url', 'secret', '--show']);
  assert.equal(r.out.trim(), `https://abc.trycloudflare.com/hooks/secret?token=${DEDICATED}`);
  r = await runBridgeToExit(env, ['url', 'follow']);
  assert.equal(r.code, 1, 'no clipboard here');
  assert.match(r.out, /cannot copy to the clipboard here\. URL: https:\/\/abc\.trycloudflare\.com\/hooks\/follow\?token=\*\*\*\*\* \(public URL saved by the F8 window\)/);
  assert.match(r.out, /the token is "token" in config\.json; LibertyTalk can also send it in the X-Bridge-Token header\. To print the full URL, add --show/);
  assert.ok(!r.out.includes(TOKEN), 'never printed without --show');
  r = await runBridgeToExit(env, ['url', 'secret']);
  assert.match(r.out, /the token is "hookTokens" > "secret" in config\.json/);
  assert.ok(!r.out.includes(DEDICATED));
  r = await runBridgeToExit(env, ['url', 'follow', '--base', 'https://user:pw@other.example/base/?x=1#f', '--show']);
  assert.equal(r.out.trim(), `https://other.example/base/hooks/follow?token=${TOKEN}`);
  r = await runBridgeToExit(env, ['url', 'nope']);
  assert.equal(r.code, 1);
  assert.match(r.out, /Unknown webhook "nope"\. Webhooks: bits, caps, follow, /);
  r = await runBridgeToExit(env, ['url']);
  assert.equal(r.code, 1);
  assert.match(r.out, /^Usage: node bridge\.js url <webhook> \[--show\] \[--base <public URL>\]/m);
  r = await runBridgeToExit(env, ['url', 'follow', '--base', 'ftp://x', '--show']);
  assert.equal(r.code, 1);
  assert.match(r.out, /The public URL \(command line\) must start with https:\/\//);
  assert.ok(!r.out.includes(TOKEN));
});

await t('CLI new-token: a new random token in config.json, the rest of the file kept, never printed', async () => {
  const dir = path.join(tmpRoot, 'rotate');
  fs.mkdirSync(dir, { recursive: true });
  const file = path.join(dir, 'config.json');
  const exampleRaw = fs.readFileSync(path.join(bridgeDir, 'config.example.json'), 'utf8');
  const before = exampleRaw.replace('change-me-to-a-long-random-string', 'old-token-0123456789abcdef');
  fs.writeFileSync(file, before);
  const r = await runBridgeToExit({ LT_BRIDGE_CONFIG: file }, ['new-token']);
  assert.equal(r.code, 0, r.out);
  const after = fs.readFileSync(file, 'utf8');
  const cfg = JSON.parse(after);
  assert.match(cfg.token, /^[0-9a-f]{48}$/);
  assert.deepEqual({ ...cfg, token: 'old-token-0123456789abcdef' }, JSON.parse(before), 'nothing else changes');
  const old = before.split('\n');
  const changed = after.split('\n').filter((l, i) => l !== old[i]);
  assert.equal(after.split('\n').length, old.length, 'same layout');
  assert.deepEqual(changed, [`  "token": "${cfg.token}",`]);
  assert.match(r.out, /new random token written to .*config\.json: it is in config\.json \("token"\), never shown here/);
  assert.match(r.out, /restart the bridge \(the old token works until then\), paste the new token into "Bridge token" in the LibertyTalk widget, and copy your webhook URLs again \(node bridge\.js url <webhook>\)\. The dedicated tokens of "hookTokens" do not change\./);
  assert.ok(!r.out.includes(cfg.token) && !r.out.includes('old-token'), 'never printed');
  assert.deepEqual(fs.readdirSync(dir), ['config.json'], 'no temporary file left');
  // A config.json copied by hand with the placeholder token: it gets a real one
  fs.writeFileSync(file, exampleRaw);
  assert.equal((await runBridgeToExit({ LT_BRIDGE_CONFIG: file }, ['new-token'])).code, 0);
  assert.match(JSON.parse(fs.readFileSync(file, 'utf8')).token, /^[0-9a-f]{48}$/);
  const missing = await runBridgeToExit({ LT_BRIDGE_CONFIG: path.join(dir, 'missing.json') }, ['new-token']);
  assert.equal(missing.code, 1);
  assert.match(missing.out, /No config at .*missing\.json\. Start the bridge once \(start-bridge\.cmd\): it creates config\.json with a random token\./);
  assert.equal(fs.existsSync(path.join(dir, 'missing.json')), false);
});

// ------------------------------------------------------------------ first start without config.json

console.log('first start without config.json');

// A fake user folder: os.homedir() reads HOME (Linux, macOS) or USERPROFILE (Windows), so
// %USERPROFILE%/Zomboid/Lua of config.example.json lands in it too.
const fakeHome = path.join(tmpRoot, 'home');
const homeBin = path.join(fakeHome, 'bin');
fs.mkdirSync(homeBin, { recursive: true });
const homeEnv = (lang, configPath) => ({
  HOME: fakeHome, USERPROFILE: fakeHome, LANG: lang, LC_ALL: lang, LC_MESSAGES: lang, LANGUAGE: '',
  PATH: homeBin, 'ProgramFiles(x86)': path.join(fakeHome, 'PF86'), ProgramFiles: path.join(fakeHome, 'PF'),
  LT_BRIDGE_CONFIG: configPath,
});
// LANG / LC_ALL choose the locale of Node on Linux and macOS. On Windows, Node reads the
// regional format of the user whatever the environment: the language of this machine.
const langFor = (posixLang) => (process.platform === 'win32' ? bridgeModule.systemLanguage() : posixLang.slice(0, 2));
const exampleText = fs.readFileSync(path.join(bridgeDir, 'config.example.json'), 'utf8');
const sameAsExample = (cfg) => {
  const ex = JSON.parse(exampleText);
  assert.deepEqual({ ...cfg, token: ex.token, settings: { ...cfg.settings, language: ex.settings.language } }, ex, 'only token and language differ from config.example.json');
};

// The created config.json listens on 7420 (config.example.json): wait for the lines printed
// before listening, then stop the bridge, so the test does not depend on that port.
async function firstStart(env, until) {
  const proc = startBridge(env.LT_BRIDGE_CONFIG, env);
  try {
    await waitFor(() => until.test(proc.out) || proc.child.exitCode !== null, 8000, `bridge output ${until}`);
  } finally {
    await stopBridge(proc);
  }
  return proc.out;
}

const frDir = path.join(fakeHome, 'Documents', 'Talky', 'bridge');
const frConfig = path.join(frDir, 'config.json');
fs.mkdirSync(frDir, { recursive: true });

await t('first start: config.json created with a random token of 48 hex characters (French system)', async () => {
  assert.equal(fs.existsSync(frConfig), false);
  const lang = langFor('fr_FR.UTF-8');
  const out = await firstStart(homeEnv('fr_FR.UTF-8', frConfig), /talky_config\.json from config\.json/);
  const raw = fs.readFileSync(frConfig);
  assert.equal(raw[0], 0x7b, 'no BOM');
  const cfg = JSON.parse(raw.toString('utf8'));
  assert.match(cfg.token, /^[0-9a-f]{48}$/);
  assert.equal(cfg.settings.language, lang);
  sameAsExample(cfg);
  assert.match(out, /created ~[\\/]Documents[\\/]Talky[\\/]bridge[\\/]config\.json with a random token \(language: (fr|en)\)/);
  assert.ok(out.includes(`with a random token (language: ${lang})`), out);
  assert.match(out, /the token is in config\.json \("token"\), never shown here: paste it into "Bridge token" in the LibertyTalk widget/);
  assert.match(out, lang === 'fr'
    ? /created ~[\\/]Zomboid[\\/]Lua[\\/]talky_config\.json from config\.json \(fr: \d+ text\(s\) translated\)/
    : /created ~[\\/]Zomboid[\\/]Lua[\\/]talky_config\.json from config\.json$/m, 'examples written in the language of the system');
  assert.ok(!out.includes(cfg.token), 'the token is never printed');
  assert.ok(!out.includes(fakeHome), out);
  assert.deepEqual(fs.readdirSync(frDir).filter((f) => f.endsWith('.tmp')), [], 'no temporary file left');
  const game = JSON.parse(fs.readFileSync(path.join(fakeHome, 'Zomboid', 'Lua', 'talky_config.json'), 'utf8'));
  assert.equal(game.workflows.new_follower.steps[0].text, lang === 'fr' ? '{{user}} rejoint la horde !' : '{{user}} joins the horde!');
  assert.equal(game.token, undefined, 'the token stays in config.json');
});

await t('next start: the existing config.json is kept byte for byte', async () => {
  const before = fs.readFileSync(frConfig, 'utf8');
  const out = await firstStart(homeEnv('en_US.UTF-8', frConfig), /config loaded/);
  assert.equal(fs.readFileSync(frConfig, 'utf8'), before);
  assert.doesNotMatch(out, /with a random token/);
  assert.ok(!out.includes(JSON.parse(before).token), 'the token is never printed');
});

await t('first start: English system, startup warnings (cloudflared, Talky twice, bridge in Zomboid/mods)', async () => {
  // Talky copied by hand to Zomboid/mods AND subscribed on the Workshop, in the default Steam folder of the platform
  fs.mkdirSync(path.join(fakeHome, 'Zomboid', 'mods', 'Talky', '42'), { recursive: true });
  fs.writeFileSync(path.join(fakeHome, 'Zomboid', 'mods', 'Talky', '42', 'mod.info'), 'id=Talky\n');
  const steamRoot = process.platform === 'win32' ? path.join(fakeHome, 'PF86', 'Steam')
    : process.platform === 'darwin' ? path.join(fakeHome, 'Library', 'Application Support', 'Steam')
      : path.join(fakeHome, '.local', 'share', 'Steam');
  fs.mkdirSync(path.join(steamRoot, 'steamapps', 'workshop', 'content', '108600', '3141592653', 'mods', 'Talky', '42'), { recursive: true });
  // Zip extracted straight into Zomboid/mods: bridge/ lands next to the mod
  const inMods = path.join(fakeHome, 'Zomboid', 'mods', 'bridge');
  fs.mkdirSync(inMods, { recursive: true });
  const enConfig = path.join(inMods, 'config.json');
  const out = await firstStart(homeEnv('en_US.UTF-8', enConfig), /config loaded/);
  const cfg = JSON.parse(fs.readFileSync(enConfig, 'utf8'));
  assert.match(cfg.token, /^[0-9a-f]{48}$/);
  const lang = langFor('en_US.UTF-8');
  assert.equal(cfg.settings.language, lang);
  sameAsExample(cfg);
  assert.notEqual(cfg.token, JSON.parse(fs.readFileSync(frConfig, 'utf8')).token);
  assert.ok(out.includes(`with a random token (language: ${lang})`), out);
  assert.ok(!out.includes(cfg.token), 'the token is never printed');
  assert.match(out, /warning: cloudflared is not in the PATH\. .*winget install --id Cloudflare\.cloudflared/);
  assert.match(out, /warning: Talky is installed twice: in ~[\\/]Zomboid[\\/]mods[\\/]Talky and from the Steam Workshop \(~[\\/].*3141592653[\\/]mods[\\/]Talky\)/);
  assert.match(out, /warning: The bridge folder ~[\\/]Zomboid[\\/]mods[\\/]bridge is inside ~[\\/]Zomboid[\\/]mods, the folder of the game's mods/);
  assert.ok(!out.includes(fakeHome), out);
  // With cloudflared on the PATH, its warning goes away
  fs.writeFileSync(path.join(homeBin, process.platform === 'win32' ? 'cloudflared.exe' : 'cloudflared'), '');
  const again = await firstStart(homeEnv('en_US.UTF-8', enConfig), /config loaded/);
  assert.doesNotMatch(again, /cloudflared is not in the PATH/);
  assert.match(again, /warning: Talky is installed twice/);
});

await t('a config.json copied by hand with the placeholder token is refused, not replaced', async () => {
  const dir = path.join(fakeHome, 'Documents', 'TalkyCopy', 'bridge');
  fs.mkdirSync(dir, { recursive: true });
  const file = path.join(dir, 'config.json');
  fs.writeFileSync(file, exampleText);
  const r = await runBridgeToExit(homeEnv('fr_FR.UTF-8', file));
  assert.equal(r.code, 1);
  assert.match(r.out, /Set a long random "token" in config\.json .*or delete config\.json and start the bridge again: it creates a new one with a random token\./);
  assert.equal(fs.readFileSync(file, 'utf8'), exampleText);
});

await t('fire without config.json: clear message, nothing created', async () => {
  const missing = path.join(frDir, 'missing.json');
  const r = await runBridgeToExit(homeEnv('fr_FR.UTF-8', missing), ['fire', 'new_follower']);
  assert.equal(r.code, 1);
  assert.match(r.out, /No config at ~[\\/]Documents[\\/]Talky[\\/]bridge[\\/]missing\.json\. Start the bridge once \(start-bridge\.cmd\): it creates config\.json\./);
  assert.ok(!r.out.includes(fakeHome), r.out);
  assert.equal(fs.existsSync(missing), false);
});

await t('config.json errors show ~ instead of the user folder', async () => {
  const broken = path.join(frDir, 'broken.json');
  fs.writeFileSync(broken, '{ "port": 7420, }');
  const bad = await runBridgeToExit(homeEnv('fr_FR.UTF-8', broken));
  assert.equal(bad.code, 1);
  assert.match(bad.out, /Cannot read ~[\\/]Documents[\\/]Talky[\\/]bridge[\\/]broken\.json: /);
  assert.ok(!bad.out.includes(fakeHome), bad.out);
  assert.equal(fs.readFileSync(broken, 'utf8'), '{ "port": 7420, }', 'a broken file is not replaced');
});

await t('config.json with a bad hookTokens or httpTargets: clear message, value not shown, the bridge does not start', async () => {
  const file = path.join(frDir, 'bad-secrets.json');
  fs.writeFileSync(file, JSON.stringify({ token: TOKEN, hookTokens: { follow: 'tiny-secret' } }));
  let r = await runBridgeToExit(homeEnv('en_US.UTF-8', file));
  assert.equal(r.code, 1);
  assert.match(r.out, /"hookTokens" > "follow" in config\.json must be a long random text \(16 characters or more\)\./);
  assert.ok(!r.out.includes('tiny-secret'));
  fs.writeFileSync(file, JSON.stringify({ token: TOKEN, httpTargets: { lt: { url: 'https://a.liberty-talk.com/x', headers: { 'X-Webhook-Secret': 42 } } } }));
  r = await runBridgeToExit(homeEnv('en_US.UTF-8', file));
  assert.equal(r.code, 1);
  assert.match(r.out, /"httpTargets" > "lt" in config\.json: "headers" must be an object of texts, with valid header names\./);
  assert.doesNotMatch(r.out, /listening on/);
});

await t('jobTtlSeconds above 900 in config.json: one warning at the start, jobs live 900 s', async () => {
  const dir = path.join(tmpRoot, 'ttl');
  fs.mkdirSync(dir, { recursive: true });
  const ttlPort = await freePort();
  const file = path.join(dir, 'config.json');
  const ttlLua = path.join(dir, 'Lua');
  fs.writeFileSync(file, JSON.stringify({
    port: ttlPort, token: TOKEN, zomboidLuaDir: ttlLua, jobTtlSeconds: 3600,
    webhooks: {}, workflows: { w: { steps: [{ action: 'notify', text: 'ttl' }] } },
  }));
  const proc = startBridge(file);
  try {
    await waitFor(() => proc.out.includes('http steps allowed to'), 8000, 'ttl bridge start');
    const r = await request(ttlPort, 'POST', '/fire/w', { headers: auth, body: {} });
    assert.equal(r.status, 200, r.text);
    const job = await waitFor(() => readJobs(ttlLua)[0], 3000, 'ttl job');
    assert.equal(job.expiresAt - job.createdAt, 900000);
    assert.equal(proc.out.match(/warning: "jobTtlSeconds" in config\.json is 3600: 900 is used\./g)?.length, 1, proc.out);
  } finally {
    await stopBridge(proc);
  }
});

await new Promise((r) => sink.close(r));
fs.rmSync(tmpRoot, { recursive: true, force: true });

const failed = results.filter((r) => !r.ok);
console.log(`\n${results.length - failed.length}/${results.length} passed`);
process.exit(failed.length ? 1 : 0);

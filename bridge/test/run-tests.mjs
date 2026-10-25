// Talky bridge tests, no dependencies: node test/run-tests.mjs (or npm test).
//
// Unit tests on lib/*, then real bridge processes on free ports with a temporary
// "Zomboid/Lua" folder: authentication, 404 after authentication, double slash,
// numeric fields, http host list, caps, inbox / ack / outbox files, first-run seeding,
// "Test now" right after a save, errors of game workflows, UTF-8 bodies, ~ in messages,
// config.json created on the first start (token never printed, never replaced), startup
// warnings. TALKY_TEST_TMP=<dir> chooses where the temporary folders go (default:
// os.tmpdir()). The tests never touch the clipboard (TALKY_NO_CLIPBOARD).

import assert from 'node:assert/strict';
import { spawn } from 'node:child_process';
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
const { GameLink } = require('../lib/ipc.js');
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

await t('version is 0.3.0 everywhere in the bridge', () => {
  assert.equal(pkg.version, '0.3.0');
  assert.equal(bridgeModule.VERSION, '0.3.0');
  assert.equal(pkg.name, 'talky-bridge');
  assert.equal(pkg.engines.node, '>=18');
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
}, null, 2));

// talky_config.json already exists, as after a first run. Its own "httpAllowedHosts"
// (written by a hostile mod, say) must be ignored.
const gameConfigPath = path.join(luaDir, 'talky_config.json');
const outboxPath = path.join(luaDir, 'talky_outbox.jsonl');
const gameConfig = {
  httpAllowedHosts: ['*'],
  settings: { language: 'fr' },
  webhooks: {
    follow: { workflow: 'new_follower' },
    secret: { workflow: 'new_follower', token: DEDICATED },
    bits: { workflow: 'bits_wf' },
    caps: { workflow: 'caps_wf' },
    http_ok: { workflow: 'http_ok' },
    http_bad: { workflow: 'http_bad' },
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
    on_kill: { steps: [{ action: 'notify', text: '{{name}} is down' }] },
    broken_wf: { steps: [{ action: 'notify', text: '{{hoursSurvived | nope}}' }] },
  },
  gameEvents: { zombie_killed: 'on_kill', player_died: 'broken_wf' },
};
fs.writeFileSync(gameConfigPath, JSON.stringify(gameConfig, null, 2));

const bridge = startBridge(configPath);
const auth = { 'X-Bridge-Token': TOKEN, 'Content-Type': 'application/json' };

try {
  await t('bridge starts', async () => {
    await waitFor(() => bridge.out.includes('listening on'), 8000, 'bridge start');
    assert.match(bridge.out, /Talky bridge 0\.3\.0 listening on http:\/\/127\.0\.0\.1:\d+/);
    assert.match(bridge.out, /http steps allowed to: \*\.liberty-talk\.com, 127\.0\.0\.1:\d+/);
  });

  await t('GET /health: nothing without token, details with token', async () => {
    const anon = await request(port, 'GET', '/health');
    assert.equal(anon.status, 200);
    assert.deepEqual(anon.json, { ok: true });
    const full = await request(port, 'GET', `/health?token=${TOKEN}`);
    assert.equal(full.json.version, '0.3.0');
    assert.equal(typeof full.json.pending, 'number');
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

  await t('dedicated webhook token: the global token is refused, the dedicated one works', async () => {
    assert.equal((await request(port, 'POST', '/hooks/secret', { headers: auth, body: {} })).status, 401);
    const ok = await request(port, 'POST', '/hooks/secret', { headers: { 'X-Bridge-Token': DEDICATED }, body: { user_name: 'Ded' } });
    assert.equal(ok.status, 200);
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

  await t('outbox file: a game event runs its workflow', async () => {
    fs.writeFileSync(outboxPath, `${JSON.stringify({ event: 'zombie_killed', data: { name: 'Bob', byPlayer: true }, ts: Date.now() })}\n`);
    const job = await waitFor(() => readJobs(luaDir).find((j) => j.workflow === 'on_kill'), 3000, 'on_kill job');
    assert.equal(job.steps[0].text, 'Bob is down');
    assert.equal(fs.existsSync(outboxPath), false);
  });

  await t('Test now right after a save: the bridge runs the version just written', async () => {
    // Same order as the window: talky_config.json, then the outbox line, in the same millisecond
    gameConfig.workflows.fresh_wf = { steps: [{ action: 'notify', text: 'fresh {{user}}' }] };
    fs.writeFileSync(gameConfigPath, JSON.stringify(gameConfig, null, 2));
    fs.writeFileSync(outboxPath, `${JSON.stringify({ event: 'test_workflow', data: { workflow: 'fresh_wf', vars: { user: 'Tess' } } })}\n`);
    const job = await waitFor(() => readJobs(luaDir).find((j) => j.workflow === 'fresh_wf'), 3000, 'fresh_wf job');
    assert.equal(job.steps[0].text, 'fresh Tess');
    // A modified workflow runs in its new version
    gameConfig.workflows.fresh_wf.steps[0].text = 'v2 {{user}}';
    fs.writeFileSync(gameConfigPath, JSON.stringify(gameConfig, null, 2));
    fs.writeFileSync(outboxPath, `${JSON.stringify({ event: 'test_workflow', data: { workflow: 'fresh_wf', vars: { user: 'Tess' } } })}\n`);
    const job2 = await waitFor(() => readJobs(luaDir).find((j) => j.workflow === 'fresh_wf' && j.seq > job.seq), 3000, 'fresh_wf v2 job');
    assert.equal(job2.steps[0].text, 'v2 Tess');
  });

  await t('a game workflow that fails does not lose the other events of the batch', async () => {
    fs.writeFileSync(outboxPath, `${[
      { event: 'player_died', data: { hoursSurvived: 3 } }, // broken_wf: unknown filter
      { event: 'test_workflow', data: { workflow: 'broken_wf', vars: { user: 'Tess' } } },
      { event: 'zombie_killed', data: { name: 'Kim', byPlayer: true } },
    ].map((e) => JSON.stringify(e)).join('\n')}\n`);
    await waitFor(() => readJobs(luaDir).find((j) => j.workflow === 'on_kill' && j.steps[0].text === 'Kim is down'), 3000, 'on_kill after a failure');
    assert.match(bridge.out, /\[game:player_died\] broken_wf failed: unknown filter "nope"/);
    assert.match(bridge.out, /\[test\] broken_wf failed: unknown filter "nope"/);
    const health = await request(port, 'GET', `/health?token=${TOKEN}`);
    const errors = health.json.recent.filter((e) => e.workflow === 'broken_wf' && /unknown filter/.test(e.error || ''));
    assert.deepEqual(errors.map((e) => e.source).sort(), ['game:player_died', 'test'], 'shown on the F8 Status page');
  });

  await t('status file for the in-game window', async () => {
    const status = await waitFor(() => JSON.parse(fs.readFileSync(path.join(luaDir, 'talky_status.json'), 'utf8')), 3000, 'status');
    assert.equal(status.version, '0.3.0');
    assert.equal(status.port, port);
    assert.ok(status.webhooks.includes('follow'));
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
    assert.match(bridge2.out, /fr: \d+ text\(s\) translated/);
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
  assert.equal(out.trim(), '0.3.0');
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

await new Promise((r) => sink.close(r));
fs.rmSync(tmpRoot, { recursive: true, force: true });

const failed = results.filter((r) => !r.ok);
console.log(`\n${results.length - failed.length}/${results.length} passed`);
process.exit(failed.length ? 1 : 0);

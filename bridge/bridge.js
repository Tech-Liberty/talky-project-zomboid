#!/usr/bin/env node
// Talky bridge: LibertyTalk webhooks -> Project Zomboid.
//
//   node bridge.js                                start the bridge
//   node bridge.js fire <workflow> [key=value...] trigger a workflow on the running bridge (tests, Stream Deck...)
//   node bridge.js url <webhook> [--show]         copy the full URL of a webhook (with its token) to the clipboard
//   node bridge.js new-token                      give the bridge a new random token in config.json
//   node bridge.js version                        print the version
//
// bridge/config.json            : port, token, dedicated webhook tokens (hookTokens), http
//                                 targets and their secrets (httpTargets), allowed http hosts,
//                                 poll source. Created on the first start from
//                                 config.example.json, with a random token; an existing file is
//                                 never replaced. The game cannot read it.
// Zomboid/Lua/talky_config.json : webhooks, workflows, game events, settings - edited by the
//                                 in-game window, reloaded here on every save (seeded from
//                                 config.json on first run). Every mod running in the game can
//                                 read and write it (on a server: every mod of the server's
//                                 list), so nothing secret goes there, and nothing in it can
//                                 widen what the bridge allows.
//
// No dependencies: Node >= 18.

'use strict';

const http = require('http');
const fs = require('fs');
const os = require('os');
const path = require('path');
const crypto = require('crypto');
const { spawnSync } = require('child_process');
const { isDeepStrictEqual } = require('util');
const { expand, test, buildVars, render, arr, LIMITS } = require('./lib/engine');
const { GameLink } = require('./lib/ipc');
const { DEFAULT_HTTP_ALLOWED_HOSTS, checkHttpUrl } = require('./lib/hosts');
const { localizeExamples, normalizeLanguage } = require('./lib/examples');

const VERSION = require('./package.json').version;
const CONFIG_PATH = process.env.LT_BRIDGE_CONFIG || path.join(__dirname, 'config.json');
const EXAMPLE_PATH = path.join(__dirname, 'config.example.json');
const MAX_BODY = 65536;

// Version of the files exchanged with the mod, written in talky_status.json as "protocol".
//   1 (bridge 0.3.0, no "protocol" field): outbox talky_outbox.jsonl, ack "S".
//   2 (bridge 0.4.0): outbox talky_outbox.txt (the .jsonl one still read), ack "S s1 s2 ...",
//     "testNonce" required in test_workflow, job_rejected / job_expired events.
const PROTOCOL = 2;

// Hides the Windows user name when the console is visible on stream.
const displayPath = (p) => {
  const home = os.homedir();
  const full = path.resolve(p);
  return home && full.toLowerCase().startsWith(home.toLowerCase()) ? `~${full.slice(home.length)}` : full;
};

// Same thing inside any text (error messages of Node quote full paths): the user folder,
// written with \ or /, becomes ~.
const HOME_RE = (() => {
  const home = os.homedir();
  if (!home || home.length < 3) return null;
  const parts = home.split(/[\\/]+/).map((s) => s.replace(/[.*+?^${}()|[\]\\]/g, '\\$&'));
  return new RegExp(`${parts.join('[\\\\/]+')}(?![\\w.-])`, 'gi');
})();
const hideHome = (text) => (HOME_RE ? String(text).replace(HOME_RE, '~') : String(text));

const log = (...args) => console.log(new Date().toLocaleTimeString(), ...args.map((a) => (typeof a === 'string' ? hideHome(a) : a)));

const own = (obj, key) => (obj && Object.prototype.hasOwnProperty.call(obj, key) ? obj[key] : undefined);

const isPlainObject = (v) => v !== null && typeof v === 'object' && !Array.isArray(v);

function fail(message) {
  console.error(hideHome(message));
  process.exit(1);
}

// ------------------------------------------------------------------ first start

const PLACEHOLDER_TOKEN = 'change-me-to-a-long-random-string';

// "fr" when the locale of the system starts with fr (fr-FR, fr-CA...), "en" otherwise. On
// Windows, Node reads it from the regional format of the user.
function systemLanguage(locale) {
  let l = locale;
  if (l === undefined) {
    try {
      l = Intl.DateTimeFormat().resolvedOptions().locale;
    } catch {
      l = '';
    }
  }
  return /^fr(?![a-z])/i.test(String(l || '')) ? 'fr' : 'en';
}

// Windows only (clip.exe reads the text on its input). A failure is not an error: the
// token stays in config.json. TALKY_NO_CLIPBOARD=1 turns the copy off (tests).
function copyToClipboard(text) {
  if (process.platform !== 'win32' || process.env.TALKY_NO_CLIPBOARD) return false;
  try {
    const r = spawnSync('clip', [], { input: text, stdio: ['pipe', 'ignore', 'ignore'], windowsHide: true, timeout: 5000 });
    return !r.error && r.status === 0;
  } catch {
    return false;
  }
}

// config.example.json with the token and the language swapped in, its layout kept.
// Rebuilt from the parsed example when these two lines are not found.
function newConfigText(exampleText, token, language) {
  const text = String(exampleText).replace(/^﻿/, '');
  const example = JSON.parse(text);
  const out = text
    .replace(JSON.stringify(PLACEHOLDER_TOKEN), JSON.stringify(token))
    .replace(/("language"\s*:\s*)"[^"]*"/, `$1${JSON.stringify(language)}`);
  try {
    const check = JSON.parse(out);
    if (check.token === token && check.settings && check.settings.language === language) return out;
  } catch { /* rebuilt below */ }
  const settings = example.settings && typeof example.settings === 'object' && !Array.isArray(example.settings) ? example.settings : {};
  return `${JSON.stringify({ ...example, token, settings: { ...settings, language } }, null, 2)}\n`;
}

const removeQuietly = (file) => {
  try {
    fs.unlinkSync(file);
  } catch { /* already gone */ }
};

// Creates config.json from config.example.json with a random token (24 bytes, 48 hex
// characters). Written to a temporary file, then linked into place: the link fails when
// config.json exists, so a file created in between is never replaced. Returns null in
// that case.
function createConfig(configPath, examplePath, language) {
  let exampleText;
  try {
    exampleText = fs.readFileSync(examplePath, 'utf8');
  } catch (e) {
    fail(`No config at ${displayPath(configPath)}, and ${displayPath(examplePath)} cannot be read (${e.message}). Extract the whole Talky zip again.`);
  }
  const token = crypto.randomBytes(24).toString('hex');
  let text;
  try {
    text = newConfigText(exampleText, token, language);
  } catch (e) {
    fail(`Cannot read ${displayPath(examplePath)}: ${e.message}`);
  }
  const tmp = `${configPath}.${process.pid}.tmp`;
  let created = true;
  try {
    const fd = fs.openSync(tmp, 'w', 0o600);
    try {
      fs.writeSync(fd, text);
      fs.fsyncSync(fd);
    } finally {
      fs.closeSync(fd);
    }
    try {
      fs.linkSync(tmp, configPath);
    } catch (e) {
      // Drives without hard links (FAT32, some network drives): rename, still never over a file
      if (e.code === 'EEXIST' || fs.existsSync(configPath)) created = false;
      else fs.renameSync(tmp, configPath);
    }
  } catch (e) {
    removeQuietly(tmp);
    fail(`Cannot create ${displayPath(configPath)}: ${e.message}. Move the Talky folder to a folder you can write to, for example Documents\\Talky.`);
  }
  removeQuietly(tmp);
  return created ? { token, language } : null;
}

// ------------------------------------------------------------------ startup warnings
// Printed when the bridge starts; none of them stops it.

const samePath = (a, b) => (process.platform === 'win32' ? a.toLowerCase() === b.toLowerCase() : a === b);

function isInside(child, parent) {
  const c = path.resolve(child);
  const p = path.resolve(parent);
  return samePath(c, p) || samePath(c.slice(0, p.length + 1), p + path.sep);
}

// Full path of a program found in PATH, or null.
function findOnPath(name, env = process.env, platform = process.platform) {
  const dirs = String(env.PATH ?? env.Path ?? '').split(path.delimiter).map((d) => d.trim().replace(/^"(.*)"$/, '$1')).filter(Boolean);
  const exts = platform === 'win32' ? String(env.PATHEXT || '.COM;.EXE;.BAT;.CMD').split(';').filter(Boolean) : [''];
  for (const dir of dirs) {
    for (const ext of exts) {
      const file = path.join(dir, name + ext);
      try {
        if (fs.statSync(file).isFile()) return file;
      } catch { /* not here */ }
    }
  }
  return null;
}

function defaultSteamRoots(env = process.env, platform = process.platform, home = os.homedir()) {
  if (platform === 'win32') return [env['ProgramFiles(x86)'], env.ProgramFiles].filter(Boolean).map((d) => path.join(d, 'Steam'));
  if (platform === 'darwin') return [path.join(home, 'Library', 'Application Support', 'Steam')];
  return [path.join(home, '.steam', 'steam'), path.join(home, '.local', 'share', 'Steam')];
}

// Talky folders of the Steam Workshop (Project Zomboid is app 108600), in the Steam folder
// and in the other libraries listed in libraryfolders.vdf.
function workshopCopies(steamRoots) {
  const libraries = new Map();
  const addLibrary = (dir) => libraries.set(path.resolve(dir).toLowerCase(), path.resolve(dir));
  for (const root of steamRoots) {
    if (!root) continue;
    addLibrary(root);
    for (const vdf of [path.join(root, 'steamapps', 'libraryfolders.vdf'), path.join(root, 'config', 'libraryfolders.vdf')]) {
      let text;
      try {
        text = fs.readFileSync(vdf, 'utf8');
      } catch {
        continue;
      }
      for (const m of text.matchAll(/"path"\s+"([^"]+)"/g)) addLibrary(m[1].replace(/\\\\/g, '\\'));
    }
  }
  const found = [];
  for (const lib of libraries.values()) {
    const content = path.join(lib, 'steamapps', 'workshop', 'content', '108600');
    let items;
    try {
      items = fs.readdirSync(content, { withFileTypes: true });
    } catch {
      continue;
    }
    for (const item of items) {
      const mod = path.join(content, item.name, 'mods', 'Talky');
      if (item.isDirectory() && fs.existsSync(mod)) found.push(mod);
    }
  }
  return found;
}

// zomboidDir: the Zomboid user folder (parent of zomboidLuaDir). bridgeDirs: the folders
// of bridge.js and of config.json. needsTunnel: false in poll mode, which needs no public address.
function startupWarnings({ zomboidDir, bridgeDirs = [__dirname, path.dirname(CONFIG_PATH)], needsTunnel = true, env = process.env, platform = process.platform, steamRoots } = {}) {
  const warnings = [];
  if (needsTunnel && !findOnPath('cloudflared', env, platform)) {
    warnings.push('cloudflared is not in the PATH. LibertyTalk reaches the bridge through a public https address, which cloudflared provides. Install it with "winget install --id Cloudflare.cloudflared", then open a new window.');
  }
  const modsDir = path.join(zomboidDir, 'mods');
  const manualCopy = path.join(modsDir, 'Talky');
  if (fs.existsSync(path.join(manualCopy, '42', 'mod.info'))) {
    const workshop = workshopCopies(steamRoots ?? defaultSteamRoots(env, platform));
    if (workshop.length) {
      warnings.push(`Talky is installed twice: in ${displayPath(manualCopy)} and from the Steam Workshop (${displayPath(workshop[0])}). Two mods with the id Talky confuse the game: delete the folder ${displayPath(manualCopy)}, the Workshop version is enough.`);
    }
  }
  const inMods = bridgeDirs.find((d) => isInside(d, modsDir));
  if (inMods) {
    warnings.push(`The bridge folder ${displayPath(inMods)} is inside ${displayPath(modsDir)}, the folder of the game's mods: removing or replacing a mod there can delete the bridge and its config.json. Move the whole Talky folder elsewhere, for example to Documents\\Talky, and start start-bridge.cmd from there.`);
  }
  return warnings;
}

// ------------------------------------------------------------------ config

const HEADER_NAME = /^[!#$%&'*+.^_`|~0-9A-Za-z-]{1,64}$/;
const TARGET_NAME = /^[A-Za-z0-9_.-]{1,64}$/;
const MIN_HOOK_TOKEN = 16;

// "httpTargets": { "<name>": { "url", "headers"?, "hmacSecret"?, "hmacHeader"?, "method"? } }.
// An http step names one with "target"; its address and its secrets never appear in
// talky_config.json. Returns an error message, or null. Values are never quoted.
function httpTargetsError(targets) {
  const shape = '{ "<name>": { "url": "https://...", "headers": { "X-Webhook-Secret": "..." } } }';
  if (!isPlainObject(targets)) return `"httpTargets" in config.json must be an object: ${shape}.`;
  for (const [name, t] of Object.entries(targets)) {
    const where = `"httpTargets" > "${cleanText(name, 64)}" in config.json`;
    if (!TARGET_NAME.test(name)) return `${where}: a target name is made of letters, digits, _ . and - (64 at most).`;
    if (!isPlainObject(t)) return `${where} must be an object: { "url": "https://...", "headers": { ... } }.`;
    if (typeof t.url !== 'string' || t.url.trim() === '') return `${where} needs a "url".`;
    if (t.headers !== undefined) {
      if (!isPlainObject(t.headers)) return `${where}: "headers" must be an object of texts.`;
      for (const [h, v] of Object.entries(t.headers)) {
        if (!HEADER_NAME.test(h) || typeof v !== 'string') return `${where}: "headers" must be an object of texts, with valid header names.`;
      }
    }
    if (t.hmacSecret !== undefined && (typeof t.hmacSecret !== 'string' || t.hmacSecret === '')) return `${where}: "hmacSecret" must be a text.`;
    if (t.hmacHeader !== undefined && (typeof t.hmacHeader !== 'string' || !HEADER_NAME.test(t.hmacHeader))) return `${where}: "hmacHeader" must be a header name.`;
    if (t.method !== undefined && (typeof t.method !== 'string' || !/^[A-Za-z]{1,16}$/.test(t.method))) return `${where}: "method" must be an http method, for example "POST".`;
  }
  return null;
}

// "hookTokens": { "<webhook id>": "<long random text>" }: a webhook listed here takes this
// token only (the bridge token is refused for it). Returns an error message, or null.
function hookTokensError(tokens) {
  if (!isPlainObject(tokens)) return '"hookTokens" in config.json must be an object: { "<webhook id>": "<long random text>" }.';
  for (const [id, token] of Object.entries(tokens)) {
    if (typeof token !== 'string' || token.length < MIN_HOOK_TOKEN || token.startsWith('change-me')) {
      return `"hookTokens" > "${cleanText(id, 64)}" in config.json must be a long random text (${MIN_HOOK_TOKEN} characters or more).`;
    }
  }
  return null;
}

// The game and the server drop a job 15 minutes after the bridge created it
// (Talky_Config.maxJobTtlMs of the mod), whatever jobTtlSeconds says: above that, a job would
// only wait in the inbox for nothing.
const MAX_JOB_TTL_SECONDS = 900;

// "jobTtlSeconds" of config.json -> { seconds, warning? }: missing = 900, above 900 = 900.
function jobTtl(value) {
  if (value === undefined || value === null) return { seconds: MAX_JOB_TTL_SECONDS };
  const n = typeof value === 'number' ? value : typeof value === 'string' && /^\s*\d+(\.\d+)?\s*$/.test(value) ? Number(value) : NaN;
  if (!Number.isFinite(n) || n <= 0) {
    return { seconds: MAX_JOB_TTL_SECONDS, warning: `"jobTtlSeconds" in config.json is not a number of seconds above 0: ${MAX_JOB_TTL_SECONDS} is used.` };
  }
  if (n > MAX_JOB_TTL_SECONDS) {
    return { seconds: MAX_JOB_TTL_SECONDS, warning: `"jobTtlSeconds" in config.json is ${n}: ${MAX_JOB_TTL_SECONDS} is used. The game and the server drop a job 15 minutes after the bridge created it.` };
  }
  return { seconds: n };
}

// create: on the first start, config.json is created from config.example.json. The
// token is copied to the clipboard and never printed (the window may be on stream).
// warnings: a list that gets the warnings about config.json (logged once, at the start).
function loadConfig({ create = false, warnings } = {}) {
  if (!fs.existsSync(CONFIG_PATH)) {
    if (!create) fail(`No config at ${displayPath(CONFIG_PATH)}. Start the bridge once (start-bridge.cmd): it creates config.json.`);
    const made = createConfig(CONFIG_PATH, EXAMPLE_PATH, systemLanguage());
    if (made) {
      log(`created ${displayPath(CONFIG_PATH)} with a random token (language: ${made.language})`);
      const where = copyToClipboard(made.token) ? 'in your clipboard and in config.json' : 'in config.json ("token")';
      log(`the token is ${where}, never shown here: paste it into "Bridge token" in the LibertyTalk widget`);
    }
  }
  let cfg;
  try {
    // Strip the BOM PowerShell adds when it writes UTF-8
    cfg = JSON.parse(fs.readFileSync(CONFIG_PATH, 'utf8').replace(/^﻿/, ''));
  } catch (e) {
    fail(`Cannot read ${displayPath(CONFIG_PATH)}: ${e.message}`);
  }
  cfg.port ??= 7420;
  cfg.webhooks ??= {};
  cfg.workflows ??= {};
  cfg.gameEvents ??= {};
  cfg.zomboidLuaDir = cfg.zomboidLuaDir
    ? cfg.zomboidLuaDir.replace(/^~|%USERPROFILE%/, os.homedir())
    : path.join(os.homedir(), 'Zomboid', 'Lua');
  if (!cfg.token || String(cfg.token).startsWith('change-me')) {
    fail('Set a long random "token" in config.json (it protects your webhook URLs), or delete config.json and start the bridge again: it creates a new one with a random token.');
  }
  if (cfg.httpAllowedHosts === undefined) cfg.httpAllowedHosts = [...DEFAULT_HTTP_ALLOWED_HOSTS];
  if (!Array.isArray(cfg.httpAllowedHosts) || cfg.httpAllowedHosts.some((h) => typeof h !== 'string')) {
    fail('"httpAllowedHosts" in config.json must be a list of host names, for example ["*.liberty-talk.com"].');
  }
  cfg.httpTargets ??= {};
  cfg.hookTokens ??= {};
  const error = httpTargetsError(cfg.httpTargets) || hookTokensError(cfg.hookTokens);
  if (error) fail(error);
  const ttl = jobTtl(cfg.jobTtlSeconds);
  cfg.jobTtlSeconds = ttl.seconds;
  if (ttl.warning && Array.isArray(warnings)) warnings.push(ttl.warning);
  return cfg;
}

// ------------------------------------------------------------------ requests

// LibertyTalk inserts variables into the JSON body without escaping them, so a chat
// message containing a quote produces invalid JSON. Recover "key": value pairs anyway.
function parseBody(raw) {
  if (!raw || !raw.trim()) return {};
  try {
    return JSON.parse(raw);
  } catch { /* fall through */ }
  const out = {};
  const re = /"([\w.-]+)"\s*:\s*(?:"([\s\S]*?)"(?=\s*(?:,\s*"[\w.-]+"\s*:|\}\s*$))|(-?\d+(?:\.\d+)?|true|false|null))/g;
  let m;
  while ((m = re.exec(raw))) {
    out[m[1]] = m[2] !== undefined ? m[2] : JSON.parse(m[3]);
  }
  if (Object.keys(out).length) return out;
  try {
    return Object.fromEntries(new URLSearchParams(raw));
  } catch {
    return { raw };
  }
}

// "//hooks/x", "/hooks//x/" -> "/hooks/x". A base URL pasted with a trailing slash
// ("https://abc.trycloudflare.com/") produces the double slash.
function normalizePath(rawUrl) {
  const s = String(rawUrl || '/');
  const q = s.indexOf('?');
  const pathPart = q === -1 ? s : s.slice(0, q);
  const query = q === -1 ? '' : s.slice(q);
  return '/' + pathPart.split('/').filter(Boolean).join('/') + query;
}

function safeEqual(a, b) {
  const ba = Buffer.from(String(a ?? ''));
  const bb = Buffer.from(String(b ?? ''));
  return ba.length === bb.length && crypto.timingSafeEqual(ba, bb);
}

// LibertyTalk activity feed item -> the variables the webhook workflows expect.
function activityToPayload(item) {
  const out = { ...item, user_name: item.actor_name || '' };
  const amount = item.amount;
  if (item.type === 'cheer') out.bits = amount;
  else if (item.type === 'raid') out.viewers = amount;
  else if (item.type === 'subscribe_gift' || item.type === 'member_gift') out.total = amount;
  if (amount !== null && amount !== undefined && item.currency) out.formatted_amount = `${amount} ${item.currency}`;
  return out;
}

function activityItems(json) {
  if (Array.isArray(json)) return json;
  if (json && Array.isArray(json.items)) return json.items;
  if (json && Array.isArray(json.data)) return json.data;
  return [];
}

// ------------------------------------------------------------------ bridge

const GAME_FIELDS = ['webhooks', 'workflows', 'gameEvents', 'publicUrl', 'settings'];

// Missing, null, {} or [] (Kahlua writes an empty Lua table as {}).
const isEmptyTable = (v) => v === undefined || v === null || (typeof v === 'object' && Object.keys(v).length === 0);

// ------------------------------------------------------------------ game events

// Event names written by the mod: zombie_killed, job_done, the "event" of emit steps...
// A name with control characters could forge lines in the console: refused.
const isEventName = (v) => typeof v === 'string' && v.length > 0 && v.length <= 64 && !/[\u0000-\u001f\u007f]/.test(v);

// Text from the game, before it reaches the console or the F8 Status page.
const cleanText = (v, max) => (typeof v === 'string' ? v.replace(/[\u0000-\u001f\u007f]/g, ' ').slice(0, max) : '');

// Jobs the game (or the server, in multiplayer) refused for good: it acknowledges them, so
// they leave the inbox, and sends job_rejected { seq, workflow, reason }. job_expired { seq,
// workflow } is a job that waited past its time to live before it could start.
const REJECT_HINTS = {
  not_allowed: 'this player may not use Talky on this server. A server admin adds the username to the sandbox option Talky.AllowedPlayers, or gives the player the admin or moderator role. The host of a game can also press "Allow me" on the F8 Status page.',
  invalid: 'the server could not read the job. Update Talky on this PC and on the server to the same version.',
  duplicate: 'the server had already received this job.',
  unknown_action: 'the server does not know an action of this job. Update Talky on the server.',
  disabled: 'an action of this job is turned off in the sandbox options of the server.',
  expired: 'the job waited longer than its time to live (jobTtlSeconds) before it could start.',
  too_large: 'the job is too large for one network message of the game, so the game on this PC did not send it to the server. Give the workflow fewer steps (repeat counts too) or shorter texts.',
};
// Informative only: they never run gameEvents workflows. A workflow with game steps sent
// after a refusal would be refused again, and again.
const NO_WORKFLOW_EVENTS = new Set(['job_rejected', 'job_expired']);

const newNonce = () => crypto.randomBytes(16).toString('hex');

class Bridge {
  constructor(cfg) {
    this.base = cfg;
    this.cfg = cfg;
    this.lastRun = new Map(); // cooldown keys -> timestamp
    this.recent = [];
    this.pendingBridgeWork = new Set();
    // "Test now" must send back this value, written in talky_status.json (new at each start):
    // a game event that does not come from the F8 window of this PC cannot run any workflow.
    this.testNonce = newNonce();
    this.testRefusals = new Set(); // refusal reasons already logged since the start
    this.warned = new Set(); // keys of the warnings already logged since the start
    // Read from bridge/config.json only: talky_config.json cannot widen them, and the
    // game cannot read them
    this.allowedHosts = Array.isArray(cfg.httpAllowedHosts) ? cfg.httpAllowedHosts : [...DEFAULT_HTTP_ALLOWED_HOSTS];
    this.httpTargets = isPlainObject(cfg.httpTargets) ? cfg.httpTargets : {};
    this.hookTokens = isPlainObject(cfg.hookTokens) ? cfg.hookTokens : {};
    this.gameConfigPath = path.join(cfg.zomboidLuaDir, 'talky_config.json');
    this.statusPath = path.join(cfg.zomboidLuaDir, 'talky_status.json');
    this.link = new GameLink({
      luaDir: cfg.zomboidLuaDir,
      // Next to config.json, never in the mod folder (the Workshop rewrites it on update)
      stateFile: path.join(path.dirname(CONFIG_PATH), 'bridge-state.json'),
      jobTtlSeconds: jobTtl(cfg.jobTtlSeconds).seconds, // loadConfig already bounded it
      log,
    });
  }

  settings() {
    const s = this.cfg.settings;
    return s && typeof s === 'object' && !Array.isArray(s) ? s : {};
  }

  language() {
    return normalizeLanguage(this.settings().language);
  }

  // Name used when the event names nobody (anonymous cheer, gift...).
  anonymousName() {
    const custom = this.settings().anonymousName;
    if (typeof custom === 'string' && custom.trim() !== '') return custom.trim().slice(0, 40);
    return this.language() === 'fr' ? 'Anonyme' : 'Anonymous';
  }

  varsFor(payload, extra = {}) {
    return buildVars(payload, extra, { anonymousName: this.anonymousName() });
  }

  warnOnce(key, message) {
    if (this.warned.has(key)) return;
    this.warned.add(key);
    log(message);
  }

  // First run: copy the workflows of config.json into the game file the window edits.
  // Also when that file exists without any webhook or workflow: the F8 window saved it
  // (language, public URL...) before the bridge ever ran. Its public URL, settings and
  // game events are kept; a file with at least one webhook or workflow is never touched.
  seedGameConfig() {
    let current = null;
    if (fs.existsSync(this.gameConfigPath)) {
      try {
        current = JSON.parse(fs.readFileSync(this.gameConfigPath, 'utf8').replace(/^﻿/, ''));
      } catch {
        return; // unreadable: loadGameConfig reports it, the file stays as it is
      }
      if (!current || typeof current !== 'object' || Array.isArray(current)) return;
      if (!isEmptyTable(current.webhooks) || !isEmptyTable(current.workflows)) return;
      if (isEmptyTable(this.base.webhooks) && isEmptyTable(this.base.workflows)) return; // nothing to add
    }
    fs.mkdirSync(path.dirname(this.gameConfigPath), { recursive: true });
    let seed = {};
    for (const k of GAME_FIELDS) if (this.base[k] !== undefined) seed[k] = JSON.parse(JSON.stringify(this.base[k]));
    // A webhook token never goes to the game folder (see authorized)
    if (isPlainObject(seed.webhooks)) for (const hook of Object.values(seed.webhooks)) if (isPlainObject(hook)) delete hook.token;
    if (current) {
      const saved = current.settings && typeof current.settings === 'object' && !Array.isArray(current.settings) ? current.settings : {};
      seed = {
        ...current,
        webhooks: seed.webhooks ?? {},
        workflows: seed.workflows ?? {},
        gameEvents: isEmptyTable(current.gameEvents) ? (seed.gameEvents ?? {}) : current.gameEvents,
        publicUrl: typeof current.publicUrl === 'string' && current.publicUrl !== '' ? current.publicUrl : (seed.publicUrl ?? ''),
        // What the window saved wins; config.json fills the rest (language set when it was created...)
        settings: { ...(seed.settings || {}), ...saved },
      };
    }
    const lang = normalizeLanguage(seed.settings?.language);
    let localized = 0;
    try {
      localized = localizeExamples(seed, lang);
    } catch (e) {
      log(`cannot translate the example workflows (${e.message}), keeping English`);
    }
    fs.writeFileSync(this.gameConfigPath, JSON.stringify(seed, null, 2));
    const translated = localized ? ` (${lang}: ${localized} text(s) translated)` : '';
    if (current) log(`${displayPath(this.gameConfigPath)} had no webhook and no workflow: examples added from config.json${translated}`);
    else log(`created ${displayPath(this.gameConfigPath)} from config.json${translated}`);
  }

  loadGameConfig() {
    let game;
    let stamp;
    try {
      const st = fs.statSync(this.gameConfigPath);
      stamp = `${st.mtimeMs}:${st.size}`;
      game = JSON.parse(fs.readFileSync(this.gameConfigPath, 'utf8').replace(/^﻿/, ''));
    } catch (e) {
      log(`cannot read talky_config.json (${e.message}), keeping the previous version`);
      return;
    }
    if (!game || typeof game !== 'object' || Array.isArray(game)) {
      log('talky_config.json is not a JSON object, keeping the previous version');
      return;
    }
    this.gameConfigStamp = stamp;
    const cfg = { ...this.base };
    for (const k of GAME_FIELDS) if (game[k] !== undefined) cfg[k] = game[k];
    // Kahlua writes empty objects for empty lists and the other way round
    for (const k of ['webhooks', 'workflows', 'gameEvents']) {
      if (!cfg[k] || typeof cfg[k] !== 'object' || Array.isArray(cfg[k])) cfg[k] = {};
    }
    for (const hook of Object.values(cfg.webhooks)) if (hook && hook.routes) hook.routes = arr(hook.routes);
    this.cfg = cfg;
    log(`config loaded: ${Object.keys(cfg.webhooks).length} webhook(s), ${Object.keys(cfg.workflows).length} workflow(s)`);
    this.warnHookTokens();
  }

  // A "token" of a webhook in talky_config.json (the F8 window of Talky 0.3.0 wrote it
  // there) no longer counts: any mod could plant one there and reach the webhook through
  // the public URL. Logged once per webhook and per start.
  warnHookTokens() {
    const ids = Object.entries(this.cfg.webhooks)
      .filter(([id, h]) => isPlainObject(h) && h.token !== undefined && h.token !== null && h.token !== '' && !this.warned.has(`hook-token:${id}`))
      .map(([id]) => id);
    if (!ids.length) return;
    ids.forEach((id) => this.warned.add(`hook-token:${id}`));
    const list = ids.map((id) => `"${cleanText(id, 64)}"`).join(', ');
    log(`warning: the "token" of webhook ${list} in talky_config.json is ignored: every mod running in the game can write that file. A dedicated webhook token is read from "hookTokens" in bridge/config.json only, for example "hookTokens": { ${JSON.stringify(cleanText(ids[0], 64))}: "<long random text>" }; a webhook not listed there takes the bridge token.`);
  }

  // Skips a change already loaded (by the "Test now" button, see handleGameEvent).
  watchGameConfig() {
    fs.watchFile(this.gameConfigPath, { interval: 1000 }, (cur, prev) => {
      if (cur.mtimeMs !== prev.mtimeMs && `${cur.mtimeMs}:${cur.size}` !== this.gameConfigStamp) this.loadGameConfig();
    });
  }

  // Heartbeat read by the in-game window (connection pill, URLs, recent events). "protocol"
  // tells the window which files this bridge reads (see PROTOCOL), "testNonce" goes back in
  // test_workflow, "session" changes only when bridge-state.json was lost (seqs may repeat).
  // Every mod running in the game can read this file: no token goes in it (the window shows
  // the URLs masked; "node bridge.js url <webhook>" copies them), "hookTokens" lists only the
  // ids of the webhooks with a dedicated token. stopped: last write, when the bridge stops
  // (ts 0 so the window shows it offline at once, and no test code).
  writeStatus({ stopped = false } = {}) {
    const status = {
      ts: stopped ? 0 : Date.now(),
      version: VERSION,
      protocol: PROTOCOL,
      ...(stopped ? { stopped: true } : { testNonce: this.testNonce }),
      session: this.link.state.session || '',
      port: this.base.port,
      publicUrl: this.cfg.publicUrl || '',
      pending: this.link.state.pending.length,
      lastAck: this.link.lastAck,
      webhooks: Object.keys(this.cfg.webhooks),
      hookTokens: Object.keys(this.hookTokens),
      recent: this.recent.slice(0, 15),
    };
    const tmp = this.statusPath + '.tmp';
    try {
      fs.writeFileSync(tmp, JSON.stringify(status));
      fs.renameSync(tmp, this.statusPath);
    } catch { /* the game is reading it; next beat */ }
  }

  remember(entry) {
    this.recent.unshift({ at: new Date().toISOString(), ...entry });
    this.recent.length = Math.min(this.recent.length, 50);
  }

  async runWorkflow(name, vars, source) {
    const skip = (reason) => {
      this.remember({ source, workflow: name, user: vars.user, skipped: reason });
      return { workflow: name, skipped: reason };
    };
    const wf = own(this.cfg.workflows, name);
    if (!wf || typeof wf !== 'object') return skip('unknown workflow');
    if (wf.enabled === false) return skip('disabled');
    if (!test(wf.when, vars)) return skip('condition');
    if (wf.chance !== undefined && wf.chance !== null && Math.random() >= Number(wf.chance)) return skip('chance');

    const now = Date.now();
    const keys = [];
    if (wf.cooldownSeconds) keys.push([`wf:${name}`, wf.cooldownSeconds]);
    if (wf.userCooldownSeconds) keys.push([`wf:${name}:${String(vars.user).toLowerCase()}`, wf.userCooldownSeconds]);
    for (const [key, secs] of keys) {
      if (now - (this.lastRun.get(key) || 0) < secs * 1000) return skip('cooldown');
    }
    keys.forEach(([key]) => this.lastRun.set(key, now));

    const { game, bridge, dropped, truncated } = expand(wf.steps, vars);
    if (dropped || truncated) {
      log(`[${name}] ${dropped} step(s) dropped${truncated ? ', then the rest of the workflow skipped' : ''} (limits per job: ${LIMITS.gameStepsPerJob} game steps, ${LIMITS.bridgeStepsPerJob} http/log steps, ${LIMITS.visitedStepsPerJob} steps and loop turns walked through)`);
    }
    let seq;
    if (game.length) seq = this.link.push(name, game, { user: vars.user }).seq;
    log(`[${source}] ${name} -> ${game.length} game step(s)${seq ? ` (job #${seq})` : ''} user=${vars.user}`);
    this.remember({ source, workflow: name, user: vars.user, job: seq, steps: game.length });

    // Bridge steps (http, log) run in the background: a slow http call must not delay
    // the reply to LibertyTalk (its webhook call gives up after 10 s).
    if (bridge.length) {
      const work = this.runBridgeSteps(bridge, { workflow: name, source, user: vars.user });
      this.pendingBridgeWork.add(work);
      work.finally(() => this.pendingBridgeWork.delete(work));
    }
    return { workflow: name, job: seq, steps: game.length };
  }

  async runBridgeSteps(steps, ctx) {
    for (const action of steps) {
      try {
        await this.runBridgeAction(action, ctx);
      } catch (e) {
        log(`[${ctx.workflow}] ${action.action} failed:`, e.message);
        this.remember({ source: ctx.source, workflow: ctx.workflow, user: ctx.user, error: `${action.action}: ${e.message}` });
      }
    }
  }

  async runBridgeAction(a, ctx = {}) {
    if (a.action === 'log') return log('[log]', a.message ?? a.text ?? '');
    if (a.action === 'http') {
      const req = this.httpRequestFor(a, ctx);
      if (req.refused) {
        log(`[${ctx.workflow}] http step refused: ${req.refused}`);
        this.remember({ source: ctx.source, workflow: ctx.workflow, user: ctx.user, error: `http refused: ${req.refused}` });
        return;
      }
      const hasBody = a.body !== undefined && req.method !== 'GET' && req.method !== 'HEAD';
      const body = hasBody ? (typeof a.body === 'string' ? a.body : JSON.stringify(a.body)) : undefined;
      const headers = { 'Content-Type': 'application/json', ...req.headers };
      if (req.hmacSecret && body) {
        headers[req.hmacHeader || 'X-Signature'] = crypto.createHmac('sha256', String(req.hmacSecret)).update(body).digest('hex');
      }
      // redirect: 'error' so an allowed host cannot bounce the call to another one
      const res = await fetch(req.url, { method: req.method, headers, body, redirect: 'error', signal: AbortSignal.timeout(10000) });
      if (!res.ok) throw new Error(`HTTP ${res.status} from ${req.url.host}`);
    }
  }

  // Where an http step goes and with which secrets: { url, method, headers, hmacSecret,
  // hmacHeader }, or { refused: reason }.
  //   "target": "<name>" -> everything from "httpTargets" of bridge/config.json; the url,
  //     headers and hmac fields of the step are ignored, so a step written by a mod can
  //     neither read these secrets nor send them to another address.
  //   "url" (+ "headers") written in the step -> still sent, with a warning when it carries
  //     headers: talky_config.json can be read by every mod running in the game. An
  //     "hmacSecret" written in the step is refused.
  httpRequestFor(a, ctx = {}) {
    const wf = cleanText(String(ctx.workflow ?? ''), 64);
    if (a.target !== undefined && a.target !== null && a.target !== '') {
      const name = String(a.target);
      const shown = cleanText(name, 64);
      const t = own(this.httpTargets, name);
      if (!isPlainObject(t)) return { refused: `unknown http target "${shown}": add it to "httpTargets" in bridge/config.json` };
      const ignored = ['url', 'headers', 'hmacSecret', 'hmacHeader'].filter((k) => a[k] !== undefined);
      if (ignored.length) {
        this.warnOnce(`target-fields:${wf}`, `[${wf}] http step: ${ignored.map((k) => `"${k}"`).join(', ')} ignored, the step has a "target" ("httpTargets" > "${shown}" of bridge/config.json gives the address and its secrets)`);
      }
      const headers = isPlainObject(t.headers) ? t.headers : {};
      const placeholder = (v) => typeof v === 'string' && /PASTE_|<[^>]*>/.test(v);
      if (placeholder(t.url) || placeholder(t.hmacSecret) || Object.values(headers).some(placeholder)) {
        return { refused: `fill "httpTargets" > "${shown}" in bridge/config.json first (it still holds a placeholder)` };
      }
      const check = checkHttpUrl(t.url, this.allowedHosts);
      // The reason for an invalid URL quotes it, and its path can hold a secret (the token of
      // a LibertyTalk incoming webhook): never in the console
      if (!check.ok) return { refused: /^invalid URL/.test(check.reason) ? `"httpTargets" > "${shown}" > "url" is not a valid URL` : check.reason };
      return { url: check.url, method: String(t.method || a.method || 'POST').toUpperCase(), headers, hmacSecret: t.hmacSecret, hmacHeader: t.hmacHeader };
    }
    if (a.hmacSecret !== undefined && a.hmacSecret !== null && a.hmacSecret !== '') {
      return { refused: '"hmacSecret" written in the workflow: talky_config.json can be read by every mod running in the game. Put the address and the secret in "httpTargets" of bridge/config.json, and write "target": "<name>" in the step' };
    }
    const check = checkHttpUrl(a.url, this.allowedHosts);
    if (!check.ok) return { refused: check.reason };
    const headers = isPlainObject(a.headers) ? a.headers : {};
    if (Object.keys(headers).length) {
      this.warnOnce(`inline-headers:${wf}`, `[${wf}] warning: this http step has "headers" in talky_config.json, a file every mod running in the game can read. Move the address and its headers to "httpTargets" in bridge/config.json, and write "target": "<name>" in the step.`);
    }
    return { url: check.url, method: String(a.method || 'POST').toUpperCase(), headers };
  }

  // A webhook either names its workflow(s) or routes by payload fields.
  async handleWebhook(id, hook, payload, query) {
    const vars = this.varsFor(payload, { webhook: id, query });
    let names = [];
    if (hook.routes) {
      const route = arr(hook.routes).find((r) => r && test(r.when, vars));
      if (route) names = [].concat(route.workflow);
    } else {
      names = [].concat(hook.workflow || []);
    }
    if (!names.length) {
      this.remember({ source: `hook:${id}`, user: vars.user, skipped: 'no matching route' });
      return [{ skipped: 'no matching route' }];
    }
    const results = [];
    for (const name of names) results.push(await this.runWorkflow(name, { ...vars }, `hook:${id}`));
    return results;
  }

  // A broken workflow (unknown filter, bad regex...) is logged and shown on the F8 Status
  // page; the other workflows of the event and the next events still run.
  async runWorkflowSafely(name, vars, source) {
    try {
      return await this.runWorkflow(name, vars, source);
    } catch (e) {
      log(`[${source}] ${name} failed:`, e.message);
      this.remember({ source, workflow: name, user: vars.user, error: e.message });
      return { workflow: name, error: e.message };
    }
  }

  async handleGameEvent(evt) {
    if (!evt || typeof evt !== 'object' || !isEventName(evt.event)) {
      log(`[game] event ignored (no valid "event" name): ${cleanText(JSON.stringify(evt) ?? '', 200)}`);
      return { skipped: 'bad event' };
    }
    const data = evt.data && typeof evt.data === 'object' && !Array.isArray(evt.data) ? evt.data : {};
    // "Test now" button of the in-game window. The window saves talky_config.json just
    // before; the file watcher may not have seen it yet, so read it now.
    if (evt.event === 'test_workflow') {
      const refused = this.checkTestNonce(data);
      if (refused) return { workflow: data.workflow, skipped: refused };
      this.loadGameConfig();
      return this.runWorkflowSafely(data.workflow, this.varsFor(data.vars || {}), 'test');
    }
    if (NO_WORKFLOW_EVENTS.has(evt.event)) return this.jobRefused(evt.event, data);
    const names = [].concat(own(this.cfg.gameEvents, evt.event) || []);
    if (evt.event !== 'job_done') log(`[game] ${evt.event} ${JSON.stringify(data)}`);
    for (const name of names) {
      await this.runWorkflowSafely(name, this.varsFor(data, { event: evt.event }), `game:${evt.event}`);
    }
    return { event: evt.event, workflows: names.length };
  }

  // Returns null when test_workflow carries the nonce of this start, else the refusal reason.
  // Each reason is logged once per start, so a flood of lines does not fill the console. The
  // F8 Status entry carries the reason as "skipped" (the 0.4.0 window translates it:
  // UI_Talky_Skip_no_test_code, UI_Talky_Skip_test_code_mismatch) and an English "error"
  // for older windows.
  checkTestNonce(data) {
    if (typeof data.nonce === 'string' && safeEqual(data.nonce, this.testNonce)) return null;
    const reason = typeof data.nonce === 'string' && data.nonce !== '' ? 'test code mismatch' : 'no test code';
    if (!this.testRefusals.has(reason)) {
      this.testRefusals.add(reason);
      const why = reason === 'no test code'
        ? 'it carries no test code. Talky mods older than 0.4.0 do not send it: update the mod (the bridge and the mod go together).'
        : 'its test code is not the one of this bridge (talky_status.json, new at each start). If the bridge has just restarted, press Test now again.';
      log(`[test] "Test now" refused: ${why} Further refusals of this kind are not logged.`);
      this.remember({
        source: 'test', workflow: cleanText(data.workflow, 64) || undefined, skipped: reason,
        error: `Test now refused: ${reason === 'no test code' ? 'update the Talky mod to 0.4.0' : 'test code mismatch, press Test now again'}`,
      });
    }
    return reason;
  }

  // job_rejected / job_expired: console line, and an entry on the F8 Status page with the
  // reason code ("rejected") for the window and an English text ("error") for older windows.
  // too_large never reached the server: the game on this PC could not send it.
  jobRefused(event, data) {
    const seq = Number.isSafeInteger(data.seq) && data.seq > 0 ? data.seq : undefined;
    let reason = event === 'job_expired' ? 'expired' : data.reason;
    if (typeof reason !== 'string' || !/^[a-z0-9_]{1,32}$/.test(reason)) reason = 'unknown';
    // Workflow and viewer as the bridge recorded them when the job was created
    const origin = seq ? this.recent.find((e) => e.job === seq && !e.rejected) : undefined;
    const workflow = origin?.workflow ?? (cleanText(data.workflow, 64) || undefined);
    const hint = own(REJECT_HINTS, reason) || 'see the [Talky] lines of the server console.';
    const what = `job${seq ? ` #${seq}` : ''}${workflow ? ` (${workflow})` : ''}`;
    const outcome = reason === 'expired' ? 'expired'
      : reason === 'too_large' ? 'not sent to the server: too_large'
        : `refused by the server: ${reason}`;
    log(`[game] ${what} ${outcome} - ${hint}`);
    this.remember({
      source: `game:${event}`, workflow, user: origin?.user, job: seq, rejected: reason,
      error: reason === 'expired' ? 'expired before it could start' : outcome,
    });
    return { event, job: seq, rejected: reason };
  }

  // ---------------------------------------------------------------- polling source
  // Experimental alternative to webhooks when you don't want a public URL: poll the
  // LibertyTalk activity feed (GET https://<tenant>.api.<domain>/community/<id>/activity).
  startPolling() {
    const p = this.base.poll;
    if (!p || !p.enabled) return;
    if (!p.url || /[<>]/.test(p.url) || !p.apiToken || /[<>]/.test(p.apiToken)) {
      log('poll: fill "poll.url" and "poll.apiToken" in config.json first (see README)');
      return;
    }
    let seen = new Set(this.link.state.pollSeen || []);
    let primed = seen.size > 0;
    let busy = false;
    const tick = async () => {
      if (busy) return;
      busy = true;
      try {
        const res = await fetch(p.url, {
          headers: { Accept: 'application/json', ...(p.headers || {}), Authorization: `Bearer ${p.apiToken}` },
          signal: AbortSignal.timeout(10000),
        });
        if (!res.ok) throw new Error(`HTTP ${res.status}`);
        const items = activityItems(await res.json()).slice().reverse(); // newest first -> oldest first
        for (const item of items) {
          if (!item || item.id === undefined || seen.has(item.id)) continue;
          seen.add(item.id);
          const wf = own(p.types, item.type);
          if (primed && wf) {
            await this.runWorkflow(wf, this.varsFor(activityToPayload(item)), `poll:${item.type}`);
          }
        }
        primed = true;
        if (seen.size > 1000) seen = new Set([...seen].slice(-500));
        this.link.state.pollSeen = [...seen].slice(-500);
      } catch (e) {
        log('poll error:', e.message);
      } finally {
        busy = false;
      }
    };
    tick();
    this.pollTimer = setInterval(tick, Math.max(5, Number(p.intervalSeconds) || 10) * 1000);
    log(`polling the LibertyTalk activity feed every ${Math.max(5, Number(p.intervalSeconds) || 10)}s (experimental)`);
  }

  // ---------------------------------------------------------------- http server
  // hookId: the webhook of a /hooks/<id> request. A webhook listed in "hookTokens"
  // (bridge/config.json) takes its dedicated token only; everything else takes the bridge
  // token. A "token" in talky_config.json counts for nothing (see warnHookTokens).
  authorized(req, url, hookId) {
    const given = req.headers['x-bridge-token'] || url.searchParams.get('token');
    const dedicated = hookId === undefined ? undefined : own(this.hookTokens, hookId);
    return safeEqual(given, typeof dedicated === 'string' && dedicated !== '' ? dedicated : this.base.token);
  }

  async handleRequest(req, res) {
    const send = (code, obj) => {
      res.writeHead(code, { 'Content-Type': 'application/json' });
      res.end(JSON.stringify(obj));
    };
    try {
      const url = new URL(normalizePath(req.url), 'http://localhost');
      if (req.method === 'GET' && url.pathname === '/health') {
        if (!this.authorized(req, url)) return send(200, { ok: true });
        return send(200, {
          ok: true, version: VERSION, protocol: PROTOCOL, pending: this.link.state.pending.length,
          lastAck: this.link.lastAck, ackedAbove: this.link.ackedAbove, recent: this.recent,
        });
      }
      const parts = url.pathname.split('/').filter(Boolean);
      const [kind, rawId] = parts;
      if (req.method !== 'POST' || parts.length !== 2 || !['hooks', 'fire'].includes(kind)) return send(404, { error: 'not found' });
      let id;
      try {
        id = decodeURIComponent(rawId);
      } catch {
        return send(404, { error: 'not found' });
      }

      // Token first: without it, every webhook id answers 401, so ids cannot be guessed.
      const hook = kind === 'hooks' ? own(this.cfg.webhooks, id) : undefined;
      if (!this.authorized(req, url, kind === 'hooks' ? id : undefined)) return send(401, { error: 'bad token' });
      if (kind === 'hooks' && (!hook || typeof hook !== 'object')) return send(404, { error: `unknown webhook "${id}"` });

      // Bytes are joined before decoding: a character split between two chunks stays whole.
      const chunks = [];
      let size = 0;
      let tooLarge = false;
      for await (const chunk of req) {
        if (tooLarge) continue; // drain without keeping it
        size += chunk.length;
        if (size > MAX_BODY) {
          tooLarge = true;
          chunks.length = 0;
        } else {
          chunks.push(chunk);
        }
      }
      if (tooLarge) return send(413, { error: 'body too large' });
      const payload = parseBody(Buffer.concat(chunks).toString('utf8'));
      const query = Object.fromEntries([...url.searchParams].filter(([k]) => k !== 'token'));

      const results = kind === 'hooks'
        ? await this.handleWebhook(id, hook, payload, query)
        : [await this.runWorkflow(id, this.varsFor({ ...query, ...payload }), 'fire')];
      send(200, { ok: true, results });
    } catch (e) {
      log('request error:', e.message);
      send(500, { error: e.message });
    }
  }

  listen() {
    const host = this.cfg.host || '127.0.0.1';
    this.server = http.createServer((req, res) => this.handleRequest(req, res));
    this.server.on('error', (e) => {
      if (e.code === 'EADDRINUSE') fail(`Port ${this.cfg.port} is already used. Change "port" in config.json (and in the cloudflared command).`);
      fail(`Cannot listen on ${host}:${this.cfg.port}: ${e.message}`);
    });
    this.server.listen(this.cfg.port, host, () => {
      log(`Talky bridge ${VERSION} listening on http://${host}:${this.cfg.port}`);
      log(`game folder: ${displayPath(this.cfg.zomboidLuaDir)}`);
      log(`http steps allowed to: ${this.allowedHosts.join(', ') || '(none)'}`);
      // Host only: the path of a LibertyTalk incoming webhook is its token
      const targets = Object.entries(this.httpTargets).map(([name, t]) => {
        let host = 'invalid url';
        try {
          host = /PASTE_|<[^>]*>/.test(t.url) ? 'not filled in' : new URL(t.url).host;
        } catch { /* stays "invalid url" */ }
        return `${cleanText(name, 64)} (${host})`;
      });
      if (targets.length) log(`http targets: ${targets.join(', ')}`);
      for (const id of Object.keys(this.cfg.webhooks)) log(`  webhook  POST /hooks/${id}${own(this.hookTokens, id) ? '  (dedicated token)' : ''}`);
    });
  }

  start() {
    this.started = true;
    this.testNonce = newNonce();
    this.testRefusals.clear();
    this.warned.clear();
    this.seedGameConfig();
    this.loadGameConfig();
    this.watchGameConfig();
    this.link.start((evt) => this.handleGameEvent(evt));
    this.writeStatus();
    this.statusTimer = setInterval(() => this.writeStatus(), 2000);
    this.listen();
    this.startPolling();
  }

  // Also runs from the "exit" handler of the process: synchronous only.
  stop() {
    clearInterval(this.statusTimer);
    clearInterval(this.pollTimer);
    fs.unwatchFile(this.gameConfigPath);
    this.link.stop();
    if (this.server) this.server.close();
    // The test code is no longer valid, and the window shows the bridge offline at once
    if (this.started) this.writeStatus({ stopped: true });
    this.started = false;
  }
}

// ------------------------------------------------------------------ CLI

// Vars as JSON or as key=value pairs: fire bits user=Bob bits=500
async function fireCli(cfg, workflow, args) {
  if (!workflow) fail('Usage: node bridge.js fire <workflow> [key=value...]');
  const body = args[0]?.trim().startsWith('{')
    ? args[0]
    : JSON.stringify(Object.fromEntries(args.map((a) => [a.split('=')[0], a.split('=').slice(1).join('=')])));
  const res = await fetch(`http://127.0.0.1:${cfg.port}/fire/${encodeURIComponent(workflow)}`, {
    method: 'POST',
    headers: { 'Content-Type': 'application/json', 'X-Bridge-Token': cfg.token },
    body,
  });
  console.log(res.status, await res.text());
}

// The full URL of a webhook: <public URL>/hooks/<id>?token=<its token>, or "*****" for the
// token when masked. Built here, on the PC, never written to a file the game can read.
// Webhooks, public URL: from talky_config.json, as the bridge loads them (config.json when
// the game file has none). base: a public URL given on the command line instead.
function webhookUrl(cfg, game, id, { base, masked = false } = {}) {
  const webhooks = game.webhooks !== undefined ? (isPlainObject(game.webhooks) ? game.webhooks : {}) : (isPlainObject(cfg.webhooks) ? cfg.webhooks : {});
  const known = Object.keys(webhooks).sort();
  if (!id) return { error: `Usage: node bridge.js url <webhook> [--show] [--base <public URL>]. Webhooks: ${known.map((k) => cleanText(k, 64)).join(', ') || '(none)'}` };
  if (!isPlainObject(own(webhooks, id))) return { error: `Unknown webhook "${cleanText(id, 64)}". Webhooks: ${known.map((k) => cleanText(k, 64)).join(', ') || '(none)'}` };
  const pick = (v) => (typeof v === 'string' && v.trim() !== '' ? v.trim() : undefined);
  const from = base !== undefined ? 'command line' : pick(game.publicUrl) ? 'talky_config.json' : pick(cfg.publicUrl) ? 'config.json' : 'local';
  const raw = base ?? pick(game.publicUrl) ?? pick(cfg.publicUrl) ?? `http://127.0.0.1:${cfg.port}`;
  let url;
  try {
    url = new URL(raw);
  } catch {
    return { error: `The public URL "${cleanText(raw, 200)}" (${from}) is not a URL. Give it with --base https://<your tunnel address>.` };
  }
  if (url.protocol !== 'https:' && url.protocol !== 'http:') return { error: `The public URL (${from}) must start with https://.` };
  const dedicated = own(cfg.hookTokens, id);
  const token = typeof dedicated === 'string' && dedicated !== '' ? dedicated : cfg.token;
  // origin + path: no user:password@, query or #fragment from the stored text
  const prefix = `${url.origin}${url.pathname.replace(/\/+$/, '')}/hooks/${encodeURIComponent(id)}?token=`;
  return {
    url: prefix + (masked ? '*****' : encodeURIComponent(token)),
    masked: `${prefix}*****`,
    host: url.host,
    from,
    tokenName: token === cfg.token ? '"token"' : `"hookTokens" > "${cleanText(id, 64)}"`,
  };
}

function readGameConfigFile(cfg) {
  try {
    const game = JSON.parse(fs.readFileSync(path.join(cfg.zomboidLuaDir, 'talky_config.json'), 'utf8').replace(/^﻿/, ''));
    return isPlainObject(game) ? game : {};
  } catch {
    return {};
  }
}

// node bridge.js url <webhook> [--show] [--base <url>]: the full URL goes to the clipboard,
// the console shows it masked (the window may be on stream). Nothing in the game can ask
// for this copy: game Lua can read the clipboard.
function urlCli(cfg, args) {
  let show = false;
  let base;
  const ids = [];
  for (let i = 0; i < args.length; i++) {
    if (args[i] === '--show') show = true;
    else if (args[i] === '--base') base = args[++i] ?? '';
    else ids.push(args[i]);
  }
  const r = webhookUrl(cfg, readGameConfigFile(cfg), ids[0], { base });
  if (r.error) fail(r.error);
  if (show) {
    console.log(r.url);
    return;
  }
  const where = { 'command line': 'given with --base', 'talky_config.json': 'saved by the F8 window', 'config.json': 'of config.json', local: 'local address: set the public URL in the F8 window, or give it with --base' }[r.from];
  if (copyToClipboard(r.url)) {
    console.log(`copied to the clipboard: ${r.masked}`);
    console.log(`public URL ${where}. Check that ${r.host} is your tunnel before you paste the URL into LibertyTalk.`);
    return;
  }
  console.log(`cannot copy to the clipboard here. URL: ${r.masked} (public URL ${where})`);
  console.log(`the token is ${r.tokenName} in config.json; LibertyTalk can also send it in the X-Bridge-Token header. To print the full URL, add --show (not while this window is on stream).`);
  process.exitCode = 1;
}

const escapeRe = (s) => s.replace(/[.*+?^${}()|[\]\\]/g, '\\$&');

// config.json with a new random token, the rest of the file kept as it is (same layout when
// the "token" line is found, else rewritten from the parsed file). Written to a temporary
// file, then renamed over config.json. Returns the new token, never printed.
function rotateToken(configPath) {
  const text = fs.readFileSync(configPath, 'utf8').replace(/^﻿/, '');
  const cfg = JSON.parse(text);
  if (!isPlainObject(cfg)) throw new Error('it is not a JSON object');
  const token = crypto.randomBytes(24).toString('hex');
  let out;
  if (typeof cfg.token === 'string') {
    const candidate = text.replace(new RegExp(`("token"\\s*:\\s*)${escapeRe(JSON.stringify(cfg.token))}`), (_, key) => key + JSON.stringify(token));
    try {
      const check = JSON.parse(candidate);
      if (check.token === token && isDeepStrictEqual({ ...check, token: cfg.token }, cfg)) out = candidate;
    } catch { /* rebuilt below */ }
  }
  out ??= `${JSON.stringify({ ...cfg, token }, null, 2)}\n`;
  const tmp = `${configPath}.${process.pid}.tmp`;
  try {
    const fd = fs.openSync(tmp, 'w', 0o600);
    try {
      fs.writeSync(fd, out);
      fs.fsyncSync(fd);
    } finally {
      fs.closeSync(fd);
    }
    fs.renameSync(tmp, configPath);
  } catch (e) {
    removeQuietly(tmp);
    throw e;
  }
  return token;
}

function newTokenCli() {
  if (!fs.existsSync(CONFIG_PATH)) fail(`No config at ${displayPath(CONFIG_PATH)}. Start the bridge once (start-bridge.cmd): it creates config.json with a random token.`);
  let token;
  try {
    token = rotateToken(CONFIG_PATH);
  } catch (e) {
    fail(`Cannot give ${displayPath(CONFIG_PATH)} a new token: ${e.message}`);
  }
  const where = copyToClipboard(token) ? 'in your clipboard and in config.json' : 'in config.json ("token")';
  log(`new random token written to ${displayPath(CONFIG_PATH)}: it is ${where}, never shown here`);
  log('restart the bridge (the old token works until then), paste the new token into "Bridge token" in the LibertyTalk widget, and copy your webhook URLs again (node bridge.js url <webhook>). The dedicated tokens of "hookTokens" do not change.');
}

if (require.main === module) {
  const [cmd, ...rest] = process.argv.slice(2);
  if (cmd === 'version' || cmd === '--version') {
    console.log(VERSION);
  } else if (cmd === 'fire') {
    const cfg = loadConfig();
    fireCli(cfg, rest[0], rest.slice(1)).catch((e) => fail(`Is the bridge running? ${e.message}`));
  } else if (cmd === 'url') {
    urlCli(loadConfig(), rest);
  } else if (cmd === 'new-token') {
    newTokenCli();
  } else {
    const configWarnings = [];
    const cfg = loadConfig({ create: true, warnings: configWarnings });
    for (const w of [...configWarnings, ...startupWarnings({ zomboidDir: path.dirname(cfg.zomboidLuaDir), needsTunnel: !(cfg.poll && cfg.poll.enabled) })]) log(`warning: ${w}`);
    const bridge = new Bridge(cfg);
    bridge.start();
    // Ctrl+C, Ctrl+Break, the console window closed: the last status is written on the way
    // out (process.exit runs the "exit" handlers, a signal alone does not)
    process.on('exit', () => bridge.stop());
    for (const sig of ['SIGINT', 'SIGTERM', 'SIGHUP', 'SIGBREAK']) {
      if (os.constants.signals[sig] !== undefined) process.on(sig, () => process.exit(0));
    }
  }
}

module.exports = {
  Bridge, parseBody, normalizePath, activityToPayload, render, hideHome, VERSION, PROTOCOL,
  systemLanguage, newConfigText, createConfig, findOnPath, workshopCopies, startupWarnings,
  REJECT_HINTS, httpTargetsError, hookTokensError, webhookUrl, rotateToken, jobTtl, MAX_JOB_TTL_SECONDS,
};

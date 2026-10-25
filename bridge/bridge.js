#!/usr/bin/env node
// Talky bridge: LibertyTalk webhooks -> Project Zomboid.
//
//   node bridge.js                                start the bridge
//   node bridge.js fire <workflow> [key=value...] trigger a workflow on the running bridge (tests, Stream Deck...)
//   node bridge.js version                        print the version
//
// bridge/config.json            : port, token, allowed http hosts, poll source (secrets stay here).
//                                 Created on the first start from config.example.json, with a
//                                 random token; an existing file is never replaced.
// Zomboid/Lua/talky_config.json : webhooks, workflows, game events, settings - edited by the
//                                 in-game window, reloaded here on every save (seeded from
//                                 config.json on first run)
//
// No dependencies: Node >= 18.

'use strict';

const http = require('http');
const fs = require('fs');
const os = require('os');
const path = require('path');
const crypto = require('crypto');
const { spawnSync } = require('child_process');
const { expand, test, buildVars, render, arr, LIMITS } = require('./lib/engine');
const { GameLink } = require('./lib/ipc');
const { DEFAULT_HTTP_ALLOWED_HOSTS, checkHttpUrl } = require('./lib/hosts');
const { localizeExamples, normalizeLanguage } = require('./lib/examples');

const VERSION = require('./package.json').version;
const CONFIG_PATH = process.env.LT_BRIDGE_CONFIG || path.join(__dirname, 'config.json');
const EXAMPLE_PATH = path.join(__dirname, 'config.example.json');
const MAX_BODY = 65536;

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

// create: on the first start, config.json is created from config.example.json. The
// token is copied to the clipboard and never printed (the window may be on stream).
function loadConfig({ create = false } = {}) {
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

class Bridge {
  constructor(cfg) {
    this.base = cfg;
    this.cfg = cfg;
    this.lastRun = new Map(); // cooldown keys -> timestamp
    this.recent = [];
    this.pendingBridgeWork = new Set();
    // Read from bridge/config.json only: talky_config.json cannot widen it
    this.allowedHosts = Array.isArray(cfg.httpAllowedHosts) ? cfg.httpAllowedHosts : [...DEFAULT_HTTP_ALLOWED_HOSTS];
    this.gameConfigPath = path.join(cfg.zomboidLuaDir, 'talky_config.json');
    this.statusPath = path.join(cfg.zomboidLuaDir, 'talky_status.json');
    this.link = new GameLink({
      luaDir: cfg.zomboidLuaDir,
      // Next to config.json, never in the mod folder (the Workshop rewrites it on update)
      stateFile: path.join(path.dirname(CONFIG_PATH), 'bridge-state.json'),
      jobTtlSeconds: cfg.jobTtlSeconds ?? 900,
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
  }

  // Skips a change already loaded (by the "Test now" button, see handleGameEvent).
  watchGameConfig() {
    fs.watchFile(this.gameConfigPath, { interval: 1000 }, (cur, prev) => {
      if (cur.mtimeMs !== prev.mtimeMs && `${cur.mtimeMs}:${cur.size}` !== this.gameConfigStamp) this.loadGameConfig();
    });
  }

  // Heartbeat read by the in-game window (connection pill, URLs, recent events).
  writeStatus() {
    const status = {
      ts: Date.now(),
      version: VERSION,
      port: this.base.port,
      token: this.base.token,
      publicUrl: this.cfg.publicUrl || '',
      pending: this.link.state.pending.length,
      lastAck: this.link.lastAck,
      webhooks: Object.keys(this.cfg.webhooks),
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
      const check = checkHttpUrl(a.url, this.allowedHosts);
      if (!check.ok) {
        log(`[${ctx.workflow}] http step refused: ${check.reason}`);
        this.remember({ source: ctx.source, workflow: ctx.workflow, user: ctx.user, error: `http refused: ${check.reason}` });
        return;
      }
      const method = String(a.method || 'POST').toUpperCase();
      const hasBody = a.body !== undefined && method !== 'GET' && method !== 'HEAD';
      const body = hasBody ? (typeof a.body === 'string' ? a.body : JSON.stringify(a.body)) : undefined;
      const headers = { 'Content-Type': 'application/json', ...(a.headers && typeof a.headers === 'object' ? a.headers : {}) };
      if (a.hmacSecret && body) {
        headers[a.hmacHeader || 'X-Signature'] = crypto.createHmac('sha256', String(a.hmacSecret)).update(body).digest('hex');
      }
      // redirect: 'error' so an allowed host cannot bounce the call to another one
      const res = await fetch(check.url, { method, headers, body, redirect: 'error', signal: AbortSignal.timeout(10000) });
      if (!res.ok) throw new Error(`HTTP ${res.status} from ${check.url.host}`);
    }
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
    // "Test now" button of the in-game window. The window saves talky_config.json just
    // before; the file watcher may not have seen it yet, so read it now.
    if (evt.event === 'test_workflow') {
      this.loadGameConfig();
      const { workflow, vars } = evt.data || {};
      return this.runWorkflowSafely(workflow, this.varsFor(vars || {}), 'test');
    }
    const names = [].concat(own(this.cfg.gameEvents, evt.event) || []);
    if (evt.event !== 'job_done') log(`[game] ${evt.event} ${JSON.stringify(evt.data || {})}`);
    for (const name of names) {
      await this.runWorkflowSafely(name, this.varsFor(evt.data || {}, { event: evt.event }), `game:${evt.event}`);
    }
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
  authorized(req, url, hook) {
    const given = req.headers['x-bridge-token'] || url.searchParams.get('token');
    return safeEqual(given, hook?.token || this.cfg.token);
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
        return send(200, { ok: true, version: VERSION, pending: this.link.state.pending.length, lastAck: this.link.lastAck, recent: this.recent });
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
      if (!this.authorized(req, url, hook)) return send(401, { error: 'bad token' });
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
      for (const id of Object.keys(this.cfg.webhooks)) log(`  webhook  POST /hooks/${id}`);
    });
  }

  start() {
    this.seedGameConfig();
    this.loadGameConfig();
    this.watchGameConfig();
    this.link.start((evt) => this.handleGameEvent(evt));
    this.writeStatus();
    this.statusTimer = setInterval(() => this.writeStatus(), 2000);
    this.listen();
    this.startPolling();
  }

  stop() {
    clearInterval(this.statusTimer);
    clearInterval(this.pollTimer);
    fs.unwatchFile(this.gameConfigPath);
    this.link.stop();
    if (this.server) this.server.close();
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

if (require.main === module) {
  const [cmd, ...rest] = process.argv.slice(2);
  if (cmd === 'version' || cmd === '--version') {
    console.log(VERSION);
  } else if (cmd === 'fire') {
    const cfg = loadConfig();
    fireCli(cfg, rest[0], rest.slice(1)).catch((e) => fail(`Is the bridge running? ${e.message}`));
  } else {
    const cfg = loadConfig({ create: true });
    for (const w of startupWarnings({ zomboidDir: path.dirname(cfg.zomboidLuaDir), needsTunnel: !(cfg.poll && cfg.poll.enabled) })) log(`warning: ${w}`);
    new Bridge(cfg).start();
  }
}

module.exports = {
  Bridge, parseBody, normalizePath, activityToPayload, render, hideHome, VERSION,
  systemLanguage, newConfigText, createConfig, findOnPath, workshopCopies, startupWarnings,
};

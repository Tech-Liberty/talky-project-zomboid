# Changelog

## 0.3.0 (2026-10-25)

First public version, published on GitHub and prepared for the Steam Workshop.

### Bridge
- On its first start, the bridge creates `bridge/config.json` from `config.example.json`: random token of 48 hexadecimal characters, `settings.language` set to `fr` when the locale of the system is French (`en` otherwise), atomic write without BOM. On Windows, the token is copied to the clipboard; it is never printed in the console. An existing `config.json` is never replaced.
- Startup warnings (the bridge starts anyway): cloudflared missing from the PATH (with the `winget` command), Talky installed both in `Zomboid\mods\Talky` and from the Steam Workshop, bridge folder inside `Zomboid\mods`.
- `//hooks/follow` is read as `/hooks/follow`: a bridge URL pasted with a trailing `/` no longer breaks the webhook calls.
- `bits`, `viewers`, `total`, `amount` and `tier` sent as strings by LibertyTalk (`"500"`) become numbers before conditions and filters run. Numeric filters (`div`, `mul`, `clamp`...) also read `"4,50"` and `"1 000"`.
- New `httpAllowedHosts` list in `bridge/config.json` (default `["*.liberty-talk.com"]`). An `http` step to another host is refused and logged. The list cannot be changed from `talky_config.json`, a file other mods can write to.
- Caps applied before a job reaches the game: `wait` at most 600 s, `notify` / `say` / `halo` texts at most 200 characters, banners at most 60 s, `repeat` at most 100 iterations, 500 game steps and 20 `http` / `log` steps per job.
- A webhook id only answers 404 after the token is checked: without a valid token every id gets 401, so webhook names cannot be guessed.
- `http` and `log` steps run in the background and no longer delay the reply to LibertyTalk. Redirects are not followed.
- The name used for anonymous events comes from `settings.anonymousName`, or `Anonymous` / `Anonyme` depending on `settings.language`.
- On the first run with `settings.language: "fr"`, the example workflows are written in French.
- Poll mode fixed (reads `items`, URL without `/api`, type `subscribe_gift`, `bits` / `viewers` / `total` filled from `amount`). It stays experimental: it was not tested against a live LibertyTalk instance.
- `bridge-state.json` is written next to `config.json`. The console shows `~` instead of the Windows user folder. A busy port gives a clear message.
- `package.json` (name `talky-bridge`, Node 18 or later), `npm start`, `npm run fire`, `npm test`, and `node bridge.js version`.
- New example workflow `report_to_libertytalk` (disabled), which sends game events to a LibertyTalk incoming webhook with `X-Webhook-Secret`.
- Example `chat_zombie`: no more `when` on the command name (LibertyTalk filters the command, and the widget lets the streamer choose it), no more per-viewer cooldown (the widget does not send the viewer name, so it acted as a 5 minute global cooldown) and no more `crawl` branch on `args` (the widget does not send the text typed after the command). It spawns one zombie with the name of anonymous events.
- Example `points_zombie`: named after the viewer who redeemed the reward, no longer after the text typed with the reward (the widget does not send `user_input`).
- One job walks through 10 000 steps and loop turns at most, and stops as soon as its game and `http` / `log` lists are both full: nested `repeat` steps no longer freeze the bridge.
- "Test now" in the F8 window reads `talky_config.json` before running: a workflow saved a moment before runs in that version (it used to run the previous one, or answer "unknown workflow").
- A game-event workflow that fails (unknown filter, bad regex...) is logged and shown on the F8 Status page. The other events read in the same batch still run.
- A `talky_config.json` saved from F8 before the first launch of the bridge, with no webhook and no workflow, gets the examples of `config.json`; its public URL and settings are kept.
- Webhook bodies are decoded once complete, so an accented character split between two network packets stays whole. The 64 KB limit counts bytes.
- `{{x | toString}}` or a condition `{"x": {"constructor": 1}}` give "unknown filter" / "unknown operator" instead of running a built-in JavaScript function.
- Every message of the bridge, errors about `config.json` included, shows `~` instead of the Windows user folder.

### Mod
- Interface translated: English by default, French complete (`media/lua/shared/Translate/{EN,FR}/UI.json`), including the F8 window, the action forms, the settings and the banners. Mod name and description translated (`Mod.json`).
- "Copy URL" uses the webhook's own token when it has one (it used to copy the global token, which the bridge refused with 401).
- `require "Talky/TalkyJson"` fixed (the file is `Talky_Json.lua`).
- Same caps as the bridge: `wait` 600 s, texts 200 characters, banners 60 s, zombie names 60 characters, 200 jobs waiting at most.
- Settings page: language of the bridge texts and name for anonymous events.
- The Status page shows the bridge version and the bridge errors (refused `http` step...).
- The dedicated token of a webhook (F8 > Webhooks) is typed in a masked field, so it stays off stream.
- `mod.info`: English description, poster, GitHub URL, author Tech Liberty.

### Distribution
- `install.ps1` removed: the bridge sets itself up on its first start (see Bridge). Installing is now: the mod from the Steam Workshop, or the `Talky` folder of the zip copied by hand to `%USERPROFILE%\Zomboid\mods`; the zip extracted to a folder you keep (not `Zomboid\mods`); then a double-click on `start-bridge.cmd`.
- `start-bridge.cmd` replaces `start-bridge.bat`, checks Node.js 18 or later and explains what to do when it is missing. It no longer requires `bridge\config.json`.
- `tools/build-workshop.ps1` assembles the Workshop folder, `tools/build-release.ps1` builds the release zip and its SHA-256 sum.
- MIT license, English and French READMEs.
- `poster.png` and `preview.png` are provisional images, to be replaced before the Workshop release.

### Known limits
- Solo or host only.
- Tested with a simulated game API (Lua run in Kahlua outside the game). Name tags position, zombie aggro, `testHelicopter()` outside debug mode, weather stages and the custom key binding still need a check in a real game.

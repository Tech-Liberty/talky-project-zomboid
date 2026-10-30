# Changelog

## 0.5.0 (2026-10-29)

Server mode: on a server, the bridge runs on the machine of the server, and the streamers install nothing but the mod. The relay of 0.4.0 (a bridge and a tunnel on each streamer's PC, jobs relayed to the server by the streamer's game) is gone. Single player works as before. Update the mod and the bridge together, on the server and on every PC.

### Changes that break a 0.4.0 setup
1. On a server, a streamer's own bridge no longer reaches the game: the streamer's game reads no inbox and sends no job. The admin runs one bridge in server mode next to the server (`start-bridge.sh` on Linux, `start-bridge.cmd server` on Windows), adds the streamers in F8 > Webhooks, and gives each one the public address of the bridge and their token, to paste into the LibertyTalk widget.
2. The sandbox options `Talky.AllowedPlayers` and `Talky.AllowAdmins` are removed. The streamers of F8 > Webhooks get the effects; the roles with the CreateHorde capability (admin and moderator by default) manage Talky.
3. The client commands `hello` and `jobs` of the 0.4.0 protocol are gone; a 0.4.0 client gets no answer. The refusal reasons `not_allowed`, `duplicate` and `too_large` no longer exist; a job for a player who is not a streamer gives `not_streamer`.
4. The release zip is `Talky-<version>.zip` (Windows and Linux), no longer `-windows.zip`.

### Server mode
- `"mode": "server"` in `bridge/config.json`, or `--server` on the command line (`--solo` the other way). The first start with `--server` creates `config.json` in server mode. `start-bridge.sh` (Linux, server mode by default), `start-bridge.cmd server` (Windows), and `talky-bridge.service`, an example systemd unit.
- The bridge listens on `0.0.0.0` in server mode (`host` empty: `127.0.0.1` in solo mode, `0.0.0.0` in server mode; a loopback host in server mode prints a warning, for a reverse proxy). In clear text: the README says that the token travels in clear, and how to put https in front (reverse proxy). Slow connections are closed (10 s for the headers, 15 s per request), 64 connections at most; an error answers `internal error` without its text.
- One token per streamer, drawn by the bridge (48 hexadecimal characters), kept in `bridge/streamers.json` (permissions 600) and copied to `Zomboid/Lua/talky_streamers.json` for the server code. The bridge never reads that copy back and rewrites it at every start. 200 streamers at most; usernames of 1 to 64 characters, A-Z not case-sensitive.
- `/hooks/<id>` takes the token of a streamer only, and that token names the streamer: the job carries `target`. `/fire/<workflow>` takes the token of a streamer, or the bridge token with `streamer=<username>` (`node bridge.js fire <workflow> streamer=<username>`). `node bridge.js url <webhook> --streamer <username>`.
- Requests of the server in the outbox: `streamer_add`, `streamer_remove`, `streamer_token` `{ name, by }`. They never run a workflow, and are ignored in solo mode (one warning). A token is never printed.
- Game events carry `streamer`: their workflows run for that streamer ({{streamer}} in the templates). An event without streamer (`game_started` of a server) runs only the `http` and `log` steps of its workflows. A Test now of an admin who is not a streamer gives a job marked `test`.
- Cooldowns count per streamer in server mode.
- `talky_status.json`: `mode`, the number of streamers in server mode; protocol 3. `/health` gives the mode. `publicUrl` in `config.json` (the address given to the streamers); the one of `talky_config.json` wins only when it is not empty.
- `hookTokens` and the poll mode are ignored in server mode (one warning each).

### Mod
- The server code reads the jobs itself (`server/Talky/Talky_Inbox.lua`), in single player and on a server: inbox, ack line `S s1 s2 ...`, checks of the steps, queue, refusals, results written to the outbox (`job_done`, `action_failed`, `job_rejected`, `job_expired`, `zombie_killed`, custom `emit` steps), with `streamer` in server mode. Only `server/Talky/Talky_Files.lua` opens files, and only Talky's own names.
- Server mode: a job runs only for a streamer of `talky_streamers.json` (`server/Talky/Talky_Streamers.lua`), or as a test for an admin online. A job for nobody, or for a player who is not a streamer, is refused for good (`not_streamer`). A streamer removed during the game loses their waiting and running jobs (checked once a second). The jobs of a streamer offline wait, within their time to live; after 15 minutes offline they are dropped with `job_expired`.
- Busy or rate limited: the job stays in the inbox and is read again (the next second, or when the minute ends), the jobs of the same streamer behind it too; the other streamers go on.
- The server writes `game_started { mode = "server" }` when it starts and `player_died { streamer, hoursSurvived, zombieKills }` when a streamer dies (read every second: `OnPlayerDeath` does not exist on a server).
- `emit` steps are written where the job runs, with their `data` (8 KB at most). They may not write `test_workflow`, `game_started`, `player_died`, `job_rejected`, `job_expired` nor the streamer requests (`action_failed` with `invalid`).
- `heal` checks on the server that the character is alive (`dead` otherwise); the client no longer writes anything for it.
- Admin commands of the server (`streamers`, `streamer`, `config`, `saveConfig`, `test`), checked at every command with the CreateHorde capability; `status` for every player. The tokens of the streamers only go to an admin who asks for them. The configuration goes through the network as a table (size checked against the 1,000,000-byte packet buffer and the 32,767-byte strings).
- Removed: the relay of `client/Talky/Talky_Bridge.lua` (inbox, pending jobs, resends, batches, size estimate of a job, `hello`, `jobAcks`, `emitStep`, the 60-lines-a-minute budget), the `emit` / `emitStep` / `helloAck` / `jobAcks` handlers of the client, `Talky_Server.acceptJob` and the `hello` / `jobs` commands, the sandbox options `AllowedPlayers` and `AllowAdmins`, `Talky_Config.protocolVersion` and `jobsPerBatch`, and their texts. The client of single player writes only `game_started`, `player_died` and `test_workflow`.

### F8 window
- Multiplayer: the window asks the server (`client/Talky/Talky_Remote.lua`): its answer, whether the player is a streamer or an admin, the state of the bridge of the server (offline, solo mode, older than 0.5.0), the limits, the last events of the bridge for the admins.
- Webhooks, for the admins: **Streamers** tab (public address of the bridge, the list, + Add streamer, the two values of the widget of the selected streamer with the token masked, Show token, Copy URL and token, New token, Remove) and **Webhooks** tab (the webhooks of the server). Workflows, Game events and the settings of the bridge edit the `talky_config.json` of the server, loaded from it and saved to it; Test now runs around the admin. A player who is not an admin sees "Reserved to the admins of this server"; the host of a game who is not admin gets Allow me (host) there.
- Multiplayer settings: the display settings (names above zombies, banners) are those of the server's `talky_config.json`, set by an admin in F8 > Settings. Every player gets them with the status and again as soon as an admin saves (`display` command); the other players see them read only. The caps are the server's, read only. The game of a player writes no file.
- New and shorter texts in EN and FR `UI.json`, so that each line fits the window.

### Tests
- Lua: the relay scenarios are replaced by server mode ones: the routing of a job to the streamer its token named, offline streamers, a streamer added, removed or given a new token by an admin (and refused for a player who is not admin), Test now of an admin, the configuration loaded and saved from the window, the F8 pages for an admin and for a player in EN and FR, the 0.4.0 relay absent (no `jobs`, `hello`, `jobAcks`, `emitStep`, `AllowedPlayers`), a hosted game where the host adds a friend. A client never opens a file of the bridge; the server and single player open only Talky's own files.
- Bridge: server mode in the bridge and in real bridge processes started with `--server` (streamer requests, routing by token, `/fire` with a streamer, game events with a streamer, old events skipped, first start with `--server`, startup warnings).
- `& tools\test-lua.ps1` runs the Lua tests from PowerShell.

### Packaging
- Steam Workshop item `3830066321`. The Workshop preview and the poster of the mod list use the talkie-walkie logo of the LibertyTalk widget.
- F8 > Workflows: the buttons of the test line are sized to their text ("Tester maintenant" was hidden under "Workflow en JSON" in French).

### Known limits
- The machine of the server must be reachable on the port of the bridge (or through a reverse proxy or a tunnel); a rented server without Node.js cannot run it.
- Tested in a real game on 2026-10-30 (Build 42.21, real Twitch events through LibertyTalk): single player end to end, helicopter and weather stages included; a dedicated server started with `-cachedir`, with Talky from the Workshop (server code reading and writing `Zomboid/Lua`, admin window, a streamer added, a chat command run by the server, `player_died` on the server). Not yet checked in a real game: a hosted game and **Allow me (host)**, LibertyTalk calling an `http://<IP>:<port>` address (LibertyTalk accepts it), `getServerName()` on a server, and the checks listed for 0.4.0 that the README still lists.

## 0.4.0 (2026-10-26)

Talky runs on servers: hosted games and dedicated servers. Update the mod and the bridge together, and install the same mod version on the server and on every client.

### Changes that break a 0.3.0 setup
1. A dedicated webhook token typed in the F8 window of 0.3.0 is ignored: the bridge reads dedicated tokens from `hookTokens` in `bridge/config.json` only (`talky_config.json` can be written by every game mod). The webhook takes the bridge token, and the LibertyTalk URLs that carry the old dedicated token get `401 bad token` until the token is moved to `hookTokens` and the bridge restarted. The bridge window names each webhook concerned at start.
2. An `http` step with `hmacSecret` written in `talky_config.json` is refused. Put the address and the secrets in `httpTargets` of `bridge/config.json` and write `"target": "<name>"` in the step.
3. `talky_status.json` no longer holds the token (every game mod can read it; on a server, every mod of the server's list).
4. New bridge commands `node bridge.js url <webhook> [--show] [--base <url>]` and `node bridge.js new-token` (npm scripts `url` and `new-token`): the full URL of a webhook and a new token are only given there.
5. The "Copy URL" buttons of F8 copy the command `node bridge\bridge.js url <webhook>`, to run in the Talky folder, instead of a URL with its token.

### Multiplayer
- New server code in `media/lua/server/Talky/` (`Talky_Server`, `Talky_ServerRunner`, `Talky_Tags`). The streamer's game reads the jobs of its bridge and sends them to the server (module `Talky`). The server checks them, runs them around the streamer's character and answers. Every player sees the effects in the world.
- Hosted games work. In 0.3.0 the effects ran in the host's game, which is a client of a separate server process, so most of them did not reach the world.
- The bridge stays on the streamer's PC. Nothing runs on the server machine apart from the mod, and the server code never reads or writes files: in a hosted game, the server shares `Zomboid/Lua` with the host's game, and only the host's game reads the jobs.
- Handshake: the game sends `hello` every 3 s until the server answers (2 minutes at most), and sends jobs only once the server allows them. A protocol version mismatch stops the relay and is shown on F8 > Status. Jobs go by 10 per message; a job without answer is sent again every 30 s until its time to live ends.
- Who may use Talky on a server: roles with the CreateHorde capability (admin and moderator by default) when `Talky.AllowAdmins` is on, and the usernames listed in `Talky.AllowedPlayers`. The sender is the player of the connection, never a name taken from the message. A refused player is asked again every 30 s, so a permission given during the game applies without reconnecting. `Talky.AllowedPlayers` takes usernames separated by commas or semicolons: a space is part of a name, and only A to Z ignore case, as for the account names of the game.
- The permission and the category toggles are checked again on every tick for the jobs already accepted: a player taken off the list loses their waiting and running jobs (`job_rejected`, `not_allowed`), and the steps of a category turned off give `action_failed` with `disabled`.
- Hosted game: the host's account is not admin by default. F8 > Status explains it and offers an "Allow me (host)" button, which sends `/setaccesslevel "<username>" admin`.
- 34 sandbox options on a "Talky" page (`media/sandbox-options.txt`, EN and FR `Sandbox.json`): access, zombies per action, per job and per 10 minutes (per player and for all players), spawn distance, steps per job, waiting and running jobs per player, jobs per minute, one toggle per category (zombies, items, vehicles, XP, heal and stats, weather, time, fire, helicopter, sounds), budgets per 10 minutes for items, vehicles and XP, forbidden items, server-wide cooldowns for weather, thunder, time and helicopter, noise radius, distance from other players, banner audience, actions of other mods. A world created before 0.4.0 uses the defaults.
- Fire and the helicopter are off by default on a server. The helicopter, which the game sends to a random player, only runs while one player is online unless `Talky.HelicopterAnyTarget` is on. With fire off, zombies spawn without fire.
- No Talky zombie, fire or vehicle appears within `Talky.ProtectRadius` (15 tiles) of another online player, nor in a safehouse the streamer may not enter. Vehicles only from the ground floor.
- Fixed limits on a server: 50 waiting and 12 running jobs for all players, 10 zombies created per tick for the whole server, 100 items and 1000 XP per action, 12 game hours of weather per action, 900 s of `wait` per job, 10 `fire` steps per player and 20 for the whole server per 10 minutes, 60 `noise` and `sound` steps per player per 10 minutes, 12 `say` lines a minute per player and 60 for the whole server (beyond, the line shows above the character without going to the chat), 5 commands per second per player. Single player has none of the fire, sound and `say` budgets.
- A job lives 15 minutes at most after the bridge created it, sooner when `jobTtlSeconds` of the bridge ends first; the bridge brings a larger `jobTtlSeconds` back to 900.
- Every value of a job is checked on the server: only the known parameters of each step are kept, numbers are parsed strictly (`NaN`, `inf`, `1e308` and texts ending in "nan" give the default), texts are cut (names 40 characters, texts 200), colors must be `#rrggbb`, item and vehicle types must exist in the game scripts, XP only goes to skills (not to `Perks.None`, `MAX` or the categories) and in whole amounts (a value below 1 gives `action_failed` with `invalid`; single player keeps the fractions).
- Each effect runs where the game expects it: world effects on the server; `heal` on the streamer's game; `stat` on the server, then sent to the player; `say` through the "say" chat; weather and storms through the server's climate updates; sounds heard by nearby players.
- Answers: `not_allowed`, `invalid`, `unknown_action`, `disabled` and `expired` are final (the job is acknowledged so the bridge drops it, `job_rejected` is written, a banner shows the reason); `duplicate` counts as accepted; `busy` and `rate_limited` make the game send the job again later, in order. A job too large for one network message of the game is never sent: the streamer's game acknowledges it and reports `job_rejected` with `too_large`.
- `action_failed`: a step that cannot be read comes with the action `step` and the code `invalid`; `refused` also means that the game created none of the zombies of a step.
- Names above zombies: the server keeps a list (128 names, 32 per streamer, 30 minutes) and sends each change to every player; players who join later receive the whole list. Names of dead, despawned or reused zombies are removed every second.
- `zombie_killed` is sent by the server to the game of the streamer whose job spawned the zombie, once per zombie (a zombie on fire used to trigger it twice).
- Banners can be shown to every player (`Talky.BannerAudience` = 2), with the streamer's name in front; 6 a minute per streamer and 20 a minute in all, `notify` banners and named zombie deaths counted together, the others go to the streamer only.
- From the server, the game writes only `zombie_killed`, `job_done`, `action_failed`, `job_rejected` and `job_expired`, with fixed fields, 60 lines a minute at most. `emit` steps are written from the game's own copy of the job. `test_workflow`, `game_started` and `player_died` only come from the game itself.
- Console lines of the server are limited per player and per reason. The server prints `[Talky] server ready (Talky 0.4.0, protocol 1)` when it starts.
- `Talky_Actions.lua` moved to `shared/`; the client runner (`Talky_Runner.lua`) is replaced by the server runner, which single player uses too. `Talky_Actions.register(name, fn, opts)`: on a server, an action of another mod runs only with `opts.network = true` and the option `Talky.AllowCustomActions`, and receives only its declared `opts.params`.

### Fixed
- Game events and **Test now** reach the bridge again. Since game version 42.20.1, mods may only write `.ini`, `.cfg`, `.txt`, `.log` and `.json` files: `talky_outbox.jsonl` was never written, so `zombie_killed`, `player_died`, `game_started`, `job_done`, `action_failed` and **Test now** were lost. The outbox is now `talky_outbox.txt`.
- Weather: the current weather stops before a new one starts. A storm used to be refused while it rained.
- `talky_ack.txt` is now `S` or `S s1 s2 ...`: every job up to `S` is taken, and `s1`, `s2`... too. An answer that arrives before the one of an older job no longer makes the bridge drop the older job. A 0.3.0 bridge still reads `S`.
- A color that is not `#rrggbb` no longer breaks the names above zombies.
- The values of `talky_config.json` are clamped to the bounds of the F8 window when the game reads them.

### Single player
Single player keeps the caps of F8 > Settings and has no sandbox limit, budget, category toggle or cooldown. Differences with 0.3.0:
- Zombie names are cut at 40 characters (60 before).
- At most 10 zombies are created per tick: a large horde appears over a few ticks.
- Banners, `say`, `halo` and `emit` steps appear one tick later.
- With 200 jobs waiting, a new job stays in the bridge and is sent again a few seconds later instead of being dropped.
- A job that waits past its time to live (15 minutes at most) before it can start is dropped, and the bridge receives `job_expired`.
- `item` and `script` must exist in the game scripts; `stat` accepts the 24 stat names of the game; `Perks.None` and `Perks.MAX` are refused.
- `game_started` carries `{mode, host, server}` instead of no data.
- `action_failed` carries a `code` (`cooldown`, `no_square`, `not_found`...) and `error` with the same value, instead of an error text.
- An action registered by another mod receives `job = {seq, id, workflow, user}` as third argument instead of the raw job.

### Bridge
- Reads `talky_outbox.txt`, and still `talky_outbox.jsonl` (mod 0.3.0).
- Reads the ack line `S s1 s2 ...`; `/health` returns `protocol` and `ackedAbove`.
- `talky_status.json` carries `protocol` (2) and a test code (`testNonce`) drawn at each start. `test_workflow` runs only with that code. Otherwise F8 > Status shows "skipped: no test code (update the mod)" (mod older than 0.4.0) or "skipped: test code mismatch, press Test now again" (the bridge restarted after the window read the code); the entry also carries an English `error` for windows older than 0.4.0. Each kind of refusal is explained once per start in the bridge window. The code only stops `test_workflow` lines a Talky server would have the game write: a game mod can read it.
- `talky_status.json` no longer holds the token, and lists in `hookTokens` the ids of the webhooks that have a dedicated token.
- Dedicated webhook tokens come from `hookTokens` in `bridge/config.json` (16 characters or more); a `token` of a webhook in `talky_config.json` is ignored, with one warning per webhook at start.
- `http` steps can name a target, `"target": "<name>"`, of `httpTargets` in `bridge/config.json`, which holds the address, the headers and the HMAC secret; the example workflow `report_to_libertytalk` uses the target `lt_report`. A target that still holds a `PASTE_...` placeholder is refused. In a step without target, `hmacSecret` is refused and `headers` are sent with a warning.
- `node bridge.js url <webhook>` puts the full URL of a webhook in the clipboard and prints it masked (`--show` prints it, `--base <url>` sets the public URL). `node bridge.js new-token` writes a new random token in `config.json`, the rest of the file unchanged, and puts it in the clipboard without printing it.
- `jobTtlSeconds` above 900 (or not a number) is brought back to 900, with one warning at start: the game and the server drop a job 15 minutes after the bridge created it.
- A bridge that lost `bridge-state.json` but finds an inbox or an ack file starts its job numbers 1000 above every number in them, so a late answer of the server for an old job cannot acknowledge a new job that took its number. The highest number of the inbox also counts when the state file is behind it.
- New game events `job_rejected {seq, workflow, reason}` and `job_expired {seq, workflow}`: printed with what to do, shown on F8 > Status, and never run a `gameEvents` workflow. `too_large` is printed as "not sent to the server".
- Game events with no valid name are ignored; texts from the game are cleaned of control characters before they reach the console.

### F8 window
- Status: single player or multiplayer, the answer of the server, its limits, the categories it turned off, the jobs without answer, the last refused job, the "Allow me (host)" button for the host, and a warning when the bridge is older than 0.4.0.
- Settings: in multiplayer, the three caps show the values of the server, read only.
- Test now sends the test code read from `talky_status.json`.
- No token in the window: the URLs of the Status page show `?token=*****`, the **Copy command** buttons (Status and Webhooks) copy `node bridge\bridge.js url <webhook>` and refuse a webhook id with other characters than A-Z, a-z, 0-9, `-` and `_`. The masked token field of the Webhooks page is replaced by a read-only line: dedicated token or not (from `hookTokens` of `talky_status.json`), set in `bridge/config.json` > `hookTokens`.
- New texts in EN and FR `UI.json`.

### Tests
- `tools\test-lua.ps1` needs a JDK 25 or later (the classes of game 42.21 are Java 25 classes) and also finds the `java` folder of a dedicated server installed alone.
- The Lua tests run one Lua state per game process (single player game, dedicated server with several clients, hosted game) and copy the messages between them with the game's own network serializer (`zombie.network.TableNetworkUtils`). The scenarios are split into `tools/lua-test/test_*.lua`.

### Distribution
- `mod.info`: `versionMin=42.20.1`, `modversion=0.4.0`, description for single player, hosted game and dedicated server. Same description in `Mod.json`.
- Steam Workshop description: multiplayer section, tag `Multiplayer`.
- READMEs: new "Multiplayer" section (install on a server, who may use Talky, every server option with its default and range, refused and delayed jobs, limits, checks still to do in a real game).

### Known limits
- The bridge must run on the streamer's PC; a server cannot read the jobs of a bridge on its own machine.
- Weather and time of day are the same for every player. On a server, a blizzard or a tropical storm reaches the other players at the next climate update (up to 10 game minutes), a time change within about 10 seconds.
- Names above zombies are lost when the zombie despawns, is reused by the game, after 30 minutes or when the server restarts.
- Events of a streamer who is offline are lost; the jobs of a streamer offline for 15 minutes are dropped.
- Tested with a simulated game API (Lua run in Kahlua outside the game): single player, a dedicated server with several clients, a hosted game. Still to check in a real game: `heal` and `stat` in multiplayer, names above zombies in multiplayer, the target of the helicopter on a server, the delay of blizzard and tropical storm on a server, the delay of a time change, the "Allow me (host)" flow, `say` through the chat, items on the ground on a server, the vehicle type check, the role and safehouse checks of the server code, the empty default of the text options. The checks listed for 0.3.0 still apply.

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
- Single player only. The README said "solo or host", but in a hosted game the host's game is a client of a separate server process, and the effects of 0.3.0 did not reach that server (see 0.4.0).
- Tested with a simulated game API (Lua run in Kahlua outside the game). Name tags position, zombie aggro, `testHelicopter()` outside debug mode, weather stages and the custom key binding still need a check in a real game.

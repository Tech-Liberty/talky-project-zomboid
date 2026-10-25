# Talky: LibertyTalk live events for Project Zomboid (Build 42)

[Version française](README.fr.md)

Talky connects [LibertyTalk](https://liberty-talk.com) to Project Zomboid. A follow, a sub, bits, a raid, a channel point redemption or a Super Chat on your stream runs a workflow in your game: a zombie named after the new follower, a horde sized by the raid, the helicopter for 1000 bits. The game sends its own events back ("a named zombie died", "the player died"), and they can run workflows too, including a call to LibertyTalk.

```
LibertyTalk                       your PC
+--------------+   HTTPS    +--------------+   files    +-------------------+
| trigger      |----------->| tunnel       |----------->| Project Zomboid   |
| (follow...)  |  webhook   |   |          |   inbox    | Talky mod (Lua)   |
|   |          |   call     | bridge.js    |<-----------| F8 window         |
| widget       |            | (workflows)  | ack/outbox |                   |
+--------------+            +--------------+            +-------------------+
```

**Why a bridge?** The Lua of Project Zomboid (Kahlua) cannot open a network connection. It can only read and write files in `%USERPROFILE%\Zomboid\Lua\`. The bridge is a small Node.js program without dependencies: it receives the webhooks, runs the logic (conditions, random picks, cooldowns, templates) and writes jobs that the mod reads every second.

## Requirements

- Windows 10 or 11.
- Project Zomboid Build 42, in solo or as the host of a game. Dedicated servers are not supported.
- Node.js 18 or later: `winget install OpenJS.NodeJS.LTS`
- cloudflared, for the public address of the bridge: `winget install --id Cloudflare.cloudflared`
- A LibertyTalk account with Twitch or YouTube connected.

## Install

There are two ways to get the mod. Use only one: two mods with the id `Talky` confuse the game. In both cases, the bridge comes from the GitHub release, and there is nothing to run before `start-bridge.cmd`.

**A. Mod from the Steam Workshop**

1. Subscribe to Talky on the Steam Workshop.
2. Download `Talky-0.3.0-windows.zip` from the [GitHub releases](https://github.com/Tech-Liberty/talky-project-zomboid/releases) and extract it to a folder you keep, for example `Documents\Talky`.
3. Leave the `Talky` folder of the zip where it is: the Workshop already provides the mod, and the game does not read that folder outside `Zomboid\mods`.

**B. Without the Steam Workshop**

1. Download `Talky-0.3.0-windows.zip` and extract it to a folder you keep, as in A.
2. Copy the `Talky` folder of the zip into `%USERPROFILE%\Zomboid\mods`, so that the game finds `%USERPROFILE%\Zomboid\mods\Talky\42\mod.info`. Copy only this folder: the bridge stays in `Documents\Talky`.

Do not extract the zip into `Zomboid\mods`. With the Workshop, the `Talky` folder of the zip would be a second copy of the mod. In both cases, removing or replacing a mod there can delete the bridge and its `bridge\config.json`. The bridge prints a warning at startup in both situations.

To check the download, compare `Get-FileHash Talky-0.3.0-windows.zip -Algorithm SHA256` with `SHA256SUMS.txt` of the release.

## Start and test

1. Double-click `start-bridge.cmd` and keep its window open. On the first launch, you should see these lines, each one after the time:
   ```
   created ~\Documents\Talky\bridge\config.json with a random token (language: en)
   the token is in your clipboard and in config.json, never shown here: paste it into "Bridge token" in the LibertyTalk widget
   created ~\Zomboid\Lua\talky_config.json from config.json
   config loaded: 10 webhook(s), 14 workflow(s)
   Talky bridge 0.3.0 listening on http://127.0.0.1:7420
   game folder: ~\Zomboid\Lua
   http steps allowed to: *.liberty-talk.com
     webhook  POST /hooks/follow
   ```
   The first three lines only show on the first launch. With a French Windows, they read `(language: fr)` and `from config.json (fr: 19 text(s) translated)`.
2. In Project Zomboid: **Mods**, enable **Talky - LibertyTalk Live Events**, then start a solo game or load one. Press **F8**. The Status page shows `Bridge connected on port 7420 - 0 job(s) waiting  (v0.3.0)`.
3. Test without LibertyTalk: on the **Workflows** page, select `new_follower`, type a name and click **Test now**. Or, in a terminal in the Talky folder:
   ```powershell
   node bridge\bridge.js fire new_follower user=Bob
   ```
   A banner "Bob joins the horde!" appears, then, 2 seconds later, a zombie named Bob 8 to 14 tiles away.

What the first launch does:

- `start-bridge.cmd` checks that Node.js 18 or later is installed, and prints the `winget` command when it is not.
- The bridge creates `bridge\config.json` from `bridge\config.example.json`, with a random token of 48 hexadecimal characters. An existing `config.json` is never modified. To get a new token, delete `config.json`, start the bridge again and paste the new token in the widget.
- The token goes to your clipboard and is never printed, so it stays off stream. When the copy fails, the line reads `the token is in config.json ("token")`.
- The example workflows and the bridge texts are in French when the regional format of Windows is French, in English otherwise. To switch later: stop the bridge, set `settings.language` to `fr` or `en` in `bridge\config.json`, rename `%USERPROFILE%\Zomboid\Lua\talky_config.json` (it holds what you changed in F8) and start the bridge again.
- For a game started with `-cachedir`, set `zomboidLuaDir` in `bridge\config.json` to the `Lua` folder of that location, then restart the bridge.
- At every start, a `warning:` line shows when cloudflared is not in the PATH, when Talky is installed twice (in `Zomboid\mods\Talky` and from the Workshop), or when the bridge folder is inside `Zomboid\mods`. The bridge starts anyway.

## Give the bridge a public address

LibertyTalk refuses local and private addresses (protection against server-side request forgery), so the bridge needs a public HTTPS address. In a second window:

```powershell
cloudflared tunnel --url http://127.0.0.1:7420
```

cloudflared prints an address such as `https://example-words.trycloudflare.com`. This quick tunnel needs no account, but its address changes at each launch and Cloudflare offers it for tests, without uptime guarantee. For an address that stays the same from one stream to the next, create a named tunnel on your own domain (see the Cloudflare Tunnel documentation).

Paste the address in **F8 > Status > Public URL**, then **Save**: the "Copy URL" buttons use it.

## Connect LibertyTalk: the "Project Zomboid · Talky" widget

1. In the LibertyTalk dashboard, open **Marketplace**, then the **Project Zomboid · Talky** listing, and click **Install for free**. The widget is added to **My purchases**.
2. In **My purchases**, click **Install** on the Project Zomboid · Talky card. LibertyTalk prepares the widget in your community, switched off. If the "Set up your workflow" assistant opens, you can leave it: this widget is set up on its own page.
3. Open **Widgets**, then the **Project Zomboid · Talky** card. Keep the **Global** scope (selected by default): the widget then listens to every Twitch and YouTube account of the community.
4. In the **Widget configuration** tab, fill in the two sections, then click **Save**:
   - **Talky bridge connection**: **Talky bridge public URL** (`talky_bridge_url`), the tunnel address without a `/` at the end; **Bridge token** (`talky_token`), the `token` value of `bridge\config.json` (the one the bridge put in your clipboard on its first launch); **Chat command (without "!")** (`talky_command`), `zombie` by default.
   - **Events sent to the game**: one box per event, from **Send follows** to **Send new YouTube members** (`talky_on_follow`, `talky_on_sub`, `talky_on_gift`, `talky_on_bits`, `talky_on_raid`, `talky_on_points`, `talky_on_command`, `talky_on_donation`, `talky_on_superchat`, `talky_on_member`), all ticked by default.
5. In the **Activation** block, click **Activate**. The line changes to "Active on Global." and the **Listening to** block lists the accounts the widget listens to.

`talky_token` is declared as a secret variable: LibertyTalk keeps it without showing it again and masks it in execution traces. To change it, type the new value and save.

For each event that is switched on, the widget sends `POST <talky_bridge_url>/hooks/<id>` with the `X-Bridge-Token` header:

| Event | LibertyTalk trigger | Bridge webhook | Example workflow | Fields sent |
|---|---|---|---|---|
| New follower | `channelFollow` | `/hooks/follow` | `new_follower` | `user_name` |
| Subscription (gifted subs excluded) | `channelSubscribe` | `/hooks/sub` | `new_sub` | `user_name`, `tier`, `is_gift` |
| Gifted subs | `channelSubscriptionGift` | `/hooks/gift` | `gift_subs` | `user_name`, `total`, `tier` |
| Bits | `channelCheer` | `/hooks/bits` | `bits` | `user_name`, `bits` |
| Raid | `channelRaid` | `/hooks/raid` | `raid` | `user_name`, `viewers` |
| Channel points | `channelPointsRedemption` | `/hooks/points` | routes on the reward title | `user_name`, `reward_title` |
| Chat command | `commandReceived` | `/hooks/command` | `chat_zombie` | `command` |
| Donation | `donationReceived` | `/hooks/donation` | `donation` | `donor`, `amount`, `formatted_amount` |
| Super Chat | `youtubeSuperChat` | `/hooks/superchat` | `donation` | `author_display_name`, `formatted_amount` |
| New member | `youtubeNewMember` | `/hooks/member` | `new_sub` | `author_display_name` |

Good to know:

- The chat command call carries only the command name, `{"command":"zombie"}`: no viewer name and no text typed after the command. The Twitch developer agreement forbids redistributing chat messages outside Twitch, and LibertyTalk applies this rule to marketplace widgets. `!zombie` and `!zombie Bob` therefore do the same thing: the zombie takes the name set for anonymous events (**F8 > Settings > Name for anonymous events**, `Anonymous` when empty, `Anonyme` with the French settings).
- The widget never sends a free text typed by a viewer: the channel points call carries the viewer name and the reward title, not the text entered with the reward (`user_input`).
- Subscriptions: the `sub` call only runs for subscriptions that are not gifts. A gift of 5 subs arrives once, on `gift`, with `total` = 5.
- Channel points: the `points` webhook picks a workflow from the reward title. With the English examples, the title must contain `helicopter`, `heal`, `storm` or `zombie` (`hélico`, `soin`, `tempête` or `zombie` with the French examples). Change the words in **F8 > Webhooks > points > Edit routes (JSON)**.
- When the tunnel address changes, update **Talky bridge public URL** in the widget configuration and click **Save**. The change applies right away, without deactivating the widget.
- LibertyTalk waits 10 seconds for the bridge. A call to a stopped bridge can still show as completed in the LibertyTalk execution console: check the bridge window or **F8 > Status** first.

**Without the widget**, build your own LibertyTalk workflow: a trigger from the table, then the action **Webhook / API call** with the URL `https://<tunnel>/hooks/<id>`, the method `POST`, the additional headers `{"X-Bridge-Token":"<token>"}` and a JSON body built like the "Fields sent" column, for example `{"user_name":"{user_name}","bits":"{bits}"}`. Leave "Sign the request" on No: that signature uses a key the bridge does not know. The token can also go in the URL (`?token=...`), but the header keeps it out of the URL.

## The in-game window (F8)

The key can be changed in **Options > Keybinds > Talky**.

| Page | Content |
|---|---|
| **Status** | Bridge connected or offline, bridge version, public URL of the tunnel, URL of each webhook with a **Copy URL** button (the token is copied, never shown), last events received by the bridge with the reason when one was skipped. |
| **Webhooks** | Create, rename or delete webhooks. Choose the workflow each one runs, or routes based on the content. Optional dedicated token. |
| **Workflows** | Enable, cooldowns, chance, condition. Steps edited with one form per action (fields accept `{{user}}`), moved up or down, advanced steps in JSON (`if`, `random`, `repeat`). **Test now** with the name of your choice. |
| **Game events** | Link "a named zombie dies", "the player dies" and "the game starts" to a workflow. |
| **Settings** | Caps (zombies per action, workflows at the same time, spawn distance), names above zombies, banner duration and position, language of the bridge texts, name for anonymous events. |

**Save** writes `Zomboid\Lua\talky_config.json`, which the bridge reloads without a restart. On its first launch, the bridge creates this file from `bridge\config.json`. If F8 > Save created it first, with no webhook and no workflow, the bridge adds the examples of `config.json` to it and keeps the public URL and the settings already saved. After that, `talky_config.json` holds the webhooks, workflows, game events, public URL and settings, and `bridge\config.json` keeps the port, the token, the allowed hosts and the poll mode. A newer `config.example.json` never changes an existing `talky_config.json`: to get the new examples, rename `talky_config.json` and restart the bridge.

## Writing workflows by hand

The F8 window covers everything below. This section is for those who prefer to edit `Zomboid\Lua\talky_config.json`.

### Webhooks and workflows

```json
"webhooks": {
  "follow": { "workflow": "new_follower" },
  "points": { "routes": [
    { "when": { "reward_title": { "contains": "helicopter" } }, "workflow": "points_helicopter" },
    { "when": { "reward_title": { "contains": "zombie" } }, "workflow": "points_zombie" }
  ] }
}
```

Each key of `webhooks` becomes `POST /hooks/<key>`. `routes` picks the workflow from the event content: the first route that matches wins. `workflow` also accepts a list, to run several workflows.

```json
"new_follower": {
  "when": { "user": { "ne": "SomeBot" } },
  "chance": 1,
  "cooldownSeconds": 0,
  "userCooldownSeconds": 0,
  "steps": [
    { "action": "notify", "text": "{{user}} joins the horde!", "color": "#b388ff" },
    { "action": "wait", "seconds": 2 },
    { "action": "spawn_zombie", "name": "{{user}}", "distance": 14 }
  ]
}
```

### Templates `{{ }}`

- `{{user}}`, `{{bits}}`, `{{payload.field.sub_field}}`, `{{query.param}}`. `{{user}}` is the `user` field when the call has one, otherwise the first field found among `user_name`, `author_display_name`, `display_name`, `donor`, `chatter_name`, `actor_name`, `username`, `author_username`, `user_login` and `name`, so the same workflow works for Twitch and YouTube. When none is filled, it is the name for anonymous events (F8 > Settings).
- Filters: `{{bits | div:100 | floor | clamp:1:20}}`, `{{tier | tier}}` (1000/2000/3000 becomes 1/2/3), `{{user | upper}}`, `{{user | truncate:12}}`, `{{viewers | default:5}}`, `{{'' | pick:Ann:Bob:Cid}}`.
- All filters: `default upper lower truncate number round floor ceil add sub mul div min max clamp tier pick json`.
- A field that holds a single `{{...}}` keeps its type: `"count": "{{viewers}}"` gives a number.
- `bits`, `viewers`, `total`, `amount` and `tier` arrive from LibertyTalk as strings (`"500"`). The bridge turns them into numbers before conditions and filters run.
- These double braces only work in `talky_config.json`. In a LibertyTalk field, `{user_name}` is a LibertyTalk variable.

### Conditions (`when`, `if`, `routes`)

- `{ "bits": { "gte": 100 } }`, `{ "tier": "3000" }`, `{ "command": ["zombie", "z"] }`
- Operators: `eq ne gt gte lt lte in contains matches exists` (`contains` and `matches` ignore case).
- Combinations: `{ "all": [...] }`, `{ "any": [...] }`, `{ "not": {...} }`

### Control steps

The bridge resolves these steps before it sends the job to the game.

| Step | Effect |
|---|---|
| `{ "if": cond, "then": [...], "else": [...] }` | branch |
| `{ "random": [[...], [...]], "weights": [3, 1] }` | one branch picked at random, weighted |
| `{ "repeat": "{{bits \| div:100 \| floor}}", "max": 20, "steps": [...] }` | loop, `{{i}}` is the iteration (100 at most) |
| `{ "chance": 0.3, "steps": [...] }` | probability |
| `{ "set": { "x": "{{...}}" } }` | sets a variable for the next steps |
| `{ "action": "wait", "seconds": 2 }` | pause **in the game**, 600 s at most, other jobs keep running |
| `{ "action": "http", "url": "...", "body": {...} }` | outgoing HTTP call by the bridge, only to the allowed hosts (see Security); `headers`, `method`, `hmacSecret` and `hmacHeader` are optional |
| `{ "action": "log", "message": "..." }` | line in the bridge window |

`http` and `log` steps run in the background: they do not delay the game steps nor the reply to LibertyTalk.

## Actions in the game

| Action | Parameters |
|---|---|
| `notify` | `text` (200 characters at most), `color` (#hex), `seconds` (60 at most): banner on screen |
| `say` / `halo` | `text` (200 characters at most): the character speaks / floating text |
| `spawn_zombie` | `name`, `count`, `distance`, `minDistance`, `outfit`, `crawler`, `health`, `onFire`, `fakeDead`, `aggro` (true by default), `cluster`, `radius`, `sameName`, `color`, `outside` |
| `horde` | like `spawn_zombie`, as a group (15 zombies at 25 tiles by default) |
| `noise` | `radius`, `volume`, `sound`: a noise that attracts zombies |
| `sound` | `name`: a game sound |
| `helicopter` | starts the helicopter event |
| `thunder` | `strike` |
| `weather` | `type`: `storm`, `blizzard`, `tropical` or `clear`, or `stage` (number), `hours` |
| `time` | `hour` (0 to 23.99) |
| `fire` | `distance`: a fire near the player |
| `vehicle` | `script` (for example `Base.PickUpTruck`), `distance` |
| `give_item` | `item` (for example `Base.Katana`), `count`, `onGround` |
| `heal` | full heal |
| `stat` | `stat` (`PANIC`, `STRESS`, `FATIGUE`, `HUNGER`, `INTOXICATION`...), `op` (`add`, `set` or `remove`), `value` |
| `xp` | `perk` (for example `Woodwork`), `amount` |
| `emit` | `event`, `data`: sends an event back to the bridge |

Named zombies show their name above their head and keep it after a save (it is stored in their modData). The caps are set on the Settings page: 60 zombies per action, 8 jobs at the same time and 60 tiles of distance by default. A job older than `jobTtlSeconds` (15 minutes by default) is skipped, so a game started late does not receive 40 hordes at once.

To add an action, in a Lua file of your mod or of another mod:

```lua
Talky_Actions.register("teleport", function(p, player) player:setX(p.x); player:setY(p.y) end)
```

## Events sent back by the game

| Event | Data |
|---|---|
| `zombie_killed` | `name`, `byPlayer` (a named zombie dies) |
| `player_died` | `hoursSurvived`, `zombieKills` |
| `game_started` | none |
| `job_done` | `seq`, `workflow` |
| `action_failed` | `seq`, `action`, `error` |

```json
"gameEvents": { "zombie_killed": "on_zombie_killed", "player_died": ["on_player_died", "report_to_libertytalk"] }
```

**Sending a game event to LibertyTalk**

1. In LibertyTalk, create a workflow with the **Incoming webhook** trigger. It gives a URL (`https://api.liberty-talk.com/webhooks/workflow/<token>`) and a secret. Map the fields you need (`name`, `event`, `zombieKills`...).
2. In `talky_config.json`, fill in the example workflow `report_to_libertytalk` and enable it:
   ```json
   "report_to_libertytalk": {
     "steps": [
       { "action": "http",
         "url": "https://api.liberty-talk.com/webhooks/workflow/<token>",
         "headers": { "X-Webhook-Secret": "<secret>" },
         "body": { "event": "{{event}}", "name": "{{name}}", "zombieKills": "{{zombieKills}}" } }
     ]
   }
   ```
3. Link it to a game event (F8 > Game events, or `gameEvents` above). LibertyTalk answers 202. The host matches the default `*.liberty-talk.com` of `httpAllowedHosts`.

The bridge can also sign the body with `"hmacSecret"` and `"hmacHeader": "X-LT-Signature"`, but LibertyTalk treats a signature without timestamp as a legacy one: prefer `X-Webhook-Secret`.

## Security

- **Token.** Every call to `/hooks/<id>` and `/fire/<workflow>` needs the token, in the `X-Bridge-Token` header or in `?token=`. The comparison runs in constant time. Without a valid token, every webhook id answers 401, so the ids cannot be guessed. A webhook can have its own token (it then refuses the global one). `POST /fire/<workflow>` runs any workflow with the global token.
- **Network.** The bridge listens on `127.0.0.1` only (`host` in `config.json`). The tunnel is what makes it reachable from the internet.
- **Outgoing calls.** An `http` step only reaches the hosts listed in `httpAllowedHosts` of `bridge\config.json` (default `["*.liberty-talk.com"]`; `*.example.com` covers every subdomain of example.com but not example.com itself; `"*"` allows every host and removes this protection). Another step is refused and shown in the bridge window and on the F8 Status page. Redirects are not followed. The reason: `talky_config.json` lives in `Zomboid\Lua`, a folder every other mod can write to. Without the list, a mod could add an `http` step and use the bridge to send data anywhere, on the internet or on your local network. The list itself stays in `bridge\config.json`, out of reach of game mods.
- **What remains.** A mod can still read `talky_status.json`, which holds the token for the "Copy URL" buttons, and can still target an incoming webhook of any LibertyTalk account. Install only mods you trust.
- **Caps.** `wait` 600 s, texts of `notify` / `say` / `halo` 200 characters, banners 60 s, zombie names 60 characters, `repeat` 100 iterations, 500 game steps and 20 `http` / `log` steps per job, 10 000 steps and loop turns walked through per job (past that, the rest of the workflow is skipped and the bridge window says so), 200 jobs waiting in the game, body of a webhook call 64 KB.
- **On stream.** The F8 window never shows a token: the global one is not displayed, and the dedicated token of a webhook is typed in a masked field. The bridge window shows `~` instead of your Windows user folder, error messages included. On its first launch, the bridge copies its new token to the clipboard without printing it.
- **Secrets on disk.** `bridge\config.json` and `bridge\bridge-state.json` are in `.gitignore` and never in the release zip. The Steam Workshop item only contains the mod.

## Limits

- Solo or host only. A dedicated server would need a `server/` module (`sendClientCommand`).
- The address of a quick tunnel changes at each launch: update the widget settings and the F8 public URL.
- Version 0.3.0 was tested with a simulated game API: the Lua runs in Kahlua (the Lua VM of the game) with fake game objects. To check in a real game: the position of the names above heads, zombie aggro (`spotted` / `pathToCharacter`), `testHelicopter()` outside debug mode, the weather stage numbers (taken from the B42 debug menu), the custom key binding, and `byPlayer` (which may always be `false`).
- The poll mode (below) was not tested against a live LibertyTalk instance.

## Troubleshooting

| Symptom | Cause and fix |
|---|---|
| F8 shows "Bridge offline" | The bridge is not running, or `zomboidLuaDir` in `config.json` points to the wrong folder (game started with `-cachedir`). |
| `No config at ... Start the bridge once (start-bridge.cmd)`, after `node bridge\bridge.js fire ...` | `bridge\config.json` does not exist yet. Start the bridge once with `start-bridge.cmd`: it creates the file. |
| `Cannot create ...\bridge\config.json` | You cannot write to the Talky folder (under `C:\Program Files`, say). Move it to `Documents\Talky` and start `start-bridge.cmd` again. |
| `Set a long random "token" in config.json` | The token is empty or still `change-me...` (a `config.json` copied by hand from `config.example.json`). Put a long random string there, or delete `config.json` and start the bridge again: it creates a new one. |
| `warning: cloudflared is not in the PATH` | Install it with `winget install --id Cloudflare.cloudflared`, then open a new window. |
| `warning: Talky is installed twice` | Delete `%USERPROFILE%\Zomboid\mods\Talky`: the Workshop version is enough. |
| `warning: The bridge folder ... is inside ...\Zomboid\mods` | Move the whole Talky folder, `bridge\config.json` included, out of `Zomboid\mods` (to `Documents\Talky`, say), then start `start-bridge.cmd` from there. The token does not change. |
| `'node' is not recognized`, or `Node.js was not found on this PC.` in the `start-bridge.cmd` window | Install Node.js 18 or later, then open a new window. |
| `Port 7420 is already used` | Another program (or a second bridge) uses the port. Change `port` in `config.json` and in the cloudflared command. |
| LibertyTalk refuses the URL | The URL is local (`http://127.0.0.1...`). Paste the `https://...trycloudflare.com` address. |
| `401 bad token` | Wrong token, or a webhook with its own token called with the global one. The bridge checks the token first: without the right one, even an unknown webhook id answers 401. |
| `404 unknown webhook` | The id is missing from `talky_config.json`. After the first launch, `config.json` is no longer read for webhooks, unless `talky_config.json` has neither webhooks nor workflows. |
| `413 body too large` | Body over 64 KB. |
| The bridge logs `job #N` but nothing happens | Game paused, player dead, back to the main menu, job older than `jobTtlSeconds`, or 8 jobs already running (long `wait` steps). |
| Status shows "skipped: cooldown / condition not met / chance roll lost / workflow disabled" | The workflow refused the event: see its settings on the Workflows page. |
| `http step refused: host "..." is not in httpAllowedHosts` | Add the host to `httpAllowedHosts` in `bridge\config.json` and restart the bridge. |
| Nothing happens after a restart | The tunnel address changed: update the widget and the F8 public URL. |
| The mod is not in the list | Without the Workshop, the game needs `%USERPROFILE%\Zomboid\mods\Talky\42\mod.info`: copy the `Talky` folder of the zip, not the folder that contains it. Check that Talky is not installed twice (Workshop and `Zomboid\mods`). |

Logs: the game writes `[Talky]` lines in `%USERPROFILE%\Zomboid\console.txt`. `http://127.0.0.1:7420/health?token=<token>` returns the number of jobs waiting, the last acknowledged job and the last 50 events.

Exchange files in `%USERPROFILE%\Zomboid\Lua\`: `talky_inbox.jsonl` (jobs), `talky_ack.txt`, `talky_outbox.jsonl` (game events), `talky_status.json` (bridge heartbeat) and `talky_config.json` (the configuration edited by the F8 window).

## `bridge\config.json` reference

| Key | Default | Role |
|---|---|---|
| `port` | `7420` | Port of the bridge. |
| `host` | `127.0.0.1` | Listening address. Keep `127.0.0.1`: the tunnel connects locally. |
| `token` | random | Token of the webhook calls, drawn when the bridge creates `config.json`. |
| `zomboidLuaDir` | `%USERPROFILE%/Zomboid/Lua` | Folder shared with the mod. |
| `jobTtlSeconds` | `900` | A job older than this is skipped by the game. |
| `httpAllowedHosts` | `["*.liberty-talk.com"]` | Hosts that `http` steps may call. |
| `settings` | `{"language": "en", "anonymousName": ""}`, `fr` when the regional format of Windows is French | Copied to `talky_config.json` on the first launch, then edited in F8 > Settings. |
| `webhooks`, `workflows`, `gameEvents` | examples | Copied to `talky_config.json` on the first launch. |
| `poll` | disabled | Experimental source without public address, see below. |

**Poll mode (experimental).** Instead of receiving webhooks, the bridge reads the LibertyTalk activity feed every `intervalSeconds` (10 s, 5 s at least) with an API token: `"url": "https://<tenant>.api.liberty-talk.com/community/<community_id>/activity?per_page=50"`, `"apiToken"`, optional `"headers"`. `types` maps an activity type to a workflow: `follow`, `subscribe`, `subscribe_gift`, `cheer`, `raid`, `donation`, `superchat`, `member` (`resub`, `member_gift`, `charity`, `boost` and `first_message` also exist). The bridge fills `user_name` from `actor_name`, `bits` (cheer), `viewers` (raid) and `total` (gifts) from `amount`. Events already in the feed when the bridge starts are not replayed.

## Development

- Bridge tests: `cd bridge`, then `npm test` (Node 18 or later, no dependencies). They start real bridges on free ports with a temporary game folder.
- Lua tests: `powershell -ExecutionPolicy Bypass -File tools\test-lua.ps1 -GameDir "<path to ProjectZomboid>"` (Java 17 or later). They compile every file with the Kahlua of the game jar, then run the mod with fake game objects: every page of the F8 window in English and French, translation keys, caps.
- Steam Workshop folder: `tools\build-workshop.ps1` assembles `%USERPROFILE%\Zomboid\Workshop\Talky` (`-OutDir` to build it elsewhere), keeps the Workshop `id=` after the first upload and refuses the file types the Workshop rejects. Then, in the game: **Workshop > Create and update items**.
- Release: `tools\build-release.ps1` builds `dist\Talky-<version>-windows.zip` and `dist\SHA256SUMS.txt`. The version of `bridge\package.json` must match `modversion` in `mod.info`.
- `mod\Talky\42\poster.png` and `packaging\workshop\preview.png` are provisional images drawn by `tools\make-placeholder-images.ps1`.
- Translations: `mod\Talky\42\media\lua\shared\Translate\<LANG>\UI.json` (keys `UI_Talky_*`, the same keys in every language) and `Mod.json` (name and description of the mod).

## License

MIT, see [LICENSE](LICENSE). The license covers the code, not the LibertyTalk and Tech Liberty names and logos.

# Talky: LibertyTalk live events for Project Zomboid (Build 42)

[Version française](README.fr.md)

Talky connects [LibertyTalk](https://liberty-talk.com) to Project Zomboid. A follow, a sub, bits, a raid, a channel point redemption or a Super Chat on your stream runs a workflow in your game: a zombie named after the new follower, a horde sized by the raid, the helicopter for 1000 bits. The game sends its own events back ("a named zombie died", "the player died"), and they can run workflows too, including a call to LibertyTalk.

Talky works in single player, in a hosted game and on a dedicated server. In multiplayer the server runs the effects, so every player sees them: see [Multiplayer](#multiplayer).

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

- Windows 10 or 11, on the PC that runs the game and the bridge.
- Project Zomboid Build 42.20.1 or later, in single player, as the host of a game, or on a dedicated server. On a server, Talky must be installed on the server too: see [Multiplayer](#multiplayer).
- Node.js 18 or later: `winget install OpenJS.NodeJS.LTS`
- cloudflared, for the public address of the bridge: `winget install --id Cloudflare.cloudflared`
- A LibertyTalk account with Twitch or YouTube connected.

## Install

There are two ways to get the mod. Use only one: two mods with the id `Talky` confuse the game. In both cases, the bridge comes from the GitHub release, and there is nothing to run before `start-bridge.cmd`.

**A. Mod from the Steam Workshop**

1. Subscribe to Talky on the Steam Workshop.
2. Download `Talky-0.4.0-windows.zip` from the [GitHub releases](https://github.com/Tech-Liberty/talky-project-zomboid/releases) and extract it to a folder you keep, for example `Documents\Talky`.
3. Leave the `Talky` folder of the zip where it is: the Workshop already provides the mod, and the game does not read that folder outside `Zomboid\mods`.

**B. Without the Steam Workshop**

1. Download `Talky-0.4.0-windows.zip` and extract it to a folder you keep, as in A.
2. Copy the `Talky` folder of the zip into `%USERPROFILE%\Zomboid\mods`, so that the game finds `%USERPROFILE%\Zomboid\mods\Talky\42\mod.info`. Copy only this folder: the bridge stays in `Documents\Talky`.

Do not extract the zip into `Zomboid\mods`. With the Workshop, the `Talky` folder of the zip would be a second copy of the mod. In both cases, removing or replacing a mod there can delete the bridge and its `bridge\config.json`. The bridge prints a warning at startup in both situations.

To check the download, compare `Get-FileHash Talky-0.4.0-windows.zip -Algorithm SHA256` with `SHA256SUMS.txt` of the release.

**Updating from 0.3.0.** Replace the mod and the bridge at the same time, and keep `bridge\config.json` and `%USERPROFILE%\Zomboid\Lua\talky_config.json`. Since game version 42.20.1, mods may only write `.ini`, `.cfg`, `.txt`, `.log` and `.json` files. The game refused the `talky_outbox.jsonl` file of Talky 0.3.0, so no game event (`zombie_killed`, `player_died`, `game_started`, `job_done`, `action_failed`) and no **Test now** reached the bridge. Talky 0.4.0 writes `talky_outbox.txt`, which bridge 0.4.0 reads (it still reads the old file). **Test now** also needs both at 0.4.0: the bridge only runs a test that carries the test code it writes in `talky_status.json` at each start. With an older bridge, F8 > Status shows "Bridge older than 0.4.0".

What 0.4.0 changes for a 0.3.0 setup:

- A dedicated webhook token typed in the F8 window of 0.3.0 is saved in `talky_config.json`, a file every game mod can read. Bridge 0.4.0 ignores it (a `warning:` line names the webhook) and that webhook takes the bridge token, so a LibertyTalk URL that carries the old dedicated token gets `401 bad token`. Move the token to `hookTokens` in `bridge\config.json` (see [Webhook URLs and tokens](#webhook-urls-and-tokens)) and restart the bridge.
- An `http` step with `hmacSecret` written in `talky_config.json` is refused. Put the address and its secrets in `httpTargets` of `bridge\config.json` and name the target in the step (see [Sending a game event to LibertyTalk](#sending-a-game-event-to-libertytalk)). `headers` written in a step still work, with a warning.
- `talky_status.json` no longer holds the token, and the **Copy URL** buttons of F8 became **Copy command**: they copy `node bridge\bridge.js url <webhook>`, which puts the full URL in the clipboard.

## Start and test

1. Double-click `start-bridge.cmd` and keep its window open. On the first launch, you should see these lines, each one after the time:
   ```
   created ~\Documents\Talky\bridge\config.json with a random token (language: en)
   the token is in your clipboard and in config.json, never shown here: paste it into "Bridge token" in the LibertyTalk widget
   created ~\Zomboid\Lua\talky_config.json from config.json
   config loaded: 10 webhook(s), 14 workflow(s)
   Talky bridge 0.4.0 listening on http://127.0.0.1:7420
   game folder: ~\Zomboid\Lua
   http steps allowed to: *.liberty-talk.com
     webhook  POST /hooks/follow
   ```
   The first three lines only show on the first launch. With a French Windows, they read `(language: fr)` and `from config.json (fr: 19 text(s) translated)`.
2. In Project Zomboid: **Mods**, enable **Talky - LibertyTalk Live Events**, then start a solo game or load one (for a server, see [Multiplayer](#multiplayer)). Press **F8**. The Status page shows `Bridge connected on port 7420 - 0 job(s) waiting  (v0.4.0)`, then `Single player: the jobs run in this game.`
3. Test without LibertyTalk: on the **Workflows** page, select `new_follower`, type a name and click **Test now**. Or, in a terminal in the Talky folder:
   ```powershell
   node bridge\bridge.js fire new_follower user=Bob
   ```
   A banner "Bob joins the horde!" appears, then, 2 seconds later, a zombie named Bob 8 to 14 tiles away.

What the first launch does:

- `start-bridge.cmd` checks that Node.js 18 or later is installed, and prints the `winget` command when it is not.
- The bridge creates `bridge\config.json` from `bridge\config.example.json`, with a random token of 48 hexadecimal characters. An existing `config.json` is never replaced. To get a new token, run `node bridge\bridge.js new-token` (see [Webhook URLs and tokens](#webhook-urls-and-tokens)).
- The token goes to your clipboard and is never printed, so it stays off stream. When the copy fails, the line reads `the token is in config.json ("token")`.
- The example workflows and the bridge texts are in French when the regional format of Windows is French, in English otherwise. To switch later: stop the bridge, set `settings.language` to `fr` or `en` in `bridge\config.json`, rename `%USERPROFILE%\Zomboid\Lua\talky_config.json` (it holds what you changed in F8) and start the bridge again.
- For a game started with `-cachedir`, set `zomboidLuaDir` in `bridge\config.json` to the `Lua` folder of that location, then restart the bridge.
- At every start, a `warning:` line shows when cloudflared is not in the PATH, when Talky is installed twice (in `Zomboid\mods\Talky` and from the Workshop), when the bridge folder is inside `Zomboid\mods`, or when `jobTtlSeconds` is above 900 or not a number (900 is then used). The bridge starts anyway.

## Give the bridge a public address

LibertyTalk refuses local and private addresses (protection against server-side request forgery), so the bridge needs a public HTTPS address. In a second window:

```powershell
cloudflared tunnel --url http://127.0.0.1:7420
```

cloudflared prints an address such as `https://example-words.trycloudflare.com`. This quick tunnel needs no account, but its address changes at each launch and Cloudflare offers it for tests, without uptime guarantee. For an address that stays the same from one stream to the next, create a named tunnel on your own domain (see the Cloudflare Tunnel documentation).

Paste the address in **F8 > Status > Public URL**, then **Save**: `node bridge\bridge.js url <webhook>` builds the webhook URLs from it.

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

**Without the widget**, build your own LibertyTalk workflow: a trigger from the table, then the action **Webhook / API call** with the URL `https://<tunnel>/hooks/<id>`, the method `POST`, the additional headers `{"X-Bridge-Token":"<token>"}` and a JSON body built like the "Fields sent" column, for example `{"user_name":"{user_name}","bits":"{bits}"}`. Leave "Sign the request" on No: that signature uses a key the bridge does not know. The token can also go in the URL (`?token=...`), but the header keeps it out of the URL. A webhook listed in `hookTokens` takes its own token instead of the bridge token.

## Webhook URLs and tokens

The game never knows the tokens: they stay in `bridge\config.json`, which the game cannot read. These commands run in a terminal opened in the Talky folder, whether the bridge runs or not:

- `node bridge\bridge.js url <webhook>` puts the full URL of a webhook, `<public URL>/hooks/<webhook>?token=<its token>`, in the clipboard, and prints it with the token masked. The public URL is the one saved in F8 > Status; `--base https://<tunnel address>` gives another one. `--show` prints the full URL (not while the window is on stream). The **Copy command** buttons of F8 copy this command for the selected webhook.
- `node bridge\bridge.js new-token` writes a new random token in `bridge\config.json`, the rest of the file unchanged, and puts it in the clipboard without printing it. Restart the bridge (the old token works until then), paste the new token into **Bridge token** of the LibertyTalk widget, and copy your webhook URLs again with `url`. The tokens of `hookTokens` do not change.
- `hookTokens` in `bridge\config.json` gives a webhook its own token, 16 characters or more: `"hookTokens": { "follow": "<long random text>" }`. That webhook then refuses the bridge token. Restart the bridge after a change. F8 > Webhooks shows whether a webhook has a dedicated token, never the token.

From the `bridge` folder, where `start-bridge.cmd` starts the bridge, the same commands are `node bridge.js url <webhook>` and `node bridge.js new-token`, or `npm run url -- <webhook>` and `npm run new-token`.

## The in-game window (F8)

The key can be changed in **Options > Keybinds > Talky**.

| Page | Content |
|---|---|
| **Status** | Bridge connected or offline, bridge version (with a warning when the bridge is older than 0.4.0), single player or multiplayer, public URL of the tunnel, URL of each webhook with the token masked and a **Copy command** button (it copies `node bridge\bridge.js url <webhook>`; the game never copies a token), last events received by the bridge with the reason when one was skipped or refused. In multiplayer: the answer of the server (it runs your jobs, or it refuses them and why), its limits, the categories it turned off, the jobs without answer, the last refused job, and the **Allow me (host)** button for the host of a game. |
| **Webhooks** | Create, rename or delete webhooks. Choose the workflow each one runs, or routes based on the content. Whether the webhook has a dedicated token (set in `hookTokens` of `bridge\config.json`), and **Copy command**. |
| **Workflows** | Enable, cooldowns, chance, condition. Steps edited with one form per action (fields accept `{{user}}`), moved up or down, advanced steps in JSON (`if`, `random`, `repeat`). **Test now** with the name of your choice. |
| **Game events** | Link "a named zombie dies", "the player dies" and "the game starts" to a workflow. |
| **Settings** | Caps (zombies per action, workflows at the same time, spawn distance), names above zombies, banner duration and position, language of the bridge texts, name for anonymous events. In multiplayer, the three caps show the values of the server, read only (`30 (set by the server)`). |

**Save** writes `Zomboid\Lua\talky_config.json`, which the bridge reloads without a restart. On its first launch, the bridge creates this file from `bridge\config.json`. If F8 > Save created it first, with no webhook and no workflow, the bridge adds the examples of `config.json` to it and keeps the public URL and the settings already saved. After that, `talky_config.json` holds the webhooks, workflows, game events, public URL and settings, and `bridge\config.json` keeps the port, the token, the dedicated webhook tokens (`hookTokens`), the http targets and their secrets (`httpTargets`), the allowed hosts and the poll mode. A newer `config.example.json` never changes an existing `talky_config.json`: to get the new examples, rename `talky_config.json` and restart the bridge.

## Multiplayer

Talky works in a hosted game (**Host** in the main menu) and on a dedicated server. Single player works as before.

```
streamer's PC                                              server
+-----------+   files   +-----------------+   network   +-------------------+
| bridge.js |---------->| Project Zomboid |------------>| Talky (server)    |
|           |<----------| Talky (client)  |<------------| checks the jobs,  |
+-----------+  ack and  +-----------------+ answers and | runs them         |
                outbox                      effects     +-------------------+
```

### What changes

- The bridge and the tunnel stay on the streamer's PC, as in single player. Nothing changes on the server machine apart from the mod: no bridge, no tunnel, no port to open.
- The streamer's game reads the jobs of its bridge and sends them to the server. The server checks who sent them, applies its limits, then runs them around the streamer's character.
- World effects run on the server, so every player sees them: zombies and the names above them, items, vehicles, fire, weather, time of day, noise, sounds, helicopter.
- Effects on a character only reach the streamer who sent the job: `heal` (it runs on the streamer's game), `stat`, `xp` and `give_item`. No step can target another player.
- Banners (`notify`) show on the streamer's screen only, unless the server shows them to every player (option **Banners**). `say` goes through the "say" chat, so nearby players see it: 12 lines a minute per streamer and 60 for the whole server, beyond which the line only shows above the character. `halo` shows on the streamer's screen.
- Game events (`zombie_killed`, `job_done`, `action_failed`...) go back to the game of the streamer who sent the job, which writes them for its own bridge. `player_died` and `game_started` come from the streamer's own game; in multiplayer, `game_started` is written after the first answer of the server.
- Several streamers can play on the same server, each with their own bridge and LibertyTalk widget. Each one has their own waiting list and limits; the limits marked "all players" apply to them together.
- The webhooks, workflows and game events of the F8 window stay on each streamer's PC, in `talky_config.json`. The caps of the Settings page come from the server.
- The server never reads or writes the files of `Zomboid\Lua`. In a hosted game, the server and the host's game share that folder; only the host's game reads the jobs.

### Install on a server

The mod goes on the server and on every client. A player who joins a server only runs the mods of the server's list, so Talky must be in that list, even for a single streamer.

**Dedicated server.** Stop the server. In `Zomboid\Server\<server name>.ini` (`servertest.ini` by default; the `Zomboid` folder is in the home folder of the account that runs the server), add Talky to these two lists, separated from the other entries by `;`:

```ini
Mods=Talky
WorkshopItems=<Workshop id of Talky>
```

- `WorkshopItems` takes the number at the end of the address of the Steam Workshop item, once Talky is published there. Players who join are then asked to download it.
- Without the Workshop, leave Talky out of `WorkshopItems` and copy the `Talky` folder of the zip into the `Zomboid\mods` folder of the server and of every player. Every copy must be the same version.
- Game 42.21 reads `Mods=\Talky` the same way as `Mods=Talky`.

Start the server. Its console (`Zomboid\server-console.txt`) shows `[Talky] server ready (Talky 0.4.0, protocol 1)`.

**Hosted game.** In the main menu: **Host** > **Manage settings...**, select the settings, then **Edit Selected Settings**. On the **Mods** page, add Talky ("Add an installed mod to the list"). With the Workshop version, also add it on the **Steam Workshop** page. The **Talky** page of the same settings holds the options below (if it is missing, enable Talky in the **Mods** menu of the main menu and open the settings again). Then start the game. The console of the server of a hosted game is `Zomboid\coop-console.txt`.

**On each streamer's PC.** Nothing new: the mod (same version as the server) and the bridge, as in [Install](#install). Start the bridge, then join the server. F8 > Status shows `Multiplayer:  the server runs your jobs (Talky 0.4.0 on the server).`, or `Hosted game (you are the host):` for the host.

### Who may use Talky

On a server, the server checks every job. A player may use Talky when:

- their role has the **CreateHorde** capability and the option **Admins and moderators may use Talky** is on (default). Among the default roles, admin and moderator have it, gm and observer do not. A custom role can be given it;
- or their username is in **Allowed players**: usernames separated by commas or semicolons. A space is part of the name: `Big Boss` is one username. Only the letters A to Z ignore case, as for the account names of the game: `zoé` and `ZOÉ` are two names, `Bob` and `bob` one.

On a server open to everyone, the first person who connects with a free username creates that account. Add a streamer to **Allowed players** after they joined once and set a password, or use a whitelisted server.

For anyone else, F8 > Status shows `the server refuses the jobs of <name>.` and the game sends no job. The jobs wait in the bridge and expire after `jobTtlSeconds`. The game asks the server again every 30 seconds, so a role or an **Allowed players** entry given during the game applies without reconnecting. The server checks the permission again on every tick for the jobs it already accepted. If the permission is removed during the game, the server drops the jobs of that player, waiting or running, and refuses the next ones the game sends: each one gives `job_rejected` with the reason `not_allowed`. The game then stops sending jobs and asks the server again every 30 seconds. A category turned off during the game (see [Server options](#server-options-sandbox-options--talky)) works the same way: the steps of that category that have not run yet give `action_failed` with the code `disabled`.

**Hosted game.** The host's account starts with the default role, not admin, so the host is refused at first. F8 > Status then shows `Your role on this server is not admin: click Allow me, or add <name> to Sandbox Options > Talky > Allowed players.` The **Allow me (host)** button sends `/setaccesslevel "<your username>" admin` to the server, which accepts this command from the host of the game. A few seconds later the status changes to `the server runs your jobs`. The other way: add the host's username to **Allowed players** before starting the game.

In single player every job runs, and the sandbox options of Talky do not apply: the caps are those of F8 > Settings.

The `cmd` log of the server (in `Zomboid\Logs`) records each Talky command with the username of the player who sent it.

### Server options (Sandbox Options > Talky)

Where to set them:

- hosted game: the **Talky** page of the settings (see above);
- dedicated server: `Zomboid\Server\<server name>_SandboxVars.lua`, in the `Talky` table. Stop the server before you edit it:
  ```lua
  Talky = {
      AllowedPlayers = "streamer_one, streamer_two",
      AllowAdmins = true,
      MaxZombiesPerAction = 30,
      -- ...
  },
  ```
- during a game, for a player with the admin role: **Admin panel** > **Sandbox Options** > **Talky**.

A world created before 0.4.0 has no Talky options: the defaults apply until you set them. Talky reads the values again every second.

| Option (in game) | `Talky.` name | Default | Range | Effect |
|---|---|---|---|---|
| Allowed players | `AllowedPlayers` | empty | text | Usernames that may use Talky, separated by commas or semicolons (a space is part of the name). |
| Admins and moderators may use Talky | `AllowAdmins` | on | | Roles with the CreateHorde capability may use Talky without being in the list. |
| Max zombies per action | `MaxZombiesPerAction` | 30 | 1-300 | One `spawn_zombie` or `horde` step. |
| Max zombies per job | `MaxZombiesPerJob` | 60 | 1-500 | All the steps of one job together. |
| Max zombies per player per 10 minutes | `MaxZombiesPer10Min` | 150 | 1-2000 | Jobs of one streamer, over the last 10 minutes. |
| Max zombies per 10 minutes (all players) | `MaxZombiesPer10MinServer` | 400 | 1-5000 | Every streamer together. |
| Max spawn distance (tiles) | `MaxSpawnDistance` | 40 | 5-150 | Distance from the streamer. |
| Max steps per job | `MaxStepsPerJob` | 100 | 10-500 | Steps beyond it are dropped; the console of the streamer's game says how many. |
| Max waiting jobs per player | `MaxQueuedJobs` | 10 | 1-50 | Beyond it the server answers `busy` and the streamer's game sends the job again 5 seconds later. |
| Max jobs running at the same time per player | `MaxActiveJobs` | 4 | 1-20 | A job keeps its slot during its `wait` steps. |
| Max jobs per minute per player | `MaxJobsPerMinute` | 30 | 1-120 | Beyond it the server answers `rate_limited` and the job is sent again later, until its time to live ends. |
| Zombies and hordes | `AllowZombies` | on | | `spawn_zombie`, `horde`. |
| Items | `AllowItems` | on | | `give_item` (100 items per action at most). |
| Max items per player per 10 minutes | `MaxItemsPer10Min` | 300 | 1-5000 | |
| Forbidden items | `ItemDenylist` | empty | text | Full item types separated by commas, for example `Base.Katana, Base.Shotgun`. |
| Vehicles | `AllowVehicles` | on | | `vehicle`, outdoors, only when the streamer is on the ground floor. |
| Max vehicles per player per 10 minutes | `MaxVehiclesPer10Min` | 2 | 1-20 | Each vehicle stays in the save. |
| XP | `AllowXp` | on | | `xp` (1000 XP per action at most, skills only: not the categories such as `Combat`). |
| Max XP per player per 10 minutes | `MaxXpPer10Min` | 5000 | 1-100000 | |
| Heal and stats | `AllowPlayerEffects` | on | | `heal`, `stat`, on the streamer's own character. |
| Weather and thunder | `AllowWeather` | on | | `weather`, `thunder`. Same weather for every player, 12 game hours per action at most. |
| Weather cooldown (minutes) | `WeatherCooldownMinutes` | 15 | 0-240 | For the whole server. |
| Thunder cooldown (seconds) | `ThunderCooldownSeconds` | 30 | 0-3600 | For the whole server. |
| Time of day | `AllowTime` | on | | `time`. Same time for every player. |
| Time cooldown (minutes) | `TimeCooldownMinutes` | 30 | 0-240 | For the whole server. |
| Fire | `AllowFire` | **off** | | `fire`, and the `onFire` parameter of `spawn_zombie` / `horde` (zombies appear without fire when off). Fire spreads and can reach the bases of other players. |
| Helicopter | `AllowHelicopter` | **off** | | `helicopter`. On a server the helicopter flies to a random player, not to the streamer. |
| Helicopter with several players online | `HelicopterAnyTarget` | off | | Off: `helicopter` only runs while one player is online. |
| Helicopter cooldown (minutes) | `HelicopterCooldownMinutes` | 60 | 0-600 | For the whole server. |
| Noise and sounds | `AllowSounds` | on | | `noise`, `sound`. |
| Max noise radius (tiles) | `MaxNoiseRadius` | 80 | 1-300 | A noise attracts every zombie in this radius. |
| Distance from other players (tiles) | `ProtectRadius` | 15 | 0-100 | No Talky zombie, fire or vehicle appears this close to another online player, nor in a safehouse the streamer may not enter. 0 turns off the distance check (the safehouse check stays). |
| Banners | `BannerAudience` | The streamer only | The streamer only (1), Every player, with the streamer's name (2) | `notify` banners and the banner of a named zombie that dies. With 2, other players see `[<streamer>] ` before the text; past 6 banners a minute per streamer or 20 a minute in all (`notify` banners and named zombie deaths counted together), the next ones go to the streamer only. |
| Actions of other mods | `AllowCustomActions` | off | | Actions other mods add with `Talky_Actions.register` and mark `network = true`. |

The category toggles return the code `disabled`; the budgets return `budget` and the cooldowns `cooldown` (see [Events sent back by the game](#events-sent-back-by-the-game)).

Fixed limits on a server (not options): 50 waiting jobs and 12 running jobs for every player together; 10 zombies created per tick for the whole server (a bigger group appears over the next ticks); 100 items and 1000 XP per action; 12 game hours of weather per action; 900 seconds of `wait` steps per job; 10 `fire` steps per streamer and 20 for the whole server per 10 minutes; 60 `noise` and `sound` steps per streamer per 10 minutes (beyond these budgets: `action_failed` with `budget`); 12 `say` lines a minute per streamer and 60 for the whole server, beyond which the line still shows above the character but does not go to the chat; 128 named zombies on the server, 32 per streamer; 5 commands per second per player. In single player, `fire`, `noise`, `sound` and `say` have no budget.

A job that has not started when its time to live ends is dropped (`job_expired`), in single player too: the time to live is `jobTtlSeconds` of the bridge, and never more than 15 minutes after the bridge created the job.

### Refused and delayed jobs

- **Refused for good** (`not_allowed`, `invalid`, `unknown_action`, `disabled`, `expired`): the game tells the bridge the job is taken, so it leaves the inbox. It writes `job_rejected {seq, workflow, reason}` for the bridge, shows the banner `Talky: job #12 refused by the server (not allowed)`, and F8 > Status shows the last refused job. The bridge window prints the reason with what to do. `duplicate` (the server already has the job) counts as accepted.
- **Too large to be sent** (`too_large`, multiplayer only): the job does not fit in one network message of the game, so the streamer's game never sends it. It is acknowledged and reported like a refused job, with the banner `Talky: job #12 is too large to be sent to the server, skipped`. Give the workflow fewer steps (count the turns of `repeat`) or shorter texts.
- **Delayed** (`busy`: waiting list full; `rate_limited`: too many jobs in the last minute): the game sends the job again later, 5 seconds later for `busy`, and keeps the order of the jobs behind it.
- **One step refused** (an action turned off, a cooldown, a budget used up, no free square): the other steps run, and the bridge receives `action_failed` with the code. A job whose steps are all refused is refused for good, with the reason of the first step.
- **No answer**: the game sends the job again every 30 seconds until its time to live ends. F8 > Status counts the jobs without answer after 15 seconds.
- **Expired on the server**: a job that waited past its time to live before it could start gives `job_expired {seq, workflow}`.

### Limits in multiplayer

- The bridge runs on the streamer's PC. A dedicated server cannot read the jobs of a bridge installed on its own machine in this version.
- Weather and time of day are the same for every player. Their cooldowns count for the whole server.
- On a server, `testHelicopter()` picks a random online player: the helicopter is off by default and, when on, only runs while one player is online, unless **Helicopter with several players online** is on (otherwise `action_failed` with `helicopter_random_target`).
- On a server, a storm starts at once for every player; a blizzard or a tropical storm reaches the other players at the next climate update of the server, up to 10 game minutes later. A time change reaches the players within about 10 seconds.
- Names above zombies last while the zombie stays in the game: a zombie that despawns far from players, a zombie the game reuses, a server restart or 30 minutes remove the name. Every player sees the names (often viewer names). With more than 32 named zombies per streamer, or 128 in all, the oldest lose their name.
- `zombie_killed` is sent once per zombie, to the streamer whose job spawned it, and only while that streamer is online. `byPlayer` is `true` when that streamer killed it.
- `heal` runs on the streamer's game (health belongs to the player's game in multiplayer). On a dead character it gives `action_failed` with `dead`.
- **Distance from other players** can leave a spawn, a fire or a vehicle without a free square: `action_failed` with `no_square`.
- The jobs of a streamer who is offline or dead, or of a paused server, wait; `wait` steps keep counting in real time. After 15 minutes offline, the jobs of that streamer are dropped. The events of a streamer who is offline are lost.
- The server and every client must run the same Talky version. Otherwise F8 > Status shows `Talky <version> on the server, 0.4.0 here: install the same version on both.` and nothing is sent.
- Actions that other mods add with `Talky_Actions.register` run on a server only with `network = true` and the option **Actions of other mods**.

### To check in a real game

Version 0.4.0 was tested with a simulated game API: the Lua runs in Kahlua with fake game objects, in single player, on a dedicated server with several clients and in a hosted game. Not yet checked in a real game:

- `heal` (on the streamer's game) and `stat` (changed on the server, then sent to the player);
- names above zombies in multiplayer;
- the target of the helicopter on a server (a random player);
- the delay of a blizzard or a tropical storm on a server (next climate update);
- the delay of a time change on a server (about 10 seconds);
- the **Allow me (host)** button in a hosted game;
- `say` through the chat in multiplayer, items on the ground on a server, the vehicle type check, the role and safehouse checks of the server code, and the empty default of the text options (**Allowed players**, **Forbidden items**).

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
| `{ "action": "http", "target": "lt_report", "body": {...} }` | outgoing HTTP call by the bridge to a target of `httpTargets` in `bridge\config.json`, which holds the address, the headers and the HMAC secret (see [Sending a game event to LibertyTalk](#sending-a-game-event-to-libertytalk)); `method` is optional. A step can give `url` and `headers` itself instead of `target`: the bridge sends them, with a warning for the headers, since every game mod can read `talky_config.json`; it refuses a step with `hmacSecret`. Only to the allowed hosts (see Security) |
| `{ "action": "log", "message": "..." }` | line in the bridge window |

`http` and `log` steps run in the background: they do not delay the game steps nor the reply to LibertyTalk.

## Actions in the game

| Action | Parameters |
|---|---|
| `notify` | `text` (200 characters at most), `color` (`#rrggbb`), `seconds` (60 at most): banner on screen |
| `say` / `halo` | `text` (200 characters at most): the character speaks (in multiplayer, in the "say" chat, seen by nearby players) / floating text |
| `spawn_zombie` | `name` (40 characters at most), `count`, `distance`, `minDistance`, `outfit`, `crawler`, `health`, `onFire`, `fakeDead`, `aggro` (true by default), `cluster`, `radius`, `sameName`, `color`, `outside` |
| `horde` | like `spawn_zombie`, as a group (15 zombies at 25 tiles by default) |
| `noise` | `radius`, `volume`, `sound`: a noise that attracts zombies |
| `sound` | `name`: a game sound |
| `helicopter` | starts the helicopter event (on a server: toward a random player) |
| `thunder` | `strike` |
| `weather` | `type`: `storm`, `blizzard`, `tropical` or `clear`, `hours`. In single player, `stage` (number) also works. The current weather stops first. |
| `time` | `hour` (0 to 23.99) |
| `fire` | `distance`, `minDistance`: a fire near the player |
| `vehicle` | `script` (for example `Base.PickUpTruck`), `distance`: outdoors |
| `give_item` | `item` (for example `Base.Katana`), `count` (100 at most), `onGround` |
| `heal` | full heal (on the streamer's game) |
| `stat` | `stat` (`PANIC`, `STRESS`, `FATIGUE`, `HUNGER`, `THIRST`, `INTOXICATION`...), `op` (`add`, `set` or `remove`), `value` |
| `xp` | `perk` (for example `Woodwork`), `amount` (10 000 at most in single player, 1000 on a server). On a server the amount is a whole number: the fraction is dropped, and a value below 1 gives `action_failed` with `invalid`. Single player keeps the fractions. |
| `emit` | `event`, `data`: sends an event back to the bridge (not `test_workflow`, `game_started` nor `player_died`, which only the game itself writes) |

`item` and `script` must exist in the game scripts; on a server the item must also be neither hidden nor obsolete, and outside **Forbidden items**. On a server, each action also follows the sandbox options (see [Multiplayer](#multiplayer)): categories, budgets, cooldowns, distance from other players.

In single player, named zombies show their name above their head and keep it after a save (it is stored in their modData); in multiplayer, see [Limits in multiplayer](#limits-in-multiplayer). In single player, the caps are set on the Settings page: 60 zombies per action, 8 jobs at the same time and 60 tiles of distance by default. In multiplayer, the sandbox options of the server set them. A job older than `jobTtlSeconds` (15 minutes by default, 15 minutes at most: a larger value in `bridge\config.json` is brought back to 900 seconds, with a warning at the start of the bridge) is skipped, so a game started late does not receive 40 hordes at once.

To add an action, in a Lua file of your mod or of another mod:

```lua
Talky_Actions.register("teleport", function(p, player) player:setX(p.x); player:setY(p.y) end)
```

This action runs in single player. To run an action on a server too, register it in a `shared/` or `server/` file (the `client/` files do not run on a server), declare it network-safe and its parameters; the server then keeps only these parameters, with their type, and the server option **Actions of other mods** must be on:

```lua
Talky_Actions.register("my_action", function(p, player, job, ctx)
    -- p.amount is a number; job = { seq, id, workflow, user }
end, { network = true, params = { amount = "number" } })
```

A handler returns nothing when it worked, or a short code (`"no_square"`, for example) that the bridge receives in `action_failed`.

## Events sent back by the game

| Event | Data |
|---|---|
| `zombie_killed` | `name`, `byPlayer` (a named zombie dies; `byPlayer` is `true` when the streamer killed it) |
| `player_died` | `hoursSurvived`, `zombieKills` |
| `game_started` | `mode` (`sp` or `client`), `host` (`true` for the host of a hosted game), `server` (server name, empty in single player). In multiplayer, written after the first answer of the server. |
| `job_done` | `seq`, `workflow` |
| `action_failed` | `seq`, `action`, `code`, and `error` with the same value (the field of 0.3.0) |
| `job_rejected` | `seq`, `workflow`, `reason`: a job refused for good (see [Refused and delayed jobs](#refused-and-delayed-jobs)) |
| `job_expired` | `seq`, `workflow`: a job that waited past its time to live before it could start |

`action_failed` codes: `unknown_action`, `disabled` (turned off on the server), `invalid` (a value the action cannot use; a step that cannot be read, not an object or without a valid `action`, comes with the action `step`), `cooldown`, `budget` (limit per 10 minutes or per job reached), `no_square` (no free square), `not_found` (unknown item, vehicle, sound, skill, stat or weather type), `refused` (the game refused the weather, or created none of the zombies of a `spawn_zombie` or `horde` step), `helicopter_random_target`, `error` (the action failed; details in the console of the game or of the server), `dead` (`heal` on a dead character).

`job_rejected` and `job_expired` are shown in the bridge window and on F8 > Status, and never run a workflow of `gameEvents`.

```json
"gameEvents": { "zombie_killed": "on_zombie_killed", "player_died": ["on_player_died", "report_to_libertytalk"] }
```

### Sending a game event to LibertyTalk

1. In LibertyTalk, create a workflow with the **Incoming webhook** trigger. It gives a URL (`https://api.liberty-talk.com/webhooks/workflow/<token>`) and a secret. Map the fields you need (`name`, `event`, `zombieKills`...).
2. In `bridge\config.json`, fill in the target `lt_report` of `httpTargets` (the `config.json` created from the example already has it, with `PASTE_...` placeholders that the bridge refuses to send), then restart the bridge:
   ```json
   "httpTargets": {
     "lt_report": {
       "url": "https://api.liberty-talk.com/webhooks/workflow/<token>",
       "headers": { "X-Webhook-Secret": "<secret>" }
     }
   }
   ```
3. In `talky_config.json`, enable the example workflow `report_to_libertytalk`. Its step names the target, so the URL and the secret never go to a file the game can read:
   ```json
   "report_to_libertytalk": {
     "steps": [
       { "action": "http", "target": "lt_report",
         "body": { "event": "{{event}}", "name": "{{name}}", "zombieKills": "{{zombieKills}}" } }
     ]
   }
   ```
4. Link it to a game event (F8 > Game events, or `gameEvents` above). LibertyTalk answers 202. The host of the target must be in `httpAllowedHosts` (`*.liberty-talk.com` by default).

A target can also sign the body: `"hmacSecret"` and `"hmacHeader": "X-LT-Signature"` in its `httpTargets` entry. LibertyTalk treats a signature without timestamp as a legacy one: prefer `X-Webhook-Secret`. With `target`, the `url`, `headers`, `hmacSecret` and `hmacHeader` written in the step are ignored (one warning per workflow). Without `target`, an `hmacSecret` written in the step makes the bridge refuse it, and `headers` written there are sent with a warning.

## Security

- **Token.** Every call to `/hooks/<id>` and `/fire/<workflow>` needs the token, in the `X-Bridge-Token` header or in `?token=`. The comparison runs in constant time. Without a valid token, every webhook id answers 401, so the ids cannot be guessed. A webhook listed in `hookTokens` of `bridge\config.json` has its own token and refuses the global one; a `token` written for a webhook in `talky_config.json` counts for nothing (the bridge window says so). `POST /fire/<workflow>` runs any workflow with the global token.
- **Network.** The bridge listens on `127.0.0.1` only (`host` in `config.json`). The tunnel is what makes it reachable from the internet.
- **Outgoing calls.** An `http` step only reaches the hosts listed in `httpAllowedHosts` of `bridge\config.json` (default `["*.liberty-talk.com"]`; `*.example.com` covers every subdomain of example.com but not example.com itself; `"*"` allows every host and removes this protection). Another step is refused and shown in the bridge window and on the F8 Status page. Redirects are not followed. The reason: `talky_config.json` lives in `Zomboid\Lua`, a folder every other mod can write to. Without the list, a mod could add an `http` step and use the bridge to send data anywhere, on the internet or on your local network. The list itself stays in `bridge\config.json`, out of reach of game mods.
- **Other mods.** Every mod running in the game can read `talky_status.json` and `talky_config.json`, write `talky_config.json` and the outbox, and send what it reads to the server it plays on. On a server, these are all the mods of the server's list. So no token, no http secret and no full webhook URL goes to these files: the tokens and the targets stay in `bridge\config.json`, `talky_status.json` lists only the ids of the webhooks with a dedicated token, and the **Copy command** buttons copy a command. Game mods can also read the clipboard: after `node bridge\bridge.js url`, paste the URL, then copy something else. Talky itself sends neither token, nor URL, nor webhook to the server. A mod can still add a workflow that calls an incoming webhook of any LibertyTalk account (a host of `httpAllowedHosts`), or run a workflow through a game event or **Test now**. Join only servers whose mod list you accept, or stop the bridge before you join. In doubt, run `node bridge\bridge.js new-token`, restart the bridge, then update the LibertyTalk widget and the webhook URLs.
- **Test now.** The bridge writes a random test code in `talky_status.json` at each start, and runs a `test_workflow` event only when it carries that code. The code only stops `test_workflow` lines that a Talky server would have the game write: the server never knows it (and the game already refuses to write these lines for the server). A mod running in the game can read it.
- **Multiplayer.** The server receives, for each job, its number, the workflow name, the viewer name and the game steps. The token, the public URL and the webhooks never leave the streamer's PC. The server keeps only the known parameters of each step, with their type and bounds (numbers such as `NaN` or `1e308` fall back to the default, texts are cut, colors must be `#rrggbb`), and never trusts a name sent by a client: the sender is the player of the connection. From the server, the streamer's game only writes `zombie_killed`, `job_done`, `action_failed`, `job_rejected` and `job_expired`, with fixed fields, 60 lines a minute at most; an `emit` step is written from the game's own copy of the job, and `test_workflow`, `game_started` and `player_died` only come from the game itself. Each player may send 5 Talky commands per second.
- **Caps.** `wait` 600 s, texts of `notify` / `say` / `halo` 200 characters, banners 60 s, zombie names 40 characters, `repeat` 100 iterations, 500 game steps and 20 `http` / `log` steps per job, 10 000 steps and loop turns walked through per job (past that, the rest of the workflow is skipped and the bridge window says so), 200 jobs waiting in the game in single player, body of a webhook call 64 KB. On a server, the sandbox options and the fixed limits of [Multiplayer](#multiplayer) apply on top.
- **On stream.** The F8 window never shows nor copies a token. `node bridge\bridge.js url` prints the URL with the token masked, unless you add `--show`. The bridge window shows `~` instead of your Windows user folder, error messages included. On its first launch, the bridge copies its new token to the clipboard without printing it.
- **Secrets on disk.** `bridge\config.json` and `bridge\bridge-state.json` are in `.gitignore` and never in the release zip. The Steam Workshop item only contains the mod.

## Limits

- Multiplayer has its own limits: see [Limits in multiplayer](#limits-in-multiplayer) and [To check in a real game](#to-check-in-a-real-game).
- The address of a quick tunnel changes at each launch: update the widget settings and the F8 public URL.
- Version 0.4.0 was tested with a simulated game API: the Lua runs in Kahlua (the Lua VM of the game) with fake game objects. Also to check in a real game, since 0.3.0: the position of the names above heads, zombie aggro (`spotted` / `pathToCharacter`), `testHelicopter()` outside debug mode, the weather stage numbers (taken from the B42 debug menu), the custom key binding, and `byPlayer`.
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
| The bridge logs `job #N` but nothing happens | Game paused, player dead, back to the main menu, job older than `jobTtlSeconds`, or 8 jobs already running (long `wait` steps). In multiplayer, also: the server has not accepted it yet (F8 > Status), or its limits (see the rows below). |
| F8 > Status: `the server refuses the jobs of <name>.` | Your username is not in **Allowed players** and your role does not have the CreateHorde capability: see [Who may use Talky](#who-may-use-talky). Host of a hosted game: click **Allow me (host)**. |
| F8 > Status: `no answer from the server.` | The Talky code of the server did not answer for 2 minutes, and the game sends nothing. Look for `[Talky]` lines and Lua errors in the console of the server (`server-console.txt`, or `coop-console.txt` for a hosted game), then join again. In single player, look in `console.txt`. |
| F8 > Status: `Talky <version> on the server, 0.4.0 here` | Install the same Talky version on the server and on every PC. |
| F8 > Status: `Bridge older than 0.4.0` | Update the bridge with the zip of the same release as the mod. Game events and **Test now** need it. |
| Status shows "skipped: no test code (update the mod)" or "skipped: test code mismatch, press Test now again" (an F8 window older than 0.4.0 shows "error: Test now refused: ...") | The bridge ran no test. First message: the test carried no test code, so the mod is older than 0.4.0: update it. Second message: the bridge restarted after the F8 window read its test code: press **Test now** again. The bridge window explains it once per start (`"Test now" refused: ...`). |
| `warning: the "token" of webhook "<id>" in talky_config.json is ignored` | The F8 window of Talky 0.3.0 saved a dedicated token there. Until you move it to `hookTokens` in `bridge\config.json` and restart the bridge, the webhook takes the bridge token, and a URL with the old token gets `401 bad token`. |
| `http step refused: "hmacSecret" written in the workflow` | Move the address and its secrets to `httpTargets` in `bridge\config.json`, write `"target": "<name>"` in the step, and restart the bridge (see [Sending a game event to LibertyTalk](#sending-a-game-event-to-libertytalk)). |
| `http step refused: fill "httpTargets" > "lt_report" in bridge/config.json first` | The target still holds a `PASTE_...` placeholder: put the URL and the secret of your incoming webhook there, then restart the bridge. |
| `warning: "jobTtlSeconds" in config.json is ...: 900 is used.` | The game and the server drop a job 15 minutes after the bridge created it: set `jobTtlSeconds` to 900 or less. |
| The bridge window shows `not sent to the server: too_large` | The job does not fit in one network message of the game: give the workflow fewer steps or shorter texts. |
| The bridge window shows `refused by the server: disabled` | An action of the job is turned off in the sandbox options of the server (**Zombies and hordes**, **Fire**, **Helicopter**...). |
| `action_failed` with `cooldown` or `budget` | A cooldown of the server (weather, thunder, time, helicopter) or a budget per 10 minutes or per job: see [Server options](#server-options-sandbox-options--talky). |
| `action_failed` with `helicopter_random_target` | Several players are online and **Helicopter with several players online** is off. |
| `action_failed` with `no_square` on a server | Another online player within **Distance from other players**, a safehouse the streamer may not enter, or no free square around the streamer. |
| Status shows "skipped: cooldown / condition not met / chance roll lost / workflow disabled" | The workflow refused the event: see its settings on the Workflows page. |
| `http step refused: host "..." is not in httpAllowedHosts` | Add the host to `httpAllowedHosts` in `bridge\config.json` and restart the bridge. |
| Nothing happens after a restart | The tunnel address changed: update the widget and the F8 public URL. |
| The mod is not in the list | Without the Workshop, the game needs `%USERPROFILE%\Zomboid\mods\Talky\42\mod.info`: copy the `Talky` folder of the zip, not the folder that contains it. Check that Talky is not installed twice (Workshop and `Zomboid\mods`). |

Logs: the game writes `[Talky]` lines in `%USERPROFILE%\Zomboid\console.txt`, a dedicated server in `Zomboid\server-console.txt`, the server of a hosted game in `Zomboid\coop-console.txt`. `http://127.0.0.1:7420/health?token=<token>` returns the number of jobs waiting, the last acknowledged job, the jobs acknowledged above it and the last 50 events.

Exchange files in `%USERPROFILE%\Zomboid\Lua\` of the streamer's PC: `talky_inbox.jsonl` (jobs), `talky_ack.txt` (`S`, or `S s1 s2 ...`: every job up to `S` is taken, and `s1`, `s2`... too), `talky_outbox.txt` (game events; `talky_outbox.jsonl` with Talky 0.3.0), `talky_status.json` (bridge heartbeat, with the test code and the ids of the webhooks that have a dedicated token, never a token) and `talky_config.json` (the configuration edited by the F8 window).

## `bridge\config.json` reference

| Key | Default | Role |
|---|---|---|
| `port` | `7420` | Port of the bridge. |
| `host` | `127.0.0.1` | Listening address. Keep `127.0.0.1`: the tunnel connects locally. |
| `token` | random | Token of the webhook calls, drawn when the bridge creates `config.json`. `node bridge\bridge.js new-token` draws a new one. |
| `hookTokens` | `{}` | `{ "<webhook id>": "<16 characters or more>" }`: a webhook with its own token, which then refuses `token`. |
| `zomboidLuaDir` | `%USERPROFILE%/Zomboid/Lua` | Folder shared with the mod. |
| `jobTtlSeconds` | `900` | A job older than this is skipped by the game (900 at most: a larger value is brought back to 900, with a warning at the start). |
| `httpAllowedHosts` | `["*.liberty-talk.com"]` | Hosts that `http` steps may call. |
| `httpTargets` | `lt_report` with placeholders | `{ "<name>": { "url", "headers", "hmacSecret", "hmacHeader", "method" } }`: the address and the secrets of an `http` step that says `"target": "<name>"`. Only `url` is required. |
| `settings` | `{"language": "en", "anonymousName": ""}`, `fr` when the regional format of Windows is French | Copied to `talky_config.json` on the first launch, then edited in F8 > Settings. |
| `webhooks`, `workflows`, `gameEvents` | examples | Copied to `talky_config.json` on the first launch. |
| `poll` | disabled | Experimental source without public address, see below. |

**Poll mode (experimental).** Instead of receiving webhooks, the bridge reads the LibertyTalk activity feed every `intervalSeconds` (10 s, 5 s at least) with an API token: `"url": "https://<tenant>.api.liberty-talk.com/community/<community_id>/activity?per_page=50"`, `"apiToken"`, optional `"headers"`. `types` maps an activity type to a workflow: `follow`, `subscribe`, `subscribe_gift`, `cheer`, `raid`, `donation`, `superchat`, `member` (`resub`, `member_gift`, `charity`, `boost` and `first_message` also exist). The bridge fills `user_name` from `actor_name`, `bits` (cheer), `viewers` (raid) and `total` (gifts) from `amount`. Events already in the feed when the bridge starts are not replayed.

## Development

- Bridge tests: `cd bridge`, then `npm test` (Node 18 or later, no dependencies). They start real bridges on free ports with a temporary game folder.
- Lua tests: `powershell -ExecutionPolicy Bypass -File tools\test-lua.ps1 -GameDir "<path to ProjectZomboid>"` (JDK 25 or later: the classes of game 42.21 are Java 25 classes; `-Java "<path to java.exe>"` picks another JDK). They compile every file with the Kahlua of the game jar, then run the mod with fake game objects, one Lua state per game process: a single player game, a dedicated server with several clients and a hosted game. Messages between processes are copied by the game's own network serializer. Covered: every page of the F8 window in English and French, translation keys, sandbox options, caps, permissions, acks, name tags, events back to the bridge. For a dedicated server installed alone, `-GameDir` can be its `java` folder.
- Steam Workshop folder: `tools\build-workshop.ps1` assembles `%USERPROFILE%\Zomboid\Workshop\Talky` (`-OutDir` to build it elsewhere), keeps the Workshop `id=` after the first upload and refuses the file types the Workshop rejects. Then, in the game: **Workshop > Create and update items**.
- Release: `tools\build-release.ps1` builds `dist\Talky-<version>-windows.zip` and `dist\SHA256SUMS.txt`. The version of `bridge\package.json` must match `modversion` in `mod.info`.
- `mod\Talky\42\poster.png` and `packaging\workshop\preview.png` are provisional images drawn by `tools\make-placeholder-images.ps1`.
- Translations: `mod\Talky\42\media\lua\shared\Translate\<LANG>\UI.json` (keys `UI_Talky_*`, the same keys in every language), `Sandbox.json` (the server options of `media\sandbox-options.txt`, keys `Sandbox_Talky_*`) and `Mod.json` (name and description of the mod).
- Code layout: `media\lua\client` runs only in the player's game, `media\lua\server` on the server and in single player, `media\lua\shared` everywhere. The server files never require a `client` file and never read or write files.

## License

MIT, see [LICENSE](LICENSE). The license covers the code, not the LibertyTalk and Tech Liberty names and logos.

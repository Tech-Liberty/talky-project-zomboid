# Talky: LibertyTalk live events for Project Zomboid (Build 42)

[Version française](README.fr.md)

Talky connects [LibertyTalk](https://liberty-talk.com) to Project Zomboid. A follow, a sub, bits, a raid, a channel point redemption or a Super Chat on your stream runs a workflow in your game: a zombie named after the new follower, a horde sized by the raid, the helicopter for 1000 bits. The game sends its own events back ("a named zombie died", "the player died"), and they can run workflows too, including a call to LibertyTalk.

Talky works in two modes:

- **Single player**: the bridge runs on your PC, next to your game.
- **Server** (dedicated, or a game hosted from the main menu): the admin runs the bridge on the machine of the server and adds the streamers in game. A streamer installs nothing but the mod, and pastes into their LibertyTalk widget the address and the token the admin gives them. See [Multiplayer](#multiplayer).

```
LibertyTalk                       your PC
+--------------+   HTTPS    +--------------+   files    +-------------------+
| trigger      |----------->| tunnel       |----------->| Project Zomboid   |
| (follow...)  |  webhook   |   |          |   inbox    | Talky mod (Lua)   |
|   |          |   call     | bridge.js    |<-----------| F8 window         |
| widget       |            | (workflows)  | ack/outbox |                   |
+--------------+            +--------------+            +-------------------+
```

**Why a bridge?** The Lua of Project Zomboid (Kahlua) cannot open a network connection. It can only read and write files in the `Zomboid\Lua\` folder of the game (or of the server). The bridge is a small Node.js program without dependencies: it receives the webhooks, runs the logic (conditions, random picks, cooldowns, templates) and writes jobs that the mod reads every second.

## Requirements

- Project Zomboid Build 42.20.1 or later.
- Node.js 18 or later, on the machine that runs the bridge: `winget install OpenJS.NodeJS.LTS` on Windows, the package of your distribution (when it is 18 or later) or [nodejs.org](https://nodejs.org) on Linux.
- Single player: Windows 10 or 11 on the PC that runs the game and the bridge, and cloudflared for the public address of the bridge: `winget install --id Cloudflare.cloudflared`.
- Server: the machine of the server (Linux or Windows), reachable from the internet on one TCP port (7420 by default). See [Multiplayer](#multiplayer).
- A LibertyTalk account with Twitch or YouTube connected.

## Install

There are two ways to get the mod. Use only one: two mods with the id `Talky` confuse the game. In both cases, the bridge comes from the GitHub release, and there is nothing to run before `start-bridge.cmd`.

**A. Mod from the Steam Workshop**

1. Subscribe to [Talky on the Steam Workshop](https://steamcommunity.com/sharedfiles/filedetails/?id=3830066321).
2. Download `Talky-0.5.0.zip` from the [GitHub releases](https://github.com/Tech-Liberty/talky-project-zomboid/releases) and extract it to a folder you keep, for example `Documents\Talky`.
3. Leave the `Talky` folder of the zip where it is: the Workshop already provides the mod, and the game does not read that folder outside `Zomboid\mods`.

**B. Without the Steam Workshop**

1. Download `Talky-0.5.0.zip` and extract it to a folder you keep, as in A.
2. Copy the `Talky` folder of the zip into `%USERPROFILE%\Zomboid\mods`, so that the game finds `%USERPROFILE%\Zomboid\mods\Talky\42\mod.info`. Copy only this folder: the bridge stays in `Documents\Talky`.

Do not extract the zip into `Zomboid\mods`. With the Workshop, the `Talky` folder of the zip would be a second copy of the mod. In both cases, removing or replacing a mod there can delete the bridge and its `bridge\config.json`. The bridge prints a warning at startup in both situations.

To check the download, compare `Get-FileHash Talky-0.5.0.zip -Algorithm SHA256` (Windows) or `sha256sum Talky-0.5.0.zip` (Linux) with `SHA256SUMS.txt` of the release.

**Updating from 0.4.0.** Replace the mod and the bridge at the same time, on the server and on every PC. Keep `bridge\config.json` and `Zomboid\Lua\talky_config.json`. Single player works as before. Multiplayer changed completely: the bridge no longer runs on the streamer's PC, and the game of a streamer no longer relays jobs to the server. The admin runs one bridge in server mode next to the server and adds the streamers in F8 > Webhooks (see [Multiplayer](#multiplayer)); a streamer who used 0.4.0 on a server can stop their own bridge and tunnel, and pastes into the LibertyTalk widget the address and the token the admin gives them. The sandbox options **Allowed players** and **Admins and moderators may use Talky** are gone: the list of streamers of F8 > Webhooks replaces them. Coming from 0.3.0: read the 0.4.0 notes of the [CHANGELOG](CHANGELOG.md) too.

## Start and test (single player)

1. Double-click `start-bridge.cmd` and keep its window open. On the first launch, you should see these lines, each one after the time:
   ```
   created ~\Documents\Talky\bridge\config.json with a random token (language: en)
   the token is in your clipboard and in config.json, never shown here: paste it into "Bridge token" in the LibertyTalk widget
   created ~\Zomboid\Lua\talky_config.json from config.json
   config loaded: 10 webhook(s), 14 workflow(s)
   Talky bridge 0.5.0 listening on http://127.0.0.1:7420
   game folder: ~\Zomboid\Lua
   http steps allowed to: *.liberty-talk.com
     webhook  POST /hooks/follow
   ```
   The first three lines only show on the first launch. With a French Windows, they read `(language: fr)` and `from config.json (fr: 19 text(s) translated)`.
2. In Project Zomboid: **Mods**, enable **Talky - LibertyTalk Live Events**, then start a solo game or load one. Press **F8**. The Status page shows `Bridge connected on port 7420 - 0 job(s) waiting  (v0.5.0)`, then `Single player: the jobs run in this game.`
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

## Give the bridge a public address (single player)

LibertyTalk refuses local and private addresses (protection against server-side request forgery), so the bridge needs a public address. In a second window:

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
   - **Talky bridge connection**: **Talky bridge public URL** (`talky_bridge_url`) without a `/` at the end: in single player, the tunnel address; on a server, the address the admin gives you (`http://<public IP of the server>:7420`); **Bridge token** (`talky_token`): in single player, the `token` value of `bridge\config.json` (the one the bridge put in your clipboard on its first launch); on a server, your own token, from the admin; **Chat command (without "!")** (`talky_command`), `zombie` by default.
   - **Events sent to the game**: one box per event, from **Send follows** to **Send new YouTube members** (`talky_on_follow`, `talky_on_sub`, `talky_on_gift`, `talky_on_bits`, `talky_on_raid`, `talky_on_points`, `talky_on_command`, `talky_on_donation`, `talky_on_superchat`, `talky_on_member`), all ticked by default.
5. In the **Activation** block, click **Activate**. The line changes to "Active on Global." and the **Listening to** block lists the accounts the widget listens to.

`talky_token` is declared as a secret variable: LibertyTalk keeps it without showing it again and masks it in execution traces. To change it, type the new value and save.

If LibertyTalk refuses an `http://` address with "Only the tunnel address, for example https://...", your LibertyTalk does not accept the address of a server bridge in clear text yet: give the bridge an `https://` address meanwhile (see [Ports and security](#ports-and-security)).

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

**Without the widget**, build your own LibertyTalk workflow: a trigger from the table, then the action **Webhook / API call** with the URL `<bridge address>/hooks/<id>`, the method `POST`, the additional headers `{"X-Bridge-Token":"<token>"}` and a JSON body built like the "Fields sent" column, for example `{"user_name":"{user_name}","bits":"{bits}"}`. Leave "Sign the request" on No: that signature uses a key the bridge does not know. The token can also go in the URL (`?token=...`), but the header keeps it out of the URL. In single player, a webhook listed in `hookTokens` takes its own token instead of the bridge token.

## Webhook URLs and tokens

In single player, the game never knows the tokens: they stay in `bridge\config.json`, which the game cannot read. These commands run in a terminal opened in the Talky folder, whether the bridge runs or not:

- `node bridge\bridge.js url <webhook>` puts the full URL of a webhook, `<public URL>/hooks/<webhook>?token=<its token>`, in the clipboard, and prints it with the token masked. The public URL is the one saved in F8 > Status; `--base https://<tunnel address>` gives another one. `--show` prints the full URL (not while the window is on stream). The **Copy command** buttons of F8 copy this command for the selected webhook. In server mode, add `--streamer <username>`: the URL carries the token of that streamer.
- `node bridge\bridge.js new-token` writes a new random token in `bridge\config.json`, the rest of the file unchanged, and puts it in the clipboard without printing it. Restart the bridge (the old token works until then), paste the new token into **Bridge token** of the LibertyTalk widget, and copy your webhook URLs again with `url`. The tokens of `hookTokens` and of the streamers of a server do not change.
- `hookTokens` in `bridge\config.json` gives a webhook its own token, 16 characters or more: `"hookTokens": { "follow": "<long random text>" }`. That webhook then refuses the bridge token. Restart the bridge after a change. F8 > Webhooks shows whether a webhook has a dedicated token, never the token. Single player only: in server mode, each streamer has their own token.

From the `bridge` folder, where `start-bridge.cmd` starts the bridge, the same commands are `node bridge.js url <webhook>` and `node bridge.js new-token`, or `npm run url -- <webhook>` and `npm run new-token`.

## The in-game window (F8)

The key can be changed in **Options > Keybinds > Talky**.

| Page | Single player | Multiplayer |
|---|---|---|
| **Status** | Bridge connected or offline, bridge version (with a warning when the bridge is older than 0.4.0), public URL of the tunnel, URL of each webhook with the token masked and a **Copy command** button (it copies `node bridge\bridge.js url <webhook>`; the game never copies a token), last events received by the bridge with the reason when one was skipped or refused. | Every player: the answer of the server, whether you are a streamer of this server, whether its bridge runs (and in server mode), its limits and the categories it turned off. Admins: the last events of the bridge. The host of a game who is not admin gets the **Allow me (host)** button. |
| **Webhooks** | Create, rename or delete webhooks. Choose the workflow each one runs, or routes based on the content. Whether the webhook has a dedicated token (set in `hookTokens` of `bridge\config.json`), and **Copy command**. | Admins only. **Streamers** tab: the public address of the bridge, the streamers, **+ Add streamer**, and for the selected one the two values of their widget, **Show token**, **Copy URL and token**, **New token**, **Remove**. **Webhooks** tab: the webhooks of the server, as in single player. |
| **Workflows** | Enable, cooldowns, chance, condition. Steps edited with one form per action (fields accept `{{user}}`), moved up or down, advanced steps in JSON (`if`, `random`, `repeat`). **Test now** with the name of your choice. | Admins only, the workflows of the server. **Test now** runs the workflow around your own character. |
| **Game events** | Link "a named zombie dies", "the player dies" and "the game starts" to a workflow. | Admins only, the game events of the server. |
| **Settings** | Caps (zombies per action, workflows at the same time, spawn distance), names above zombies, banner duration and position, language of the bridge texts, name for anonymous events. | The three caps show the values of the server, read only (`30 (set by the server)`). The names above zombies and the banners follow the configuration of the server: admins set them here for every player, the other players see them read only. Admins also set the language of the bridge texts and the name for anonymous events. |

In single player, **Save** writes `Zomboid\Lua\talky_config.json`, which the bridge reloads without a restart. On its first launch, the bridge creates this file from `bridge\config.json`. If F8 > Save created it first, with no webhook and no workflow, the bridge adds the examples of `config.json` to it and keeps the public URL and the settings already saved. After that, `talky_config.json` holds the webhooks, workflows, game events, public URL and settings, and `bridge\config.json` keeps the mode, the port, the token, the dedicated webhook tokens (`hookTokens`), the http targets and their secrets (`httpTargets`), the allowed hosts and the poll mode. A newer `config.example.json` never changes an existing `talky_config.json`: to get the new examples, rename `talky_config.json` and restart the bridge.

In multiplayer, the window of an admin loads the `talky_config.json` of the server and **Save** sends it back; the server writes it and the bridge reloads it. The other keys of the file stay as they are.

## Multiplayer

On a server, dedicated or hosted from the main menu, the bridge runs on the machine of the server. The streamers install nothing but the mod.

```
LibertyTalk                  machine of the server                              players
+-------------+  HTTP(S)  +----------------+   files   +---------------------+  network  +-----------+
| widget of   |---------->| bridge.js      |---------->| Project Zomboid     |---------->| games     |
| a streamer  | webhook + | --server       |   inbox   | server + Talky      |  effects, | + Talky   |
| (their      | their     | 0.0.0.0:7420   |<----------| (reads the jobs,    |  names,   | (F8)      |
|  token)     | token     |                | ack,      |  writes the events) |  F8       |           |
+-------------+           +----------------+ outbox    +---------------------+           +-----------+
```

### How it works

- The admin runs the bridge in server mode on the machine of the server, or on the PC that hosts the game. It listens on every address of the machine, port 7420 by default, and works with the `Zomboid/Lua` folder of the server.
- In game, the admin adds each streamer on **F8 > Webhooks** with their username. The bridge draws a token for each one. The admin sends the streamer the public address of the bridge (`http://<public IP of the server>:7420`) and their token.
- The streamer pastes the two values into their LibertyTalk widget: no bridge, no tunnel on their PC.
- A webhook call carries the token of a streamer. The bridge writes the job for that streamer (`target`), the server reads it from the inbox and runs it around their character. Every player sees the effects in the world.
- The server writes the game events (`zombie_killed`, `player_died`, `job_done`, `action_failed`...) with the streamer they are about; their workflows run for that streamer.
- One set of webhooks, workflows and game events for the whole server: the `talky_config.json` of the server. Admins edit it in F8.

### Install the mod on a server

The mod goes on the server and on every client. A player who joins a server only runs the mods of the server's list, so Talky must be in that list.

**Dedicated server.** Stop the server. In `Zomboid\Server\<server name>.ini` (`servertest.ini` by default; the `Zomboid` folder is in the home folder of the account that runs the server), add Talky to these two lists, separated from the other entries by `;`:

```ini
Mods=Talky
WorkshopItems=3830066321
```

- `WorkshopItems` takes the number at the end of the address of the Steam Workshop item: `3830066321` for Talky. The server downloads the mod when it starts, and the players who join get it.
- Without the Workshop, leave Talky out of `WorkshopItems` and copy the `Talky` folder of the zip into the `Zomboid\mods` folder of the server and of every player. Every copy must be the same version.
- Game 42.21 reads `Mods=\Talky` the same way as `Mods=Talky`.

**Hosted game.** In the main menu: **Host** > **Manage settings...**, select the settings, then **Edit Selected Settings**. On the **Mods** page, add Talky ("Add an installed mod to the list"). With the Workshop version, also add it on the **Steam Workshop** page. The **Talky** page of the same settings holds the options below (if it is missing, enable Talky in the **Mods** menu of the main menu and open the settings again).

### Run the bridge next to the server

**Linux (dedicated server).**

1. Install Node.js 18 or later.
2. Extract the zip to a folder of the account that runs the server, for example `~/talky`.
3. With that account: `sh ~/talky/start-bridge.sh`. It starts the bridge in server mode; on the first start it creates `bridge/config.json` with `"mode": "server"`.
4. Open the TCP port 7420 to the internet: the firewall of the machine (`sudo ufw allow 7420/tcp`, for example) and the one of the hosting provider, if any.
5. To start the bridge with the machine: `talky-bridge.service` of the zip is an example unit for systemd (instructions inside).

**Windows (dedicated server).** In a terminal in the Talky folder: `start-bridge.cmd server` (or a shortcut to `start-bridge.cmd` with the `server` argument). Open the port in an administrator PowerShell: `New-NetFirewallRule -DisplayName "Talky bridge" -Direction Inbound -Protocol TCP -LocalPort 7420 -Action Allow`.

**Hosted game.** The host runs `start-bridge.cmd server` on their PC: the server of a hosted game runs on the same PC, with the same `Zomboid\Lua` folder. Forward the TCP port 7420 of the router to this PC. Without a public address, a cloudflared tunnel works too (`cloudflared tunnel --url http://127.0.0.1:7420`): its `https://` address is then the public address of the bridge.

The bridge must use the `Zomboid/Lua` folder of the server: run it with the account that runs the server. For a server started with `-cachedir=<folder>`, set `zomboidLuaDir` in `bridge/config.json` to `<folder>/Lua`. At its start, the bridge window shows `listening on http://0.0.0.0:7420 (server mode)`, the number of streamers and the public address. The console of the server shows `[Talky] server ready (Talky 0.5.0)`, then `inbox ready, last seq = 0 (server)` (`Zomboid\server-console.txt`, or `coop-console.txt` for a hosted game).

### Add a streamer (admins)

1. Press **F8**, page **Webhooks**, tab **Streamers**. The page is reserved to the admins: roles with the **CreateHorde** capability (admin and moderator by default). The server checks it at every request.
2. **Public address of the bridge**: `http://<public IP of the server>:7420`, then **Save**. An address typed without `http://` gets it, with the port of the bridge (`203.0.113.5` becomes `http://203.0.113.5:7420`). `publicUrl` in `bridge/config.json` sets it too.
3. Type the username of the streamer at the bottom left, then **+ Add streamer**. A second later the bridge has drawn their token and the streamer shows in the list.
4. Select the streamer. The page shows the two values of their widget, the token masked (**Show token** shows it). **Copy URL and token** puts both in the clipboard, one per line: send them to the streamer in private, never on stream.
5. **New token**: the old token stops at once, the streamer pastes the new one into the widget. **Remove**: their token stops, and their jobs waiting or running are dropped.

The username is the account name on the server (only A to Z ignore case, as for the accounts of the game). A streamer can be added before their first connection: their jobs wait while they are offline.

Hosted game: the host's account starts with the default role, so the host is not admin at first. F8 > Status and F8 > Webhooks then show **Allow me (host)**: the button sends `/setaccesslevel "<your username>" admin` to the server, which accepts this command from the host of the game. A few seconds later the window shows the admin pages.

### What the streamer does

1. Join the server (the mod comes with the server's list).
2. In their LibertyTalk widget: **Talky bridge public URL** = the address from the admin, **Bridge token** = their token. **Save**, then **Activate** (see [Connect LibertyTalk](#connect-libertytalk-the-project-zomboid--talky-widget)).
3. F8 > Status shows `You are a streamer of this server: the events of your live happen around your character.`

### Ports and security

- The bridge listens on TCP 7420 (`port` of `bridge/config.json`), on every address (`host` empty or `0.0.0.0`). Only this port is needed; the game server keeps its own ports.
- **HTTP in clear text.** Between LibertyTalk and the bridge, the token of the streamer travels in clear (`X-Bridge-Token` header): someone who can read that traffic could reuse it until the admin draws a new one. For https, put a reverse proxy with a certificate in front of the bridge (Caddy, nginx...), set `"host": "127.0.0.1"` in `bridge/config.json` so that the bridge only answers the proxy, and give the `https://` address of the proxy as public address.
- The token of the bridge (`token` of `bridge/config.json`) is for the admin, on the machine of the server (`node bridge.js fire <workflow> streamer=<username>`, `/health`). The streamers never need it, and `/hooks/<id>` refuses it in server mode.
- The tokens of the streamers stay on the machine of the server: `bridge/streamers.json` (the copy the bridge trusts), and `Zomboid/Lua/talky_streamers.json`, which the server code reads to show them to the admins. They only go to the game of an admin who opens the Streamers tab. Every mod of the server's list can read the `Zomboid/Lua` folder of the server: install on a server only mods you trust. In a hosted game, the host's game shares that folder.
- The bridge closes slow connections (10 s for the headers, 15 s for a request), keeps 64 connections at most and refuses bodies over 64 KB. Without a valid token, every webhook id answers 401.

### Who may do what

- **The streamers of F8 > Webhooks** get the effects of their own live, around their own character. The bridge only writes a job for a known token, and the server only runs a job for a streamer of its list.
- **The admins** (CreateHorde capability, admin and moderator by default) manage the streamers, edit the configuration of the server, and run **Test now**, which runs the workflow around their own character, streamer or not.
- The server checks the capability at every command, never trusts a name sent by a client (the player is the one of the connection), and checks again once a second that the owner of each job is still a streamer: a streamer removed during the game loses their waiting and running jobs (`job_rejected` with `not_streamer`).
- In single player every job runs, and the sandbox options of Talky do not apply: the caps are those of F8 > Settings.

### Server options (Sandbox Options > Talky)

Where to set them:

- hosted game: the **Talky** page of the settings (see above);
- dedicated server: `Zomboid\Server\<server name>_SandboxVars.lua`, in the `Talky` table. Stop the server before you edit it:
  ```lua
  Talky = {
      MaxZombiesPerAction = 30,
      AllowFire = false,
      -- ...
  },
  ```
- during a game, for a player with the admin role: **Admin panel** > **Sandbox Options** > **Talky**.

A world created before 0.4.0 has no Talky options: the defaults apply until you set them. Talky reads the values again every second.

| Option (in game) | `Talky.` name | Default | Range | Effect |
|---|---|---|---|---|
| Max zombies per action | `MaxZombiesPerAction` | 30 | 1-300 | One `spawn_zombie` or `horde` step. |
| Max zombies per job | `MaxZombiesPerJob` | 60 | 1-500 | All the steps of one job together. |
| Max zombies per player per 10 minutes | `MaxZombiesPer10Min` | 150 | 1-2000 | Jobs of one streamer, over the last 10 minutes. |
| Max zombies per 10 minutes (all players) | `MaxZombiesPer10MinServer` | 400 | 1-5000 | Every streamer together. |
| Max spawn distance (tiles) | `MaxSpawnDistance` | 40 | 5-150 | Distance from the streamer. |
| Max steps per job | `MaxStepsPerJob` | 100 | 10-500 | Steps beyond it are dropped; the console of the server says how many. |
| Max waiting jobs per player | `MaxQueuedJobs` | 10 | 1-50 | Beyond it, the next jobs of that streamer stay in the inbox of the bridge and are read again a second later. |
| Max jobs running at the same time per player | `MaxActiveJobs` | 4 | 1-20 | A job keeps its slot during its `wait` steps. |
| Max jobs per minute per player | `MaxJobsPerMinute` | 30 | 1-120 | Beyond it, the next jobs of that streamer stay in the inbox until the minute is over, or until their time to live ends. |
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

Fixed limits on a server (not options): 50 waiting jobs and 12 running jobs for every player together; 10 zombies created per tick for the whole server (a bigger group appears over the next ticks); 100 items and 1000 XP per action; 12 game hours of weather per action; 900 seconds of `wait` steps per job; 10 `fire` steps per streamer and 20 for the whole server per 10 minutes; 60 `noise` and `sound` steps per streamer per 10 minutes (beyond these budgets: `action_failed` with `budget`); 12 `say` lines a minute per streamer and 60 for the whole server, beyond which the line still shows above the character but does not go to the chat; 128 named zombies on the server, 32 per streamer; 5 commands per second per player; 200 streamers. In single player, `fire`, `noise`, `sound` and `say` have no budget.

A job that has not started when its time to live ends is dropped, in single player too: the time to live is `jobTtlSeconds` of the bridge, and never more than 15 minutes after the bridge created it.

### Refused and delayed jobs

- **Refused for good** (`not_streamer`, `disabled`, `unknown_action`, `invalid`): the server takes the job out of the inbox (ack) and writes `job_rejected {seq, workflow, reason, streamer}`. The bridge window prints the reason with what to do, and F8 > Status (admins) shows it. `not_streamer`: the job names no streamer of the server (removed in F8 > Webhooks, or a bridge in solo mode next to the server).
- **Delayed** (the waiting list of the streamer is full, or too many jobs in the last minute): the job stays in the inbox and the server reads it again, the next second or when the minute is over. The jobs of the same streamer behind it wait too, so their order is kept; the jobs of the other streamers go on.
- **One step refused** (an action turned off, a cooldown, a budget used up, no free square): the other steps run, and the bridge receives `action_failed` with the code. A job whose steps are all refused is refused for good, with the reason of the first step.
- **Expired**: a job older than its time to live when the server reads it is taken without running; one that waited past it in the queue of the server, or whose streamer stayed offline 15 minutes, gives `job_expired {seq, workflow, streamer}`.

### Limits in multiplayer

- The machine of the server must be reachable from the internet on the port of the bridge, or through a reverse proxy or a tunnel. A rented server where you cannot run Node.js cannot run the bridge.
- Weather and time of day are the same for every player. Their cooldowns count for the whole server.
- On a server, `testHelicopter()` picks a random online player: the helicopter is off by default and, when on, only runs while one player is online, unless **Helicopter with several players online** is on (otherwise `action_failed` with `helicopter_random_target`).
- On a server, a storm starts at once for every player; a blizzard or a tropical storm reaches the other players at the next climate update of the server, up to 10 game minutes later. A time change reaches the players within about 10 seconds.
- Names above zombies last while the zombie stays in the game: a zombie that despawns far from players, a zombie the game reuses, a server restart or 30 minutes remove the name. Every player sees the names (often viewer names). With more than 32 named zombies per streamer, or 128 in all, the oldest lose their name.
- `zombie_killed` is written once per zombie, for the streamer whose job spawned it, online or not. `byPlayer` is `true` when that streamer killed it.
- `heal` runs on the streamer's game (health belongs to the player's game in multiplayer).
- **Distance from other players** can leave a spawn, a fire or a vehicle without a free square: `action_failed` with `no_square`.
- The jobs of a streamer who is offline or dead, or of a paused server, wait; `wait` steps keep counting in real time. After 15 minutes offline, the jobs of that streamer are dropped (`job_expired`).
- The server and every client run the same Talky version: the game only lets a player join with the mods of the server.
- Actions that other mods add with `Talky_Actions.register` run on a server only with `network = true` and the option **Actions of other mods**.

### To check in a real game

Version 0.5.0 was tested with a simulated game API (the Lua runs in Kahlua with fake game objects, one Lua state per game process: a single player game, a dedicated server with several clients, a hosted game) and with real bridges started by the tests, then in a real game on 2026-10-30, on Build 42.21, with real Twitch events sent by LibertyTalk.

Checked in a real game:

- single player: the bridge and its tunnel, the F8 pages, **Test now**, the banners, the named zombies and the position of the names above heads, zombies going for the player, bits, `player_died`, a real Twitch follow end to end, the helicopter (`testHelicopter()` outside debug mode) and the weather stages;
- a dedicated server started with `-cachedir`, with Talky from the Steam Workshop on the server and the client: the server code reading and writing the `Zomboid/Lua` folder of the server, the F8 window of an admin (configuration saved, a streamer added, **Copy URL and token**), a chat command sent by LibertyTalk and run by the server around the streamer, and `player_died` read on the server.

Not yet checked in a real game:

- the server of a hosted game and the **Allow me (host)** button;
- LibertyTalk calling an `http://<IP>:<port>` address (the server test went through an `https://` tunnel address; LibertyTalk accepts both);
- `getServerName()` of `game_started` on a server;
- still to check since 0.4.0: `heal` (on the streamer's game) and `stat` (changed on the server, then sent to the player); names above zombies in multiplayer; the target of the helicopter on a server; the delay of a blizzard or of a time change on a server; `say` through the chat; items on the ground; the vehicle type check; the role and safehouse checks of the server code; the empty default of **Forbidden items**.

## Writing workflows by hand

The F8 window covers everything below. This section is for those who prefer to edit `Zomboid\Lua\talky_config.json` (in multiplayer, the one of the server).

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

In server mode, the cooldowns count per streamer: a `!zombie` on one stream does not hold the others.

### Templates `{{ }}`

- `{{user}}`, `{{bits}}`, `{{payload.field.sub_field}}`, `{{query.param}}`. `{{user}}` is the `user` field when the call has one, otherwise the first field found among `user_name`, `author_display_name`, `display_name`, `donor`, `chatter_name`, `actor_name`, `username`, `author_username`, `user_login` and `name`, so the same workflow works for Twitch and YouTube. When none is filled, it is the name for anonymous events (F8 > Settings).
- In server mode, `{{streamer}}` is the username of the streamer the job is for.
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
| `emit` | `event`, `data` (8 KB at most): writes an event for the bridge (not `test_workflow`, `game_started`, `player_died`, `job_rejected`, `job_expired` nor the streamer requests, which only Talky writes: `action_failed` with `invalid`) |

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

In server mode, the server writes them, and each one about a job or a player also carries `streamer`: the workflows of `gameEvents` then run for that streamer.

| Event | Data |
|---|---|
| `zombie_killed` | `name`, `byPlayer` (a named zombie dies; `byPlayer` is `true` when the streamer killed it) |
| `player_died` | `hoursSurvived`, `zombieKills` (in server mode: a streamer dies) |
| `game_started` | `mode` (`sp`, or `server` when a server starts), `host`, `server` (server name, empty in single player). No streamer: its workflows only run their `http` and `log` steps in server mode. |
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

- **Token.** Every call to `/hooks/<id>` and `/fire/<workflow>` needs a token, in the `X-Bridge-Token` header or in `?token=`. The comparison runs in constant time. Without a valid token, every webhook id answers 401, so the ids cannot be guessed. Single player: the token of the bridge, or for a webhook listed in `hookTokens` of `bridge\config.json` its own token (it then refuses the bridge token); a `token` written for a webhook in `talky_config.json` counts for nothing (the bridge window says so). Server mode: `/hooks/<id>` takes the token of a streamer only, and that token names the streamer; `/fire/<workflow>` takes the token of a streamer, or the token of the bridge with `streamer=<username>`.
- **Network.** Single player: the bridge listens on `127.0.0.1` only (`host` empty in `config.json`); the tunnel is what makes it reachable from the internet. Server mode: the bridge listens on every address (`0.0.0.0`), in clear text: see [Ports and security](#ports-and-security).
- **Outgoing calls.** An `http` step only reaches the hosts listed in `httpAllowedHosts` of `bridge\config.json` (default `["*.liberty-talk.com"]`; `*.example.com` covers every subdomain of example.com but not example.com itself; `"*"` allows every host and removes this protection). Another step is refused and shown in the bridge window and on the F8 Status page. Redirects are not followed. The reason: `talky_config.json` lives in `Zomboid\Lua`, a folder every other mod can write to. Without the list, a mod could add an `http` step and use the bridge to send data anywhere, on the internet or on your local network. The list itself stays in `bridge\config.json`, out of reach of game mods.
- **Other mods.** Every mod running in the game can read `talky_status.json` and `talky_config.json`, write `talky_config.json` and the outbox. So, in single player, no token, no http secret and no full webhook URL goes to these files: the tokens and the targets stay in `bridge\config.json`, `talky_status.json` lists only the ids of the webhooks with a dedicated token, and the **Copy command** buttons copy a command. Game mods can also read the clipboard: after `node bridge\bridge.js url`, paste the URL, then copy something else. A mod can still add a workflow that calls an incoming webhook of any LibertyTalk account (a host of `httpAllowedHosts`), or run a workflow through a game event or **Test now**. On a server, the mods of the server's list can also read `talky_streamers.json` (the tokens of the streamers) and write the outbox (the requests of the admins about the streamers): install on a server only mods you trust. An `emit` step can never write these requests.
- **Test now.** The bridge writes a random test code in `talky_status.json` at each start, and runs a `test_workflow` event only when it carries that code. In multiplayer, the server writes the event for an admin, with the code read from `talky_status.json` of the server.
- **Multiplayer.** No job crosses the network: the server reads them from the bridge's files. A client only receives the effects of its own game (banners, `say`, `halo`, `heal`), the names above zombies and, for an admin, what the F8 window needs. The server checks the capability of the player at every admin command, keeps only the known parameters of each step, with their type and bounds (numbers such as `NaN` or `1e308` fall back to the default, texts are cut, colors must be `#rrggbb`), and never trusts a name sent by a client: the player is the one of the connection. Each player may send 5 Talky commands per second.
- **Caps.** `wait` 600 s, texts of `notify` / `say` / `halo` 200 characters, banners 60 s, zombie names 40 characters, `repeat` 100 iterations, 500 game steps and 20 `http` / `log` steps per job, 10 000 steps and loop turns walked through per job (past that, the rest of the workflow is skipped and the bridge window says so), 200 jobs waiting in the game in single player, body of a webhook call 64 KB. On a server, the sandbox options and the fixed limits of [Multiplayer](#multiplayer) apply on top.
- **On stream.** The F8 window never shows a token, except the Streamers tab of an admin after **Show token**. `node bridge\bridge.js url` prints the URL with the token masked, unless you add `--show`. The bridge window shows `~` instead of your user folder, error messages included, and never prints a token. On its first launch, the bridge copies its new token to the clipboard without printing it.
- **Secrets on disk.** `bridge\config.json`, `bridge\streamers.json` and `bridge\bridge-state.json` are in `.gitignore` and never in the release zip. The Steam Workshop item only contains the mod.

## Limits

- Multiplayer has its own limits: see [Limits in multiplayer](#limits-in-multiplayer) and [To check in a real game](#to-check-in-a-real-game).
- The address of a quick tunnel changes at each launch: update the widget settings and the F8 public URL.
- Version 0.5.0 was tested in a real game on Build 42.21, in single player and on a dedicated server (see [To check in a real game](#to-check-in-a-real-game)). Still to check since 0.3.0: the custom key binding, and `byPlayer`.
- The poll mode (below) was not tested against a live LibertyTalk instance, and does not exist in server mode.

## Troubleshooting

| Symptom | Cause and fix |
|---|---|
| F8 shows "Bridge offline" | The bridge is not running, or `zomboidLuaDir` in `config.json` points to the wrong folder (game started with `-cachedir`). |
| `No config at ... Start the bridge once (start-bridge.cmd, or start-bridge.sh on Linux)`, after `node bridge\bridge.js fire ...` | `bridge\config.json` does not exist yet. Start the bridge once: it creates the file. |
| `Cannot create ...\bridge\config.json` | You cannot write to the Talky folder (under `C:\Program Files`, say). Move it to `Documents\Talky` and start `start-bridge.cmd` again. |
| `Set a long random "token" in config.json` | The token is empty or still `change-me...` (a `config.json` copied by hand from `config.example.json`). Put a long random string there, or delete `config.json` and start the bridge again: it creates a new one. |
| `warning: cloudflared is not in the PATH` | Single player: install it with `winget install --id Cloudflare.cloudflared`, then open a new window. |
| `warning: Talky is installed twice` | Delete `%USERPROFILE%\Zomboid\mods\Talky`: the Workshop version is enough. |
| `warning: The bridge folder ... is inside ...\Zomboid\mods` | Move the whole Talky folder, `bridge\config.json` included, out of `Zomboid\mods` (to `Documents\Talky`, say), then start `start-bridge.cmd` from there. The token does not change. |
| `'node' is not recognized`, or `Node.js was not found on this PC.` in the `start-bridge.cmd` window | Install Node.js 18 or later, then open a new window. |
| `Port 7420 is already used` | Another program (or a second bridge) uses the port. Change `port` in `config.json`, and in the cloudflared command or the public address of the bridge. |
| LibertyTalk refuses the URL | Single player: the URL is local (`http://127.0.0.1...`): paste the `https://...trycloudflare.com` address. Server: an `http://` address needs the LibertyTalk update that accepts it; meanwhile, an `https://` address (reverse proxy). |
| `401 bad token` | Wrong token, or a webhook with its own token called with the global one. The bridge checks the token first: without the right one, even an unknown webhook id answers 401. Server mode: the bridge token is refused on `/hooks`: use the token of a streamer; a streamer whose token was renewed or who was removed gets 401. |
| `404 unknown webhook` | The id is missing from `talky_config.json`. After the first launch, `config.json` is no longer read for webhooks, unless `talky_config.json` has neither webhooks nor workflows. |
| `413 body too large` | Body over 64 KB. |
| The bridge logs `job #N` but nothing happens | Game paused, player dead, back to the main menu, job older than `jobTtlSeconds`, or 8 jobs already running (long `wait` steps). On a server, also: the streamer is offline, the limits of the server (see the rows below), or the server does not read the inbox (look for `inbox ready` in its console). |
| F8 > Status: `Bridge of the server: offline.` | Start the bridge on the machine of the server (`start-bridge.sh`, `start-bridge.cmd server`), with the account of the server, or set `zomboidLuaDir` to the `Lua` folder of the server. |
| F8 > Status: `The bridge of the server runs in solo mode` | Start it with `--server`, or set `"mode": "server"` in `bridge/config.json`. |
| F8 > Status: `no answer from the Talky code of the server` | The server does not run Talky, or its Talky code failed. Look for `[Talky]` lines and Lua errors in the console of the server (`server-console.txt`, or `coop-console.txt` for a hosted game). |
| F8 > Webhooks: `Reserved to the admins of this server` | Your role does not have the CreateHorde capability. The host of a game clicks **Allow me (host)**. |
| F8 > Webhooks: the streamer stays `waiting for the bridge to draw the token` | The bridge of the server is not running in server mode, or does not use the `Zomboid/Lua` folder of the server. |
| The bridge window shows `refused by the server: not_streamer` | The streamer was removed, or the bridge runs in solo mode next to a server. |
| The bridge window shows `refused by the server: disabled` | An action of the job is turned off in the sandbox options of the server (**Zombies and hordes**, **Fire**, **Helicopter**...). |
| `action_failed` with `cooldown` or `budget` | A cooldown of the server (weather, thunder, time, helicopter) or a budget per 10 minutes or per job: see [Server options](#server-options-sandbox-options--talky). |
| `action_failed` with `helicopter_random_target` | Several players are online and **Helicopter with several players online** is off. |
| `action_failed` with `no_square` on a server | Another online player within **Distance from other players**, a safehouse the streamer may not enter, or no free square around the streamer. |
| Status shows "skipped: cooldown / condition not met / chance roll lost / workflow disabled" | The workflow refused the event: see its settings on the Workflows page. |
| Status shows "skipped: no test code (update the mod)" or "skipped: test code mismatch, press Test now again" | The bridge ran no test. First message: the test carried no test code, so the mod is older than 0.4.0: update it. Second message: the bridge restarted after the F8 window read its test code: press **Test now** again. |
| `http step refused: host "..." is not in httpAllowedHosts` | Add the host to `httpAllowedHosts` in `bridge\config.json` and restart the bridge. |
| `http step refused: fill "httpTargets" > "lt_report" in bridge/config.json first` | The target still holds a `PASTE_...` placeholder: put the URL and the secret of your incoming webhook there, then restart the bridge. |
| `warning: "jobTtlSeconds" in config.json is ...: 900 is used.` | The game and the server drop a job 15 minutes after the bridge created it: set `jobTtlSeconds` to 900 or less. |
| `warning: server mode, but the bridge listens on 127.0.0.1 only` | Set `host` to `""` in `bridge/config.json`, unless a reverse proxy of the machine forwards the calls to the bridge. |
| Nothing happens after a restart | The tunnel address changed: update the widget and the F8 public URL. |
| The mod is not in the list | Without the Workshop, the game needs `%USERPROFILE%\Zomboid\mods\Talky\42\mod.info`: copy the `Talky` folder of the zip, not the folder that contains it. Check that Talky is not installed twice (Workshop and `Zomboid\mods`). |

Logs: the game writes `[Talky]` lines in `%USERPROFILE%\Zomboid\console.txt`, a dedicated server in `Zomboid\server-console.txt`, the server of a hosted game in `Zomboid\coop-console.txt`. `http://127.0.0.1:7420/health?token=<bridge token>` returns the mode, the number of jobs waiting, the last acknowledged job, the jobs acknowledged above it and the last 50 events.

Exchange files in `Zomboid\Lua\` of the game (single player) or of the server (server mode): `talky_inbox.jsonl` (jobs; in server mode each one with `target`), `talky_ack.txt` (`S`, or `S s1 s2 ...`: every job up to `S` is taken, and `s1`, `s2`... too), `talky_outbox.txt` (game events, and the requests of the admins about the streamers), `talky_status.json` (bridge heartbeat, with the mode, the test code and the ids of the webhooks that have a dedicated token, never a token), `talky_config.json` (the configuration edited by the F8 window) and, in server mode, `talky_streamers.json` (the streamers and their tokens, written by the bridge). In multiplayer, the game of a player writes no file: its display settings come from the `talky_config.json` of the server.

## `bridge\config.json` reference

| Key | Default | Role |
|---|---|---|
| `mode` | `solo` | `solo`: the bridge of a player's PC. `server`: next to a server, with a token per streamer. `--server` / `--solo` on the command line win for one run; `start-bridge.cmd server` and `start-bridge.sh` pass `--server`. |
| `port` | `7420` | Port of the bridge. |
| `host` | empty | Listening address. Empty: `127.0.0.1` in solo mode (the tunnel connects locally), `0.0.0.0` in server mode. `127.0.0.1` in server mode for a reverse proxy on the same machine. |
| `publicUrl` | empty | Server mode: the address given to the streamers (`http://<public IP>:<port>`). The one set in F8 > Webhooks (saved in `talky_config.json`) wins. |
| `token` | random | Token of the bridge, drawn when the bridge creates `config.json`. Single player: the token of the webhook calls. Server mode: `/fire` and `/health` only. `node bridge\bridge.js new-token` draws a new one. |
| `hookTokens` | `{}` | Single player: `{ "<webhook id>": "<16 characters or more>" }`, a webhook with its own token, which then refuses `token`. |
| `zomboidLuaDir` | `%USERPROFILE%/Zomboid/Lua` | Folder shared with the mod: the one of the game, or of the server in server mode (`<folder>/Lua` for a server started with `-cachedir=<folder>`). |
| `jobTtlSeconds` | `900` | A job older than this is skipped by the game (900 at most: a larger value is brought back to 900, with a warning at the start). |
| `httpAllowedHosts` | `["*.liberty-talk.com"]` | Hosts that `http` steps may call. |
| `httpTargets` | `lt_report` with placeholders | `{ "<name>": { "url", "headers", "hmacSecret", "hmacHeader", "method" } }`: the address and the secrets of an `http` step that says `"target": "<name>"`. Only `url` is required. |
| `settings` | `{"language": "en", "anonymousName": ""}`, `fr` when the regional format of the system is French | Copied to `talky_config.json` on the first launch, then edited in F8 > Settings. |
| `webhooks`, `workflows`, `gameEvents` | examples | Copied to `talky_config.json` on the first launch. |
| `poll` | disabled | Experimental source without public address, see below (single player only). |

The streamers of server mode are in `bridge\streamers.json`, next to `config.json`: keep it with `config.json` when you move or update the bridge (without it, every streamer needs a new token).

**Poll mode (experimental, single player).** Instead of receiving webhooks, the bridge reads the LibertyTalk activity feed every `intervalSeconds` (10 s, 5 s at least) with an API token: `"url": "https://<tenant>.api.liberty-talk.com/community/<community_id>/activity?per_page=50"`, `"apiToken"`, optional `"headers"`. `types` maps an activity type to a workflow: `follow`, `subscribe`, `subscribe_gift`, `cheer`, `raid`, `donation`, `superchat`, `member` (`resub`, `member_gift`, `charity`, `boost` and `first_message` also exist). The bridge fills `user_name` from `actor_name`, `bits` (cheer), `viewers` (raid) and `total` (gifts) from `amount`. Events already in the feed when the bridge starts are not replayed.

## Development

- Bridge tests: `node bridge/test/run-tests.mjs` (or `npm test` in `bridge`; Node 18 or later, no dependencies). They start real bridges, in solo and in server mode, on free ports with a temporary game folder.
- Lua tests: `& tools\test-lua.ps1` in PowerShell, from the Talky folder (`-GameDir "<path to ProjectZomboid>"` when the game is not found; JDK 25 or later: the classes of game 42.21 are Java 25 classes; `-Java "<path to java.exe>"` picks another JDK). They compile every file with the Kahlua of the game jar, then run the mod with fake game objects, one Lua state per game process: a single player game, a dedicated server with several clients and a hosted game. Messages between processes are copied by the game's own network serializer. Covered: every page of the F8 window in English and French, for an admin and for a player, translation keys, sandbox options, caps, the streamer list, the routing of the jobs to their streamer, offline streamers, acks, name tags, events for the bridge. For a dedicated server installed alone, `-GameDir` can be its `java` folder.
- Steam Workshop folder: `tools\build-workshop.ps1` assembles `%USERPROFILE%\Zomboid\Workshop\Talky` (`-OutDir` to build it elsewhere), keeps the Workshop `id=` after the first upload and refuses the file types the Workshop rejects. Then, in the game: **Workshop > Create and update items**.
- Release: `tools\build-release.ps1` builds `dist\Talky-<version>.zip` (Windows and Linux) and `dist\SHA256SUMS.txt`. The version of `bridge\package.json` must match `modversion` in `mod.info`.
- `mod\Talky\42\poster.png` (512x512) and `packaging\workshop\preview.png` (256x256) use the logo of the LibertyTalk widget. `tools\make-placeholder-images.ps1` draws the old provisional images and would overwrite them.
- Translations: `mod\Talky\42\media\lua\shared\Translate\<LANG>\UI.json` (keys `UI_Talky_*`, the same keys in every language), `Sandbox.json` (the server options of `media\sandbox-options.txt`, keys `Sandbox_Talky_*`) and `Mod.json` (name and description of the mod).
- Code layout: `media\lua\client` runs only in the player's game, `media\lua\server` on the server and in single player, `media\lua\shared` everywhere. The server files never require a `client` file; only `server\Talky\Talky_Files.lua` opens files (the bridge's files, in `Zomboid\Lua`). `server\Talky\Talky_Inbox.lua` reads the jobs, `Talky_Streamers.lua` the streamer list, `Talky_Server.lua` answers the clients, `Talky_ServerRunner.lua` runs the jobs. `client\Talky\Talky_Remote.lua` is what the F8 window asks the server in multiplayer.

## License

MIT, see [LICENSE](LICENSE). The license covers the code, not the LibertyTalk and Tech Liberty names and logos.

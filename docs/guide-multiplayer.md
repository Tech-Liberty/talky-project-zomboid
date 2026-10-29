# Partie multijoueur du guide « Project Zomboid × LibertyTalk : Talky » (Talky 0.5.0)

Texte proposé pour la future partie multijoueur du guide LibertyTalk (`/guides/project-zomboid-talky`, éditeur
`/mcp/guides`, fixture `saas/api/database/seeders/guides/project-zomboid-talky.json`). Ce fichier n'est pas le guide :
l'orchestrateur l'y intègre. Chaque bloc a un identifiant proposé (`p3-...`, à la suite des parties 1 et 2), un type
indicatif et son texte en français puis en anglais. Les blocs suivent l'ordre de lecture.

Ce qui change par rapport aux parties 1 et 2 : elles décrivent le solo (bridge et tunnel sur le PC du joueur). En
multijoueur, le streamer n'installe rien d'autre que le mod ; c'est l'admin du serveur qui lance le bridge.

Prérequis côté LibertyTalk : le widget officiel doit accepter une adresse `http://<IP>:<port>` (voir la fin de ce
fichier). Tant que ce n'est pas livré, la phrase du bloc `p3-ports-https` est la seule voie (adresse `https://`).

---

## p3-title (titre de partie)

**FR.** Jouer à Talky sur un serveur

**EN.** Playing Talky on a server

## p3-intro (paragraphe)

**FR.** Sur un serveur, dédié ou hébergé depuis le menu principal du jeu, le bridge ne tourne pas sur le PC des streamers : l'admin le lance sur la machine du serveur, et ajoute les streamers depuis le jeu. Chaque streamer reçoit une adresse et un jeton, qu'il colle dans son widget LibertyTalk. Les effets de son live se produisent autour de son personnage, et tous les joueurs les voient.

**EN.** On a server, dedicated or hosted from the main menu of the game, the bridge does not run on the streamers' PCs: the admin runs it on the machine of the server, and adds the streamers from the game. Each streamer gets an address and a token, to paste into their LibertyTalk widget. The events of their live happen around their character, and every player sees them.

## p3-who (liste)

**FR.**
- L'admin du serveur : installe le mod sur le serveur, lance le bridge à côté, ouvre un port, ajoute les streamers.
- Chaque streamer : rejoint le serveur, installe le widget LibertyTalk et y colle l'adresse et le jeton reçus. Rien à installer sur son PC à part le mod, que le serveur demande de toute façon.

**EN.**
- The admin of the server: installs the mod on the server, runs the bridge next to it, opens a port, adds the streamers.
- Each streamer: joins the server, installs the LibertyTalk widget and pastes the address and the token they got. Nothing to install on their PC but the mod, which the server asks for anyway.

---

## p3-admin-title (sous-titre)

**FR.** Pour l'admin : préparer le serveur

**EN.** For the admin: setting up the server

## p3-admin-mod (étapes)

**FR.**
1. Ajoutez Talky aux mods du serveur. Serveur dédié : dans `Zomboid/Server/<nom du serveur>.ini`, `Mods=Talky` et l'id Workshop de Talky dans `WorkshopItems=`. Partie hébergée : **Héberger** > **Modifier les réglages...** > page **Mods** (et **Workshop Steam** avec la version du Workshop).
2. Les options de Talky sont sur la page **Talky** des options bac à sable : limites de zombies, d'objets, de météo, un interrupteur par catégorie. Le feu et l'hélicoptère sont désactivés par défaut.

**EN.**
1. Add Talky to the mods of the server. Dedicated server: in `Zomboid/Server/<server name>.ini`, `Mods=Talky` and the Workshop id of Talky in `WorkshopItems=`. Hosted game: **Host** > **Manage settings...** > **Mods** page (and **Steam Workshop** with the Workshop version).
2. The options of Talky are on the **Talky** page of the sandbox options: limits for zombies, items, weather, one switch per category. Fire and the helicopter are off by default.

## p3-admin-bridge (étapes)

**FR.**
1. Installez Node.js 18 ou plus sur la machine du serveur.
2. Téléchargez le zip de Talky depuis les releases GitHub et décompressez-le dans un dossier du compte qui lance le serveur.
3. Lancez le bridge en mode serveur, avec ce compte :
   - Linux : `sh start-bridge.sh` ;
   - Windows : `start-bridge.cmd server` dans un terminal ouvert dans le dossier de Talky ;
   - partie hébergée : `start-bridge.cmd server` sur le PC de l'hôte.
4. La fenêtre du bridge affiche `listening on http://0.0.0.0:7420 (server mode)`. La console du serveur affiche `[Talky] server ready (Talky 0.5.0)`.

**EN.**
1. Install Node.js 18 or later on the machine of the server.
2. Download the Talky zip from the GitHub releases and extract it to a folder of the account that runs the server.
3. Start the bridge in server mode, with that account:
   - Linux: `sh start-bridge.sh`;
   - Windows: `start-bridge.cmd server` in a terminal opened in the Talky folder;
   - hosted game: `start-bridge.cmd server` on the host's PC.
4. The bridge window shows `listening on http://0.0.0.0:7420 (server mode)`. The console of the server shows `[Talky] server ready (Talky 0.5.0)`.

## p3-admin-bridge-note (encadré « bon à savoir »)

**FR.** Le bridge doit utiliser le dossier `Zomboid/Lua` du serveur : lancez-le avec le compte qui lance le serveur. Pour un serveur lancé avec `-cachedir=<dossier>`, indiquez `<dossier>/Lua` dans `zomboidLuaDir` de `bridge/config.json`. Pour que le bridge démarre avec la machine sous Linux, le zip contient `talky-bridge.service`, un exemple d'unité systemd.

**EN.** The bridge must use the `Zomboid/Lua` folder of the server: start it with the account that runs the server. For a server started with `-cachedir=<folder>`, set `zomboidLuaDir` to `<folder>/Lua` in `bridge/config.json`. To start the bridge with the machine on Linux, the zip holds `talky-bridge.service`, an example systemd unit.

## p3-admin-port (étapes)

**FR.**
1. Ouvrez le port TCP 7420 vers internet : pare-feu de la machine (sous Linux, par exemple `sudo ufw allow 7420/tcp` ; sous Windows, une règle entrante TCP 7420) et pare-feu de l'hébergeur s'il y en a un.
2. Partie hébergée : redirigez le port TCP 7420 de la box vers le PC de l'hôte.
3. Notez l'adresse publique du bridge : `http://<IP publique du serveur>:7420`.

**EN.**
1. Open the TCP port 7420 to the internet: the firewall of the machine (on Linux, for example `sudo ufw allow 7420/tcp`; on Windows, an inbound TCP 7420 rule) and the firewall of the hosting provider, if any.
2. Hosted game: forward the TCP port 7420 of the router to the host's PC.
3. Note the public address of the bridge: `http://<public IP of the server>:7420`.

## p3-admin-streamers (étapes)

**FR.**
1. En jeu, appuyez sur **F8**, page **Webhooks**, onglet **Streamers**. Cette page est réservée aux admins (rôle admin ou modérateur par défaut).
2. Dans **Adresse publique du bridge**, tapez l'adresse notée plus haut, puis **Enregistrer**. L'IP seule suffit : Talky ajoute `http://` et le port.
3. Tapez le nom d'utilisateur du streamer en bas à gauche, puis **+ Ajouter un streamer**. Une seconde plus tard, il apparaît dans la liste.
4. Choisissez-le, puis **Copier l'URL et le jeton** : le presse-papiers contient les deux valeurs de son widget. Envoyez-les-lui en message privé.

**EN.**
1. In game, press **F8**, **Webhooks** page, **Streamers** tab. This page is reserved to the admins (admin or moderator role by default).
2. In **Public address of the bridge**, type the address noted above, then **Save**. The IP alone is enough: Talky adds `http://` and the port.
3. Type the username of the streamer at the bottom left, then **+ Add streamer**. A second later, they show in the list.
4. Select them, then **Copy URL and token**: the clipboard holds the two values of their widget. Send them in a private message.

## p3-admin-streamers-note (encadré « attention »)

**FR.** Le jeton s'affiche masqué dans F8 ; **Afficher le jeton** le montre. Ne l'affichez pas pendant un live. **Nouveau jeton** remplace le jeton d'un streamer (l'ancien s'arrête tout de suite, le streamer colle le nouveau dans son widget) ; **Retirer** l'arrête et abandonne ses jobs en attente.

**EN.** The token shows masked in F8; **Show token** reveals it. Do not reveal it during a live. **New token** replaces the token of a streamer (the old one stops at once, the streamer pastes the new one into their widget); **Remove** stops it and drops their waiting jobs.

## p3-admin-host (encadré « partie hébergée »)

**FR.** Dans une partie hébergée, le compte de l'hôte n'est pas admin au départ. Sur la page Statut ou Webhooks de F8, cliquez sur **M'autoriser (hôte)** : quelques secondes plus tard, les pages des admins s'ouvrent.

**EN.** In a hosted game, the host's account is not admin at first. On the Status or Webhooks page of F8, click **Allow me (host)**: a few seconds later, the admin pages open.

---

## p3-streamer-title (sous-titre)

**FR.** Pour le streamer : brancher son live

**EN.** For the streamer: connecting your live

## p3-streamer-steps (étapes)

**FR.**
1. Rejoignez le serveur. Le mod Talky vient avec la liste des mods du serveur.
2. Dans le dashboard LibertyTalk, installez le widget **Project Zomboid · Talky** (Marketplace, puis Mes achats) et ouvrez sa page dans **Widgets**.
3. Dans **Configuration du widget** : **Adresse publique du pont Talky** = l'adresse reçue de l'admin, **Jeton du pont** = votre jeton. Cliquez sur **Enregistrer**, puis sur **Activer**.
4. En jeu, F8 > Statut affiche « Vous êtes streamer ici : les événements de votre live se produisent autour de votre personnage. »

**EN.**
1. Join the server. The Talky mod comes with the mod list of the server.
2. In the LibertyTalk dashboard, install the **Project Zomboid · Talky** widget (Marketplace, then My purchases) and open its page in **Widgets**.
3. In **Widget configuration**: **Talky bridge public URL** = the address from the admin, **Bridge token** = your token. Click **Save**, then **Activate**.
4. In game, F8 > Status shows "You are a streamer of this server: the events of your live happen around your character."

## p3-streamer-note (encadré « bon à savoir »)

**FR.** Rien à lancer sur votre PC : ni bridge, ni tunnel. Si l'admin vous donne un nouveau jeton, remplacez **Jeton du pont** dans le widget et enregistrez. Les workflows (ce qui se passe pour un follow, un raid...) et l'affichage (noms au-dessus des zombies, bandeaux) sont ceux du serveur : c'est l'admin qui les règle, dans F8.

**EN.** Nothing to run on your PC: no bridge, no tunnel. If the admin gives you a new token, replace **Bridge token** in the widget and save. The workflows (what happens for a follow, a raid...) and the display (names above zombies, banners) are the server's: the admin sets them, in F8.

---

## p3-ports-title (sous-titre)

**FR.** Ports et sécurité

**EN.** Ports and security

## p3-ports (liste)

**FR.**
- Un seul port à ouvrir : TCP 7420 (`port` de `bridge/config.json`), vers la machine qui fait tourner le bridge. Le serveur du jeu garde ses propres ports.
- Les appels de LibertyTalk arrivent en `http`, en clair : le jeton du streamer circule en clair entre LibertyTalk et le bridge. Quelqu'un qui intercepte ce trafic pourrait le réutiliser jusqu'au prochain **Nouveau jeton**.
- Le jeton d'un streamer ne déclenche que des effets autour de ce streamer, dans les limites des options bac à sable du serveur.

**EN.**
- One port to open: TCP 7420 (`port` of `bridge/config.json`), to the machine that runs the bridge. The game server keeps its own ports.
- The calls from LibertyTalk arrive in `http`, in clear text: the token of the streamer travels in clear between LibertyTalk and the bridge. Someone who intercepts that traffic could reuse it until the next **New token**.
- The token of a streamer only triggers effects around that streamer, within the limits of the sandbox options of the server.

## p3-ports-https (encadré « pour aller plus loin »)

**FR.** Pour du https, placez un proxy inverse avec un certificat (Caddy, nginx...) devant le bridge, mettez `"host": "127.0.0.1"` dans `bridge/config.json` pour que le bridge ne réponde qu'au proxy, et tapez l'adresse `https://` du proxy comme adresse publique dans F8. Pour une partie hébergée sans adresse publique, un tunnel cloudflared (`cloudflared tunnel --url http://127.0.0.1:7420`) donne aussi une adresse `https://`.

**EN.** For https, put a reverse proxy with a certificate (Caddy, nginx...) in front of the bridge, set `"host": "127.0.0.1"` in `bridge/config.json` so that the bridge only answers the proxy, and type the `https://` address of the proxy as public address in F8. For a hosted game without a public address, a cloudflared tunnel (`cloudflared tunnel --url http://127.0.0.1:7420`) gives an `https://` address too.

---

## p3-limits-title (sous-titre)

**FR.** Limites

**EN.** Limits

## p3-limits (liste)

**FR.**
- La machine du serveur doit pouvoir lancer Node.js et être joignable depuis internet sur le port du bridge. Un serveur loué sans accès à la ligne de commande ne convient pas.
- Un seul jeu de workflows pour tout le serveur : chaque streamer reçoit les mêmes effets, autour de son propre personnage. Les cooldowns comptent par streamer.
- La météo et l'heure sont les mêmes pour tous les joueurs, et leurs délais comptent pour tout le serveur.
- L'hélicoptère va vers un joueur au hasard : il est désactivé par défaut et, une fois activé, ne part que si un seul joueur est connecté (sauf option contraire).
- Les jobs d'un streamer hors ligne attendent son retour, 15 minutes au plus ; au-delà, ils sont abandonnés.
- Les effets autour d'un streamer évitent les autres joueurs (15 cases par défaut) et les refuges où il n'a pas accès.

**EN.**
- The machine of the server must be able to run Node.js and be reachable from the internet on the port of the bridge. A rented server without command-line access does not fit.
- One set of workflows for the whole server: every streamer gets the same effects, around their own character. Cooldowns count per streamer.
- Weather and time of day are the same for every player, and their cooldowns count for the whole server.
- The helicopter flies to a random player: it is off by default and, when on, only leaves while one player is online (unless an option says otherwise).
- The jobs of a streamer who is offline wait for them, 15 minutes at most; past that, they are dropped.
- Effects around a streamer keep away from the other players (15 tiles by default) and from the safehouses the streamer may not enter.

## p3-troubleshooting (tableau symptôme / solution)

**FR.**

| Symptôme | Solution |
|---|---|
| F8 > Statut : « Bridge du serveur : hors ligne. » | Lancez le bridge sur la machine du serveur, avec le compte du serveur. |
| F8 > Statut : « Le bridge du serveur tourne en mode solo » | Relancez-le avec `start-bridge.sh` (Linux) ou `start-bridge.cmd server` (Windows). |
| F8 > Webhooks : « Réservé aux admins de ce serveur » | Votre rôle n'est pas admin ni modérateur. Hôte d'une partie : **M'autoriser (hôte)**. |
| Rien ne se passe en jeu après un follow | Le port 7420 n'est pas ouvert, l'adresse du widget est fausse, ou le streamer a été retiré (la fenêtre du bridge affiche `401 bad token` ou `not_streamer`). |
| LibertyTalk refuse l'adresse `http://...` | Votre LibertyTalk n'accepte pas encore les adresses en clair : utilisez une adresse `https://` (proxy inverse ou tunnel). |

**EN.**

| Symptom | Fix |
|---|---|
| F8 > Status: "Bridge of the server: offline." | Start the bridge on the machine of the server, with the account of the server. |
| F8 > Status: "The bridge of the server runs in solo mode" | Restart it with `start-bridge.sh` (Linux) or `start-bridge.cmd server` (Windows). |
| F8 > Webhooks: "Reserved to the admins of this server" | Your role is neither admin nor moderator. Host of a game: **Allow me (host)**. |
| Nothing happens in game after a follow | The port 7420 is not open, the address of the widget is wrong, or the streamer was removed (the bridge window shows `401 bad token` or `not_streamer`). |
| LibertyTalk refuses the `http://...` address | Your LibertyTalk does not accept clear-text addresses yet: use an `https://` address (reverse proxy or tunnel). |

---

## Ce qui doit changer côté LibertyTalk (widget officiel)

Le contrat d'appel est gardé : mêmes webhooks (`follow`, `sub`, `gift`, `bits`, `raid`, `points`, `command`,
`donation`, `superchat`, `member`), même URL `{talky_bridge_url}/hooks/<id>`, même en-tête `X-Bridge-Token: {talky_token}`,
mêmes corps. En mode serveur, `talky_token` est le jeton du streamer, qui désigne son personnage. Seule l'adresse bloque,
dans `api/app/Marketplace/Official/Widgets/TalkyProjectZomboid.php` :

1. `BRIDGE_URL_RX` n'accepte que `https://`. Remplacer `~^https://` par `~^https?://` :
   `'~^https?://[^\s/?#]+(?:/(?!hooks(?:/|\z))[^\s/?#]+)*\z~'`. Ce motif sert deux fois (motif de la variable
   `talky_bridge_url` et condition `regex_match` de chaque « Si ») : les deux suivent la constante. `OutboundUrlGuard`
   accepte déjà `http` et tout port de 1 à 65535, et refuse les IP privées.
2. Textes de `talky_bridge_url` : `pattern_hint_i18n` et `description_i18n` parlent de « l'adresse du tunnel »
   en https. Proposition : FR « L'adresse du pont : celle du tunnel (https://exemple.trycloudflare.com) en solo, celle
   que l'admin du serveur vous donne (http://203.0.113.5:7420) sur un serveur. Sans « / » à la fin, sans /hooks/… et sans
   « ?token= ». » ; EN « The address of the bridge: the tunnel one (https://example.trycloudflare.com) in single player,
   the one the admin of the server gives you (http://203.0.113.5:7420) on a server. No trailing "/", no /hooks/... and
   no "?token=" part. »
3. Texte de `talky_token` : « La valeur token du fichier bridge/config.json du pont. » Proposition : FR « En solo, la
   valeur token de bridge/config.json. Sur un serveur, le jeton que l'admin vous donne (F8 > Webhooks). » ; EN « In single
   player, the token value of bridge/config.json. On a server, the token the admin gives you (F8 > Webhooks). »
4. Descriptions (`descriptionI18n`, `listing()` : `summary` et `description`) : elles disent que le pont tourne sur le
   PC du streamer, que le serveur doit « vous autoriser » (option « Joueurs autorisés ») et que « le pont et le tunnel
   restent sur votre PC ». Tout cela est faux en 0.5.0. À dire : en solo, pont et tunnel sur le PC ; sur un serveur,
   l'admin lance le pont à côté du serveur, ajoute le streamer dans F8 > Webhooks et lui donne une adresse et un jeton ;
   le streamer n'installe que le mod. L'option « Joueurs autorisés » n'existe plus.
5. Le commentaire de classe (« qui tourne sur le PC du joueur ») et celui de `BRIDGE_URL_RX` (« https seulement (le
   jeton part dans un en-tête) ») sont à mettre à jour de la même façon.

Après le changement : l'éditeur fait foi pour les widgets officiels (le code ne fait que semer le modèle). Il faut donc
soit reporter le motif et les textes dans le modèle depuis l'éditeur, soit réinitialiser le modèle depuis le code
(console « Réinitialiser depuis le code », ou `marketplace:publish-official project-zomboid-talky --reset-from-code`),
puis publier, pour que l'annonce et les installs existantes reçoivent la nouvelle version.

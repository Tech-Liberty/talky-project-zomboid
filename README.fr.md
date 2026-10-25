# Talky : les événements live de LibertyTalk dans Project Zomboid (Build 42)

[English version](README.md)

Talky relie [LibertyTalk](https://liberty-talk.com) à Project Zomboid. Un follow, un abonnement, des bits, un raid, une récompense de points de chaîne ou un Super Chat sur votre stream lance un workflow dans votre partie : un zombie au nom du nouveau follower, une horde à la taille du raid, l'hélicoptère pour 1000 bits. Le jeu renvoie aussi ses propres événements (« un zombie nommé est mort », « le joueur est mort »), qui peuvent lancer d'autres workflows, y compris un appel vers LibertyTalk.

```
LibertyTalk                       votre PC
+--------------+   HTTPS    +--------------+  fichiers  +-------------------+
| déclencheur  |----------->| tunnel       |----------->| Project Zomboid   |
| (follow...)  |  appel     |   |          |   inbox    | mod Talky (Lua)   |
|   |          |  webhook   | bridge.js    |<-----------| fenêtre F8        |
| widget       |            | (workflows)  | ack/outbox |                   |
+--------------+            +--------------+            +-------------------+
```

**Pourquoi un bridge ?** Le Lua de Project Zomboid (Kahlua) ne peut pas ouvrir de connexion réseau. Il peut seulement lire et écrire des fichiers dans `%USERPROFILE%\Zomboid\Lua\`. Le bridge (le « pont ») est un petit programme Node.js sans dépendance : il reçoit les webhooks, exécute la logique (conditions, tirages au hasard, cooldowns, gabarits) et dépose des jobs que le mod lit chaque seconde.

## Prérequis

- Windows 10 ou 11.
- Project Zomboid Build 42, en solo ou en tant qu'hôte d'une partie. Les serveurs dédiés ne sont pas pris en charge.
- Node.js 18 ou plus : `winget install OpenJS.NodeJS.LTS`
- cloudflared, pour l'adresse publique du bridge : `winget install --id Cloudflare.cloudflared`
- Un compte LibertyTalk avec Twitch ou YouTube connecté.

## Installation

Le mod s'obtient de deux façons. N'en utilisez qu'une : deux mods avec l'id `Talky` perturbent le jeu. Dans les deux cas, le bridge vient de la release GitHub, et il n'y a rien à lancer avant `start-bridge.cmd`.

**A. Le mod depuis le Steam Workshop**

1. Abonnez-vous à Talky sur le Steam Workshop.
2. Téléchargez `Talky-0.3.0-windows.zip` dans les [releases GitHub](https://github.com/Tech-Liberty/talky-project-zomboid/releases) et décompressez-le dans un dossier que vous gardez, par exemple `Documents\Talky`.
3. Laissez le dossier `Talky` du zip où il est : le Workshop fournit déjà le mod, et le jeu ne lit pas ce dossier en dehors de `Zomboid\mods`.

**B. Sans le Steam Workshop**

1. Téléchargez `Talky-0.3.0-windows.zip` et décompressez-le dans un dossier que vous gardez, comme en A.
2. Copiez le dossier `Talky` du zip dans `%USERPROFILE%\Zomboid\mods`, pour que le jeu trouve `%USERPROFILE%\Zomboid\mods\Talky\42\mod.info`. Ne copiez que ce dossier : le bridge reste dans `Documents\Talky`.

Ne décompressez pas le zip dans `Zomboid\mods`. Avec le Workshop, le dossier `Talky` du zip y deviendrait une seconde copie du mod. Dans les deux cas, supprimer ou remplacer un mod à cet endroit peut effacer le bridge et son `bridge\config.json`. Le bridge affiche un avertissement au démarrage dans ces deux situations.

Pour vérifier le téléchargement, comparez `Get-FileHash Talky-0.3.0-windows.zip -Algorithm SHA256` avec le fichier `SHA256SUMS.txt` de la release.

## Lancer et tester

1. Double-cliquez sur `start-bridge.cmd` et laissez sa fenêtre ouverte. Au premier lancement, vous devez voir ces lignes, chacune précédée de l'heure :
   ```
   created ~\Documents\Talky\bridge\config.json with a random token (language: fr)
   the token is in your clipboard and in config.json, never shown here: paste it into "Bridge token" in the LibertyTalk widget
   created ~\Zomboid\Lua\talky_config.json from config.json (fr: 19 text(s) translated)
   config loaded: 10 webhook(s), 14 workflow(s)
   Talky bridge 0.3.0 listening on http://127.0.0.1:7420
   game folder: ~\Zomboid\Lua
   http steps allowed to: *.liberty-talk.com
     webhook  POST /hooks/follow
   ```
   Les trois premières lignes n'apparaissent qu'au premier lancement. Avec un Windows en anglais, elles affichent `(language: en)` et `from config.json` sans la mention `(fr: ...)`.
2. Dans Project Zomboid : **Mods**, activez **Talky - LibertyTalk Live Events**, puis lancez une partie solo ou chargez-en une. Appuyez sur **F8**. La page Statut affiche `Bridge connecté sur le port 7420 - 0 job(s) en attente  (v0.3.0)`.
3. Testez sans LibertyTalk : sur la page **Workflows**, sélectionnez `new_follower`, saisissez un pseudo et cliquez sur **Tester maintenant**. Ou, dans un terminal ouvert dans le dossier Talky :
   ```powershell
   node bridge\bridge.js fire new_follower user=Bob
   ```
   Un bandeau « Bob rejoint la horde ! » s'affiche puis, 2 secondes plus tard, un zombie nommé Bob apparaît entre 8 et 14 cases.

Ce que fait le premier lancement :

- `start-bridge.cmd` vérifie que Node.js 18 ou plus est installé, et affiche la commande `winget` quand ce n'est pas le cas.
- Le bridge crée `bridge\config.json` à partir de `bridge\config.example.json`, avec un jeton aléatoire de 48 caractères hexadécimaux. Un `config.json` existant n'est jamais modifié. Pour obtenir un nouveau jeton, supprimez `config.json`, relancez le bridge et collez le nouveau jeton dans le widget.
- Le jeton est copié dans votre presse-papiers et n'est jamais affiché, il reste donc hors du stream. Quand la copie échoue, la ligne indique `the token is in config.json ("token")`.
- Les workflows d'exemple et les textes du bridge sont en français quand le format régional de Windows est le français, en anglais sinon. Pour changer de langue ensuite : arrêtez le bridge, mettez `settings.language` à `fr` ou `en` dans `bridge\config.json`, renommez `%USERPROFILE%\Zomboid\Lua\talky_config.json` (il contient ce que vous avez modifié dans F8) et relancez le bridge.
- Si vous lancez le jeu avec `-cachedir`, indiquez le dossier `Lua` de cet emplacement dans `zomboidLuaDir` de `bridge\config.json`, puis relancez le bridge.
- À chaque démarrage, une ligne `warning:` s'affiche quand cloudflared n'est pas dans le PATH, quand Talky est installé deux fois (dans `Zomboid\mods\Talky` et depuis le Workshop), ou quand le dossier du bridge se trouve dans `Zomboid\mods`. Le bridge démarre quand même.

## Donner une adresse publique au bridge

LibertyTalk refuse les adresses locales et privées (protection contre les requêtes forgées côté serveur) : le bridge a donc besoin d'une adresse HTTPS publique. Dans une seconde fenêtre :

```powershell
cloudflared tunnel --url http://127.0.0.1:7420
```

cloudflared affiche une adresse du type `https://des-mots-au-hasard.trycloudflare.com`. Ce tunnel rapide ne demande aucun compte, mais son adresse change à chaque lancement et Cloudflare le réserve aux tests, sans garantie de disponibilité. Pour garder la même adresse d'un stream à l'autre, créez un tunnel nommé sur votre propre domaine (voir la documentation Cloudflare Tunnel).

Collez l'adresse dans **F8 > Statut > URL publique**, puis **Enregistrer** : les boutons « Copier l'URL » l'utilisent.

## Brancher LibertyTalk : le widget « Project Zomboid · Talky »

1. Dans le dashboard LibertyTalk, ouvrez la **Marketplace**, puis la fiche **Project Zomboid · Talky**, et cliquez sur **Installer gratuitement**. Le widget rejoint **Mes achats**.
2. Dans **Mes achats**, cliquez sur **Installer** sur la carte Project Zomboid · Talky. LibertyTalk prépare le widget dans votre communauté, désactivé. Si l'assistant « Configurez votre workflow » s'ouvre, vous pouvez le quitter : ce widget se configure sur sa propre page.
3. Ouvrez **Widgets**, puis la carte **Project Zomboid · Talky**. Gardez la portée **Global** (sélectionnée par défaut) : le widget écoute alors tous les comptes Twitch et YouTube de la communauté.
4. Dans l'onglet **Configuration du widget**, remplissez les deux sections, puis cliquez sur **Enregistrer** :
   - **Connexion au pont Talky** : **Adresse publique du pont Talky** (`talky_bridge_url`), l'adresse du tunnel sans `/` final ; **Jeton du pont** (`talky_token`), la valeur `token` de `bridge\config.json` (celle que le bridge a mise dans votre presse-papiers à son premier lancement) ; **Commande de chat (sans « ! »)** (`talky_command`), `zombie` par défaut.
   - **Événements envoyés au jeu** : une case par événement, de **Envoyer les follows** à **Envoyer les nouveaux membres YouTube** (`talky_on_follow`, `talky_on_sub`, `talky_on_gift`, `talky_on_bits`, `talky_on_raid`, `talky_on_points`, `talky_on_command`, `talky_on_donation`, `talky_on_superchat`, `talky_on_member`), toutes cochées par défaut.
5. Dans le bloc **Activation**, cliquez sur **Activer**. La ligne passe à « Actif sur Global. » et le bloc **Écoute** liste les comptes que le widget écoute.

`talky_token` est déclaré comme variable secrète : LibertyTalk le conserve sans le réafficher et le masque dans les traces d'exécution. Pour le changer, saisissez la nouvelle valeur et enregistrez.

Pour chaque événement activé, le widget envoie `POST <talky_bridge_url>/hooks/<id>` avec l'en-tête `X-Bridge-Token` :

| Événement | Déclencheur LibertyTalk | Webhook du bridge | Workflow d'exemple | Champs envoyés |
|---|---|---|---|---|
| Nouveau follower | `channelFollow` | `/hooks/follow` | `new_follower` | `user_name` |
| Abonnement (hors abonnements offerts) | `channelSubscribe` | `/hooks/sub` | `new_sub` | `user_name`, `tier`, `is_gift` |
| Abonnements offerts | `channelSubscriptionGift` | `/hooks/gift` | `gift_subs` | `user_name`, `total`, `tier` |
| Bits | `channelCheer` | `/hooks/bits` | `bits` | `user_name`, `bits` |
| Raid | `channelRaid` | `/hooks/raid` | `raid` | `user_name`, `viewers` |
| Points de chaîne | `channelPointsRedemption` | `/hooks/points` | routes selon le titre de la récompense | `user_name`, `reward_title` |
| Commande de chat | `commandReceived` | `/hooks/command` | `chat_zombie` | `command` |
| Don | `donationReceived` | `/hooks/donation` | `donation` | `donor`, `amount`, `formatted_amount` |
| Super Chat | `youtubeSuperChat` | `/hooks/superchat` | `donation` | `author_display_name`, `formatted_amount` |
| Nouveau membre | `youtubeNewMember` | `/hooks/member` | `new_sub` | `author_display_name` |

À savoir :

- L'appel de la commande de chat ne contient que le nom de la commande, `{"command":"zombie"}` : ni le pseudo du viewer, ni le texte tapé après la commande. Le contrat développeur de Twitch interdit de redistribuer les messages du chat hors de Twitch, et LibertyTalk applique cette règle aux widgets de la marketplace. `!zombie` et `!zombie Bob` font donc la même chose : le zombie prend le pseudo réglé pour les événements anonymes (**F8 > Réglages > Pseudo des événements anonymes**, `Anonyme` quand le champ est vide et la langue du bridge en français, `Anonymous` en anglais).
- Le widget n'envoie jamais un texte libre tapé par un viewer : l'appel des points de chaîne contient le pseudo du viewer et le titre de la récompense, pas le texte saisi avec la récompense (`user_input`).
- Abonnements : l'appel `sub` ne part que pour les abonnements qui ne sont pas offerts. Un cadeau de 5 abonnements arrive une seule fois, sur `gift`, avec `total` = 5.
- Points de chaîne : le webhook `points` choisit le workflow d'après le titre de la récompense. Avec les exemples en français, le titre doit contenir `hélico`, `soin`, `tempête` ou `zombie` (`helicopter`, `heal`, `storm` ou `zombie` avec les exemples en anglais). Les mots se changent dans **F8 > Webhooks > points > Modifier les routes (JSON)**.
- Quand l'adresse du tunnel change, mettez à jour **Adresse publique du pont Talky** dans la configuration du widget et cliquez sur **Enregistrer**. Le changement s'applique tout de suite, sans désactiver le widget.
- LibertyTalk attend le bridge 10 secondes. Un appel vers un bridge arrêté peut tout de même apparaître comme terminé dans la console d'exécution de LibertyTalk : vérifiez d'abord la fenêtre du bridge ou **F8 > Statut**.

**Sans le widget**, construisez votre propre workflow LibertyTalk : un déclencheur du tableau, puis l'action **Appel webhook / API** avec l'URL `https://<tunnel>/hooks/<id>`, la méthode `POST`, les en-têtes supplémentaires `{"X-Bridge-Token":"<jeton>"}` et un corps JSON construit comme la colonne « Champs envoyés », par exemple `{"user_name":"{user_name}","bits":"{bits}"}`. Laissez « Signer la requête » sur Non : cette signature utilise une clé que le bridge ne connaît pas. Le jeton peut aussi aller dans l'URL (`?token=...`), mais l'en-tête le garde hors de l'URL.

## La fenêtre en jeu (F8)

La touche se change dans **Options > Raccourcis > Talky**.

| Page | Contenu |
|---|---|
| **Statut** | Bridge connecté ou hors ligne, version du bridge, URL publique du tunnel, URL de chaque webhook avec un bouton **Copier l'URL** (le jeton est copié, jamais affiché), derniers événements reçus par le bridge avec la raison quand l'un d'eux a été ignoré. |
| **Webhooks** | Créer, renommer ou supprimer des webhooks. Choisir le workflow que chacun lance, ou des routes selon le contenu. Jeton dédié optionnel. |
| **Workflows** | Activation, cooldowns, chance, condition. Étapes modifiées par un formulaire par action (les champs acceptent `{{user}}`), déplacées vers le haut ou le bas, étapes avancées en JSON (`if`, `random`, `repeat`). **Tester maintenant** avec le pseudo de votre choix. |
| **Événements du jeu** | Associer « un zombie nommé meurt », « le joueur meurt » et « la partie démarre » à un workflow. |
| **Réglages** | Plafonds (zombies par action, workflows simultanés, distance d'apparition), noms au-dessus des zombies, durée et position des bandeaux, langue des textes du bridge, pseudo des événements anonymes. |

**Enregistrer** écrit `Zomboid\Lua\talky_config.json`, que le bridge recharge sans redémarrage. À son premier lancement, le bridge crée ce fichier à partir de `bridge\config.json`. Si F8 > Enregistrer l'a créé avant, sans aucun webhook ni workflow, le bridge y ajoute les exemples de `config.json` et garde l'URL publique et les réglages déjà enregistrés. Ensuite, `talky_config.json` contient les webhooks, les workflows, les événements du jeu, l'URL publique et les réglages, et `bridge\config.json` garde le port, le jeton, les hôtes autorisés et le mode polling. Un `config.example.json` plus récent ne modifie jamais un `talky_config.json` existant : pour obtenir les nouveaux exemples, renommez `talky_config.json` et relancez le bridge.

## Écrire des workflows à la main

La fenêtre F8 couvre tout ce qui suit. Cette section sert si vous préférez modifier `Zomboid\Lua\talky_config.json` directement.

### Webhooks et workflows

```json
"webhooks": {
  "follow": { "workflow": "new_follower" },
  "points": { "routes": [
    { "when": { "reward_title": { "contains": "hélico" } }, "workflow": "points_helicopter" },
    { "when": { "reward_title": { "contains": "zombie" } }, "workflow": "points_zombie" }
  ] }
}
```

Chaque clé de `webhooks` devient `POST /hooks/<clé>`. `routes` choisit le workflow d'après le contenu de l'événement : la première route qui correspond l'emporte. `workflow` accepte aussi une liste, pour lancer plusieurs workflows.

```json
"new_follower": {
  "when": { "user": { "ne": "UnBotQuelconque" } },
  "chance": 1,
  "cooldownSeconds": 0,
  "userCooldownSeconds": 0,
  "steps": [
    { "action": "notify", "text": "{{user}} rejoint la horde !", "color": "#b388ff" },
    { "action": "wait", "seconds": 2 },
    { "action": "spawn_zombie", "name": "{{user}}", "distance": 14 }
  ]
}
```

### Gabarits `{{ }}`

- `{{user}}`, `{{bits}}`, `{{payload.champ.sous_champ}}`, `{{query.param}}`. `{{user}}` est le champ `user` quand l'appel en contient un, sinon le premier champ trouvé parmi `user_name`, `author_display_name`, `display_name`, `donor`, `chatter_name`, `actor_name`, `username`, `author_username`, `user_login` et `name` : le même workflow fonctionne pour Twitch et YouTube. Quand aucun n'est rempli, c'est le pseudo des événements anonymes (F8 > Réglages).
- Filtres : `{{bits | div:100 | floor | clamp:1:20}}`, `{{tier | tier}}` (1000/2000/3000 devient 1/2/3), `{{user | upper}}`, `{{user | truncate:12}}`, `{{viewers | default:5}}`, `{{'' | pick:Jean:Paul:Marie}}`.
- Tous les filtres : `default upper lower truncate number round floor ceil add sub mul div min max clamp tier pick json`.
- Un champ qui ne contient qu'un seul `{{...}}` garde son type : `"count": "{{viewers}}"` donne un nombre.
- `bits`, `viewers`, `total`, `amount` et `tier` arrivent de LibertyTalk sous forme de texte (`"500"`). Le bridge les convertit en nombres avant les conditions et les filtres.
- Ces doubles accolades ne fonctionnent que dans `talky_config.json`. Dans un champ LibertyTalk, `{user_name}` est une variable LibertyTalk.

### Conditions (`when`, `if`, `routes`)

- `{ "bits": { "gte": 100 } }`, `{ "tier": "3000" }`, `{ "command": ["zombie", "z"] }`
- Opérateurs : `eq ne gt gte lt lte in contains matches exists` (`contains` et `matches` ignorent la casse).
- Combinaisons : `{ "all": [...] }`, `{ "any": [...] }`, `{ "not": {...} }`

### Étapes de contrôle

Le bridge résout ces étapes avant d'envoyer le job au jeu.

| Étape | Effet |
|---|---|
| `{ "if": cond, "then": [...], "else": [...] }` | branche |
| `{ "random": [[...], [...]], "weights": [3, 1] }` | une branche tirée au hasard, pondérée |
| `{ "repeat": "{{bits \| div:100 \| floor}}", "max": 20, "steps": [...] }` | boucle, `{{i}}` est le numéro du tour (100 au plus) |
| `{ "chance": 0.3, "steps": [...] }` | probabilité |
| `{ "set": { "x": "{{...}}" } }` | définit une variable pour les étapes suivantes |
| `{ "action": "wait", "seconds": 2 }` | pause **dans le jeu**, 600 s au plus, les autres jobs continuent |
| `{ "action": "http", "url": "...", "body": {...} }` | appel HTTP sortant fait par le bridge, uniquement vers les hôtes autorisés (voir Sécurité) ; `headers`, `method`, `hmacSecret` et `hmacHeader` sont optionnels |
| `{ "action": "log", "message": "..." }` | ligne dans la fenêtre du bridge |

Les étapes `http` et `log` s'exécutent en arrière-plan : elles ne retardent ni les étapes du jeu ni la réponse à LibertyTalk.

## Actions en jeu

| Action | Paramètres |
|---|---|
| `notify` | `text` (200 caractères au plus), `color` (#hex), `seconds` (60 au plus) : bandeau à l'écran |
| `say` / `halo` | `text` (200 caractères au plus) : le personnage parle / texte flottant |
| `spawn_zombie` | `name`, `count`, `distance`, `minDistance`, `outfit`, `crawler`, `health`, `onFire`, `fakeDead`, `aggro` (vrai par défaut), `cluster`, `radius`, `sameName`, `color`, `outside` |
| `horde` | comme `spawn_zombie`, en groupe (15 zombies à 25 cases par défaut) |
| `noise` | `radius`, `volume`, `sound` : un bruit qui attire les zombies |
| `sound` | `name` : un son du jeu |
| `helicopter` | lance l'événement hélicoptère |
| `thunder` | `strike` |
| `weather` | `type` : `storm`, `blizzard`, `tropical` ou `clear`, ou `stage` (numéro), `hours` |
| `time` | `hour` (de 0 à 23,99) |
| `fire` | `distance` : un départ de feu près du joueur |
| `vehicle` | `script` (par exemple `Base.PickUpTruck`), `distance` |
| `give_item` | `item` (par exemple `Base.Katana`), `count`, `onGround` |
| `heal` | soin complet |
| `stat` | `stat` (`PANIC`, `STRESS`, `FATIGUE`, `HUNGER`, `INTOXICATION`...), `op` (`add`, `set` ou `remove`), `value` |
| `xp` | `perk` (par exemple `Woodwork`), `amount` |
| `emit` | `event`, `data` : renvoie un événement au bridge |

Les zombies nommés affichent leur nom au-dessus de la tête et le gardent après une sauvegarde (il est stocké dans leur modData). Les plafonds se règlent sur la page Réglages : 60 zombies par action, 8 jobs en même temps et 60 cases de distance par défaut. Un job plus ancien que `jobTtlSeconds` (15 minutes par défaut) est ignoré : une partie lancée en retard ne reçoit pas 40 hordes d'un coup.

Pour ajouter une action, dans un fichier Lua de votre mod ou d'un autre mod :

```lua
Talky_Actions.register("teleport", function(p, player) player:setX(p.x); player:setY(p.y) end)
```

## Événements renvoyés par le jeu

| Événement | Données |
|---|---|
| `zombie_killed` | `name`, `byPlayer` (un zombie nommé meurt) |
| `player_died` | `hoursSurvived`, `zombieKills` |
| `game_started` | aucune |
| `job_done` | `seq`, `workflow` |
| `action_failed` | `seq`, `action`, `error` |

```json
"gameEvents": { "zombie_killed": "on_zombie_killed", "player_died": ["on_player_died", "report_to_libertytalk"] }
```

**Envoyer un événement du jeu à LibertyTalk**

1. Dans LibertyTalk, créez un workflow avec le déclencheur **Webhook entrant**. Il fournit une URL (`https://api.liberty-talk.com/webhooks/workflow/<jeton>`) et un secret. Associez les champs dont vous avez besoin (`name`, `event`, `zombieKills`...).
2. Dans `talky_config.json`, complétez le workflow d'exemple `report_to_libertytalk` et activez-le :
   ```json
   "report_to_libertytalk": {
     "steps": [
       { "action": "http",
         "url": "https://api.liberty-talk.com/webhooks/workflow/<jeton>",
         "headers": { "X-Webhook-Secret": "<secret>" },
         "body": { "event": "{{event}}", "name": "{{name}}", "zombieKills": "{{zombieKills}}" } }
     ]
   }
   ```
3. Associez-le à un événement du jeu (F8 > Événements du jeu, ou `gameEvents` ci-dessus). LibertyTalk répond 202. L'hôte correspond au `*.liberty-talk.com` de `httpAllowedHosts` par défaut.

Le bridge sait aussi signer le corps avec `"hmacSecret"` et `"hmacHeader": "X-LT-Signature"`, mais LibertyTalk traite une signature sans horodatage comme une signature ancienne : préférez `X-Webhook-Secret`.

## Sécurité

- **Jeton.** Chaque appel à `/hooks/<id>` et `/fire/<workflow>` exige le jeton, dans l'en-tête `X-Bridge-Token` ou dans `?token=`. La comparaison se fait en temps constant. Sans jeton valide, tous les identifiants de webhook répondent 401 : impossible de les deviner. Un webhook peut avoir son propre jeton (il refuse alors le jeton global). `POST /fire/<workflow>` lance n'importe quel workflow avec le jeton global.
- **Réseau.** Le bridge n'écoute que sur `127.0.0.1` (`host` dans `config.json`). C'est le tunnel qui le rend joignable depuis internet.
- **Appels sortants.** Une étape `http` ne joint que les hôtes listés dans `httpAllowedHosts` de `bridge\config.json` (par défaut `["*.liberty-talk.com"]` ; `*.exemple.com` couvre tous les sous-domaines de exemple.com mais pas exemple.com lui-même ; `"*"` autorise tous les hôtes et supprime cette protection). Toute autre étape est refusée et signalée dans la fenêtre du bridge et sur la page Statut de F8. Les redirections ne sont pas suivies. La raison : `talky_config.json` se trouve dans `Zomboid\Lua`, un dossier où n'importe quel autre mod peut écrire. Sans cette liste, un mod pourrait ajouter une étape `http` et se servir du bridge pour envoyer des données n'importe où, sur internet ou sur votre réseau local. La liste elle-même reste dans `bridge\config.json`, hors de portée des mods du jeu.
- **Ce qui reste possible.** Un mod peut toujours lire `talky_status.json`, qui contient le jeton pour les boutons « Copier l'URL », et viser le webhook entrant de n'importe quel compte LibertyTalk. N'installez que des mods de confiance.
- **Plafonds.** `wait` 600 s, textes de `notify` / `say` / `halo` 200 caractères, bandeaux 60 s, noms de zombies 60 caractères, `repeat` 100 tours, 500 étapes de jeu et 20 étapes `http` / `log` par job, 10 000 étapes et tours de boucle parcourus par job (au-delà, la suite du workflow est ignorée et la fenêtre du bridge le signale), 200 jobs en attente dans le jeu, corps d'un appel webhook 64 Ko.
- **En stream.** La fenêtre F8 n'affiche jamais de jeton : le jeton global n'y apparaît pas, et le jeton dédié d'un webhook se saisit dans un champ masqué. La fenêtre du bridge affiche `~` à la place de votre dossier utilisateur Windows, messages d'erreur compris. À son premier lancement, le bridge copie son nouveau jeton dans le presse-papiers sans l'afficher.
- **Secrets sur le disque.** `bridge\config.json` et `bridge\bridge-state.json` sont dans `.gitignore` et jamais dans le zip de release. L'élément du Steam Workshop ne contient que le mod.

## Limites

- Solo ou hôte uniquement. Un serveur dédié demanderait un module `server/` (`sendClientCommand`).
- L'adresse d'un tunnel rapide change à chaque lancement : mettez à jour les réglages du widget et l'URL publique de F8.
- La version 0.3.0 a été testée avec une API du jeu simulée : le Lua tourne dans Kahlua (la machine Lua du jeu) avec de faux objets du jeu. À vérifier en partie réelle : la position des noms au-dessus des têtes, l'aggro des zombies (`spotted` / `pathToCharacter`), `testHelicopter()` hors mode debug, les numéros de stades météo (repris du menu debug B42), le raccourci personnalisé, et `byPlayer` (qui vaut peut-être toujours `false`).
- Le mode polling (plus bas) n'a pas été testé sur une instance LibertyTalk réelle.

## Dépannage

| Symptôme | Cause et solution |
|---|---|
| F8 affiche « Bridge hors ligne » | Le bridge n'est pas lancé, ou `zomboidLuaDir` dans `config.json` pointe vers le mauvais dossier (jeu lancé avec `-cachedir`). |
| `No config at ... Start the bridge once (start-bridge.cmd)`, après `node bridge\bridge.js fire ...` | `bridge\config.json` n'existe pas encore. Lancez une première fois le bridge avec `start-bridge.cmd` : il crée le fichier. |
| `Cannot create ...\bridge\config.json` | Vous ne pouvez pas écrire dans le dossier de Talky (sous `C:\Program Files`, par exemple). Déplacez-le dans `Documents\Talky` et relancez `start-bridge.cmd`. |
| `Set a long random "token" in config.json` | Le jeton est vide ou vaut encore `change-me...` (un `config.json` copié à la main depuis `config.example.json`). Mettez-y une longue chaîne aléatoire, ou supprimez `config.json` et relancez le bridge : il en crée un nouveau. |
| `warning: cloudflared is not in the PATH` | Installez-le avec `winget install --id Cloudflare.cloudflared`, puis ouvrez une nouvelle fenêtre. |
| `warning: Talky is installed twice` | Supprimez `%USERPROFILE%\Zomboid\mods\Talky` : la version du Workshop suffit. |
| `warning: The bridge folder ... is inside ...\Zomboid\mods` | Sortez tout le dossier de Talky de `Zomboid\mods`, `bridge\config.json` compris (vers `Documents\Talky`, par exemple), puis lancez `start-bridge.cmd` depuis ce nouvel emplacement. Le jeton ne change pas. |
| `'node' n'est pas reconnu`, ou `Node.js was not found on this PC.` dans la fenêtre de `start-bridge.cmd` | Installez Node.js 18 ou plus, puis ouvrez une nouvelle fenêtre. |
| `Port 7420 is already used` | Un autre programme (ou un second bridge) utilise le port. Changez `port` dans `config.json` et dans la commande cloudflared. |
| LibertyTalk refuse l'URL | L'URL est locale (`http://127.0.0.1...`). Collez l'adresse `https://...trycloudflare.com`. |
| `401 bad token` | Mauvais jeton, ou webhook à jeton dédié appelé avec le jeton global. Le bridge vérifie le jeton en premier : sans le bon jeton, même un identifiant de webhook inconnu répond 401. |
| `404 unknown webhook` | L'identifiant manque dans `talky_config.json`. Après le premier lancement, `config.json` n'est plus lu pour les webhooks, sauf si `talky_config.json` n'a ni webhook ni workflow. |
| `413 body too large` | Corps de plus de 64 Ko. |
| Le bridge affiche `job #N` mais rien ne se passe | Jeu en pause, joueur mort, retour au menu principal, job plus ancien que `jobTtlSeconds`, ou 8 jobs déjà en cours (longues étapes `wait`). |
| Statut affiche « ignoré : cooldown / condition non remplie / tirage de chance perdu / workflow désactivé » | Le workflow a refusé l'événement : voyez ses réglages sur la page Workflows. |
| `http step refused: host "..." is not in httpAllowedHosts` | Ajoutez l'hôte à `httpAllowedHosts` dans `bridge\config.json` et relancez le bridge. |
| Plus rien ne marche après un redémarrage | L'adresse du tunnel a changé : mettez à jour le widget et l'URL publique de F8. |
| Le mod n'apparaît pas dans la liste | Sans le Workshop, le jeu a besoin de `%USERPROFILE%\Zomboid\mods\Talky\42\mod.info` : copiez le dossier `Talky` du zip, pas le dossier qui le contient. Vérifiez que Talky n'est pas installé deux fois (Workshop et `Zomboid\mods`). |

Journaux : le jeu écrit des lignes `[Talky]` dans `%USERPROFILE%\Zomboid\console.txt`. `http://127.0.0.1:7420/health?token=<jeton>` renvoie le nombre de jobs en attente, le dernier job acquitté et les 50 derniers événements.

Fichiers d'échange dans `%USERPROFILE%\Zomboid\Lua\` : `talky_inbox.jsonl` (jobs), `talky_ack.txt`, `talky_outbox.jsonl` (événements du jeu), `talky_status.json` (battement du bridge) et `talky_config.json` (la configuration modifiée par la fenêtre F8).

## Référence de `bridge\config.json`

| Clé | Défaut | Rôle |
|---|---|---|
| `port` | `7420` | Port du bridge. |
| `host` | `127.0.0.1` | Adresse d'écoute. Gardez `127.0.0.1` : le tunnel se connecte en local. |
| `token` | aléatoire | Jeton des appels webhook, tiré au sort quand le bridge crée `config.json`. |
| `zomboidLuaDir` | `%USERPROFILE%/Zomboid/Lua` | Dossier partagé avec le mod. |
| `jobTtlSeconds` | `900` | Un job plus ancien est ignoré par le jeu. |
| `httpAllowedHosts` | `["*.liberty-talk.com"]` | Hôtes que les étapes `http` peuvent appeler. |
| `settings` | `{"language": "en", "anonymousName": ""}`, `fr` quand le format régional de Windows est le français | Copiés dans `talky_config.json` au premier lancement, puis modifiés dans F8 > Réglages. |
| `webhooks`, `workflows`, `gameEvents` | exemples | Copiés dans `talky_config.json` au premier lancement. |
| `poll` | désactivé | Source expérimentale sans adresse publique, voir ci-dessous. |

**Mode polling (expérimental).** Au lieu de recevoir des webhooks, le bridge lit le flux d'activité LibertyTalk toutes les `intervalSeconds` (10 s, 5 s au minimum) avec un jeton d'API : `"url": "https://<tenant>.api.liberty-talk.com/community/<community_id>/activity?per_page=50"`, `"apiToken"`, `"headers"` optionnel. `types` associe un type d'activité à un workflow : `follow`, `subscribe`, `subscribe_gift`, `cheer`, `raid`, `donation`, `superchat`, `member` (`resub`, `member_gift`, `charity`, `boost` et `first_message` existent aussi). Le bridge remplit `user_name` à partir de `actor_name`, et `bits` (cheer), `viewers` (raid) et `total` (abonnements offerts) à partir de `amount`. Les événements déjà présents dans le flux au démarrage du bridge ne sont pas rejoués.

## Développement

- Tests du bridge : `cd bridge`, puis `npm test` (Node 18 ou plus, sans dépendance). Ils lancent de vrais bridges sur des ports libres avec un dossier de jeu temporaire.
- Tests Lua : `powershell -ExecutionPolicy Bypass -File tools\test-lua.ps1 -GameDir "<chemin de ProjectZomboid>"` (Java 17 ou plus). Ils compilent chaque fichier avec le Kahlua du jar du jeu, puis font tourner le mod avec de faux objets du jeu : chaque page de la fenêtre F8 en anglais et en français, clés de traduction, plafonds.
- Dossier Steam Workshop : `tools\build-workshop.ps1` assemble `%USERPROFILE%\Zomboid\Workshop\Talky` (`-OutDir` pour l'assembler ailleurs), conserve l'`id=` Workshop après le premier envoi et refuse les types de fichiers que le Workshop rejette. Ensuite, dans le jeu : **Workshop > Create and update items**.
- Release : `tools\build-release.ps1` produit `dist\Talky-<version>-windows.zip` et `dist\SHA256SUMS.txt`. La version de `bridge\package.json` doit correspondre au `modversion` de `mod.info`.
- `mod\Talky\42\poster.png` et `packaging\workshop\preview.png` sont des images provisoires dessinées par `tools\make-placeholder-images.ps1`.
- Traductions : `mod\Talky\42\media\lua\shared\Translate\<LANGUE>\UI.json` (clés `UI_Talky_*`, les mêmes clés dans chaque langue) et `Mod.json` (nom et description du mod).

## Licence

MIT, voir [LICENSE](LICENSE). La licence couvre le code, pas les noms ni les logos LibertyTalk et Tech Liberty.

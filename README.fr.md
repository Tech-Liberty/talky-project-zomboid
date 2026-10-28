# Talky : les événements live de LibertyTalk dans Project Zomboid (Build 42)

[English version](README.md)

Talky relie [LibertyTalk](https://liberty-talk.com) à Project Zomboid. Un follow, un abonnement, des bits, un raid, une récompense de points de chaîne ou un Super Chat sur votre stream lance un workflow dans votre partie : un zombie au nom du nouveau follower, une horde à la taille du raid, l'hélicoptère pour 1000 bits. Le jeu renvoie aussi ses propres événements (« un zombie nommé est mort », « le joueur est mort »), qui peuvent lancer d'autres workflows, y compris un appel vers LibertyTalk.

Talky fonctionne en solo, en partie hébergée et sur un serveur dédié. En multijoueur, c'est le serveur qui exécute les effets, et tous les joueurs les voient : voir [Multijoueur](#multijoueur).

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

- Windows 10 ou 11, sur le PC qui fait tourner le jeu et le bridge.
- Project Zomboid Build 42.20.1 ou plus, en solo, en tant qu'hôte d'une partie ou sur un serveur dédié. Sur un serveur, Talky doit aussi être installé sur le serveur : voir [Multijoueur](#multijoueur).
- Node.js 18 ou plus : `winget install OpenJS.NodeJS.LTS`
- cloudflared, pour l'adresse publique du bridge : `winget install --id Cloudflare.cloudflared`
- Un compte LibertyTalk avec Twitch ou YouTube connecté.

## Installation

Le mod s'obtient de deux façons. N'en utilisez qu'une : deux mods avec l'id `Talky` perturbent le jeu. Dans les deux cas, le bridge vient de la release GitHub, et il n'y a rien à lancer avant `start-bridge.cmd`.

**A. Le mod depuis le Steam Workshop**

1. Abonnez-vous à Talky sur le Steam Workshop.
2. Téléchargez `Talky-0.4.0-windows.zip` dans les [releases GitHub](https://github.com/Tech-Liberty/talky-project-zomboid/releases) et décompressez-le dans un dossier que vous gardez, par exemple `Documents\Talky`.
3. Laissez le dossier `Talky` du zip où il est : le Workshop fournit déjà le mod, et le jeu ne lit pas ce dossier en dehors de `Zomboid\mods`.

**B. Sans le Steam Workshop**

1. Téléchargez `Talky-0.4.0-windows.zip` et décompressez-le dans un dossier que vous gardez, comme en A.
2. Copiez le dossier `Talky` du zip dans `%USERPROFILE%\Zomboid\mods`, pour que le jeu trouve `%USERPROFILE%\Zomboid\mods\Talky\42\mod.info`. Ne copiez que ce dossier : le bridge reste dans `Documents\Talky`.

Ne décompressez pas le zip dans `Zomboid\mods`. Avec le Workshop, le dossier `Talky` du zip y deviendrait une seconde copie du mod. Dans les deux cas, supprimer ou remplacer un mod à cet endroit peut effacer le bridge et son `bridge\config.json`. Le bridge affiche un avertissement au démarrage dans ces deux situations.

Pour vérifier le téléchargement, comparez `Get-FileHash Talky-0.4.0-windows.zip -Algorithm SHA256` avec le fichier `SHA256SUMS.txt` de la release.

**Mise à jour depuis la 0.3.0.** Remplacez le mod et le bridge en même temps, et gardez `bridge\config.json` et `%USERPROFILE%\Zomboid\Lua\talky_config.json`. Depuis la version 42.20.1 du jeu, les mods ne peuvent écrire que des fichiers `.ini`, `.cfg`, `.txt`, `.log` et `.json`. Le jeu refusait le fichier `talky_outbox.jsonl` de Talky 0.3.0 : aucun événement du jeu (`zombie_killed`, `player_died`, `game_started`, `job_done`, `action_failed`) ni aucun **Tester maintenant** n'arrivait au bridge. Talky 0.4.0 écrit `talky_outbox.txt`, que le bridge 0.4.0 lit (il lit toujours l'ancien fichier). **Tester maintenant** demande aussi les deux en 0.4.0 : le bridge n'exécute qu'un test qui porte le code de test qu'il écrit dans `talky_status.json` à chaque démarrage. Avec un bridge plus ancien, F8 > Statut affiche « Bridge antérieur à 0.4.0 ».

Ce que la 0.4.0 change pour une installation 0.3.0 :

- Un jeton de webhook dédié saisi dans la fenêtre F8 de la 0.3.0 est enregistré dans `talky_config.json`, un fichier que tout mod du jeu peut lire. Le bridge 0.4.0 l'ignore (une ligne `warning:` nomme le webhook) et ce webhook prend le jeton du bridge : une URL LibertyTalk qui porte l'ancien jeton dédié reçoit `401 bad token`. Déplacez le jeton dans `hookTokens` de `bridge\config.json` (voir [URL des webhooks et jetons](#url-des-webhooks-et-jetons)) et relancez le bridge.
- Une étape `http` avec un `hmacSecret` écrit dans `talky_config.json` est refusée. Mettez l'adresse et ses secrets dans `httpTargets` de `bridge\config.json` et nommez la cible dans l'étape (voir [Envoyer un événement du jeu à LibertyTalk](#envoyer-un-événement-du-jeu-à-libertytalk)). Des `headers` écrits dans une étape fonctionnent toujours, avec un avertissement.
- `talky_status.json` ne contient plus le jeton, et les boutons **Copier l'URL** de F8 sont devenus **Copier la commande** : ils copient `node bridge\bridge.js url <webhook>`, qui met l'URL complète dans le presse-papiers.

## Lancer et tester

1. Double-cliquez sur `start-bridge.cmd` et laissez sa fenêtre ouverte. Au premier lancement, vous devez voir ces lignes, chacune précédée de l'heure :
   ```
   created ~\Documents\Talky\bridge\config.json with a random token (language: fr)
   the token is in your clipboard and in config.json, never shown here: paste it into "Bridge token" in the LibertyTalk widget
   created ~\Zomboid\Lua\talky_config.json from config.json (fr: 19 text(s) translated)
   config loaded: 10 webhook(s), 14 workflow(s)
   Talky bridge 0.4.0 listening on http://127.0.0.1:7420
   game folder: ~\Zomboid\Lua
   http steps allowed to: *.liberty-talk.com
     webhook  POST /hooks/follow
   ```
   Les trois premières lignes n'apparaissent qu'au premier lancement. Avec un Windows en anglais, elles affichent `(language: en)` et `from config.json` sans la mention `(fr: ...)`.
2. Dans Project Zomboid : **Mods**, activez **Talky - LibertyTalk Live Events**, puis lancez une partie solo ou chargez-en une (pour un serveur, voir [Multijoueur](#multijoueur)). Appuyez sur **F8**. La page Statut affiche `Bridge connecté sur le port 7420 - 0 job(s) en attente  (v0.4.0)`, puis `Solo : les jobs s'exécutent dans cette partie.`
3. Testez sans LibertyTalk : sur la page **Workflows**, sélectionnez `new_follower`, saisissez un pseudo et cliquez sur **Tester maintenant**. Ou, dans un terminal ouvert dans le dossier Talky :
   ```powershell
   node bridge\bridge.js fire new_follower user=Bob
   ```
   Un bandeau « Bob rejoint la horde ! » s'affiche puis, 2 secondes plus tard, un zombie nommé Bob apparaît entre 8 et 14 cases.

Ce que fait le premier lancement :

- `start-bridge.cmd` vérifie que Node.js 18 ou plus est installé, et affiche la commande `winget` quand ce n'est pas le cas.
- Le bridge crée `bridge\config.json` à partir de `bridge\config.example.json`, avec un jeton aléatoire de 48 caractères hexadécimaux. Un `config.json` existant n'est jamais remplacé. Pour obtenir un nouveau jeton, lancez `node bridge\bridge.js new-token` (voir [URL des webhooks et jetons](#url-des-webhooks-et-jetons)).
- Le jeton est copié dans votre presse-papiers et n'est jamais affiché, il reste donc hors du stream. Quand la copie échoue, la ligne indique `the token is in config.json ("token")`.
- Les workflows d'exemple et les textes du bridge sont en français quand le format régional de Windows est le français, en anglais sinon. Pour changer de langue ensuite : arrêtez le bridge, mettez `settings.language` à `fr` ou `en` dans `bridge\config.json`, renommez `%USERPROFILE%\Zomboid\Lua\talky_config.json` (il contient ce que vous avez modifié dans F8) et relancez le bridge.
- Si vous lancez le jeu avec `-cachedir`, indiquez le dossier `Lua` de cet emplacement dans `zomboidLuaDir` de `bridge\config.json`, puis relancez le bridge.
- À chaque démarrage, une ligne `warning:` s'affiche quand cloudflared n'est pas dans le PATH, quand Talky est installé deux fois (dans `Zomboid\mods\Talky` et depuis le Workshop), quand le dossier du bridge se trouve dans `Zomboid\mods`, ou quand `jobTtlSeconds` dépasse 900 ou n'est pas un nombre (900 est alors utilisé). Le bridge démarre quand même.

## Donner une adresse publique au bridge

LibertyTalk refuse les adresses locales et privées (protection contre les requêtes forgées côté serveur) : le bridge a donc besoin d'une adresse HTTPS publique. Dans une seconde fenêtre :

```powershell
cloudflared tunnel --url http://127.0.0.1:7420
```

cloudflared affiche une adresse du type `https://des-mots-au-hasard.trycloudflare.com`. Ce tunnel rapide ne demande aucun compte, mais son adresse change à chaque lancement et Cloudflare le réserve aux tests, sans garantie de disponibilité. Pour garder la même adresse d'un stream à l'autre, créez un tunnel nommé sur votre propre domaine (voir la documentation Cloudflare Tunnel).

Collez l'adresse dans **F8 > Statut > URL publique**, puis **Enregistrer** : `node bridge\bridge.js url <webhook>` construit les URL des webhooks à partir d'elle.

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

**Sans le widget**, construisez votre propre workflow LibertyTalk : un déclencheur du tableau, puis l'action **Appel webhook / API** avec l'URL `https://<tunnel>/hooks/<id>`, la méthode `POST`, les en-têtes supplémentaires `{"X-Bridge-Token":"<jeton>"}` et un corps JSON construit comme la colonne « Champs envoyés », par exemple `{"user_name":"{user_name}","bits":"{bits}"}`. Laissez « Signer la requête » sur Non : cette signature utilise une clé que le bridge ne connaît pas. Le jeton peut aussi aller dans l'URL (`?token=...`), mais l'en-tête le garde hors de l'URL. Un webhook listé dans `hookTokens` prend son propre jeton à la place de celui du bridge.

## URL des webhooks et jetons

Le jeu ne connaît jamais les jetons : ils restent dans `bridge\config.json`, que le jeu ne peut pas lire. Ces commandes se lancent dans un terminal ouvert dans le dossier de Talky, que le bridge tourne ou non :

- `node bridge\bridge.js url <webhook>` met l'URL complète d'un webhook, `<URL publique>/hooks/<webhook>?token=<son jeton>`, dans le presse-papiers, et l'affiche avec le jeton masqué. L'URL publique est celle enregistrée dans F8 > Statut ; `--base https://<adresse du tunnel>` en donne une autre. `--show` affiche l'URL complète (pas pendant que la fenêtre est à l'écran du stream). Les boutons **Copier la commande** de F8 copient cette commande pour le webhook sélectionné.
- `node bridge\bridge.js new-token` écrit un nouveau jeton aléatoire dans `bridge\config.json`, le reste du fichier inchangé, et le met dans le presse-papiers sans l'afficher. Relancez le bridge (l'ancien jeton marche jusque-là), collez le nouveau jeton dans **Jeton du pont** du widget LibertyTalk, et copiez de nouveau les URL de vos webhooks avec `url`. Les jetons de `hookTokens` ne changent pas.
- `hookTokens` dans `bridge\config.json` donne à un webhook son propre jeton, de 16 caractères ou plus : `"hookTokens": { "follow": "<long texte aléatoire>" }`. Ce webhook refuse alors le jeton du bridge. Relancez le bridge après une modification. F8 > Webhooks indique si un webhook a un jeton dédié, jamais le jeton.

Depuis le dossier `bridge`, où `start-bridge.cmd` lance le bridge, les mêmes commandes s'écrivent `node bridge.js url <webhook>` et `node bridge.js new-token`, ou `npm run url -- <webhook>` et `npm run new-token`.

## La fenêtre en jeu (F8)

La touche se change dans **Options > Raccourcis > Talky**.

| Page | Contenu |
|---|---|
| **Statut** | Bridge connecté ou hors ligne, version du bridge (avec un avertissement quand le bridge est antérieur à 0.4.0), solo ou multijoueur, URL publique du tunnel, URL de chaque webhook avec le jeton masqué et un bouton **Copier la commande** (il copie `node bridge\bridge.js url <webhook>` ; le jeu ne copie jamais de jeton), derniers événements reçus par le bridge avec la raison quand l'un d'eux a été ignoré ou refusé. En multijoueur : la réponse du serveur (il exécute vos jobs, ou il les refuse et pourquoi), ses limites, les catégories qu'il a désactivées, les jobs sans réponse, le dernier job refusé, et le bouton **M'autoriser (hôte)** pour l'hôte d'une partie. |
| **Webhooks** | Créer, renommer ou supprimer des webhooks. Choisir le workflow que chacun lance, ou des routes selon le contenu. Si le webhook a un jeton dédié (réglé dans `hookTokens` de `bridge\config.json`), et **Copier la commande**. |
| **Workflows** | Activation, cooldowns, chance, condition. Étapes modifiées par un formulaire par action (les champs acceptent `{{user}}`), déplacées vers le haut ou le bas, étapes avancées en JSON (`if`, `random`, `repeat`). **Tester maintenant** avec le pseudo de votre choix. |
| **Événements du jeu** | Associer « un zombie nommé meurt », « le joueur meurt » et « la partie démarre » à un workflow. |
| **Réglages** | Plafonds (zombies par action, workflows simultanés, distance d'apparition), noms au-dessus des zombies, durée et position des bandeaux, langue des textes du bridge, pseudo des événements anonymes. En multijoueur, les trois plafonds affichent les valeurs du serveur, en lecture seule (`30 (fixé par le serveur)`). |

**Enregistrer** écrit `Zomboid\Lua\talky_config.json`, que le bridge recharge sans redémarrage. À son premier lancement, le bridge crée ce fichier à partir de `bridge\config.json`. Si F8 > Enregistrer l'a créé avant, sans aucun webhook ni workflow, le bridge y ajoute les exemples de `config.json` et garde l'URL publique et les réglages déjà enregistrés. Ensuite, `talky_config.json` contient les webhooks, les workflows, les événements du jeu, l'URL publique et les réglages, et `bridge\config.json` garde le port, le jeton, les jetons dédiés des webhooks (`hookTokens`), les cibles http et leurs secrets (`httpTargets`), les hôtes autorisés et le mode polling. Un `config.example.json` plus récent ne modifie jamais un `talky_config.json` existant : pour obtenir les nouveaux exemples, renommez `talky_config.json` et relancez le bridge.

## Multijoueur

Talky fonctionne en partie hébergée (**Héberger** dans le menu principal) et sur un serveur dédié. Le solo fonctionne comme avant.

```
PC du streamer                                             serveur
+-----------+  fichiers +-----------------+   réseau    +-------------------+
| bridge.js |---------->| Project Zomboid |------------>| Talky (serveur)   |
|           |<----------| Talky (client)  |<------------| vérifie les jobs, |
+-----------+  ack et   +-----------------+ réponses et | les exécute       |
                outbox                      effets      +-------------------+
```

### Ce qui change

- Le bridge et le tunnel restent sur le PC du streamer, comme en solo. Rien ne change sur la machine du serveur à part le mod : ni bridge, ni tunnel, ni port à ouvrir.
- Le jeu du streamer lit les jobs de son bridge et les envoie au serveur. Le serveur vérifie qui les envoie, applique ses limites, puis les exécute autour du personnage du streamer.
- Les effets sur le monde s'exécutent sur le serveur, et tous les joueurs les voient : les zombies et les noms au-dessus d'eux, les objets, les véhicules, le feu, la météo, l'heure, les bruits, les sons, l'hélicoptère.
- Les effets sur un personnage ne touchent que le streamer qui a envoyé le job : `heal` (exécuté dans le jeu du streamer), `stat`, `xp` et `give_item`. Aucune étape ne peut viser un autre joueur.
- Les bandeaux (`notify`) s'affichent seulement sur l'écran du streamer, sauf si le serveur les montre à tous les joueurs (option **Bannières**). `say` passe par le chat « say », les joueurs proches le voient : 12 lignes par minute par streamer et 60 pour tout le serveur, au-delà desquelles la ligne s'affiche seulement au-dessus du personnage. `halo` s'affiche sur l'écran du streamer.
- Les événements du jeu (`zombie_killed`, `job_done`, `action_failed`...) reviennent au jeu du streamer qui a envoyé le job, qui les écrit pour son propre bridge. `player_died` et `game_started` viennent du jeu du streamer lui-même ; en multijoueur, `game_started` est écrit après la première réponse du serveur.
- Plusieurs streamers peuvent jouer sur le même serveur, chacun avec son bridge et son widget LibertyTalk. Chacun a sa propre file d'attente et ses propres limites ; les limites marquées « tous les joueurs » s'appliquent à tous ensemble.
- Les webhooks, workflows et événements du jeu de la fenêtre F8 restent sur le PC de chaque streamer, dans `talky_config.json`. Les plafonds de la page Réglages viennent du serveur.
- Le serveur ne lit ni n'écrit jamais les fichiers de `Zomboid\Lua`. En partie hébergée, le serveur et le jeu de l'hôte partagent ce dossier ; seul le jeu de l'hôte lit les jobs.

### Installer sur un serveur

Le mod va sur le serveur et sur chaque client. Un joueur qui rejoint un serveur ne fait tourner que les mods de la liste du serveur : Talky doit donc être dans cette liste, même pour un seul streamer.

**Serveur dédié.** Arrêtez le serveur. Dans `Zomboid\Server\<nom du serveur>.ini` (`servertest.ini` par défaut ; le dossier `Zomboid` est dans le dossier personnel du compte qui lance le serveur), ajoutez Talky à ces deux listes, séparé des autres entrées par `;` :

```ini
Mods=Talky
WorkshopItems=<id Workshop de Talky>
```

- `WorkshopItems` prend le numéro à la fin de l'adresse de l'élément du Steam Workshop, une fois Talky publié. Les joueurs qui se connectent sont alors invités à le télécharger.
- Sans le Workshop, laissez Talky hors de `WorkshopItems` et copiez le dossier `Talky` du zip dans le dossier `Zomboid\mods` du serveur et de chaque joueur. Toutes les copies doivent être de la même version.
- Le jeu 42.21 lit `Mods=\Talky` comme `Mods=Talky`.

Démarrez le serveur. Sa console (`Zomboid\server-console.txt`) affiche `[Talky] server ready (Talky 0.4.0, protocol 1)`.

**Partie hébergée.** Dans le menu principal : **Héberger** > **Modifier les réglages ...**, sélectionnez les réglages, puis **Modifier les réglages sélectionnés**. Sur la page **Mods**, ajoutez Talky (« Ajouter à la liste un mod installé »). Avec la version du Workshop, ajoutez-le aussi sur la page **Workshop Steam**. La page **Talky** des mêmes réglages contient les options ci-dessous (si elle manque, activez Talky dans le menu **Mods** du menu principal et rouvrez les réglages). Lancez ensuite la partie. La console du serveur d'une partie hébergée est `Zomboid\coop-console.txt`.

**Sur le PC de chaque streamer.** Rien de nouveau : le mod (même version que le serveur) et le bridge, comme dans [Installation](#installation). Lancez le bridge, puis rejoignez le serveur. F8 > Statut affiche `Multijoueur :  le serveur exécute vos jobs (Talky 0.4.0 sur le serveur).`, ou `Partie hébergée (vous êtes l'hôte) :` pour l'hôte.

### Qui peut utiliser Talky

Sur un serveur, le serveur vérifie chaque job. Un joueur peut utiliser Talky quand :

- son rôle a la capacité **CreateHorde** et l'option **Les admins et modérateurs peuvent utiliser Talky** est activée (par défaut). Parmi les rôles par défaut, admin et moderator l'ont, gm et observer non. Un rôle personnalisé peut la recevoir ;
- ou son nom d'utilisateur est dans **Joueurs autorisés** : noms séparés par des virgules ou des points-virgules. Un espace fait partie du nom : `Big Boss` est un seul nom d'utilisateur. Seules les lettres de A à Z ignorent les majuscules, comme pour les noms de comptes du jeu : `zoé` et `ZOÉ` sont deux noms, `Bob` et `bob` un seul.

Sur un serveur ouvert à tous, la première personne qui se connecte avec un nom d'utilisateur libre crée ce compte. Ajoutez un streamer à **Joueurs autorisés** après sa première connexion, une fois son mot de passe choisi, ou utilisez un serveur sur liste blanche.

Pour tout autre joueur, F8 > Statut affiche `le serveur refuse les jobs de <nom>.` et le jeu n'envoie aucun job. Les jobs attendent dans le bridge et expirent après `jobTtlSeconds`. Le jeu redemande au serveur toutes les 30 secondes : un rôle ou une entrée dans **Joueurs autorisés** donné en cours de partie s'applique sans se reconnecter. Le serveur revérifie l'autorisation à chaque tick pour les jobs qu'il a déjà acceptés. Si l'autorisation est retirée en cours de partie, le serveur abandonne les jobs de ce joueur, en attente ou en cours, et refuse les suivants que le jeu envoie : chacun donne `job_rejected` avec la raison `not_allowed`. Le jeu arrête alors d'envoyer des jobs et redemande au serveur toutes les 30 secondes. Une catégorie désactivée en cours de partie (voir [Options du serveur](#options-du-serveur-options-bac-à-sable--talky)) fonctionne de la même façon : les étapes de cette catégorie qui n'ont pas encore tourné donnent `action_failed` avec le code `disabled`.

**Partie hébergée.** Le compte de l'hôte démarre avec le rôle par défaut, pas admin : l'hôte est donc refusé au début. F8 > Statut affiche alors `Votre rôle sur ce serveur n'est pas admin : cliquez sur M'autoriser, ou ajoutez <nom> dans Options bac à sable > Talky > Joueurs autorisés.` Le bouton **M'autoriser (hôte)** envoie `/setaccesslevel "<votre nom d'utilisateur>" admin` au serveur, qui accepte cette commande de la part de l'hôte de la partie. Quelques secondes plus tard, le statut passe à `le serveur exécute vos jobs`. Autre solution : ajoutez le nom d'utilisateur de l'hôte à **Joueurs autorisés** avant de lancer la partie.

En solo, chaque job s'exécute, et les options bac à sable de Talky ne s'appliquent pas : les plafonds sont ceux de F8 > Réglages.

Le journal `cmd` du serveur (dans `Zomboid\Logs`) enregistre chaque commande Talky avec le nom d'utilisateur du joueur qui l'a envoyée.

### Options du serveur (Options bac à sable > Talky)

Où les régler :

- partie hébergée : la page **Talky** des réglages (voir plus haut) ;
- serveur dédié : `Zomboid\Server\<nom du serveur>_SandboxVars.lua`, dans la table `Talky`. Arrêtez le serveur avant de le modifier :
  ```lua
  Talky = {
      AllowedPlayers = "streamer_un, streamer_deux",
      AllowAdmins = true,
      MaxZombiesPerAction = 30,
      -- ...
  },
  ```
- en cours de partie, pour un joueur au rôle admin : **Panneau d'admin** > **Options bac à sable** > **Talky**.

Un monde créé avant la 0.4.0 n'a pas d'options Talky : les valeurs par défaut s'appliquent tant que vous ne les réglez pas. Talky relit les valeurs chaque seconde.

| Option (en jeu) | Nom `Talky.` | Défaut | Plage | Effet |
|---|---|---|---|---|
| Joueurs autorisés | `AllowedPlayers` | vide | texte | Noms d'utilisateur qui peuvent utiliser Talky, séparés par des virgules ou des points-virgules (un espace fait partie du nom). |
| Les admins et modérateurs peuvent utiliser Talky | `AllowAdmins` | activé | | Les rôles qui ont la capacité CreateHorde peuvent utiliser Talky sans être dans la liste. |
| Zombies max par action | `MaxZombiesPerAction` | 30 | 1-300 | Une étape `spawn_zombie` ou `horde`. |
| Zombies max par job | `MaxZombiesPerJob` | 60 | 1-500 | Toutes les étapes d'un même job. |
| Zombies max par joueur sur 10 minutes | `MaxZombiesPer10Min` | 150 | 1-2000 | Jobs d'un même streamer, sur les 10 dernières minutes. |
| Zombies max sur 10 minutes (tous les joueurs) | `MaxZombiesPer10MinServer` | 400 | 1-5000 | Tous les streamers ensemble. |
| Distance d'apparition max (cases) | `MaxSpawnDistance` | 40 | 5-150 | Distance au streamer. |
| Étapes max par job | `MaxStepsPerJob` | 100 | 10-500 | Les étapes au-delà sont ignorées ; la console du jeu du streamer indique combien. |
| Jobs en attente max par joueur | `MaxQueuedJobs` | 10 | 1-50 | Au-delà, le serveur répond `busy` et le jeu du streamer renvoie le job 5 secondes plus tard. |
| Jobs en cours en même temps max par joueur | `MaxActiveJobs` | 4 | 1-20 | Un job garde sa place pendant ses étapes `wait`. |
| Jobs max par minute par joueur | `MaxJobsPerMinute` | 30 | 1-120 | Au-delà, le serveur répond `rate_limited` et le job est renvoyé plus tard, jusqu'à la fin de sa durée de vie. |
| Zombies et hordes | `AllowZombies` | activé | | `spawn_zombie`, `horde`. |
| Objets | `AllowItems` | activé | | `give_item` (100 objets au plus par action). |
| Objets max par joueur sur 10 minutes | `MaxItemsPer10Min` | 300 | 1-5000 | |
| Objets interdits | `ItemDenylist` | vide | texte | Types complets d'objets séparés par des virgules, par exemple `Base.Katana, Base.Shotgun`. |
| Véhicules | `AllowVehicles` | activé | | `vehicle`, dehors, seulement quand le streamer est au rez-de-chaussée. |
| Véhicules max par joueur sur 10 minutes | `MaxVehiclesPer10Min` | 2 | 1-20 | Chaque véhicule reste dans la sauvegarde. |
| XP | `AllowXp` | activé | | `xp` (1000 XP au plus par action, compétences seulement : pas les catégories comme `Combat`). |
| XP max par joueur sur 10 minutes | `MaxXpPer10Min` | 5000 | 1-100000 | |
| Soin et stats | `AllowPlayerEffects` | activé | | `heal`, `stat`, sur le personnage du streamer lui-même. |
| Météo et tonnerre | `AllowWeather` | activé | | `weather`, `thunder`. La même météo pour tous les joueurs, 12 heures de jeu au plus par action. |
| Délai entre deux météos (minutes) | `WeatherCooldownMinutes` | 15 | 0-240 | Pour tout le serveur. |
| Délai entre deux tonnerres (secondes) | `ThunderCooldownSeconds` | 30 | 0-3600 | Pour tout le serveur. |
| Heure du jour | `AllowTime` | activé | | `time`. La même heure pour tous les joueurs. |
| Délai entre deux changements d'heure (minutes) | `TimeCooldownMinutes` | 30 | 0-240 | Pour tout le serveur. |
| Feu | `AllowFire` | **désactivé** | | `fire`, et le paramètre `onFire` de `spawn_zombie` / `horde` (les zombies apparaissent sans feu quand il est désactivé). Le feu se propage et peut atteindre les bases des autres joueurs. |
| Hélicoptère | `AllowHelicopter` | **désactivé** | | `helicopter`. Sur un serveur, l'hélicoptère va vers un joueur au hasard, pas vers le streamer. |
| Hélicoptère avec plusieurs joueurs connectés | `HelicopterAnyTarget` | désactivé | | Désactivé : `helicopter` ne s'exécute que lorsqu'un seul joueur est connecté. |
| Délai entre deux hélicoptères (minutes) | `HelicopterCooldownMinutes` | 60 | 0-600 | Pour tout le serveur. |
| Bruits et sons | `AllowSounds` | activé | | `noise`, `sound`. |
| Rayon de bruit max (cases) | `MaxNoiseRadius` | 80 | 1-300 | Un bruit attire tous les zombies dans ce rayon. |
| Distance des autres joueurs (cases) | `ProtectRadius` | 15 | 0-100 | Aucun zombie, feu ou véhicule de Talky n'apparaît aussi près d'un autre joueur connecté, ni dans un refuge où le streamer n'a pas accès. 0 désactive le contrôle de distance (le contrôle des refuges reste). |
| Bannières | `BannerAudience` | Le streamer seulement | Le streamer seulement (1), Tous les joueurs, avec le nom du streamer (2) | Les bandeaux `notify` et le bandeau d'un zombie nommé qui meurt. Avec 2, les autres joueurs voient `[<streamer>] ` avant le texte ; au-delà de 6 bandeaux par minute par streamer ou 20 par minute en tout (bandeaux `notify` et morts de zombies nommés comptés ensemble), les suivants ne vont qu'au streamer. |
| Actions d'autres mods | `AllowCustomActions` | désactivé | | Les actions que d'autres mods ajoutent avec `Talky_Actions.register` et marquent `network = true`. |

Les catégories désactivées renvoient le code `disabled`, les budgets `budget` et les délais `cooldown` (voir [Événements renvoyés par le jeu](#événements-renvoyés-par-le-jeu)).

Limites fixes sur un serveur (pas des options) : 50 jobs en attente et 12 jobs en cours pour tous les joueurs ensemble ; 10 zombies créés par tick pour tout le serveur (un groupe plus grand apparaît sur les ticks suivants) ; 100 objets et 1000 XP par action ; 12 heures de jeu de météo par action ; 900 secondes d'étapes `wait` par job ; 10 étapes `fire` par streamer et 20 pour tout le serveur sur 10 minutes ; 60 étapes `noise` et `sound` par streamer sur 10 minutes (au-delà de ces budgets : `action_failed` avec `budget`) ; 12 lignes `say` par minute par streamer et 60 pour tout le serveur, au-delà desquelles la ligne s'affiche toujours au-dessus du personnage mais ne va pas dans le chat ; 128 zombies nommés sur le serveur, 32 par streamer ; 5 commandes par seconde par joueur. En solo, `fire`, `noise`, `sound` et `say` n'ont pas de budget.

Un job qui n'a pas démarré à la fin de sa durée de vie est abandonné (`job_expired`), en solo aussi : la durée de vie est `jobTtlSeconds` du bridge, et jamais plus de 15 minutes après la création du job par le bridge.

### Jobs refusés et retardés

- **Refusé définitivement** (`not_allowed`, `invalid`, `unknown_action`, `disabled`, `expired`) : le jeu signale au bridge que le job est pris, il quitte donc l'inbox. Il écrit `job_rejected {seq, workflow, reason}` pour le bridge, affiche le bandeau `Talky : job #12 refusé par le serveur (non autorisé)`, et F8 > Statut affiche le dernier job refusé. La fenêtre du bridge affiche la raison avec ce qu'il faut faire. `duplicate` (le serveur a déjà ce job) compte comme accepté.
- **Trop gros pour être envoyé** (`too_large`, multijoueur seulement) : le job ne tient pas dans un message réseau du jeu, le jeu du streamer ne l'envoie donc jamais. Il est acquitté et signalé comme un job refusé, avec le bandeau `Talky : job #12 trop gros pour être envoyé au serveur, ignoré`. Donnez au workflow moins d'étapes (comptez les tours de `repeat`) ou des textes plus courts.
- **Retardé** (`busy` : file d'attente pleine ; `rate_limited` : trop de jobs dans la dernière minute) : le jeu renvoie le job plus tard, 5 secondes plus tard pour `busy`, et garde l'ordre des jobs qui le suivent.
- **Une étape refusée** (une action désactivée, un délai, un budget épuisé, aucune case libre) : les autres étapes s'exécutent, et le bridge reçoit `action_failed` avec le code. Un job dont toutes les étapes sont refusées est refusé définitivement, avec la raison de la première étape.
- **Pas de réponse** : le jeu renvoie le job toutes les 30 secondes jusqu'à la fin de sa durée de vie. F8 > Statut compte les jobs sans réponse après 15 secondes.
- **Expiré sur le serveur** : un job qui a attendu au-delà de sa durée de vie avant de pouvoir démarrer donne `job_expired {seq, workflow}`.

### Limites en multijoueur

- Le bridge tourne sur le PC du streamer. Dans cette version, un serveur dédié ne peut pas lire lui-même les jobs d'un bridge installé sur sa machine.
- La météo et l'heure sont les mêmes pour tous les joueurs. Leurs délais comptent pour tout le serveur.
- Sur un serveur, `testHelicopter()` choisit un joueur connecté au hasard : l'hélicoptère est désactivé par défaut et, une fois activé, ne s'exécute que lorsqu'un seul joueur est connecté, sauf si **Hélicoptère avec plusieurs joueurs connectés** est activé (sinon `action_failed` avec `helicopter_random_target`).
- Sur un serveur, une tempête démarre tout de suite pour tous les joueurs ; un blizzard ou une tempête tropicale arrive chez les autres joueurs à la mise à jour climatique suivante du serveur, jusqu'à 10 minutes de jeu plus tard. Un changement d'heure arrive chez les joueurs en 10 secondes environ.
- Les noms au-dessus des zombies durent tant que le zombie reste dans la partie : un zombie qui disparaît loin des joueurs, un zombie que le jeu réutilise, un redémarrage du serveur ou 30 minutes effacent le nom. Tous les joueurs voient les noms (souvent des pseudos de viewers). Au-delà de 32 zombies nommés par streamer, ou de 128 en tout, les plus anciens perdent leur nom.
- `zombie_killed` part une seule fois par zombie, vers le streamer dont le job l'a fait apparaître, et seulement si ce streamer est connecté. `byPlayer` vaut `true` quand ce streamer l'a tué.
- `heal` s'exécute dans le jeu du streamer (en multijoueur, la santé appartient au jeu du joueur). Sur un personnage mort, il donne `action_failed` avec `dead`.
- **Distance des autres joueurs** peut laisser une apparition, un feu ou un véhicule sans case libre : `action_failed` avec `no_square`.
- Les jobs d'un streamer déconnecté ou mort, ou d'un serveur en pause, attendent ; les étapes `wait` continuent de compter en temps réel. Après 15 minutes de déconnexion, les jobs de ce streamer sont abandonnés. Les événements d'un streamer déconnecté sont perdus.
- Le serveur et chaque client doivent avoir la même version de Talky. Sinon, F8 > Statut affiche `Talky <version> sur le serveur, 0.4.0 ici : installez la même version des deux côtés.` et rien n'est envoyé.
- Les actions que d'autres mods ajoutent avec `Talky_Actions.register` ne s'exécutent sur un serveur qu'avec `network = true` et l'option **Actions d'autres mods**.

### À vérifier en partie réelle

La version 0.4.0 a été testée avec une API du jeu simulée : le Lua tourne dans Kahlua avec de faux objets du jeu, en solo, sur un serveur dédié avec plusieurs clients et en partie hébergée. Pas encore vérifié en partie réelle :

- `heal` (dans le jeu du streamer) et `stat` (modifié sur le serveur, puis envoyé au joueur) ;
- les noms au-dessus des zombies en multijoueur ;
- la cible de l'hélicoptère sur un serveur (un joueur au hasard) ;
- le délai d'un blizzard ou d'une tempête tropicale sur un serveur (mise à jour climatique suivante) ;
- le délai d'un changement d'heure sur un serveur (10 secondes environ) ;
- le bouton **M'autoriser (hôte)** en partie hébergée ;
- `say` par le chat en multijoueur, les objets au sol sur un serveur, la vérification du type de véhicule, les contrôles de rôle et de refuge du code serveur, et le défaut vide des options texte (**Joueurs autorisés**, **Objets interdits**).

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
| `{ "action": "http", "target": "lt_report", "body": {...} }` | appel HTTP sortant fait par le bridge vers une cible de `httpTargets` dans `bridge\config.json`, qui contient l'adresse, les en-têtes et le secret HMAC (voir [Envoyer un événement du jeu à LibertyTalk](#envoyer-un-événement-du-jeu-à-libertytalk)) ; `method` est optionnel. Une étape peut donner elle-même `url` et `headers` à la place de `target` : le bridge les envoie, avec un avertissement pour les en-têtes, puisque tout mod du jeu peut lire `talky_config.json` ; il refuse une étape avec `hmacSecret`. Uniquement vers les hôtes autorisés (voir Sécurité) |
| `{ "action": "log", "message": "..." }` | ligne dans la fenêtre du bridge |

Les étapes `http` et `log` s'exécutent en arrière-plan : elles ne retardent ni les étapes du jeu ni la réponse à LibertyTalk.

## Actions en jeu

| Action | Paramètres |
|---|---|
| `notify` | `text` (200 caractères au plus), `color` (`#rrggbb`), `seconds` (60 au plus) : bandeau à l'écran |
| `say` / `halo` | `text` (200 caractères au plus) : le personnage parle (en multijoueur, dans le chat « say », vu par les joueurs proches) / texte flottant |
| `spawn_zombie` | `name` (40 caractères au plus), `count`, `distance`, `minDistance`, `outfit`, `crawler`, `health`, `onFire`, `fakeDead`, `aggro` (vrai par défaut), `cluster`, `radius`, `sameName`, `color`, `outside` |
| `horde` | comme `spawn_zombie`, en groupe (15 zombies à 25 cases par défaut) |
| `noise` | `radius`, `volume`, `sound` : un bruit qui attire les zombies |
| `sound` | `name` : un son du jeu |
| `helicopter` | lance l'événement hélicoptère (sur un serveur : vers un joueur au hasard) |
| `thunder` | `strike` |
| `weather` | `type` : `storm`, `blizzard`, `tropical` ou `clear`, `hours`. En solo, `stage` (numéro) fonctionne aussi. La météo en cours s'arrête d'abord. |
| `time` | `hour` (de 0 à 23,99) |
| `fire` | `distance`, `minDistance` : un départ de feu près du joueur |
| `vehicle` | `script` (par exemple `Base.PickUpTruck`), `distance` : dehors |
| `give_item` | `item` (par exemple `Base.Katana`), `count` (100 au plus), `onGround` |
| `heal` | soin complet (dans le jeu du streamer) |
| `stat` | `stat` (`PANIC`, `STRESS`, `FATIGUE`, `HUNGER`, `THIRST`, `INTOXICATION`...), `op` (`add`, `set` ou `remove`), `value` |
| `xp` | `perk` (par exemple `Woodwork`), `amount` (10 000 au plus en solo, 1000 sur un serveur). Sur un serveur, la quantité est un nombre entier : la partie décimale est retirée, et une valeur inférieure à 1 donne `action_failed` avec `invalid`. Le solo garde les décimales. |
| `emit` | `event`, `data` : renvoie un événement au bridge (ni `test_workflow`, ni `game_started`, ni `player_died`, que seul le jeu lui-même écrit) |

`item` et `script` doivent exister dans les scripts du jeu ; sur un serveur, l'objet ne doit en plus être ni caché ni obsolète, ni dans **Objets interdits**. Sur un serveur, chaque action suit aussi les options bac à sable (voir [Multijoueur](#multijoueur)) : catégories, budgets, délais, distance des autres joueurs.

En solo, les zombies nommés affichent leur nom au-dessus de la tête et le gardent après une sauvegarde (il est stocké dans leur modData) ; en multijoueur, voir [Limites en multijoueur](#limites-en-multijoueur). En solo, les plafonds se règlent sur la page Réglages : 60 zombies par action, 8 jobs en même temps et 60 cases de distance par défaut. En multijoueur, ce sont les options bac à sable du serveur qui les fixent. Un job plus ancien que `jobTtlSeconds` (15 minutes par défaut, 15 minutes au plus : une valeur plus grande dans `bridge\config.json` est ramenée à 900 secondes, avec un avertissement au démarrage du bridge) est ignoré : une partie lancée en retard ne reçoit pas 40 hordes d'un coup.

Pour ajouter une action, dans un fichier Lua de votre mod ou d'un autre mod :

```lua
Talky_Actions.register("teleport", function(p, player) player:setX(p.x); player:setY(p.y) end)
```

Cette action s'exécute en solo. Pour exécuter une action aussi sur un serveur, enregistrez-la dans un fichier `shared/` ou `server/` (les fichiers `client/` ne tournent pas sur un serveur), déclarez-la compatible réseau ainsi que ses paramètres ; le serveur ne garde alors que ces paramètres, avec leur type, et l'option serveur **Actions d'autres mods** doit être activée :

```lua
Talky_Actions.register("mon_action", function(p, player, job, ctx)
    -- p.amount est un nombre ; job = { seq, id, workflow, user }
end, { network = true, params = { amount = "number" } })
```

Un gestionnaire ne renvoie rien quand il a réussi, ou un code court (`"no_square"`, par exemple) que le bridge reçoit dans `action_failed`.

## Événements renvoyés par le jeu

| Événement | Données |
|---|---|
| `zombie_killed` | `name`, `byPlayer` (un zombie nommé meurt ; `byPlayer` vaut `true` quand le streamer l'a tué) |
| `player_died` | `hoursSurvived`, `zombieKills` |
| `game_started` | `mode` (`sp` ou `client`), `host` (`true` pour l'hôte d'une partie hébergée), `server` (nom du serveur, vide en solo). En multijoueur, écrit après la première réponse du serveur. |
| `job_done` | `seq`, `workflow` |
| `action_failed` | `seq`, `action`, `code`, et `error` avec la même valeur (le champ de la 0.3.0) |
| `job_rejected` | `seq`, `workflow`, `reason` : un job refusé définitivement (voir [Jobs refusés et retardés](#jobs-refusés-et-retardés)) |
| `job_expired` | `seq`, `workflow` : un job qui a attendu au-delà de sa durée de vie avant de pouvoir démarrer |

Codes de `action_failed` : `unknown_action`, `disabled` (désactivé sur le serveur), `invalid` (une valeur que l'action ne peut pas utiliser ; une étape illisible, qui n'est pas un objet ou n'a pas d'`action` valide, arrive avec l'action `step`), `cooldown`, `budget` (limite par 10 minutes ou par job atteinte), `no_square` (aucune case libre), `not_found` (objet, véhicule, son, compétence, stat ou type de météo inconnu), `refused` (le jeu a refusé la météo, ou n'a créé aucun des zombies d'une étape `spawn_zombie` ou `horde`), `helicopter_random_target`, `error` (l'action a échoué ; détails dans la console du jeu ou du serveur), `dead` (`heal` sur un personnage mort).

`job_rejected` et `job_expired` s'affichent dans la fenêtre du bridge et sur F8 > Statut, et ne lancent jamais de workflow de `gameEvents`.

```json
"gameEvents": { "zombie_killed": "on_zombie_killed", "player_died": ["on_player_died", "report_to_libertytalk"] }
```

### Envoyer un événement du jeu à LibertyTalk

1. Dans LibertyTalk, créez un workflow avec le déclencheur **Webhook entrant**. Il fournit une URL (`https://api.liberty-talk.com/webhooks/workflow/<jeton>`) et un secret. Associez les champs dont vous avez besoin (`name`, `event`, `zombieKills`...).
2. Dans `bridge\config.json`, complétez la cible `lt_report` de `httpTargets` (le `config.json` créé à partir de l'exemple l'a déjà, avec des valeurs `PASTE_...` que le bridge refuse d'envoyer), puis relancez le bridge :
   ```json
   "httpTargets": {
     "lt_report": {
       "url": "https://api.liberty-talk.com/webhooks/workflow/<jeton>",
       "headers": { "X-Webhook-Secret": "<secret>" }
     }
   }
   ```
3. Dans `talky_config.json`, activez le workflow d'exemple `report_to_libertytalk`. Son étape nomme la cible : l'URL et le secret ne vont jamais dans un fichier que le jeu peut lire.
   ```json
   "report_to_libertytalk": {
     "steps": [
       { "action": "http", "target": "lt_report",
         "body": { "event": "{{event}}", "name": "{{name}}", "zombieKills": "{{zombieKills}}" } }
     ]
   }
   ```
4. Associez-le à un événement du jeu (F8 > Événements du jeu, ou `gameEvents` ci-dessus). LibertyTalk répond 202. L'hôte de la cible doit être dans `httpAllowedHosts` (`*.liberty-talk.com` par défaut).

Une cible peut aussi signer le corps : `"hmacSecret"` et `"hmacHeader": "X-LT-Signature"` dans son entrée de `httpTargets`. LibertyTalk traite une signature sans horodatage comme une signature ancienne : préférez `X-Webhook-Secret`. Avec `target`, les `url`, `headers`, `hmacSecret` et `hmacHeader` écrits dans l'étape sont ignorés (un avertissement par workflow). Sans `target`, un `hmacSecret` écrit dans l'étape la fait refuser par le bridge, et des `headers` écrits là sont envoyés avec un avertissement.

## Sécurité

- **Jeton.** Chaque appel à `/hooks/<id>` et `/fire/<workflow>` exige le jeton, dans l'en-tête `X-Bridge-Token` ou dans `?token=`. La comparaison se fait en temps constant. Sans jeton valide, tous les identifiants de webhook répondent 401 : impossible de les deviner. Un webhook listé dans `hookTokens` de `bridge\config.json` a son propre jeton et refuse le jeton global ; un `token` écrit pour un webhook dans `talky_config.json` ne compte pas (la fenêtre du bridge le signale). `POST /fire/<workflow>` lance n'importe quel workflow avec le jeton global.
- **Réseau.** Le bridge n'écoute que sur `127.0.0.1` (`host` dans `config.json`). C'est le tunnel qui le rend joignable depuis internet.
- **Appels sortants.** Une étape `http` ne joint que les hôtes listés dans `httpAllowedHosts` de `bridge\config.json` (par défaut `["*.liberty-talk.com"]` ; `*.exemple.com` couvre tous les sous-domaines de exemple.com mais pas exemple.com lui-même ; `"*"` autorise tous les hôtes et supprime cette protection). Toute autre étape est refusée et signalée dans la fenêtre du bridge et sur la page Statut de F8. Les redirections ne sont pas suivies. La raison : `talky_config.json` se trouve dans `Zomboid\Lua`, un dossier où n'importe quel autre mod peut écrire. Sans cette liste, un mod pourrait ajouter une étape `http` et se servir du bridge pour envoyer des données n'importe où, sur internet ou sur votre réseau local. La liste elle-même reste dans `bridge\config.json`, hors de portée des mods du jeu.
- **Les autres mods.** Tout mod qui tourne dans le jeu peut lire `talky_status.json` et `talky_config.json`, écrire `talky_config.json` et l'outbox, et envoyer ce qu'il lit au serveur où il joue. Sur un serveur, ce sont tous les mods de la liste du serveur. Aucun jeton, aucun secret http et aucune URL complète de webhook ne va donc dans ces fichiers : les jetons et les cibles restent dans `bridge\config.json`, `talky_status.json` ne liste que les identifiants des webhooks qui ont un jeton dédié, et les boutons **Copier la commande** copient une commande. Les mods du jeu peuvent aussi lire le presse-papiers : après `node bridge\bridge.js url`, collez l'URL, puis copiez autre chose. Talky lui-même n'envoie au serveur ni jeton, ni URL, ni webhook. Un mod peut encore ajouter un workflow qui appelle le webhook entrant de n'importe quel compte LibertyTalk (un hôte de `httpAllowedHosts`), ou lancer un workflow par un événement du jeu ou par **Tester maintenant**. Ne rejoignez que des serveurs dont vous acceptez la liste de mods, ou arrêtez le bridge avant de rejoindre. En cas de doute, lancez `node bridge\bridge.js new-token`, relancez le bridge, puis mettez à jour le widget LibertyTalk et les URL des webhooks.
- **Tester maintenant.** Le bridge écrit un code de test aléatoire dans `talky_status.json` à chaque démarrage, et n'exécute un événement `test_workflow` que s'il porte ce code. Ce code n'arrête que les lignes `test_workflow` qu'un serveur Talky ferait écrire au jeu : le serveur ne le connaît jamais (et le jeu refuse déjà d'écrire ces lignes pour le serveur). Un mod qui tourne dans le jeu peut le lire.
- **Multijoueur.** Le serveur reçoit, pour chaque job, son numéro, le nom du workflow, le pseudo du viewer et les étapes de jeu. Le jeton, l'URL publique et les webhooks ne quittent jamais le PC du streamer. Le serveur ne garde que les paramètres connus de chaque étape, avec leur type et leurs bornes (des nombres comme `NaN` ou `1e308` reprennent la valeur par défaut, les textes sont coupés, les couleurs doivent être `#rrggbb`), et ne se fie jamais à un nom envoyé par un client : l'expéditeur est le joueur de la connexion. Depuis le serveur, le jeu du streamer n'écrit que `zombie_killed`, `job_done`, `action_failed`, `job_rejected` et `job_expired`, avec des champs fixes, 60 lignes par minute au plus ; une étape `emit` est écrite à partir de la copie du job que le jeu a lui-même, et `test_workflow`, `game_started` et `player_died` ne viennent que du jeu lui-même. Chaque joueur peut envoyer 5 commandes Talky par seconde.
- **Plafonds.** `wait` 600 s, textes de `notify` / `say` / `halo` 200 caractères, bandeaux 60 s, noms de zombies 40 caractères, `repeat` 100 tours, 500 étapes de jeu et 20 étapes `http` / `log` par job, 10 000 étapes et tours de boucle parcourus par job (au-delà, la suite du workflow est ignorée et la fenêtre du bridge le signale), 200 jobs en attente dans le jeu en solo, corps d'un appel webhook 64 Ko. Sur un serveur, les options bac à sable et les limites fixes de [Multijoueur](#multijoueur) s'ajoutent.
- **En stream.** La fenêtre F8 n'affiche et ne copie jamais de jeton. `node bridge\bridge.js url` affiche l'URL avec le jeton masqué, sauf avec `--show`. La fenêtre du bridge affiche `~` à la place de votre dossier utilisateur Windows, messages d'erreur compris. À son premier lancement, le bridge copie son nouveau jeton dans le presse-papiers sans l'afficher.
- **Secrets sur le disque.** `bridge\config.json` et `bridge\bridge-state.json` sont dans `.gitignore` et jamais dans le zip de release. L'élément du Steam Workshop ne contient que le mod.

## Limites

- Le multijoueur a ses propres limites : voir [Limites en multijoueur](#limites-en-multijoueur) et [À vérifier en partie réelle](#à-vérifier-en-partie-réelle).
- L'adresse d'un tunnel rapide change à chaque lancement : mettez à jour les réglages du widget et l'URL publique de F8.
- La version 0.4.0 a été testée avec une API du jeu simulée : le Lua tourne dans Kahlua (la machine Lua du jeu) avec de faux objets du jeu. Toujours à vérifier en partie réelle depuis la 0.3.0 : la position des noms au-dessus des têtes, l'aggro des zombies (`spotted` / `pathToCharacter`), `testHelicopter()` hors mode debug, les numéros de stades météo (repris du menu debug B42), le raccourci personnalisé, et `byPlayer`.
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
| Le bridge affiche `job #N` mais rien ne se passe | Jeu en pause, joueur mort, retour au menu principal, job plus ancien que `jobTtlSeconds`, ou 8 jobs déjà en cours (longues étapes `wait`). En multijoueur, aussi : le serveur ne l'a pas encore accepté (F8 > Statut), ou ses limites (voir les lignes ci-dessous). |
| F8 > Statut : `le serveur refuse les jobs de <nom>.` | Votre nom d'utilisateur n'est pas dans **Joueurs autorisés** et votre rôle n'a pas la capacité CreateHorde : voir [Qui peut utiliser Talky](#qui-peut-utiliser-talky). Hôte d'une partie hébergée : cliquez sur **M'autoriser (hôte)**. |
| F8 > Statut : `pas de réponse du serveur.` | Le code Talky du serveur n'a pas répondu pendant 2 minutes, et le jeu n'envoie rien. Cherchez les lignes `[Talky]` et les erreurs Lua dans la console du serveur (`server-console.txt`, ou `coop-console.txt` pour une partie hébergée), puis reconnectez-vous. En solo, regardez dans `console.txt`. |
| F8 > Statut : `Talky <version> sur le serveur, 0.4.0 ici` | Installez la même version de Talky sur le serveur et sur chaque PC. |
| F8 > Statut : `Bridge antérieur à 0.4.0` | Mettez à jour le bridge avec le zip de la même release que le mod. Les événements du jeu et **Tester maintenant** en ont besoin. |
| Statut affiche « ignoré : pas de code de test (mettez le mod à jour) » ou « ignoré : code de test différent, relancez Tester maintenant » (une fenêtre F8 antérieure à 0.4.0 affiche « erreur : Test now refused: ... ») | Le bridge n'a lancé aucun test. Premier message : le test ne portait pas de code de test, le mod est donc antérieur à 0.4.0 : mettez-le à jour. Second message : le bridge a redémarré après que la fenêtre F8 a lu son code de test : cliquez de nouveau sur **Tester maintenant**. La fenêtre du bridge l'explique une fois par démarrage (`"Test now" refused: ...`). |
| `warning: the "token" of webhook "<id>" in talky_config.json is ignored` | La fenêtre F8 de Talky 0.3.0 y a enregistré un jeton dédié. Tant que vous ne l'avez pas déplacé dans `hookTokens` de `bridge\config.json` et relancé le bridge, le webhook prend le jeton du bridge, et une URL avec l'ancien jeton reçoit `401 bad token`. |
| `http step refused: "hmacSecret" written in the workflow` | Déplacez l'adresse et ses secrets dans `httpTargets` de `bridge\config.json`, écrivez `"target": "<nom>"` dans l'étape et relancez le bridge (voir [Envoyer un événement du jeu à LibertyTalk](#envoyer-un-événement-du-jeu-à-libertytalk)). |
| `http step refused: fill "httpTargets" > "lt_report" in bridge/config.json first` | La cible contient encore une valeur `PASTE_...` : mettez-y l'URL et le secret de votre webhook entrant, puis relancez le bridge. |
| `warning: "jobTtlSeconds" in config.json is ...: 900 is used.` | Le jeu et le serveur abandonnent un job 15 minutes après sa création par le bridge : mettez `jobTtlSeconds` à 900 ou moins. |
| La fenêtre du bridge affiche `not sent to the server: too_large` | Le job ne tient pas dans un message réseau du jeu : donnez au workflow moins d'étapes ou des textes plus courts. |
| La fenêtre du bridge affiche `refused by the server: disabled` | Une action du job est désactivée dans les options bac à sable du serveur (**Zombies et hordes**, **Feu**, **Hélicoptère**...). |
| `action_failed` avec `cooldown` ou `budget` | Un délai du serveur (météo, tonnerre, heure, hélicoptère) ou un budget par 10 minutes ou par job : voir [Options du serveur](#options-du-serveur-options-bac-à-sable--talky). |
| `action_failed` avec `helicopter_random_target` | Plusieurs joueurs sont connectés et **Hélicoptère avec plusieurs joueurs connectés** est désactivé. |
| `action_failed` avec `no_square` sur un serveur | Un autre joueur connecté dans la **Distance des autres joueurs**, un refuge où le streamer n'a pas accès, ou aucune case libre autour du streamer. |
| Statut affiche « ignoré : cooldown / condition non remplie / tirage de chance perdu / workflow désactivé » | Le workflow a refusé l'événement : voyez ses réglages sur la page Workflows. |
| `http step refused: host "..." is not in httpAllowedHosts` | Ajoutez l'hôte à `httpAllowedHosts` dans `bridge\config.json` et relancez le bridge. |
| Plus rien ne marche après un redémarrage | L'adresse du tunnel a changé : mettez à jour le widget et l'URL publique de F8. |
| Le mod n'apparaît pas dans la liste | Sans le Workshop, le jeu a besoin de `%USERPROFILE%\Zomboid\mods\Talky\42\mod.info` : copiez le dossier `Talky` du zip, pas le dossier qui le contient. Vérifiez que Talky n'est pas installé deux fois (Workshop et `Zomboid\mods`). |

Journaux : le jeu écrit des lignes `[Talky]` dans `%USERPROFILE%\Zomboid\console.txt`, un serveur dédié dans `Zomboid\server-console.txt`, le serveur d'une partie hébergée dans `Zomboid\coop-console.txt`. `http://127.0.0.1:7420/health?token=<jeton>` renvoie le nombre de jobs en attente, le dernier job acquitté, les jobs acquittés au-delà et les 50 derniers événements.

Fichiers d'échange dans `%USERPROFILE%\Zomboid\Lua\` du PC du streamer : `talky_inbox.jsonl` (jobs), `talky_ack.txt` (`S`, ou `S s1 s2 ...` : tous les jobs jusqu'à `S` sont pris, et `s1`, `s2`... aussi), `talky_outbox.txt` (événements du jeu ; `talky_outbox.jsonl` avec Talky 0.3.0), `talky_status.json` (battement du bridge, avec le code de test et les identifiants des webhooks qui ont un jeton dédié, jamais un jeton) et `talky_config.json` (la configuration modifiée par la fenêtre F8).

## Référence de `bridge\config.json`

| Clé | Défaut | Rôle |
|---|---|---|
| `port` | `7420` | Port du bridge. |
| `host` | `127.0.0.1` | Adresse d'écoute. Gardez `127.0.0.1` : le tunnel se connecte en local. |
| `token` | aléatoire | Jeton des appels webhook, tiré au sort quand le bridge crée `config.json`. `node bridge\bridge.js new-token` en tire un nouveau. |
| `hookTokens` | `{}` | `{ "<identifiant du webhook>": "<16 caractères ou plus>" }` : un webhook avec son propre jeton, qui refuse alors `token`. |
| `zomboidLuaDir` | `%USERPROFILE%/Zomboid/Lua` | Dossier partagé avec le mod. |
| `jobTtlSeconds` | `900` | Un job plus ancien est ignoré par le jeu (900 au plus : une valeur plus grande est ramenée à 900, avec un avertissement au démarrage). |
| `httpAllowedHosts` | `["*.liberty-talk.com"]` | Hôtes que les étapes `http` peuvent appeler. |
| `httpTargets` | `lt_report` avec des valeurs à remplacer | `{ "<nom>": { "url", "headers", "hmacSecret", "hmacHeader", "method" } }` : l'adresse et les secrets d'une étape `http` qui indique `"target": "<nom>"`. Seule `url` est obligatoire. |
| `settings` | `{"language": "en", "anonymousName": ""}`, `fr` quand le format régional de Windows est le français | Copiés dans `talky_config.json` au premier lancement, puis modifiés dans F8 > Réglages. |
| `webhooks`, `workflows`, `gameEvents` | exemples | Copiés dans `talky_config.json` au premier lancement. |
| `poll` | désactivé | Source expérimentale sans adresse publique, voir ci-dessous. |

**Mode polling (expérimental).** Au lieu de recevoir des webhooks, le bridge lit le flux d'activité LibertyTalk toutes les `intervalSeconds` (10 s, 5 s au minimum) avec un jeton d'API : `"url": "https://<tenant>.api.liberty-talk.com/community/<community_id>/activity?per_page=50"`, `"apiToken"`, `"headers"` optionnel. `types` associe un type d'activité à un workflow : `follow`, `subscribe`, `subscribe_gift`, `cheer`, `raid`, `donation`, `superchat`, `member` (`resub`, `member_gift`, `charity`, `boost` et `first_message` existent aussi). Le bridge remplit `user_name` à partir de `actor_name`, et `bits` (cheer), `viewers` (raid) et `total` (abonnements offerts) à partir de `amount`. Les événements déjà présents dans le flux au démarrage du bridge ne sont pas rejoués.

## Développement

- Tests du bridge : `cd bridge`, puis `npm test` (Node 18 ou plus, sans dépendance). Ils lancent de vrais bridges sur des ports libres avec un dossier de jeu temporaire.
- Tests Lua : `powershell -ExecutionPolicy Bypass -File tools\test-lua.ps1 -GameDir "<chemin de ProjectZomboid>"` (JDK 25 ou plus : les classes du jeu 42.21 sont des classes Java 25 ; `-Java "<chemin de java.exe>"` choisit un autre JDK). Ils compilent chaque fichier avec le Kahlua du jar du jeu, puis font tourner le mod avec de faux objets du jeu, un état Lua par processus du jeu : une partie solo, un serveur dédié avec plusieurs clients et une partie hébergée. Les messages entre processus sont copiés par le sérialiseur réseau du jeu lui-même. Couvert : chaque page de la fenêtre F8 en anglais et en français, clés de traduction, options bac à sable, plafonds, autorisations, acquittements, noms au-dessus des zombies, événements renvoyés au bridge. Pour un serveur dédié installé seul, `-GameDir` peut être son dossier `java`.
- Dossier Steam Workshop : `tools\build-workshop.ps1` assemble `%USERPROFILE%\Zomboid\Workshop\Talky` (`-OutDir` pour l'assembler ailleurs), conserve l'`id=` Workshop après le premier envoi et refuse les types de fichiers que le Workshop rejette. Ensuite, dans le jeu : **Workshop > Create and update items**.
- Release : `tools\build-release.ps1` produit `dist\Talky-<version>-windows.zip` et `dist\SHA256SUMS.txt`. La version de `bridge\package.json` doit correspondre au `modversion` de `mod.info`.
- `mod\Talky\42\poster.png` et `packaging\workshop\preview.png` sont des images provisoires dessinées par `tools\make-placeholder-images.ps1`.
- Traductions : `mod\Talky\42\media\lua\shared\Translate\<LANGUE>\UI.json` (clés `UI_Talky_*`, les mêmes clés dans chaque langue), `Sandbox.json` (les options serveur de `media\sandbox-options.txt`, clés `Sandbox_Talky_*`) et `Mod.json` (nom et description du mod).
- Organisation du code : `media\lua\client` ne tourne que dans le jeu du joueur, `media\lua\server` sur le serveur et en solo, `media\lua\shared` partout. Les fichiers serveur ne chargent jamais un fichier `client` et ne lisent ni n'écrivent de fichiers.

## Licence

MIT, voir [LICENSE](LICENSE). La licence couvre le code, pas les noms ni les logos LibertyTalk et Tech Liberty.

# Talky : les événements live de LibertyTalk dans Project Zomboid (Build 42)

[English version](README.md)

Talky relie [LibertyTalk](https://liberty-talk.com) à Project Zomboid. Un follow, un abonnement, des bits, un raid, une récompense de points de chaîne ou un Super Chat sur votre stream lance un workflow dans votre partie : un zombie au nom du nouveau follower, une horde à la taille du raid, l'hélicoptère pour 1000 bits. Le jeu renvoie aussi ses propres événements (« un zombie nommé est mort », « le joueur est mort »), qui peuvent lancer d'autres workflows, y compris un appel vers LibertyTalk.

Talky fonctionne en deux modes :

- **Solo** : le bridge tourne sur votre PC, à côté de votre partie.
- **Serveur** (dédié, ou une partie hébergée depuis le menu principal) : l'admin lance le bridge sur la machine du serveur et ajoute les streamers en jeu. Un streamer n'installe rien d'autre que le mod, et colle dans son widget LibertyTalk l'adresse et le jeton que l'admin lui donne. Voir [Multijoueur](#multijoueur).

```
LibertyTalk                       votre PC
+--------------+   HTTPS    +--------------+  fichiers  +-------------------+
| déclencheur  |----------->| tunnel       |----------->| Project Zomboid   |
| (follow...)  |  appel     |   |          |   inbox    | mod Talky (Lua)   |
|   |          |  webhook   | bridge.js    |<-----------| fenêtre F8        |
| widget       |            | (workflows)  | ack/outbox |                   |
+--------------+            +--------------+            +-------------------+
```

**Pourquoi un bridge ?** Le Lua de Project Zomboid (Kahlua) ne peut pas ouvrir de connexion réseau. Il peut seulement lire et écrire des fichiers dans le dossier `Zomboid\Lua\` du jeu (ou du serveur). Le bridge (le « pont ») est un petit programme Node.js sans dépendance : il reçoit les webhooks, exécute la logique (conditions, tirages au hasard, cooldowns, gabarits) et dépose des jobs que le mod lit chaque seconde.

## Prérequis

- Project Zomboid Build 42.20.1 ou plus.
- Node.js 18 ou plus, sur la machine qui fait tourner le bridge : `winget install OpenJS.NodeJS.LTS` sous Windows, le paquet de votre distribution (s'il est en version 18 ou plus) ou [nodejs.org](https://nodejs.org) sous Linux.
- Solo : Windows 10 ou 11 sur le PC qui fait tourner le jeu et le bridge, et cloudflared pour l'adresse publique du bridge : `winget install --id Cloudflare.cloudflared`.
- Serveur : la machine du serveur (Linux ou Windows), joignable depuis internet sur un port TCP (7420 par défaut). Voir [Multijoueur](#multijoueur).
- Un compte LibertyTalk avec Twitch ou YouTube connecté.

## Installation

Le mod s'obtient de deux façons. N'en utilisez qu'une : deux mods avec l'id `Talky` perturbent le jeu. Dans les deux cas, le bridge vient de la release GitHub, et il n'y a rien à lancer avant `start-bridge.cmd`.

**A. Le mod depuis le Steam Workshop**

1. Abonnez-vous à Talky sur le Steam Workshop.
2. Téléchargez `Talky-0.5.0.zip` dans les [releases GitHub](https://github.com/Tech-Liberty/talky-project-zomboid/releases) et décompressez-le dans un dossier que vous gardez, par exemple `Documents\Talky`.
3. Laissez le dossier `Talky` du zip où il est : le Workshop fournit déjà le mod, et le jeu ne lit pas ce dossier en dehors de `Zomboid\mods`.

**B. Sans le Steam Workshop**

1. Téléchargez `Talky-0.5.0.zip` et décompressez-le dans un dossier que vous gardez, comme en A.
2. Copiez le dossier `Talky` du zip dans `%USERPROFILE%\Zomboid\mods`, pour que le jeu trouve `%USERPROFILE%\Zomboid\mods\Talky\42\mod.info`. Ne copiez que ce dossier : le bridge reste dans `Documents\Talky`.

Ne décompressez pas le zip dans `Zomboid\mods`. Avec le Workshop, le dossier `Talky` du zip y deviendrait une seconde copie du mod. Dans les deux cas, supprimer ou remplacer un mod à cet endroit peut effacer le bridge et son `bridge\config.json`. Le bridge affiche un avertissement au démarrage dans ces deux situations.

Pour vérifier le téléchargement, comparez `Get-FileHash Talky-0.5.0.zip -Algorithm SHA256` (Windows) ou `sha256sum Talky-0.5.0.zip` (Linux) avec le fichier `SHA256SUMS.txt` de la release.

**Mise à jour depuis la 0.4.0.** Remplacez le mod et le bridge en même temps, sur le serveur et sur chaque PC. Gardez `bridge\config.json` et `Zomboid\Lua\talky_config.json`. Le solo fonctionne comme avant. Le multijoueur change entièrement : le bridge ne tourne plus sur le PC du streamer, et le jeu d'un streamer ne relaie plus les jobs vers le serveur. L'admin lance un seul bridge en mode serveur à côté du serveur et ajoute les streamers dans F8 > Webhooks (voir [Multijoueur](#multijoueur)) ; un streamer qui utilisait la 0.4.0 sur un serveur peut arrêter son propre bridge et son tunnel, et colle dans le widget LibertyTalk l'adresse et le jeton que l'admin lui donne. Les options bac à sable **Joueurs autorisés** et **Les admins et modérateurs peuvent utiliser Talky** disparaissent : la liste des streamers de F8 > Webhooks les remplace. Depuis la 0.3.0 : lisez aussi les notes de la 0.4.0 dans le [CHANGELOG](CHANGELOG.md).

## Lancer et tester (solo)

1. Double-cliquez sur `start-bridge.cmd` et laissez sa fenêtre ouverte. Au premier lancement, vous devez voir ces lignes, chacune précédée de l'heure :
   ```
   created ~\Documents\Talky\bridge\config.json with a random token (language: fr)
   the token is in your clipboard and in config.json, never shown here: paste it into "Bridge token" in the LibertyTalk widget
   created ~\Zomboid\Lua\talky_config.json from config.json (fr: 19 text(s) translated)
   config loaded: 10 webhook(s), 14 workflow(s)
   Talky bridge 0.5.0 listening on http://127.0.0.1:7420
   game folder: ~\Zomboid\Lua
   http steps allowed to: *.liberty-talk.com
     webhook  POST /hooks/follow
   ```
   Les trois premières lignes n'apparaissent qu'au premier lancement. Avec un Windows en anglais, elles affichent `(language: en)` et `from config.json` sans la mention `(fr: ...)`.
2. Dans Project Zomboid : **Mods**, activez **Talky - LibertyTalk Live Events**, puis lancez une partie solo ou chargez-en une. Appuyez sur **F8**. La page Statut affiche `Bridge connecté sur le port 7420 - 0 job(s) en attente  (v0.5.0)`, puis `Solo : les jobs s'exécutent dans cette partie.`
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

## Donner une adresse publique au bridge (solo)

LibertyTalk refuse les adresses locales et privées (protection contre les requêtes forgées côté serveur) : le bridge a donc besoin d'une adresse publique. Dans une seconde fenêtre :

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
   - **Connexion au pont Talky** : **Adresse publique du pont Talky** (`talky_bridge_url`) sans `/` final : en solo, l'adresse du tunnel ; sur un serveur, l'adresse que l'admin vous donne (`http://<IP publique du serveur>:7420`) ; **Jeton du pont** (`talky_token`) : en solo, la valeur `token` de `bridge\config.json` (celle que le bridge a mise dans votre presse-papiers à son premier lancement) ; sur un serveur, votre propre jeton, donné par l'admin ; **Commande de chat (sans « ! »)** (`talky_command`), `zombie` par défaut.
   - **Événements envoyés au jeu** : une case par événement, de **Envoyer les follows** à **Envoyer les nouveaux membres YouTube** (`talky_on_follow`, `talky_on_sub`, `talky_on_gift`, `talky_on_bits`, `talky_on_raid`, `talky_on_points`, `talky_on_command`, `talky_on_donation`, `talky_on_superchat`, `talky_on_member`), toutes cochées par défaut.
5. Dans le bloc **Activation**, cliquez sur **Activer**. La ligne passe à « Actif sur Global. » et le bloc **Écoute** liste les comptes que le widget écoute.

`talky_token` est déclaré comme variable secrète : LibertyTalk le conserve sans le réafficher et le masque dans les traces d'exécution. Pour le changer, saisissez la nouvelle valeur et enregistrez.

Si LibertyTalk refuse une adresse en `http://` avec « Seulement l'adresse du tunnel, par exemple https://... », votre LibertyTalk n'accepte pas encore l'adresse en clair du bridge d'un serveur : donnez en attendant une adresse `https://` au bridge (voir [Ports et sécurité](#ports-et-sécurité)).

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

**Sans le widget**, construisez votre propre workflow LibertyTalk : un déclencheur du tableau, puis l'action **Appel webhook / API** avec l'URL `<adresse du bridge>/hooks/<id>`, la méthode `POST`, les en-têtes supplémentaires `{"X-Bridge-Token":"<jeton>"}` et un corps JSON construit comme la colonne « Champs envoyés », par exemple `{"user_name":"{user_name}","bits":"{bits}"}`. Laissez « Signer la requête » sur Non : cette signature utilise une clé que le bridge ne connaît pas. Le jeton peut aussi aller dans l'URL (`?token=...`), mais l'en-tête le garde hors de l'URL. En solo, un webhook listé dans `hookTokens` prend son propre jeton à la place de celui du bridge.

## URL des webhooks et jetons

En solo, le jeu ne connaît jamais les jetons : ils restent dans `bridge\config.json`, que le jeu ne peut pas lire. Ces commandes se lancent dans un terminal ouvert dans le dossier de Talky, que le bridge tourne ou non :

- `node bridge\bridge.js url <webhook>` met l'URL complète d'un webhook, `<URL publique>/hooks/<webhook>?token=<son jeton>`, dans le presse-papiers, et l'affiche avec le jeton masqué. L'URL publique est celle enregistrée dans F8 > Statut ; `--base https://<adresse du tunnel>` en donne une autre. `--show` affiche l'URL complète (pas pendant que la fenêtre est à l'écran du stream). Les boutons **Copier la commande** de F8 copient cette commande pour le webhook sélectionné. En mode serveur, ajoutez `--streamer <nom d'utilisateur>` : l'URL porte le jeton de ce streamer.
- `node bridge\bridge.js new-token` écrit un nouveau jeton aléatoire dans `bridge\config.json`, le reste du fichier inchangé, et le met dans le presse-papiers sans l'afficher. Relancez le bridge (l'ancien jeton marche jusque-là), collez le nouveau jeton dans **Jeton du pont** du widget LibertyTalk, et copiez de nouveau les URL de vos webhooks avec `url`. Les jetons de `hookTokens` et ceux des streamers d'un serveur ne changent pas.
- `hookTokens` dans `bridge\config.json` donne à un webhook son propre jeton, de 16 caractères ou plus : `"hookTokens": { "follow": "<long texte aléatoire>" }`. Ce webhook refuse alors le jeton du bridge. Relancez le bridge après une modification. F8 > Webhooks indique si un webhook a un jeton dédié, jamais le jeton. Solo uniquement : en mode serveur, chaque streamer a son propre jeton.

Depuis le dossier `bridge`, où `start-bridge.cmd` lance le bridge, les mêmes commandes s'écrivent `node bridge.js url <webhook>` et `node bridge.js new-token`, ou `npm run url -- <webhook>` et `npm run new-token`.

## La fenêtre en jeu (F8)

La touche se change dans **Options > Raccourcis > Talky**.

| Page | Solo | Multijoueur |
|---|---|---|
| **Statut** | Bridge connecté ou hors ligne, version du bridge (avec un avertissement quand le bridge est antérieur à 0.4.0), URL publique du tunnel, URL de chaque webhook avec le jeton masqué et un bouton **Copier la commande** (il copie `node bridge\bridge.js url <webhook>` ; le jeu ne copie jamais de jeton), derniers événements reçus par le bridge avec la raison quand l'un d'eux a été ignoré ou refusé. | Chaque joueur : la réponse du serveur, si vous êtes streamer sur ce serveur, si son bridge tourne (et en mode serveur), ses limites et les catégories qu'il a désactivées. Les admins : les derniers événements du bridge. L'hôte d'une partie qui n'est pas admin a le bouton **M'autoriser (hôte)**. |
| **Webhooks** | Créer, renommer ou supprimer des webhooks. Choisir le workflow que chacun lance, ou des routes selon le contenu. Si le webhook a un jeton dédié (réglé dans `hookTokens` de `bridge\config.json`), et **Copier la commande**. | Réservé aux admins. Onglet **Streamers** : l'adresse publique du bridge, les streamers, **+ Ajouter un streamer**, et pour le streamer choisi les deux valeurs de son widget, **Afficher le jeton**, **Copier l'URL et le jeton**, **Nouveau jeton**, **Retirer**. Onglet **Webhooks** : les webhooks du serveur, comme en solo. |
| **Workflows** | Activation, cooldowns, chance, condition. Étapes modifiées par un formulaire par action (les champs acceptent `{{user}}`), déplacées vers le haut ou le bas, étapes avancées en JSON (`if`, `random`, `repeat`). **Tester maintenant** avec le pseudo de votre choix. | Réservé aux admins, les workflows du serveur. **Tester maintenant** exécute le workflow autour de votre propre personnage. |
| **Événements du jeu** | Associer « un zombie nommé meurt », « le joueur meurt » et « la partie démarre » à un workflow. | Réservé aux admins, les événements du jeu du serveur. |
| **Réglages** | Plafonds (zombies par action, workflows simultanés, distance d'apparition), noms au-dessus des zombies, durée et position des bandeaux, langue des textes du bridge, pseudo des événements anonymes. | Les trois plafonds affichent les valeurs du serveur, en lecture seule (`30 (fixé par le serveur)`). Les noms au-dessus des zombies et les bandeaux suivent la configuration du serveur : les admins les règlent ici pour tous les joueurs, les autres joueurs les voient en lecture seule. Les admins règlent aussi la langue des textes du bridge et le pseudo des événements anonymes. |

En solo, **Enregistrer** écrit `Zomboid\Lua\talky_config.json`, que le bridge recharge sans redémarrage. À son premier lancement, le bridge crée ce fichier à partir de `bridge\config.json`. Si F8 > Enregistrer l'a créé avant, sans aucun webhook ni workflow, le bridge y ajoute les exemples de `config.json` et garde l'URL publique et les réglages déjà enregistrés. Ensuite, `talky_config.json` contient les webhooks, les workflows, les événements du jeu, l'URL publique et les réglages, et `bridge\config.json` garde le mode, le port, le jeton, les jetons dédiés des webhooks (`hookTokens`), les cibles http et leurs secrets (`httpTargets`), les hôtes autorisés et le mode polling. Un `config.example.json` plus récent ne modifie jamais un `talky_config.json` existant : pour obtenir les nouveaux exemples, renommez `talky_config.json` et relancez le bridge.

En multijoueur, la fenêtre d'un admin charge le `talky_config.json` du serveur et **Enregistrer** le renvoie ; le serveur l'écrit et le bridge le recharge. Les autres clés du fichier restent telles quelles.

## Multijoueur

Sur un serveur, dédié ou hébergé depuis le menu principal, le bridge tourne sur la machine du serveur. Les streamers n'installent rien d'autre que le mod.

```
LibertyTalk                  machine du serveur                                 joueurs
+-------------+  HTTP(S)  +----------------+  fichiers +---------------------+  réseau   +-----------+
| widget d'un |---------->| bridge.js      |---------->| Project Zomboid     |---------->| jeux      |
| streamer    | webhook + | --server       |   inbox   | serveur + Talky     |  effets,  | + Talky   |
| (son jeton) | son jeton | 0.0.0.0:7420   |<----------| (lit les jobs,      |  noms,    | (F8)      |
|             |           |                | ack,      |  écrit les          |  F8       |           |
+-------------+           +----------------+ outbox    |  événements)        |           +-----------+
                                                       +---------------------+
```

### Fonctionnement

- L'admin lance le bridge en mode serveur sur la machine du serveur, ou sur le PC qui héberge la partie. Il écoute sur toutes les adresses de la machine, port 7420 par défaut, et travaille avec le dossier `Zomboid/Lua` du serveur.
- En jeu, l'admin ajoute chaque streamer dans **F8 > Webhooks** avec son nom d'utilisateur. Le bridge tire un jeton pour chacun. L'admin envoie au streamer l'adresse publique du bridge (`http://<IP publique du serveur>:7420`) et son jeton.
- Le streamer colle les deux valeurs dans son widget LibertyTalk : ni bridge ni tunnel sur son PC.
- Un appel webhook porte le jeton d'un streamer. Le bridge écrit le job pour ce streamer (`target`), le serveur le lit dans l'inbox et l'exécute autour de son personnage. Tous les joueurs voient les effets dans le monde.
- Le serveur écrit les événements du jeu (`zombie_killed`, `player_died`, `job_done`, `action_failed`...) avec le streamer qu'ils concernent ; leurs workflows s'exécutent pour ce streamer.
- Un seul jeu de webhooks, de workflows et d'événements du jeu pour tout le serveur : le `talky_config.json` du serveur. Les admins le modifient dans F8.

### Installer le mod sur un serveur

Le mod va sur le serveur et sur chaque client. Un joueur qui rejoint un serveur ne fait tourner que les mods de la liste du serveur : Talky doit donc être dans cette liste.

**Serveur dédié.** Arrêtez le serveur. Dans `Zomboid\Server\<nom du serveur>.ini` (`servertest.ini` par défaut ; le dossier `Zomboid` se trouve dans le dossier personnel du compte qui lance le serveur), ajoutez Talky à ces deux listes, séparé des autres entrées par `;` :

```ini
Mods=Talky
WorkshopItems=<id Workshop de Talky>
```

- `WorkshopItems` prend le numéro à la fin de l'adresse de l'élément du Steam Workshop, une fois Talky publié. Les joueurs qui rejoignent doivent alors le télécharger.
- Sans le Workshop, laissez Talky hors de `WorkshopItems` et copiez le dossier `Talky` du zip dans le dossier `Zomboid\mods` du serveur et de chaque joueur. Toutes les copies doivent être de la même version.
- Le jeu 42.21 lit `Mods=\Talky` comme `Mods=Talky`.

**Partie hébergée.** Dans le menu principal : **Héberger** > **Modifier les réglages...**, sélectionnez les réglages, puis **Modifier les réglages sélectionnés**. Sur la page **Mods**, ajoutez Talky (« Ajouter un mod installé à la liste »). Avec la version du Workshop, ajoutez-le aussi sur la page **Workshop Steam**. La page **Talky** de ces mêmes réglages contient les options ci-dessous (si elle manque, activez Talky dans le menu **Mods** du menu principal et rouvrez les réglages).

### Lancer le bridge à côté du serveur

**Linux (serveur dédié).**

1. Installez Node.js 18 ou plus.
2. Décompressez le zip dans un dossier du compte qui lance le serveur, par exemple `~/talky`.
3. Avec ce compte : `sh ~/talky/start-bridge.sh`. Il lance le bridge en mode serveur ; au premier lancement, il crée `bridge/config.json` avec `"mode": "server"`.
4. Ouvrez le port TCP 7420 vers internet : le pare-feu de la machine (`sudo ufw allow 7420/tcp`, par exemple) et celui de l'hébergeur, s'il y en a un.
5. Pour lancer le bridge au démarrage de la machine : `talky-bridge.service` du zip est un exemple d'unité systemd (mode d'emploi à l'intérieur).

**Windows (serveur dédié).** Dans un terminal ouvert dans le dossier de Talky : `start-bridge.cmd server` (ou un raccourci vers `start-bridge.cmd` avec l'argument `server`). Ouvrez le port dans un PowerShell administrateur : `New-NetFirewallRule -DisplayName "Talky bridge" -Direction Inbound -Protocol TCP -LocalPort 7420 -Action Allow`.

**Partie hébergée.** L'hôte lance `start-bridge.cmd server` sur son PC : le serveur d'une partie hébergée tourne sur le même PC, avec le même dossier `Zomboid\Lua`. Redirigez le port TCP 7420 de la box vers ce PC. Sans adresse publique, un tunnel cloudflared marche aussi (`cloudflared tunnel --url http://127.0.0.1:7420`) : son adresse `https://` est alors l'adresse publique du bridge.

Le bridge doit utiliser le dossier `Zomboid/Lua` du serveur : lancez-le avec le compte qui lance le serveur. Pour un serveur lancé avec `-cachedir=<dossier>`, mettez `zomboidLuaDir` à `<dossier>/Lua` dans `bridge/config.json`. À son démarrage, la fenêtre du bridge affiche `listening on http://0.0.0.0:7420 (server mode)`, le nombre de streamers et l'adresse publique. La console du serveur affiche `[Talky] server ready (Talky 0.5.0)`, puis `inbox ready, last seq = 0 (server)` (`Zomboid\server-console.txt`, ou `coop-console.txt` pour une partie hébergée).

### Ajouter un streamer (admins)

1. Appuyez sur **F8**, page **Webhooks**, onglet **Streamers**. La page est réservée aux admins : les rôles qui ont la capacité **CreateHorde** (admin et modérateur par défaut). Le serveur le vérifie à chaque demande.
2. **Adresse publique du bridge** : `http://<IP publique du serveur>:7420`, puis **Enregistrer**. Une adresse tapée sans `http://` le reçoit, avec le port du bridge (`203.0.113.5` devient `http://203.0.113.5:7420`). `publicUrl` dans `bridge/config.json` la règle aussi.
3. Tapez le nom d'utilisateur du streamer en bas à gauche, puis **+ Ajouter un streamer**. Une seconde plus tard, le bridge a tiré son jeton et le streamer apparaît dans la liste.
4. Choisissez le streamer. La page affiche les deux valeurs de son widget, le jeton masqué (**Afficher le jeton** l'affiche). **Copier l'URL et le jeton** met les deux dans le presse-papiers, une par ligne : envoyez-les au streamer en privé, jamais à l'écran.
5. **Nouveau jeton** : l'ancien jeton s'arrête tout de suite, le streamer colle le nouveau dans le widget. **Retirer** : son jeton s'arrête, et ses jobs en attente ou en cours sont abandonnés.

Le nom d'utilisateur est le nom du compte sur le serveur (seules les lettres de A à Z ignorent la casse, comme pour les comptes du jeu). Un streamer peut être ajouté avant sa première connexion : ses jobs attendent tant qu'il est hors ligne.

Partie hébergée : le compte de l'hôte démarre avec le rôle par défaut, l'hôte n'est donc pas admin au départ. F8 > Statut et F8 > Webhooks affichent alors **M'autoriser (hôte)** : le bouton envoie `/setaccesslevel "<votre nom d'utilisateur>" admin` au serveur, qui accepte cette commande de l'hôte de la partie. Quelques secondes plus tard, la fenêtre affiche les pages des admins.

### Ce que fait le streamer

1. Rejoindre le serveur (le mod vient avec la liste du serveur).
2. Dans son widget LibertyTalk : **Adresse publique du pont Talky** = l'adresse donnée par l'admin, **Jeton du pont** = son jeton. **Enregistrer**, puis **Activer** (voir [Brancher LibertyTalk](#brancher-libertytalk--le-widget--project-zomboid--talky-)).
3. F8 > Statut affiche `Vous êtes streamer ici : les événements de votre live se produisent autour de votre personnage.`

### Ports et sécurité

- Le bridge écoute sur le port TCP 7420 (`port` de `bridge/config.json`), sur toutes les adresses (`host` vide ou `0.0.0.0`). Seul ce port est nécessaire ; le serveur du jeu garde ses propres ports.
- **HTTP en clair.** Entre LibertyTalk et le bridge, le jeton du streamer circule en clair (en-tête `X-Bridge-Token`) : quelqu'un qui peut lire ce trafic pourrait le réutiliser jusqu'à ce que l'admin en tire un nouveau. Pour du https, placez un proxy inverse avec un certificat devant le bridge (Caddy, nginx...), mettez `"host": "127.0.0.1"` dans `bridge/config.json` pour que le bridge ne réponde qu'au proxy, et donnez l'adresse `https://` du proxy comme adresse publique.
- Le jeton du bridge (`token` de `bridge/config.json`) sert à l'admin, sur la machine du serveur (`node bridge.js fire <workflow> streamer=<nom d'utilisateur>`, `/health`). Les streamers n'en ont jamais besoin, et `/hooks/<id>` le refuse en mode serveur.
- Les jetons des streamers restent sur la machine du serveur : `bridge/streamers.json` (la copie à laquelle le bridge se fie), et `Zomboid/Lua/talky_streamers.json`, que le code du serveur lit pour les montrer aux admins. Ils ne partent que vers le jeu d'un admin qui ouvre l'onglet Streamers. Tous les mods de la liste du serveur peuvent lire le dossier `Zomboid/Lua` du serveur : n'installez sur un serveur que des mods de confiance. En partie hébergée, le jeu de l'hôte partage ce dossier.
- Le bridge ferme les connexions lentes (10 s pour les en-têtes, 15 s pour une requête), garde 64 connexions au plus et refuse les corps de plus de 64 Ko. Sans jeton valide, tous les identifiants de webhook répondent 401.

### Qui peut faire quoi

- **Les streamers de F8 > Webhooks** reçoivent les effets de leur propre live, autour de leur propre personnage. Le bridge n'écrit un job que pour un jeton connu, et le serveur n'exécute un job que pour un streamer de sa liste.
- **Les admins** (capacité CreateHorde, admin et modérateur par défaut) gèrent les streamers, modifient la configuration du serveur, et lancent **Tester maintenant**, qui exécute le workflow autour de leur propre personnage, streamer ou non.
- Le serveur vérifie la capacité à chaque commande, ne se fie jamais à un nom envoyé par un client (le joueur est celui de la connexion), et vérifie de nouveau chaque seconde que le propriétaire de chaque job est toujours streamer : un streamer retiré en cours de partie perd ses jobs en attente et en cours (`job_rejected` avec `not_streamer`).
- En solo, chaque job s'exécute, et les options bac à sable de Talky ne s'appliquent pas : les plafonds sont ceux de F8 > Réglages.

### Options du serveur (Options bac à sable > Talky)

Où les régler :

- partie hébergée : la page **Talky** des réglages (voir plus haut) ;
- serveur dédié : `Zomboid\Server\<nom du serveur>_SandboxVars.lua`, dans la table `Talky`. Arrêtez le serveur avant de le modifier :
  ```lua
  Talky = {
      MaxZombiesPerAction = 30,
      AllowFire = false,
      -- ...
  },
  ```
- en cours de partie, pour un joueur qui a le rôle admin : **Panneau admin** > **Options bac à sable** > **Talky**.

Un monde créé avant la 0.4.0 n'a pas d'options Talky : les valeurs par défaut s'appliquent jusqu'à ce que vous les régliez. Talky relit les valeurs chaque seconde.

| Option (en jeu) | Nom `Talky.` | Défaut | Plage | Effet |
|---|---|---|---|---|
| Zombies max par action | `MaxZombiesPerAction` | 30 | 1-300 | Une étape `spawn_zombie` ou `horde`. |
| Zombies max par job | `MaxZombiesPerJob` | 60 | 1-500 | Toutes les étapes d'un même job ensemble. |
| Zombies max par joueur sur 10 minutes | `MaxZombiesPer10Min` | 150 | 1-2000 | Les jobs d'un même streamer, sur les 10 dernières minutes. |
| Zombies max sur 10 minutes (tous les joueurs) | `MaxZombiesPer10MinServer` | 400 | 1-5000 | Tous les streamers ensemble. |
| Distance d'apparition max (cases) | `MaxSpawnDistance` | 40 | 5-150 | Distance au streamer. |
| Étapes max par job | `MaxStepsPerJob` | 100 | 10-500 | Les étapes au-delà sont ignorées ; la console du serveur indique combien. |
| Jobs en attente max par joueur | `MaxQueuedJobs` | 10 | 1-50 | Au-delà, les jobs suivants de ce streamer restent dans l'inbox du bridge et sont relus une seconde plus tard. |
| Jobs en cours en même temps max par joueur | `MaxActiveJobs` | 4 | 1-20 | Un job garde sa place pendant ses étapes `wait`. |
| Jobs max par minute par joueur | `MaxJobsPerMinute` | 30 | 1-120 | Au-delà, les jobs suivants de ce streamer restent dans l'inbox jusqu'à la fin de la minute, ou jusqu'à la fin de leur durée de vie. |
| Zombies et hordes | `AllowZombies` | activé | | `spawn_zombie`, `horde`. |
| Objets | `AllowItems` | activé | | `give_item` (100 objets par action au plus). |
| Objets max par joueur sur 10 minutes | `MaxItemsPer10Min` | 300 | 1-5000 | |
| Objets interdits | `ItemDenylist` | vide | texte | Types complets d'objets séparés par des virgules, par exemple `Base.Katana, Base.Shotgun`. |
| Véhicules | `AllowVehicles` | activé | | `vehicle`, dehors, seulement quand le streamer est au rez-de-chaussée. |
| Véhicules max par joueur sur 10 minutes | `MaxVehiclesPer10Min` | 2 | 1-20 | Chaque véhicule reste dans la sauvegarde. |
| XP | `AllowXp` | activé | | `xp` (1000 XP par action au plus, compétences seulement : pas les catégories comme `Combat`). |
| XP max par joueur sur 10 minutes | `MaxXpPer10Min` | 5000 | 1-100000 | |
| Soin et stats | `AllowPlayerEffects` | activé | | `heal`, `stat`, sur le personnage du streamer lui-même. |
| Météo et tonnerre | `AllowWeather` | activé | | `weather`, `thunder`. La même météo pour tous les joueurs, 12 heures de jeu par action au plus. |
| Délai entre deux météos (minutes) | `WeatherCooldownMinutes` | 15 | 0-240 | Pour tout le serveur. |
| Délai entre deux tonnerres (secondes) | `ThunderCooldownSeconds` | 30 | 0-3600 | Pour tout le serveur. |
| Heure du jour | `AllowTime` | activé | | `time`. La même heure pour tous les joueurs. |
| Délai entre deux changements d'heure (minutes) | `TimeCooldownMinutes` | 30 | 0-240 | Pour tout le serveur. |
| Feu | `AllowFire` | **désactivé** | | `fire`, et le paramètre `onFire` de `spawn_zombie` / `horde` (les zombies apparaissent sans feu quand c'est désactivé). Le feu se propage et peut atteindre les bases des autres joueurs. |
| Hélicoptère | `AllowHelicopter` | **désactivé** | | `helicopter`. Sur un serveur, l'hélicoptère va vers un joueur au hasard, pas vers le streamer. |
| Hélicoptère avec plusieurs joueurs connectés | `HelicopterAnyTarget` | désactivé | | Désactivé : `helicopter` ne s'exécute que lorsqu'un seul joueur est connecté. |
| Délai entre deux hélicoptères (minutes) | `HelicopterCooldownMinutes` | 60 | 0-600 | Pour tout le serveur. |
| Bruits et sons | `AllowSounds` | activé | | `noise`, `sound`. |
| Rayon de bruit max (cases) | `MaxNoiseRadius` | 80 | 1-300 | Un bruit attire tous les zombies dans ce rayon. |
| Distance des autres joueurs (cases) | `ProtectRadius` | 15 | 0-100 | Aucun zombie, feu ou véhicule de Talky n'apparaît aussi près d'un autre joueur connecté, ni dans un refuge où le streamer n'a pas accès. 0 désactive le contrôle de distance (celui des refuges reste). |
| Bannières | `BannerAudience` | Le streamer seulement | Le streamer seulement (1), Tous les joueurs, avec le nom du streamer (2) | Les bandeaux `notify` et le bandeau d'un zombie nommé qui meurt. Avec 2, les autres joueurs voient `[<streamer>] ` devant le texte ; au-delà de 6 bandeaux par minute et par streamer ou de 20 par minute en tout (bandeaux `notify` et morts de zombies nommés comptés ensemble), les suivants ne vont qu'au streamer. |
| Actions d'autres mods | `AllowCustomActions` | désactivé | | Les actions que d'autres mods ajoutent avec `Talky_Actions.register` en les marquant `network = true`. |

Les interrupteurs de catégorie renvoient le code `disabled` ; les budgets renvoient `budget` et les délais `cooldown` (voir [Événements renvoyés par le jeu](#événements-renvoyés-par-le-jeu)).

Limites fixes sur un serveur (pas des options) : 50 jobs en attente et 12 jobs en cours pour tous les joueurs ensemble ; 10 zombies créés par tick pour tout le serveur (un groupe plus grand apparaît sur les ticks suivants) ; 100 objets et 1000 XP par action ; 12 heures de jeu de météo par action ; 900 secondes d'étapes `wait` par job ; 10 étapes `fire` par streamer et 20 pour tout le serveur sur 10 minutes ; 60 étapes `noise` et `sound` par streamer sur 10 minutes (au-delà de ces budgets : `action_failed` avec `budget`) ; 12 lignes `say` par minute et par streamer et 60 pour tout le serveur, au-delà desquelles la ligne s'affiche encore au-dessus du personnage mais ne va pas dans le chat ; 128 zombies nommés sur le serveur, 32 par streamer ; 5 commandes par seconde par joueur ; 200 streamers. En solo, `fire`, `noise`, `sound` et `say` n'ont pas de budget.

Un job qui n'a pas démarré à la fin de sa durée de vie est abandonné, en solo aussi : la durée de vie est `jobTtlSeconds` du bridge, et jamais plus de 15 minutes après la création du job par le bridge.

### Jobs refusés et retardés

- **Refusés définitivement** (`not_streamer`, `disabled`, `unknown_action`, `invalid`) : le serveur retire le job de l'inbox (ack) et écrit `job_rejected {seq, workflow, reason, streamer}`. La fenêtre du bridge affiche la raison et ce qu'il faut faire, et F8 > Statut (admins) la montre. `not_streamer` : le job ne nomme aucun streamer du serveur (retiré dans F8 > Webhooks, ou un bridge en mode solo à côté du serveur).
- **Retardés** (la file d'attente du streamer est pleine, ou trop de jobs dans la dernière minute) : le job reste dans l'inbox et le serveur le relit, la seconde suivante ou à la fin de la minute. Les jobs suivants du même streamer attendent aussi, leur ordre est donc gardé ; ceux des autres streamers continuent.
- **Une étape refusée** (une action désactivée, un délai, un budget épuisé, aucune case libre) : les autres étapes s'exécutent, et le bridge reçoit `action_failed` avec le code. Un job dont toutes les étapes sont refusées est refusé définitivement, avec la raison de la première étape.
- **Expirés** : un job plus vieux que sa durée de vie quand le serveur le lit est pris sans s'exécuter ; un job qui l'a dépassée dans la file du serveur, ou dont le streamer est resté 15 minutes hors ligne, donne `job_expired {seq, workflow, streamer}`.

### Limites en multijoueur

- La machine du serveur doit être joignable depuis internet sur le port du bridge, ou par un proxy inverse ou un tunnel. Un serveur loué où vous ne pouvez pas lancer Node.js ne peut pas faire tourner le bridge.
- La météo et l'heure sont les mêmes pour tous les joueurs. Leurs délais comptent pour tout le serveur.
- Sur un serveur, `testHelicopter()` choisit un joueur connecté au hasard : l'hélicoptère est désactivé par défaut et, une fois activé, ne s'exécute que lorsqu'un seul joueur est connecté, sauf si **Hélicoptère avec plusieurs joueurs connectés** est activé (sinon `action_failed` avec `helicopter_random_target`).
- Sur un serveur, une tempête démarre tout de suite pour tous les joueurs ; un blizzard ou une tempête tropicale atteint les autres joueurs à la prochaine mise à jour du climat du serveur, jusqu'à 10 minutes de jeu plus tard. Un changement d'heure atteint les joueurs en une dizaine de secondes.
- Les noms au-dessus des zombies durent tant que le zombie reste dans la partie : un zombie qui disparaît loin des joueurs, un zombie que le jeu réutilise, un redémarrage du serveur ou 30 minutes effacent le nom. Tous les joueurs voient les noms (souvent des pseudos de viewers). Au-delà de 32 zombies nommés par streamer, ou de 128 en tout, les plus anciens perdent leur nom.
- `zombie_killed` est écrit une fois par zombie, pour le streamer dont le job l'a fait apparaître, connecté ou non. `byPlayer` vaut `true` quand ce streamer l'a tué.
- `heal` s'exécute dans le jeu du streamer (la santé appartient au jeu du joueur en multijoueur).
- **Distance des autres joueurs** peut laisser une apparition, un feu ou un véhicule sans case libre : `action_failed` avec `no_square`.
- Les jobs d'un streamer hors ligne ou mort, ou d'un serveur en pause, attendent ; les étapes `wait` continuent de compter en temps réel. Après 15 minutes hors ligne, les jobs de ce streamer sont abandonnés (`job_expired`).
- Le serveur et chaque client font tourner la même version de Talky : le jeu ne laisse rejoindre un serveur qu'avec les mods du serveur.
- Les actions que d'autres mods ajoutent avec `Talky_Actions.register` ne s'exécutent sur un serveur qu'avec `network = true` et l'option **Actions d'autres mods**.

### À vérifier en partie réelle

La version 0.5.0 a été testée avec une API du jeu simulée (le Lua tourne dans Kahlua avec de faux objets du jeu, un état Lua par processus du jeu : une partie solo, un serveur dédié avec plusieurs clients, une partie hébergée) et avec de vrais bridges lancés par les tests. Pas encore vérifié en partie réelle :

- le code du serveur qui lit et écrit le dossier `Zomboid/Lua` d'un serveur dédié (`getFileReader` / `getFileWriter` sur le serveur), d'un serveur lancé avec `-cachedir`, et du serveur d'une partie hébergée ;
- `player_died` lu sur le serveur (`isDead`, `getHoursSurvived` et `getZombieKills` du joueur côté serveur), et `getServerName()` de `game_started` sur un serveur ;
- la fenêtre F8 d'un admin sur un vrai serveur : la configuration chargée et enregistrée, le presse-papiers sur deux lignes ;
- LibertyTalk qui appelle une adresse `http://<IP>:<port>` (il faut la mise à jour de LibertyTalk qui l'accepte) ;
- toujours à vérifier depuis la 0.4.0 : `heal` (dans le jeu du streamer) et `stat` (modifiée sur le serveur, puis envoyée au joueur) ; les noms au-dessus des zombies en multijoueur ; la cible de l'hélicoptère ; le délai d'un blizzard ou d'un changement d'heure sur un serveur ; le bouton **M'autoriser (hôte)** ; `say` par le chat ; les objets au sol ; la vérification du type de véhicule ; les contrôles de rôle et de refuge du code serveur ; la valeur par défaut vide de **Objets interdits**.

## Écrire des workflows à la main

La fenêtre F8 couvre tout ce qui suit. Cette section sert si vous préférez modifier `Zomboid\Lua\talky_config.json` directement (en multijoueur, celui du serveur).

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

En mode serveur, les cooldowns comptent par streamer : un `!zombie` sur un stream ne bloque pas les autres.

### Gabarits `{{ }}`

- `{{user}}`, `{{bits}}`, `{{payload.champ.sous_champ}}`, `{{query.param}}`. `{{user}}` est le champ `user` quand l'appel en contient un, sinon le premier champ trouvé parmi `user_name`, `author_display_name`, `display_name`, `donor`, `chatter_name`, `actor_name`, `username`, `author_username`, `user_login` et `name` : le même workflow fonctionne pour Twitch et YouTube. Quand aucun n'est rempli, c'est le pseudo des événements anonymes (F8 > Réglages).
- En mode serveur, `{{streamer}}` est le nom d'utilisateur du streamer pour qui le job s'exécute.
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
| `emit` | `event`, `data` (8 Ko au plus) : écrit un événement pour le bridge (ni `test_workflow`, ni `game_started`, ni `player_died`, ni `job_rejected`, ni `job_expired`, ni les demandes sur les streamers, que seul Talky écrit : `action_failed` avec `invalid`) |

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

En mode serveur, c'est le serveur qui les écrit, et chacun qui concerne un job ou un joueur porte aussi `streamer` : les workflows de `gameEvents` s'exécutent alors pour ce streamer.

| Événement | Données |
|---|---|
| `zombie_killed` | `name`, `byPlayer` (un zombie nommé meurt ; `byPlayer` vaut `true` quand le streamer l'a tué) |
| `player_died` | `hoursSurvived`, `zombieKills` (en mode serveur : un streamer meurt) |
| `game_started` | `mode` (`sp`, ou `server` quand un serveur démarre), `host`, `server` (nom du serveur, vide en solo). Sans streamer : en mode serveur, ses workflows n'exécutent que leurs étapes `http` et `log`. |
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

- **Jeton.** Chaque appel à `/hooks/<id>` et `/fire/<workflow>` exige un jeton, dans l'en-tête `X-Bridge-Token` ou dans `?token=`. La comparaison se fait en temps constant. Sans jeton valide, tous les identifiants de webhook répondent 401 : impossible de les deviner. Solo : le jeton du bridge, ou pour un webhook listé dans `hookTokens` de `bridge\config.json` son propre jeton (il refuse alors le jeton du bridge) ; un `token` écrit pour un webhook dans `talky_config.json` ne compte pas (la fenêtre du bridge le signale). Mode serveur : `/hooks/<id>` ne prend que le jeton d'un streamer, et ce jeton désigne le streamer ; `/fire/<workflow>` prend le jeton d'un streamer, ou le jeton du bridge avec `streamer=<nom d'utilisateur>`.
- **Réseau.** Solo : le bridge n'écoute que sur `127.0.0.1` (`host` vide dans `config.json`) ; c'est le tunnel qui le rend joignable depuis internet. Mode serveur : le bridge écoute sur toutes les adresses (`0.0.0.0`), en clair : voir [Ports et sécurité](#ports-et-sécurité).
- **Appels sortants.** Une étape `http` ne joint que les hôtes listés dans `httpAllowedHosts` de `bridge\config.json` (par défaut `["*.liberty-talk.com"]` ; `*.exemple.com` couvre tous les sous-domaines de exemple.com mais pas exemple.com lui-même ; `"*"` autorise tous les hôtes et supprime cette protection). Toute autre étape est refusée et signalée dans la fenêtre du bridge et sur la page Statut de F8. Les redirections ne sont pas suivies. La raison : `talky_config.json` se trouve dans `Zomboid\Lua`, un dossier où n'importe quel autre mod peut écrire. Sans cette liste, un mod pourrait ajouter une étape `http` et se servir du bridge pour envoyer des données n'importe où, sur internet ou sur votre réseau local. La liste elle-même reste dans `bridge\config.json`, hors de portée des mods du jeu.
- **Les autres mods.** Tout mod qui tourne dans le jeu peut lire `talky_status.json` et `talky_config.json`, écrire `talky_config.json` et l'outbox. En solo, aucun jeton, aucun secret http et aucune URL complète de webhook ne va donc dans ces fichiers : les jetons et les cibles restent dans `bridge\config.json`, `talky_status.json` ne liste que les identifiants des webhooks qui ont un jeton dédié, et les boutons **Copier la commande** copient une commande. Les mods du jeu peuvent aussi lire le presse-papiers : après `node bridge\bridge.js url`, collez l'URL, puis copiez autre chose. Un mod peut encore ajouter un workflow qui appelle le webhook entrant de n'importe quel compte LibertyTalk (un hôte de `httpAllowedHosts`), ou lancer un workflow par un événement du jeu ou par **Tester maintenant**. Sur un serveur, les mods de la liste du serveur peuvent aussi lire `talky_streamers.json` (les jetons des streamers) et écrire l'outbox (les demandes des admins sur les streamers) : n'installez sur un serveur que des mods de confiance. Une étape `emit` ne peut jamais écrire ces demandes.
- **Tester maintenant.** Le bridge écrit un code de test aléatoire dans `talky_status.json` à chaque démarrage, et n'exécute un événement `test_workflow` que s'il porte ce code. En multijoueur, c'est le serveur qui écrit l'événement pour un admin, avec le code lu dans `talky_status.json` du serveur.
- **Multijoueur.** Aucun job ne traverse le réseau : le serveur les lit dans les fichiers du bridge. Un client ne reçoit que les effets de son propre jeu (bandeaux, `say`, `halo`, `heal`), les noms au-dessus des zombies et, pour un admin, ce dont la fenêtre F8 a besoin. Le serveur vérifie la capacité du joueur à chaque commande d'admin, ne garde que les paramètres connus de chaque étape, avec leur type et leurs bornes (des nombres comme `NaN` ou `1e308` reprennent la valeur par défaut, les textes sont coupés, les couleurs doivent être `#rrggbb`), et ne se fie jamais à un nom envoyé par un client : le joueur est celui de la connexion. Chaque joueur peut envoyer 5 commandes Talky par seconde.
- **Plafonds.** `wait` 600 s, textes de `notify` / `say` / `halo` 200 caractères, bandeaux 60 s, noms de zombies 40 caractères, `repeat` 100 tours, 500 étapes de jeu et 20 étapes `http` / `log` par job, 10 000 étapes et tours de boucle parcourus par job (au-delà, la suite du workflow est ignorée et la fenêtre du bridge le signale), 200 jobs en attente dans le jeu en solo, corps d'un appel webhook 64 Ko. Sur un serveur, les options bac à sable et les limites fixes de [Multijoueur](#multijoueur) s'ajoutent.
- **En stream.** La fenêtre F8 n'affiche jamais de jeton, sauf l'onglet Streamers d'un admin après **Afficher le jeton**. `node bridge\bridge.js url` affiche l'URL avec le jeton masqué, sauf avec `--show`. La fenêtre du bridge affiche `~` à la place de votre dossier utilisateur, messages d'erreur compris, et n'affiche jamais de jeton. À son premier lancement, le bridge copie son nouveau jeton dans le presse-papiers sans l'afficher.
- **Secrets sur le disque.** `bridge\config.json`, `bridge\streamers.json` et `bridge\bridge-state.json` sont dans `.gitignore` et jamais dans le zip de release. L'élément du Steam Workshop ne contient que le mod.

## Limites

- Le multijoueur a ses propres limites : voir [Limites en multijoueur](#limites-en-multijoueur) et [À vérifier en partie réelle](#à-vérifier-en-partie-réelle).
- L'adresse d'un tunnel rapide change à chaque lancement : mettez à jour les réglages du widget et l'URL publique de F8.
- La version 0.5.0 a été testée avec une API du jeu simulée : le Lua tourne dans Kahlua (la machine Lua du jeu) avec de faux objets du jeu. Toujours à vérifier en partie réelle depuis la 0.3.0 : la position des noms au-dessus des têtes, l'aggro des zombies (`spotted` / `pathToCharacter`), `testHelicopter()` hors mode debug, les numéros de stades météo (repris du menu debug B42), le raccourci personnalisé, et `byPlayer`.
- Le mode polling (plus bas) n'a pas été testé sur une instance LibertyTalk réelle, et n'existe pas en mode serveur.

## Dépannage

| Symptôme | Cause et solution |
|---|---|
| F8 affiche « Bridge hors ligne » | Le bridge n'est pas lancé, ou `zomboidLuaDir` dans `config.json` pointe vers le mauvais dossier (jeu lancé avec `-cachedir`). |
| `No config at ... Start the bridge once (start-bridge.cmd, or start-bridge.sh on Linux)`, après `node bridge\bridge.js fire ...` | `bridge\config.json` n'existe pas encore. Lancez une première fois le bridge : il crée le fichier. |
| `Cannot create ...\bridge\config.json` | Vous ne pouvez pas écrire dans le dossier de Talky (sous `C:\Program Files`, par exemple). Déplacez-le dans `Documents\Talky` et relancez `start-bridge.cmd`. |
| `Set a long random "token" in config.json` | Le jeton est vide ou vaut encore `change-me...` (un `config.json` copié à la main depuis `config.example.json`). Mettez-y une longue chaîne aléatoire, ou supprimez `config.json` et relancez le bridge : il en crée un nouveau. |
| `warning: cloudflared is not in the PATH` | Solo : installez-le avec `winget install --id Cloudflare.cloudflared`, puis ouvrez une nouvelle fenêtre. |
| `warning: Talky is installed twice` | Supprimez `%USERPROFILE%\Zomboid\mods\Talky` : la version du Workshop suffit. |
| `warning: The bridge folder ... is inside ...\Zomboid\mods` | Sortez tout le dossier de Talky de `Zomboid\mods`, `bridge\config.json` compris (vers `Documents\Talky`, par exemple), puis lancez `start-bridge.cmd` depuis ce nouvel emplacement. Le jeton ne change pas. |
| `'node' n'est pas reconnu`, ou `Node.js was not found on this PC.` dans la fenêtre de `start-bridge.cmd` | Installez Node.js 18 ou plus, puis ouvrez une nouvelle fenêtre. |
| `Port 7420 is already used` | Un autre programme (ou un second bridge) utilise le port. Changez `port` dans `config.json`, et dans la commande cloudflared ou l'adresse publique du bridge. |
| LibertyTalk refuse l'URL | Solo : l'URL est locale (`http://127.0.0.1...`) : collez l'adresse `https://...trycloudflare.com`. Serveur : une adresse `http://` demande la mise à jour de LibertyTalk qui l'accepte ; en attendant, une adresse `https://` (proxy inverse). |
| `401 bad token` | Mauvais jeton, ou webhook à jeton dédié appelé avec le jeton global. Le bridge vérifie le jeton en premier : sans le bon jeton, même un identifiant de webhook inconnu répond 401. Mode serveur : le jeton du bridge est refusé sur `/hooks` : utilisez le jeton d'un streamer ; un streamer dont le jeton a été renouvelé ou qui a été retiré reçoit 401. |
| `404 unknown webhook` | L'identifiant manque dans `talky_config.json`. Après le premier lancement, `config.json` n'est plus lu pour les webhooks, sauf si `talky_config.json` n'a ni webhook ni workflow. |
| `413 body too large` | Corps de plus de 64 Ko. |
| Le bridge affiche `job #N` mais rien ne se passe | Jeu en pause, joueur mort, retour au menu principal, job plus ancien que `jobTtlSeconds`, ou 8 jobs déjà en cours (longues étapes `wait`). Sur un serveur, aussi : le streamer est hors ligne, les limites du serveur (voir les lignes ci-dessous), ou le serveur ne lit pas l'inbox (cherchez `inbox ready` dans sa console). |
| F8 > Statut : `Bridge du serveur : hors ligne.` | Lancez le bridge sur la machine du serveur (`start-bridge.sh`, `start-bridge.cmd server`), avec le compte du serveur, ou mettez `zomboidLuaDir` sur le dossier `Lua` du serveur. |
| F8 > Statut : `Le bridge du serveur tourne en mode solo` | Lancez-le avec `--server`, ou mettez `"mode": "server"` dans `bridge/config.json`. |
| F8 > Statut : `le code Talky du serveur ne répond pas` | Le serveur ne fait pas tourner Talky, ou son code Talky a échoué. Cherchez les lignes `[Talky]` et les erreurs Lua dans la console du serveur (`server-console.txt`, ou `coop-console.txt` pour une partie hébergée). |
| F8 > Webhooks : `Réservé aux admins de ce serveur` | Votre rôle n'a pas la capacité CreateHorde. L'hôte d'une partie clique sur **M'autoriser (hôte)**. |
| F8 > Webhooks : le streamer reste sur `le bridge tire le jeton...` | Le bridge du serveur ne tourne pas en mode serveur, ou n'utilise pas le dossier `Zomboid/Lua` du serveur. |
| La fenêtre du bridge affiche `refused by the server: not_streamer` | Le streamer a été retiré, ou le bridge tourne en mode solo à côté d'un serveur. |
| La fenêtre du bridge affiche `refused by the server: disabled` | Une action du job est désactivée dans les options bac à sable du serveur (**Zombies et hordes**, **Feu**, **Hélicoptère**...). |
| `action_failed` avec `cooldown` ou `budget` | Un délai du serveur (météo, tonnerre, heure, hélicoptère) ou un budget par 10 minutes ou par job : voir [Options du serveur](#options-du-serveur-options-bac-à-sable--talky). |
| `action_failed` avec `helicopter_random_target` | Plusieurs joueurs sont connectés et **Hélicoptère avec plusieurs joueurs connectés** est désactivé. |
| `action_failed` avec `no_square` sur un serveur | Un autre joueur connecté dans la **Distance des autres joueurs**, un refuge où le streamer n'a pas accès, ou aucune case libre autour du streamer. |
| Statut affiche « ignoré : cooldown / condition non remplie / tirage de chance perdu / workflow désactivé » | Le workflow a refusé l'événement : voyez ses réglages sur la page Workflows. |
| Statut affiche « ignoré : pas de code de test (mettez le mod à jour) » ou « ignoré : code de test différent, relancez Tester maintenant » | Le bridge n'a lancé aucun test. Premier message : le test ne portait pas de code de test, le mod est donc antérieur à 0.4.0 : mettez-le à jour. Second message : le bridge a redémarré après que la fenêtre F8 a lu son code de test : cliquez de nouveau sur **Tester maintenant**. |
| `http step refused: host "..." is not in httpAllowedHosts` | Ajoutez l'hôte à `httpAllowedHosts` dans `bridge\config.json` et relancez le bridge. |
| `http step refused: fill "httpTargets" > "lt_report" in bridge/config.json first` | La cible contient encore une valeur `PASTE_...` : mettez-y l'URL et le secret de votre webhook entrant, puis relancez le bridge. |
| `warning: "jobTtlSeconds" in config.json is ...: 900 is used.` | Le jeu et le serveur abandonnent un job 15 minutes après sa création par le bridge : mettez `jobTtlSeconds` à 900 ou moins. |
| `warning: server mode, but the bridge listens on 127.0.0.1 only` | Mettez `host` à `""` dans `bridge/config.json`, sauf si un proxy inverse de la machine transmet les appels au bridge. |
| Plus rien ne marche après un redémarrage | L'adresse du tunnel a changé : mettez à jour le widget et l'URL publique de F8. |
| Le mod n'apparaît pas dans la liste | Sans le Workshop, le jeu a besoin de `%USERPROFILE%\Zomboid\mods\Talky\42\mod.info` : copiez le dossier `Talky` du zip, pas le dossier qui le contient. Vérifiez que Talky n'est pas installé deux fois (Workshop et `Zomboid\mods`). |

Journaux : le jeu écrit des lignes `[Talky]` dans `%USERPROFILE%\Zomboid\console.txt`, un serveur dédié dans `Zomboid\server-console.txt`, le serveur d'une partie hébergée dans `Zomboid\coop-console.txt`. `http://127.0.0.1:7420/health?token=<jeton du bridge>` renvoie le mode, le nombre de jobs en attente, le dernier job acquitté, les jobs acquittés au-delà et les 50 derniers événements.

Fichiers d'échange dans `Zomboid\Lua\` du jeu (solo) ou du serveur (mode serveur) : `talky_inbox.jsonl` (jobs ; en mode serveur, chacun avec `target`), `talky_ack.txt` (`S`, ou `S s1 s2 ...` : tous les jobs jusqu'à `S` sont pris, et `s1`, `s2`... aussi), `talky_outbox.txt` (événements du jeu, et demandes des admins sur les streamers), `talky_status.json` (battement du bridge, avec le mode, le code de test et les identifiants des webhooks qui ont un jeton dédié, jamais un jeton), `talky_config.json` (la configuration modifiée par la fenêtre F8) et, en mode serveur, `talky_streamers.json` (les streamers et leurs jetons, écrit par le bridge). En multijoueur, le jeu d'un joueur n'écrit aucun fichier : ses réglages d'affichage viennent du `talky_config.json` du serveur.

## Référence de `bridge\config.json`

| Clé | Défaut | Rôle |
|---|---|---|
| `mode` | `solo` | `solo` : le bridge du PC d'un joueur. `server` : à côté d'un serveur, avec un jeton par streamer. `--server` / `--solo` sur la ligne de commande l'emportent le temps d'un lancement ; `start-bridge.cmd server` et `start-bridge.sh` passent `--server`. |
| `port` | `7420` | Port du bridge. |
| `host` | vide | Adresse d'écoute. Vide : `127.0.0.1` en mode solo (le tunnel se connecte en local), `0.0.0.0` en mode serveur. `127.0.0.1` en mode serveur pour un proxy inverse sur la même machine. |
| `publicUrl` | vide | Mode serveur : l'adresse donnée aux streamers (`http://<IP publique>:<port>`). Celle réglée dans F8 > Webhooks (enregistrée dans `talky_config.json`) l'emporte. |
| `token` | aléatoire | Jeton du bridge, tiré au sort quand le bridge crée `config.json`. Solo : le jeton des appels webhook. Mode serveur : `/fire` et `/health` seulement. `node bridge\bridge.js new-token` en tire un nouveau. |
| `hookTokens` | `{}` | Solo : `{ "<identifiant du webhook>": "<16 caractères ou plus>" }`, un webhook avec son propre jeton, qui refuse alors `token`. |
| `zomboidLuaDir` | `%USERPROFILE%/Zomboid/Lua` | Dossier partagé avec le mod : celui du jeu, ou du serveur en mode serveur (`<dossier>/Lua` pour un serveur lancé avec `-cachedir=<dossier>`). |
| `jobTtlSeconds` | `900` | Un job plus ancien est ignoré par le jeu (900 au plus : une valeur plus grande est ramenée à 900, avec un avertissement au démarrage). |
| `httpAllowedHosts` | `["*.liberty-talk.com"]` | Hôtes que les étapes `http` peuvent appeler. |
| `httpTargets` | `lt_report` avec des valeurs à remplacer | `{ "<nom>": { "url", "headers", "hmacSecret", "hmacHeader", "method" } }` : l'adresse et les secrets d'une étape `http` qui indique `"target": "<nom>"`. Seule `url` est obligatoire. |
| `settings` | `{"language": "en", "anonymousName": ""}`, `fr` quand le format régional du système est le français | Copiés dans `talky_config.json` au premier lancement, puis modifiés dans F8 > Réglages. |
| `webhooks`, `workflows`, `gameEvents` | exemples | Copiés dans `talky_config.json` au premier lancement. |
| `poll` | désactivé | Source expérimentale sans adresse publique, voir ci-dessous (solo seulement). |

Les streamers du mode serveur sont dans `bridge\streamers.json`, à côté de `config.json` : gardez-le avec `config.json` quand vous déplacez ou mettez à jour le bridge (sans lui, chaque streamer a besoin d'un nouveau jeton).

**Mode polling (expérimental, solo).** Au lieu de recevoir des webhooks, le bridge lit le flux d'activité LibertyTalk toutes les `intervalSeconds` (10 s, 5 s au minimum) avec un jeton d'API : `"url": "https://<tenant>.api.liberty-talk.com/community/<community_id>/activity?per_page=50"`, `"apiToken"`, `"headers"` optionnel. `types` associe un type d'activité à un workflow : `follow`, `subscribe`, `subscribe_gift`, `cheer`, `raid`, `donation`, `superchat`, `member` (`resub`, `member_gift`, `charity`, `boost` et `first_message` existent aussi). Le bridge remplit `user_name` à partir de `actor_name`, et `bits` (cheer), `viewers` (raid) et `total` (abonnements offerts) à partir de `amount`. Les événements déjà présents dans le flux au démarrage du bridge ne sont pas rejoués.

## Développement

- Tests du bridge : `node bridge/test/run-tests.mjs` (ou `npm test` dans `bridge` ; Node 18 ou plus, sans dépendance). Ils lancent de vrais bridges, en mode solo et en mode serveur, sur des ports libres avec un dossier de jeu temporaire.
- Tests Lua : `& tools\test-lua.ps1` dans PowerShell, depuis le dossier de Talky (`-GameDir "<chemin de ProjectZomboid>"` quand le jeu n'est pas trouvé ; JDK 25 ou plus : les classes du jeu 42.21 sont des classes Java 25 ; `-Java "<chemin de java.exe>"` choisit un autre JDK). Ils compilent chaque fichier avec le Kahlua du jar du jeu, puis font tourner le mod avec de faux objets du jeu, un état Lua par processus du jeu : une partie solo, un serveur dédié avec plusieurs clients et une partie hébergée. Les messages entre processus sont copiés par le sérialiseur réseau du jeu lui-même. Couvert : chaque page de la fenêtre F8 en anglais et en français, pour un admin et pour un joueur, clés de traduction, options bac à sable, plafonds, la liste des streamers, l'acheminement des jobs vers leur streamer, les streamers hors ligne, acquittements, noms au-dessus des zombies, événements pour le bridge. Pour un serveur dédié installé seul, `-GameDir` peut être son dossier `java`.
- Dossier Steam Workshop : `tools\build-workshop.ps1` assemble `%USERPROFILE%\Zomboid\Workshop\Talky` (`-OutDir` pour l'assembler ailleurs), conserve l'`id=` Workshop après le premier envoi et refuse les types de fichiers que le Workshop rejette. Ensuite, dans le jeu : **Workshop > Create and update items**.
- Release : `tools\build-release.ps1` produit `dist\Talky-<version>.zip` (Windows et Linux) et `dist\SHA256SUMS.txt`. La version de `bridge\package.json` doit correspondre au `modversion` de `mod.info`.
- `mod\Talky\42\poster.png` et `packaging\workshop\preview.png` sont des images provisoires dessinées par `tools\make-placeholder-images.ps1`.
- Traductions : `mod\Talky\42\media\lua\shared\Translate\<LANGUE>\UI.json` (clés `UI_Talky_*`, les mêmes clés dans chaque langue), `Sandbox.json` (les options serveur de `media\sandbox-options.txt`, clés `Sandbox_Talky_*`) et `Mod.json` (nom et description du mod).
- Organisation du code : `media\lua\client` ne tourne que dans le jeu du joueur, `media\lua\server` sur le serveur et en solo, `media\lua\shared` partout. Les fichiers serveur ne chargent jamais un fichier `client` ; seul `server\Talky\Talky_Files.lua` ouvre des fichiers (ceux du bridge, dans `Zomboid\Lua`). `server\Talky\Talky_Inbox.lua` lit les jobs, `Talky_Streamers.lua` la liste des streamers, `Talky_Server.lua` répond aux clients, `Talky_ServerRunner.lua` exécute les jobs. `client\Talky\Talky_Remote.lua` est ce que la fenêtre F8 demande au serveur en multijoueur.

## Licence

MIT, voir [LICENSE](LICENSE). La licence couvre le code, pas les noms ni les logos LibertyTalk et Tech Liberty.

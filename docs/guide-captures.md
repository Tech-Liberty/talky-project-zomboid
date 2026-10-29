# Captures du guide « Project Zomboid × LibertyTalk : Talky »

Les encadrés « Capture à ajouter » ont été retirés du guide publié le 29/10/2026 (ils étaient visibles par les lecteurs).
Chaque capture prise devient un bloc `image` (fr et en) inséré après le bloc indiqué, dans l'éditeur `/mcp/guides` et dans
`saas/api/database/seeders/guides/project-zomboid-talky.json`.

## p1-start-bridge-shot

À insérer après le bloc `p1-start-bridge-keep-open`.

**FR.** Capture 1 : la fenêtre « Talky bridge » ouverte par `start-bridge.cmd`, au premier lancement d'un Talky décompressé dans `Documents\Talky`, sur un PC où cloudflared est installé. À voir : `created ~\Documents\Talky\bridge\config.json with a random token (language: fr)`, la ligne `the token is in your clipboard and in config.json, never shown here: ...`, `config loaded: 10 webhook(s), 14 workflow(s)`, `Talky bridge 0.5.0 listening on http://127.0.0.1:7420` et les dix lignes `webhook POST /hooks/...`, sans aucune ligne `warning:`. La ligne `created ~\Zomboid\Lua\talky_config.json from config.json (fr: 19 text(s) translated)` n'apparaît que si ce fichier n'existe pas encore : elle peut manquer sur un PC où Talky a déjà tourné. Pour refaire un premier lancement sur un tel PC, fermez la fenêtre du pont en cours et décompressez le zip dans un nouveau dossier, le temps de la capture. Rien à flouter : le jeton n'apparaît pas et le pont écrit `~` à la place de votre dossier utilisateur. La même capture sert aux deux versions du guide : seuls `(language: fr)` et `(fr: 19 text(s) translated)` dépendent du format régional de Windows.

**EN.** Screenshot 1: the "Talky bridge" window opened by `start-bridge.cmd`, on the first launch of a Talky extracted to `Documents\Talky`, on a PC where cloudflared is installed. To show: `created ~\Documents\Talky\bridge\config.json with a random token (language: fr)`, the `the token is in your clipboard and in config.json, never shown here: ...` line, `config loaded: 10 webhook(s), 14 workflow(s)`, `Talky bridge 0.5.0 listening on http://127.0.0.1:7420` and the ten `webhook POST /hooks/...` lines, without any `warning:` line. The `created ~\Zomboid\Lua\talky_config.json from config.json (fr: 19 text(s) translated)` line only shows when that file doesn't exist yet: it can be missing on a PC where Talky already ran. To get a first launch again on such a PC, close the running bridge window and extract the zip to a new folder, for the time of the shot. Nothing to blur: the token doesn't show and the bridge writes `~` instead of your user folder. The same shot serves both versions of the guide: only `(language: fr)` and `(fr: 19 text(s) translated)` depend on the regional format of Windows.

## p1-enable-mod-shot

À insérer après le bloc `p1-enable-mod-pages`.

**FR.** Capture 2 : en partie, le menu F8 ouvert sur la page **Statut**, pont lancé. À voir : la pastille verte « Bridge connecté » en bas à gauche, la ligne verte « Bridge connecté sur le port 7420 - 0 job(s) en attente (v0.5.0) », le champ « URL publique (tunnel Cloudflare) » et la liste des webhooks, dont les adresses se terminent par `?token=*****`. Ce menu n'affiche jamais le jeton.

**EN.** Screenshot 2: in game, the F8 menu open on the **Status** page, with the bridge running. To show: the green "Bridge connected" pill at the bottom left, the green "Bridge connected on port 7420 - 0 job(s) waiting (v0.5.0)" line, the "Public URL (Cloudflare tunnel)" field and the webhook list, whose addresses end with `?token=*****`. This menu never shows the token.

## p1-test-offline-menu-shot

À insérer après le bloc `p1-test-offline-result`.

**FR.** Capture 3 : le menu F8 sur la page **Workflows**, `new_follower` sélectionné à gauche. À voir : la case « Activé » cochée, la liste « Étapes (exécutées dans l'ordre, double-clic pour modifier) » avec ses trois étapes, le champ « Tester avec le pseudo » rempli avec `Bob` et le bouton **Tester maintenant**.

**EN.** Screenshot 3: the F8 menu on the **Workflows** page, `new_follower` selected on the left. To show: the ticked "Enabled" box, the "Steps (run in order, double-click to edit)" list with its three steps, the "Test with the name" field filled with `Bob` and the **Test now** button.

## p1-test-offline-shot

À insérer après le bloc `p1-test-offline-result`.

**FR.** Capture 4 : en jeu, partie non en pause, deux à trois secondes après **Tester maintenant**. À voir : le bandeau « Bob rejoint la horde ! » en haut de l'écran et, dans le même plan si possible, le zombie avec « Bob » écrit en violet au-dessus de la tête. Si les deux ne tiennent pas dans un seul plan, faites deux captures : le bandeau, puis le zombie nommé.

**EN.** Screenshot 4: in game, not paused, two to three seconds after **Test now**. To show: the "Bob joins the horde!" banner at the top of the screen and, in the same shot if possible, the zombie with "Bob" written in purple above its head. If both don't fit in one shot, take two: the banner, then the named zombie.

## p1-tunnel-shot

À insérer après le bloc `p1-tunnel-new-address`.

**FR.** Capture 5 : le terminal PowerShell où tourne `cloudflared tunnel --url http://127.0.0.1:7420`, quelques secondes après le lancement. À voir : le cadre qui contient l'adresse en `https://...trycloudflare.com`, encadrée ou surlignée. Floutez la partie aléatoire de l'adresse : le jeton refuse les appels, mais l'adresse permet d'en envoyer à votre pont.

**EN.** Screenshot 5: the PowerShell terminal running `cloudflared tunnel --url http://127.0.0.1:7420`, a few seconds after it starts. To show: the box holding the `https://...trycloudflare.com` address, outlined or highlighted. Blur the random part of the address: the token refuses the calls, but the address lets anyone send some to your bridge.

## p1-official-widget-listing-shot

À insérer après le bloc `p1-official-widget-fields`.

**FR.** Capture 6 : la fiche du widget dans la Marketplace du dashboard, avant l'installation, une communauté sélectionnée. À voir : le titre « Project Zomboid · Talky », les badges « Officiel » et « Gratuit », et dans la colonne de droite le bouton **Installer** avec la phrase « Le widget est ajouté à la communauté sélectionnée, désactivé. Vous remplissez ses réglages sur sa page, puis vous l'activez. ».

**EN.** Screenshot 6: the widget's page in the dashboard Marketplace, before installing, with a community selected. To show: the "Project Zomboid · Talky" title, the "Official" and "Free" badges, and in the right column the **Install** button with the sentence "The widget is added to the selected community, turned off. You fill in its settings on its page, then turn it on."

## p1-official-widget-shot

À insérer après le bloc `p1-official-widget-fields`.

**FR.** Capture 7 : la page du widget dans Widgets, portée **Global**, onglet **Configuration du widget**, section « Connexion au pont Talky » dépliée et remplie. À voir : « Adresse publique du pont Talky » avec une adresse en `trycloudflare.com`, « Jeton du pont » rempli, « Commande de chat (sans « ! ») » à `zombie`, et le bouton **Enregistrer**. Floutez la partie aléatoire de l'adresse, et le jeton entièrement s'il s'affiche en clair.

**EN.** Screenshot 7: the widget's page in Widgets, **Global** scope, **Widget configuration** tab, "Talky bridge connection" section open and filled in. To show: "Talky bridge public URL" with a `trycloudflare.com` address, "Bridge token" filled in, "Chat command (without "!")" set to `zombie`, and the **Save** button. Blur the random part of the address, and the whole token if it shows in clear.

## p1-official-widget-active-shot

À insérer après le bloc `p1-official-widget-fields`.

**FR.** Capture 8 : la même page juste après **Activer**. À voir : le bloc **Activation** avec « Actif sur Global. » et le bouton **Désactiver**, puis le bloc **Écoute** avec la puce de votre chaîne Twitch, et celle de YouTube si elle est connectée.

**EN.** Screenshot 8: the same page right after **Activate**. To show: the **Activation** block with "Active on Global." and the **Deactivate** button, then the **Listening to** block with your Twitch channel's chip, and the YouTube one if it's connected.

## p1-end-to-end-status-shot

À insérer après le bloc `p1-end-to-end-follow`.

**FR.** Capture 9 : le menu F8, page **Statut**, juste après un vrai follow. À voir : dans « Derniers événements reçus par le bridge », la ligne `hook:follow -> new_follower (Pseudo)` avec son heure. Floutez le pseudo s'il n'est pas le vôtre.

**EN.** Screenshot 9: the F8 menu, **Status** page, right after a real follow. To show: in "Latest events received by the bridge", the `hook:follow -> new_follower (Name)` line with its time. Blur the name if it isn't yours.

## p1-end-to-end-console-shot

À insérer après le bloc `p1-end-to-end-follow`.

**FR.** Capture 10 : l'onglet **Exécutions** de la page du widget après ce follow, « Charger le dernier run » cliqué. À voir : les étapes du run, du déclencheur « Nouveau follower » à « Appel webhook / API (arrière-plan) », marquées « Terminé », et la sortie de l'appel ouverte avec `webhook_response_status` à 200 et `webhook_response_ok` à `true`. Floutez l'adresse du tunnel ; le jeton doit apparaître masqué.

**EN.** Screenshot 10: the **Executions** tab of the widget's page after that follow, "Load last run" clicked. To show: the steps of the run, from the "New follower" trigger to "Webhook / API call (background)", marked "Completed", and the call's output open with `webhook_response_status` at 200 and `webhook_response_ok` at `true`. Blur the tunnel address; the token must show masked.

## p2-example-bits-shot

À insérer après le bloc `p2-example-bits-cap`.

**FR.** Capture 11 : en jeu, juste après **Tester maintenant** sur le workflow `bits` avec le pseudo `Bob`, partie non en pause. À voir : le bandeau « Bob envoie 5 zombie(s) ! » et, si possible dans le même plan, plusieurs zombies nommés « Bob » qui arrivent, un par seconde.

**EN.** Screenshot 11: in game, right after **Test now** on the `bits` workflow with the name `Bob`, not paused. To show: the "Bob sends 5 zombie(s)!" banner and, in the same shot if possible, several zombies named "Bob" coming in, one per second.


# DNS Pilot

App macOS de barre de menus pour basculer le DNS système en 2 clics : AdGuard Home self-hébergé, DNS du travail, ou retour au DHCP — avec statut visible en permanence.

- **Icône pleine** (🛡 `shield.fill`) : un DNS personnalisé est actif
- **Icône contour** (`shield`) : DHCP (DNS automatique)
- **Icône alerte** (`exclamationmark.shield.fill`) : le DNS personnalisé actif ne répond plus (health check toutes les 60 s)

Swift 5.9+ / SwiftUI / `MenuBarExtra`, macOS 14+, **zéro dépendance externe**.

## Build & install

Prérequis : macOS 14+, Xcode 15+ (ou Command Line Tools récents).

```sh
make app        # construit dist/DNS Pilot.app (binaire release + Info.plist + signature ad hoc)
make install    # copie le bundle dans ~/Applications
```

Puis lancez **DNS Pilot** depuis le Finder ou Spotlight. L'app n'apparaît que dans la barre de menus (pas de Dock).

Pour le développement : `swift run DNSPilot` (ou `make run`). Attention : le launch at login et la lecture du SSID exigent le bundle `.app` — via `swift run`, ces deux fonctions sont indisponibles (macOS les lie à l'identité du bundle).

> Le bundle est signé **ad hoc** (`codesign --sign -`) : parfait pour un usage local. Sur une autre machine, Gatekeeper bloque le premier lancement — voir la section [Releases](#releases--dmg-via-github-actions).

## Releases : DMG via GitHub Actions

Chaque tag `vX.Y.Z` poussé sur GitHub déclenche le workflow [`release.yml`](.github/workflows/release.yml) : build sur un runner macOS, création de `DNS-Pilot-X.Y.Z.dmg` (l'app + un raccourci vers /Applications), checksum SHA-256, puis publication d'une **GitHub Release** avec notes générées automatiquement.

Publier une version :

```sh
git tag v1.0.0
git push origin v1.0.0
```

La version du tag est injectée au build dans l'Info.plist (`CFBundleShortVersionString`) et `CFBundleVersion` reçoit le numéro de run Actions — visible dans *Préférences › Général › À propos*. Un déclenchement manuel du workflow (*Run workflow* dans l'onglet Actions) produit un DMG de test en artefact, sans créer de Release.

En local : `make dmg` (ou `make dmg VERSION=1.2.3`).

> ⚠️ Le DMG est signé **ad hoc** et non notarisé (aucun compte Apple Developer requis). Au premier lancement sur une autre machine, macOS le bloque : autorisez-le via *Réglages Système › Confidentialité et sécurité › « Ouvrir quand même »*, ou `xattr -dr com.apple.quarantine "/Applications/DNS Pilot.app"`. Pour une distribution publique propre, il faudrait ajouter au workflow une signature Developer ID + notarisation. Ce blocage ne concerne que la première installation manuelle : les [mises à jour automatiques](#mises-à-jour-automatiques) passent sans.

## Mises à jour automatiques

DNS Pilot vérifie une fois par jour (et au lancement) si une nouvelle Release GitHub existe — une simple requête à l'API, silencieuse. Quand c'est le cas : notification (une seule par version) et entrée **« Installer la mise à jour X.Y.Z… »** dans le menu, également disponible dans *Préférences › Général › Mises à jour* (où la vérification automatique se désactive).

L'installation ne démarre que sur un clic explicite, puis tout est automatique : téléchargement du DMG de la Release, **SHA-256 vérifié** contre le `checksums.txt` publié par la CI, montage, contrôle que le bundle annonce bien la version promise, remplacement du bundle en place et relance de l'app. Comme c'est l'app elle-même qui télécharge, l'attribut quarantine est retiré au passage : **pas de blocage Gatekeeper sur les mises à jour**, contrairement au premier lancement manuel d'un DMG.

Garde-fous :

- Checksum absent, SHA-256 divergent ou version inattendue dans le DMG → abandon, rien n'est touché.
- Le remplacement du bundle est fait par un petit script détaché après la fermeture de l'app ; si la pose de la nouvelle version échoue, **l'ancienne est restaurée** telle quelle.
- Aucun privilège requis : le bundle appartient à l'utilisateur (`~/Applications` ou `/Applications`) — la règle sudoers n'est pas concernée. Si le dossier n'est pas modifiable, l'app le dit et il faut mettre à jour à la main.
- Limite assumée : app ad hoc non notarisée, donc la confiance repose sur HTTPS + l'intégrité du dépôt GitHub (le checksum garantit un téléchargement intact, pas une signature d'éditeur). Indisponible via `swift run` (pas de bundle à remplacer).

## Utilisation

Le menu propose :

- **La liste des profils DNS** (nom + serveurs + **latence**, ex. `· 12 ms`, ou `· ne répond pas`) — le profil actif est coché. Un clic l'applique à l'interface réseau courante. La latence est mesurée par une vraie requête DNS UDP vers le premier serveur de chaque profil, toutes les 30 s environ et à chaque « Actualiser l'état ».
- **DHCP (auto)** — supprime les DNS manuels, retour aux DNS du DHCP.
- **Vider le cache DNS** — `dscacheutil -flushcache` + `killall -HUP mDNSResponder`.
- **Actualiser l'état** — force une relecture (faite aussi automatiquement toutes les 30 s et à chaque changement de réseau).
- **Installer la mise à jour X.Y.Z…** — n'apparaît que lorsqu'une nouvelle Release est disponible (voir [Mises à jour automatiques](#mises-à-jour-automatiques)).
- **Préférences…** — deux onglets : *Profils* (add/edit/delete, SSID de bascule auto, URL DoH) et *Général* (launch at login, bascule auto, autorisation admin).

L'interface active est détectée via la route par défaut (`route -n get default`), mappée sur `networksetup -listnetworkserviceorder`. Si la route par défaut passe par un tunnel (`utun*` : Tailscale, VPN…), DNS Pilot retombe sur le premier service physique actif de l'ordre système — c'est bien lui qu'il faut configurer, `networksetup` ne connaissant pas les interfaces de tunnel.

## Mot de passe admin : demandé une seule fois

`networksetup -setdnsservers` exige les droits root. DNS Pilot procède ainsi :

1. **Chaque écriture tente d'abord `sudo -n`** (non interactif, aucune boîte de dialogue).
2. Si ça échoue (première utilisation), une **unique invite admin** AppleScript apparaît. Elle exécute le changement demandé **et installe dans la foulée** une règle sudoers dans `/etc/sudoers.d/dns-pilot` :

   ```
   <vous> ALL=(root) NOPASSWD: /usr/sbin/networksetup, /usr/bin/dscacheutil, /usr/bin/killall -HUP mDNSResponder
   ```

3. Toutes les actions suivantes passent par `sudo -n` : **plus jamais de mot de passe**.

Garde-fous :

- La règle est écrite dans un fichier temporaire, **validée par `visudo -c`**, puis seulement mise en place — impossible de casser sudo, même en cas de bug.
- Portée minimale : trois commandes précises, pour votre utilisateur uniquement. `networksetup` permet « seulement » de modifier la configuration réseau de vos interfaces.
- Désactivable : onglet *Général* → décocher « Mémoriser l'autorisation » et/ou « Supprimer la règle sudoers… ». Le comportement redevient alors celui d'une invite par changement.
- Les adresses IP des profils sont validées (IPv4/IPv6 strict) avant toute commande privilégiée — rien du contenu de `profiles.json` ne peut s'injecter dans le shell.

### Alternatives non retenues

| Approche | Avantage | Pourquoi pas ici |
|---|---|---|
| **Helper privilégié** (`SMAppService.daemon` + XPC, successeur de SMJobBless) | Même résultat (une autorisation, zéro prompt ensuite), surface encore plus réduite | Signature Developer ID requise en pratique, plist launchd, protocole XPC à sécuriser : lourd pour une app perso ; la règle sudoers validée par visudo offre le même confort |
| **`NEDNSSettingsManager`** (NetworkExtension) | API native, DoH inclus | Entitlement spécial à demander à Apple, distribution signée obligatoire |

### Pourquoi pas de sandbox ?

Le sandbox interdit de lancer des processus externes (`networksetup`, `sudo`, `osascript`) et de modifier la configuration réseau. App non-sandboxée → distribution locale uniquement (pas d'App Store).

## Profils

Stockés dans `~/Library/Application Support/DNSPilot/profiles.json` :

```json
[
  { "name": "AdGuard Home", "servers": ["192.168.1.104"], "autoSSIDs": ["MonWiFiMaison"] },
  { "name": "Travail", "servers": ["10.0.0.53", "10.0.0.54"], "autoSSIDs": ["Corp-WiFi"] },
  { "name": "Cloudflare", "servers": ["1.1.1.1", "1.0.0.1"], "dohURL": "https://cloudflare-dns.com/dns-query" }
]
```

Éditables via les Préférences ou à la main (`id` optionnel ; un fichier corrompu est mis de côté en `.bak`, jamais écrasé).

## Bascule automatique par SSID

Configurez les SSID dans chaque profil (onglet *Profils*). Quand le Mac change de réseau (détection `NWPathMonitor`, debounce 3 s le temps que le Wi-Fi se stabilise), DNS Pilot lit le SSID et applique le profil correspondant.

À savoir :

- **macOS exige l'autorisation Localisation pour lire le SSID** (le nom du réseau est considéré comme une donnée de position). Bouton « Autoriser » dans l'onglet *Général* ; aucune position n'est utilisée.
- La bascule est **strictement silencieuse** : elle ne passe que par `sudo -n`. Sans règle sudoers, il ne se passe rien — jamais de boîte de dialogue surprise.
- Un choix manuel n'est **jamais écrasé** tant que vous restez sur le même réseau : la bascule ne s'évalue qu'au changement de SSID (et au lancement).
- Premier profil correspondant dans l'ordre de la liste = gagnant, en cas de SSID présent dans plusieurs profils.
- Réseaux filaires : pas de SSID, pas de bascule (extension possible : matcher sur la passerelle/le subnet).

## DNS-over-HTTPS (DoH)

Renseignez l'URL DoH d'un profil (ex. `https://dns.adguard.com/dns-query`), puis « Générer le profil système (.mobileconfig)… ». DNS Pilot crée un profil de configuration (payload `com.apple.dnsSettings.managed`, avec les IP du profil en bootstrap) dans `~/Downloads` et l'ouvre.

**Limite structurelle** : hors MDM, macOS n'autorise aucune installation silencieuse de profil — il faut terminer manuellement dans Réglages Système › Général › Gestion des appareils (double-clic → Installer). Une fois installé, le DoH **prend le pas** sur les DNS `networksetup` pour tout le système ; pensez à le retirer au même endroit pour revenir aux profils classiques. Le health check (port 53) ne couvre pas le DoH.

## Health check & failover

Toutes les 60 s, DNS Pilot envoie une vraie requête DNS UDP (question A `apple.com`, port 53, timeout 2,5 s) au premier serveur du profil actif — via Network.framework, sans processus externe. Une requête perdue est re-vérifiée immédiatement : il faut **deux échecs d'affilée** pour déclarer le serveur muet (icône alerte).

**Failover automatique** (activé par défaut, désactivable dans *Général*) : quand le DNS actif est déclaré muet, DNS Pilot bascule sur la **cible de secours** (DHCP par défaut, ou n'importe quel profil — ex. Cloudflare). Il continue de sonder le serveur d'origine toutes les 60 s et **rétablit le profil initial dès qu'il répond** de nouveau. Pendant un failover, l'icône passe en `exclamationmark.shield` (contour) et le menu affiche la panne en cours.

- Strictement silencieux : le failover ne passe que par `sudo -n`. Sans règle sudoers, il ne bascule pas (une notification vous prévient).
- Un changement manuel de profil annule le failover en cours (vous reprenez la main).
- Si la cible de secours est le profil en panne lui-même, il ne se passe rien.
- Attention si votre box annonce AdGuard via DHCP : la cible « DHCP (auto) » vous ramènerait au même serveur en panne — choisissez plutôt un profil public (Cloudflare) comme cible.

## Intégration AdGuard Home

L'instance AdGuard Home est une **configuration globale** (*Préférences › AdGuard Home* : URL, identifiants, bouton « Tester la connexion ») — pas une propriété des profils. L'association est automatique : la section AdGuard du menu apparaît **quand le DNS actif pointe vers l'instance** (correspondance par IP ; si l'URL utilise un nom d'hôte — Tailscale MagicDNS, reverse proxy — il est résolu et comparé). C'est le seul moment où « suspendre le blocage » a un sens.

La section du menu propose :

- **Statut** : protection activée/suspendue, requêtes bloquées / totales (fenêtre de stats du serveur, 24 h par défaut).
- **« Suspendre le blocage 5 min »** — le geste marteau quand un site casse à cause d'un filtre. La réactivation est gérée côté serveur (paramètre `duration` de l'API), donc même si l'app quitte, la protection revient.
- **« Débloquer un domaine récent »** — le geste scalpel : le sous-menu liste les derniers domaines bloqués (journal des requêtes, dédupliqués, 8 max). Un clic ajoute la règle d'autorisation `@@||domaine^` aux règles utilisateur — prioritaire sur les listes de blocage, et **permanente** (à retirer dans l'interface AGH, *Filtres › Règles de filtrage personnalisées*). Le sous-menu n'apparaît que si le journal des requêtes est activé côté serveur.
- **« Réactiver la protection »** quand elle est suspendue.
- **« Ouvrir l'interface AdGuard Home… »**.

**Détection automatique** : tant qu'aucune instance n'est configurée, DNS Pilot sonde le serveur DNS actif sur les ports web habituels d'AdGuard Home (80, 3000, 8080) et prérenseigne l'URL s'il le reconnaît. Interface sur un port exotique ou derrière un reverse proxy ? Saisissez l'URL à la main (bouton « Détecter sur le DNS actif » également disponible).

**Identifiants** : l'API est appelée en HTTP Basic. Le mot de passe est stocké dans le **trousseau macOS** (jamais en clair). Note : l'app étant signée ad hoc, macOS peut redemander l'accès au trousseau après un rebuild.

## Notifications

Notifications macOS (désactivables dans *Général*) pour : bascule auto par SSID, failover déclenché, profil rétabli, et failover impossible faute d'autorisation admin mémorisée. Comme tout ce qui dépend de l'identité de l'app, elles exigent le bundle `.app` (silencieuses via `swift run`).

## Architecture

```
Sources/DNSPilot/
├── DNSPilotApp.swift        # @main, MenuBarExtra + Settings, politique .accessory
├── AppState.swift           # Coordinateur @MainActor : état, actions, bascule auto SSID, failover, AdGuard
├── DNSManager.swift         # networksetup : lecture libre, écriture sudo -n → AppleScript ; règle sudoers (visudo -c)
├── ProfileStore.swift       # profiles.json (Application Support), ObservableObject
├── HealthChecker.swift      # Requête DNS UDP artisanale toutes les 60 s, double tentative, mesure de latence (Network.framework)
├── AdGuardClient.swift      # API AdGuard Home (status/stats/protection/querylog/règles), détection auto, résolution d'hôte
├── Keychain.swift           # Mot de passe AdGuard dans le trousseau macOS
├── NotificationManager.swift# Notifications macOS (UserNotifications)
├── SSIDProvider.swift       # SSID courant via CoreWLAN + autorisation CoreLocation
├── DoHProfileGenerator.swift# Génère le .mobileconfig com.apple.dnsSettings.managed
├── Updater.swift            # Mises à jour : API GitHub Releases, SHA-256, swap du bundle + relance
├── AppSettings.swift        # Clés UserDefaults + wrapper SMAppService (launch at login)
├── Models.swift             # DNSProfile (Codable : servers, autoSSIDs, dohURL)
├── MenuContent.swift        # Menu déroulant (profils, AdGuard, failover)
└── PreferencesView.swift    # Préférences : onglets Profils / AdGuard Home / Général
```

Les vues ne parlent qu'à `AppState`, qui orchestre `DNSManager` (shell), `ProfileStore` (persistance), `HealthChecker` (réseau), `SSIDProvider` (Wi-Fi) et `AdGuardClient` (HTTP). Tout le travail bloquant s'exécute hors du main thread.

## Désinstallation

```sh
rm -rf ~/Applications/"DNS Pilot.app"
rm -rf ~/Library/Application\ Support/DNSPilot
sudo rm -f /etc/sudoers.d/dns-pilot   # règle installée par l'app (ou : Préférences → Supprimer la règle)
```

Et retirez l'éventuel profil DoH dans Réglages Système › Général › Gestion des appareils.

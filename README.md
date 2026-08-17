# Post-install Proxmox VE 9 — T-BAO R3 Pro

Script de post-installation pour un hôte **Proxmox VE 9** personnel : nœud unique, sans souscription,
sans Ceph. Non-interactif, idempotent, et il ne supprime jamais rien.

Machine cible : T-BAO R3 Pro — Ryzen 7 5700U (iGPU Vega), 32 Go, SSD 1 To, 2× 2.5 GbE.

Le point de départ était [`tools/pve/post-pve-install.sh`](https://github.com/community-scripts/ProxmoxVE/blob/main/tools/pve/post-pve-install.sh)
de **community-scripts/ProxmoxVE**, dont l'original verbatim est conservé dans [`upstream/`](upstream/)
— voir [Pourquoi ne pas utiliser le script communautaire tel quel](#pourquoi-ne-pas-utiliser-le-script-communautaire-tel-quel).

| Fichier | Rôle |
|---|---|
| `pve9-postinstall.sh` | Le script. 161 lignes, dont ~20 de JS pour l'UI mobile et ~25 de journalisation. |
| `upstream/post-pve-install.sh` | L'amont verbatim, épinglé sur [`fb1d670`](https://github.com/community-scripts/ProxmoxVE/commit/fb1d670158ba68a41397ce4f21c3b6444c1a76d4) (2026-08-06, md5 `cb32f577bc9aeb730e447faa74e52732`). Jamais exécuté, sert de référence. |
| `upstream/api.func` | Le module de télémétrie de l'amont, archivé pour audit. Jamais exécuté. |

## Utilisation

**Ne pas** faire `curl … | bash`. On copie le fichier et on le lance.

```bash
tar czf /root/etc-apt-$(date +%F).tgz /etc/apt     # sauvegarde
scp pve9-postinstall.sh root@<pve>:/root/
bash /root/pve9-postinstall.sh
```

## Ce qu'il fait

Sept actions, dans cet ordre :

1. Désactive les dépôts réservés aux abonnés — `pve-enterprise.sources` **et** `ceph.sources`, tous deux
   sur `enterprise.proxmox.com` sur une PVE 9 fraîche, donc traités par une seule boucle.
2. Écrit `proxmox.sources` avec `pve-no-subscription`.
3. Garantit `contrib` **et** `non-free-firmware` sur chaque ligne `Components:` de `debian.sources`.
4. Désactive HA et Corosync (nœud unique).
5. `apt update` puis `apt -y dist-upgrade`.
6. Installe le microcode et les firmwares **détectés via `lspci`**.
7. Retire le bandeau de souscription sur les deux UI, desktop et mobile.

Il finit par un rappel. **Pas de reboot automatique.**

### Journal de console

Chaque étape annonce ce qu'elle fait et distingue trois états, pour qu'un second lancement soit lisible :

```
==> Depots APT
    ok   pve-enterprise.sources desactive
    --   ceph.sources deja desactive
    !!   1 fichier(s) .list legacy, NON touches - a revoir a la main :
```

`ok` = action appliquée, `--` = déjà en état, `!!` = avertissement (sur stderr). Un `trap … ERR` signale la
ligne fautive si le script s'arrête. Les couleurs se désactivent hors terminal, donc
`bash pve9-postinstall.sh | tee post.log` reste propre.

### Garde-fous

- **`VERSION_CODENAME=trixie` exigé.** Le script écrit `Suites: trixie` en dur ; l'exécuter sur un hôte
  bookworm/PVE 8 basculerait les dépôts de base et enchaînerait une montée de version non supportée.
- **Rien de destructif. Aucun `rm`, et jamais d'`apt autoremove`** (voir plus bas pourquoi c'est la
  commande qui compte). Les `.list` legacy sont **signalés, pas supprimés** — c'est encore le format de
  Docker, Tailscale et de plusieurs scripts communautaires. `/etc/apt/sources.list` est commenté avec un
  `.bak` créé par `cp -n`, donc un second passage n'écrase pas la sauvegarde d'origine.
- **Le patch du nag est vérifié après application.** Si le motif `data.status` est introuvable (format
  amont modifié), le script avertit au lieu d'annoncer un succès.
- **Une unité systemd absente n'interrompt pas le script** : elle est signalée, le reste s'applique.
- **`lspci` décide des firmwares** plutôt qu'une supposition : `firmware-realtek` et `firmware-iwlwifi` ne
  sont ajoutés que si le contrôleur correspondant est présent.

## Relancer le script

Il est conçu pour être **ta commande de mise à jour**, à la place d'`apt dist-upgrade` : tu récupères au
passage la remise en état des dépôts, de HA et du bandeau, ce qu'un simple `apt` ne fait pas.

- S'il n'y a rien à faire, il ne fait rien (tout en `--`).
- S'il y a des mises à jour, il les applique **puis** re-supprime le bandeau, dans le même passage.

Deux réserves à connaître :

- **`proxmox.sources` est réécrit sans condition** (contenu identique, donc sans effet). Ne le modifie pas
  à la main : un prochain passage l'écraserait. Pour un miroir local, change le script.
- Si `apt` échoue, `set -e` arrête tout et **le patch du nag ne s'exécute pas** ce coup-ci. Le `!!` te le dit.

### Le bandeau revient régulièrement, c'est normal

`proxmoxlib.js` appartient à `proxmox-widget-toolkit` et `index.html.tpl` à `pve-yew-mobile-gui` : toute
mise à jour de ces paquets écrase le patch. D'après le changelog amont, `proxmox-widget-toolkit` sort
**~1,7 version par mois** (13 en 2026 à mi-août, 21 en 2025) — donc le bandeau réapparaît en pratique à
presque chaque cycle de mise à jour.

C'est un choix assumé : **aucun hook APT n'est posé.** Relancer le script suffit. Si tu veux seulement
faire sauter le bandeau sans rien mettre à jour ni redémarrer de service :

```bash
W=/usr/share/javascript/proxmox-widget-toolkit/proxmoxlib.js
grep -q NoMoreNagging "$W" || sed -i -e '/data\.status/ s/!//' -e '/data\.status/ s/active/NoMoreNagging/' "$W"
# puis Ctrl+Shift+R dans le navigateur
```

### À propos de `dist-upgrade`

`apt full-upgrade` (= `dist-upgrade`) est la commande **officiellement recommandée** par Proxmox, qui met
explicitement en garde contre `apt upgrade` : ce dernier ne sait pas supprimer un paquet pour résoudre une
dépendance et peut laisser « un état de paquets partiellement mis à jour ou cassé ».

Les suppressions de paquets pendant un `full-upgrade` sont donc le mécanisme normal (paquets
transitionnels, renommages, métapaquets obsolètes). Le seul cas catastrophique — apt proposant de
supprimer `proxmox-ve` parce que le dépôt PVE ne fournit rien — est **déjà couvert par Proxmox** :
`proxmox-ve` installe `/etc/apt/apt.conf.d/10pveapthook`, qui branche
`/usr/share/proxmox-ve/pve-apt-hook` en `DPkg::Pre-Install-Pkgs`. Ce hook avorte toute la transaction si
`proxmox-ve` ou le noyau épinglé apparaît en `**REMOVE**`, et exige un `touch /please-remove-proxmox-ve`
explicite pour passer outre. Rien à ajouter de notre côté.

En revanche, `full-upgrade` **laisse les anciens noyaux installés** : ton entrée GRUB de secours existe par
défaut. C'est `apt autoremove` qui les retire — donc c'est `autoremove` qui peut supprimer ton filet de
sécurité, pas `full-upgrade`. Le script ne l'appelle jamais.

Sur ce boîtier il n'y a **ni IPMI ni carte de gestion** : si un noyau ne démarre pas, choisir l'ancienne
entrée GRUB demande un écran HDMI et un clavier. C'est la vraie exposition, et elle est indépendante du
script.

## Pourquoi ne pas utiliser le script communautaire tel quel

Trois constats sur l'amont, tous vérifiables contre [`upstream/`](upstream/). Ils justifient les choix de
conception ci-dessus.

**1. Du code distant exécuté en root à chaque lancement.** L'amont fait
`source <(curl -fsSL …/misc/api.func)` puis `init_tool_telemetry`, soit ~1 200 lignes de code non épinglé
chargées depuis le réseau, plus un `trap … EXIT`. L'envoi vers `telemetry.community-scripts.org` est en
réalité **opt-in** — `_tm_enabled()` sort immédiatement sauf si `DIAGNOSTICS=yes` dans
`/usr/local/community-scripts/diagnostics`, absent d'une install neuve. Le problème n'était donc pas la
télémétrie mais le `source` distant.

**2. Un hook APT permanent, et un piège d'ordonnancement.** L'amont écrit
`/etc/apt/apt.conf.d/no-nag-script`, un `DPkg::Post-Invoke` qui réexécute le patch après **chaque**
opération dpkg, indéfiniment. Le retirer n'est pas une simple suppression : l'amont lance
`apt --reinstall install proxmox-widget-toolkit` **inconditionnellement** juste après la branche nag, ce
qui restaure le `proxmoxlib.js` d'origine — et c'est le hook qui re-patchait derrière. Supprimer le hook
seul aurait silencieusement fait revenir le bandeau. D'où l'ordre imposé ici : le patch en dernier, après
le `dist-upgrade`.

**3. Un faux positif qui saute une question.** `component_exists_in_sources "no-subscription"` construit
la regex `\bno-subscription\b` ; `-` étant une frontière de mot, elle matche aussi `pve-no-subscription`.
Comme `proxmox.sources` est créé quelques étapes plus haut dans la même exécution, la question Ceph était
**toujours** sautée, avec le message faussement rassurant « already exists (skipped) ».

### Ce qui a été écarté par rapport à « oui à tout »

| Étape de l'amont | Pourquoi écartée |
|---|---|
| Migration deb822 des sources | La branche est sautée dès qu'un `*.sources` existe — le cas sur une PVE 9 fraîche. Zéro effet. |
| Dépôt Ceph no-subscription | Nœud unique sans Ceph : un dépôt de plus à interroger à chaque `apt update`, pour rien. |
| Dépôt `pve-test` | L'amont l'ajoute avec `Enabled: false` : un fichier sans aucun effet. |
| `apt --reinstall proxmox-widget-toolkit` | Ne servait qu'à déclencher le hook APT, ou à restaurer le fichier si on répondait « non ». En répondant « oui », c'est du travail annulé aussitôt. |
| « Activer HA » puis « désactiver HA » | L'amont pose les deux questions à la suite ; sur un nœud unique on désactive, point. |
| `rm -f /etc/apt/sources.list.d/*.list` | Destructif et sans sauvegarde. Ici les `.list` sont signalés, jamais supprimés. |

## Limites

- La boucle de désactivation suppose des `.sources` **mono-strophe** — le cas de ceux que livre Proxmox.
  Sur un fichier multi-strophes, `sed '/^Enabled:/d'` retirerait toutes les lignes `Enabled:`.
- `trixie` et `pve-no-subscription` sont figés : script spécifique à PVE 9, par conception. D'où la garde
  `VERSION_CODENAME=trixie` en tête. Pour PVE 10, repartir de l'amont à jour.
- **Le `sed` du nag dépend du retour à la ligne.** `s/!//` supprime le *premier* `!` de la ligne ; ça ne
  fonctionne que parce que Proxmox met `!res` et `res.data.status… !== 'active'` sur des lignes séparées.
  Si la condition était un jour reformatée sur une seule ligne, le `!` de `!res` serait mangé à la place et
  la condition deviendrait toujours vraie — le bandeau réapparaîtrait. Défaillance bénigne, et le contrôle
  post-patch l'affiche au lieu de la taire.
- Les sélecteurs CSS du bloc mobile sont ceux de l'amont et dépendent du build de l'UI mobile PVE. Une
  refonte de cette UI les invaliderait silencieusement : le bloc cesserait d'agir sans rien casser.
- Écart volontaire vis-à-vis de l'amont : le `clearInterval` manquant a été ajouté. L'amont coupe son
  `MutationObserver` au bout de 10 s mais laisse tourner un `setInterval(…, 300)` indéfiniment dans le
  navigateur.

## Tests

Le script est **exécuté en entier** hors hôte, pas seulement relu. Le harnais dérive une copie du vrai
fichier en préfixant les 4 variables de chemin déclarées en tête (`D`, `SL`, `WEB_JS`, `MOBILE_TPL`) et
fournit des stubs pour `apt`, `systemctl`, `lspci` et `pveversion`. Un `diff` confirme que le harnais ne
diverge du script que sur ces chemins — toute la logique testée est celle qui tournera sur l'hôte.

Fixtures : arborescence PVE 9 reconstituée, avec un extrait **réel** de `src/Utils.js` récupéré depuis
`git.proxmox.com` comme `proxmoxlib.js`.

| Cas | Attendu | Résultat |
|---|---|---|
| Passage 1 puis 2, nominal | `diff -r` vide au 2ᵈ passage, tout signalé « deja » | conforme |
| `debian.sources` | `contrib` sur les 2 strophes, jamais dupliqué | conforme |
| Dépôts enterprise | un seul `Enabled: false` par fichier | conforme |
| `proxmoxlib.js` | `!== 'active'` → `== 'NoMoreNagging'` | conforme |
| `sources.list` avec `deb` actifs, dont une ligne indentée | commentés, `.bak` = original | conforme |
| `docker.list` présent | intact, signalé seulement | conforme |
| `corosync` absent | avertissement, script poursuit | conforme |
| Motif `data.status` introuvable | avertissement, pas de faux succès | conforme |
| UI mobile absente | `--` propre, sans erreur | conforme |

Non testable hors hôte : le JS mobile lui-même (il dépend du DOM de l'UI mobile PVE) et le comportement
réel d'`apt` et de `systemctl`.

## Contrôles sur l'hôte

```bash
test ! -e /etc/apt/apt.conf.d/no-nag-script && echo "aucun hook APT: OK"
grep -c NoMoreNagging /usr/share/javascript/proxmox-widget-toolkit/proxmoxlib.js    # 1
grep -c NoMoreNagging /usr/share/pve-yew-mobile-gui/index.html.tpl                  # 1
grep Components /etc/apt/sources.list.d/debian.sources   # contrib + non-free-firmware
systemctl is-enabled pve-ha-lrm pve-ha-crm corosync      # disabled
apt update                                               # aucun depot enterprise interroge
df -h /boot ; proxmox-boot-tool kernel list              # espace et noyaux disponibles
```

## Licence

MIT, conservée depuis l'amont — voir [`LICENSE`](LICENSE). `pve9-postinstall.sh` contient du code dérivé
du script communautaire (le `sed` du nag, le bloc JS mobile), donc l'attribution reste due même sans le
fork. Crédit : tteck / tteckster, MickLesk (CanbiZ) et la communauté community-scripts.

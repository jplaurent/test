# Post-install Proxmox VE 9 — T-BAO R3 Pro

Script de post-installation pour un hôte **Proxmox VE 9** personnel : nœud unique, sans souscription,
sans Ceph. Non-interactif, idempotent, et il ne supprime jamais rien.

Machine cible : T-BAO R3 Pro — Ryzen 7 5700U (iGPU Vega), 32 Go, NVMe 1 To, 2× 2,5 GbE **Intel I226-V**
(interfaces `nic0`/`nic1`), Wi-Fi 6 AX200. Racine en ext4 sur LVM. Voir
[État constaté sur l'hôte](#état-constaté-sur-lhôte-2026-08-19).

Le point de départ était [`tools/pve/post-pve-install.sh`](https://github.com/community-scripts/ProxmoxVE/blob/main/tools/pve/post-pve-install.sh)
de **community-scripts/ProxmoxVE**, dont l'original verbatim est conservé dans [`upstream/`](upstream/)
— voir [Pourquoi ne pas utiliser le script communautaire tel quel](#pourquoi-ne-pas-utiliser-le-script-communautaire-tel-quel).

| Fichier | Rôle |
|---|---|
| `pve9-postinstall.sh` | Le script. 181 lignes, dont ~20 de JS pour l'UI mobile et ~25 de journalisation. |
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
6. Installe `amd64-microcode`. **Aucun paquet `firmware-*` de Debian** — voir ci-dessous.
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
  Docker, Tailscale et de plusieurs scripts communautaires. `/etc/apt/sources.list` est commenté après
  création d'un `.bak`, sous test explicite `[[ -e $SL.bak ]] ||` — un second passage ne peut pas écraser la
  sauvegarde d'origine.
- **Un hook APT `no-nag-script` résiduel est signalé, pas retiré.** Si un passage du script communautaire en
  a laissé un, tu es averti avec la commande pour l'enlever ; le choix reste le tien.
- **Le patch du nag est vérifié après application.** Si le motif `data.status` est introuvable (format
  amont modifié), le script avertit au lieu d'annoncer un succès.
- **Une unité systemd absente n'interrompt pas le script** : elle est signalée, le reste s'applique.
- **Aucun paquet `firmware-*` de Debian n'est installé** — voir la section suivante, c'est le piège le plus
  sérieux rencontré sur ce script.

### Ne jamais installer les paquets `firmware-*` de Debian

Erreur commise puis corrigée dans ce dépôt, elle vaut d'être documentée. `pve-firmware` déclare
**`Conflicts:` et `Replaces:`** sur `firmware-amd-graphics`, `firmware-iwlwifi`, `firmware-realtek` et une
vingtaine d'autres (voir `debian/control` de `pve-firmware.git`). Installer l'un d'eux fait résoudre le
conflit à apt en **retirant `pve-firmware`**, dont dépend le noyau Proxmox :

```
REMOVING: proxmox-default-kernel
W: (pve-apt-hook) You are attempting to remove the meta-package 'proxmox-ve'!
Error: Sub-process /usr/share/proxmox-ve/pve-apt-hook returned an error code (1)
```

Le `pve-apt-hook` avorte la transaction avant tout changement, donc rien n'est cassé — mais l'étape échoue
et, `set -e` aidant, le script s'arrête là.

Le `Replaces:` dit l'essentiel : **ces blobs sont déjà installés**, fournis par `pve-firmware`. Il n'y a
rien à ajouter pour l'iGPU Vega ni pour le Wi-Fi. Le script se contente donc de vérifier la présence de
`pve-firmware` et d'installer `amd64-microcode`, qui n'est pas dans la liste de conflits.

Et si tu croises ce message un jour : **ne fais pas `touch /please-remove-proxmox-ve`.** C'est la porte de
sortie prévue pour désinstaller Proxmox volontairement, pas un contournement.

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
fournit des stubs pour `apt`, `systemctl`, `dpkg` et `pveversion`. Un `diff` confirme que le harnais ne
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
| `pve-firmware` présent / absent | `ok` / `!!`, et jamais de paquet `firmware-*` Debian installé | conforme |
| `pve-firmware` en état `deinstall ok config-files` | `!!`, pas de faux « présent » | conforme |
| Hook APT `no-nag-script` résiduel | signalé, jamais retiré | conforme |

Non testable hors hôte : le JS mobile lui-même (il dépend du DOM de l'UI mobile PVE) et le comportement
réel d'`apt` et de `systemctl`.

### Validé sur l'hôte réel (2026-08-19)

- **Exécution complète réussie**, étape microcode incluse, après le correctif `firmware-*`. Le double
  patch du nag (desktop et mobile) a été appliqué par le script lui-même.
- **`shellcheck` ne remonte rien** sur `pve9-postinstall.sh` — aucune remarque, y compris au niveau
  `style`, qui est la sévérité rapportée par défaut. C'est le dernier contrôle statique qui manquait.

  Un `shellcheck` silencieux est un succès : il ne produit aucun message quand il n'a rien à dire. Pour
  s'assurer qu'il a bien analysé quelque chose, un contrôle positif :

  ```bash
  printf '#!/bin/sh\nrm $1\n' > /tmp/sc-test.sh
  shellcheck /tmp/sc-test.sh   # doit sortir un SC2086 et un code retour non nul
  ```

  Deux détails d'écriture y contribuent et ne doivent pas être « simplifiés » :
  `trap '...$LINENO...' ERR` en **guillemets simples** (en doubles, `$LINENO` serait figé à la définition
  du trap et désignerait la mauvaise ligne — `SC2064`), et `dpkg-query -W -f='${Status}'` de même (en
  doubles, bash tenterait d'expandre `${Status}` et `set -u` ferait échouer le script).

## Matériel spécifique — points à connaître

Le script ne touche à aucun de ces points : ce sont des choses à savoir sur cette machine, à traiter
seulement si le besoin apparaît.

### Le NIC Intel I226-V a un défaut connu

Les deux ports 2,5 GbE sont des **Intel I226-V** (pilote `igc`), pas du Realtek. Cette puce a un problème
documenté de **coupures de lien aléatoires**, imputé à trois causes : l'Energy Efficient Ethernet (EEE),
une gestion d'énergie PCIe (ASPM) trop agressive, et un firmware d'adaptateur périmé. Intel a reconnu le
problème et publié une mise à jour **NVM** (firmware de la carte, distinct du pilote) comme correctif
définitif ; désactiver l'EEE est le contournement côté système, et il n'est pas toujours suffisant.

Sources : [Intel Community](https://community.intel.com/t5/Ethernet-Products/Intel-Communication-Intel-Ethernet-Controller-I226-Series-Random/m-p/1453177),
[Intel I226-V is still randomly disconnecting](https://community.intel.com/t5/Ethernet-Products/Intel-I226-V-is-still-randomly-disconnecting/td-p/1630534),
[AnandTech](https://at-web1.www.anandtech.com/show/18755/intel-shares-stopgap-solution-for-intermittent-connection-drops-on-700series-motherboards),
[ComputingForGeeks](https://computingforgeeks.com/fix-intel-i226-nic-drops-opnsense/).

**Vérifié le 2026-08-19 : 0 coupure de lien sur 7 jours. Le défaut ne se manifeste pas sur cet
exemplaire — ne change rien.** Cette section reste ici comme référence si la situation évolue.

Attention au nommage : sur cette machine les interfaces sont **`nic0` et `nic1`**, pas `enp1s0`.

```bash
journalctl -k --since "7 days ago" | grep -ciE 'link is down|nic link is down'
ethtool --show-eee nic0     # ethtool n'est pas installe par defaut : apt install ethtool
```

Si un jour le lien se met à battre et que l'EEE est actif, désactive-le puis rends-le persistant dans la
strophe de l'interface concernée de `/etc/network/interfaces` (le port est esclave de `vmbr0`) :

```
post-up /usr/sbin/ethtool --set-eee nic0 eee off
```

Le correctif définitif reste la mise à jour NVM publiée par Intel, pas ce contournement.

### Autres points

- **Le microcode est appliqué et fonctionne.** Vérifié : `microcode: Updated early from: 0x08608103` →
  `Current revision: 0x08608108`. Contrairement à une réserve émise plus tôt dans ce dépôt, AMD publie bien
  une révision pour ce 5700U, et elle est chargée tôt via l'initramfs. Contrôle :
  `dmesg | grep -i microcode`. Ne prend effet qu'après un redémarrage suivant l'installation.
- **iGPU Vega : opérationnel.** `amdgpu` est attaché, `/dev/dri/card0` et `/dev/dri/renderD128` sont
  présents. Rien à installer — `pve-firmware` fournit les blobs. Pour du transcodage matériel en LXC,
  passer `/dev/dri/renderD128` au conteneur.
- **Passthrough** (iGPU ou contrôleur disque vers une VM) : la ligne de commande du noyau ne contient
  actuellement que `root=... ro quiet`. Il faudrait ajouter `amd_iommu=on iommu=pt`. Hors périmètre de ce
  script, à faire consciemment.
- **`Acquire::Check-Valid-Until "false"`** est positionné dans `/etc/apt/apt.conf.d/99mmdebstrap`. Ce
  fichier vient de **l'installeur Proxmox VE 9 officiel** (installation depuis l'ISO), qui bootstrape avec
  `mmdebstrap` — ce n'est donc pas un résidu étranger.

  Le réglage a du sens *pendant* l'installation : les métadonnées embarquées dans l'ISO sont forcément
  périmées au regard de leur `Valid-Until` le jour où on installe. Ce qui est moins clair, c'est s'il est
  volontairement destiné à rester actif ensuite. Laissé en place, il désactive le contrôle de fraîcheur des
  métadonnées de dépôt : un miroir figé ou compromis peut resservir d'anciennes métadonnées et masquer des
  mises à jour de sécurité (attaque par gel). D'autant que `debian.sources` tape en `http://`.

  Le retirer est peu risqué et restaure une protection par défaut, mais c'est un écart vis-à-vis d'un
  fichier livré par l'éditeur — donc un choix conscient, pas une correction évidente :

  ```bash
  dpkg -S /etc/apt/apt.conf.d/99mmdebstrap   # si aucun paquet ne le possede, rien ne le restaurera
  cp /etc/apt/apt.conf.d/99mmdebstrap /root/99mmdebstrap.bak
  sed -i '/Check-Valid-Until/d' /etc/apt/apt.conf.d/99mmdebstrap
  apt update
  ```
- **Les deux baies 3,5" vides** sont la destination naturelle des sauvegardes `vzdump`. Un hôte cassé se
  réinstalle ; des VM perdues ne reviennent pas.

### État constaté sur l'hôte (2026-08-19)

Audit après le premier passage du script. Tout est conforme.

| | |
|---|---|
| Version | `pve-manager/9.2.11`, noyau `7.0.14-12-pve` |
| Racine | **ext4 sur LVM** (`/dev/mapper/pve-root`), 94 Go dont 84 libres. Pas de ZFS → pas de réglage d'ARC à prévoir. |
| `/boot` | sur la racine, pas de partition dédiée → aucun risque de saturation par accumulation de noyaux |
| Noyaux | `7.0.14-12-pve` (courant) + `7.0.2-6-pve` (repli GRUB). Aucun redémarrage en attente. C'est ce repli qu'`apt autoremove` supprimerait. |
| Disques | un seul NVMe de 954 Go ; les deux baies 3,5" sont vides |
| Dépôts | enterprise et ceph-squid en `Enabled: false`, `pve-no-subscription` actif, `main contrib non-free-firmware` sur les deux strophes Debian, aucun `.list` legacy, 0 ligne active dans `sources.list` |
| Microcode | `amd64-microcode` fourni par le dépôt **Proxmox** lui-même (`~bpo13+1`), pas par un backports Debian tiers |
| HA | `pve-ha-lrm`, `pve-ha-crm`, `corosync` : `disabled` |
| Nag | desktop et mobile patchés (`NoMoreNagging` × 1 chacun) |
| Hooks APT | `10pveapthook` présent (garde-fou officiel actif), **aucun** `no-nag-script` |
| `linux-image-amd64` | non installé — pas de conflit avec les noyaux PVE |

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

# post-pve-install.sh — fork durci

Fork de [`tools/pve/post-pve-install.sh`](https://github.com/community-scripts/ProxmoxVE/blob/main/tools/pve/post-pve-install.sh)
du projet **community-scripts/ProxmoxVE**, épinglé sur le commit
[`fb1d670`](https://github.com/community-scripts/ProxmoxVE/commit/fb1d670158ba68a41397ce4f21c3b6444c1a76d4)
(2026-08-06, md5 `cb32f577bc9aeb730e447faa74e52732`, 698 lignes).

Objectif : pouvoir **lancer le script sans crainte** sur un hôte Proxmox VE personnel — donc pas de code
distant exécuté en root, pas de hook APT permanent, et une divergence assez faible pour être relue en
entier d'un coup d'œil.

Ce dépôt contient deux scripts :

| Fichier | Rôle |
|---|---|
| `post-pve-install.sh` | Le fork fidèle à l'amont : interactif, portable PVE 8.x/9.x, ~700 lignes. La référence auditable. |
| `pve9-postinstall-minimal.sh` | Équivalent de « oui à tout » pour **cette** machine, sans UI. 63 lignes dont 29 de shell. L'outil du quotidien. Voir [Variante minimale](#variante-minimale-non-interactive). |

## Vérifier ce fork

`upstream/` contient les originaux **verbatim** et n'est jamais modifié. La revue se fait par diff :

```bash
diff -u upstream/post-pve-install.sh post-pve-install.sh
```

7 hunks, **17 lignes de code retirées et 33 ajoutées** (dont 19 pour deux fonctions autonomes ajoutées).
Tout le reste n'est que du commentaire. Chaque divergence porte un marqueur `FORK:` :

```bash
grep -n 'FORK' post-pve-install.sh          # 14 occurrences
grep -nE 'curl|wget|api\.func' post-pve-install.sh   # uniquement dans les commentaires
bash -n post-pve-install.sh                 # contrôle de syntaxe
```

L'historique git est le changelog : un commit par modification, avec sa justification.

```bash
git log --oneline
git log -p -- post-pve-install.sh
```

## Les 7 modifications

| # | Modification | Pourquoi |
|---|---|---|
| **M1** | Suppression du `source <(curl …/misc/api.func)` et de `init_tool_telemetry` | Exécutait ~1 200 lignes de code distant **non épinglé** en root à chaque lancement, et posait un `trap … EXIT`. L'envoi vers `telemetry.community-scripts.org` était déjà opt-in (`DIAGNOSTICS=yes`, absent d'une install neuve) — c'est le `source` distant qui posait problème, pas la télémétrie. Aucun autre appelant : suppression pure. |
| **M2** | Le nag est patché explicitement, plus de hook `DPkg::Post-Invoke` | Amont écrivait `/etc/apt/apt.conf.d/no-nag-script`, qui réexécutait le patch après **chaque** opération dpkg, indéfiniment. Voir le piège d'ordonnancement ci-dessous. |
| **M3** | `preflight()` : root / `pveversion` / `whiptail` | L'original supposait ces conditions et échouait obscurément sinon (permission-denied en plein milieu de la réécriture de `/etc/apt`). Aucun changement de comportement une fois remplies. |
| **M4** | `non-free-firmware` ajouté aux `Components` du deb822 généré | PVE 9 livre `main non-free-firmware` par défaut ; amont écrivait `main contrib`, perdant `amd64-microcode` et les paquets `firmware-*`. Filet de sécurité : cette branche ne s'exécute que si aucun `*.sources` n'existe. |
| **M5** | Détection du dépôt Ceph par URI au lieu du nom de composant | **Bug amont** : `\bno-subscription\b` matche aussi `pve-no-subscription` (le `-` est une frontière de mot). Comme `proxmox.sources` est créé plus haut dans la même exécution, la question Ceph était **toujours** sautée, avec un message faussement rassurant. |
| **M6** | `_fork_on_exit` : message clair sur ESC/Annuler | Les 20 prompts sont des `CHOICE=$(whiptail …)` ; ESC renvoie ≠ 0 et sous `set -e` tuait le script en silence, sans indiquer ce qui avait déjà été appliqué. Le handler ne fait qu'afficher. |
| **M7** | En-tête `FORK NOTICE`, `upstream/`, `LICENSE`, ce README | Traçabilité. Copyright MIT et attribution `tteck | MickLesk (CanbiZ)` conservés. |

### Le piège d'ordonnancement du nag (M2)

Retirer le hook n'est pas une simple suppression. Dans l'original,
`apt --reinstall install proxmox-widget-toolkit` est exécuté **inconditionnellement** juste après la
branche nag, et restaure le `proxmoxlib.js` d'origine. C'est le hook `DPkg::Post-Invoke` qui re-patchait
derrière. Supprimer le hook seul aurait donc silencieusement fait revenir le bandeau.

Le fork appelle donc `/usr/local/bin/pve-remove-nag.sh` **après** le réinstall. Le script lui-même est
inchangé et idempotent (il teste `NoMoreNagging` et le marqueur mobile avant d'écrire).

**Contrepartie assumée** : sans hook, une mise à jour future de `proxmox-widget-toolkit` fera revenir le
bandeau. C'était le prix demandé pour ne pas laisser de hook APT permanent. Pour le remettre :

```bash
/usr/local/bin/pve-remove-nag.sh     # idempotent, relançable à volonté
# puis Ctrl+Shift+R dans le navigateur
```

## Utilisation

**Ne pas** faire `curl … | bash` — cela annule tout l'intérêt de la démarche.

```bash
# sauvegarde préalable (couvre les branches sans backup, voir Limites connues)
tar czf /root/etc-apt-$(date +%F).tgz /etc/apt

# depuis le poste de travail
scp post-pve-install.sh root@<pve>:/root/

# sur l'hôte
bash /root/post-pve-install.sh
```

Versions supportées (inchangé vs amont) : **PVE 8.0–8.9** et **9.0–9.2**.

## Idempotence

Le script est relançable. Ce qui l'était déjà en amont : tous les `cat > fichier` (contenu fixe),
`pve-remove-nag.sh` (gardes `grep`), `systemctl enable/disable --now`, la branche « legacy sources » 9.x,
l'ajout de `Enabled: false`. Ce que le fork ajoute : `rm -f` sur le hook (au lieu de `[[ -f ]] && rm`),
et l'appel au patch nag conditionné à la réponse.

Contrôles après un passage — les compteurs doivent rester à `1` après un second lancement :

```bash
test ! -e /etc/apt/apt.conf.d/no-nag-script && echo "aucun hook APT: OK"
grep -c NoMoreNagging /usr/share/javascript/proxmox-widget-toolkit/proxmoxlib.js   # 1
grep -c 'MANAGED BLOCK FOR MOBILE NAG' /usr/share/pve-yew-mobile-gui/index.html.tpl # 1
systemctl is-enabled pve-ha-lrm pve-ha-crm     # disabled
apt update                                      # aucun avertissement
```

## Limites connues (non corrigées — hors périmètre « divergence minimale »)

- **`cat > /etc/apt/sources.list` sans sauvegarde** (branche 8.x) et
  **`rm -f /etc/apt/sources.list.d/*.list`** (branche 9.x). La branche 9.x concernée est sautée dès qu'un
  `*.sources` existe, donc inatteignable sur une PVE 9 fraîche. Mitigé par le `tar` préalable ci-dessus.
- **`echo "Enabled: false" >> fichier`** : dans un `.sources` multi-strophes, l'ajout se rattache à la
  dernière strophe, pas forcément à celle qui a matché. Inoffensif sur les fichiers mono-strophe générés
  par Proxmox.
- **`grep … /etc/apt/sources.list.d/*.sources` avec `nullglob`** (helper `component_exists_in_sources`,
  bloc ceph-enterprise) : si aucun `.sources` n'existe, le glob disparaît et `grep` lit stdin → blocage
  possible. Non atteignable sur PVE 9. La ligne du M5 utilise l'idiome robuste `… *.sources /dev/null`.
- **Branche 8.x** laissée telle quelle : la cible ici est PVE 9. Le M4 n'y est pas appliqué.

## Variante minimale non-interactive

`pve9-postinstall-minimal.sh` applique directement l'équivalent de « oui à tout », sur les specs réelles
de la machine : **PVE 9 (trixie), nœud unique, pas de souscription, pas de Ceph**. Pas de whiptail, pas de
couleurs, pas de fonctions. 63 lignes dont 29 de shell — le reste étant le bloc JS de l'UI mobile.

```bash
tar czf /root/etc-apt-$(date +%F).tgz /etc/apt     # sauvegarde
scp pve9-postinstall-minimal.sh root@<pve>:/root/
bash /root/pve9-postinstall-minimal.sh
```

Il fait 7 choses : désactive les dépôts `enterprise.proxmox.com` (`pve-enterprise.sources` **et**
`ceph.sources`, en une boucle), ajoute `pve-no-subscription`, ajoute `contrib` à `debian.sources`,
désactive HA et Corosync, met à jour, installe `amd64-microcode` + `firmware-amd-graphics`, puis retire le
nag sur les deux UI. Il finit par un rappel — **pas** de reboot automatique.

### Ce qui a été écarté par rapport à « oui à tout »

| Étape de l'original | Pourquoi écartée |
|---|---|
| Migration deb822 des sources | La branche est sautée dès qu'un `*.sources` existe — le cas sur une PVE 9 fraîche. Zéro effet. |
| Dépôt Ceph no-subscription | Nœud unique sans Ceph : un dépôt de plus à interroger à chaque `apt update`, pour rien. |
| Dépôt `pve-test` | L'original l'ajoute avec `Enabled: false` : un fichier sans aucun effet. |
| `apt --reinstall proxmox-widget-toolkit` | Ne servait qu'à déclencher le hook APT, ou à restaurer le fichier si on répondait « non ». En répondant « oui », c'est du travail annulé aussitôt. |
| « Activer HA » puis « désactiver HA » | L'original demande les deux successivement ; sur un nœud unique on désactive, point. |

### Ordre imposé

Les patches du nag sont **les dernières actions**, après le `dist-upgrade` : `proxmoxlib.js` appartient à
`proxmox-widget-toolkit` et `index.html.tpl` à `pve-yew-mobile-gui`, donc toute mise à jour de ces paquets
annule le patch. C'est la même cause que le piège décrit plus haut pour le fork.

### Limites

- La boucle de désactivation suppose des `.sources` **mono-strophe** — le cas de ceux que livre Proxmox.
  Sur un fichier multi-strophes, `sed '/^Enabled:/d'` retirerait toutes les lignes `Enabled:`.
- `trixie` et `pve-no-subscription` sont figés : script spécifique à PVE 9, par conception. Le fork reste
  la version portable 8.x/9.x, d'où la garde `VERSION_CODENAME=trixie` en tête.
- Les sélecteurs CSS du bloc mobile sont ceux de l'amont et dépendent du build de l'UI mobile PVE. Une
  refonte de cette UI les invaliderait silencieusement : le bloc cesserait d'agir sans rien casser.
- Le nag revient après une mise à jour de `proxmox-widget-toolkit` ou `pve-yew-mobile-gui` — relancer le
  script, il est idempotent. C'est le prix choisi pour ne pas poser de hook APT.
- Écart volontaire vis-à-vis de l'amont : le `clearInterval` manquant a été ajouté. L'original coupe son
  `MutationObserver` au bout de 10 s mais laisse tourner un `setInterval(…, 300)` indéfiniment dans le
  navigateur.

### Idempotence — testée sur fixtures

Les transformations ont été rejouées hors hôte contre une arborescence PVE 9 reconstituée
(`debian.sources` en `main non-free-firmware`, `pve-enterprise.sources` et `ceph.sources` sur
`enterprise.proxmox.com`, un `proxmoxlib.js` réaliste), en deux passages, sur trois variantes : nominale,
`contrib` + `Enabled: true` déjà présents, et UI mobile absente. Résultat : second passage sans aucune
modification, `Enabled: false` et `NoMoreNagging` en un seul exemplaire, `contrib` jamais dupliqué, et
no-op propre quand `index.html.tpl` n'existe pas.

## À faire après le fork (spécifique à la machine)

Inutile si tu as lancé `pve9-postinstall-minimal.sh`, qui s'en charge. Après le fork en revanche —
T-BAO R3 Pro, Ryzen 7 5700U, iGPU Vega :

```bash
grep Components /etc/apt/sources.list.d/debian.sources   # doit contenir non-free-firmware
apt install amd64-microcode firmware-amd-graphics
```

## Licence

MIT, conservée depuis l'amont — voir [`LICENSE`](LICENSE). Crédit : tteck / tteckster, MickLesk (CanbiZ)
et la communauté community-scripts.

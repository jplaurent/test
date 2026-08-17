# post-pve-install.sh — fork durci

Fork de [`tools/pve/post-pve-install.sh`](https://github.com/community-scripts/ProxmoxVE/blob/main/tools/pve/post-pve-install.sh)
du projet **community-scripts/ProxmoxVE**, épinglé sur le commit
[`fb1d670`](https://github.com/community-scripts/ProxmoxVE/commit/fb1d670158ba68a41397ce4f21c3b6444c1a76d4)
(2026-08-06, md5 `cb32f577bc9aeb730e447faa74e52732`, 698 lignes).

Objectif : pouvoir **lancer le script sans crainte** sur un hôte Proxmox VE personnel — donc pas de code
distant exécuté en root, pas de hook APT permanent, et une divergence assez faible pour être relue en
entier d'un coup d'œil.

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

## À faire après le script (spécifique à la machine)

T-BAO R3 Pro — Ryzen 7 5700U, iGPU Vega :

```bash
grep Components /etc/apt/sources.list.d/debian.sources   # doit contenir non-free-firmware
apt install amd64-microcode firmware-amd-graphics
```

## Licence

MIT, conservée depuis l'amont — voir [`LICENSE`](LICENSE). Crédit : tteck / tteckster, MickLesk (CanbiZ)
et la communauté community-scripts.

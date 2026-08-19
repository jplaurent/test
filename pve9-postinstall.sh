#!/usr/bin/env bash
# Post-install Proxmox VE 9, non interactif - noeud unique, sans souscription.
# Equivalent de "oui a tout" sur community-scripts/post-pve-install.sh, sans les
# etapes qui n'ont aucun effet ici. Idempotent, et ne supprime jamais rien.
set -euo pipefail
shopt -s nullglob

D=/etc/apt/sources.list.d
SL=/etc/apt/sources.list
WEB_JS=/usr/share/javascript/proxmox-widget-toolkit/proxmoxlib.js
MOBILE_TPL=/usr/share/pve-yew-mobile-gui/index.html.tpl

if [[ -t 1 ]]; then B=$'\e[1m' G=$'\e[32m' Y=$'\e[33m' N=$'\e[0m'; else B='' G='' Y='' N=''; fi
step() { echo "${B}==> $*${N}"; }
ok() { echo "    ${G}ok${N}   $*"; }
skip() { echo "    --   $*"; }
warn() { echo "    ${Y}!!${N}   $*" >&2; }
trap 'warn "echec ligne $LINENO - rien au-dela de ce point n a ete applique"' ERR

[[ $EUID -eq 0 ]] || {
  echo "erreur : a lancer en root" >&2
  exit 1
}
grep -q 'VERSION_CODENAME=trixie' /etc/os-release || {
  echo "erreur : ce script est specifique a Debian 13 (trixie) / PVE 9" >&2
  exit 1
}
command -v pveversion >/dev/null || {
  echo "erreur : pveversion introuvable, ce n est pas un hote Proxmox VE" >&2
  exit 1
}
step "$(pveversion | cut -d/ -f1,2 | tr / ' ') - $HOSTNAME"

# ------------------------------------------------------------------ depots APT
step "Depots APT"

# Desactive les depots reserves aux abonnes : pve-enterprise.sources ET ceph.sources.
for f in "$D"/*.sources; do
  [[ -f $f ]] || continue
  grep -q 'enterprise\.proxmox\.com' "$f" || continue
  if grep -qx 'Enabled: false' "$f"; then
    skip "$(basename "$f") deja desactive"
  else
    sed -i '/^Enabled:/d' "$f"
    echo 'Enabled: false' >>"$f"
    ok "$(basename "$f") desactive"
  fi
done

cat >"$D/proxmox.sources" <<'EOF'
Types: deb
URIs: http://download.proxmox.com/debian/pve
Suites: trixie
Components: pve-no-subscription
Signed-By: /usr/share/keyrings/proxmox-archive-keyring.gpg
EOF
ok "pve-no-subscription ecrit dans proxmox.sources"

# contrib pour les scripts communautaires, non-free-firmware pour microcode et iGPU.
if [[ -f $D/debian.sources ]]; then
  before=$(md5sum <"$D/debian.sources")
  sed -i '/^Components:/{/contrib/!s/$/ contrib/}' "$D/debian.sources"
  sed -i '/^Components:/{/non-free-firmware/!s/$/ non-free-firmware/}' "$D/debian.sources"
  if [[ $(md5sum <"$D/debian.sources") == "$before" ]]; then
    skip "debian.sources : $(grep -m1 '^Components:' "$D/debian.sources")"
  else
    ok "debian.sources : $(grep -m1 '^Components:' "$D/debian.sources")"
  fi
else
  warn "$D/debian.sources absent - composants Debian non verifies"
fi

# Legacy : on commente sources.list (avec sauvegarde), on ne SUPPRIME aucun .list.
if [[ -f $SL ]] && grep -qE '^\s*deb ' "$SL"; then
  # Test explicite plutot que `cp -n` : le code de retour de -n quand la cible
  # existe a varie selon les versions de coreutils, et sous set -e on ne veut
  # pas en dependre. Ne jamais ecraser une sauvegarde deja presente.
  [[ -e $SL.bak ]] || cp "$SL" "$SL.bak"
  sed -i '/^\s*deb /s/^/# /' "$SL"
  ok "entrees actives commentees dans $SL (sauvegarde $SL.bak)"
fi
legacy=("$D"/*.list)
if ((${#legacy[@]})); then
  warn "${#legacy[@]} fichier(s) .list legacy, NON touches - a revoir a la main :"
  printf '            %s\n' "${legacy[@]}" >&2
fi

# Hook APT laisse par un passage du script communautaire : signale, jamais retire.
# Ce script n'en pose aucun ; si tu l'as installe volontairement, c'est ton choix.
if [[ -e /etc/apt/apt.conf.d/no-nag-script ]]; then
  warn "hook APT /etc/apt/apt.conf.d/no-nag-script present (pose par le script"
  warn "communautaire). Il repatche le nag apres chaque operation dpkg."
  warn "Pour le retirer : rm /etc/apt/apt.conf.d/no-nag-script"
fi

# ------------------------------------------------------------------ noeud seul
step "Noeud unique : HA et Corosync"
for u in pve-ha-lrm pve-ha-crm corosync; do
  state=$(systemctl is-enabled "$u" 2>/dev/null || true)
  case ${state:-absent} in
  absent) warn "$u : unite absente, ignore" ;;
  disabled | masked) skip "$u deja $state" ;;
  *)
    if systemctl disable --now "$u" &>/dev/null; then
      ok "$u desactive ($state -> disabled)"
    else
      warn "$u : echec de la desactivation"
    fi
    ;;
  esac
done

# ------------------------------------------------------------------- mise a jour
step "Mise a jour du systeme"
apt update
apt -y dist-upgrade

# ------------------------------------------------------- microcode et firmware
# NE JAMAIS installer les paquets firmware-* de Debian sur un hote Proxmox VE.
# pve-firmware declare Conflicts ET Replaces sur firmware-amd-graphics,
# firmware-iwlwifi, firmware-realtek et une vingtaine d'autres. apt resout le
# conflit en retirant pve-firmware, ce qui entraine proxmox-default-kernel puis
# proxmox-ve : le pve-apt-hook officiel avorte alors toute la transaction.
# Le Replaces dit l'essentiel : ces blobs sont deja fournis par pve-firmware,
# donc il n'y a rien a installer. amd64-microcode, lui, n'est pas en conflit.
step "Microcode"
# dpkg-query sur le Status, pas `dpkg -s` : ce dernier renvoie 0 aussi pour un
# paquet retire dont les fichiers de conf subsistent (deinstall ok config-files),
# ce qui donnerait un faux "present" sur le controle le plus important du script.
if [[ $(dpkg-query -W -f='${Status}' pve-firmware 2>/dev/null) == 'install ok installed' ]]; then
  ok "pve-firmware present : blobs GPU / Wi-Fi / Ethernet deja fournis"
else
  warn "pve-firmware non installe - installation Proxmox inhabituelle, a verifier a la main"
fi
apt -y install amd64-microcode

# --------------------------------------------------------------------- le nag
# En dernier : proxmoxlib.js appartient a proxmox-widget-toolkit et index.html.tpl
# a pve-yew-mobile-gui. Toute mise a jour ci-dessus annulerait le patch.
step "Bandeau de souscription"
if [[ ! -f $WEB_JS ]]; then
  warn "$WEB_JS absent - UI desktop non patchee"
elif grep -q NoMoreNagging "$WEB_JS"; then
  skip "UI desktop deja patchee"
else
  sed -i -e '/data\.status/ s/!//' -e '/data\.status/ s/active/NoMoreNagging/' "$WEB_JS"
  if grep -q NoMoreNagging "$WEB_JS"; then
    ok "UI desktop patchee"
  else
    warn "UI desktop : motif data.status introuvable, rien patche (format amont modifie ?)"
  fi
fi

if [[ ! -f $MOBILE_TPL ]]; then
  skip "UI mobile absente (pve-yew-mobile-gui non installe)"
elif grep -q NoMoreNagging "$MOBILE_TPL"; then
  skip "UI mobile deja patchee"
else
  cat >>"$MOBILE_TPL" <<'EOF'
<!-- NoMoreNagging -->
<script>
  const strip = () => {
    document.querySelectorAll('dialog.pwt-outer-dialog').forEach(d => {
      if ((d.textContent || '').toLowerCase().includes('subscription')) d.remove();
    });
    document.querySelectorAll('.pwt-card.pwt-p-2.pwt-d-flex.pwt-interactive.pwt-justify-content-center').forEach(c => {
      if (!c.querySelector('button') && (c.textContent || '').toLowerCase().includes('subscription')) c.remove();
    });
  };
  const obs = new MutationObserver(strip);
  obs.observe(document.body, { childList: true, subtree: true });
  strip();
  const iv = setInterval(strip, 300);
  setTimeout(() => { obs.disconnect(); clearInterval(iv); }, 10000);
</script>
EOF
  ok "UI mobile patchee"
fi

step "Termine"
echo "    reboot recommande, puis Ctrl+Shift+R dans le navigateur"

#!/usr/bin/env bash
# Minimal non-interactive Proxmox VE 9 post-install: single node, no subscription.
# Equivalent to answering "yes" to everything in community-scripts/post-pve-install.sh,
# minus every step that is a no-op or dead weight here. Idempotent: safe to re-run.
set -euo pipefail
shopt -s nullglob

[[ $(id -u) == 0 ]] || { echo "must run as root" >&2; exit 1; }
grep -q 'VERSION_CODENAME=trixie' /etc/os-release || { echo "expects Debian 13 / PVE 9" >&2; exit 1; }

# Disable the subscription-only repos: pve-enterprise.sources and ceph.sources.
for f in /etc/apt/sources.list.d/*.sources; do
  grep -q 'enterprise\.proxmox\.com' "$f" || continue
  sed -i '/^Enabled:/d' "$f"
  echo 'Enabled: false' >>"$f"
done

# Add pve-no-subscription.
cat >/etc/apt/sources.list.d/proxmox.sources <<'EOF'
Types: deb
URIs: http://download.proxmox.com/debian/pve
Suites: trixie
Components: pve-no-subscription
Signed-By: /usr/share/keyrings/proxmox-archive-keyring.gpg
EOF

# Add contrib; PVE 9 ships "Components: main non-free-firmware".
sed -i '/^Components:/{/contrib/!s/$/ contrib/}' /etc/apt/sources.list.d/debian.sources

# Single node: no HA, no cluster.
systemctl disable -q --now pve-ha-lrm pve-ha-crm corosync

apt update
apt -y dist-upgrade
apt -y install amd64-microcode firmware-amd-graphics

# Nag removal goes last: the upgrades above own both files and would undo it.
W=/usr/share/javascript/proxmox-widget-toolkit/proxmoxlib.js
grep -q NoMoreNagging "$W" || sed -i -e '/data\.status/ s/!//' -e '/data\.status/ s/active/NoMoreNagging/' "$W"

M=/usr/share/pve-yew-mobile-gui/index.html.tpl
if [[ -f $M ]] && ! grep -q NoMoreNagging "$M"; then
  cat >>"$M" <<'EOF'
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
fi

echo "done - reboot recommended; hard-reload the web UI (Ctrl+Shift+R)"

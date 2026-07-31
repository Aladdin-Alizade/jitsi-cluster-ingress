#!/usr/bin/env bash
# Mövcud meet-control-a Prosody→portal live sync quraşdır (redeploy olmadan).
# .env + terraform outputs + PORTAL_UPLOAD_META_* lazımdır.
#
#   ./scripts/install-live-sync.sh

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "${ROOT}"

if [[ ! -f "${ROOT}/.env" ]]; then
  echo ".env lazımdır"
  exit 1
fi
set -a
# shellcheck disable=SC1091
source "${ROOT}/.env"
set +a

: "${GCP_PROJECT_ID:?}"
: "${GCP_ZONE:?}"
: "${PORTAL_UPLOAD_META_URL:?PORTAL_UPLOAD_META_URL .env-də lazımdır}"
: "${PORTAL_UPLOAD_META_TOKEN:?PORTAL_UPLOAD_META_TOKEN .env-də lazımdır}"
DOMAIN="${DOMAIN:-}"

OUTPUTS_JSON="${ROOT}/terraform/generated/outputs.json"
[[ -f "${OUTPUTS_JSON}" ]] || { echo "outputs.json yoxdur — əvvəl deploy"; exit 1; }
CONTROL_PUBLIC_IP="$(jq -r '.control_public_ip' "${OUTPUTS_JSON}")"

if [[ -n "${SSH_PUBLIC_KEY_PATH:-}" && -f "${SSH_PUBLIC_KEY_PATH}" ]]; then
  SSH_PRIV="${SSH_PUBLIC_KEY_PATH%.pub}"
else
  SSH_PRIV="${ROOT}/secrets/deploy_key"
fi
[[ -f "${SSH_PRIV}" ]] || { echo "SSH private key yoxdur: ${SSH_PRIV}"; exit 1; }

ssh_opts=(
  -o BatchMode=yes
  -o StrictHostKeyChecking=no
  -o UserKnownHostsFile=/dev/null
  -o GlobalKnownHostsFile=/dev/null
  -o ConnectTimeout=15
  -i "${SSH_PRIV}"
)

echo "[+] active-rooms + live-notify + muc_size + cron..."
scp -q "${ssh_opts[@]}" \
  "${ROOT}/scripts/active-rooms.sh" \
  "${ROOT}/scripts/live-notify.sh" \
  "ubuntu@${CONTROL_PUBLIC_IP}:/tmp/"

ssh "${ssh_opts[@]}" "ubuntu@${CONTROL_PUBLIC_IP}" "sudo bash -s" <<REMOTE
set -euo pipefail
install -m 755 /tmp/active-rooms.sh /opt/jitsi-cluster/active-rooms.sh
install -m 755 /tmp/live-notify.sh /opt/jitsi-cluster/live-notify.sh

# cluster.env-ə portal meta (əgər yoxdursa)
ENVF=/opt/jitsi-cluster/cluster.env
touch "\${ENVF}"
grep -q '^PORTAL_UPLOAD_META_URL=' "\${ENVF}" 2>/dev/null \
  && sed -i 's|^PORTAL_UPLOAD_META_URL=.*|PORTAL_UPLOAD_META_URL=${PORTAL_UPLOAD_META_URL}|' "\${ENVF}" \
  || echo "PORTAL_UPLOAD_META_URL=${PORTAL_UPLOAD_META_URL}" >> "\${ENVF}"
grep -q '^PORTAL_UPLOAD_META_TOKEN=' "\${ENVF}" 2>/dev/null \
  && sed -i 's|^PORTAL_UPLOAD_META_TOKEN=.*|PORTAL_UPLOAD_META_TOKEN=${PORTAL_UPLOAD_META_TOKEN}|' "\${ENVF}" \
  || echo "PORTAL_UPLOAD_META_TOKEN=${PORTAL_UPLOAD_META_TOKEN}" >> "\${ENVF}"
chmod 600 "\${ENVF}"

# muc_size modul
DOMAIN_CFG="${DOMAIN}"
PROSODY_CFG="/etc/prosody/conf.avail/\${DOMAIN_CFG}.cfg.lua"
if [[ -f "\${PROSODY_CFG}" ]] && ! grep -q '"muc_size"' "\${PROSODY_CFG}"; then
  sed -i '/modules_enabled = {/a\\        "muc_size";' "\${PROSODY_CFG}" || true
  systemctl reload prosody || systemctl restart prosody || true
fi

mkdir -p /var/log/jitsi /var/lib/jitsi-cluster
touch /var/log/jitsi/live-notify.log
cat > /etc/cron.d/jitsi-live-sync <<'CRON'
PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
SHELL=/bin/bash
* * * * * root /opt/jitsi-cluster/live-notify.sh >>/var/log/jitsi/live-notify.log 2>&1
CRON
chmod 644 /etc/cron.d/jitsi-live-sync
systemctl enable --now cron 2>/dev/null || true

echo "=== active-rooms sample ==="
/opt/jitsi-cluster/active-rooms.sh --pretty || /opt/jitsi-cluster/active-rooms.sh || true
echo "=== one-shot sync ==="
/opt/jitsi-cluster/live-notify.sh || true
echo "[+] live-sync installed"
REMOTE

echo "[+] Hazır. Hər dəqiqə Prosody → portal /api/jitsi/sync-live/"

#!/usr/bin/env bash
# Mövcud meet-control-a Prosody→portal live sync quraşdır (redeploy olmadan).
# .env + PORTAL_UPLOAD_META_* lazımdır.
#
# Cloud Shell / lokal:
#   ./scripts/install-live-sync.sh
#
# Prefer: gcloud compute scp/ssh (IAM). Fallback: secrets/deploy_key.

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
CONTROL_INSTANCE="${CONTROL_INSTANCE:-meet-control}"

OUTPUTS_JSON="${ROOT}/terraform/generated/outputs.json"
CONTROL_PUBLIC_IP=""
if [[ -f "${OUTPUTS_JSON}" ]]; then
  CONTROL_PUBLIC_IP="$(jq -r '.control_public_ip // empty' "${OUTPUTS_JSON}" 2>/dev/null || true)"
fi

if [[ -n "${SSH_PUBLIC_KEY_PATH:-}" && -f "${SSH_PUBLIC_KEY_PATH}" ]]; then
  SSH_PRIV="${SSH_PUBLIC_KEY_PATH%.pub}"
else
  SSH_PRIV="${ROOT}/secrets/deploy_key"
fi

ssh_opts=(
  -o BatchMode=yes
  -o StrictHostKeyChecking=no
  -o UserKnownHostsFile=/dev/null
  -o GlobalKnownHostsFile=/dev/null
  -o ConnectTimeout=15
)
if [[ -f "${SSH_PRIV}" ]]; then
  ssh_opts+=(-i "${SSH_PRIV}")
fi

USE_GCLOUD=0
if command -v gcloud >/dev/null 2>&1; then
  # Prefer live IP from GCP (outputs.json köhnə ola bilər)
  LIVE_IP="$(gcloud compute instances describe "${CONTROL_INSTANCE}" \
    --zone="${GCP_ZONE}" --project="${GCP_PROJECT_ID}" \
    --format='get(networkInterfaces[0].accessConfigs[0].natIP)' 2>/dev/null || true)"
  if [[ -n "${LIVE_IP}" ]]; then
    CONTROL_PUBLIC_IP="${LIVE_IP}"
  fi
  STATUS="$(gcloud compute instances describe "${CONTROL_INSTANCE}" \
    --zone="${GCP_ZONE}" --project="${GCP_PROJECT_ID}" \
    --format='get(status)' 2>/dev/null || true)"
  if [[ "${STATUS}" != "RUNNING" ]]; then
    echo "[!] ${CONTROL_INSTANCE} status=${STATUS:-unknown} — start et:"
    echo "    gcloud compute instances start ${CONTROL_INSTANCE} --zone=${GCP_ZONE} --project=${GCP_PROJECT_ID}"
    exit 1
  fi
  USE_GCLOUD=1
fi

if [[ -z "${CONTROL_PUBLIC_IP}" && "${USE_GCLOUD}" -eq 0 ]]; then
  echo "control IP tapılmadı (outputs.json və ya gcloud lazımdır)"
  exit 1
fi

echo "[+] target: ${CONTROL_INSTANCE} ip=${CONTROL_PUBLIC_IP:-via-gcloud} zone=${GCP_ZONE}"

REMOTE_SCRIPT="$(mktemp)"
trap 'rm -f "${REMOTE_SCRIPT}"' EXIT

cat >"${REMOTE_SCRIPT}" <<REMOTE
set -euo pipefail
install -m 755 /tmp/active-rooms.sh /opt/jitsi-cluster/active-rooms.sh
install -m 755 /tmp/live-notify.sh /opt/jitsi-cluster/live-notify.sh

ENVF=/opt/jitsi-cluster/cluster.env
mkdir -p /opt/jitsi-cluster /var/lib/jitsi-cluster /var/log/jitsi
touch "\${ENVF}"
grep -q '^PORTAL_UPLOAD_META_URL=' "\${ENVF}" 2>/dev/null \\
  && sed -i 's|^PORTAL_UPLOAD_META_URL=.*|PORTAL_UPLOAD_META_URL=${PORTAL_UPLOAD_META_URL}|' "\${ENVF}" \\
  || echo "PORTAL_UPLOAD_META_URL=${PORTAL_UPLOAD_META_URL}" >> "\${ENVF}"
grep -q '^PORTAL_UPLOAD_META_TOKEN=' "\${ENVF}" 2>/dev/null \\
  && sed -i 's|^PORTAL_UPLOAD_META_TOKEN=.*|PORTAL_UPLOAD_META_TOKEN=${PORTAL_UPLOAD_META_TOKEN}|' "\${ENVF}" \\
  || echo "PORTAL_UPLOAD_META_TOKEN=${PORTAL_UPLOAD_META_TOKEN}" >> "\${ENVF}"
chmod 600 "\${ENVF}"

DOMAIN_CFG="${DOMAIN}"
PROSODY_CFG="/etc/prosody/conf.avail/\${DOMAIN_CFG}.cfg.lua"
if [[ -f "\${PROSODY_CFG}" ]] && ! grep -q '"muc_size"' "\${PROSODY_CFG}"; then
  sed -i '/modules_enabled = {/a\\        "muc_size";' "\${PROSODY_CFG}" || true
  systemctl reload prosody || systemctl restart prosody || true
fi

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

copy_and_run_gcloud() {
  echo "[+] gcloud compute scp/ssh..."
  gcloud compute scp \
    --zone="${GCP_ZONE}" --project="${GCP_PROJECT_ID}" \
    "${ROOT}/scripts/active-rooms.sh" \
    "${ROOT}/scripts/live-notify.sh" \
    "${CONTROL_INSTANCE}:/tmp/"
  # shellcheck disable=SC2029
  gcloud compute ssh "${CONTROL_INSTANCE}" \
    --zone="${GCP_ZONE}" --project="${GCP_PROJECT_ID}" \
    --command="sudo bash -s" <"${REMOTE_SCRIPT}"
}

copy_and_run_key() {
  [[ -f "${SSH_PRIV}" ]] || { echo "SSH private key yoxdur: ${SSH_PRIV}"; return 1; }
  [[ -n "${CONTROL_PUBLIC_IP}" ]] || { echo "CONTROL_PUBLIC_IP boş"; return 1; }
  echo "[+] scp/ssh via deploy_key → ubuntu@${CONTROL_PUBLIC_IP}..."
  scp -q "${ssh_opts[@]}" \
    "${ROOT}/scripts/active-rooms.sh" \
    "${ROOT}/scripts/live-notify.sh" \
    "ubuntu@${CONTROL_PUBLIC_IP}:/tmp/"
  ssh "${ssh_opts[@]}" "ubuntu@${CONTROL_PUBLIC_IP}" "sudo bash -s" <"${REMOTE_SCRIPT}"
}

ok=0
if [[ "${USE_GCLOUD}" -eq 1 ]]; then
  if copy_and_run_gcloud; then
    ok=1
  else
    echo "[!] gcloud yolu uğursuz — deploy_key yoxlanır..."
  fi
fi
if [[ "${ok}" -eq 0 ]]; then
  copy_and_run_key || {
    echo
    echo "SSH/SCP bağlana bilmədi. Əl ilə Cloud Shell-dən:"
    echo "  gcloud compute instances describe ${CONTROL_INSTANCE} --zone=${GCP_ZONE} --project=${GCP_PROJECT_ID} --format='get(status,networkInterfaces[0].accessConfigs[0].natIP)'"
    echo "  gcloud compute scp --zone=${GCP_ZONE} --project=${GCP_PROJECT_ID} scripts/active-rooms.sh scripts/live-notify.sh ${CONTROL_INSTANCE}:/tmp/"
    echo "  gcloud compute ssh ${CONTROL_INSTANCE} --zone=${GCP_ZONE} --project=${GCP_PROJECT_ID}"
    echo "  # VM-də: sudo install -m 755 /tmp/active-rooms.sh /tmp/live-notify.sh /opt/jitsi-cluster/"
    exit 1
  }
fi

echo "[+] Hazır. Hər dəqiqə Prosody → Telegram Meeting başladı/bitdi (yalnız diff)"

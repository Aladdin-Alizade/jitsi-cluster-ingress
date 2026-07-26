#!/usr/bin/env bash
# Mövcud cluster-ə Telegram alert-ləri quraşdır (tam redeploy olmadan).
# .env-də TELEGRAM_BOT_TOKEN + TELEGRAM_CHAT_ID olmalıdır.
#
#   ./scripts/install-telegram-alerts.sh

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
: "${TELEGRAM_BOT_TOKEN:?TELEGRAM_BOT_TOKEN .env-də lazımdır}"
: "${TELEGRAM_CHAT_ID:?TELEGRAM_CHAT_ID .env-də lazımdır}"
TELEGRAM_TOPIC_ID="${TELEGRAM_TOPIC_ID:-}"
TELEGRAM_NOTIFY="${TELEGRAM_NOTIFY:-true}"
DOMAIN="${DOMAIN:-}"
GCP_REGION="${GCP_REGION:-europe-west1}"
ENABLE_SCHEDULE="${ENABLE_SCHEDULE:-true}"

OUTPUTS_JSON="${ROOT}/terraform/generated/outputs.json"
[[ -f "${OUTPUTS_JSON}" ]] || { echo "outputs.json yoxdur — əvvəl deploy"; exit 1; }

CONTROL_PUBLIC_IP="$(jq -r '.control_public_ip' "${OUTPUTS_JSON}")"
JVB_PRIVATE_IP="$(jq -r '.jvb_private_ip' "${OUTPUTS_JSON}")"
JIBRI_PER_VM="$(jq -r '.jibri_per_vm // 5' "${OUTPUTS_JSON}")"
mapfile -t JIBRI_PRIVATE_IPS < <(jq -r '.jibri_private_ips[]?' "${OUTPUTS_JSON}")
RECORDER_IPS_CSV="$(IFS=,; echo "${JIBRI_PRIVATE_IPS[*]}")"

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
JUMP_OPTS=(
  -o "ProxyCommand=ssh -o BatchMode=yes -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o GlobalKnownHostsFile=/dev/null -i ${SSH_PRIV} -W %h:%p ubuntu@${CONTROL_PUBLIC_IP}"
)

echo "[+] Control-a telegram + health quraşdırılır..."
scp -q "${ssh_opts[@]}" \
  "${ROOT}/scripts/telegram-notify.sh" \
  "${ROOT}/scripts/health-notify.sh" \
  "ubuntu@${CONTROL_PUBLIC_IP}:/tmp/"
scp -q "${ssh_opts[@]}" "${SSH_PRIV}" "ubuntu@${CONTROL_PUBLIC_IP}:/tmp/deploy_key"

ssh "${ssh_opts[@]}" "ubuntu@${CONTROL_PUBLIC_IP}" "sudo bash -s" <<REMOTE
set -euo pipefail
mkdir -p /opt/jitsi-cluster /var/lib/jitsi-cluster /var/log/jitsi
install -m 755 /tmp/telegram-notify.sh /opt/jitsi-cluster/telegram-notify.sh
install -m 755 /tmp/health-notify.sh /opt/jitsi-cluster/health-notify.sh
mv /tmp/deploy_key /opt/jitsi-cluster/deploy_key
chmod 600 /opt/jitsi-cluster/deploy_key
chown root:root /opt/jitsi-cluster/deploy_key

cat > /opt/jitsi-cluster/telegram.env <<EOF
TELEGRAM_BOT_TOKEN=${TELEGRAM_BOT_TOKEN}
TELEGRAM_CHAT_ID=${TELEGRAM_CHAT_ID}
TELEGRAM_TOPIC_ID=${TELEGRAM_TOPIC_ID}
TELEGRAM_NOTIFY=${TELEGRAM_NOTIFY}
EOF
chmod 600 /opt/jitsi-cluster/telegram.env

# cluster.env-ə telegram + recorder IP-ləri merge
touch /opt/jitsi-cluster/cluster.env
chmod 600 /opt/jitsi-cluster/cluster.env
for key in TELEGRAM_BOT_TOKEN TELEGRAM_CHAT_ID TELEGRAM_TOPIC_ID TELEGRAM_NOTIFY JIBRI_PER_VM RECORDER_PRIVATE_IPS JVB_PRIVATE_IP DOMAIN; do
  sed -i "/^\${key}=/d" /opt/jitsi-cluster/cluster.env 2>/dev/null || true
done
cat >> /opt/jitsi-cluster/cluster.env <<EOF
DOMAIN=${DOMAIN}
JVB_PRIVATE_IP=${JVB_PRIVATE_IP}
JIBRI_PER_VM=${JIBRI_PER_VM}
RECORDER_PRIVATE_IPS=${RECORDER_IPS_CSV}
TELEGRAM_BOT_TOKEN=${TELEGRAM_BOT_TOKEN}
TELEGRAM_CHAT_ID=${TELEGRAM_CHAT_ID}
TELEGRAM_TOPIC_ID=${TELEGRAM_TOPIC_ID}
TELEGRAM_NOTIFY=${TELEGRAM_NOTIFY}
EOF

cat > /etc/cron.d/jitsi-health-notify <<'CRON'
PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
SHELL=/bin/bash
*/5 * * * * root /opt/jitsi-cluster/health-notify.sh >>/var/log/jitsi/health-notify.log 2>&1
CRON
chmod 644 /etc/cron.d/jitsi-health-notify
touch /var/log/jitsi/health-notify.log
# köhnə shell-state faylı
rm -f /var/lib/jitsi-cluster/health-state
systemctl enable --now cron 2>/dev/null || true

# jq/curl health + telegram üçün
command -v jq >/dev/null || apt-get install -y -qq jq >/dev/null 2>&1 || true
command -v curl >/dev/null || apt-get install -y -qq curl >/dev/null 2>&1 || true

/opt/jitsi-cluster/telegram-notify.sh "Jitsi Telegram alerts installed on meet-control (${DOMAIN})"
REMOTE

echo "[+] Recorder-lərə telegram-notify + env..."
for ip in "${JIBRI_PRIVATE_IPS[@]}"; do
  [[ -n "${ip}" ]] || continue
  echo "  → ${ip}"
  scp -q "${ssh_opts[@]}" "${JUMP_OPTS[@]}" \
    "${ROOT}/scripts/telegram-notify.sh" \
    "${ROOT}/scripts/bunny-upload.sh" \
    "${ROOT}/scripts/finalize_recording.sh" \
    "ubuntu@${ip}:/tmp/" || { echo "scp fail ${ip}"; continue; }
  ssh "${ssh_opts[@]}" "${JUMP_OPTS[@]}" "ubuntu@${ip}" "sudo bash -s" <<REMOTE
set -euo pipefail
mkdir -p /opt/jitsi-jibri
install -m 755 -o jibri -g jibri /tmp/telegram-notify.sh /opt/jitsi-jibri/telegram-notify.sh
install -m 755 -o jibri -g jibri /tmp/bunny-upload.sh /opt/jitsi-jibri/bunny-upload.sh
install -m 755 -o jibri -g jibri /tmp/finalize_recording.sh /opt/jitsi-jibri/finalize_recording.sh
cat > /opt/jitsi-jibri/telegram.env <<EOF
TELEGRAM_BOT_TOKEN=${TELEGRAM_BOT_TOKEN}
TELEGRAM_CHAT_ID=${TELEGRAM_CHAT_ID}
TELEGRAM_TOPIC_ID=${TELEGRAM_TOPIC_ID}
TELEGRAM_NOTIFY=${TELEGRAM_NOTIFY}
EOF
chmod 600 /opt/jitsi-jibri/telegram.env
chown jibri:jibri /opt/jitsi-jibri/telegram.env
# bunny.env-ə telegram əlavə/yenilə
touch /opt/jitsi-jibri/bunny.env
for key in TELEGRAM_BOT_TOKEN TELEGRAM_CHAT_ID TELEGRAM_TOPIC_ID TELEGRAM_NOTIFY; do
  sed -i "/^\${key}=/d" /opt/jitsi-jibri/bunny.env 2>/dev/null || true
done
cat >> /opt/jitsi-jibri/bunny.env <<EOF
TELEGRAM_BOT_TOKEN=${TELEGRAM_BOT_TOKEN}
TELEGRAM_CHAT_ID=${TELEGRAM_CHAT_ID}
TELEGRAM_TOPIC_ID=${TELEGRAM_TOPIC_ID}
TELEGRAM_NOTIFY=${TELEGRAM_NOTIFY}
EOF
chown jibri:jibri /opt/jitsi-jibri/bunny.env
chmod 600 /opt/jitsi-jibri/bunny.env
rm -f /tmp/telegram-notify.sh /tmp/bunny-upload.sh /tmp/finalize_recording.sh
REMOTE
done

if [[ "${ENABLE_SCHEDULE}" == "true" ]]; then
  echo "[+] Cloud Scheduler Telegram job-ları..."
  # cron strings from .env schedule helpers — reuse deploy logic lightly
  hhmm_to_cron() {
    local t="$1" dow="${2:-*}"
    local hh="${t%%:*}" mm="${t##*:}"
    echo "${mm} ${hh} * * ${dow}"
  }
  SCHEDULE_WEEKDAYS="${SCHEDULE_WEEKDAYS:-1-5}"
  SCHEDULE_START_UTC="${SCHEDULE_START_UTC:-03:30}"
  SCHEDULE_STOP_UTC="${SCHEDULE_STOP_UTC:-06:05}"
  export SCHEDULE_START_CRON="$(hhmm_to_cron "${SCHEDULE_START_UTC}" "${SCHEDULE_WEEKDAYS}")"
  export SCHEDULE_STOP_CRON="$(hhmm_to_cron "${SCHEDULE_STOP_UTC}" "${SCHEDULE_WEEKDAYS}")"
  SCHEDULE_SAT_START_CRON=""
  SCHEDULE_SAT_STOP_CRON=""
  if [[ -n "${SCHEDULE_SAT_START_UTC:-}" && -n "${SCHEDULE_SAT_STOP_UTC:-}" ]]; then
    SCHEDULE_SAT_START_CRON="$(hhmm_to_cron "${SCHEDULE_SAT_START_UTC}" "6")"
    SCHEDULE_SAT_STOP_CRON="$(hhmm_to_cron "${SCHEDULE_SAT_STOP_UTC}" "6")"
  fi
  export GCP_PROJECT_ID GCP_REGION SCHEDULE_START_CRON SCHEDULE_STOP_CRON
  export SCHEDULE_SAT_START_CRON SCHEDULE_SAT_STOP_CRON
  export SCHEDULE_TIMEZONE TELEGRAM_BOT_TOKEN TELEGRAM_CHAT_ID TELEGRAM_TOPIC_ID DOMAIN
  bash "${ROOT}/scripts/install-telegram-scheduler-jobs.sh" || echo "[!] scheduler tg jobs fail"
fi

# test
bash "${ROOT}/scripts/telegram-notify.sh" "Jitsi install-telegram-alerts.sh tamamlandı (${DOMAIN})"
echo "[+] Hazır. Health: hər 5 dəq meet-control-da /var/log/jitsi/health-notify.log"

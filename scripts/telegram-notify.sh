#!/usr/bin/env bash
# Best-effort Telegram mesajı. Token/chat yoxdursa və ya xəta olsa exit 0.
#
# İstifadə:
#   telegram-notify.sh "mesaj"
#   echo "mesaj" | telegram-notify.sh
#
# Env (və ya telegram.env / bunny.env / cluster.env):
#   TELEGRAM_BOT_TOKEN
#   TELEGRAM_CHAT_ID          # qrup/channel: -100...
#   TELEGRAM_TOPIC_ID         # forum topic message_thread_id (optional)
#   TELEGRAM_NOTIFY=true|false

set +e
set +u

_load_telegram_env() {
  local f
  for f in \
    "${TELEGRAM_ENV_FILE:-}" \
    /opt/jitsi-cluster/telegram.env \
    /opt/jitsi-jibri/telegram.env \
    /opt/jitsi-cluster/cluster.env \
    /opt/jitsi-jibri/bunny.env
  do
    [[ -n "${f}" && -f "${f}" ]] || continue
    # shellcheck disable=SC1090
    set -a
    # shellcheck source=/dev/null
    source "${f}" 2>/dev/null
    set +a
  done
}

_load_telegram_env

NOTIFY="${TELEGRAM_NOTIFY:-}"
TOKEN="${TELEGRAM_BOT_TOKEN:-}"
CHAT="${TELEGRAM_CHAT_ID:-}"
TOPIC="${TELEGRAM_TOPIC_ID:-}"

if [[ -z "${TOKEN}" || -z "${CHAT}" ]]; then
  exit 0
fi
if [[ "${NOTIFY}" == "false" || "${NOTIFY}" == "0" || "${NOTIFY}" == "no" ]]; then
  exit 0
fi

MSG="${*:-}"
if [[ -z "${MSG}" ]]; then
  MSG="$(cat 2>/dev/null || true)"
fi
[[ -n "${MSG}" ]] || exit 0

# Telegram limit ~4096
if (( ${#MSG} > 4000 )); then
  MSG="${MSG:0:3990}…"
fi

if [[ -n "${TOPIC}" ]]; then
  BODY="$(jq -nc --arg c "${CHAT}" --arg t "${MSG}" --argjson th "${TOPIC}" \
    '{chat_id:$c,text:$t,message_thread_id:$th,disable_web_page_preview:true}')"
else
  BODY="$(jq -nc --arg c "${CHAT}" --arg t "${MSG}" \
    '{chat_id:$c,text:$t,disable_web_page_preview:true}')"
fi

curl -sS --connect-timeout 8 --max-time 20 \
  -X POST "https://api.telegram.org/bot${TOKEN}/sendMessage" \
  -H "Content-Type: application/json" \
  --data "${BODY}" \
  >/dev/null 2>&1 || true

exit 0

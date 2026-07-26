#!/usr/bin/env bash
# Best-effort Telegram mesajı. Token/chat yoxdursa və ya xəta olsa exit 0.
#
# İstifadə:
#   telegram-notify.sh "mesaj"
#   echo "mesaj" | telegram-notify.sh
#
# Env / fayllar (boş dəyər dolunu əzmir; caller export ən yüksək prioritet):
#   TELEGRAM_BOT_TOKEN, TELEGRAM_CHAT_ID, TELEGRAM_TOPIC_ID, TELEGRAM_NOTIFY

set +e
set +u

_SAVED_TOKEN="${TELEGRAM_BOT_TOKEN:-}"
_SAVED_CHAT="${TELEGRAM_CHAT_ID:-}"
_SAVED_TOPIC="${TELEGRAM_TOPIC_ID:-}"
_SAVED_NOTIFY="${TELEGRAM_NOTIFY:-}"

_apply_tg_line() {
  local line="$1" k v
  [[ -z "${line}" || "${line}" =~ ^[[:space:]]*# ]] && return 0
  [[ "${line}" == TELEGRAM_*=* ]] || return 0
  k="${line%%=*}"
  v="${line#*=}"
  k="${k#"${k%%[![:space:]]*}"}"
  k="${k%"${k##*[![:space:]]}"}"
  v="${v#"${v%%[![:space:]]*}"}"
  v="${v%"${v##*[![:space:]]}"}"
  if [[ "${v}" =~ ^\"(.*)\"$ ]]; then v="${BASH_REMATCH[1]}"; fi
  if [[ "${v}" =~ ^\'(.*)\'$ ]]; then v="${BASH_REMATCH[1]}"; fi
  [[ -n "${v}" ]] || return 0
  case "${k}" in
    TELEGRAM_BOT_TOKEN) TELEGRAM_BOT_TOKEN="${v}" ;;
    TELEGRAM_CHAT_ID) TELEGRAM_CHAT_ID="${v}" ;;
    TELEGRAM_TOPIC_ID) TELEGRAM_TOPIC_ID="${v}" ;;
    TELEGRAM_NOTIFY) TELEGRAM_NOTIFY="${v}" ;;
  esac
}

_load_tg_file() {
  local f="$1" line
  [[ -n "${f}" && -f "${f}" ]] || return 0
  while IFS= read -r line || [[ -n "${line}" ]]; do
    _apply_tg_line "${line}"
  done < "${f}"
}

_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd 2>/dev/null || true)"
# Əvvəl geniş konfiq, sonda dedicated telegram.env
_load_tg_file "${_root}/.env"
_load_tg_file "/opt/jitsi-cluster/cluster.env"
_load_tg_file "/opt/jitsi-jibri/bunny.env"
_load_tg_file "/opt/jitsi-jibri/telegram.env"
_load_tg_file "/opt/jitsi-cluster/telegram.env"
_load_tg_file "${TELEGRAM_ENV_FILE:-}"

# Caller/export qalib gəlir
[[ -n "${_SAVED_TOKEN}" ]] && TELEGRAM_BOT_TOKEN="${_SAVED_TOKEN}"
[[ -n "${_SAVED_CHAT}" ]] && TELEGRAM_CHAT_ID="${_SAVED_CHAT}"
[[ -n "${_SAVED_TOPIC}" ]] && TELEGRAM_TOPIC_ID="${_SAVED_TOPIC}"
[[ -n "${_SAVED_NOTIFY}" ]] && TELEGRAM_NOTIFY="${_SAVED_NOTIFY}"

NOTIFY="${TELEGRAM_NOTIFY:-true}"
TOKEN="${TELEGRAM_BOT_TOKEN:-}"
CHAT="${TELEGRAM_CHAT_ID:-}"
TOPIC="$(echo "${TELEGRAM_TOPIC_ID:-}" | tr -d '[:space:]')"

if [[ -z "${TOKEN}" || -z "${CHAT}" ]]; then
  if [[ "${TELEGRAM_DEBUG:-}" == "1" || "${TELEGRAM_DEBUG:-}" == "true" ]]; then
    echo "telegram-notify: TELEGRAM_BOT_TOKEN or TELEGRAM_CHAT_ID empty" >&2
  fi
  exit 0
fi
if [[ "${NOTIFY}" == "false" || "${NOTIFY}" == "0" || "${NOTIFY}" == "no" ]]; then
  exit 0
fi

if ! command -v jq >/dev/null 2>&1 || ! command -v curl >/dev/null 2>&1; then
  echo "telegram-notify: jq/curl lazımdır" >&2
  exit 0
fi

MSG="${*:-}"
if [[ -z "${MSG}" ]]; then
  MSG="$(cat 2>/dev/null || true)"
fi
[[ -n "${MSG}" ]] || exit 0

if (( ${#MSG} > 4000 )); then
  MSG="${MSG:0:3990}…"
fi

if [[ -n "${TOPIC}" ]]; then
  if ! [[ "${TOPIC}" =~ ^[0-9]+$ ]]; then
    echo "telegram-notify: TELEGRAM_TOPIC_ID must be numeric (got: ${TOPIC})" >&2
    exit 0
  fi
  BODY="$(jq -nc --arg c "${CHAT}" --arg t "${MSG}" --argjson th "${TOPIC}" \
    '{chat_id:$c,text:$t,message_thread_id:$th,disable_web_page_preview:true}')"
else
  BODY="$(jq -nc --arg c "${CHAT}" --arg t "${MSG}" \
    '{chat_id:$c,text:$t,disable_web_page_preview:true}')"
fi

RESP="$(curl -sS --connect-timeout 8 --max-time 20 \
  -X POST "https://api.telegram.org/bot${TOKEN}/sendMessage" \
  -H "Content-Type: application/json" \
  --data "${BODY}" 2>&1)" || true

if [[ "${TELEGRAM_DEBUG:-}" == "1" || "${TELEGRAM_DEBUG:-}" == "true" ]]; then
  echo "${RESP}" >&2
fi
if ! echo "${RESP}" | jq -e '.ok == true' >/dev/null 2>&1; then
  echo "telegram-notify: send failed (TELEGRAM_DEBUG=1 for details)" >&2
fi

exit 0

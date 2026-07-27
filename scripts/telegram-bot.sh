#!/usr/bin/env bash
# meet-control: Telegram bot long-poll — /status /live /recordings /help
# Yalnız TELEGRAM_CHAT_ID-dən gələn mesajlara cavab verir.
# systemd: jitsi-telegram-bot.service

set +e
set +u

export PATH="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin:${PATH:-}"

STATE_DIR="${STATE_DIR:-/var/lib/jitsi-cluster}"
OFFSET_FILE="${STATE_DIR}/telegram-bot-offset"
CLUSTER_ENV="${CLUSTER_ENV:-/opt/jitsi-cluster/cluster.env}"
SSH_KEY="${SSH_KEY:-/opt/jitsi-cluster/deploy_key}"
SSH_USER="${SSH_USER:-ubuntu}"
NOTIFY_BIN="${NOTIFY_BIN:-/opt/jitsi-cluster/telegram-notify.sh}"
POLL_TIMEOUT="${TELEGRAM_BOT_POLL_TIMEOUT:-25}"
LOG_TAG="telegram-bot"

mkdir -p "${STATE_DIR}" 2>/dev/null || true

log() { echo "[$(date -Iseconds)] [${LOG_TAG}] $*" >&2; }

if [[ -f "${CLUSTER_ENV}" ]]; then
  # shellcheck disable=SC1090
  set -a
  # shellcheck source=/dev/null
  source "${CLUSTER_ENV}"
  set +a
fi
if [[ -f /opt/jitsi-cluster/telegram.env ]]; then
  # shellcheck disable=SC1091
  set -a
  # shellcheck source=/dev/null
  source /opt/jitsi-cluster/telegram.env
  set +a
fi

TOKEN="${TELEGRAM_BOT_TOKEN:-}"
CHAT_ALLOW="${TELEGRAM_CHAT_ID:-}"
DOMAIN="${DOMAIN:-}"
JVB_PRIVATE_IP="${JVB_PRIVATE_IP:-}"
RECORDER_PRIVATE_IPS="${RECORDER_PRIVATE_IPS:-}"
JIBRI_PER_VM="${JIBRI_PER_VM:-5}"
PORTAL_UPLOAD_META_URL="${PORTAL_UPLOAD_META_URL:-}"
PORTAL_UPLOAD_META_TOKEN="${PORTAL_UPLOAD_META_TOKEN:-}"

if [[ -z "${TOKEN}" || -z "${CHAT_ALLOW}" ]]; then
  log "TELEGRAM_BOT_TOKEN / TELEGRAM_CHAT_ID boş — exit"
  exit 1
fi
if ! command -v jq >/dev/null 2>&1 || ! command -v curl >/dev/null 2>&1; then
  log "jq/curl lazımdır"
  exit 1
fi

API="https://api.telegram.org/bot${TOKEN}"

reply() {
  local text="$1"
  if [[ -x "${NOTIFY_BIN}" ]]; then
    "${NOTIFY_BIN}" "${text}"
  else
    # fallback — topic olmadan
    curl -sS --connect-timeout 8 --max-time 20 \
      -X POST "${API}/sendMessage" \
      -H "Content-Type: application/json" \
      --data "$(jq -nc --arg c "${CHAT_ALLOW}" --arg t "${text}" \
        '{chat_id:$c,text:$t,disable_web_page_preview:true}')" >/dev/null 2>&1 || true
  fi
}

ssh_rec() {
  local ip="$1"
  shift
  local opts=(-o BatchMode=yes -o StrictHostKeyChecking=no \
    -o UserKnownHostsFile=/dev/null -o ConnectTimeout=5 -o LogLevel=ERROR)
  [[ -f "${SSH_KEY}" ]] && opts+=(-i "${SSH_KEY}")
  ssh "${opts[@]}" "${SSH_USER}@${ip}" "$@"
}

cmd_help() {
  cat <<EOF
Jitsi bot əmrləri (${DOMAIN:-?}):

/status — cluster health (servis, HTTPS, recorder SSH, Jibri)
/live — portalda açıq meetinglər (müəllim / qrup / room)
/recordings — indi yazılan recording slotları + aktiv fayllar
/help — bu siyahı

Yalnız konfiqurasiya olunmuş chat-dan işləyir.
EOF
}

cmd_status() {
  local issues=() busy=() line ip active https_ok=0
  local out="Jitsi /status
domain=${DOMAIN:-?}
time=$(date -Iseconds)"

  for s in nginx prosody jicofo; do
    if systemctl list-unit-files "${s}.service" >/dev/null 2>&1 \
      || systemctl status "${s}" >/dev/null 2>&1; then
      if systemctl is-active --quiet "${s}"; then
        out+=$'\n'"svc ${s}: ok"
      else
        out+=$'\n'"svc ${s}: DOWN"
        issues+=("${s} inactive")
      fi
    fi
  done

  if curl -skf --connect-timeout 5 --max-time 10 -H "Host: ${DOMAIN:-localhost}" \
    "https://127.0.0.1/" >/dev/null 2>&1 \
    || { [[ -n "${DOMAIN}" ]] && curl -skf --connect-timeout 5 --max-time 10 "https://${DOMAIN}/" >/dev/null 2>&1; }; then
    https_ok=1
  fi
  if (( https_ok )); then
    out+=$'\n'"https: ok"
  else
    out+=$'\n'"https: FAIL"
    issues+=("HTTPS down")
  fi

  if [[ -n "${JVB_PRIVATE_IP}" ]]; then
    if ping -c 1 -W 2 "${JVB_PRIVATE_IP}" >/dev/null 2>&1 \
      || timeout 3 bash -c "echo >/dev/tcp/${JVB_PRIVATE_IP}/22" 2>/dev/null; then
      out+=$'\n'"jvb (${JVB_PRIVATE_IP}): ok"
    else
      out+=$'\n'"jvb (${JVB_PRIVATE_IP}): FAIL"
      issues+=("JVB unreachable")
    fi
  fi

  IFS=',' read -r -a REC_IPS <<< "${RECORDER_PRIVATE_IPS}"
  for ip in "${REC_IPS[@]}"; do
    ip="$(echo "${ip}" | xargs)"
    [[ -n "${ip}" ]] || continue
    if ! ssh_rec "${ip}" "true" >/dev/null 2>&1; then
      out+=$'\n'"recorder ${ip}: SSH FAIL"
      issues+=("recorder SSH ${ip}")
      continue
    fi
    active="$(ssh_rec "${ip}" "systemctl list-units --type=service --state=running 'jibri@*' --no-legend 2>/dev/null | wc -l" | tr -d '[:space:]')"
    out+=$'\n'"recorder ${ip}: ssh ok, jibri_running=${active:-0}"
    if [[ -z "${active}" || "${active}" == "0" ]]; then
      issues+=("jibri down ${ip}")
    fi
    for i in $(seq 1 "${JIBRI_PER_VM}"); do
      port=$((2222 + i - 1))
      busy_json="$(ssh_rec "${ip}" "curl -sf --max-time 3 http://127.0.0.1:${port}/jibri/api/v1.0/health 2>/dev/null" 2>/dev/null || true)"
      if echo "${busy_json}" | grep -qiE '"busy"[[:space:]]*:[[:space:]]*true|"busyStatus"[[:space:]]*:[[:space:]]*"BUSY"'; then
        busy+=("${ip}:slot${i}")
      fi
    done
  done

  if (( ${#busy[@]} )); then
    out+=$'\n'"recording busy: $(IFS=,; echo "${busy[*]}")"
  else
    out+=$'\n'"recording busy: none"
  fi

  if (( ${#issues[@]} == 0 )); then
    out+=$'\nstatus: OK'
  else
    out+=$'\nstatus: ISSUES'
    for line in "${issues[@]}"; do
      out+=$'\n'"- ${line}"
    done
  fi
  printf '%s' "${out}"
}

cmd_live() {
  local base token url resp
  base="${PORTAL_UPLOAD_META_URL:-}"
  token="${PORTAL_UPLOAD_META_TOKEN:-}"
  if [[ -z "${base}" || -z "${token}" ]]; then
    echo "Jitsi /live
portal meta URL/token yoxdur (PORTAL_UPLOAD_META_*).
Müəllim/qrup göstərmək üçün cluster.env-ə əlavə et."
    return 0
  fi
  base="${base%/}"
  url="${base}/portal/api/jitsi/live-meetings/"
  resp="$(curl -sS --connect-timeout 8 --max-time 20 \
    -H "Authorization: Bearer ${token}" \
    -H "Accept: application/json" \
    "${url}" 2>/dev/null)" || {
    echo "Jitsi /live
portal live-meetings curl fail"
    return 0
  }
  if ! echo "${resp}" | jq -e '.ok == true' >/dev/null 2>&1; then
    echo "Jitsi /live
portal error: ${resp:0:300}"
    return 0
  fi
  local count
  count="$(echo "${resp}" | jq -r '.count // 0')"
  if [[ "${count}" == "0" ]]; then
    echo "Jitsi /live
domain=${DOMAIN:-?}
open meetings: 0"
    return 0
  fi
  {
    echo "Jitsi /live"
    echo "domain=${DOMAIN:-?}"
    echo "open meetings: ${count}"
    echo "${resp}" | jq -r '
      .meetings[]? |
      "— teacher=\(.teacher_name // "?") (@\(.teacher_username // "?"))\n  group=\(.group_name // "?")\n  room=\(.room // "?")\n  started=\(.started_at // "?")"
    '
  }
}

cmd_recordings() {
  local out ip i port busy_json busy_list=()
  out="Jitsi /recordings
domain=${DOMAIN:-?}
time=$(date -Iseconds)"

  IFS=',' read -r -a REC_IPS <<< "${RECORDER_PRIVATE_IPS}"
  if (( ${#REC_IPS[@]} == 0 )) || [[ -z "${REC_IPS[0]// /}" ]]; then
    out+=$'\n'"recorder IP yoxdur (RECORDER_PRIVATE_IPS)"
    printf '%s' "${out}"
    return 0
  fi

  for ip in "${REC_IPS[@]}"; do
    ip="$(echo "${ip}" | xargs)"
    [[ -n "${ip}" ]] || continue
    if ! ssh_rec "${ip}" "true" >/dev/null 2>&1; then
      out+=$'\n'"recorder ${ip}: SSH FAIL"
      continue
    fi
    out+=$'\n'"recorder ${ip}:"
    for i in $(seq 1 "${JIBRI_PER_VM}"); do
      port=$((2222 + i - 1))
      busy_json="$(ssh_rec "${ip}" "curl -sf --max-time 3 http://127.0.0.1:${port}/jibri/api/v1.0/health 2>/dev/null" 2>/dev/null || true)"
      if echo "${busy_json}" | grep -qiE '"busy"[[:space:]]*:[[:space:]]*true|"busyStatus"[[:space:]]*:[[:space:]]*"BUSY"'; then
        out+=$'\n'"  slot${i}: BUSY"
        busy_list+=("${ip}:slot${i}")
      else
        out+=$'\n'"  slot${i}: idle"
      fi
    done
    # aktiv recording metadata (son 6 saat)
    local meta
    meta="$(ssh_rec "${ip}" 'bash -s' <<'REMOTE' 2>/dev/null || true
find /srv/recordings -mindepth 2 -maxdepth 3 -name metadata.json -mmin -360 2>/dev/null | while read -r m; do
  url=$(jq -r '.meeting_url // .meetingUrl // empty' "$m" 2>/dev/null || true)
  sz=$(du -sh "$(dirname "$m")" 2>/dev/null | awk '{print $1}')
  echo "  file dir=$(basename "$(dirname "$m")") size=${sz} url=${url:-?}"
done | head -15
REMOTE
)"
    if [[ -n "${meta}" ]]; then
      out+=$'\n'"active files:"
      out+=$'\n'"${meta}"
    fi
  done

  if (( ${#busy_list[@]} == 0 )); then
    out+=$'\n'"summary: no busy slots"
  else
    out+=$'\n'"summary busy: $(IFS=,; echo "${busy_list[*]}")"
  fi

  # portal konteksti (kim meeting açıb)
  local live
  live="$(cmd_live 2>/dev/null | grep -v '^Jitsi /live$' | head -40)"
  if [[ -n "${live}" ]]; then
    out+=$'\n\n'"portal:"
    out+=$'\n'"${live}"
  fi
  printf '%s' "${out}"
}

handle_text() {
  local text="$1" cmd
  text="$(printf '%s' "${text}" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')"
  [[ -n "${text}" ]] || return 0
  # /status@MyBot → /status
  cmd="$(printf '%s' "${text}" | awk '{print tolower($1)}' | sed 's/@.*//')"
  case "${cmd}" in
    /start|/help)
      reply "$(cmd_help)"
      ;;
    /status)
      reply "$(cmd_status)"
      ;;
    /live)
      reply "$(cmd_live)"
      ;;
    /recordings|/recording|/rec)
      reply "$(cmd_recordings)"
      ;;
    /*)
      reply "Naməlum əmr: ${cmd}

$(cmd_help)"
      ;;
  esac
}

# offset
OFFSET=0
if [[ -f "${OFFSET_FILE}" ]]; then
  OFFSET="$(tr -d '[:space:]' <"${OFFSET_FILE}" 2>/dev/null || echo 0)"
fi
[[ "${OFFSET}" =~ ^[0-9]+$ ]] || OFFSET=0

log "started chat=${CHAT_ALLOW} domain=${DOMAIN:-?} offset=${OFFSET}"

# Drop pending backlog on first start if offset=0 (avoid replaying old cmds)
if [[ "${OFFSET}" == "0" ]]; then
  boot="$(curl -sS --connect-timeout 10 --max-time 35 \
    "${API}/getUpdates?timeout=0&limit=100" 2>/dev/null || true)"
  last="$(echo "${boot}" | jq -r '[.result[]?.update_id] | max // empty' 2>/dev/null || true)"
  if [[ -n "${last}" && "${last}" =~ ^[0-9]+$ ]]; then
    OFFSET=$((last + 1))
    echo "${OFFSET}" >"${OFFSET_FILE}"
    log "skip backlog → offset=${OFFSET}"
  fi
fi

while true; do
  RESP="$(curl -sS --connect-timeout 10 --max-time $((POLL_TIMEOUT + 15)) \
    "${API}/getUpdates?timeout=${POLL_TIMEOUT}&offset=${OFFSET}&allowed_updates=%5B%22message%22%5D" 2>/dev/null)" || {
    log "getUpdates fail — sleep 5"
    sleep 5
    continue
  }
  if ! echo "${RESP}" | jq -e '.ok == true' >/dev/null 2>&1; then
    log "getUpdates not ok: ${RESP:0:200}"
    sleep 5
    continue
  fi

  COUNT="$(echo "${RESP}" | jq -r '.result | length' 2>/dev/null || echo 0)"
  if [[ "${COUNT}" == "0" || -z "${COUNT}" ]]; then
    continue
  fi

  # process each update
  while IFS= read -r row; do
    [[ -n "${row}" ]] || continue
    uid="$(echo "${row}" | jq -r '.update_id')"
    chat="$(echo "${row}" | jq -r '.message.chat.id // empty')"
    text="$(echo "${row}" | jq -r '.message.text // empty')"
    if [[ -n "${uid}" && "${uid}" =~ ^[0-9]+$ ]]; then
      next=$((uid + 1))
      if (( next > OFFSET )); then
        OFFSET="${next}"
        echo "${OFFSET}" >"${OFFSET_FILE}"
      fi
    fi
    # yalnız icazəli chat
    if [[ "${chat}" != "${CHAT_ALLOW}" ]]; then
      continue
    fi
    [[ -n "${text}" ]] || continue
    log "cmd from ${chat}: ${text}"
    handle_text "${text}"
  done < <(echo "${RESP}" | jq -c '.result[]?' 2>/dev/null)
done

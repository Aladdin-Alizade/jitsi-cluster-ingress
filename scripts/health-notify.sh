#!/usr/bin/env bash
# meet-control cron: xidmət / SSL / disk / CPU / JVB / Jibri yoxla → Telegram
# Spam az: yalnız status dəyişəndə; CRITICAL hər 60 dəq təkrarlana bilər.

set +e
set +u

NOTIFY_BIN="${NOTIFY_BIN:-/opt/jitsi-cluster/telegram-notify.sh}"
STATE_DIR="${STATE_DIR:-/var/lib/jitsi-cluster}"
STATE_FILE="${STATE_DIR}/health-state"
CRIT_COOLDOWN_SEC="${CRIT_COOLDOWN_SEC:-3600}"
CLUSTER_ENV="${CLUSTER_ENV:-/opt/jitsi-cluster/cluster.env}"
SSH_KEY="${SSH_KEY:-/opt/jitsi-cluster/deploy_key}"
SSH_USER="${SSH_USER:-ubuntu}"

mkdir -p "${STATE_DIR}" 2>/dev/null || true

if [[ -f "${CLUSTER_ENV}" ]]; then
  # shellcheck disable=SC1090
  set -a
  # shellcheck source=/dev/null
  source "${CLUSTER_ENV}"
  set +a
fi

DOMAIN="${DOMAIN:-}"
JVB_PRIVATE_IP="${JVB_PRIVATE_IP:-}"
RECORDER_PRIVATE_IPS="${RECORDER_PRIVATE_IPS:-}"
JIBRI_PER_VM="${JIBRI_PER_VM:-5}"

tg() {
  if [[ -x "${NOTIFY_BIN}" ]]; then
    "${NOTIFY_BIN}" "$*"
  fi
}

# issues: lines "LEVEL|key|message"
ISSUES=()
BUSY_NOW=()

add_issue() {
  ISSUES+=("$1|$2|$3")
}

check_svc() {
  local svc="$1"
  if systemctl list-unit-files "${svc}.service" >/dev/null 2>&1 \
    || systemctl status "${svc}" >/dev/null 2>&1; then
    if systemctl is-active --quiet "${svc}"; then
      return 0
    fi
    add_issue "CRITICAL" "svc_${svc}" "${svc} inactive"
    return 1
  fi
  return 0
}

# --- local services ---
for s in nginx prosody jicofo; do
  check_svc "${s}"
done
if systemctl list-unit-files coturn.service >/dev/null 2>&1 \
  || systemctl is-enabled coturn >/dev/null 2>&1; then
  check_svc coturn
elif systemctl list-unit-files turnserver.service >/dev/null 2>&1; then
  check_svc turnserver
fi

# --- HTTPS ---
HTTPS_URL="https://127.0.0.1"
[[ -n "${DOMAIN}" ]] && HTTPS_URL="https://${DOMAIN}"
if ! curl -skf --connect-timeout 5 --max-time 12 "${HTTPS_URL}/" >/dev/null 2>&1; then
  add_issue "CRITICAL" "https" "HTTPS cavab vermir (${HTTPS_URL})"
fi

# --- SSL ---
CERT=""
if [[ -n "${DOMAIN}" && -f "/etc/jitsi/meet/${DOMAIN}.crt" ]]; then
  CERT="/etc/jitsi/meet/${DOMAIN}.crt"
elif [[ -n "${DOMAIN}" && -f "/etc/letsencrypt/live/${DOMAIN}/fullchain.pem" ]]; then
  CERT="/etc/letsencrypt/live/${DOMAIN}/fullchain.pem"
fi
if [[ -n "${CERT}" && -f "${CERT}" ]]; then
  END_EPOCH="$(openssl x509 -enddate -noout -in "${CERT}" 2>/dev/null | cut -d= -f2 | xargs -I{} date -d {} +%s 2>/dev/null || true)"
  NOW_EPOCH="$(date +%s)"
  if [[ -z "${END_EPOCH}" ]]; then
    add_issue "WARN" "ssl_parse" "SSL enddate oxunmadı"
  else
    DAYS_LEFT=$(( (END_EPOCH - NOW_EPOCH) / 86400 ))
    if (( DAYS_LEFT < 0 )); then
      add_issue "CRITICAL" "ssl_expired" "SSL vaxtı bitib (${CERT})"
    elif (( DAYS_LEFT <= 14 )); then
      add_issue "WARN" "ssl_expiring" "SSL ${DAYS_LEFT} günə bitir"
    fi
  fi
  if ! openssl x509 -in "${CERT}" -noout -text 2>/dev/null | grep -qiE "Let's Encrypt|ISRG"; then
    add_issue "WARN" "ssl_selfsigned" "SSL Let's Encrypt deyil (Not Secure ola bilər)"
  fi
fi

# --- disk ---
check_disk() {
  local path="$1" label="$2"
  [[ -d "${path}" ]] || return 0
  local pct
  pct="$(df -P "${path}" 2>/dev/null | awk 'NR==2 {gsub(/%/,"",$5); print $5}')"
  [[ -n "${pct}" ]] || return 0
  if (( pct >= 95 )); then
    add_issue "CRITICAL" "disk_${label}" "${path} disk ${pct}%"
  elif (( pct >= 85 )); then
    add_issue "WARN" "disk_${label}" "${path} disk ${pct}%"
  fi
}
check_disk "/" "root"
check_disk "/srv/recordings" "recordings"

# --- load ---
NPROC="$(nproc 2>/dev/null || echo 1)"
LOAD5="$(awk '{print $2}' /proc/loadavg 2>/dev/null || echo 0)"
# bash float compare via awk
if awk -v l="${LOAD5}" -v n="${NPROC}" 'BEGIN { exit !(l > n * 1.5) }'; then
  add_issue "WARN" "load" "load5=${LOAD5} nproc=${NPROC}"
fi

# --- JVB ---
if [[ -n "${JVB_PRIVATE_IP}" ]]; then
  if ! ping -c 1 -W 2 "${JVB_PRIVATE_IP}" >/dev/null 2>&1 \
    && ! timeout 3 bash -c "echo >/dev/tcp/${JVB_PRIVATE_IP}/22" 2>/dev/null; then
    add_issue "CRITICAL" "jvb_host" "meet-jvb reachable deyil (${JVB_PRIVATE_IP})"
  else
    # colibri private stats often on 8080
    if ! curl -sf --connect-timeout 3 --max-time 5 \
      "http://${JVB_PRIVATE_IP}:8080/about/health" >/dev/null 2>&1 \
      && ! curl -sf --connect-timeout 3 --max-time 5 \
      "http://${JVB_PRIVATE_IP}:8080/colibri/stats" >/dev/null 2>&1; then
      # host up amma health endpoint yox — yalnız WARN
      add_issue "WARN" "jvb_health" "JVB host var, colibri health cavab vermir"
    fi
  fi
fi

# --- Jibri via SSH ---
ssh_rec() {
  local ip="$1"
  shift
  local opts=(-o BatchMode=yes -o StrictHostKeyChecking=no \
    -o UserKnownHostsFile=/dev/null -o ConnectTimeout=5)
  if [[ -f "${SSH_KEY}" ]]; then
    opts+=(-i "${SSH_KEY}")
  fi
  ssh "${opts[@]}" "${SSH_USER}@${ip}" "$@"
}

IFS=',' read -r -a REC_IPS <<< "${RECORDER_PRIVATE_IPS}"
for ip in "${REC_IPS[@]}"; do
  ip="$(echo "${ip}" | xargs)"
  [[ -n "${ip}" ]] || continue
  if ! ssh_rec "${ip}" "true" >/dev/null 2>&1; then
    add_issue "CRITICAL" "recorder_${ip}" "recorder SSH fail (${ip})"
    continue
  fi
  # active units
  ACTIVE="$(ssh_rec "${ip}" "systemctl list-units --type=service --state=running 'jibri@*' --no-legend 2>/dev/null | wc -l" | tr -d '[:space:]')"
  if [[ -z "${ACTIVE}" || "${ACTIVE}" == "0" ]]; then
    add_issue "CRITICAL" "jibri_units_${ip}" "jibri@* işləmir (${ip})"
  fi
  # busy via Jibri API (api HTTP on 2222+i-1)
  for i in $(seq 1 "${JIBRI_PER_VM}"); do
    port=$((2222 + i - 1))
    busy="$(ssh_rec "${ip}" "curl -sf --max-time 3 http://127.0.0.1:${port}/jibri/api/v1.0/health 2>/dev/null" 2>/dev/null || true)"
    if echo "${busy}" | grep -qi '"busy"[[:space:]]*:[[:space:]]*true'; then
      BUSY_NOW+=("${ip}:slot${i}")
    fi
  done
done

# --- state / notify ---
PREV_ISSUES=""
PREV_BUSY=""
PREV_CRIT_TS=0
if [[ -f "${STATE_FILE}" ]]; then
  # shellcheck disable=SC1090
  source "${STATE_FILE}" 2>/dev/null
fi

CUR_KEYS="$(printf '%s\n' "${ISSUES[@]}" | sort | paste -sd';' -)"
PREV_KEYS="${PREV_ISSUES:-}"
CUR_BUSY="$(printf '%s\n' "${BUSY_NOW[@]}" | sort | paste -sd';' -)"
PREV_BUSY_S="${PREV_BUSY:-}"

NOW_TS="$(date +%s)"
HAS_CRIT=0
for line in "${ISSUES[@]}"; do
  [[ "${line}" == CRITICAL\|* ]] && HAS_CRIT=1
done

CHANGED=0
[[ "${CUR_KEYS}" != "${PREV_KEYS}" ]] && CHANGED=1
[[ "${CUR_BUSY}" != "${PREV_BUSY_S}" ]] && CHANGED=1

SHOULD_SEND=0
if (( CHANGED )); then
  SHOULD_SEND=1
elif (( HAS_CRIT )); then
  if (( NOW_TS - PREV_CRIT_TS >= CRIT_COOLDOWN_SEC )); then
    SHOULD_SEND=1
  fi
fi

if (( SHOULD_SEND )); then
  HOST="$(hostname -f 2>/dev/null || hostname)"
  MSG="Jitsi health @ ${HOST}
domain=${DOMAIN:-?}
time=$(date -Iseconds)"

  if (( ${#ISSUES[@]} == 0 )); then
    MSG+=$'\nstatus: OK'
  else
    MSG+=$'\nstatus: ISSUES'
    for line in "${ISSUES[@]}"; do
      IFS='|' read -r lvl key msg <<<"${line}"
      MSG+=$'\n'"[${lvl}] ${msg}"
    done
  fi

  # busy transitions
  if [[ "${CUR_BUSY}" != "${PREV_BUSY_S}" ]]; then
    if [[ -n "${CUR_BUSY}" ]]; then
      MSG+=$'\nrecording busy: '"${CUR_BUSY}"
      # new slots
      IFS=';' read -r -a prev_a <<< "${PREV_BUSY_S}"
      IFS=';' read -r -a cur_a <<< "${CUR_BUSY}"
      for s in "${cur_a[@]}"; do
        [[ -z "${s}" ]] && continue
        found=0
        for p in "${prev_a[@]}"; do [[ "${p}" == "${s}" ]] && found=1 && break; done
        if (( !found )); then
          tg "Jitsi recording STARTED: ${s} (${DOMAIN:-})"
        fi
      done
      for p in "${prev_a[@]}"; do
        [[ -z "${p}" ]] && continue
        found=0
        for s in "${cur_a[@]}"; do [[ "${s}" == "${p}" ]] && found=1 && break; done
        if (( !found )); then
          tg "Jitsi recording IDLE (slot free): ${p} (${DOMAIN:-})"
        fi
      done
    elif [[ -n "${PREV_BUSY_S}" ]]; then
      MSG+=$'\nrecording: all idle'
    fi
  fi

  # only send aggregate health if issues changed or crit cooldown / recovery
  if [[ "${CUR_KEYS}" != "${PREV_KEYS}" ]] || (( HAS_CRIT && NOW_TS - PREV_CRIT_TS >= CRIT_COOLDOWN_SEC )); then
    tg "${MSG}"
  fi

  if (( HAS_CRIT )); then
    PREV_CRIT_TS="${NOW_TS}"
  fi
fi

cat > "${STATE_FILE}" <<EOF
PREV_ISSUES='${CUR_KEYS}'
PREV_BUSY='${CUR_BUSY}'
PREV_CRIT_TS=${PREV_CRIT_TS:-0}
EOF
chmod 600 "${STATE_FILE}" 2>/dev/null || true

exit 0

#!/usr/bin/env bash
# meet-control cron: xidmət / SSL / disk / CPU / JVB / Jibri yoxla → Telegram
# Spam az: yalnız status dəyişəndə; CRITICAL hər 60 dəq təkrarlana bilər.
# Boot-dan sonra 8 dəq grace (scheduler start-da false CRITICAL olmasın).
# CRITICAL olanda: recorder diaqnostika + portal live meetings (müəllim/qrup).

set +e
set +u

export PATH="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin:${PATH:-}"

NOTIFY_BIN="${NOTIFY_BIN:-/opt/jitsi-cluster/telegram-notify.sh}"
STATE_DIR="${STATE_DIR:-/var/lib/jitsi-cluster}"
STATE_FILE="${STATE_DIR}/health-state.json"
DIAG_DIR="${DIAG_DIR:-/var/log/jitsi/health-diag}"
CRIT_COOLDOWN_SEC="${CRIT_COOLDOWN_SEC:-3600}"
BOOT_GRACE_SEC="${BOOT_GRACE_SEC:-480}"
CLUSTER_ENV="${CLUSTER_ENV:-/opt/jitsi-cluster/cluster.env}"
SSH_KEY="${SSH_KEY:-/opt/jitsi-cluster/deploy_key}"
SSH_USER="${SSH_USER:-ubuntu}"

mkdir -p "${STATE_DIR}" "${DIAG_DIR}" 2>/dev/null || true

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

DOMAIN="${DOMAIN:-}"
JVB_PRIVATE_IP="${JVB_PRIVATE_IP:-}"
RECORDER_PRIVATE_IPS="${RECORDER_PRIVATE_IPS:-}"
JIBRI_PER_VM="${JIBRI_PER_VM:-5}"
PORTAL_UPLOAD_META_URL="${PORTAL_UPLOAD_META_URL:-}"
PORTAL_UPLOAD_META_TOKEN="${PORTAL_UPLOAD_META_TOKEN:-}"

tg() {
  if [[ -x "${NOTIFY_BIN}" ]]; then
    "${NOTIFY_BIN}" "$*"
  fi
}

# Boot grace — hələ qalxır
UPTIME_SEC="$(awk '{print int($1)}' /proc/uptime 2>/dev/null || echo 99999)"
if (( UPTIME_SEC < BOOT_GRACE_SEC )); then
  exit 0
fi

ISSUES=()
BUSY_NOW=()
FAIL_IPS=()

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

for s in nginx prosody jicofo; do
  check_svc "${s}"
done
if systemctl list-unit-files coturn.service >/dev/null 2>&1 \
  || systemctl is-enabled coturn >/dev/null 2>&1; then
  check_svc coturn
elif systemctl list-unit-files turnserver.service >/dev/null 2>&1; then
  check_svc turnserver
fi

# HTTPS — əvvəl localhost (DNS/SNI asılı olmasın), sonra domain
HTTPS_OK=0
if curl -skf --connect-timeout 5 --max-time 12 -H "Host: ${DOMAIN:-localhost}" \
  "https://127.0.0.1/" >/dev/null 2>&1; then
  HTTPS_OK=1
elif [[ -n "${DOMAIN}" ]] && curl -skf --connect-timeout 5 --max-time 12 \
  "https://${DOMAIN}/" >/dev/null 2>&1; then
  HTTPS_OK=1
fi
if (( HTTPS_OK == 0 )); then
  add_issue "CRITICAL" "https" "HTTPS cavab vermir"
fi

CERT=""
if [[ -n "${DOMAIN}" && -f "/etc/letsencrypt/live/${DOMAIN}/fullchain.pem" ]]; then
  CERT="/etc/letsencrypt/live/${DOMAIN}/fullchain.pem"
elif [[ -n "${DOMAIN}" && -f "/etc/jitsi/meet/${DOMAIN}.crt" ]]; then
  CERT="/etc/jitsi/meet/${DOMAIN}.crt"
fi
if [[ -n "${CERT}" && -f "${CERT}" ]]; then
  END_EPOCH="$(openssl x509 -enddate -noout -in "${CERT}" 2>/dev/null | cut -d= -f2 | xargs -I{} date -d {} +%s 2>/dev/null || true)"
  NOW_EPOCH="$(date +%s)"
  if [[ -z "${END_EPOCH}" ]]; then
    add_issue "WARN" "ssl_parse" "SSL enddate oxunmadı"
  else
    DAYS_LEFT=$(( (END_EPOCH - NOW_EPOCH) / 86400 ))
    if (( DAYS_LEFT < 0 )); then
      add_issue "CRITICAL" "ssl_expired" "SSL vaxtı bitib"
    elif (( DAYS_LEFT <= 14 )); then
      add_issue "WARN" "ssl_expiring" "SSL ${DAYS_LEFT} günə bitir"
    fi
  fi
  if [[ "${CERT}" != *letsencrypt* ]] \
    && ! openssl x509 -in "${CERT}" -noout -issuer 2>/dev/null | grep -qiE "Let's Encrypt|ISRG"; then
    add_issue "WARN" "ssl_selfsigned" "SSL Let's Encrypt deyil (Not Secure ola bilər)"
  fi
fi

check_disk() {
  local path="$1" label="$2" pct
  [[ -d "${path}" ]] || return 0
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

NPROC="$(nproc 2>/dev/null || echo 1)"
LOAD5="$(awk '{print $2}' /proc/loadavg 2>/dev/null || echo 0)"
if awk -v l="${LOAD5}" -v n="${NPROC}" 'BEGIN { exit !(l > n * 2.0) }'; then
  add_issue "WARN" "load" "load5=${LOAD5} nproc=${NPROC}"
fi

# JVB — yalnız host reachable
if [[ -n "${JVB_PRIVATE_IP}" ]]; then
  if ! ping -c 1 -W 2 "${JVB_PRIVATE_IP}" >/dev/null 2>&1 \
    && ! timeout 3 bash -c "echo >/dev/tcp/${JVB_PRIVATE_IP}/22" 2>/dev/null; then
    add_issue "CRITICAL" "jvb_host" "meet-jvb reachable deyil (${JVB_PRIVATE_IP})"
  fi
fi

ssh_rec() {
  local ip="$1"
  shift
  local opts=(-o BatchMode=yes -o StrictHostKeyChecking=no \
    -o UserKnownHostsFile=/dev/null -o ConnectTimeout=5 -o LogLevel=ERROR)
  if [[ -f "${SSH_KEY}" ]]; then
    opts+=(-i "${SSH_KEY}")
  fi
  ssh "${opts[@]}" "${SSH_USER}@${ip}" "$@"
}

# Recorder SSH + Jibri busy slots
IFS=',' read -r -a REC_IPS <<< "${RECORDER_PRIVATE_IPS}"
for ip in "${REC_IPS[@]}"; do
  ip="$(echo "${ip}" | xargs)"
  [[ -n "${ip}" ]] || continue
  if ! ssh_rec "${ip}" "true" >/dev/null 2>&1; then
    add_issue "CRITICAL" "recorder_${ip}" "recorder SSH fail (${ip})"
    FAIL_IPS+=("${ip}")
    continue
  fi
  ACTIVE="$(ssh_rec "${ip}" "systemctl list-units --type=service --state=running 'jibri@*' --no-legend 2>/dev/null | wc -l" | tr -d '[:space:]')"
  if [[ -z "${ACTIVE}" || "${ACTIVE}" == "0" ]]; then
    add_issue "CRITICAL" "jibri_units_${ip}" "jibri@* işləmir (${ip})"
    FAIL_IPS+=("${ip}")
  fi
  for i in $(seq 1 "${JIBRI_PER_VM}"); do
    port=$((2222 + i - 1))
    busy="$(ssh_rec "${ip}" "curl -sf --max-time 3 http://127.0.0.1:${port}/jibri/api/v1.0/health 2>/dev/null" 2>/dev/null || true)"
    if echo "${busy}" | grep -qiE '"busy"[[:space:]]*:[[:space:]]*true|"busyStatus"[[:space:]]*:[[:space:]]*"BUSY"'; then
      BUSY_NOW+=("${ip}:slot${i}")
    fi
  done
done

# --- CRITICAL diaqnostika (SSH + portal live) ---
collect_recorder_diag() {
  local ip="$1"
  local out ping_ok=0 tcp_ok=0
  out="--- recorder ${ip} ---"
  if ping -c 1 -W 2 "${ip}" >/dev/null 2>&1; then
    ping_ok=1
  fi
  if timeout 3 bash -c "echo >/dev/tcp/${ip}/22" 2>/dev/null; then
    tcp_ok=1
  fi
  out+=$'\n'"ping=${ping_ok} tcp22=${tcp_ok}"
  if ! ssh_rec "${ip}" "true" >/dev/null 2>&1; then
    out+=$'\n'"ssh: FAIL (VM down / sshd / firewall / hələ boot)"
    echo "${out}"
    return 0
  fi
  out+=$'\n'"ssh: OK"
  out+=$'\n'"$(ssh_rec "${ip}" 'bash -s' <<'REMOTE' 2>/dev/null || echo "(diag ssh cmd fail)"
set +e
echo "host=$(hostname -s) uptime=$(uptime -p 2>/dev/null || uptime)"
echo "loadavg=$(cat /proc/loadavg)"
free -m 2>/dev/null | awk '/^Mem:/{printf "mem=%s/%sMB used\n",$3,$2}'
df -h / 2>/dev/null | awk 'NR==2{printf "disk_root=%s used %s free\n",$5,$4}'
df -h /srv/recordings 2>/dev/null | awk 'NR==2{printf "disk_rec=%s used %s free\n",$5,$4}'
echo "jibri_units:"
systemctl list-units --type=service --all 'jibri@*' --no-legend 2>/dev/null | head -20
echo "active_recordings:"
find /srv/recordings -mindepth 2 -maxdepth 3 -name metadata.json -mmin -360 2>/dev/null | while read -r m; do
  url=$(jq -r '.meeting_url // .meetingUrl // empty' "$m" 2>/dev/null || true)
  sz=$(du -sh "$(dirname "$m")" 2>/dev/null | awk '{print $1}')
  echo "  dir=$(basename "$(dirname "$m")") size=${sz} url=${url:-?}"
done | head -20
echo "journal_jibri (last 25):"
journalctl -u 'jibri@*' --no-pager -n 25 --since '30 min ago' 2>/dev/null | tail -25
REMOTE
)"
  echo "${out}"
}

fetch_portal_live() {
  local base token url resp
  base="${PORTAL_UPLOAD_META_URL:-}"
  token="${PORTAL_UPLOAD_META_TOKEN:-}"
  if [[ -z "${base}" || -z "${token}" ]]; then
    echo "(portal meta URL/token yoxdur — teacher/group bilinmir)"
    return 0
  fi
  base="${base%/}"
  url="${base}/portal/api/jitsi/live-meetings/"
  resp="$(curl -sS --connect-timeout 8 --max-time 20 \
    -H "Authorization: Bearer ${token}" \
    -H "Accept: application/json" \
    "${url}" 2>/dev/null)" || {
    echo "(portal live-meetings curl fail)"
    return 0
  }
  if ! echo "${resp}" | jq -e '.ok == true' >/dev/null 2>&1; then
    echo "(portal live-meetings: ${resp:0:200})"
    return 0
  fi
  local count
  count="$(echo "${resp}" | jq -r '.count // 0')"
  if [[ "${count}" == "0" ]]; then
    echo "portal live meetings: none open"
    return 0
  fi
  echo "portal live meetings (${count}):"
  echo "${resp}" | jq -r '
    .meetings[]? |
    "  teacher=\(.teacher_name // "?") (@\(.teacher_username // "?")) group=\(.group_name // "?") room=\(.room // "?") started=\(.started_at // "?")"
  ' 2>/dev/null || echo "${resp:0:500}"
}

build_critical_diag() {
  local stamp diag_file block
  stamp="$(date +%Y%m%dT%H%M%S)"
  diag_file="${DIAG_DIR}/crit-${stamp}.log"
  {
    echo "==== health CRITICAL diag ${stamp} domain=${DOMAIN:-?} ===="
    echo "time=$(date -Iseconds)"
    echo "issues:"
    for line in "${ISSUES[@]}"; do
      echo "  ${line}"
    done
    echo "recording_busy: ${CUR_BUSY:-none}"
    echo
    echo "=== portal ==="
    fetch_portal_live
    echo
    echo "=== recorders ==="
    # Fail IP-lər + bütün reachable recorder-lərdə aktiv recording
    local seen=()
    for ip in "${FAIL_IPS[@]}" "${REC_IPS[@]}"; do
      ip="$(echo "${ip}" | xargs)"
      [[ -n "${ip}" ]] || continue
      local dup=0
      for s in "${seen[@]}"; do [[ "${s}" == "${ip}" ]] && dup=1 && break; done
      (( dup )) && continue
      seen+=("${ip}")
      collect_recorder_diag "${ip}"
      echo
    done
  } >"${diag_file}" 2>&1

  # Telegram üçün qısa (limit ~4000); tam fayl yolda
  block="$(head -c 3200 "${diag_file}" 2>/dev/null || true)"
  if (( $(wc -c <"${diag_file}" 2>/dev/null || echo 0) > 3200 )); then
    block+=$'\n'"… truncated; full: ${diag_file}"
  else
    block+=$'\n'"full: ${diag_file}"
  fi
  echo "${block}"
}

PREV_ISSUES=""
PREV_BUSY=""
PREV_CRIT_TS=0
if [[ -f "${STATE_FILE}" ]] && command -v jq >/dev/null 2>&1; then
  PREV_ISSUES="$(jq -r '.PREV_ISSUES // empty' "${STATE_FILE}" 2>/dev/null || true)"
  PREV_BUSY="$(jq -r '.PREV_BUSY // empty' "${STATE_FILE}" 2>/dev/null || true)"
  PREV_CRIT_TS="$(jq -r '.PREV_CRIT_TS // 0' "${STATE_FILE}" 2>/dev/null || echo 0)"
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
elif (( HAS_CRIT )) && (( NOW_TS - PREV_CRIT_TS >= CRIT_COOLDOWN_SEC )); then
  SHOULD_SEND=1
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
      IFS='|' read -r lvl _key msg <<<"${line}"
      MSG+=$'\n'"[${lvl}] ${msg}"
    done
  fi

  if [[ "${CUR_BUSY}" != "${PREV_BUSY_S}" ]]; then
    IFS=';' read -r -a prev_a <<< "${PREV_BUSY_S}"
    IFS=';' read -r -a cur_a <<< "${CUR_BUSY}"
    for s in "${cur_a[@]}"; do
      [[ -z "${s}" ]] && continue
      found=0
      for p in "${prev_a[@]}"; do [[ "${p}" == "${s}" ]] && found=1 && break; done
      if (( !found )); then
        # Recording start — portal live context
        LIVE_HINT="$(fetch_portal_live 2>/dev/null | head -20)"
        tg "Jitsi recording STARTED: ${s} (${DOMAIN:-})
${LIVE_HINT}"
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
    if [[ -n "${CUR_BUSY}" ]]; then
      MSG+=$'\nrecording busy: '"${CUR_BUSY}"
    elif [[ -n "${PREV_BUSY_S}" ]]; then
      MSG+=$'\nrecording: all idle'
    fi
  fi

  # CRITICAL → diaqnostika + portal müəllim/meeting
  if (( HAS_CRIT )); then
    DIAG_TEXT="$(build_critical_diag)"
    MSG+=$'\n\n'"${DIAG_TEXT}"
  fi

  if [[ "${CUR_KEYS}" != "${PREV_KEYS}" ]] \
    || (( HAS_CRIT && NOW_TS - PREV_CRIT_TS >= CRIT_COOLDOWN_SEC )); then
    tg "${MSG}"
  fi

  if (( HAS_CRIT )); then
    PREV_CRIT_TS="${NOW_TS}"
  fi
fi

if command -v jq >/dev/null 2>&1; then
  jq -nc \
    --arg issues "${CUR_KEYS}" \
    --arg busy "${CUR_BUSY}" \
    --argjson ts "${PREV_CRIT_TS:-0}" \
    '{PREV_ISSUES:$issues,PREV_BUSY:$busy,PREV_CRIT_TS:$ts}' \
    >"${STATE_FILE}" 2>/dev/null || true
  chmod 600 "${STATE_FILE}" 2>/dev/null || true
fi

# Köhnə diaq faylları (~7 gün)
find "${DIAG_DIR}" -type f -name 'crit-*.log' -mtime +7 -delete 2>/dev/null || true

exit 0

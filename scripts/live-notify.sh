#!/usr/bin/env bash
# meet-control cron (hər dəqiqə):
#  1) Prosody active rooms → portal /api/jitsi/sync-live/ (stale open flags bağlanır)
#  2) portal live meetings → Telegram OPENED/CLOSED
# Yalnız PORTAL_UPLOAD_META_* olanda işləyir.

set +e
set +u

export PATH="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin:${PATH:-}"

NOTIFY_BIN="${NOTIFY_BIN:-/opt/jitsi-cluster/telegram-notify.sh}"
ACTIVE_ROOMS_BIN="${ACTIVE_ROOMS_BIN:-/opt/jitsi-cluster/active-rooms.sh}"
STATE_DIR="${STATE_DIR:-/var/lib/jitsi-cluster}"
STATE_FILE="${STATE_DIR}/live-notify-state.json"
CLUSTER_ENV="${CLUSTER_ENV:-/opt/jitsi-cluster/cluster.env}"

mkdir -p "${STATE_DIR}" 2>/dev/null || true

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
PORTAL_UPLOAD_META_URL="${PORTAL_UPLOAD_META_URL:-}"
PORTAL_UPLOAD_META_TOKEN="${PORTAL_UPLOAD_META_TOKEN:-}"

tg() {
  [[ -x "${NOTIFY_BIN}" ]] && "${NOTIFY_BIN}" "$*" || true
}

if [[ -z "${PORTAL_UPLOAD_META_URL}" || -z "${PORTAL_UPLOAD_META_TOKEN}" ]]; then
  exit 0
fi
if ! command -v jq >/dev/null 2>&1 || ! command -v curl >/dev/null 2>&1; then
  exit 0
fi

base="${PORTAL_UPLOAD_META_URL%/}"

# ---- 1) Prosody → portal sync (source of truth for "live") ---------------- #
if [[ -x "${ACTIVE_ROOMS_BIN}" ]]; then
  rooms_json="$("${ACTIVE_ROOMS_BIN}" 2>/dev/null)" || rooms_json=""
  if echo "${rooms_json}" | jq -e 'has("prosody_ok")' >/dev/null 2>&1; then
    sync_body="$(echo "${rooms_json}" | jq -c '{
      prosody_ok: (.prosody_ok == true),
      active_rooms: (.rooms // [])
    }')"
    curl -sS --connect-timeout 8 --max-time 20 \
      -X POST \
      -H "Authorization: Bearer ${PORTAL_UPLOAD_META_TOKEN}" \
      -H "Content-Type: application/json" \
      -H "Accept: application/json" \
      -d "${sync_body}" \
      "${base}/portal/api/jitsi/sync-live/" >/dev/null 2>&1 || true
  fi
fi

# ---- 2) Telegram OPENED/CLOSED from reconciled portal state --------------- #
url="${base}/portal/api/jitsi/live-meetings/"
resp="$(curl -sS --connect-timeout 8 --max-time 20 \
  -H "Authorization: Bearer ${PORTAL_UPLOAD_META_TOKEN}" \
  -H "Accept: application/json" \
  "${url}" 2>/dev/null)" || exit 0

if ! echo "${resp}" | jq -e '.ok == true' >/dev/null 2>&1; then
  exit 0
fi

# room → human line
CUR_JSON="$(echo "${resp}" | jq -c '
  [.meetings[]? | {
    room: (.room // ""),
    line: (
      "teacher=\(.teacher_name // "?") (@\(.teacher_username // "?"))\n" +
      "group=\(.group_name // "?")\n" +
      "room=\(.room // "?")\n" +
      "started=\(.started_at // "?")"
    )
  } | select(.room != "")]
' 2>/dev/null || echo '[]')"

CUR_ROOMS="$(echo "${CUR_JSON}" | jq -r '[.[].room] | sort | join(",")' 2>/dev/null || true)"
PREV_ROOMS=""
if [[ -f "${STATE_FILE}" ]]; then
  PREV_ROOMS="$(jq -r '.PREV_ROOMS // empty' "${STATE_FILE}" 2>/dev/null || true)"
fi

# İlk run — baseline, spam olmasın (mövcud open meetinglər üçün flood yox)
if [[ ! -f "${STATE_FILE}" ]]; then
  jq -nc --arg r "${CUR_ROOMS}" '{PREV_ROOMS:$r}' >"${STATE_FILE}" 2>/dev/null || true
  chmod 600 "${STATE_FILE}" 2>/dev/null || true
  exit 0
fi

IFS=',' read -r -a prev_a <<< "${PREV_ROOMS}"
IFS=',' read -r -a cur_a <<< "${CUR_ROOMS}"

# OPENED
for room in "${cur_a[@]}"; do
  [[ -z "${room}" ]] && continue
  found=0
  for p in "${prev_a[@]}"; do [[ "${p}" == "${room}" ]] && found=1 && break; done
  if (( !found )); then
    line="$(echo "${CUR_JSON}" | jq -r --arg r "${room}" '.[] | select(.room==$r) | .line' 2>/dev/null)"
    tg "Jitsi meeting OPENED @ ${DOMAIN:-?}
${line:-room=${room}}"
  fi
done

# CLOSED
for room in "${prev_a[@]}"; do
  [[ -z "${room}" ]] && continue
  found=0
  for c in "${cur_a[@]}"; do [[ "${c}" == "${room}" ]] && found=1 && break; done
  if (( !found )); then
    tg "Jitsi meeting CLOSED @ ${DOMAIN:-?}
room=${room}"
  fi
done

jq -nc --arg r "${CUR_ROOMS}" '{PREV_ROOMS:$r}' >"${STATE_FILE}" 2>/dev/null || true
chmod 600 "${STATE_FILE}" 2>/dev/null || true
exit 0

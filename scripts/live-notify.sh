#!/usr/bin/env bash
# meet-control cron (hər dəqiqə):
#  Prosody active rooms → Telegram yalnız Meeting başladıldı / Meeting bitdi
#  State-file diff: hər otaq lifecycle-də bir dəfə.
#  flock: paralel cron run spam etməsin.
#  sticky grace: Prosody bir neçə dəqiqə otağı "yox" saysa belə dərhal bitdi/başladı spam etmə.
#  Portal sync-live / live-meetings çağırılmır.

set +e
set +u

export PATH="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin:${PATH:-}"

NOTIFY_BIN="${NOTIFY_BIN:-/opt/jitsi-cluster/telegram-notify.sh}"
ACTIVE_ROOMS_BIN="${ACTIVE_ROOMS_BIN:-/opt/jitsi-cluster/active-rooms.sh}"
STATE_DIR="${STATE_DIR:-/var/lib/jitsi-cluster}"
STATE_FILE="${STATE_DIR}/live-notify-state.json"
LOCK_FILE="${STATE_DIR}/live-notify.lock"
CLUSTER_ENV="${CLUSTER_ENV:-/opt/jitsi-cluster/cluster.env}"
# Prosody human-count flicker: bu qədər saniyə "yox" qalsa sonra Meeting bitdi
MISSING_GRACE_SEC="${MISSING_GRACE_SEC:-180}"

mkdir -p "${STATE_DIR}" 2>/dev/null || true

# Parallel cron (köhnə ikili cron.d) eyni anda işləməsin.
exec 9>"${LOCK_FILE}"
if ! flock -n 9; then
  exit 0
fi

if [[ -r "${CLUSTER_ENV}" ]]; then
  # shellcheck disable=SC1090
  set -a
  # shellcheck source=/dev/null
  source "${CLUSTER_ENV}"
  set +a
fi
if [[ -r /opt/jitsi-cluster/telegram.env ]]; then
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

# ISO / epoch / empty → "26 05 2026 saat 14:40 da" (GNU date on meet-control)
format_vaxt() {
  local raw="${1:-}" out=""
  if [[ -n "${raw}" ]]; then
    out="$(date -d "${raw}" '+%d %m %Y saat %H:%M da' 2>/dev/null || true)"
  fi
  if [[ -z "${out}" ]]; then
    out="$(date '+%d %m %Y saat %H:%M da')"
  fi
  printf '%s' "${out}"
}

# title teacher email group room vaxt_raw
fmt_action_msg() {
  local title="$1" teacher="$2" email="$3" group="$4" room="$5" vaxt_raw="$6"
  local vaxt
  vaxt="$(format_vaxt "${vaxt_raw}")"
  [[ -n "${teacher}" ]] || teacher="?"
  [[ -n "${email}" ]] || email="—"
  [[ -n "${group}" ]] || group="?"
  [[ -n "${room}" ]] || room="?"
  printf '%s\nVaxt: %s\nMuellim-%s (%s)\nGrup- %s\notaq nomresi:%s' \
    "${title}" "${vaxt}" "${teacher}" "${email}" "${group}" "${room}"
}

fetch_room_meta() {
  local room="$1" base token url resp
  base="${PORTAL_UPLOAD_META_URL:-}"
  token="${PORTAL_UPLOAD_META_TOKEN:-}"
  if [[ -z "${base}" || -z "${token}" || -z "${room}" ]]; then
    echo '{"teacher_name":"","teacher_email":"","group_name":""}'
    return 0
  fi
  base="${base%/}"
  url="${base}/portal/api/jitsi/room/${room}/upload-meta/"
  resp="$(curl -sS --connect-timeout 8 --max-time 20 \
    -H "Authorization: Bearer ${token}" \
    -H "Accept: application/json" \
    "${url}" 2>/dev/null)" || {
    echo '{"teacher_name":"","teacher_email":"","group_name":""}'
    return 0
  }
  echo "${resp}" | jq -c '{
    teacher_name: (.teacher_name // ""),
    teacher_email: (.teacher_email // ""),
    group_name: (.group_name // "")
  }' 2>/dev/null || echo '{"teacher_name":"","teacher_email":"","group_name":""}'
}

epoch_of() {
  local raw="${1:-}"
  if [[ -n "${raw}" ]]; then
    date -d "${raw}" +%s 2>/dev/null || echo ""
  else
    echo ""
  fi
}

if ! command -v jq >/dev/null 2>&1 || ! command -v curl >/dev/null 2>&1; then
  exit 0
fi
if [[ ! -x "${ACTIVE_ROOMS_BIN}" ]]; then
  exit 0
fi

rooms_json="$("${ACTIVE_ROOMS_BIN}" 2>/dev/null)" || rooms_json=""
if ! echo "${rooms_json}" | jq -e '.prosody_ok == true' >/dev/null 2>&1; then
  # Prosody down — do not invent closes/opens; keep previous state.
  exit 0
fi

NOW_ISO="$(date -Iseconds 2>/dev/null || date '+%Y-%m-%dT%H:%M:%S%z')"
NOW_EPOCH="$(date +%s)"

# Seen this tick from Prosody
SEEN_MAP='{}'
while IFS= read -r room; do
  [[ -z "${room}" ]] && continue
  meta="$(fetch_room_meta "${room}")"
  SEEN_MAP="$(jq -c --arg r "${room}" --argjson m "${meta}" --arg s "${NOW_ISO}" '
    . + {
      ($r): {
        teacher_name: ($m.teacher_name // ""),
        teacher_email: ($m.teacher_email // ""),
        group_name: ($m.group_name // ""),
        started_at: $s,
        missing_since: null
      }
    }
  ' <<<"${SEEN_MAP}")"
done < <(echo "${rooms_json}" | jq -r '.rooms[]?.room // empty' 2>/dev/null)

PREV_MAP='{}'
if [[ -f "${STATE_FILE}" ]]; then
  PREV_MAP="$(jq -c '.meetings // {}' "${STATE_FILE}" 2>/dev/null || echo '{}')"
  if [[ "${PREV_MAP}" == "null" ]]; then
    PREV_MAP='{}'
  fi
  # Backward compat: older state only had PREV_ROOMS
  if [[ "${PREV_MAP}" == "{}" ]]; then
    PREV_ROOMS="$(jq -r '.PREV_ROOMS // empty' "${STATE_FILE}" 2>/dev/null || true)"
    if [[ -n "${PREV_ROOMS}" ]]; then
      PREV_MAP="$(jq -nc --arg r "${PREV_ROOMS}" --arg s "${NOW_ISO}" '
        reduce ($r | split(",") | .[] | select(length>0)) as $room ({};
          . + {($room): {teacher_name:"",teacher_email:"",group_name:"",started_at:$s,missing_since:null}}
        )
      ' 2>/dev/null || echo '{}')"
    fi
  fi
fi

# İlk run — baseline, spam olmasın
if [[ ! -f "${STATE_FILE}" ]]; then
  jq -nc --argjson m "${SEEN_MAP}" '{meetings:$m}' >"${STATE_FILE}" 2>/dev/null || true
  chmod 600 "${STATE_FILE}" 2>/dev/null || true
  exit 0
fi

NEXT_MAP='{}'
OPENED=()
CLOSED=()

# 1) Rooms currently visible in Prosody
while IFS= read -r room; do
  [[ -z "${room}" ]] && continue
  seen="$(echo "${SEEN_MAP}" | jq -c --arg r "${room}" '.[$r]' 2>/dev/null)"
  prev="$(echo "${PREV_MAP}" | jq -c --arg r "${room}" '.[$r] // null' 2>/dev/null)"

  if [[ "${prev}" == "null" || -z "${prev}" ]]; then
    OPENED+=("${room}")
    entry="$(echo "${seen}" | jq -c --arg s "${NOW_ISO}" '
      .started_at = (if (.started_at // "") != "" then .started_at else $s end)
      | .missing_since = null
    ')"
  else
    # Reappear after brief miss → eyni meeting, yenidən "başladı" yox
    entry="$(jq -nc --argjson prev "${prev}" --argjson seen "${seen}" --arg s "${NOW_ISO}" '
      {
        teacher_name: (
          if (($seen.teacher_name // "") != "") then $seen.teacher_name
          else ($prev.teacher_name // "") end
        ),
        teacher_email: (
          if (($seen.teacher_email // "") != "") then $seen.teacher_email
          else ($prev.teacher_email // "") end
        ),
        group_name: (
          if (($seen.group_name // "") != "") then $seen.group_name
          else ($prev.group_name // "") end
        ),
        started_at: ($prev.started_at // $seen.started_at // $s),
        missing_since: null
      }
    ')"
  fi
  NEXT_MAP="$(jq -c --arg r "${room}" --argjson e "${entry}" '. + {($r): $e}' <<<"${NEXT_MAP}")"
done < <(echo "${SEEN_MAP}" | jq -r 'keys[]' 2>/dev/null)

# 2) Previously tracked rooms missing this tick — sticky grace before close
while IFS= read -r room; do
  [[ -z "${room}" ]] && continue
  if echo "${SEEN_MAP}" | jq -e --arg r "${room}" 'has($r)' >/dev/null 2>&1; then
    continue
  fi
  prev="$(echo "${PREV_MAP}" | jq -c --arg r "${room}" '.[$r]' 2>/dev/null)"
  [[ "${prev}" == "null" || -z "${prev}" ]] && continue

  miss_raw="$(echo "${prev}" | jq -r '.missing_since // empty')"
  if [[ -z "${miss_raw}" || "${miss_raw}" == "null" ]]; then
    # İlk "yox" tick — hələ bitdi demə
    entry="$(echo "${prev}" | jq -c --arg s "${NOW_ISO}" '.missing_since = $s')"
    NEXT_MAP="$(jq -c --arg r "${room}" --argjson e "${entry}" '. + {($r): $e}' <<<"${NEXT_MAP}")"
    continue
  fi

  miss_epoch="$(epoch_of "${miss_raw}")"
  if [[ -n "${miss_epoch}" ]] && (( NOW_EPOCH - miss_epoch < MISSING_GRACE_SEC )); then
    # Hələ grace içində — state saxla, mesaj yox
    NEXT_MAP="$(jq -c --arg r "${room}" --argjson e "${prev}" '. + {($r): $e}' <<<"${NEXT_MAP}")"
    continue
  fi

  # Grace bitdi → Meeting bitdi, state-dən çıx
  CLOSED+=("${room}")
done < <(echo "${PREV_MAP}" | jq -r 'keys[]' 2>/dev/null)

for room in "${OPENED[@]}"; do
  [[ -z "${room}" ]] && continue
  teacher="$(echo "${NEXT_MAP}" | jq -r --arg r "${room}" '.[$r].teacher_name // empty')"
  email="$(echo "${NEXT_MAP}" | jq -r --arg r "${room}" '.[$r].teacher_email // empty')"
  group="$(echo "${NEXT_MAP}" | jq -r --arg r "${room}" '.[$r].group_name // empty')"
  started="$(echo "${NEXT_MAP}" | jq -r --arg r "${room}" '.[$r].started_at // empty')"
  tg "$(fmt_action_msg "Meeting başladıldı:" "${teacher}" "${email}" "${group}" "${room}" "${started}")"
done

for room in "${CLOSED[@]}"; do
  [[ -z "${room}" ]] && continue
  teacher="$(echo "${PREV_MAP}" | jq -r --arg r "${room}" '.[$r].teacher_name // empty')"
  email="$(echo "${PREV_MAP}" | jq -r --arg r "${room}" '.[$r].teacher_email // empty')"
  group="$(echo "${PREV_MAP}" | jq -r --arg r "${room}" '.[$r].group_name // empty')"
  tg "$(fmt_action_msg "Meeting bitdi:" "${teacher}" "${email}" "${group}" "${room}" "")"
done

jq -nc --argjson m "${NEXT_MAP}" '{meetings:$m}' >"${STATE_FILE}" 2>/dev/null || true
chmod 600 "${STATE_FILE}" 2>/dev/null || true
exit 0

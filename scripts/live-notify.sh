#!/usr/bin/env bash
# meet-control cron (hər dəqiqə):
#  Prosody active rooms → Telegram yalnız Meeting başladıldı / Meeting bitdi
#  State-file diff: hər otaq üçün lifecycle-də bir dəfə (spam yoxdur).
#  Portal sync-live / live-meetings çağırılmır.
# Exception / health / CRITICAL mesajlara toxunmur.

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

# room → {teacher_name,teacher_email,group_name,started_at}
CUR_MAP='{}'
while IFS= read -r room; do
  [[ -z "${room}" ]] && continue
  meta="$(fetch_room_meta "${room}")"
  started="$(date -Iseconds 2>/dev/null || date '+%Y-%m-%dT%H:%M:%S%z')"
  CUR_MAP="$(jq -c --arg r "${room}" --argjson m "${meta}" --arg s "${started}" '
    . + {
      ($r): {
        teacher_name: ($m.teacher_name // ""),
        teacher_email: ($m.teacher_email // ""),
        group_name: ($m.group_name // ""),
        started_at: $s
      }
    }
  ' <<<"${CUR_MAP}")"
done < <(echo "${rooms_json}" | jq -r '.rooms[]?.room // empty' 2>/dev/null)

CUR_ROOMS="$(echo "${CUR_MAP}" | jq -r 'keys | sort | join(",")' 2>/dev/null || true)"
PREV_MAP='{}'
PREV_ROOMS=""
if [[ -f "${STATE_FILE}" ]]; then
  PREV_MAP="$(jq -c '.meetings // {}' "${STATE_FILE}" 2>/dev/null || echo '{}')"
  if [[ "${PREV_MAP}" == "{}" || "${PREV_MAP}" == "null" ]]; then
    PREV_ROOMS="$(jq -r '.PREV_ROOMS // empty' "${STATE_FILE}" 2>/dev/null || true)"
    if [[ -n "${PREV_ROOMS}" ]]; then
      PREV_MAP="$(jq -nc --arg r "${PREV_ROOMS}" '
        reduce ($r | split(",") | .[] | select(length>0)) as $room ({}; . + {($room): {}})
      ' 2>/dev/null || echo '{}')"
    else
      PREV_MAP='{}'
    fi
  fi
  PREV_ROOMS="$(echo "${PREV_MAP}" | jq -r 'keys | sort | join(",")' 2>/dev/null || true)"
fi

# Keep prior started_at / meta when room still open (avoid rewriting timestamps).
CUR_MAP="$(jq -c --argjson prev "${PREV_MAP}" --argjson cur "${CUR_MAP}" '
  reduce ($cur | keys[]) as $r ({};
    . + {
      ($r): (
        if ($prev[$r] != null) then
          {
            teacher_name: (
              if (($cur[$r].teacher_name // "") != "") then $cur[$r].teacher_name
              else ($prev[$r].teacher_name // "") end
            ),
            teacher_email: (
              if (($cur[$r].teacher_email // "") != "") then $cur[$r].teacher_email
              else ($prev[$r].teacher_email // "") end
            ),
            group_name: (
              if (($cur[$r].group_name // "") != "") then $cur[$r].group_name
              else ($prev[$r].group_name // "") end
            ),
            started_at: ($prev[$r].started_at // $cur[$r].started_at // "")
          }
        else $cur[$r]
        end
      )
    }
  )
' 2>/dev/null || echo "${CUR_MAP}")"

# İlk run — baseline, spam olmasın
if [[ ! -f "${STATE_FILE}" ]]; then
  jq -nc --argjson m "${CUR_MAP}" '{meetings:$m}' >"${STATE_FILE}" 2>/dev/null || true
  chmod 600 "${STATE_FILE}" 2>/dev/null || true
  exit 0
fi

IFS=',' read -r -a prev_a <<< "${PREV_ROOMS}"
IFS=',' read -r -a cur_a <<< "${CUR_ROOMS}"

# Meeting başladı — yalnız yeni otaq
for room in "${cur_a[@]}"; do
  [[ -z "${room}" ]] && continue
  found=0
  for p in "${prev_a[@]}"; do [[ "${p}" == "${room}" ]] && found=1 && break; done
  if (( !found )); then
    teacher="$(echo "${CUR_MAP}" | jq -r --arg r "${room}" '.[$r].teacher_name // empty')"
    email="$(echo "${CUR_MAP}" | jq -r --arg r "${room}" '.[$r].teacher_email // empty')"
    group="$(echo "${CUR_MAP}" | jq -r --arg r "${room}" '.[$r].group_name // empty')"
    started="$(echo "${CUR_MAP}" | jq -r --arg r "${room}" '.[$r].started_at // empty')"
    tg "$(fmt_action_msg "Meeting başladıldı:" "${teacher}" "${email}" "${group}" "${room}" "${started}")"
  fi
done

# Meeting bitdi — yalnız itən otaq
for room in "${prev_a[@]}"; do
  [[ -z "${room}" ]] && continue
  found=0
  for c in "${cur_a[@]}"; do [[ "${c}" == "${room}" ]] && found=1 && break; done
  if (( !found )); then
    teacher="$(echo "${PREV_MAP}" | jq -r --arg r "${room}" '.[$r].teacher_name // empty')"
    email="$(echo "${PREV_MAP}" | jq -r --arg r "${room}" '.[$r].teacher_email // empty')"
    group="$(echo "${PREV_MAP}" | jq -r --arg r "${room}" '.[$r].group_name // empty')"
    tg "$(fmt_action_msg "Meeting bitdi:" "${teacher}" "${email}" "${group}" "${room}" "")"
  fi
done

jq -nc --argjson m "${CUR_MAP}" '{meetings:$m}' >"${STATE_FILE}" 2>/dev/null || true
chmod 600 "${STATE_FILE}" 2>/dev/null || true
exit 0

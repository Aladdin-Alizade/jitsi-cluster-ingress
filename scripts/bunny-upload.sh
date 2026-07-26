#!/usr/bin/env bash
# Recording bitəndən sonra: Bunny Stream-ə yüklə (Ingress portal ilə eyni API)
# Axın: create video → PUT binary → uğurlu olsa lokal sil
# Jibri finalize_recording.sh tərəfindən çağırılır
# 5 paralel Jibri eyni anda finalize edə bilər — hər çağırış öz temp faylından istifadə edir
#
# Portal: portal/bunny_stream.py → video.bunnycdn.com/library/{id}/videos

set -euo pipefail

LOG_TAG="bunny-upload"
# log → stderr (stdout yalnız collection_id / video_id üçün — command substitution pozulmasın)
log()  { echo "[$(date -Iseconds)] [${LOG_TAG}] $*" >&2; }
err()  { echo "[$(date -Iseconds)] [${LOG_TAG}] ERROR: $*" >&2; }

# Əskik alətlər — mümkün qədər avtomatik (root deyilsə xəbərdarlıq)
need_cmd() {
  local cmd="$1" pkg="${2:-$1}"
  if command -v "${cmd}" >/dev/null 2>&1; then
    return 0
  fi
  if [[ "${EUID:-$(id -u)}" -eq 0 ]] && command -v apt-get >/dev/null 2>&1; then
    log "${cmd} yoxdur — ${pkg} quraşdırılır..."
    apt-get update -qq >/dev/null 2>&1 || true
    apt-get install -y -qq "${pkg}" >/dev/null 2>&1 || true
  fi
  if ! command -v "${cmd}" >/dev/null 2>&1; then
    err "${cmd} lazımdır (paket: ${pkg})"
    return 1
  fi
}

need_cmd curl curl || exit 1
need_cmd jq jq || exit 1

ENV_FILE="${BUNNY_ENV_FILE:-/opt/jitsi-jibri/bunny.env}"
if [[ -f "${ENV_FILE}" ]]; then
  # shellcheck disable=SC1090
  set -a
  # shellcheck source=/dev/null
  source "${ENV_FILE}"
  set +a
elif [[ -z "${BUNNY_LIBRARY_ID:-}" || -z "${BUNNY_API_KEY:-}" ]]; then
  err "bunny.env tapılmadı: ${ENV_FILE}"
  exit 1
fi

TG_BIN="${TELEGRAM_NOTIFY_BIN:-/opt/jitsi-jibri/telegram-notify.sh}"
[[ -x "${TG_BIN}" ]] || TG_BIN="/opt/jitsi-cluster/telegram-notify.sh"
tg() { [[ -x "${TG_BIN}" ]] && "${TG_BIN}" "$*" || true; }

RECORDING_DIR="${1:-}"
if [[ -z "${RECORDING_DIR}" || ! -d "${RECORDING_DIR}" ]]; then
  err "Recording directory yoxdur: ${RECORDING_DIR}"
  exit 1
fi

if [[ -z "${BUNNY_LIBRARY_ID:-}" || -z "${BUNNY_API_KEY:-}" ]]; then
  err "BUNNY_LIBRARY_ID / BUNNY_API_KEY lazımdır (Stream → Video library ID + API Key)"
  exit 1
fi

CDN_HOST="${BUNNY_CDN_HOSTNAME:-}"
STREAM_API="https://video.bunnycdn.com"
LIBRARY_ID="${BUNNY_LIBRARY_ID}"
API_KEY="${BUNNY_API_KEY}"

# Paralel slotlar üçün unikal temp (5 Jibri eyni anda /tmp-də toqquşmasın)
WORKDIR="$(mktemp -d /tmp/jibri-upload.XXXXXX)"
trap 'rm -rf "${WORKDIR}"' EXIT
RESP_FILE="${WORKDIR}/resp.txt"

# Find mp4/mkv files
MP4S=()
while IFS= read -r -d '' f; do
  MP4S+=("$f")
done < <(find "${RECORDING_DIR}" -type f \( -name '*.mp4' -o -name '*.mkv' -o -name '*.webm' \) -print0 | sort -z)

if [[ ${#MP4S[@]} -eq 0 ]]; then
  err "MP4/MKV/WEBM tapılmadı: ${RECORDING_DIR}"
  exit 1
fi

# Jibri recording dir basename = session_id (NOT the Meet room).
# Real room is in metadata.json meeting_url, or the MP4 prefix (callName).
resolve_room_name() {
  local dir="$1"
  local meta url room fname base
  meta="${dir}/metadata.json"
  if [[ -f "${meta}" ]]; then
    url="$(jq -r '.meeting_url // .meetingUrl // empty' "${meta}" 2>/dev/null || true)"
    if [[ -n "${url}" ]]; then
      # https://meet.example.com/ROOM?foo → ROOM
      room="$(printf '%s' "${url}" | sed -E 's|[?#].*$||; s|/*$||; s|^.*/||')"
      room="$(printf '%s' "${room}" | sed 's/[^a-zA-Z0-9._-]/_/g')"
      if [[ -n "${room}" ]]; then
        echo "${room}"
        return 0
      fi
    fi
  fi
  # Fallback: FileSink names files "{callName}_{timestamp}.mp4"
  fname="$(basename "${MP4S[0]}")"
  base="${fname%.*}"
  if [[ "${base}" =~ ^(.+)_[0-9]{4}-[0-9]{2}-[0-9]{2}-[0-9]{2}-[0-9]{2}-[0-9]{2}$ ]]; then
    room="$(printf '%s' "${BASH_REMATCH[1]}" | sed 's/[^a-zA-Z0-9._-]/_/g')"
    if [[ -n "${room}" ]]; then
      echo "${room}"
      return 0
    fi
  fi
  # Last resort (usually Jibri session_id — portal will 404)
  basename "${dir}" | sed 's/[^a-zA-Z0-9._-]/_/g'
}

ROOM_NAME="$(resolve_room_name "${RECORDING_DIR}")"
log "Resolved room name: ${ROOM_NAME} (dir=$(basename "${RECORDING_DIR}"))"
DATE_STAMP="$(date +%Y-%m-%d)"
OK=0
META_OUT="/var/log/jitsi/bunny-uploads.jsonl"
mkdir -p "$(dirname "${META_OUT}")" 2>/dev/null || true
# Log yazıla bilməsə — /tmp-yə düş
if ! touch "${META_OUT}" 2>/dev/null; then
  META_OUT="${WORKDIR}/bunny-uploads.jsonl"
  warn_meta=1
else
  warn_meta=0
fi
[[ "${warn_meta}" -eq 1 ]] && log "bunny-uploads.jsonl yazıla bilmədi — ${META_OUT} istifadə olunur"

create_video() {
  local title="$1"
  local collection_id="${2:-}"
  local body resp
  if [[ -n "${collection_id}" ]]; then
    body="$(jq -nc --arg t "${title}" --arg c "${collection_id}" '{title:$t, collectionId:$c}')"
  else
    body="$(jq -nc --arg t "${title}" '{title:$t}')"
  fi
  resp="$(curl -sS --connect-timeout 15 --max-time 60 -X POST \
    "${STREAM_API}/library/${LIBRARY_ID}/videos" \
    -H "AccessKey: ${API_KEY}" \
    -H "Accept: application/json" \
    -H "Content-Type: application/json" \
    --data "${body}" 2>"${WORKDIR}/create.err")" || {
    err "create_video curl fail: $(cat "${WORKDIR}/create.err" 2>/dev/null || true)"
    return 1
  }

  # guid field (Bunny Stream create response — portal bunny_stream.create_video)
  echo "${resp}" | jq -r '.guid // empty'
}

# Resolve teacher+group Bunny collection via ingress portal (room UUID → collection_id).
# Optional: PORTAL_UPLOAD_META_URL + PORTAL_UPLOAD_META_TOKEN in bunny.env
# Also writes group_name to ${WORKDIR}/meta_group.txt when available.
resolve_collection_id() {
  local room="$1"
  local base token url resp cid gname
  : > "${WORKDIR}/meta_group.txt"
  base="${PORTAL_UPLOAD_META_URL:-}"
  token="${PORTAL_UPLOAD_META_TOKEN:-}"
  if [[ -z "${base}" || -z "${token}" || -z "${room}" ]]; then
    echo ""
    return 0
  fi
  base="${base%/}"
  url="${base}/portal/api/jitsi/room/${room}/upload-meta/"
  resp="$(curl -sS --connect-timeout 10 --max-time 30 \
    -H "Authorization: Bearer ${token}" \
    -H "Accept: application/json" \
    "${url}" 2>"${WORKDIR}/meta.err")" || {
    err "upload-meta curl fail: $(cat "${WORKDIR}/meta.err" 2>/dev/null || true)"
    echo ""
    return 0
  }
  cid="$(echo "${resp}" | jq -r '.collection_id // empty' 2>/dev/null || true)"
  gname="$(echo "${resp}" | jq -r '.group_name // empty' 2>/dev/null || true)"
  [[ -n "${gname}" ]] && printf '%s' "${gname}" > "${WORKDIR}/meta_group.txt"
  # Yalnız GUID qəbul et — log/HTML qarışmasın
  if [[ ! "${cid}" =~ ^[0-9a-fA-F-]{8,}$ ]]; then
    cid=""
  fi
  if [[ -z "${cid}" ]]; then
    log "upload-meta: collection yoxdur (room=${room}) — library root-a yazılacaq"
    log "upload-meta response: ${resp}"
  else
    log "upload-meta: collection=${cid} group=${gname:-?} (room=${room})"
  fi
  echo "${cid}"
}

set_video_collection() {
  local video_id="$1"
  local collection_id="$2"
  [[ -z "${video_id}" || -z "${collection_id}" ]] && return 0
  local body
  body="$(jq -nc --arg c "${collection_id}" '{collectionId:$c}')"
  curl -sS --connect-timeout 15 --max-time 30 -X POST \
    "${STREAM_API}/library/${LIBRARY_ID}/videos/${video_id}" \
    -H "AccessKey: ${API_KEY}" \
    -H "Accept: application/json" \
    -H "Content-Type: application/json" \
    --data "${body}" >/dev/null 2>"${WORKDIR}/setcol.err" || {
    err "set_video_collection fail: $(cat "${WORKDIR}/setcol.err" 2>/dev/null || true)"
    return 1
  }
  log "Video ${video_id} → collection ${collection_id}"
}

# Tell ingress portal to create a draft GroupLesson for this Bunny video.
# Best-effort: Bunny upload already succeeded — failure is logged, not fatal.
notify_portal_recording_complete() {
  local room="$1"
  local video_id="$2"
  local base token url body resp http_code attempt
  base="${PORTAL_UPLOAD_META_URL:-}"
  token="${PORTAL_UPLOAD_META_TOKEN:-}"
  if [[ -z "${base}" || -z "${token}" || -z "${room}" || -z "${video_id}" ]]; then
    log "recording-complete skip (portal url/token/room/video missing)"
    return 0
  fi
  base="${base%/}"
  url="${base}/portal/api/jitsi/room/${room}/recording-complete/"
  body="$(jq -nc --arg v "${video_id}" '{video_id:$v}')"
  for attempt in 1 2 3; do
    http_code="$(curl -sS -o "${WORKDIR}/recording-complete.json" -w '%{http_code}' \
      --connect-timeout 10 --max-time 30 \
      -X POST "${url}" \
      -H "Authorization: Bearer ${token}" \
      -H "Accept: application/json" \
      -H "Content-Type: application/json" \
      --data "${body}" 2>"${WORKDIR}/recording-complete.err" || echo "000")"
    if [[ "${http_code}" =~ ^20[0-9]$ ]]; then
      resp="$(cat "${WORKDIR}/recording-complete.json" 2>/dev/null || true)"
      log "recording-complete OK (${http_code}): ${resp}"
      return 0
    fi
    err "recording-complete attempt ${attempt}/3 HTTP ${http_code}: $(cat "${WORKDIR}/recording-complete.err" 2>/dev/null; cat "${WORKDIR}/recording-complete.json" 2>/dev/null || true)"
    sleep $((attempt * 2))
  done
  err "recording-complete failed for room=${room} video_id=${video_id} — lesson not auto-created"
  return 1
}

upload_video_file() {
  local video_id="$1"
  local file_path="$2"
  local http_code
  http_code="$(curl -sS -o "${RESP_FILE}" -w '%{http_code}' \
    --connect-timeout 30 --max-time 3600 \
    --retry 3 --retry-delay 5 \
    -X PUT \
    "${STREAM_API}/library/${LIBRARY_ID}/videos/${video_id}" \
    -H "AccessKey: ${API_KEY}" \
    -H "Content-Type: application/octet-stream" \
    --data-binary @"${file_path}" || echo "000")"
  echo "${http_code}"
}

COLLECTION_ID="$(resolve_collection_id "${ROOM_NAME}")"
GROUP_NAME="$(cat "${WORKDIR}/meta_group.txt" 2>/dev/null || true)"

for SRC in "${MP4S[@]}"; do
  FNAME="$(basename "${SRC}")"
  if [[ -n "${GROUP_NAME}" ]]; then
    TITLE="${GROUP_NAME} · ${DATE_STAMP} · live"
  else
    TITLE="${ROOM_NAME} · ${DATE_STAMP} · ${FNAME}"
  fi
  # Bunny title limit ~255
  TITLE="${TITLE:0:250}"

  log "Create video: ${TITLE}${COLLECTION_ID:+ (collection=${COLLECTION_ID})}"
  VIDEO_ID="$(create_video "${TITLE}" "${COLLECTION_ID}" || true)"
  if [[ -z "${VIDEO_ID}" || "${VIDEO_ID}" == "null" ]]; then
    err "Bunny Stream video ID qaytarmadı"
    cat "${RESP_FILE}" 2>/dev/null || true
    continue
  fi
  log "Video ID: ${VIDEO_ID}"
  if [[ -n "${COLLECTION_ID}" ]]; then
    set_video_collection "${VIDEO_ID}" "${COLLECTION_ID}" || true
  fi

  log "Upload: ${SRC}"
  HTTP_CODE="$(upload_video_file "${VIDEO_ID}" "${SRC}")"

  if [[ "${HTTP_CODE}" =~ ^20[0-9]$ ]]; then
    EMBED_URL="https://iframe.mediadelivery.net/embed/${LIBRARY_ID}/${VIDEO_ID}"
    PLAY_HINT=""
    if [[ -n "${CDN_HOST}" ]]; then
      PLAY_HINT="https://${CDN_HOST}/${VIDEO_ID}/play_720p.mp4"
    fi

    log "OK (${HTTP_CODE}): library=${LIBRARY_ID} video=${VIDEO_ID} collection=${COLLECTION_ID:-root}"
    log "Embed: ${EMBED_URL}"
    [[ -n "${PLAY_HINT}" ]] && log "CDN hint: ${PLAY_HINT}"

    # Log for portal / ops (video GUID — Ingress portal bunny_video_id kimi)
    printf '%s\n' "$(jq -nc \
      --arg local "${SRC}" \
      --arg room "${ROOM_NAME}" \
      --arg video_id "${VIDEO_ID}" \
      --arg library_id "${LIBRARY_ID}" \
      --arg collection_id "${COLLECTION_ID}" \
      --arg embed_url "${EMBED_URL}" \
      --arg cdn_host "${CDN_HOST}" \
      --arg uploaded_at "$(date -Iseconds)" \
      --argjson http_code "${HTTP_CODE}" \
      '{local:$local,room:$room,video_id:$video_id,library_id:$library_id,collection_id:$collection_id,embed_url:$embed_url,cdn_hostname:$cdn_host,uploaded_at:$uploaded_at,http_code:$http_code}')" \
      >> "${META_OUT}"

    # Auto-create published lesson on ingress portal (title: DD.MM.YYYY-part-N)
    notify_portal_recording_complete "${ROOM_NAME}" "${VIDEO_ID}" || true

    tg "Jitsi Bunny upload OK
room=${ROOM_NAME}
video_id=${VIDEO_ID}
library=${LIBRARY_ID}
collection=${COLLECTION_ID:-root}"

    rm -f "${SRC}"
    OK=1
  else
    err "Upload failed HTTP ${HTTP_CODE} for ${SRC} (video_id=${VIDEO_ID})"
    cat "${RESP_FILE}" >&2 || true
    tg "Jitsi Bunny upload FAIL
room=${ROOM_NAME}
video_id=${VIDEO_ID}
http=${HTTP_CODE}"
    # Best-effort cleanup of empty video object
    curl -sS --connect-timeout 10 --max-time 30 -X DELETE \
      "${STREAM_API}/library/${LIBRARY_ID}/videos/${VIDEO_ID}" \
      -H "AccessKey: ${API_KEY}" \
      -H "Accept: application/json" >/dev/null 2>&1 || true
  fi
done

if [[ "${OK}" -eq 1 ]]; then
  if [[ -z "$(find "${RECORDING_DIR}" -type f \( -name '*.mp4' -o -name '*.mkv' -o -name '*.webm' \) 2>/dev/null | head -1)" ]]; then
    log "Lokal recording silinir: ${RECORDING_DIR}"
    rm -rf "${RECORDING_DIR}"
  fi
  exit 0
fi

tg "Jitsi Bunny upload FAIL (no OK files) room=${ROOM_NAME:-?} dir=${RECORDING_DIR}"
exit 1

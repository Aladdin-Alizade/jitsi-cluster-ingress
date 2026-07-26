#!/usr/bin/env bash
# Jibri finalize_recording.sh hook
# Args: <recording_directory>
# Flow: wait for file settle → bunny-upload → delete local
# 5 paralel Jibri eyni anda çağıra bilər — hər biri öz recording dir-i ilə

set -euo pipefail

RECORDING_DIR="${1:-}"
LOG="/var/log/jitsi/recording-finalize.log"
UPLOAD="/opt/jitsi-jibri/bunny-upload.sh"

mkdir -p "$(dirname "${LOG}")" 2>/dev/null || true
if ! touch "${LOG}" 2>/dev/null; then
  LOG="/tmp/recording-finalize-$$.log"
fi

exec >>"${LOG}" 2>&1
echo "==== $(date -Iseconds) finalize: ${RECORDING_DIR} pid=$$ ===="

if [[ -z "${RECORDING_DIR}" || ! -d "${RECORDING_DIR}" ]]; then
  echo "Invalid recording dir: '${RECORDING_DIR}'"
  exit 1
fi

if [[ ! -x "${UPLOAD}" ]]; then
  echo "bunny-upload.sh yoxdur və ya icra edilə bilmir: ${UPLOAD}"
  # Fallback: eyni qovluqda (setup zamanı /tmp-dən kopyalanmayıbsa)
  if [[ -x "$(dirname "$0")/bunny-upload.sh" ]]; then
    UPLOAD="$(dirname "$0")/bunny-upload.sh"
    echo "Fallback upload: ${UPLOAD}"
  else
    exit 1
  fi
fi

# curl/jq yoxdursa — root ilə quraşdırma cəhdi (finalize jibri user ilə işləyir)
for pair in curl:curl jq:jq; do
  cmd="${pair%%:*}"
  pkg="${pair##*:}"
  if ! command -v "${cmd}" >/dev/null 2>&1; then
    echo "WARNING: ${cmd} yoxdur"
    if [[ "${EUID:-$(id -u)}" -eq 0 ]] && command -v apt-get >/dev/null 2>&1; then
      apt-get update -qq >/dev/null 2>&1 || true
      apt-get install -y -qq "${pkg}" >/dev/null 2>&1 || true
    fi
  fi
done

# Wait until mp4 size stabilizes (ffmpeg flush) — max ~60s
STABLE=0
for i in $(seq 1 30); do
  SIZE1="$(du -sb "${RECORDING_DIR}" 2>/dev/null | awk '{print $1}')"
  sleep 2
  SIZE2="$(du -sb "${RECORDING_DIR}" 2>/dev/null | awk '{print $1}')"
  if [[ -n "${SIZE1}" && "${SIZE1}" == "${SIZE2}" && "${SIZE1}" != "0" ]]; then
    STABLE=1
    break
  fi
  echo "settle wait ${i}/30 size=${SIZE1}->${SIZE2}"
done
[[ "${STABLE}" -eq 1 ]] || echo "WARNING: size stabilize olmadı — yenə də upload cəhdi"

# Optional: strip metadata / ensure readable
chown -R jibri:jibri "${RECORDING_DIR}" 2>/dev/null || true

TG="/opt/jitsi-jibri/telegram-notify.sh"
[[ -x "${TG}" ]] || TG="/opt/jitsi-cluster/telegram-notify.sh"
tg() { [[ -x "${TG}" ]] && "${TG}" "$*" || true; }

ROOM_HINT="$(basename "${RECORDING_DIR}")"
HOST_HINT="$(hostname -s 2>/dev/null || hostname)"

if ! "${UPLOAD}" "${RECORDING_DIR}"; then
  echo "ERROR: bunny-upload failed for ${RECORDING_DIR}"
  tg "Jitsi recording finalize FAIL @ ${HOST_HINT}: ${ROOM_HINT}"
  exit 1
fi
tg "Jitsi recording finalized @ ${HOST_HINT}: ${ROOM_HINT}"
echo "==== done $(date -Iseconds) ===="

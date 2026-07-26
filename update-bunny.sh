#!/usr/bin/env bash
# ============================================================
# update-bunny.sh — Bunny Stream + portal upload-meta + upload script
#
# .env-dəki BUNNY_* / PORTAL_UPLOAD_META_* dəyərlərini bütün
# recorder VM-lərdə /opt/jitsi-jibri/bunny.env-ə yazır və
# bunny-upload.sh / finalize_recording.sh-ı yeniləyir.
# Full deploy və ya Jibri restart lazım deyil.
#
# İstifadə:
#   1) .env-də BUNNY_LIBRARY_ID / BUNNY_API_KEY yenilə
#   2) ./update-bunny.sh
#
#   ./update-bunny.sh --dry-run
# ============================================================

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "${ROOT}"

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; NC='\033[0m'
log()  { echo -e "${GREEN}[+]${NC} $*"; }
warn() { echo -e "${YELLOW}[!]${NC} $*"; }
err()  { echo -e "${RED}[x]${NC} $*" >&2; }
die()  { err "$*"; exit 1; }

chmod +x "${ROOT}/update-bunny.sh" 2>/dev/null || true

DRY_RUN=false
while [[ $# -gt 0 ]]; do
  case "$1" in
    --dry-run) DRY_RUN=true; shift ;;
    -h|--help)
      cat <<EOF
Usage: ./update-bunny.sh [--dry-run]

.env-dən oxuyur və recorder-lərdə bunny.env + upload script yeniləyir:
  BUNNY_LIBRARY_ID
  BUNNY_API_KEY
  BUNNY_CDN_HOSTNAME          (optional)
  PORTAL_UPLOAD_META_URL      (optional)
  PORTAL_UPLOAD_META_TOKEN    (optional)
  scripts/bunny-upload.sh
  scripts/finalize_recording.sh
EOF
      exit 0
      ;;
    *) die "Naməlum arg: $1" ;;
  esac
done

[[ -f "${ROOT}/.env" ]] || die ".env tapılmadı"
[[ -f "${ROOT}/scripts/bunny-upload.sh" ]] || die "scripts/bunny-upload.sh yoxdur"
[[ -f "${ROOT}/scripts/finalize_recording.sh" ]] || die "scripts/finalize_recording.sh yoxdur"
set -a
# shellcheck disable=SC1091
source "${ROOT}/.env"
set +a

: "${GCP_PROJECT_ID:?GCP_PROJECT_ID .env-də lazımdır}"
: "${BUNNY_LIBRARY_ID:?BUNNY_LIBRARY_ID .env-də lazımdır}"
: "${BUNNY_API_KEY:?BUNNY_API_KEY .env-də lazımdır}"
GCP_ZONE="${GCP_ZONE:-europe-west1-b}"
BUNNY_CDN_HOSTNAME="${BUNNY_CDN_HOSTNAME:-}"
PORTAL_UPLOAD_META_URL="${PORTAL_UPLOAD_META_URL:-}"
PORTAL_UPLOAD_META_TOKEN="${PORTAL_UPLOAD_META_TOKEN:-}"

OUTPUTS_JSON="${ROOT}/terraform/generated/outputs.json"
[[ -f "${OUTPUTS_JSON}" ]] || die "terraform/generated/outputs.json yoxdur — əvvəl deploy olunmalıdır"

CONTROL_PUBLIC_IP="$(jq -r '.control_public_ip' "${OUTPUTS_JSON}")"
mapfile -t JIBRI_NAMES < <(jq -r '.jibri_names[]' "${OUTPUTS_JSON}")
mapfile -t JIBRI_PRIVATE_IPS < <(jq -r '.jibri_private_ips[]' "${OUTPUTS_JSON}")
(( ${#JIBRI_NAMES[@]} > 0 )) || die "Recorder VM tapılmadı (outputs.json)"

SECRETS_DIR="${ROOT}/secrets"
SSH_PRIV="${SSH_PUBLIC_KEY_PATH:-}"
if [[ -n "${SSH_PRIV}" && -f "${SSH_PRIV}" ]]; then
  SSH_PRIV="${SSH_PRIV%.pub}"
else
  SSH_PRIV="${SECRETS_DIR}/deploy_key"
fi
[[ -f "${SSH_PRIV}" ]] || die "SSH key yoxdur: ${SSH_PRIV}"

ssh_opts=(
  -o BatchMode=yes
  -o StrictHostKeyChecking=no
  -o UserKnownHostsFile=/dev/null
  -o GlobalKnownHostsFile=/dev/null
  -o ConnectTimeout=15
  -i "${SSH_PRIV}"
)
JUMP_OPTS=(
  -o "ProxyCommand=ssh -o BatchMode=yes -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o GlobalKnownHostsFile=/dev/null -i ${SSH_PRIV} -W %h:%p ubuntu@${CONTROL_PUBLIC_IP}"
)

TMP_DIR="$(mktemp -d)"
trap 'rm -rf "${TMP_DIR}"' EXIT
TMP_ENV="${TMP_DIR}/bunny.env.new"
TELEGRAM_BOT_TOKEN="${TELEGRAM_BOT_TOKEN:-}"
TELEGRAM_CHAT_ID="${TELEGRAM_CHAT_ID:-}"
TELEGRAM_TOPIC_ID="${TELEGRAM_TOPIC_ID:-}"
TELEGRAM_NOTIFY="${TELEGRAM_NOTIFY:-true}"
cat > "${TMP_ENV}" <<EOF
BUNNY_LIBRARY_ID=${BUNNY_LIBRARY_ID}
BUNNY_API_KEY=${BUNNY_API_KEY}
BUNNY_CDN_HOSTNAME=${BUNNY_CDN_HOSTNAME}
PORTAL_UPLOAD_META_URL=${PORTAL_UPLOAD_META_URL}
PORTAL_UPLOAD_META_TOKEN=${PORTAL_UPLOAD_META_TOKEN}
TELEGRAM_BOT_TOKEN=${TELEGRAM_BOT_TOKEN}
TELEGRAM_CHAT_ID=${TELEGRAM_CHAT_ID}
TELEGRAM_TOPIC_ID=${TELEGRAM_TOPIC_ID}
TELEGRAM_NOTIFY=${TELEGRAM_NOTIFY}
EOF
chmod 600 "${TMP_ENV}"
cp "${ROOT}/scripts/bunny-upload.sh" "${TMP_DIR}/bunny-upload.sh"
cp "${ROOT}/scripts/finalize_recording.sh" "${TMP_DIR}/finalize_recording.sh"
[[ -f "${ROOT}/scripts/telegram-notify.sh" ]] && cp "${ROOT}/scripts/telegram-notify.sh" "${TMP_DIR}/telegram-notify.sh"

KEY_HINT="${BUNNY_API_KEY:0:8}…"
log "Bunny update"
log "  library: ${BUNNY_LIBRARY_ID}"
log "  api key: ${KEY_HINT}"
log "  cdn:     ${BUNNY_CDN_HOSTNAME:-"(boş)"}"
log "  portal:  ${PORTAL_UPLOAD_META_URL:-"(boş)"}"
log "  recorders: ${#JIBRI_NAMES[@]}"

if [[ "${DRY_RUN}" == "true" ]]; then
  log "Dry-run — heç nə yazılmadı"
  exit 0
fi

FAIL=0
for idx in "${!JIBRI_NAMES[@]}"; do
  name="${JIBRI_NAMES[$idx]}"
  ip="${JIBRI_PRIVATE_IPS[$idx]}"
  log "→ ${name} (${ip})"
  scp_files=("${TMP_ENV}" "${TMP_DIR}/bunny-upload.sh" "${TMP_DIR}/finalize_recording.sh")
  [[ -f "${TMP_DIR}/telegram-notify.sh" ]] && scp_files+=("${TMP_DIR}/telegram-notify.sh")
  if scp -q "${ssh_opts[@]}" "${JUMP_OPTS[@]}" \
      "${scp_files[@]}" \
      "ubuntu@${ip}:/tmp/" \
    && ssh "${ssh_opts[@]}" "${JUMP_OPTS[@]}" "ubuntu@${ip}" "sudo bash -s" <<'REMOTE'
set -euo pipefail
mkdir -p /opt/jitsi-jibri
mv /tmp/bunny.env.new /opt/jitsi-jibri/bunny.env
chmod 600 /opt/jitsi-jibri/bunny.env
chown jibri:jibri /opt/jitsi-jibri/bunny.env
install -m 755 -o jibri -g jibri /tmp/bunny-upload.sh /opt/jitsi-jibri/bunny-upload.sh
install -m 755 -o jibri -g jibri /tmp/finalize_recording.sh /opt/jitsi-jibri/finalize_recording.sh
if [[ -f /tmp/telegram-notify.sh ]]; then
  install -m 755 -o jibri -g jibri /tmp/telegram-notify.sh /opt/jitsi-jibri/telegram-notify.sh
fi
rm -f /tmp/bunny-upload.sh /tmp/finalize_recording.sh /tmp/telegram-notify.sh
grep -E '^BUNNY_LIBRARY_ID=|^BUNNY_CDN_HOSTNAME=|^PORTAL_UPLOAD_META_URL=' /opt/jitsi-jibri/bunny.env
test -s /opt/jitsi-jibri/bunny.env
test -x /opt/jitsi-jibri/bunny-upload.sh
echo "bunny.env + upload scripts OK"
REMOTE
  then
    log "${name} yeniləndi"
  else
    warn "${name} uğursuz"
    FAIL=1
  fi
done

if [[ -f "${OUTPUTS_JSON}" ]] && command -v jq >/dev/null 2>&1; then
  tmp="$(mktemp)"
  jq --arg id "${BUNNY_LIBRARY_ID}" --arg cdn "${BUNNY_CDN_HOSTNAME}" \
    '.bunny.library_id = $id | .bunny.cdn_hostname = $cdn' \
    "${OUTPUTS_JSON}" >"${tmp}" && mv "${tmp}" "${OUTPUTS_JSON}"
  log "outputs.json bunny.library_id yeniləndi"
fi

if [[ "${FAIL}" -ne 0 ]]; then
  die "Bəzi recorder-lər yenilənmədi — yuxarıya baxın"
fi

cat <<EOF

${GREEN}========================================${NC}
${GREEN}  Bunny yeniləndi${NC}
${GREEN}========================================${NC}

  Library: ${BUNNY_LIBRARY_ID}
  Recorders: ${#JIBRI_NAMES[@]}

  Növbəti recording: Bunny upload + portal published lesson
  (DD.MM.YYYY-part-N). Jibri restart lazım deyil.

EOF

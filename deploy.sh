#!/usr/bin/env bash
# ============================================================
# jitsi-cluster — bir əmrlə Jitsi + multi-Jibri recorders + Bunny
#
# İstifadə:
#   cp .env.example .env   # doldurun
#   ./deploy.sh
# ============================================================

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "${ROOT}"

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; NC='\033[0m'
log()  { echo -e "${GREEN}[+]${NC} $*"; }
warn() { echo -e "${YELLOW}[!]${NC} $*"; }
err()  { echo -e "${RED}[x]${NC} $*" >&2; }
tg_notify() {
  bash "${ROOT}/scripts/telegram-notify.sh" "$*" 2>/dev/null || true
}
die() {
  err "$*"
  tg_notify "Jitsi deploy FAILED (${GCP_PROJECT_ID:-?} / ${DOMAIN:-?}): $*"
  exit 1
}

# Skript icazələri (chmod əl ilə lazım deyil)
chmod +x "${ROOT}/deploy.sh" "${ROOT}/destroy.sh" 2>/dev/null || true
chmod +x "${ROOT}"/scripts/*.sh 2>/dev/null || true

# ---------- Load .env ----------
if [[ ! -f "${ROOT}/.env" ]]; then
  die ".env tapılmadı. Əvvəl: cp .env.example .env && nano .env"
fi
set -a
# shellcheck disable=SC1091
source "${ROOT}/.env"
set +a

: "${GCP_PROJECT_ID:?GCP_PROJECT_ID .env-də lazımdır}"
: "${DOMAIN:?DOMAIN .env-də lazımdır}"
: "${ADMIN_EMAIL:?ADMIN_EMAIL .env-də lazımdır}"

GCP_REGION="${GCP_REGION:-europe-west1}"
GCP_ZONE="${GCP_ZONE:-europe-west1-b}"
GCP_NETWORK="${GCP_NETWORK:-default}"
CONTROL_MACHINE_TYPE="${CONTROL_MACHINE_TYPE:-e2-standard-4}"
JVB_MACHINE_TYPE="${JVB_MACHINE_TYPE:-e2-standard-8}"
JIBRI_MACHINE_TYPE="${JIBRI_MACHINE_TYPE:-e2-standard-8}"
CONTROL_DISK_GB="${CONTROL_DISK_GB:-50}"
JVB_DISK_GB="${JVB_DISK_GB:-50}"
JIBRI_DISK_GB="${JIBRI_DISK_GB:-80}"
ENABLE_SCHEDULE="${ENABLE_SCHEDULE:-true}"
SCHEDULE_START_UTC="${SCHEDULE_START_UTC:-03:30}"
SCHEDULE_STOP_UTC="${SCHEDULE_STOP_UTC:-06:05}"
SCHEDULE_TIMEZONE="${SCHEDULE_TIMEZONE:-UTC}"
BUNNY_LIBRARY_ID="${BUNNY_LIBRARY_ID:-}"
BUNNY_API_KEY="${BUNNY_API_KEY:-}"
BUNNY_CDN_HOSTNAME="${BUNNY_CDN_HOSTNAME:-}"
# Optional: Jibri → ingress portal (room UUID → teacher Bunny collection)
PORTAL_UPLOAD_META_URL="${PORTAL_UPLOAD_META_URL:-}"
PORTAL_UPLOAD_META_TOKEN="${PORTAL_UPLOAD_META_TOKEN:-}"
TELEGRAM_BOT_TOKEN="${TELEGRAM_BOT_TOKEN:-}"
TELEGRAM_CHAT_ID="${TELEGRAM_CHAT_ID:-}"
TELEGRAM_TOPIC_ID="${TELEGRAM_TOPIC_ID:-}"
TELEGRAM_NOTIFY="${TELEGRAM_NOTIFY:-true}"
export TELEGRAM_BOT_TOKEN TELEGRAM_CHAT_ID TELEGRAM_TOPIC_ID TELEGRAM_NOTIFY

# Recording upload üçün Bunny məcburidir (boş olsa finalize fail olur)
if [[ -z "${BUNNY_LIBRARY_ID}" || -z "${BUNNY_API_KEY}" ]]; then
  die "BUNNY_LIBRARY_ID və BUNNY_API_KEY .env-də lazımdır (Stream → Video library ID + API Key, read-only DEYİL)"
fi

# Adaptive recording capacity:
#   CONCURRENT_RECORDINGS = eyni anda max recording
#   RECORDER_COUNT        = VM sayı (az)
#   JIBRI_PER_VM          = hər VM-də Jibri prosesi
# Default: 2 VM × 5 proses = 10 paralel recording (1 VM ≠ 1 record)
CONCURRENT_RECORDINGS="${CONCURRENT_RECORDINGS:-10}"
if [[ -n "${JIBRI_COUNT:-}" && -z "${RECORDER_COUNT:-}" && -z "${JIBRI_PER_VM:-}" ]]; then
  warn "JIBRI_COUNT köhnədir — CONCURRENT_RECORDINGS=${JIBRI_COUNT} kimi istifadə olunur"
  CONCURRENT_RECORDINGS="${JIBRI_COUNT}"
fi
if [[ -z "${RECORDER_COUNT:-}" ]]; then
  # ~5 slot/VM — az VM, çox paralel recording
  RECORDER_COUNT=$(( (CONCURRENT_RECORDINGS + 4) / 5 ))
  (( RECORDER_COUNT < 1 )) && RECORDER_COUNT=1
fi
if [[ -z "${JIBRI_PER_VM:-}" ]]; then
  JIBRI_PER_VM=$(( (CONCURRENT_RECORDINGS + RECORDER_COUNT - 1) / RECORDER_COUNT ))
fi
ACTUAL_CONCURRENT=$(( RECORDER_COUNT * JIBRI_PER_VM ))

if [[ "${DEPLOY_PROFILE:-}" == "full" ]]; then
  CONCURRENT_RECORDINGS=10
  RECORDER_COUNT=2
  JIBRI_PER_VM=5
  JVB_MACHINE_TYPE=e2-standard-16
  JIBRI_MACHINE_TYPE=e2-standard-16
  ACTUAL_CONCURRENT=$(( RECORDER_COUNT * JIBRI_PER_VM ))
  warn "DEPLOY_PROFILE=full: 2×recorder(16) + jvb(16) — quota artımı lazım ola bilər"
fi

hhmm_to_cron() {
  # HH:MM → "MM HH * * DOW"  (DOW default: * = hər gün)
  local t="$1"
  local dow="${2:-*}"
  local hh="${t%%:*}"
  local mm="${t##*:}"
  # Leading zero OK for Cloud Scheduler (09 → 9 also fine; keep as-is)
  echo "${mm} ${hh} * * ${dow}"
}

SCHEDULE_WEEKDAYS="${SCHEDULE_WEEKDAYS:-1-5}"
SCHEDULE_START_CRON="$(hhmm_to_cron "${SCHEDULE_START_UTC}" "${SCHEDULE_WEEKDAYS}")"
SCHEDULE_STOP_CRON="$(hhmm_to_cron "${SCHEDULE_STOP_UTC}" "${SCHEDULE_WEEKDAYS}")"
# Şənbə pəncərəsi (boş buraxılsa job yaradılmır)
SCHEDULE_SAT_START_UTC="${SCHEDULE_SAT_START_UTC:-}"
SCHEDULE_SAT_STOP_UTC="${SCHEDULE_SAT_STOP_UTC:-}"
SCHEDULE_SAT_START_CRON=""
SCHEDULE_SAT_STOP_CRON=""
if [[ -n "${SCHEDULE_SAT_START_UTC}" && -n "${SCHEDULE_SAT_STOP_UTC}" ]]; then
  SCHEDULE_SAT_START_CRON="$(hhmm_to_cron "${SCHEDULE_SAT_START_UTC}" "6")"
  SCHEDULE_SAT_STOP_CRON="$(hhmm_to_cron "${SCHEDULE_SAT_STOP_UTC}" "6")"
fi

# ---------- Prerequisites (avtomatik quraşdırma) ----------
# shellcheck source=scripts/install-prereqs.sh
source "${ROOT}/scripts/install-prereqs.sh"
ensure_deploy_prerequisites

log "GCP project: ${GCP_PROJECT_ID}"
gcloud config set project "${GCP_PROJECT_ID}" >/dev/null

# vCPU sayını machine type-dan çıxar (e2-standard-4 → 4)
machine_vcpu() {
  local mt="$1"
  if [[ "${mt}" =~ -([0-9]+)$ ]]; then
    echo "${BASH_REMATCH[1]}"
  else
    echo 2
  fi
}

TOTAL_VCPU=$(( $(machine_vcpu "${CONTROL_MACHINE_TYPE}") + $(machine_vcpu "${JVB_MACHINE_TYPE}") + RECORDER_COUNT * $(machine_vcpu "${JIBRI_MACHINE_TYPE}") ))
PUBLIC_IPS=$(( 2 )) # yalnız meet-control + meet-jvb statik IP
DEFAULT_CPU_QUOTA="${DEFAULT_CPU_QUOTA:-32}"
DEFAULT_IP_QUOTA="${DEFAULT_IP_QUOTA:-8}"

log "Plan: ${RECORDER_COUNT} recorder VM × ${JIBRI_PER_VM} Jibri = ${ACTUAL_CONCURRENT} paralel recording"
log "      control + jvb + recorders = ${TOTAL_VCPU} vCPU, ${PUBLIC_IPS} regional IP"
if (( TOTAL_VCPU > DEFAULT_CPU_QUOTA )); then
  die "vCPU cəmi ${TOTAL_VCPU} — yeni GCP limiti adətən ${DEFAULT_CPU_QUOTA}. .env-də RECORDER_COUNT / JIBRI_MACHINE_TYPE azaldın, və ya quota artırın: https://console.cloud.google.com/iam-admin/quotas"
fi
if (( PUBLIC_IPS > DEFAULT_IP_QUOTA )); then
  die "Regional IP ${PUBLIC_IPS} > limit ${DEFAULT_IP_QUOTA}"
fi
if (( ACTUAL_CONCURRENT < CONCURRENT_RECORDINGS )); then
  warn "Hədəf ${CONCURRENT_RECORDINGS} recording, plan ${ACTUAL_CONCURRENT} — RECORDER_COUNT və ya JIBRI_PER_VM artırın"
fi

log "API-lər aktivləşdirilir..."
gcloud services enable \
  compute.googleapis.com \
  cloudscheduler.googleapis.com \
  cloudresourcemanager.googleapis.com \
  iam.googleapis.com \
  appengine.googleapis.com \
  --project="${GCP_PROJECT_ID}" >/dev/null

# Cloud Scheduler bəzi regionlarda App Engine app tələb edir
if [[ "${ENABLE_SCHEDULE}" == "true" ]]; then
  if ! gcloud app describe --project="${GCP_PROJECT_ID}" &>/dev/null; then
    log "App Engine app yaradılır (scheduler üçün)..."
    gcloud app create --region="${GCP_REGION}" --project="${GCP_PROJECT_ID}" 2>/dev/null \
      || warn "App Engine create uğursuz/artıq var — davam edilir"
  fi
fi

# ---------- SSH key ----------
SECRETS_DIR="${ROOT}/secrets"
mkdir -p "${SECRETS_DIR}"
chmod 700 "${SECRETS_DIR}"

if [[ -n "${SSH_PUBLIC_KEY_PATH:-}" && -f "${SSH_PUBLIC_KEY_PATH}" ]]; then
  SSH_PUB="$(cat "${SSH_PUBLIC_KEY_PATH}")"
  SSH_PRIV="${SSH_PUBLIC_KEY_PATH%.pub}"
  [[ -f "${SSH_PRIV}" ]] || die "Private key tapılmadı: ${SSH_PRIV}"
else
  SSH_PRIV="${SECRETS_DIR}/deploy_key"
  SSH_PUB_FILE="${SECRETS_DIR}/deploy_key.pub"
  if [[ ! -f "${SSH_PRIV}" ]]; then
    log "SSH açarı yaradılır..."
    ssh-keygen -t ed25519 -N "" -f "${SSH_PRIV}" -C "jitsi-cluster" >/dev/null
  fi
  SSH_PUB="$(cat "${SSH_PUB_FILE}")"
fi

# ---------- Terraform ----------
mkdir -p "${ROOT}/terraform/generated"
TF_DIR="${ROOT}/terraform"

cat > "${TF_DIR}/terraform.tfvars" <<TFVARS
project_id            = "${GCP_PROJECT_ID}"
region                = "${GCP_REGION}"
zone                  = "${GCP_ZONE}"
network               = "${GCP_NETWORK}"
domain                = "${DOMAIN}"
admin_email           = "${ADMIN_EMAIL}"
ssh_public_key        = "${SSH_PUB}"
recorder_count        = ${RECORDER_COUNT}
jibri_per_vm          = ${JIBRI_PER_VM}
control_machine_type  = "${CONTROL_MACHINE_TYPE}"
jvb_machine_type      = "${JVB_MACHINE_TYPE}"
jibri_machine_type    = "${JIBRI_MACHINE_TYPE}"
control_disk_gb       = ${CONTROL_DISK_GB}
jvb_disk_gb           = ${JVB_DISK_GB}
jibri_disk_gb         = ${JIBRI_DISK_GB}
enable_schedule       = ${ENABLE_SCHEDULE}
schedule_start_cron   = "${SCHEDULE_START_CRON}"
schedule_stop_cron    = "${SCHEDULE_STOP_CRON}"
schedule_timezone     = "${SCHEDULE_TIMEZONE}"
bunny_library_id      = "${BUNNY_LIBRARY_ID}"
bunny_api_key         = "${BUNNY_API_KEY}"
bunny_cdn_hostname    = "${BUNNY_CDN_HOSTNAME}"
TFVARS

# Cloud Shell stub bəzən exit 0 qaytarır — real binary yoxla
# (pipefail + head SIGPIPE verməsin deyə terraform_real istifadə olunur)
export PATH="${HOME}/bin:${PATH}"
if ! terraform_real; then
  die "Real Terraform yoxdur. Yenidən: git pull && ./deploy.sh (və ya: export PATH=\$HOME/bin:\$PATH)"
fi

# Köhnə state-də jibri-* qalıbsa (destroy natamam) — təmizlə, yoxsa apply qarışır
if [[ -f "${TF_DIR}/terraform.tfstate" ]] && grep -q '"jibri-[0-9]' "${TF_DIR}/terraform.tfstate" 2>/dev/null; then
  warn "Köhnə jibri-* Terraform state tapıldı — silinir (təmiz apply)"
  rm -f "${TF_DIR}/terraform.tfstate" "${TF_DIR}/terraform.tfstate.backup"
fi

log "Terraform init..."
if ! terraform -chdir="${TF_DIR}" init -upgrade -input=false; then
  die "Terraform init uğursuz"
fi

# Yarımçıq destroy / itmiş state: GCP-də qalan IP/SA/firewall/VM → state-ə import
# (yoxsa apply 409 alreadyExists verir)
import_existing_gcp() {
  export GCP_PROJECT_ID GCP_REGION GCP_ZONE RECORDER_COUNT ENABLE_SCHEDULE
  bash "${ROOT}/scripts/tf-import-existing.sh" || warn "Import skripti xəta verdi — apply yenə cəhd edəcək"
}

import_existing_gcp

# Cloud Shell bəzən müvəqqəti connection refused verir — retry
# Yarımçıq destroy: GCP-də qalan NAT/IP/VM → 409 → import + yenidən apply
tf_apply_with_retry() {
  local attempt=0 max=8 delay=20 rc
  local logf="${SECRETS_DIR}/terraform-apply.log"
  local import_rounds=0
  local max_import_rounds=3
  mkdir -p "${SECRETS_DIR}"
  while (( attempt < max )); do
    attempt=$((attempt + 1))
    log "Terraform apply cəhd ${attempt}/${max} (${RECORDER_COUNT} recorder + control + jvb)..."
    set +e
    terraform -chdir="${TF_DIR}" apply -auto-approve -input=false >"${logf}" 2>&1
    rc=$?
    set -e
    cat "${logf}"
    if [[ "${rc}" -eq 0 ]]; then
      return 0
    fi
    if grep -qiE 'connection refused|i/o timeout|TLS handshake|EOF|temporarily unavailable' "${logf}"; then
      warn "Şəbəkə xətası (quota DEYİL) — ${delay}s sonra yenidən..."
      sleep "${delay}"
      delay=$((delay + 15))
      continue
    fi
    if grep -qiE "Quota .* exceeded|QUOTA_EXCEEDED" "${logf}"; then
      die "GCP quota aşılıb — log: ${logf}"
    fi
    # 409 alreadyExists — state boş, GCP-də resurs var (NAT router daxil) → import + retry
    if grep -qiE 'alreadyExists|already exists' "${logf}"; then
      if (( import_rounds >= max_import_rounds )); then
        die "409 alreadyExists ${max_import_rounds} import cəhdindən sonra qalır — log: ${logf}"
      fi
      import_rounds=$((import_rounds + 1))
      warn "409 alreadyExists — import ${import_rounds}/${max_import_rounds}, sonra yenidən apply..."
      import_existing_gcp
      # Son cəhddə import olsa belə bir apply daha ver
      if (( attempt >= max )); then
        max=$((max + 1))
      fi
      continue
    fi
    die "Terraform apply uğursuz — tam log: ${logf}"
  done
  die "Terraform apply ${max} cəhddən sonra uğursuz (Cloud Shell şəbəkəsi). Bir neçə dəqiqə sonra yenidən: ./deploy.sh"
}

tf_apply_with_retry

# apply uğurlu olsa belə stub ola bilərdi — outputs məcburi
if ! terraform -chdir="${TF_DIR}" output -raw control_public_ip >/dev/null 2>&1; then
  die "Terraform output boşdur — apply işləməyib. 'terraform version' yoxlayın"
fi

CONTROL_PUBLIC_IP="$(terraform -chdir="${TF_DIR}" output -raw control_public_ip)"
JVB_PUBLIC_IP="$(terraform -chdir="${TF_DIR}" output -raw jvb_public_ip)"
CONTROL_PRIVATE_IP="$(terraform -chdir="${TF_DIR}" output -raw control_private_ip)"
JVB_PRIVATE_IP="$(terraform -chdir="${TF_DIR}" output -raw jvb_private_ip)"

OUTPUTS_JSON="${TF_DIR}/generated/outputs.json"
[[ -f "${OUTPUTS_JSON}" ]] || die "outputs.json yoxdur"

JVB_PASSWORD="$(jq -r '.secrets.jvb_password' "${OUTPUTS_JSON}")"
JICOFO_PASSWORD="$(jq -r '.secrets.jicofo_password' "${OUTPUTS_JSON}")"
JIBRI_RECORDER_PASS="$(jq -r '.secrets.jibri_recorder_pass' "${OUTPUTS_JSON}")"
JIBRI_XMPP_PASS="$(jq -r '.secrets.jibri_xmpp_pass' "${OUTPUTS_JSON}")"
TURN_SECRET="$(jq -r '.secrets.turn_secret' "${OUTPUTS_JSON}")"

mapfile -t JIBRI_NAMES < <(jq -r '.jibri_names[]' "${OUTPUTS_JSON}")

log "Control IP: ${CONTROL_PUBLIC_IP}"
log "JVB IP:     ${JVB_PUBLIC_IP}"
log "Recorders:  ${#JIBRI_NAMES[@]} VM × ${JIBRI_PER_VM} Jibri = ${ACTUAL_CONCURRENT} paralel recording"

# ---------- Wait for SSH ----------
# BatchMode=yes — heç vaxt host-key prompt gözləmə (Cloud Shell non-interactive)
ssh_opts=(
  -o BatchMode=yes
  -o StrictHostKeyChecking=no
  -o UserKnownHostsFile=/dev/null
  -o GlobalKnownHostsFile=/dev/null
  -o ConnectTimeout=10
  -i "${SSH_PRIV}"
)

wait_ssh() {
  local host="$1" name="$2"
  shift 2
  local extra_opts=("$@")
  log "SSH gözlənilir: ${name} (${host})..."
  for i in $(seq 1 60); do
    if ssh "${ssh_opts[@]}" "${extra_opts[@]}" "ubuntu@${host}" "echo ok" >/dev/null 2>&1; then
      log "SSH hazır: ${name}"
      return 0
    fi
    sleep 5
  done
  die "SSH timeout: ${name} (${host})"
}

mapfile -t JIBRI_PRIVATE_IPS < <(terraform -chdir="${TF_DIR}" output -json jibri_private_ips | jq -r '.[]')

wait_ssh "${CONTROL_PUBLIC_IP}" "meet-control"
wait_ssh "${JVB_PUBLIC_IP}" "meet-jvb"

# Recorder yalnız daxili IP — bastion ProxyCommand (host-key prompt olmasın)
JUMP_OPTS=(
  -o "ProxyCommand=ssh -o BatchMode=yes -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o GlobalKnownHostsFile=/dev/null -i ${SSH_PRIV} -W %h:%p ubuntu@${CONTROL_PUBLIC_IP}"
)
JIBRI_IP_LIST=()
for idx in "${!JIBRI_NAMES[@]}"; do
  ip="${JIBRI_PRIVATE_IPS[$idx]}"
  name="${JIBRI_NAMES[$idx]}"
  JIBRI_IP_LIST+=("${ip}")
  wait_ssh "${ip}" "${name}" "${JUMP_OPTS[@]}"
done

# ---------- Sync scripts ----------
remote_sync() {
  local host="$1"
  shift
  local extra_opts=("$@")
  ssh "${ssh_opts[@]}" "${extra_opts[@]}" "ubuntu@${host}" "sudo mkdir -p /tmp/jitsi-cluster && sudo chown ubuntu:ubuntu /tmp/jitsi-cluster"
  scp -q "${ssh_opts[@]}" "${extra_opts[@]}" -r \
    "${ROOT}/scripts" "${ROOT}/config" \
    "ubuntu@${host}:/tmp/jitsi-cluster/"
  ssh "${ssh_opts[@]}" "${extra_opts[@]}" "ubuntu@${host}" "chmod +x /tmp/jitsi-cluster/scripts/*.sh"
}

RECORDER_IPS_CSV="$(IFS=,; echo "${JIBRI_IP_LIST[*]}")"

log "Skriptlər control-a kopyalanır..."
remote_sync "${CONTROL_PUBLIC_IP}"

log "meet-control quraşdırılır..."
ssh "${ssh_opts[@]}" "ubuntu@${CONTROL_PUBLIC_IP}" "sudo bash -s" <<REMOTE
set -euo pipefail
export DOMAIN='${DOMAIN}'
export ADMIN_EMAIL='${ADMIN_EMAIL}'
export JVB_PASSWORD='${JVB_PASSWORD}'
export JICOFO_PASSWORD='${JICOFO_PASSWORD}'
export JIBRI_RECORDER_PASS='${JIBRI_RECORDER_PASS}'
export JIBRI_XMPP_PASS='${JIBRI_XMPP_PASS}'
export TURN_SECRET='${TURN_SECRET}'
export JVB_PUBLIC_IP='${JVB_PUBLIC_IP}'
export JVB_PRIVATE_IP='${JVB_PRIVATE_IP}'
export CONTROL_PUBLIC_IP='${CONTROL_PUBLIC_IP}'
export JIBRI_PER_VM='${JIBRI_PER_VM}'
export RECORDER_PRIVATE_IPS='${RECORDER_IPS_CSV}'
export TELEGRAM_BOT_TOKEN='${TELEGRAM_BOT_TOKEN}'
export TELEGRAM_CHAT_ID='${TELEGRAM_CHAT_ID}'
export TELEGRAM_TOPIC_ID='${TELEGRAM_TOPIC_ID}'
export TELEGRAM_NOTIFY='${TELEGRAM_NOTIFY}'
export PORTAL_UPLOAD_META_URL='${PORTAL_UPLOAD_META_URL}'
export PORTAL_UPLOAD_META_TOKEN='${PORTAL_UPLOAD_META_TOKEN}'
bash /tmp/jitsi-cluster/scripts/setup-control.sh
REMOTE

# Health-check üçün control → recorder SSH açarı
if [[ -n "${TELEGRAM_BOT_TOKEN}" && -n "${TELEGRAM_CHAT_ID}" && -f "${SSH_PRIV}" ]]; then
  scp -q "${ssh_opts[@]}" "${SSH_PRIV}" "ubuntu@${CONTROL_PUBLIC_IP}:/tmp/deploy_key"
  ssh "${ssh_opts[@]}" "ubuntu@${CONTROL_PUBLIC_IP}" \
    "sudo mv /tmp/deploy_key /opt/jitsi-cluster/deploy_key && sudo chmod 600 /opt/jitsi-cluster/deploy_key && sudo chown root:root /opt/jitsi-cluster/deploy_key"
fi

# Prosody: allow remote c2s (bind all interfaces)
ssh "${ssh_opts[@]}" "ubuntu@${CONTROL_PUBLIC_IP}" "sudo bash -s" <<'REMOTE'
set -euo pipefail
# Ensure c2s listens on all interfaces
if ! grep -q 'c2s_interfaces' /etc/prosody/prosody.cfg.lua 2>/dev/null; then
  sed -i '/^-- c2s_ports/a c2s_interfaces = { "*" }' /etc/prosody/prosody.cfg.lua 2>/dev/null || true
fi
# component interfaces
if grep -q 'component_ports' /etc/prosody/prosody.cfg.lua; then
  grep -q 'component_interfaces' /etc/prosody/prosody.cfg.lua || \
    sed -i '/component_ports/a component_interfaces = { "*" }' /etc/prosody/prosody.cfg.lua || true
fi
systemctl restart prosody
REMOTE

log "meet-jvb quraşdırılır..."
remote_sync "${JVB_PUBLIC_IP}"
ssh "${ssh_opts[@]}" "ubuntu@${JVB_PUBLIC_IP}" "sudo bash -s" <<REMOTE
set -euo pipefail
export DOMAIN='${DOMAIN}'
export CONTROL_PRIVATE_IP='${CONTROL_PRIVATE_IP}'
export JVB_PASSWORD='${JVB_PASSWORD}'
export JVB_PUBLIC_IP='${JVB_PUBLIC_IP}'
bash /tmp/jitsi-cluster/scripts/setup-jvb.sh
REMOTE

# ---------- Recorders (multi-Jibri per VM, parallel) ----------
log "Recorder VM-lər quraşdırılır (${#JIBRI_NAMES[@]} VM × ${JIBRI_PER_VM} Jibri)..."
PIDS=()
for idx in "${!JIBRI_NAMES[@]}"; do
  name="${JIBRI_NAMES[$idx]}"
  ip="${JIBRI_IP_LIST[$idx]}"
  (
    remote_sync "${ip}" "${JUMP_OPTS[@]}"
    ssh "${ssh_opts[@]}" "${JUMP_OPTS[@]}" "ubuntu@${ip}" "sudo bash -s" <<REMOTE
set -euo pipefail
export DOMAIN='${DOMAIN}'
export CONTROL_PRIVATE_IP='${CONTROL_PRIVATE_IP}'
export JIBRI_RECORDER_PASS='${JIBRI_RECORDER_PASS}'
export JIBRI_XMPP_PASS='${JIBRI_XMPP_PASS}'
export RECORDER_HOST_ID='${name}'
export JIBRI_PER_VM='${JIBRI_PER_VM}'
export BUNNY_LIBRARY_ID='${BUNNY_LIBRARY_ID}'
export BUNNY_API_KEY='${BUNNY_API_KEY}'
export BUNNY_CDN_HOSTNAME='${BUNNY_CDN_HOSTNAME}'
export PORTAL_UPLOAD_META_URL='${PORTAL_UPLOAD_META_URL}'
export PORTAL_UPLOAD_META_TOKEN='${PORTAL_UPLOAD_META_TOKEN}'
export TELEGRAM_BOT_TOKEN='${TELEGRAM_BOT_TOKEN}'
export TELEGRAM_CHAT_ID='${TELEGRAM_CHAT_ID}'
export TELEGRAM_TOPIC_ID='${TELEGRAM_TOPIC_ID}'
export TELEGRAM_NOTIFY='${TELEGRAM_NOTIFY}'
bash /tmp/jitsi-cluster/scripts/setup-jibri.sh
REMOTE
  ) > "${SECRETS_DIR}/setup-${name}.log" 2>&1 &
  PIDS+=($!)
done

FAIL=0
for pid in "${PIDS[@]}"; do
  wait "${pid}" || FAIL=1
done
[[ "${FAIL}" -eq 0 ]] || warn "Bəzi recorder setup-ları xəta verdi — secrets/setup-recorder-*.log baxın"

# ---------- DNS (optional) ----------
if [[ -n "${CLOUDFLARE_API_TOKEN:-}" && -n "${CLOUDFLARE_ZONE_ID:-}" ]]; then
  log "Cloudflare DNS yenilənir..."
  export CLOUDFLARE_API_TOKEN CLOUDFLARE_ZONE_ID
  export CLOUDFLARE_RECORD_NAME="${CLOUDFLARE_RECORD_NAME:-${DOMAIN}}"
  export CONTROL_PUBLIC_IP
  bash "${ROOT}/scripts/update-dns-cloudflare.sh" || warn "DNS update uğursuz"
else
  warn "Cloudflare boşdur — DNS-i əl ilə qoyun:"
  warn "  ${DOMAIN}  A  ${CONTROL_PUBLIC_IP}"
fi

# ---------- Scheduler for all VMs ----------
if [[ "${ENABLE_SCHEDULE}" == "true" ]]; then
  log "Cloud Scheduler (bütün VM-lər)..."
  SA_EMAIL="$(gcloud iam service-accounts list \
    --project="${GCP_PROJECT_ID}" \
    --filter="email:jitsi-scheduler@" \
    --format='value(email)' | head -1)"
  if [[ -n "${SA_EMAIL}" ]]; then
    export GCP_PROJECT_ID GCP_ZONE GCP_REGION
    export SCHEDULE_START_CRON SCHEDULE_STOP_CRON SCHEDULE_TIMEZONE
    export SCHEDULE_SAT_START_CRON SCHEDULE_SAT_STOP_CRON
    export SCHEDULER_SA_EMAIL="${SA_EMAIL}"
    bash "${ROOT}/scripts/install-scheduler-jobs.sh" || warn "Scheduler jobs qismən uğursuz"
    if [[ -n "${TELEGRAM_BOT_TOKEN}" && -n "${TELEGRAM_CHAT_ID}" ]]; then
      export DOMAIN TELEGRAM_BOT_TOKEN TELEGRAM_CHAT_ID TELEGRAM_TOPIC_ID
      export SCHEDULE_START_CRON SCHEDULE_STOP_CRON SCHEDULE_TIMEZONE
      export SCHEDULE_SAT_START_CRON SCHEDULE_SAT_STOP_CRON
      export SCHEDULE_START_UTC SCHEDULE_STOP_UTC SCHEDULE_WEEKDAYS
      export SCHEDULE_SAT_START_UTC SCHEDULE_SAT_STOP_UTC
      bash "${ROOT}/scripts/install-telegram-scheduler-jobs.sh" || warn "Telegram scheduler jobs qismən uğursuz"
    fi
  else
    warn "jitsi-scheduler SA tapılmadı — terraform schedule yoxlayın"
  fi
fi

tg_notify "Jitsi deploy OK
project=${GCP_PROJECT_ID}
url=https://${DOMAIN}
control=${CONTROL_PUBLIC_IP}
jvb=${JVB_PUBLIC_IP}
recorders=${#JIBRI_NAMES[@]}×${JIBRI_PER_VM}"

# ---------- Summary ----------
cat <<EOF

${GREEN}========================================${NC}
${GREEN}  Deploy tamamlandı${NC}
${GREEN}========================================${NC}

  URL:              https://${DOMAIN}
  meet-control IP:  ${CONTROL_PUBLIC_IP}
  meet-jvb IP:      ${JVB_PUBLIC_IP}
  Recorder VM:      ${#JIBRI_NAMES[@]} × ${JIBRI_PER_VM} Jibri = ${ACTUAL_CONCURRENT} paralel recording

  DNS (vacib):
    ${DOMAIN}  →  A  →  ${CONTROL_PUBLIC_IP}
    (JVB media üçün əlavə DNS lazım deyil — IP mapping avtomatikdir)

  DNS yoxla (Google/Cloudflare — router cache aldatmasın):
    dig +short ${DOMAIN} A @8.8.8.8
    # Gözlənilən: ${CONTROL_PUBLIC_IP}
    # Brauzer NXDOMAIN verirsə: router köhnə negative-cache saxlayır.
    # Tez test:  echo '${CONTROL_PUBLIC_IP} ${DOMAIN}' | sudo tee -a /etc/hosts
    # və ya DNS-i 8.8.8.8 / 1.1.1.1 et.

  Recording (Bunny Stream — Ingress portal ilə eyni):
    Meeting-də "..." → Start recording
    Bitəndə MP4 → portal upload-meta (müəllim collection) → create video + PUT → library ${BUNNY_LIBRARY_ID}
    Upload OK → serverdən silinir
    Log: /var/log/jitsi/bunny-uploads.jsonl (video_id = portal bunny_video_id)

  Jibri yoxla (Cloud Shell-dən, meet-control-da YOX):
    gcloud compute ssh recorder-1 --zone=${GCP_ZONE} --project=${GCP_PROJECT_ID} --tunnel-through-iap -- \\
      "systemctl is-active jibri@{1..5}; sudo test -s /opt/jitsi-jibri/bunny.env && echo bunny_ok"

  Schedule (${ENABLE_SCHEDULE}):
    Weekdays (${SCHEDULE_WEEKDAYS:-1-5}): ${SCHEDULE_START_UTC} → ${SCHEDULE_STOP_UTC}  (${SCHEDULE_TIMEZONE})
    Saturday: ${SCHEDULE_SAT_START_UTC:-off} → ${SCHEDULE_SAT_STOP_UTC:-off}  (${SCHEDULE_TIMEZONE})
    cron wd: ${SCHEDULE_START_CRON} / ${SCHEDULE_STOP_CRON}
    cron sat: ${SCHEDULE_SAT_START_CRON:-—} / ${SCHEDULE_SAT_STOP_CRON:-—}

  Manual start/stop:
    GCP_PROJECT_ID=${GCP_PROJECT_ID} GCP_ZONE=${GCP_ZONE} \\
      ./scripts/schedule-all.sh start

  Secrets:
    ${OUTPUTS_JSON}
    ${SSH_PRIV}

${YELLOW}DNS yayımlandıqdan sonra SSL üçün:${NC}
  gcloud compute ssh meet-control --zone=${GCP_ZONE} --project=${GCP_PROJECT_ID} -- \\
    "sudo /usr/share/jitsi-meet/scripts/install-letsencrypt-cert.sh ${ADMIN_EMAIL} ${DOMAIN}"

EOF

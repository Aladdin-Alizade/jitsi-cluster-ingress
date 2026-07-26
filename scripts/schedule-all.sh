#!/usr/bin/env bash
# Bütün Jitsi VM-lərini start/stop edir (Cloud Scheduler → Pub/Sub → bu skript əvəzinə
# deploy.sh gcloud scheduler jobs yaradır ki, hər VM üçün start/stop çağırılsın).
#
# Manual:
#   ./scripts/schedule-all.sh start
#   ./scripts/schedule-all.sh stop

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

ACTION="${1:?usage: schedule-all.sh start|stop}"
PROJECT_ID="${GCP_PROJECT_ID:?}"
ZONE="${GCP_ZONE:?}"

tg() {
  # shellcheck disable=SC1091
  if [[ -f "${ROOT}/.env" ]]; then
    set -a
    # shellcheck source=/dev/null
    source "${ROOT}/.env"
    set +a
  fi
  bash "${SCRIPT_DIR}/telegram-notify.sh" "$*" 2>/dev/null || true
}

INSTANCES=(meet-control meet-jvb)
# recorder-1 .. recorder-N (və köhnə jibri-* adları) — bash 3.2 uyğun
while IFS= read -r _name; do
  [[ -n "${_name}" ]] && INSTANCES+=("${_name}")
done < <(gcloud compute instances list \
  --project="${PROJECT_ID}" \
  --filter="name~^recorder- OR name~^jibri-" \
  --format="value(name)")

FAILS=()
for name in "${INSTANCES[@]}"; do
  [[ -z "${name}" ]] && continue
  echo "[+] ${ACTION}: ${name}"
  if ! gcloud compute instances "${ACTION}" "${name}" \
    --project="${PROJECT_ID}" \
    --zone="${ZONE}" \
    --quiet; then
    echo "[!] ${name} ${ACTION} failed (maybe already ${ACTION}ed)"
    FAILS+=("${name}")
  fi
done

echo "Done: ${ACTION} ${#INSTANCES[@]} instances"
if (( ${#FAILS[@]} > 0 )); then
  tg "Jitsi schedule-all ${ACTION}: partial fails (${PROJECT_ID}): ${FAILS[*]}"
else
  tg "Jitsi schedule-all ${ACTION} OK (${PROJECT_ID}): ${#INSTANCES[@]} VMs"
fi

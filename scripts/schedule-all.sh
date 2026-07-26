#!/usr/bin/env bash
# Bütün Jitsi VM-lərini start/stop edir.
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

if [[ -f "${ROOT}/.env" ]]; then
  set -a
  # shellcheck disable=SC1091
  source "${ROOT}/.env"
  set +a
fi

TZ_NAME="${SCHEDULE_TIMEZONE:-UTC}"
WD_START="${SCHEDULE_START_UTC:-?}"
WD_STOP="${SCHEDULE_STOP_UTC:-?}"
WD_DAYS="${SCHEDULE_WEEKDAYS:-1-5}"
SAT_START="${SCHEDULE_SAT_START_UTC:-}"
SAT_STOP="${SCHEDULE_SAT_STOP_UTC:-}"
DOMAIN="${DOMAIN:-jitsi}"

case "${WD_DAYS}" in
  1-5|1,2,3,4,5) WD_LABEL="Həftəiçi (Mon–Fri)" ;;
  *) WD_LABEL="Günlər ${WD_DAYS}" ;;
esac

WINDOW_HINT="${WD_LABEL} ${WD_START}→${WD_STOP} (${TZ_NAME})"
if [[ -n "${SAT_START}" && -n "${SAT_STOP}" ]]; then
  WINDOW_HINT+=$'\n'"saturday: ${SAT_START}→${SAT_STOP} (${TZ_NAME})"
fi

tg() {
  bash "${SCRIPT_DIR}/telegram-notify.sh" "$*" 2>/dev/null || true
}

INSTANCES=(meet-control meet-jvb)
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

if [[ "${ACTION}" == "start" ]]; then
  EVENT="MANUAL START — VM-lər açıqdır
schedule window (reference): ${WINDOW_HINT}
note: bu əl ilə start-dır; avtomatik STOP hələ cədvələ görə ${WD_STOP} (${TZ_NAME}) ola bilər"
else
  EVENT="MANUAL STOP — VM-lər sönülü
schedule window (reference): ${WINDOW_HINT}
note: bu əl ilə stop-dur; növbəti avtomatik START ${WD_START} (${TZ_NAME})"
fi

if (( ${#FAILS[@]} > 0 )); then
  tg "Jitsi schedule-all ${ACTION} PARTIAL FAIL
domain: ${DOMAIN}
project: ${PROJECT_ID}
vms: ${#INSTANCES[@]} (fails: ${FAILS[*]})
${EVENT}"
else
  tg "Jitsi schedule-all ${ACTION} OK
domain: ${DOMAIN}
project: ${PROJECT_ID}
vms: ${#INSTANCES[@]}
${EVENT}"
fi

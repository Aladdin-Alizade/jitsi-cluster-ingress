#!/usr/bin/env bash
# Cloud Scheduler → birbaşa Telegram (VM sönəndə də start/stop xəbəri çatsın)
# Eyni cron pəncərəsi ilə jitsi-tg-notify-start / stop (+ sat)
# Mesajda pəncərə aralığı, timezone, növbəti stop/start qeyd olunur.

set -euo pipefail

PROJECT_ID="${GCP_PROJECT_ID:?}"
REGION="${GCP_REGION:?}"
START_CRON="${SCHEDULE_START_CRON:?}"
STOP_CRON="${SCHEDULE_STOP_CRON:?}"
SAT_START_CRON="${SCHEDULE_SAT_START_CRON:-}"
SAT_STOP_CRON="${SCHEDULE_SAT_STOP_CRON:-}"
TZ_NAME="${SCHEDULE_TIMEZONE:-UTC}"
TOKEN="${TELEGRAM_BOT_TOKEN:?TELEGRAM_BOT_TOKEN lazımdır}"
CHAT="${TELEGRAM_CHAT_ID:?TELEGRAM_CHAT_ID lazımdır}"
TOPIC="${TELEGRAM_TOPIC_ID:-}"
DOMAIN="${DOMAIN:-jitsi}"

# İnsan oxunaqlı aralıq (.env HH:MM)
WD_START="${SCHEDULE_START_UTC:-?}"
WD_STOP="${SCHEDULE_STOP_UTC:-?}"
WD_DAYS="${SCHEDULE_WEEKDAYS:-1-5}"
SAT_START="${SCHEDULE_SAT_START_UTC:-}"
SAT_STOP="${SCHEDULE_SAT_STOP_UTC:-}"

case "${WD_DAYS}" in
  1-5|1,2,3,4,5) WD_LABEL="Həftəiçi (Mon–Fri)" ;;
  *) WD_LABEL="Günlər ${WD_DAYS}" ;;
esac

URI="https://api.telegram.org/bot${TOKEN}/sendMessage"

ensure_tg_job() {
  local name="$1" cron="$2" text="$3"
  local body_file
  body_file="$(mktemp)"
  if [[ -n "${TOPIC}" ]]; then
    jq -nc --arg c "${CHAT}" --arg t "${text}" --argjson th "${TOPIC}" \
      '{chat_id:$c,text:$t,message_thread_id:$th,disable_web_page_preview:true}' \
      >"${body_file}"
  else
    jq -nc --arg c "${CHAT}" --arg t "${text}" \
      '{chat_id:$c,text:$t,disable_web_page_preview:true}' \
      >"${body_file}"
  fi

  if gcloud scheduler jobs describe "${name}" --location="${REGION}" --project="${PROJECT_ID}" &>/dev/null; then
    if ! gcloud scheduler jobs update http "${name}" \
      --location="${REGION}" \
      --project="${PROJECT_ID}" \
      --schedule="${cron}" \
      --time-zone="${TZ_NAME}" \
      --uri="${URI}" \
      --http-method=POST \
      --headers="Content-Type=application/json" \
      --message-body-from-file="${body_file}" \
      --attempt-deadline=30s \
      --quiet; then
      echo "[!] update fail ${name} — recreate"
      gcloud scheduler jobs delete "${name}" \
        --location="${REGION}" --project="${PROJECT_ID}" --quiet || true
      gcloud scheduler jobs create http "${name}" \
        --location="${REGION}" \
        --project="${PROJECT_ID}" \
        --schedule="${cron}" \
        --time-zone="${TZ_NAME}" \
        --uri="${URI}" \
        --http-method=POST \
        --headers="Content-Type=application/json" \
        --message-body-from-file="${body_file}" \
        --attempt-deadline=30s \
        --quiet
    fi
  else
    gcloud scheduler jobs create http "${name}" \
      --location="${REGION}" \
      --project="${PROJECT_ID}" \
      --schedule="${cron}" \
      --time-zone="${TZ_NAME}" \
      --uri="${URI}" \
      --http-method=POST \
      --headers="Content-Type=application/json" \
      --message-body-from-file="${body_file}" \
      --attempt-deadline=30s \
      --quiet
  fi
  rm -f "${body_file}"
  gcloud scheduler jobs resume "${name}" \
    --location="${REGION}" \
    --project="${PROJECT_ID}" \
    --quiet 2>/dev/null || true
  echo "[+] telegram job ${name} (${cron} ${TZ_NAME})"
}

MSG_WD_START="Jitsi SCHEDULER START
domain: ${DOMAIN}
project: ${PROJECT_ID}
window: ${WD_LABEL}
active: ${WD_START} → ${WD_STOP} (${TZ_NAME})
event: pəncərə AÇILDI — VM-lər start olunur
next: avtomatik STOP ${WD_STOP} (${TZ_NAME})
note: bu 24/7 deyil; yalnız cədvəl aralığında aktivdir"

MSG_WD_STOP="Jitsi SCHEDULER STOP
domain: ${DOMAIN}
project: ${PROJECT_ID}
window: ${WD_LABEL}
was active: ${WD_START} → ${WD_STOP} (${TZ_NAME})
event: pəncərə BİTDİ — VM-lər stop olunur
next: növbəti START ${WD_START} (${TZ_NAME}, ${WD_LABEL})
note: cluster indi sönülü qalacaq (cədvəl aralığı bitdi; bütün gün aktiv deyildi)"

echo "[+] Creating Telegram scheduler jobs (region=${REGION}, tz=${TZ_NAME})"
echo "    weekday window: ${WD_START} → ${WD_STOP} (${WD_LABEL}, ${TZ_NAME})"

ensure_tg_job "jitsi-tg-notify-start" "${START_CRON}" "${MSG_WD_START}"
ensure_tg_job "jitsi-tg-notify-stop" "${STOP_CRON}" "${MSG_WD_STOP}"

if [[ -n "${SAT_START_CRON}" && -n "${SAT_STOP_CRON}" && -n "${SAT_START}" && -n "${SAT_STOP}" ]]; then
  MSG_SAT_START="Jitsi SCHEDULER START (Saturday)
domain: ${DOMAIN}
project: ${PROJECT_ID}
window: Şənbə
active: ${SAT_START} → ${SAT_STOP} (${TZ_NAME})
event: şənbə pəncərəsi AÇILDI — VM-lər start olunur
next: avtomatik STOP ${SAT_STOP} (${TZ_NAME})
note: bu 24/7 deyil; yalnız şənbə cədvəl aralığında aktivdir"

  MSG_SAT_STOP="Jitsi SCHEDULER STOP (Saturday)
domain: ${DOMAIN}
project: ${PROJECT_ID}
window: Şənbə
was active: ${SAT_START} → ${SAT_STOP} (${TZ_NAME})
event: şənbə pəncərəsi BİTDİ — VM-lər stop olunur
next: növbəti weekday START ${WD_START} (${TZ_NAME}, ${WD_LABEL})
note: cluster indi sönülü qalacaq (şənbə aralığı bitdi)"

  echo "    saturday window: ${SAT_START} → ${SAT_STOP} (${TZ_NAME})"
  ensure_tg_job "jitsi-tg-notify-sat-start" "${SAT_START_CRON}" "${MSG_SAT_START}"
  ensure_tg_job "jitsi-tg-notify-sat-stop" "${SAT_STOP_CRON}" "${MSG_SAT_STOP}"
fi

echo "Telegram scheduler notify jobs ready"
gcloud scheduler jobs list --location="${REGION}" --project="${PROJECT_ID}" \
  --filter='name:jitsi-tg-notify' --format='table(name,schedule,timeZone,state)' || true

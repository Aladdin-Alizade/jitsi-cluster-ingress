#!/usr/bin/env bash
# Cloud Scheduler → birbaşa Telegram (VM sönəndə də start/stop xəbəri çatsın)
# Eyni cron pəncərəsi ilə jitsi-tg-notify-start / stop (+ sat)

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
    gcloud scheduler jobs update http "${name}" \
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

echo "[+] Creating Telegram scheduler jobs (region=${REGION}, tz=${TZ_NAME})"
echo "    start cron: ${START_CRON}"
echo "    stop  cron: ${STOP_CRON}"

ensure_tg_job "jitsi-tg-notify-start" "${START_CRON}" \
  "Jitsi scheduler START window (${DOMAIN} / ${PROJECT_ID}) — VMs starting"
ensure_tg_job "jitsi-tg-notify-stop" "${STOP_CRON}" \
  "Jitsi scheduler STOP window (${DOMAIN} / ${PROJECT_ID}) — VMs stopping"

if [[ -n "${SAT_START_CRON}" && -n "${SAT_STOP_CRON}" ]]; then
  ensure_tg_job "jitsi-tg-notify-sat-start" "${SAT_START_CRON}" \
    "Jitsi Saturday START (${DOMAIN} / ${PROJECT_ID})"
  ensure_tg_job "jitsi-tg-notify-sat-stop" "${SAT_STOP_CRON}" \
    "Jitsi Saturday STOP (${DOMAIN} / ${PROJECT_ID})"
fi

echo "Telegram scheduler notify jobs ready"
gcloud scheduler jobs list --location="${REGION}" --project="${PROJECT_ID}" \
  --filter='name:jitsi-tg-notify' --format='table(name,schedule,timeZone,state)' || true

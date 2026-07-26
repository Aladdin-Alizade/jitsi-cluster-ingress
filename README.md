# jitsi-cluster

GCP-də Jitsi Meet cluster + multi-Jibri recording + Bunny Stream upload.

Canlı server (`meet.ingress.academy`) konfiqlərinə əsaslanır: 15 nəfərlik qruplar, 720p, simulcast, TURN, recording.

**Default (10 paralel recording, 5 Jibri / VM):**

```
meet-control   e2-standard-4     Nginx + Prosody + Jicofo + Coturn
meet-jvb       e2-standard-8     Video bridge
recorder-1..2  e2-standard-8     hər VM-də 5 Jibri → Bunny
```

`CONCURRENT_RECORDINGS=10` → deploy **2 recorder VM × 5 Jibri proses** seçir.  
1 VM ≠ 1 record — eyni hostda `jibri@1`…`jibri@5` işləyir; Jicofo brewery boş slotu seçir. Gələcəkdə `CONCURRENT_RECORDINGS` artır/azaltmaq kifayətdir.

---

## Tələblər

- `gcloud` + `gcloud auth login`
- GCP project + **billing aktiv**
- `.env` doldurulmuş

`./deploy.sh` avtomatik: Terraform, jq, API enable, App Engine (scheduler), SSH, VM-lər, multi-Jibri, DNS, scheduler.

---

## Start

```bash
git clone https://github.com/Aladdin-Biyabangard/jitsi-cluster-ingress.git 
cd jitsi-cluster-ingress
cp .env.example .env
nano .env          # doldurun
./deploy.sh
```

Deploy ~20–40 dəqiqə. Sonunda:

```
URL: https://meet.yourdomain.com
meet-control IP: x.x.x.x
```

DNS A record: `DOMAIN → meet-control IP` (Cloudflare token versəniz avtomatik).

---

## SSL / Let's Encrypt (`Not Secure`)

Deploy zamanı DNS hələ `meet-control` IP-yə getmirsə, Let's Encrypt uğursuz olur və **self-signed** sertifikat qalır — brauzer **Not Secure** göstərir.

DNS A record-u qoyduqdan sonra (yayımlandıqdan sonra) sertifikatı yenilə:

```bash
cd ~/jitsi/jitsi-cluster-ingress
source .env

# DNS doğrula — çıxan IP = control public IP olmalıdır
dig +short ${DOMAIN} A @8.8.8.8
terraform -chdir=terraform output -raw control_public_ip

# Let's Encrypt yenidən quraşdır
gcloud compute ssh meet-control --zone=${GCP_ZONE} --project=${GCP_PROJECT_ID} -- \
  "sudo bash -c 'echo y | /usr/share/jitsi-meet/scripts/install-letsencrypt-cert.sh ${ADMIN_EMAIL} ${DOMAIN}'"
```

Uğurlu olsa `https://${DOMAIN}` yenilə — padlock görünməlidir.

**Cloudflare:** LE zamanı record **DNS only** (boz bulud) olsun; bitəndən sonra istəsən Proxied (narıncı) aç.

---

## `.env`

| Dəyişən | Məcburi | İzah |
|---------|---------|------|
| `GCP_PROJECT_ID` | ✅ | GCP project |
| `DOMAIN` | ✅ | məs. `meet.example.com` |
| `ADMIN_EMAIL` | ✅ | Let's Encrypt |
| `BUNNY_LIBRARY_ID` | ✅ recording | Stream → Video library ID |
| `BUNNY_API_KEY` | ✅ recording | Stream → API Key (Read-only DEYİL) |
| `BUNNY_CDN_HOSTNAME` | optional | CDN hostname |
| `CONCURRENT_RECORDINGS` | | Default `10` (2×5 Jibri) |
| `CLOUDFLARE_*` | | DNS avtomatik |
| `SCHEDULE_*` | | Default: 03:30–06:05 UTC (= 07:30–10:05 Bakı) |
| `TELEGRAM_BOT_TOKEN` | | Telegram bot token (BotFather) |
| `TELEGRAM_CHAT_ID` | | Qrup/channel id (`-100...`) |
| `TELEGRAM_TOPIC_ID` | | Forum topic `message_thread_id` |
| `TELEGRAM_NOTIFY` | | `true`/`false` (default: token varsa on) |

---

## Domain dəyişmə (`migrate-domain.sh`)

Meet domain-ini dəyişəndə **yalnız nginx və ya yalnız LE** kifayət etmir — Prosody, `config.js`, Jicofo, JVB, Jibri və sertifikat eyni domain olmalıdır. Əks halda `ERR_CERT_COMMON_NAME_INVALID` / `JitsiMeetExternalAPI is not defined` / `conferenceRequestFailed` çıxır.

```bash
# 1) DNS: NEW → meet-control public IP (A record)
# 2) .env-də DOMAIN=meet.new.example (istəyə görə)
./migrate-domain.sh --from meet.old.example --to meet.new.example
```

Skript nə edir:

1. **meet-control** — Prosody/Nginx/`config.js`/Jicofo/Coturn + Prosody user-lər + Let's Encrypt  
2. **meet-jvb** — `jvb.conf` + `/etc/hosts`  
3. **recorder-*** — Jibri conf + hosts  
4. Lokal `.env` `DOMAIN=` yenilənir; Cloudflare token varsa DNS də

```bash
./migrate-domain.sh --from meet.edulora.online --to meet.ingress.academy
./migrate-domain.sh --from meet.old.com --to meet.new.com --skip-le   # LE-siz
./migrate-domain.sh --from meet.old.com --dry-run                     # yalnız plan
```

**Portal:** production-da `JITSI_DOMAIN` də eyni NEW domain olmalıdır, sonra portal restart.

---

## Telegram bildirişlər

Bot ilə deploy, scheduler, health və recording hadisələri Telegram-a düşür.

**Quraşdırma**

1. [@BotFather](https://t.me/BotFather) → `/newbot` → `TELEGRAM_BOT_TOKEN`
2. Bota (və ya qrupa botu əlavə edib) `/start`
3. `chat_id` al:

```bash
curl -s "https://api.telegram.org/bot<TOKEN>/getUpdates" | jq '.result[-1].message.chat.id'
```

4. `.env`:

```bash
TELEGRAM_BOT_TOKEN=123456:ABC...
TELEGRAM_CHAT_ID=-100xxxxxxxxxx
TELEGRAM_TOPIC_ID=2
TELEGRAM_NOTIFY=true
```

5. Mövcud cluster (redeploy olmadan):

```bash
./scripts/install-telegram-alerts.sh
```

Yeni deploy-da token `.env`-dədirsə avtomatik quraşır.

**Hadisələr**

| Mənbə | Nə vaxt |
|-------|---------|
| `deploy.sh` | uğurlu / uğursuz |
| Cloud Scheduler TG jobs | start/stop (və şənbə) pəncərəsi |
| `schedule-all.sh` | manual start/stop |
| meet-control cron `*/5` | xidmət/HTTPS/SSL/disk/CPU/JVB/Jibri; recording busy/idle |
| `finalize_recording.sh` / `bunny-upload.sh` | finalize + Bunny OK/FAIL |

Health spam-i azdır: yalnız status dəyişəndə; CRITICAL ~60 dəq-də bir təkrarlana bilər. Log: `/var/log/jitsi/health-notify.log`.

**Test**

```bash
source .env
./scripts/telegram-notify.sh "Jitsi test $(date -Iseconds)"
```

---

## Bunny key yeniləmə (`update-bunny.sh`)

Cluster artıq işləyir; yalnız Bunny library/API key (və ya portal upload-meta) dəyişib:

```bash
# 1) .env-də BUNNY_LIBRARY_ID / BUNNY_API_KEY (və istəyə görə PORTAL_UPLOAD_META_*)
nano .env
# 2) bütün recorder-lərdə bunny.env yenilə
./update-bunny.sh
```

Jibri restart və `./deploy.sh` lazım deyil. Növbəti recording upload yeni key ilə gedir;
`bunny-upload.sh` də yenilənir (portal published lesson callback daxil).

---

## Recording axını

```
Meeting → Start recording
    ↓
Jibri MP4 yazır (/srv/recordings/slot-N)
    ↓
Stop / meeting bitir
    ↓
finalize_recording.sh  (fayl settle gözləyir)
    ↓
bunny-upload.sh
    0) GET  portal /api/jitsi/room/{uuid}/upload-meta/  → teacher collectionId
    1) POST /library/{id}/videos  (+ collectionId)      → video GUID
    2) PUT  /library/{id}/videos/{guid}                 → MP4 binary
    3) POST portal /api/jitsi/room/{uuid}/recording-complete/
         → published GroupLesson ``DD.MM.YYYY-part-N`` (task-siz)
    ↓
HTTP 2xx  →  lokal MP4 + qovluq silinir
```

Ingress portal (`bunny_stream.py`) ilə eyni Bunny Stream API.
Hər müəllimin videosu öz Bunny collection-una düşür (`TeacherProfile.bunny_collection_id`).
Portalda lesson dərhal publish olunur (tələbələr görə bilir).

**Vacib:** Jibri recording qovluğunun adı session ID-dir; real Meet room
`metadata.json` → `meeting_url` (və ya MP4 callName) ilə götürülür — əks halda
upload-meta `room not found` verir və video library root-a düşür.

Log: hər recorder-də `/var/log/jitsi/bunny-uploads.jsonl`

---

## Arxitektura

```
                    Internet
                       │
          ┌────────────┼────────────┐
          ▼                         ▼
   meet-control                 meet-jvb
   (HTTPS/XMPP/TURN)            (UDP 10000)
          │                         │
          └──────────┬──────────────┘
                     │ VPC internal
              ┌──────┴──────┐
              ▼             ▼
        recorder-1     recorder-2
        jibri@1…@5     jibri@1…@5
              │             │
              └──────┬──────┘
                     ▼
               Bunny Stream
```

```bash
CONCURRENT_RECORDINGS=10   # eyni anda max recording
# RECORDER_COUNT=2         # optional
# JIBRI_PER_VM=5           # optional
```

**IP qənaəti:** yalnız `meet-control` və `meet-jvb` statik xarici IP. Recorder-lər yalnız daxili IP (SSH: meet-control bastion).

---

## Schedule

`ENABLE_SCHEDULE=true` → Cloud Scheduler VM start/stop.

| Bakı | UTC (default) |
|------|---------------|
| 07:30 start | 03:30 |
| 10:05 stop | 06:05 |

```bash
GCP_PROJECT_ID=... GCP_ZONE=europe-west1-b ./scripts/schedule-all.sh start
GCP_PROJECT_ID=... GCP_ZONE=europe-west1-b ./scripts/schedule-all.sh stop
```

**24/7 açıq saxlamaq** (scheduler pause + VM start):

```bash
./scripts/scheduler-pause-keep-on.sh
```

**Yenidən avtomatik cədvəl** (scheduler resume; pəncərədədirsə VM start):

```bash
./scripts/scheduler-resume.sh
```

---

## Fayl strukturu

```
jitsi-cluster/
├── deploy.sh
├── destroy.sh
├── .env.example
├── config/
│   ├── meet-custom.js      # live 15-user + recording
│   ├── jvb-custom.conf
│   ├── jicofo-custom.conf
│   ├── prosody-muc.snippet
│   └── sysctl-jitsi.conf
├── scripts/
│   ├── setup-control.sh
│   ├── setup-jvb.sh
│   ├── setup-jibri.sh      # multi-slot Jibri
│   ├── bunny-upload.sh
│   ├── finalize_recording.sh
│   ├── telegram-notify.sh
│   ├── health-notify.sh
│   ├── install-telegram-alerts.sh
│   ├── install-telegram-scheduler-jobs.sh
│   ├── schedule-all.sh
│   ├── scheduler-pause-keep-on.sh
│   ├── scheduler-resume.sh
│   └── install-scheduler-jobs.sh
└── terraform/
    ├── main.tf
    ├── variables.tf
    └── outputs.tf
```

---

## Quota (yeni GCP hesabı)

| Limit | Default | Bu deploy |
|-------|---------|-----------|
| `CPUS_ALL_REGIONS` | 32 | 4+8+2×8 = **28** |
| `IN_USE_ADDRESSES` | 8 | **2** |

Daha çox paralel recording: `CONCURRENT_RECORDINGS` artırın və ya [Quota](https://console.cloud.google.com/iam-admin/quotas) artırın.

---

## Troubleshooting

| Problem | Həll |
|---------|------|
| `CPUS_ALL_REGIONS` exceeded | `RECORDER_COUNT` / `JIBRI_MACHINE_TYPE` azaldın və ya quota |
| `connection refused` (Terraform) | Cloud Shell → GCP API şəbəkəsi; bir az sonra `./deploy.sh` |
| `409 alreadyExists` (NAT/IP/VM) | `deploy.sh` avtomatik import edir (`tf-import-existing.sh`, NAT daxil) |
| **Not Secure** / self-signed | DNS → control IP, sonra [SSL / Let's Encrypt](#ssl--lets-encrypt-not-secure) |
| Telegram gəlmir | `.env` token/chat; `./scripts/telegram-notify.sh "test"`; control: `cron.d/jitsi-health-notify` |
| Bunny key/library | `.env` yenilə → `./update-bunny.sh` |
| `Not ready yet` / ingress UI fərqli | `./repair-join.sh` (JVB+focus+Jibri Prosody auth) |
| Recording düyməsi yoxdur | `journalctl -u 'jibri@*' -n 50` |
| JVB qoşulmur | Prosody 5222 + `jitsi-allow-internal` |
| Bunny upload fail | `/var/log/jitsi/recording-finalize.log`, `bunny.env` |
| Recorder setup | `secrets/setup-recorder-*.log` |

Silmək:

```bash
./destroy.sh
```

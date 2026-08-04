#!/usr/bin/env bash
# Recorder VM: bir neçə Jibri prosesi (systemd jibri@N) → Bunny upload → delete
# JIBRI_PER_VM=5 → eyni hostda 5 paralel recording slot
# Default cluster: 2 VM × 5 = 10 eyni anda recording

set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib.sh
source "${SCRIPT_DIR}/lib.sh"
require_root

DOMAIN="${DOMAIN:?}"
CONTROL_PRIVATE_IP="${CONTROL_PRIVATE_IP:?}"
JIBRI_RECORDER_PASS="${JIBRI_RECORDER_PASS:?}"
JIBRI_XMPP_PASS="${JIBRI_XMPP_PASS:?}"
RECORDER_HOST_ID="${RECORDER_HOST_ID:-$(hostname -s)}"
JIBRI_PER_VM="${JIBRI_PER_VM:-5}"
BUNNY_LIBRARY_ID="${BUNNY_LIBRARY_ID:-}"
BUNNY_API_KEY="${BUNNY_API_KEY:-}"
BUNNY_CDN_HOSTNAME="${BUNNY_CDN_HOSTNAME:-}"

if ! [[ "${JIBRI_PER_VM}" =~ ^[0-9]+$ ]] || (( JIBRI_PER_VM < 1 || JIBRI_PER_VM > 20 )); then
  err "JIBRI_PER_VM 1–20 arası olmalıdır (indi: ${JIBRI_PER_VM})"
  exit 1
fi

log "Recorder setup: host=${RECORDER_HOST_ID} slots=${JIBRI_PER_VM} control=${CONTROL_PRIVATE_IP}"

install_base
add_jitsi_repo
install_recorder_deps
apply_sysctl "${SCRIPT_DIR}/../config/sysctl-jitsi.conf"

hostnamectl set-hostname "${RECORDER_HOST_ID}.${DOMAIN}"
grep -q "${DOMAIN}" /etc/hosts || echo "${CONTROL_PRIVATE_IP} ${DOMAIN}" >> /etc/hosts
grep -q "auth.${DOMAIN}" /etc/hosts || echo "${CONTROL_PRIVATE_IP} auth.${DOMAIN}" >> /etc/hosts
grep -q "recorder.${DOMAIN}" /etc/hosts || echo "${CONTROL_PRIVATE_IP} recorder.${DOMAIN}" >> /etc/hosts

# ALSA loopback — hər Jibri slot üçün ayrı kart
ALOOP_ENABLE="$(python3 - <<PY
n = int("${JIBRI_PER_VM}")
print(",".join(["1"] * n))
PY
)"
ALOOP_INDEX="$(python3 - <<PY
n = int("${JIBRI_PER_VM}")
print(",".join(str(i) for i in range(n)))
PY
)"
mkdir -p /etc/modprobe.d
cat > /etc/modprobe.d/alsa-loopback.conf <<EOF
options snd-aloop enable=${ALOOP_ENABLE} index=${ALOOP_INDEX}
EOF
if ! grep -q '^snd-aloop' /etc/modules; then
  echo "snd-aloop" >> /etc/modules
fi
modprobe -r snd-aloop 2>/dev/null || true
if ! modprobe snd-aloop; then
  warn "snd-aloop yüklənmədi — audio loopback olmadan davam (recording səssiz ola bilər)"
fi

# Jibri paketi
wait_apt
apt-get install -y jibri
ensure_cmds jq:jq curl:curl Xvfb:xvfb ffmpeg:ffmpeg

# Default single jibri.service — multi-instance istifadə edirik
systemctl stop jibri 2>/dev/null || true
systemctl disable jibri 2>/dev/null || true

mkdir -p /srv/recordings /opt/jitsi-jibri /etc/jitsi/jibri/instances /var/log/jitsi
chown jibri:jibri /srv/recordings
# jibri user launch-slot-*.sh yaza bilməlidir
chown jibri:jibri /opt/jitsi-jibri
chmod 755 /opt/jitsi-jibri
# Finalize / upload logları — jibri user yazabilsin (5 paralel slot)
touch /var/log/jitsi/recording-finalize.log /var/log/jitsi/bunny-uploads.jsonl
chown -R jibri:jibri /var/log/jitsi
chmod 755 /var/log/jitsi
chmod 644 /var/log/jitsi/recording-finalize.log /var/log/jitsi/bunny-uploads.jsonl

if [[ -z "${BUNNY_LIBRARY_ID}" || -z "${BUNNY_API_KEY}" ]]; then
  die "BUNNY_LIBRARY_ID / BUNNY_API_KEY boşdur — recording upload işləməyəcək"
fi

cat > /opt/jitsi-jibri/bunny.env <<ENV
BUNNY_LIBRARY_ID=${BUNNY_LIBRARY_ID}
BUNNY_API_KEY=${BUNNY_API_KEY}
BUNNY_CDN_HOSTNAME=${BUNNY_CDN_HOSTNAME}
PORTAL_UPLOAD_META_URL=${PORTAL_UPLOAD_META_URL:-}
PORTAL_UPLOAD_META_TOKEN=${PORTAL_UPLOAD_META_TOKEN:-}
TELEGRAM_BOT_TOKEN=${TELEGRAM_BOT_TOKEN:-}
TELEGRAM_CHAT_ID=${TELEGRAM_CHAT_ID:-}
TELEGRAM_TOPIC_ID=${TELEGRAM_TOPIC_ID:-}
TELEGRAM_NOTIFY=${TELEGRAM_NOTIFY:-true}
ENV
chmod 600 /opt/jitsi-jibri/bunny.env
chown jibri:jibri /opt/jitsi-jibri/bunny.env
log "Bunny env yazıldı (library=${BUNNY_LIBRARY_ID}${PORTAL_UPLOAD_META_URL:+, portal meta=on})"

cat > /opt/jitsi-jibri/telegram.env <<TGENV
TELEGRAM_BOT_TOKEN=${TELEGRAM_BOT_TOKEN:-}
TELEGRAM_CHAT_ID=${TELEGRAM_CHAT_ID:-}
TELEGRAM_TOPIC_ID=${TELEGRAM_TOPIC_ID:-}
TELEGRAM_NOTIFY=${TELEGRAM_NOTIFY:-true}
TGENV
chmod 600 /opt/jitsi-jibri/telegram.env
chown jibri:jibri /opt/jitsi-jibri/telegram.env

cp "${SCRIPT_DIR}/bunny-upload.sh" /opt/jitsi-jibri/bunny-upload.sh
cp "${SCRIPT_DIR}/finalize_recording.sh" /opt/jitsi-jibri/finalize_recording.sh
[[ -f "${SCRIPT_DIR}/telegram-notify.sh" ]] && cp "${SCRIPT_DIR}/telegram-notify.sh" /opt/jitsi-jibri/telegram-notify.sh
chmod 755 /opt/jitsi-jibri/bunny-upload.sh /opt/jitsi-jibri/finalize_recording.sh
[[ -f /opt/jitsi-jibri/telegram-notify.sh ]] && chmod 755 /opt/jitsi-jibri/telegram-notify.sh
chown jibri:jibri /opt/jitsi-jibri/*.sh /opt/jitsi-jibri/*.env 2>/dev/null || chown jibri:jibri /opt/jitsi-jibri/*.sh

# launch.sh path — Debian/Ubuntu paketində fərqli ola bilər
LAUNCH=""
for p in /opt/jitsi/jibri/launch.sh /usr/share/jibri/launch.sh; do
  if [[ -x "${p}" ]]; then
    LAUNCH="${p}"
    break
  fi
done
if [[ -z "${LAUNCH}" ]]; then
  if [[ -f /lib/systemd/system/jibri.service ]]; then
    LAUNCH="$(grep -E '^ExecStart=' /lib/systemd/system/jibri.service | head -1 | cut -d= -f2- | awk '{print $1}')"
  fi
fi
if [[ -z "${LAUNCH}" || ! -x "${LAUNCH}" ]]; then
  err "Jibri launch.sh tapılmadı"
  exit 1
fi

# ChromeDriver bəzən DISPLAY-i child Chrome-a ötürmür → wrapper məcburi inject edir
if [[ -x /usr/bin/google-chrome-stable && ! -x /usr/bin/google-chrome-stable.real ]]; then
  mv /usr/bin/google-chrome-stable /usr/bin/google-chrome-stable.real
fi
cat > /usr/local/bin/jibri-chrome-wrapper <<'CWRAP'
#!/usr/bin/env bash
set -euo pipefail
# ChromeDriver often passes DISPLAY=:0 — always derive from slot, never trust :0
SLOT=""
for arg in "$@"; do
  case "$arg" in
    --user-data-dir=/tmp/jibri-chrome-*)
      s="${arg##*-}"
      [[ "$s" =~ ^[0-9]+$ ]] && SLOT="$s"
      ;;
  esac
done
if [[ -z "$SLOT" && "${HOME:-}" =~ slot-([0-9]+) ]]; then
  SLOT="${BASH_REMATCH[1]}"
fi
if [[ -z "$SLOT" && -f "${HOME:-}/.jibri-slot" ]]; then
  SLOT="$(cat "${HOME}/.jibri-slot")"
fi
if [[ -n "$SLOT" ]]; then
  export DISPLAY=":${SLOT}"
elif [[ -z "${DISPLAY:-}" || "${DISPLAY}" == ":0" ]]; then
  for n in 1 2 3 4 5; do
    if [[ -S "/tmp/.X11-unix/X${n}" ]]; then
      export DISPLAY=":${n}"
      break
    fi
  done
fi
export DISPLAY="${DISPLAY:-:1}"
REAL="/usr/bin/google-chrome-stable.real"
[[ -x "$REAL" ]] || REAL="/opt/google/chrome/google-chrome"
exec "$REAL" "$@"
CWRAP
chmod 755 /usr/local/bin/jibri-chrome-wrapper
ln -sfn /usr/local/bin/jibri-chrome-wrapper /usr/bin/google-chrome-stable
ln -sfn /usr/local/bin/jibri-chrome-wrapper /usr/bin/google-chrome

# Jibri Java often still has DISPLAY=:0 → ffmpeg x11grab fails on :0.0
if [[ -x /usr/bin/ffmpeg && ! -L /usr/bin/ffmpeg && ! -x /usr/bin/ffmpeg.real ]]; then
  mv /usr/bin/ffmpeg /usr/bin/ffmpeg.real
fi
cat > /usr/local/bin/jibri-ffmpeg-wrapper <<'FWRAP'
#!/usr/bin/env bash
set -euo pipefail
SLOT=""
if [[ "${HOME:-}" =~ slot-([0-9]+) ]]; then
  SLOT="${BASH_REMATCH[1]}"
elif [[ -f "${HOME:-}/.jibri-slot" ]]; then
  SLOT="$(cat "${HOME}/.jibri-slot")"
fi
if [[ -z "$SLOT" ]]; then
  for n in 1 2 3 4 5; do
    if [[ -S "/tmp/.X11-unix/X${n}" ]]; then
      SLOT="$n"
      break
    fi
  done
fi
SLOT="${SLOT:-1}"
export DISPLAY=":${SLOT}"
ARGS=()
for a in "$@"; do
  case "$a" in
    :0|:0.0|:0.0+0,0)
      ARGS+=(":${SLOT}.0+0,0")
      ;;
    *)
      a="${a//:0.0+0,0/:${SLOT}.0+0,0}"
      a="${a//:0.0/:${SLOT}.0}"
      ARGS+=("$a")
      ;;
  esac
done
echo "$(date -Iseconds) DISPLAY=${DISPLAY} SLOT=${SLOT} ffmpeg ${ARGS[*]}" >> /tmp/jibri-ffmpeg-wrapper.log 2>/dev/null || true
REAL="/usr/bin/ffmpeg.real"
[[ -x "$REAL" ]] || REAL="/usr/bin/ffmpeg"
exec "$REAL" "${ARGS[@]}"
FWRAP
chmod 755 /usr/local/bin/jibri-ffmpeg-wrapper
ln -sfn /usr/local/bin/jibri-ffmpeg-wrapper /usr/local/bin/ffmpeg
if [[ -x /usr/bin/ffmpeg.real ]]; then
  ln -sfn /usr/local/bin/jibri-ffmpeg-wrapper /usr/bin/ffmpeg
fi

# Wrapper: hər slot üçün ayrı HOME / Xvfb DISPLAY / instance.conf
# Paket launch.sh -Dconfig.file=/etc/jitsi/jibri/jibri.conf hardcode edir —
# ona görə hər slot üçün patch edilmiş launch-slot-N.sh yaradırıq.
cat > /opt/jitsi-jibri/run-jibri-slot.sh <<WRAP
#!/usr/bin/env bash
set -euo pipefail
SLOT="\${1:?slot}"
CONF="/etc/jitsi/jibri/instances/\${SLOT}.conf"
export HOME="/var/lib/jibri/slot-\${SLOT}"
export DISPLAY=":\${SLOT}"
mkdir -p "\${HOME}" "/tmp/jibri-chrome-\${SLOT}" "/tmp/.X11-unix" "/tmp/jibri-upload-\${SLOT}"
echo "\${SLOT}" > "\${HOME}/.jibri-slot"

if [[ ! -f "\${CONF}" ]]; then
  echo "Missing instance config: \${CONF}" >&2
  exit 1
fi

# Slot üçün Xvfb (həmişə təmiz start)
pkill -f "Xvfb :\${SLOT} " >/dev/null 2>&1 || true
sleep 0.3
if ! command -v Xvfb >/dev/null 2>&1; then
  echo "Xvfb yoxdur — xvfb paketini quraşdırın" >&2
  exit 1
fi
Xvfb ":\${SLOT}" -screen 0 1920x1080x24 -ac +extension RANDR >/tmp/xvfb-\${SLOT}.log 2>&1 &
for _ in \$(seq 1 10); do
  if DISPLAY=":\${SLOT}" xdpyinfo >/dev/null 2>&1 || [[ -S "/tmp/.X11-unix/X\${SLOT}" ]]; then
    break
  fi
  sleep 0.5
done

LAUNCH_SRC="${LAUNCH}"
LAUNCH_COPY="/opt/jitsi-jibri/launch-slot-\${SLOT}.sh"
cp "\${LAUNCH_SRC}" "\${LAUNCH_COPY}"
chmod 755 "\${LAUNCH_COPY}"
# Hardcoded default jibri.conf → bu slotun instance conf-u
sed -i -E "s|-Dconfig.file=[^ ]*|-Dconfig.file=\${CONF}|g" "\${LAUNCH_COPY}" || true
sed -i -E "s|config.file=\"/etc/jitsi/jibri/jibri.conf\"|config.file=\"\${CONF}\"|g" "\${LAUNCH_COPY}" || true
# Hardcoded :0 → bu slotun display-i
sed -i -E "s/DISPLAY=:0/DISPLAY=:\${SLOT}/g; s/Xvfb :0/Xvfb :\${SLOT}/g; s/:0 /:\${SLOT} /g" "\${LAUNCH_COPY}" || true
exec env -i \
  PATH="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin" \
  HOME="\${HOME}" \
  DISPLAY=":\${SLOT}" \
  USER=jibri \
  LOGNAME=jibri \
  LANG="\${LANG:-C.UTF-8}" \
  "\${LAUNCH_COPY}"
WRAP
chmod 755 /opt/jitsi-jibri/run-jibri-slot.sh
chown jibri:jibri /opt/jitsi-jibri/run-jibri-slot.sh

# xdpyinfo optional (Xvfb socket check fallback var)
apt-get install -y -qq x11-utils >/dev/null 2>&1 || true

cat > /etc/systemd/system/jibri@.service <<UNIT
[Unit]
Description=Jitsi Jibri instance %i
After=network.target sound.target
Wants=network-online.target

[Service]
User=jibri
Group=jibri
UMask=0022
Type=simple
Environment=HOME=/var/lib/jibri/slot-%i
Environment=DISPLAY=:%i
ExecStart=/opt/jitsi-jibri/run-jibri-slot.sh %i
Restart=on-failure
RestartSec=5
# 5 paralel Chrome+ffmpeg üçün kifayət qədər limit
LimitNOFILE=65536
LimitNPROC=4096
TasksMax=infinity
TimeoutStopSec=30

[Install]
WantedBy=multi-user.target
UNIT

ufw_base
ufw allow from 10.0.0.0/8
ufw --force enable
usermod -aG adm,audio,video,plugdev jibri 2>/dev/null || true

systemctl daemon-reload

# Köhnə instance-ları söndür (JIBRI_PER_VM azalıbsa)
shopt -s nullglob
for old in /etc/jitsi/jibri/instances/*.conf; do
  idx="$(basename "${old}" .conf)"
  if ! [[ "${idx}" =~ ^[0-9]+$ ]] || (( idx < 1 || idx > JIBRI_PER_VM )); then
    systemctl disable --now "jibri@${idx}" 2>/dev/null || true
    rm -f "${old}"
  fi
done
shopt -u nullglob

ACTIVE=0
for i in $(seq 1 "${JIBRI_PER_VM}"); do
  NICK="${RECORDER_HOST_ID}-slot-${i}"
  EXT_PORT=$((2222 + i - 1))
  INT_PORT=$((3333 + i - 1))
  REC_DIR="/srv/recordings/slot-${i}"
  SLOT_HOME="/var/lib/jibri/slot-${i}"
  # ALSA kart indeksi 0-based
  CARD=$((i - 1))
  mkdir -p "${REC_DIR}" "${SLOT_HOME}" "/tmp/jibri-chrome-${i}" "/tmp/jibri-upload-${i}"
  chown -R jibri:jibri "${REC_DIR}" "${SLOT_HOME}" "/tmp/jibri-chrome-${i}" "/tmp/jibri-upload-${i}"

  # Hər slot öz loopback kartına bağlanır.
  # Jibri ffmpeg default: plug:bsnoop — pcm.bsnoop mütləqdir.
  # Chrome playback hw:N,0,0 → capture hw:N,1,0 (aloop cross-cable).
  cat > "${SLOT_HOME}/.asoundrc" <<ASOUND
pcm.!default {
  type asym
  playback.pcm "amix"
  capture.pcm "asnoop"
}
pcm.amix {
  type dmix
  ipc_key $((7000 + CARD))
  slave {
    pcm "hw:${CARD},0,0"
    channels 2
    rate 48000
  }
}
pcm.asnoop {
  type dsnoop
  ipc_key $((8000 + CARD))
  slave {
    pcm "hw:${CARD},1,0"
    channels 2
    rate 48000
  }
}
pcm.bsnoop {
  type plug
  slave.pcm "asnoop"
}
ctl.!default {
  type hw
  card ${CARD}
}
ASOUND
  chown jibri:jibri "${SLOT_HOME}/.asoundrc"

  cat > "/etc/jitsi/jibri/instances/${i}.conf" <<JIBRI
jibri {
  id = "${NICK}"
  single-use-mode = false

  recording {
    recordings-directory = "${REC_DIR}"
    finalize-script = "/opt/jitsi-jibri/finalize_recording.sh"
  }

  api {
    http {
      external-api-port = ${EXT_PORT}
      internal-api-port = ${INT_PORT}
    }
    xmpp {
      environments = [
        {
          name = "prod"
          xmpp-server-hosts = [ "${CONTROL_PRIVATE_IP}" ]
          xmpp-domain = "${DOMAIN}"

          control-muc {
            domain = "internal.auth.${DOMAIN}"
            room-name = "JibriBrewery"
            nickname = "${NICK}"
          }

          control-login {
            domain = "auth.${DOMAIN}"
            username = "jibri"
            password = "${JIBRI_XMPP_PASS}"
          }

          call-login {
            domain = "recorder.${DOMAIN}"
            username = "recorder"
            password = "${JIBRI_RECORDER_PASS}"
          }

          strip-from-room-domain = "conference."
          usage-timeout = 0
          trust-all-xmpp-certs = true
        }
      ]
    }
  }

  chrome {
    flags = [
      "--use-fake-ui-for-media-stream",
      "--window-size=1920,1080",
      "--window-position=0,0",
      "--start-maximized",
      "--kiosk",
      "--disable-infobars",
      "--autoplay-policy=no-user-gesture-required",
      "--ignore-certificate-errors",
      "--no-sandbox",
      "--disable-dev-shm-usage",
      "--disable-gpu",
      "--force-device-scale-factor=1",
      "--user-data-dir=/tmp/jibri-chrome-${i}"
    ]
  }

  # Screen recording: 1080p, yazı/screenshare üçün daha yüksək keyfiyyət
  ffmpeg {
    resolution = "1920x1080"
    framerate = 30
    video-encode-preset-recording = "medium"
    h264-constant-rate-factor = 18
    audio-source = "alsa"
    audio-device = "plug:bsnoop"
  }
}
JIBRI
  chown jibri:jibri "/etc/jitsi/jibri/instances/${i}.conf"

  systemctl enable "jibri@${i}"
  systemctl restart "jibri@${i}"
  sleep 2
  if systemctl is-active --quiet "jibri@${i}"; then
    log "Jibri aktiv: ${NICK} (DISPLAY=:${i} ports ${EXT_PORT}/${INT_PORT})"
    ACTIVE=$((ACTIVE + 1))
  else
    warn "Jibri start olmadı: jibri@${i} — journalctl -u jibri@${i} -n 40"
    journalctl -u "jibri@${i}" --no-pager -n 25 || true
  fi
done

log "Recorder ${RECORDER_HOST_ID}: ${ACTIVE}/${JIBRI_PER_VM} Jibri slot aktiv"
if (( ACTIVE < 1 )); then
  err "Heç bir Jibri slot işə düşmədi"
  exit 1
fi
if (( ACTIVE < JIBRI_PER_VM )); then
  warn "Yalnız ${ACTIVE}/${JIBRI_PER_VM} slot işləyir — paralel capacity azalacaq"
fi

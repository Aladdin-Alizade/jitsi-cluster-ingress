#!/usr/bin/env bash
# meet-control: Nginx + Prosody + Jicofo + Coturn (+ optional local JVB disabled)
# Live server konfiqlərinə əsasən (meet.ingress.academy)

set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib.sh
source "${SCRIPT_DIR}/lib.sh"
require_root

DOMAIN="${DOMAIN:?DOMAIN required}"
ADMIN_EMAIL="${ADMIN_EMAIL:?ADMIN_EMAIL required}"
JVB_PASSWORD="${JVB_PASSWORD:?}"
JICOFO_PASSWORD="${JICOFO_PASSWORD:?}"
JIBRI_RECORDER_PASS="${JIBRI_RECORDER_PASS:?}"
JIBRI_XMPP_PASS="${JIBRI_XMPP_PASS:?}"
TURN_SECRET="${TURN_SECRET:?}"
JVB_PUBLIC_IP="${JVB_PUBLIC_IP:?}"
JVB_PRIVATE_IP="${JVB_PRIVATE_IP:-}"
CONTROL_PUBLIC_IP="${CONTROL_PUBLIC_IP:-$(public_ip)}"

log "Control setup: domain=${DOMAIN} ip=${CONTROL_PUBLIC_IP}"

install_base
add_jitsi_repo
apply_sysctl "${SCRIPT_DIR}/../config/sysctl-jitsi.conf"

hostnamectl set-hostname "${DOMAIN}"
grep -q "${DOMAIN}" /etc/hosts || echo "${CONTROL_PUBLIC_IP} ${DOMAIN}" >> /etc/hosts

# Debconf — self-signed first, then LE
debconf-set-selections <<EOF
jitsi-meet-web-config jitsi-meet/jvb-hostname string ${DOMAIN}
jitsi-meet-web-config jitsi-videobridge/jvb-hostname string ${DOMAIN}
jitsi-meet-prosody jitsi-meet-prosody/jvb-hostname string ${DOMAIN}
jitsi-meet-prosody jitsi-videobridge/jvb-hostname string ${DOMAIN}
jitsi-meet-turnserver jitsi-meet-turnserver/jvb-hostname string ${DOMAIN}
jitsi-meet-turnserver jitsi-videobridge/jvb-hostname string ${DOMAIN}
jicofo jitsi-videobridge/jvb-hostname string ${DOMAIN}
jitsi-videobridge2 jitsi-videobridge/jvb-hostname string ${DOMAIN}
jitsi-meet-web-config jitsi-meet/cert-choice select Generate a new self-signed certificate (You will later get a chance to obtain a Let's encrypt certificate)
EOF

wait_apt
apt-get install -y jitsi-meet

# Disable local JVB on control (remote meet-jvb istifadə olunur)
systemctl stop jitsi-videobridge2 || true
systemctl disable jitsi-videobridge2 || true

# --- Prosody users (fixed passwords for cluster) ---
log "Prosody istifadəçiləri yenilənir..."
prosodyctl unregister jvb "auth.${DOMAIN}" 2>/dev/null || true
prosodyctl unregister focus "auth.${DOMAIN}" 2>/dev/null || true
prosodyctl unregister jibri "auth.${DOMAIN}" 2>/dev/null || true
prosodyctl unregister recorder "recorder.${DOMAIN}" 2>/dev/null || true

prosodyctl register jvb "auth.${DOMAIN}" "${JVB_PASSWORD}"
prosodyctl register focus "auth.${DOMAIN}" "${JICOFO_PASSWORD}"
prosodyctl register jibri "auth.${DOMAIN}" "${JIBRI_XMPP_PASS}"
prosodyctl register recorder "recorder.${DOMAIN}" "${JIBRI_RECORDER_PASS}"

# --- Prosody: Jibri brewery + recorder whitelist ---
PROSODY_CFG="/etc/prosody/conf.avail/${DOMAIN}.cfg.lua"
if [[ -f "${PROSODY_CFG}" ]]; then
  # Ensure recorder virtualhost exists (package usually creates it)
  if ! grep -q "VirtualHost \"recorder.${DOMAIN}\"" "${PROSODY_CFG}"; then
    cat >> "${PROSODY_CFG}" <<PREOF

VirtualHost "recorder.${DOMAIN}"
    modules_enabled = { "smacks"; }
    authentication = "internal_hashed"
    smacks_max_old_sessions = 2000;
PREOF
  fi

  # Internal muc admins for jibri
  if ! grep -q "jibri@auth.${DOMAIN}" "${PROSODY_CFG}"; then
    sed -i "s/admins = { \"focus@auth.${DOMAIN}\", \"jvb@auth.${DOMAIN}\" }/admins = { \"focus@auth.${DOMAIN}\", \"jvb@auth.${DOMAIN}\", \"jibri@auth.${DOMAIN}\" }/" "${PROSODY_CFG}" || true
  fi

  # Lobby whitelist for recorder (commented default-u aktiv et)
  if grep -qE "^[[:space:]]*--[[:space:]]*muc_lobby_whitelist" "${PROSODY_CFG}"; then
    sed -i "s/-- muc_lobby_whitelist = { \"recorder.${DOMAIN}\" }/muc_lobby_whitelist = { \"recorder.${DOMAIN}\" }/" "${PROSODY_CFG}" || true
  fi
  if ! grep -qE "^[[:space:]]*muc_lobby_whitelist" "${PROSODY_CFG}"; then
    sed -i "/main_muc = \"conference.${DOMAIN}\"/a\\    muc_lobby_whitelist = { \"recorder.${DOMAIN}\" }" "${PROSODY_CFG}" || true
  fi

  # TURN secret
  sed -i "s/external_service_secret = \".*\"/external_service_secret = \"${TURN_SECRET}\"/" "${PROSODY_CFG}" || true

  # Password whitelist for recorder (join locked rooms)
  if ! grep -q "recorder@recorder.${DOMAIN}" "${PROSODY_CFG}"; then
    sed -i "/muc_password_whitelist = {/a\\        \"recorder@recorder.${DOMAIN}\"," "${PROSODY_CFG}" || true
  fi

  # Live server: MUC max 15 iştirakçı
  if ! grep -q "muc_max_occupants" "${PROSODY_CFG}"; then
    sed -i "s/Component \"conference.${DOMAIN}\" \"muc\"/Component \"conference.${DOMAIN}\" \"muc\"\n    muc_max_occupants = 15/" "${PROSODY_CFG}" || true
  fi
  # Option tək kifayət deyil — modul da aktiv olmalıdır
  if grep -q "muc_max_occupants" "${PROSODY_CFG}" && ! grep -q '"muc_max_occupants"' "${PROSODY_CFG}"; then
    sed -i "/Component \"conference.${DOMAIN}\" \"muc\"/,/modules_enabled = {/{
      /modules_enabled = {/a\\        \"muc_max_occupants\";
    }" "${PROSODY_CFG}" || true
  fi
fi

# Prosody 0.12 + yeni jitsi-meet-prosody: prosody.util.* → util.* (join/speakerstats break olmasın)
# https://github.com/jitsi/jitsi-meet/commit/5e9c44ff73863f876f1a77d306ded5a3bb98ad90
for _pf in /usr/share/jitsi-meet/prosody-plugins/mod_speakerstats_component.lua \
           /usr/share/jitsi-meet/prosody-plugins/mod_room_metadata_component.lua \
           /usr/share/jitsi-meet/prosody-plugins/mod_short_lived_token.lua; do
  if [[ -f "${_pf}" ]]; then
    sed -i \
      -e 's/require "prosody\.util\./require "util./g' \
      -e "s/require 'prosody\.util\./require 'util./g" \
      "${_pf}" || true
  fi
done

# Prosody: remote JVB/Jibri üçün bütün interfeyslərdə dinlə
PROSODY_MAIN="/etc/prosody/prosody.cfg.lua"
if [[ -f "${PROSODY_MAIN}" ]]; then
  grep -q 'c2s_interfaces' "${PROSODY_MAIN}" || echo 'c2s_interfaces = { "*" }' >> "${PROSODY_MAIN}"
  grep -q 'component_interfaces' "${PROSODY_MAIN}" || echo 'component_interfaces = { "*" }' >> "${PROSODY_MAIN}"
fi

# --- Jicofo ---
log "Jicofo konfiqurasiyası..."
# focus user yuxarıda register olunur; hostname localhost — client_proxy service-unavailable olmasın
cat > /etc/jitsi/jicofo/jicofo.conf <<JICOFO
jicofo {
  xmpp: {
    client: {
      hostname: "127.0.0.1"
      port: 5222
      client-proxy: "focus.${DOMAIN}"
      xmpp-domain: "${DOMAIN}"
      domain: "auth.${DOMAIN}"
      username: "focus"
      password: "${JICOFO_PASSWORD}"
      # LE cert yalnız ${DOMAIN} üçündür; auth.* SAN yoxdur — localhost XMPP üçün lazımdır
      disable-certificate-verification: true
    }
    trusted-domains: [ "recorder.${DOMAIN}" ]
  }
  bridge: {
    # setup-jvb.sh ilə eyni (lowercase) — əks halda ayrı MUC otağı yaranır
    brewery-jid: "jvbbrewery@internal.auth.${DOMAIN}"
    selection-strategy: "SplitBridgeSelectionStrategy"
    stress-threshold: 0.8
  }
  conference: {
    max-participants: 15
    max-bridge-participants: 40
    enable-auto-owner: true
    strip-simulcast: false
  }
  jibri: {
    brewery-jid: "jibribrewery@internal.auth.${DOMAIN}"
    pending-timeout: 90 seconds
  }
  sctp {
    enabled: true
  }
}
JICOFO

# --- TURN secret ---
if [[ -f /etc/turnserver.conf ]]; then
  sed -i "s/^static-auth-secret=.*/static-auth-secret=${TURN_SECRET}/" /etc/turnserver.conf
  sed -i "s/^realm=.*/realm=${DOMAIN}/" /etc/turnserver.conf
fi

# --- Nginx site ---
NGX_CONF="/etc/nginx/sites-available/${DOMAIN}.conf"
if [[ ! -f "${NGX_CONF}" ]]; then
  cp /usr/share/jitsi-meet-web-config/jitsi-meet.example "${NGX_CONF}"
  sed -i "s/jitsi-meet.example.com/${DOMAIN}/g" "${NGX_CONF}"
fi
ln -sf "${NGX_CONF}" "/etc/nginx/sites-enabled/${DOMAIN}.conf"
rm -f /etc/nginx/sites-enabled/default

# Self-signed if missing
if [[ ! -f "/etc/jitsi/meet/${DOMAIN}.crt" ]]; then
  openssl req -new -x509 -days 3650 -nodes \
    -out "/etc/jitsi/meet/${DOMAIN}.crt" \
    -keyout "/etc/jitsi/meet/${DOMAIN}.key" \
    -subj "/CN=${DOMAIN}"
  chmod 640 "/etc/jitsi/meet/${DOMAIN}.key"
  chown root:ssl-cert "/etc/jitsi/meet/${DOMAIN}.key" 2>/dev/null || true
fi

# --- Meet config.js custom ---
MEET_CONFIG="/etc/jitsi/meet/${DOMAIN}-config.js"
if [[ ! -f "${MEET_CONFIG}" ]] || [[ $(wc -l < "${MEET_CONFIG}") -lt 200 ]]; then
  cp /usr/share/jitsi-meet-web-config/config.js "${MEET_CONFIG}"
  sed -i "s/jitsi-meet.example.com/${DOMAIN}/g" "${MEET_CONFIG}"
fi

# hosts / bosh / websocket
if ! grep -q "JITSI_CUSTOM_15_USERS" "${MEET_CONFIG}"; then
  {
    echo ""
    echo "// JITSI_CUSTOM_15_USERS"
    echo "config.hosts.domain = '${DOMAIN}';"
    echo "config.hosts.muc = 'conference.' + config.hosts.domain;"
    echo "config.bosh = 'https://${DOMAIN}/http-bind';"
    echo "config.websocket = 'wss://${DOMAIN}/xmpp-websocket';"
    sed "s/__DOMAIN__/${DOMAIN}/g" "${SCRIPT_DIR}/../config/meet-custom.js"
  } >> "${MEET_CONFIG}"
else
  # Mövcud install: kritik join fix-ləri yenilə
  grep -q "^config.conferenceRequestUrl" "${MEET_CONFIG}" || \
    echo "config.conferenceRequestUrl = 'https://${DOMAIN}/conference-request/v1';" >> "${MEET_CONFIG}"
  grep -q "^config.focusUserJid" "${MEET_CONFIG}" || \
    echo "config.focusUserJid = 'focus@auth.${DOMAIN}';" >> "${MEET_CONFIG}"
  grep -q "^config.disableDeepLinking" "${MEET_CONFIG}" || \
    echo "config.disableDeepLinking = true;" >> "${MEET_CONFIG}"
  sed -i "s/^config.defaultLanguage = 'az';/config.defaultLanguage = 'en';/" "${MEET_CONFIG}" || true
fi

# --- Firewall ---
ufw_base
ufw allow 80/tcp
ufw allow 443/tcp
ufw allow 3478/udp
ufw allow 5349/tcp
# Prosody for remote JVB/Jibri (internal VPC + tagged firewall also covers)
ufw allow from 10.0.0.0/8 to any port 5222 proto tcp
ufw allow from 10.0.0.0/8 to any port 5347 proto tcp
ufw --force enable

# --- Let's Encrypt ---
apt-get install -y -qq cron
systemctl enable --now cron
log "Let's Encrypt..."
if [[ -x /usr/share/jitsi-meet/scripts/install-letsencrypt-cert.sh ]]; then
  # Ensure nginx up for ACME
  nginx -t && systemctl reload nginx || systemctl restart nginx
  echo "y" | /usr/share/jitsi-meet/scripts/install-letsencrypt-cert.sh "${ADMIN_EMAIL}" "${DOMAIN}" \
    || warn "Let's Encrypt uğursuz — self-signed qalır (DNS yoxlayın)"
fi

# LE cert yalnız DOMAIN SAN-ı ehtiva edir. Prosody auth.* / conference.* üçün
# ayrıca self-signed (CN=auth.DOMAIN) lazımdır — yoxsa jicofo TLS fail:
# "Certificate does not authenticate auth.DOMAIN"
log "Prosody subdomain sertifikatları..."
mkdir -p /etc/prosody/certs
if [[ -f "/etc/jitsi/meet/${DOMAIN}.crt" ]]; then
  cp -f "/etc/jitsi/meet/${DOMAIN}.crt" "/etc/prosody/certs/${DOMAIN}.crt"
  cp -f "/etc/jitsi/meet/${DOMAIN}.key" "/etc/prosody/certs/${DOMAIN}.key"
fi
for h in "auth.${DOMAIN}" "internal.auth.${DOMAIN}" "conference.${DOMAIN}" "recorder.${DOMAIN}" "guest.${DOMAIN}" "focus.${DOMAIN}"; do
  openssl req -new -x509 -days 3650 -nodes \
    -out "/etc/prosody/certs/${h}.crt" \
    -keyout "/etc/prosody/certs/${h}.key" \
    -subj "/CN=${h}" >/dev/null 2>&1 || true
done
chown -R root:prosody /etc/prosody/certs 2>/dev/null || chown -R prosody:prosody /etc/prosody/certs || true
chmod 640 /etc/prosody/certs/*.key 2>/dev/null || true
chmod 644 /etc/prosody/certs/*.crt 2>/dev/null || true

systemctl restart prosody
systemctl restart jicofo
systemctl restart coturn 2>/dev/null || systemctl restart turnserver 2>/dev/null || true
systemctl reload nginx || systemctl restart nginx
systemctl enable prosody jicofo nginx

# Write cluster secrets for remote nodes (local only)
mkdir -p /opt/jitsi-cluster /var/lib/jitsi-cluster
cat > /opt/jitsi-cluster/cluster.env <<ENV
DOMAIN=${DOMAIN}
CONTROL_PRIVATE_IP=$(private_ip)
CONTROL_PUBLIC_IP=${CONTROL_PUBLIC_IP}
JVB_PUBLIC_IP=${JVB_PUBLIC_IP}
JVB_PRIVATE_IP=${JVB_PRIVATE_IP}
JVB_PASSWORD=${JVB_PASSWORD}
JICOFO_PASSWORD=${JICOFO_PASSWORD}
JIBRI_RECORDER_PASS=${JIBRI_RECORDER_PASS}
JIBRI_XMPP_PASS=${JIBRI_XMPP_PASS}
TURN_SECRET=${TURN_SECRET}
JIBRI_PER_VM=${JIBRI_PER_VM:-5}
RECORDER_PRIVATE_IPS=${RECORDER_PRIVATE_IPS:-}
TELEGRAM_BOT_TOKEN=${TELEGRAM_BOT_TOKEN:-}
TELEGRAM_CHAT_ID=${TELEGRAM_CHAT_ID:-}
TELEGRAM_TOPIC_ID=${TELEGRAM_TOPIC_ID:-}
TELEGRAM_NOTIFY=${TELEGRAM_NOTIFY:-true}
ENV
chmod 600 /opt/jitsi-cluster/cluster.env

# Telegram notify + health cron
if [[ -f "${SCRIPT_DIR}/telegram-notify.sh" ]]; then
  cp "${SCRIPT_DIR}/telegram-notify.sh" /opt/jitsi-cluster/telegram-notify.sh
  chmod 755 /opt/jitsi-cluster/telegram-notify.sh
fi
if [[ -f "${SCRIPT_DIR}/health-notify.sh" ]]; then
  cp "${SCRIPT_DIR}/health-notify.sh" /opt/jitsi-cluster/health-notify.sh
  chmod 755 /opt/jitsi-cluster/health-notify.sh
fi
cat > /opt/jitsi-cluster/telegram.env <<TGENV
TELEGRAM_BOT_TOKEN=${TELEGRAM_BOT_TOKEN:-}
TELEGRAM_CHAT_ID=${TELEGRAM_CHAT_ID:-}
TELEGRAM_TOPIC_ID=${TELEGRAM_TOPIC_ID:-}
TELEGRAM_NOTIFY=${TELEGRAM_NOTIFY:-true}
TGENV
chmod 600 /opt/jitsi-cluster/telegram.env

if [[ -n "${TELEGRAM_BOT_TOKEN:-}" && -n "${TELEGRAM_CHAT_ID:-}" ]]; then
  CRON_LINE='*/5 * * * * root /opt/jitsi-cluster/health-notify.sh >>/var/log/jitsi/health-notify.log 2>&1'
  mkdir -p /var/log/jitsi
  touch /var/log/jitsi/health-notify.log
  echo "${CRON_LINE}" > /etc/cron.d/jitsi-health-notify
  chmod 644 /etc/cron.d/jitsi-health-notify
  systemctl enable --now cron 2>/dev/null || systemctl enable --now crond 2>/dev/null || true
  log "Telegram health cron quraşdırıldı (*/5)"
  /opt/jitsi-cluster/telegram-notify.sh "Jitsi meet-control setup OK: https://${DOMAIN}" || true
else
  rm -f /etc/cron.d/jitsi-health-notify
  log "Telegram token/chat boş — health cron skip"
fi

log "Control hazır: https://${DOMAIN}"
for svc in prosody jicofo nginx; do
  systemctl is-active --quiet "$svc" && echo "  ✓ $svc" || echo "  ✗ $svc"
done

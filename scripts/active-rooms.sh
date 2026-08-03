#!/usr/bin/env bash
# meet-control: Prosody MUC-də hazırda mövcud conference room-ları JSON çıxar.
# İstifadə: active-rooms.sh          → stdout JSON
#           active-rooms.sh --pretty
#
# Çıxış:
#   {"ok":true,"prosody_ok":true,"domain":"...","rooms":[{"room":"<uuid>","occupants":N},...]}
#
# occupants = human (non-recorder) count. Yalnız Jibri recorder qalıbsa room
# active siyahısına düşmür və busy Jibri üçün stopService çağırılır.
#
# Prosody down / shell fail → prosody_ok=false (portal bütün open meeting-ləri bağlayır).

set +e
set +u

export PATH="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin:${PATH:-}"

CLUSTER_ENV="${CLUSTER_ENV:-/opt/jitsi-cluster/cluster.env}"
if [[ -f "${CLUSTER_ENV}" ]]; then
  # shellcheck disable=SC1090
  set -a
  # shellcheck source=/dev/null
  source "${CLUSTER_ENV}"
  set +a
fi

DOMAIN="${DOMAIN:-}"
PRETTY=0
[[ "${1:-}" == "--pretty" ]] && PRETTY=1

SSH_USER="${SSH_USER:-ubuntu}"
SSH_KEY="${SSH_KEY:-/home/ubuntu/.ssh/id_rsa}"
JIBRI_PER_VM="${JIBRI_PER_VM:-5}"
RECORDER_PRIVATE_IPS="${RECORDER_PRIVATE_IPS:-}"
HIDDEN_DOMAIN="recorder.${DOMAIN}"

json_fail() {
  local msg="$1"
  if command -v jq >/dev/null 2>&1; then
    jq -nc --arg d "${DOMAIN}" --arg e "${msg}" \
      '{ok:false,prosody_ok:false,domain:$d,error:$e,rooms:[]}'
  else
    printf '{"ok":false,"prosody_ok":false,"domain":"%s","error":"%s","rooms":[]}\n' \
      "${DOMAIN}" "${msg}"
  fi
}

if [[ -z "${DOMAIN}" ]]; then
  json_fail "DOMAIN empty"
  exit 0
fi

if ! command -v jq >/dev/null 2>&1; then
  json_fail "jq missing"
  exit 0
fi

if ! systemctl is-active --quiet prosody 2>/dev/null; then
  json_fail "prosody inactive"
  exit 0
fi

MUC="conference.${DOMAIN}"
TMP_LIST="$(mktemp)"
cleanup() { rm -f "${TMP_LIST}" 2>/dev/null || true; }
trap cleanup EXIT

# --- List live MUC rooms via prosodyctl shell (Prosody 0.11+/0.12) ---
list_via_shell() {
  local out=""
  out="$(printf 'muc:list("%s")\nbye\n' "${MUC}" \
    | timeout 8 prosodyctl shell 2>/dev/null)" || true
  if [[ -z "${out}" ]]; then
    out="$(printf 'muc:list("%s")\nquit\n' "${MUC}" \
      | timeout 8 prosodyctl shell "${DOMAIN}" 2>/dev/null)" || true
  fi
  printf '%s\n' "${out}" \
    | grep -oE '[0-9a-fA-F-]{8,}@'"${MUC//./\\.}" \
    | sed "s/@${MUC}//" \
    | sort -u >"${TMP_LIST}" || true
  if [[ ! -s "${TMP_LIST}" ]]; then
    printf '%s\n' "${out}" \
      | grep -oE '[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}' \
      | sort -u >"${TMP_LIST}" || true
  fi
}

# --- Total occupant count via muc_size HTTP ---
occupants_of() {
  local room="$1" raw n
  raw="$(curl -sf --connect-timeout 2 --max-time 3 \
    "http://127.0.0.1:5280/room-size?room=${room}" 2>/dev/null)" || raw=""
  if [[ -z "${raw}" ]]; then
    raw="$(curl -sf --connect-timeout 2 --max-time 3 \
      -H "Host: ${DOMAIN}" \
      "http://127.0.0.1/room-size?room=${room}" 2>/dev/null)" || raw=""
  fi
  if [[ -z "${raw}" ]]; then
    echo ""
    return 0
  fi
  n="$(printf '%s' "${raw}" | jq -r '.participants // .occupants // .count // empty' 2>/dev/null)"
  echo "${n}"
}

# --- Human (non-hiddenDomain) occupants via Prosody room._occupants ---
# Prints: "HUMAN N" or "UNKNOWN" (listing failed) or "HUMAN 0"
human_occupants_of() {
  local room="$1" out humans
  out="$(printf '%s\n' \
"local host = prosody.hosts[\"${MUC}\"]
if not host then print(\"NOHOST\"); return; end
local muc = host.modules and host.modules.muc
if not muc or not muc.get_room_from_jid then print(\"NOMUC\"); return; end
local room = muc.get_room_from_jid(\"${room}@${MUC}\")
if not room then print(\"NOROOM\"); return; end
local n = 0
for _, occ in pairs(room._occupants or {}) do
  local jid = tostring(occ.bare_jid or occ.jid or \"\")
  if jid ~= \"\" and not jid:find(\"@${HIDDEN_DOMAIN}\", 1, true) then
    n = n + 1
  end
end
print(\"HUMAN \" .. tostring(n))
bye
" | timeout 8 prosodyctl shell 2>/dev/null)" || true

  humans="$(printf '%s\n' "${out}" | grep -oE 'HUMAN [0-9]+' | tail -1 | awk '{print $2}')"
  if [[ -n "${humans}" ]]; then
    echo "HUMAN ${humans}"
    return 0
  fi
  if echo "${out}" | grep -qE 'NOHOST|NOMUC|NOROOM'; then
    echo "UNKNOWN"
    return 0
  fi
  echo "UNKNOWN"
}

ssh_rec() {
  local ip="$1"
  shift
  local opts=(-o BatchMode=yes -o StrictHostKeyChecking=no \
    -o UserKnownHostsFile=/dev/null -o ConnectTimeout=5 -o LogLevel=ERROR)
  if [[ -f "${SSH_KEY}" ]]; then
    opts+=(-i "${SSH_KEY}")
  fi
  ssh "${opts[@]}" "${SSH_USER}@${ip}" "$@"
}

# Stop busy Jibri slot(s) whose metadata meeting_url contains the room UUID.
stop_jibri_for_room() {
  local room="$1"
  local ip i port found
  [[ -n "${room}" && -n "${RECORDER_PRIVATE_IPS}" ]] || return 0

  IFS=',' read -r -a REC_IPS <<< "${RECORDER_PRIVATE_IPS}"
  for ip in "${REC_IPS[@]}"; do
    ip="$(echo "${ip}" | xargs)"
    [[ -n "${ip}" ]] || continue
    if ! ssh_rec "${ip}" "true" >/dev/null 2>&1; then
      continue
    fi
    for i in $(seq 1 "${JIBRI_PER_VM}"); do
      port=$((2222 + i - 1))
      found="$(ssh_rec "${ip}" "bash -s" <<REMOTE 2>/dev/null || true
set +e
ROOM='${room}'
SLOT='${i}'
PORT='${port}'
# Match active metadata under this slot
matched=0
while IFS= read -r m; do
  [[ -n "\$m" ]] || continue
  if jq -e --arg r "\$ROOM" '((.meeting_url // .meetingUrl // "") | tostring | contains(\$r))' "\$m" >/dev/null 2>&1; then
    matched=1
    break
  fi
done < <(find "/srv/recordings/slot-\${SLOT}" -name metadata.json -mmin -720 2>/dev/null)
# Fallback: any recent metadata on host mentioning room + this slot busy
if [[ "\$matched" -eq 0 ]]; then
  busy="\$(curl -sf --max-time 3 "http://127.0.0.1:\${PORT}/jibri/api/v1.0/health" 2>/dev/null || true)"
  if echo "\$busy" | grep -qiE '"busy"[[:space:]]*:[[:space:]]*true|"busyStatus"[[:space:]]*:[[:space:]]*"BUSY"'; then
    while IFS= read -r m; do
      [[ -n "\$m" ]] || continue
      if jq -e --arg r "\$ROOM" '((.meeting_url // .meetingUrl // "") | tostring | contains(\$r))' "\$m" >/dev/null 2>&1; then
        matched=1
        break
      fi
    done < <(find /srv/recordings -name metadata.json -mmin -720 2>/dev/null | head -40)
  fi
fi
if [[ "\$matched" -eq 1 ]]; then
  curl -sf --max-time 5 -X POST "http://127.0.0.1:\${PORT}/jibri/api/v1.0/stopService" >/dev/null 2>&1 \
    && echo "STOPPED slot-\${SLOT}" || echo "STOP_FAIL slot-\${SLOT}"
fi
REMOTE
)"
      if [[ -n "${found}" ]]; then
        echo "[active-rooms] room=${room} recorder=${ip} ${found}" >&2
      fi
    done
  done
}

list_via_shell

SHELL_HINT="$(printf 'muc:list("%s")\nbye\n' "${MUC}" \
  | timeout 8 prosodyctl shell 2>&1 | head -c 400)" || true
if [[ ! -s "${TMP_LIST}" ]]; then
  if echo "${SHELL_HINT}" | grep -qiE 'error|not found|failed|No such|attempt to'; then
    if echo "${SHELL_HINT}" | grep -qiE 'fatal|inactive|Connection refused'; then
      json_fail "prosody shell failed"
      exit 0
    fi
  fi
fi

ROOMS_JSON='[]'
while IFS= read -r room; do
  [[ -z "${room}" ]] && continue
  occ="$(occupants_of "${room}")"
  human_line="$(human_occupants_of "${room}")"
  human=""
  if [[ "${human_line}" == HUMAN* ]]; then
    human="${human_line#HUMAN }"
  fi

  # Prefer human count when Prosody occupant listing works.
  if [[ -n "${human}" ]]; then
    if [[ "${human}" == "0" ]]; then
      # Empty or recorder-only → not active for portal; stop orphan Jibri if any.
      if [[ -n "${occ}" && "${occ}" != "0" ]]; then
        stop_jibri_for_room "${room}"
      fi
      continue
    fi
    ROOMS_JSON="$(jq -c --arg r "${room}" --argjson o "${human}" \
      '. + [{room:$r, occupants:$o}]' <<<"${ROOMS_JSON}")"
    continue
  fi

  # Fallback: raw muc_size (includes Jibri) when human listing unknown.
  if [[ -n "${occ}" ]]; then
    if [[ "${occ}" == "0" ]]; then
      continue
    fi
    ROOMS_JSON="$(jq -c --arg r "${room}" --argjson o "${occ}" \
      '. + [{room:$r, occupants:$o}]' <<<"${ROOMS_JSON}")"
  else
    ROOMS_JSON="$(jq -c --arg r "${room}" \
      '. + [{room:$r, occupants:null}]' <<<"${ROOMS_JSON}")"
  fi
done <"${TMP_LIST}"

if (( PRETTY )); then
  jq -n --arg d "${DOMAIN}" --argjson rooms "${ROOMS_JSON}" \
    '{ok:true,prosody_ok:true,domain:$d,count:( $rooms|length ),rooms:$rooms}'
else
  jq -nc --arg d "${DOMAIN}" --argjson rooms "${ROOMS_JSON}" \
    '{ok:true,prosody_ok:true,domain:$d,count:( $rooms|length ),rooms:$rooms}'
fi
exit 0

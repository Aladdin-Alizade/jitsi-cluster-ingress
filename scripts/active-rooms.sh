#!/usr/bin/env bash
# meet-control: Prosody MUC-də hazırda mövcud conference room-ları JSON çıxar.
# İstifadə: active-rooms.sh          → stdout JSON
#           active-rooms.sh --pretty
#
# Çıxış:
#   {"ok":true,"prosody_ok":true,"domain":"...","rooms":[{"room":"<uuid>","occupants":N},...]}
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
TMP_OUT="$(mktemp)"
cleanup() { rm -f "${TMP_LIST}" "${TMP_OUT}" 2>/dev/null || true; }
trap cleanup EXIT

# --- List live MUC rooms via prosodyctl shell (Prosody 0.11+/0.12) ---
list_via_shell() {
  local out=""
  # Newer: `prosodyctl shell` interactive; feed muc:list
  out="$(printf 'muc:list("%s")\nbye\n' "${MUC}" \
    | timeout 8 prosodyctl shell 2>/dev/null)" || true
  if [[ -z "${out}" ]]; then
    out="$(printf 'muc:list("%s")\nquit\n' "${MUC}" \
      | timeout 8 prosodyctl shell "${DOMAIN}" 2>/dev/null)" || true
  fi
  # Extract bare room names (uuid) from JIDs like uuid@conference.domain
  printf '%s\n' "${out}" \
    | grep -oE '[0-9a-fA-F-]{8,}@'"${MUC//./\\.}" \
    | sed "s/@${MUC}//" \
    | sort -u >"${TMP_LIST}" || true
  # Also accept plain uuid lines without JID
  if [[ ! -s "${TMP_LIST}" ]]; then
    printf '%s\n' "${out}" \
      | grep -oE '[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}' \
      | sort -u >"${TMP_LIST}" || true
  fi
}

# --- Occupant count via muc_size HTTP (localhost Prosody) ---
occupants_of() {
  local room="$1" raw n
  raw="$(curl -sf --connect-timeout 2 --max-time 3 \
    "http://127.0.0.1:5280/room-size?room=${room}" 2>/dev/null)" || raw=""
  if [[ -z "${raw}" ]]; then
    # nginx local (Host required)
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

list_via_shell

# If shell listing failed completely, still report prosody_ok=true with empty rooms
# only when shell produced *some* recognisable muc response; otherwise fail closed.
SHELL_HINT="$(printf 'muc:list("%s")\nbye\n' "${MUC}" \
  | timeout 8 prosodyctl shell 2>&1 | head -c 400)" || true
if [[ ! -s "${TMP_LIST}" ]]; then
  if echo "${SHELL_HINT}" | grep -qiE 'error|not found|failed|No such|attempt to'; then
    # Empty conference component with a clean list is fine; hard errors → down.
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
  if [[ -n "${occ}" ]]; then
    # 0 occupants → room already gone / empty; skip (not active)
    if [[ "${occ}" == "0" ]]; then
      continue
    fi
    ROOMS_JSON="$(jq -c --arg r "${room}" --argjson o "${occ}" \
      '. + [{room:$r, occupants:$o}]' <<<"${ROOMS_JSON}")"
  else
    # Listed by Prosody but muc_size unavailable — still treat as active
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

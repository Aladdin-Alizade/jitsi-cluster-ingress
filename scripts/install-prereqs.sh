#!/usr/bin/env bash
# Lokal maşın / Cloud Shell üçün deploy asılılıqlarını avtomatik quraşdırır.
# deploy.sh / destroy.sh tərəfindən çağırılır.

set -euo pipefail

_log()  { echo -e "\033[0;32m[+]\033[0m $*"; }
_warn() { echo -e "\033[1;33m[!]\033[0m $*"; }
_die()  { echo -e "\033[0;31m[x]\033[0m $*" >&2; exit 1; }

cmd_ok() {
  command -v "$1" >/dev/null 2>&1
}

# Cloud Shell bəzən "terraform" stub göstərir (install təlimatı) — real binary deyil
terraform_real() {
  local out
  out="$(command terraform version 2>/dev/null | head -1 || true)"
  [[ "${out}" =~ ^Terraform\ v[0-9] ]]
}

jq_works() {
  jq --version >/dev/null 2>&1
}

run_apt() {
  if cmd_ok sudo; then
    sudo apt-get update -qq
    sudo apt-get install -y -qq "$@"
  elif [[ "${EUID:-$(id -u)}" -eq 0 ]]; then
    apt-get update -qq
    apt-get install -y -qq "$@"
  else
    _die "apt üçün sudo lazımdır: $*"
  fi
}

install_jq() {
  _log "jq quraşdırılır..."
  if cmd_ok apt-get; then
    run_apt jq
  elif cmd_ok brew; then
    brew install jq
  else
    _die "jq tapılmadı və avtomatik quraşdırıla bilmədi"
  fi
}

# Real binary → ~/bin/terraform (Cloud Shell stub-unu keçmək üçün)
install_terraform_binary() {
  local ver="${TERRAFORM_VERSION:-1.9.8}"
  local arch os zip url dest_dir dest
  dest_dir="${HOME}/bin"
  dest="${dest_dir}/terraform"
  mkdir -p "${dest_dir}"

  case "$(uname -m)" in
    x86_64|amd64) arch="amd64" ;;
    aarch64|arm64) arch="arm64" ;;
    *) _die "Dəstəklənməyən arch: $(uname -m)" ;;
  esac
  case "$(uname -s)" in
    Linux) os="linux" ;;
    Darwin) os="darwin" ;;
    *) _die "Dəstəklənməyən OS: $(uname -s)" ;;
  esac

  zip="terraform_${ver}_${os}_${arch}.zip"
  url="https://releases.hashicorp.com/terraform/${ver}/${zip}"
  _log "Terraform ${ver} yüklənir → ${dest}"
  local tmp
  tmp="$(mktemp -d)"
  (
    cd "${tmp}"
    if cmd_ok curl; then
      curl -fsSL -o "${zip}" "${url}"
    else
      wget -q -O "${zip}" "${url}"
    fi
    if cmd_ok unzip; then
      unzip -o -q "${zip}" terraform
    else
      python3 - <<PY
import zipfile
z=zipfile.ZipFile("${zip}")
z.extract("terraform")
PY
    fi
    install -m 755 terraform "${dest}"
  )
  rm -rf "${tmp}"
  export PATH="${dest_dir}:${PATH}"
}

install_terraform_apt() {
  _log "Terraform quraşdırılır (apt)..."
  local codename
  codename="$(grep -oP '(?<=UBUNTU_CODENAME=).*' /etc/os-release 2>/dev/null || lsb_release -cs 2>/dev/null || echo jammy)"
  if cmd_ok sudo; then
    wget -qO- https://apt.releases.hashicorp.com/gpg \
      | sudo gpg --dearmor -o /usr/share/keyrings/hashicorp-archive-keyring.gpg
    echo "deb [arch=$(dpkg --print-architecture) signed-by=/usr/share/keyrings/hashicorp-archive-keyring.gpg] https://apt.releases.hashicorp.com ${codename} main" \
      | sudo tee /etc/apt/sources.list.d/hashicorp.list >/dev/null
    run_apt terraform
  elif [[ "${EUID:-$(id -u)}" -eq 0 ]]; then
    wget -qO- https://apt.releases.hashicorp.com/gpg \
      | gpg --dearmor -o /usr/share/keyrings/hashicorp-archive-keyring.gpg
    echo "deb [arch=$(dpkg --print-architecture) signed-by=/usr/share/keyrings/hashicorp-archive-keyring.gpg] https://apt.releases.hashicorp.com ${codename} main" \
      > /etc/apt/sources.list.d/hashicorp.list
    apt-get update -qq && apt-get install -y -qq terraform
  else
    return 1
  fi
}

install_terraform() {
  # 1) Əvvəl ~/bin (Cloud Shell stub-undan etibarlı)
  install_terraform_binary
  if terraform_real; then
    return 0
  fi

  # 2) brew / apt fallback
  if cmd_ok brew; then
    _log "Terraform quraşdırılır (brew)..."
    brew install terraform || true
  elif cmd_ok apt-get; then
    install_terraform_apt || true
  fi

  # PATH-də ~/bin öndə qalsın
  export PATH="${HOME}/bin:${PATH}"
}

persist_cloudshell_prereqs() {
  local marker='jitsi-cluster-prereqs'
  local file="${HOME}/.customize_environment"
  if [[ -n "${CLOUD_SHELL:-}" || -f "${HOME}/.cloudshell/boot-finished" ]]; then
    if [[ -f "${file}" ]] && grep -q "${marker}" "${file}" 2>/dev/null; then
      # Köhnə stub-only bloku yenilə
      if ! grep -q 'HOME/bin' "${file}" 2>/dev/null; then
        cat >> "${file}" <<'EOF'

# jitsi-cluster-prereqs-path
export PATH="$HOME/bin:$PATH"
EOF
      fi
      return 0
    fi
    _log "Cloud Shell: prereqs ~/.customize_environment-ə yazılır"
    cat >> "${file}" <<'EOF'

# jitsi-cluster-prereqs
export PATH="$HOME/bin:$PATH"
if ! command -v terraform >/dev/null 2>&1 || ! terraform version 2>/dev/null | head -1 | grep -q '^Terraform v'; then
  mkdir -p "$HOME/bin"
  # növbəti deploy.sh özü binary quraşdıracaq
  true
fi
EOF
  fi
}

ensure_deploy_prerequisites() {
  _log "Deploy asılılıqları yoxlanılır..."

  # Həmişə ~/bin öndə — Cloud Shell stub-unu keç
  export PATH="${HOME}/bin:${PATH}"

  if ! cmd_ok curl && ! cmd_ok wget; then
    if cmd_ok apt-get; then run_apt curl; else _die "curl və ya wget lazımdır"; fi
  fi

  if ! cmd_ok unzip && ! cmd_ok python3; then
    if cmd_ok apt-get; then run_apt unzip python3; fi
  fi

  if ! cmd_ok ssh || ! cmd_ok scp; then
    if cmd_ok apt-get; then
      run_apt openssh-client
    elif cmd_ok brew; then
      brew install openssh || true
    else
      _die "ssh/scp lazımdır"
    fi
  fi

  if ! jq_works; then
    install_jq
  fi
  if ! jq_works; then
    _die "jq quraşdırıla bilmədi"
  fi

  if ! terraform_real; then
    _warn "Real Terraform tapılmadı (Cloud Shell stub ola bilər) — binary quraşdırılır"
    install_terraform
  fi

  if ! terraform_real; then
    _die "Terraform quraşdırıla bilmədi. Əl ilə: curl -fsSL https://releases.hashicorp.com/terraform/1.9.8/terraform_1.9.8_linux_amd64.zip -o /tmp/tf.zip && unzip -o /tmp/tf.zip -d \$HOME/bin && export PATH=\$HOME/bin:\$PATH"
  fi

  if ! cmd_ok gcloud; then
    _die "gcloud tapılmadı. Cloud Shell istifadə edin və ya: https://cloud.google.com/sdk/docs/install"
  fi

  persist_cloudshell_prereqs
  local tf_ver
  tf_ver="$(terraform version 2>/dev/null | head -1 || true)"
  _log "Asılılıqlar hazırdır: terraform=${tf_ver} jq=$(jq --version)"
}

# Birbaşa çağırılsa
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
  ensure_deploy_prerequisites
fi

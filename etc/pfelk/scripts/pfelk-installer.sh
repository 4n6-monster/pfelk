#!/usr/bin/env bash
# Version    | 26.10.0
# Repository | https://github.com/4n6-monster/pfelk
#
# pfELK native installer for Debian/Ubuntu + Elastic Stack 9.x
#
# Goals:
#   * reproducible, fail-fast installation
#   * official signed Elastic APT repository (no apt-key)
#   * dedicated pfelk_writer identity (no elastic superuser in Logstash)
#   * Logstash keystore for the writer password
#   * parser/config validation before service restart
#   * optional local MaxMind databases
#   * idempotent reruns where practical
#
# Usage:
#   sudo ./pfelk-installer.sh
#   sudo ./pfelk-installer.sh --non-interactive
#   sudo ./pfelk-installer.sh --stack-version 9.5.4 --timezone America/Chicago
#   sudo ./pfelk-installer.sh --repo 4n6-monster/pfelk --ref main
#
set -Eeuo pipefail
IFS=$'\n\t'
umask 027

SCRIPT_VERSION="26.10.0"
DEFAULT_STACK_VERSION="9.5.4"
DEFAULT_REPO="4n6-monster/pfelk"
DEFAULT_REF="main"
DEFAULT_NAMESPACE="default"
DEFAULT_TIMEZONE="UTC"

STACK_VERSION="${PFELK_STACK_VERSION:-$DEFAULT_STACK_VERSION}"
PFELK_REPO="${PFELK_REPO:-$DEFAULT_REPO}"
PFELK_REF="${PFELK_REF:-$DEFAULT_REF}"
PFELK_NAMESPACE="${PFELK_NAMESPACE:-$DEFAULT_NAMESPACE}"
PFELK_TIMEZONE="${PFELK_TIMEZONE:-$DEFAULT_TIMEZONE}"
NON_INTERACTIVE="${PFELK_NON_INTERACTIVE:-false}"
INSTALL_MAXMIND="${PFELK_INSTALL_MAXMIND:-false}"
INSTALL_ENRICHMENTS="${PFELK_INSTALL_ENRICHMENTS:-false}"
SKIP_KIBANA="${PFELK_SKIP_KIBANA:-false}"

PFELK_HOME="/etc/pfelk"
LOG_DIR="/var/log/pfelk"
STATE_DIR="/var/lib/pfelk"
SECRET_DIR="${PFELK_HOME}/secrets"
ELASTIC_KEYRING="/usr/share/keyrings/elasticsearch-keyring.gpg"
ELASTIC_SOURCE="/etc/apt/sources.list.d/elastic-9.x.list"
RAW_BASE=""
INSTALL_LOG=""
INSTALL_MARKER="${STATE_DIR}/installed-by-pfelk"

RED=$'\033[1;31m'
GREEN=$'\033[1;32m'
YELLOW=$'\033[1;33m'
BLUE=$'\033[1;34m'
RESET=$'\033[0m'

usage() {
  cat <<EOF
pfELK installer ${SCRIPT_VERSION}

Options:
  --stack-version VERSION   Elastic Stack version (default: ${DEFAULT_STACK_VERSION})
  --repo OWNER/REPO        Repository to install from (default: ${DEFAULT_REPO})
  --ref REF                Git ref/tag/commit (default: ${DEFAULT_REF})
  --namespace NAME         data_stream.namespace (default: ${DEFAULT_NAMESPACE})
  --timezone TZ            Firewall timezone for RFC3164 logs (default: ${DEFAULT_TIMEZONE})
  --maxmind                Configure local MaxMind GeoLite2 databases
  --enrichments            Install optional interface/rule/port/URL/UA/private enrichments
  --skip-kibana            Install Elasticsearch/Logstash only
  --non-interactive        Do not prompt; use defaults
  -h, --help               Show this help

Environment equivalents:
  PFELK_STACK_VERSION, PFELK_REPO, PFELK_REF, PFELK_NAMESPACE,
  PFELK_TIMEZONE, PFELK_INSTALL_MAXMIND, PFELK_INSTALL_ENRICHMENTS,
  PFELK_SKIP_KIBANA, PFELK_NON_INTERACTIVE
EOF
}

log()  { printf '%s\n' "${BLUE}[pfELK]${RESET} $*"; }
ok()   { printf '%s\n' "${GREEN}[ OK ]${RESET} $*"; }
warn() { printf '%s\n' "${YELLOW}[WARN]${RESET} $*" >&2; }
die()  { printf '%s\n' "${RED}[FAIL]${RESET} $*" >&2; exit 1; }

on_error() {
  local exit_code=$?
  local line="${BASH_LINENO[0]:-unknown}"
  printf '%s\n' "${RED}[FAIL]${RESET} installer failed at line ${line} (exit ${exit_code})." >&2
  if [[ -n "${INSTALL_LOG}" && -f "${INSTALL_LOG}" ]]; then
    printf 'Install log: %s\n' "${INSTALL_LOG}" >&2
  fi
  exit "${exit_code}"
}
trap on_error ERR

while (($#)); do
  case "$1" in
    --stack-version) STACK_VERSION="${2:?missing version}"; shift 2 ;;
    --repo) PFELK_REPO="${2:?missing owner/repo}"; shift 2 ;;
    --ref) PFELK_REF="${2:?missing ref}"; shift 2 ;;
    --namespace) PFELK_NAMESPACE="${2:?missing namespace}"; shift 2 ;;
    --timezone) PFELK_TIMEZONE="${2:?missing timezone}"; shift 2 ;;
    --maxmind) INSTALL_MAXMIND=true; shift ;;
    --enrichments) INSTALL_ENRICHMENTS=true; shift ;;
    --skip-kibana) SKIP_KIBANA=true; shift ;;
    --non-interactive) NON_INTERACTIVE=true; shift ;;
    -h|--help) usage; exit 0 ;;
    *) die "Unknown option: $1" ;;
  esac
done

[[ "${EUID}" -eq 0 ]] || die "Run this installer as root (sudo)."
command -v systemctl >/dev/null || die "systemd is required."

mkdir -p "${LOG_DIR}" "${STATE_DIR}" "${SECRET_DIR}"
chmod 0750 "${LOG_DIR}" "${STATE_DIR}" "${SECRET_DIR}"
INSTALL_LOG="${LOG_DIR}/install-$(date +%Y%m%d-%H%M%S).log"
touch "${INSTALL_LOG}"
chmod 0640 "${INSTALL_LOG}"
exec > >(tee -a "${INSTALL_LOG}") 2>&1

RAW_BASE="https://raw.githubusercontent.com/${PFELK_REPO}/${PFELK_REF}"

source_os_release() {
  [[ -r /etc/os-release ]] || die "/etc/os-release not found."
  # shellcheck disable=SC1091
  source /etc/os-release
  OS_ID="${ID:-unknown}"
  OS_VERSION="${VERSION_ID:-unknown}"

  case "${OS_ID}" in
    ubuntu)
      case "${OS_VERSION}" in
        22.04|24.04|26.04) ;;
        *) warn "Ubuntu ${OS_VERSION} is not in the tested matrix (22.04/24.04/26.04)." ;;
      esac
      ;;
    debian)
      case "${OS_VERSION%%.*}" in
        12|13) ;;
        *) warn "Debian ${OS_VERSION} is not in the tested matrix (12/13)." ;;
      esac
      ;;
    *)
      die "Unsupported distribution: ${OS_ID} ${OS_VERSION}. Use Debian or Ubuntu."
      ;;
  esac
}


prepare_install_state() {
  if [[ -e /var/lib/elasticsearch/nodes && ! -f "${INSTALL_MARKER}" ]]; then
    die "Existing Elasticsearch data detected that was not installed by this pfELK installer. Refusing to modify or reset its security state."
  fi

  if [[ ! -f "${INSTALL_MARKER}" ]]; then
    printf '%s\n' "pfELK installer ${SCRIPT_VERSION} in-progress" > "${INSTALL_MARKER}"
    chmod 0640 "${INSTALL_MARKER}"
  fi
}

check_resources() {
  local mem_gb disk_gb
  mem_gb="$(awk '/MemTotal/ {printf "%.0f", $2/1024/1024}' /proc/meminfo)"
  disk_gb="$(df -BG --output=avail /var | tail -1 | tr -dc '0-9')"

  if (( mem_gb < 8 )); then
    warn "Only ${mem_gb} GiB RAM detected. 8 GiB is the practical minimum; 16+ GiB is recommended."
  else
    ok "Memory check: ${mem_gb} GiB."
  fi

  if (( disk_gb < 20 )); then
    warn "Only ${disk_gb} GiB free under /var. Elasticsearch data can grow quickly."
  else
    ok "Disk check: ${disk_gb} GiB free under /var."
  fi

  if swapon --noheadings --show | grep -q .; then
    warn "Swap is enabled. The installer will not modify /etc/fstab automatically."
    warn "For dedicated Elastic hosts, review Elastic memory/swap guidance and disable or tune swap deliberately."
  fi
}

apt_install() {
  DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends "$@"
}

install_prerequisites() {
  log "Installing prerequisites..."
  apt-get update
  apt_install ca-certificates curl gnupg jq openssl apt-transport-https
}

configure_elastic_repository() {
  log "Configuring the signed Elastic 9.x APT repository..."
  install -d -m 0755 /usr/share/keyrings

  local tmp
  tmp="$(mktemp)"
  curl -fsSL --retry 4 --retry-delay 2 \
    https://artifacts.elastic.co/GPG-KEY-elasticsearch -o "${tmp}"
  gpg --dearmor --yes -o "${ELASTIC_KEYRING}" "${tmp}"
  rm -f "${tmp}"
  chmod 0644 "${ELASTIC_KEYRING}"

  printf '%s\n' \
    "deb [signed-by=${ELASTIC_KEYRING}] https://artifacts.elastic.co/packages/9.x/apt stable main" \
    > "${ELASTIC_SOURCE}"

  apt-get update
}

package_spec() {
  local pkg="$1" desired="$2" candidate
  candidate="$(
    apt-cache madison "${pkg}" 2>/dev/null |
      awk '{print $3}' |
      grep -E "(^|:)${desired}([+-]|$)" |
      head -n1 || true
  )"
  if [[ -n "${candidate}" ]]; then
    printf '%s=%s' "${pkg}" "${candidate}"
  else
    warn "${pkg} ${desired} was not found exactly in APT metadata; installing the current 9.x repository version."
    printf '%s' "${pkg}"
  fi
}

install_stack() {
  local es_pkg ls_pkg kb_pkg
  es_pkg="$(package_spec elasticsearch "${STACK_VERSION}")"
  ls_pkg="$(package_spec logstash "${STACK_VERSION}")"

  log "Installing Elasticsearch and Logstash (target ${STACK_VERSION})..."
  if [[ "${SKIP_KIBANA}" == "true" ]]; then
    DEBIAN_FRONTEND=noninteractive apt-get install -y "${es_pkg}" "${ls_pkg}"
  else
    kb_pkg="$(package_spec kibana "${STACK_VERSION}")"
    DEBIAN_FRONTEND=noninteractive apt-get install -y "${es_pkg}" "${ls_pkg}" "${kb_pkg}"
  fi
}

install_repo_file() {
  local relative="$1" destination="$2" mode="${3:-0644}"
  local tmp
  tmp="$(mktemp)"
  curl -fsSL --retry 4 --retry-delay 2 "${RAW_BASE}/${relative}" -o "${tmp}"
  install -D -m "${mode}" "${tmp}" "${destination}"
  rm -f "${tmp}"
}

install_pfelk_files() {
  log "Installing pfELK configuration from ${PFELK_REPO}@${PFELK_REF}..."

  install -d -m 0755 \
    "${PFELK_HOME}/conf.d" \
    "${PFELK_HOME}/config" \
    "${PFELK_HOME}/patterns" \
    "${PFELK_HOME}/scripts" \
    "${PFELK_HOME}/databases" \
    "${PFELK_HOME}/logs"

  local f
  for f in \
    01-inputs.pfelk \
    02-firewall.pfelk \
    05-apps.pfelk \
    30-geoip.pfelk \
    49-cleanup.pfelk \
    50-outputs.pfelk
  do
    install_repo_file "etc/pfelk/conf.d/${f}" "${PFELK_HOME}/conf.d/${f}"
  done

  install_repo_file "etc/pfelk/patterns/pfelk.grok" "${PFELK_HOME}/patterns/pfelk.grok"
  install_repo_file "etc/pfelk/patterns/openvpn.grok" "${PFELK_HOME}/patterns/openvpn.grok"
  install_repo_file "etc/pfelk/config/pipelines.yml" "/etc/logstash/pipelines.yml"
  install_repo_file "etc/pfelk/config/logstash.yml" "/etc/logstash/logstash.yml"
  install_repo_file "etc/pfelk/scripts/error-data.sh" "${PFELK_HOME}/scripts/error-data.sh" 0755
  install_repo_file "etc/pfelk/scripts/pfelk-validate.sh" "${PFELK_HOME}/scripts/pfelk-validate.sh" 0755

  if [[ "${INSTALL_ENRICHMENTS}" == "true" ]]; then
    log "Installing optional pfELK enrichment pipeline files and dictionaries..."
    for f in       20-interfaces.pfelk       35-rules-desc.pfelk       36-ports-desc.pfelk       37-enhanced_user_agent.pfelk       38-enhanced_url.pfelk       45-enhanced_private.pfelk
    do
      install_repo_file "etc/pfelk/conf.d/${f}" "${PFELK_HOME}/conf.d/${f}"
    done

    for f in private-hostnames.csv rule-names.csv service-names-port-numbers.csv; do
      install_repo_file "etc/pfelk/databases/${f}" "${PFELK_HOME}/databases/${f}"
    done
  fi

  chown -R root:logstash "${PFELK_HOME}"
  find "${PFELK_HOME}" -type d -exec chmod 0750 {} +
  find "${PFELK_HOME}/conf.d" "${PFELK_HOME}/config" "${PFELK_HOME}/patterns" \
    -type f -exec chmod 0640 {} +
  chmod 0750 "${PFELK_HOME}/scripts/"*.sh
}

ensure_managed_block() {
  local file="$1" begin="$2" end="$3" content="$4"
  touch "${file}"
  awk -v b="${begin}" -v e="${end}" '
    $0 == b {skip=1; next}
    $0 == e {skip=0; next}
    !skip {print}
  ' "${file}" > "${file}.pfelk.tmp"
  mv "${file}.pfelk.tmp" "${file}"
  {
    printf '\n%s\n' "${begin}"
    printf '%s\n' "${content}"
    printf '%s\n' "${end}"
  } >> "${file}"
}

configure_host() {
  log "Applying host settings..."
  cat > /etc/sysctl.d/99-pfelk.conf <<'EOF'
# Managed by pfELK
vm.max_map_count=262144
EOF
  sysctl --system >/dev/null
}

configure_elasticsearch_after_autoconfig() {
  # Security auto-configuration must run on Elasticsearch's first start before
  # we add discovery/network settings. Adding them before first start can cause
  # Elastic to treat security as manually configured and skip auto-configuration.
  ensure_managed_block \
    /etc/elasticsearch/elasticsearch.yml \
    "# BEGIN PFELK MANAGED" \
    "# END PFELK MANAGED" \
"cluster.name: pfelk
network.host: 127.0.0.1
http.port: 9200
discovery.type: single-node"

  systemctl restart elasticsearch
  wait_for_es
  detect_es_url
}

configure_kibana_server() {
  [[ "${SKIP_KIBANA}" == "true" ]] && return 0
  ensure_managed_block \
    /etc/kibana/kibana.yml \
    "# BEGIN PFELK MANAGED" \
    "# END PFELK MANAGED" \
"server.host: \"0.0.0.0\"
server.port: 5601"
}

wait_for_es() {
  local attempts=0
  until curl -sk --max-time 2 https://127.0.0.1:9200 >/dev/null 2>&1 ||
        curl -s  --max-time 2 http://127.0.0.1:9200 >/dev/null 2>&1; do
    attempts=$((attempts + 1))
    (( attempts < 90 )) || die "Elasticsearch did not become reachable within 180 seconds."
    sleep 2
  done
}


load_existing_state() {
  local credentials="${SECRET_DIR}/credentials.txt"

  if [[ -f "${INSTALL_MARKER}" && -r "${credentials}" ]]; then
    ELASTIC_PASSWORD="$(
      awk -F': ' '/^elastic password:/ {print $2; exit}' "${credentials}" || true
    )"
    PFELK_WRITER_PASSWORD="$(
      awk -F': ' '/^Logstash writer password:/ {print $2; exit}' "${credentials}" || true
    )"
    if [[ -n "${ELASTIC_PASSWORD}" ]]; then
      ok "Loaded existing pfELK-managed Elasticsearch credentials for idempotent rerun."
    fi
  fi
}

reset_elastic_password() {
  local output password
  output="$(/usr/share/elasticsearch/bin/elasticsearch-reset-password -u elastic -a -b 2>&1)"
  password="$(printf '%s\n' "${output}" | awk -F': ' '/New value:/ {print $2}' | tail -1)"
  [[ -n "${password}" ]] || {
    printf '%s\n' "${output}" >&2
    die "Unable to parse generated elastic password."
  }
  printf '%s' "${password}"
}

detect_es_url() {
  if [[ -f /etc/elasticsearch/certs/http_ca.crt ]] &&
     curl -s --cacert /etc/elasticsearch/certs/http_ca.crt --max-time 3 \
       https://127.0.0.1:9200 >/dev/null 2>&1; then
    ES_URL="https://127.0.0.1:9200"
    ES_CA_ARGS=(--cacert /etc/elasticsearch/certs/http_ca.crt)
  elif curl -sk --max-time 3 https://127.0.0.1:9200 >/dev/null 2>&1; then
    ES_URL="https://127.0.0.1:9200"
    ES_CA_ARGS=(-k)
  else
    ES_URL="http://127.0.0.1:9200"
    ES_CA_ARGS=()
    warn "Elasticsearch HTTP TLS was not detected. Review your security configuration."
  fi
}

es_api() {
  local method="$1" path="$2" data="${3:-}"
  local args=(-sS -u "elastic:${ELASTIC_PASSWORD}" -X "${method}")
  args+=("${ES_CA_ARGS[@]}")
  if [[ -n "${data}" ]]; then
    args+=(-H "Content-Type: application/json" -d "${data}")
  fi
  curl "${args[@]}" "${ES_URL}${path}"
}

create_writer_identity() {
  if [[ -z "${PFELK_WRITER_PASSWORD:-}" ]]; then
    PFELK_WRITER_PASSWORD="$(openssl rand -base64 36 | tr -d '\n' | tr '/+' '_-')"
  fi

  log "Creating/updating dedicated pfelk_writer role and user..."
  es_api PUT "/_security/role/pfelk_writer" '{
    "cluster": ["monitor", "manage_index_templates", "manage_ilm", "read_ilm"],
    "indices": [{
      "names": ["logs-pfelk.*-*"],
      "privileges": ["auto_configure", "create_doc", "write", "create", "create_index", "manage", "manage_ilm", "view_index_metadata"]
    }]
  }' >/dev/null

  es_api POST "/_security/user/pfelk_writer" "$(jq -n \
    --arg p "${PFELK_WRITER_PASSWORD}" \
    '{password:$p,roles:["pfelk_writer"],full_name:"pfELK Logstash Writer"}')" >/dev/null
}

configure_logstash_security() {
  log "Configuring Logstash CA, environment, and keystore..."
  install -d -o logstash -g logstash -m 0750 /etc/logstash/config/certs

  if [[ -f /etc/elasticsearch/certs/http_ca.crt ]]; then
    install -o logstash -g logstash -m 0640 \
      /etc/elasticsearch/certs/http_ca.crt \
      /etc/logstash/config/certs/http_ca.crt
    PFELK_ES_HOSTS="https://localhost:9200"
  else
    warn "Elasticsearch CA was not found; configuring Logstash for HTTP localhost."
    PFELK_ES_HOSTS="http://localhost:9200"
  fi

  install -d -m 0755 /etc/systemd/system/logstash.service.d
  cat > /etc/systemd/system/logstash.service.d/pfelk.conf <<EOF
[Service]
Environment="PFELK_ES_HOSTS=${PFELK_ES_HOSTS}"
Environment="PFELK_ES_USER=pfelk_writer"
Environment="PFELK_CA_PATH=/etc/logstash/config/certs/http_ca.crt"
Environment="PFELK_NAMESPACE=${PFELK_NAMESPACE}"
Environment="PFELK_TIMEZONE=${PFELK_TIMEZONE}"
EOF

  local keystore="/etc/logstash/logstash.keystore"
  if [[ ! -f "${keystore}" ]]; then
    /usr/share/logstash/bin/logstash-keystore --path.settings /etc/logstash create --force >/dev/null
  fi
  printf '%s' "${PFELK_WRITER_PASSWORD}" |
    /usr/share/logstash/bin/logstash-keystore --path.settings /etc/logstash \
      add PFELK_ES_PASSWORD --stdin --force >/dev/null
  chown logstash:logstash "${keystore}"
  chmod 0600 "${keystore}"

  systemctl daemon-reload
}


configure_kibana_enrollment() {
  [[ "${SKIP_KIBANA}" == "true" ]] && return 0

  if [[ ! -x /usr/share/kibana/bin/kibana-setup ]]; then
    warn "kibana-setup was not found; Kibana enrollment must be completed manually."
    return 0
  fi

  local token
  token="$(/usr/share/elasticsearch/bin/elasticsearch-create-enrollment-token -s kibana 2>/dev/null || true)"
  if [[ -z "${token}" ]]; then
    warn "Could not generate a Kibana enrollment token; manual enrollment will be required."
    return 0
  fi

  log "Enrolling Kibana with Elasticsearch..."
  if /usr/share/kibana/bin/kibana-setup --enrollment-token "${token}" >/dev/null 2>&1; then
    ok "Kibana enrollment completed."
    KIBANA_ENROLLED=true
  else
    warn "Automatic Kibana enrollment failed; manual enrollment will be required."
    KIBANA_ENROLLED=false
  fi
}

save_credentials() {
  local credentials="${SECRET_DIR}/credentials.txt"
  cat > "${credentials}" <<EOF
# Generated by pfELK installer ${SCRIPT_VERSION}
# Keep this file root-only. Delete it after storing the credentials securely.

Elasticsearch URL: ${ES_URL}
elastic user: elastic
elastic password: ${ELASTIC_PASSWORD}

Logstash writer user: pfelk_writer
Logstash writer password: ${PFELK_WRITER_PASSWORD}

Kibana URL: http://$(hostname -I | awk '{print $1}'):5601
EOF
  chmod 0600 "${credentials}"
  printf '%s\n' "pfELK installer ${SCRIPT_VERSION}" > "${INSTALL_MARKER}"
  chmod 0640 "${INSTALL_MARKER}"
  ok "Generated credentials saved to ${credentials} (mode 0600)."
}

configure_maxmind() {
  [[ "${INSTALL_MAXMIND}" == "true" ]] || return 0

  log "Configuring optional local MaxMind GeoLite2 databases..."
  if ! apt-cache show geoipupdate >/dev/null 2>&1; then
    warn "geoipupdate is not available in the configured APT repositories; using Elastic-managed GeoIP."
    return 0
  fi
  apt_install geoipupdate

  local account_id license_key
  if [[ "${NON_INTERACTIVE}" == "true" ]]; then
    account_id="${MAXMIND_ACCOUNT_ID:-}"
    license_key="${MAXMIND_LICENSE_KEY:-}"
  else
    read -r -p "MaxMind Account ID: " account_id
    read -r -s -p "MaxMind License Key: " license_key
    printf '\n'
  fi

  if [[ -z "${account_id}" || -z "${license_key}" ]]; then
    warn "MaxMind credentials not supplied; using Elastic-managed GeoIP."
    return 0
  fi

  cat > /etc/GeoIP.conf <<EOF
AccountID ${account_id}
LicenseKey ${license_key}
EditionIDs GeoLite2-Country GeoLite2-City GeoLite2-ASN
DatabaseDirectory /var/lib/GeoIP
EOF
  chmod 0600 /etc/GeoIP.conf
  install -d -m 0755 /var/lib/GeoIP
  geoipupdate

  # Enable local DB paths in pfELK's GeoIP pipeline.
  sed -i 's/^#MMR#//' "${PFELK_HOME}/conf.d/30-geoip.pfelk"

  cat > /etc/systemd/system/pfelk-geoipupdate.service <<'EOF'
[Unit]
Description=Update pfELK MaxMind GeoLite2 databases
After=network-online.target

[Service]
Type=oneshot
ExecStart=/usr/bin/geoipupdate
EOF

  cat > /etc/systemd/system/pfelk-geoipupdate.timer <<'EOF'
[Unit]
Description=Weekly pfELK MaxMind GeoLite2 update

[Timer]
OnCalendar=Sun *-*-* 17:00:00
Persistent=true
RandomizedDelaySec=30m

[Install]
WantedBy=timers.target
EOF
  systemctl daemon-reload
  systemctl enable --now pfelk-geoipupdate.timer
  ok "MaxMind GeoLite2 configured with a weekly systemd timer."
}

validate_pipeline() {
  log "Validating Logstash configuration..."
  if ! /usr/share/logstash/bin/logstash \
      --path.settings /etc/logstash \
      --config.test_and_exit; then
    die "Logstash configuration validation failed. Services were not restarted."
  fi
  ok "Logstash configuration validation passed."
}

start_services() {
  systemctl enable elasticsearch logstash >/dev/null
  if [[ "${SKIP_KIBANA}" != "true" ]]; then
    systemctl enable kibana >/dev/null
  fi

  systemctl restart logstash
  if [[ "${SKIP_KIBANA}" != "true" ]]; then
    systemctl restart kibana
  fi

  systemctl is-active --quiet elasticsearch || die "Elasticsearch is not active."
  systemctl is-active --quiet logstash || die "Logstash is not active."
  if [[ "${SKIP_KIBANA}" != "true" ]]; then
    systemctl is-active --quiet kibana || warn "Kibana is not active yet; inspect journalctl -u kibana."
  fi
}

print_kibana_enrollment() {
  [[ "${SKIP_KIBANA}" == "true" ]] && return 0
  local token
  token="$(/usr/share/elasticsearch/bin/elasticsearch-create-enrollment-token -s kibana 2>/dev/null || true)"
  if [[ -n "${token}" ]]; then
    printf '\n%s\n' "Kibana enrollment token (save securely):"
    printf '%s\n\n' "${token}"
  else
    warn "Could not generate a Kibana enrollment token automatically."
  fi
}

main() {
  printf '\n%s\n' "pfELK installer ${SCRIPT_VERSION}"
  printf '%s\n' "Repository: ${PFELK_REPO}@${PFELK_REF}"
  printf '%s\n\n' "Elastic target: ${STACK_VERSION}"

  source_os_release
  prepare_install_state
  check_resources
  install_prerequisites
  configure_elastic_repository
  install_stack
  install_pfelk_files
  configure_host
  load_existing_state

  systemctl daemon-reload
  systemctl enable --now elasticsearch
  wait_for_es
  detect_es_url

  if [[ -z "${ELASTIC_PASSWORD:-}" ]]; then
    ELASTIC_PASSWORD="$(reset_elastic_password)"
  fi

  create_writer_identity

  # Apply loopback/single-node settings only after Elastic has had the chance to
  # perform its first-start security auto-configuration.
  configure_elasticsearch_after_autoconfig
  configure_kibana_server
  configure_logstash_security
  configure_kibana_enrollment
  configure_maxmind
  save_credentials
  validate_pipeline
  start_services
  print_kibana_enrollment

  printf '\n%s\n' "${GREEN}pfELK installation completed.${RESET}"
  printf 'Validation: %s\n' "${PFELK_HOME}/scripts/pfelk-validate.sh"
  printf 'Credentials: %s\n' "${SECRET_DIR}/credentials.txt"
  printf 'Install log: %s\n' "${INSTALL_LOG}"
  printf '\nReview firewall forwarding to UDP/TCP 5140 and then open Kibana on port 5601.\n'
}

main "$@"

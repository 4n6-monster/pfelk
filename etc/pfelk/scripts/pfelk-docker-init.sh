#!/usr/bin/env bash
# Version | 26.10.1
set -Eeuo pipefail
umask 077

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
ENV_FILE="${ROOT}/.env"
EXAMPLE="${ROOT}/.env.example"

command -v openssl >/dev/null 2>&1 || {
  echo "openssl is required to generate deployment secrets." >&2
  exit 1
}

[[ -f "${EXAMPLE}" ]] || {
  echo "Missing ${EXAMPLE}" >&2
  exit 1
}

if [[ -e "${ENV_FILE}" ]]; then
  echo "${ENV_FILE} already exists; refusing to overwrite it." >&2
  echo "Move/remove the existing file only after preserving any values you need." >&2
  exit 1
fi

cp "${EXAMPLE}" "${ENV_FILE}"

random_secret() {
  openssl rand -base64 48 | tr -d '\n' | tr '/+' '_-'
}

escape_sed() {
  printf '%s' "$1" | sed 's/[&/\]/\\&/g'
}

ELASTIC_PASSWORD="$(random_secret)"
KIBANA_PASSWORD="$(random_secret)"
PFELK_ES_PASSWORD="$(random_secret)"

sed -i \
  -e "s/^ELASTIC_PASSWORD=.*/ELASTIC_PASSWORD=$(escape_sed "${ELASTIC_PASSWORD}")/" \
  -e "s/^KIBANA_PASSWORD=.*/KIBANA_PASSWORD=$(escape_sed "${KIBANA_PASSWORD}")/" \
  -e "s/^PFELK_ES_PASSWORD=.*/PFELK_ES_PASSWORD=$(escape_sed "${PFELK_ES_PASSWORD}")/" \
  "${ENV_FILE}"

chmod 0600 "${ENV_FILE}"

cat <<EOF2
Created ${ENV_FILE} with unique random credentials (mode 0600).

Before deployment review at least:
  PFELK_TIMEZONE
  PFELK_RETENTION / PFELK_ERROR_RETENTION
  PFELK_REPLICAS
  KIBANA_SERVER_NAME
  KIBANA_BIND
  SYSLOG_BIND
  memory/JVM limits

Docker Kibana uses HTTPS. Ensure KIBANA_SERVER_NAME resolves to this Docker host
(or change it before the first certificate-generation run).

Then run:
  docker compose config --quiet
  docker compose up -d
EOF2

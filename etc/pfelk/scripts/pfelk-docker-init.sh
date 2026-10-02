#!/usr/bin/env bash
# Version | 26.10.0
set -Eeuo pipefail
umask 077

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
ENV_FILE="${ROOT}/.env"
EXAMPLE="${ROOT}/.env.example"

[[ -f "${EXAMPLE}" ]] || { echo "Missing ${EXAMPLE}" >&2; exit 1; }
if [[ -e "${ENV_FILE}" ]]; then
  echo "${ENV_FILE} already exists; refusing to overwrite." >&2
  exit 1
fi

cp "${EXAMPLE}" "${ENV_FILE}"

random_secret() {
  openssl rand -base64 36 | tr -d '\n' | tr '/+' '_-'
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
echo "Created ${ENV_FILE} with strong random credentials (mode 0600)."
echo "Review PFELK_TIMEZONE, bind addresses, and memory limits before docker compose up -d."

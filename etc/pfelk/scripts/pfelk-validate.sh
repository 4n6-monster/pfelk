#!/usr/bin/env bash
# Version | 26.10.1
set -Eeuo pipefail

PFELK_HOME="${PFELK_HOME:-/etc/pfelk}"
LOGSTASH_SETTINGS="${LOGSTASH_SETTINGS:-/etc/logstash}"

GREEN=$'\033[1;32m'
YELLOW=$'\033[1;33m'
RED=$'\033[1;31m'
RESET=$'\033[0m'

pass() { printf '%s\n' "${GREEN}[PASS]${RESET} $*"; }
warn() { printf '%s\n' "${YELLOW}[WARN]${RESET} $*"; }
fail() { printf '%s\n' "${RED}[FAIL]${RESET} $*"; FAILURES=$((FAILURES+1)); }

FAILURES=0

required=(
  "${PFELK_HOME}/conf.d/01-inputs.pfelk"
  "${PFELK_HOME}/conf.d/02-firewall.pfelk"
  "${PFELK_HOME}/conf.d/05-apps.pfelk"
  "${PFELK_HOME}/conf.d/30-geoip.pfelk"
  "${PFELK_HOME}/conf.d/48-related.pfelk"
  "${PFELK_HOME}/conf.d/49-cleanup.pfelk"
  "${PFELK_HOME}/conf.d/50-outputs.pfelk"
  "${PFELK_HOME}/patterns/pfelk.grok"
  "${PFELK_HOME}/patterns/openvpn.grok"
  "${PFELK_HOME}/templates/pfelk-mappings.component-template.json"
  "${PFELK_HOME}/templates/pfelk-logs.index-template.json"
  "${PFELK_HOME}/templates/pfelk-pipeline-error.index-template.json"
  "${LOGSTASH_SETTINGS}/pipelines.yml"
  "${LOGSTASH_SETTINGS}/logstash.yml"
)

for f in "${required[@]}"; do
  [[ -r "$f" ]] && pass "Readable: $f" || fail "Missing/unreadable: $f"
done

if [[ -x /usr/share/logstash/bin/logstash ]]; then
  if /usr/share/logstash/bin/logstash \
      --path.settings "${LOGSTASH_SETTINGS}" \
      --config.test_and_exit >/tmp/pfelk-logstash-test.out 2>&1; then
    pass "Logstash --config.test_and_exit"
  else
    fail "Logstash config test"
    tail -50 /tmp/pfelk-logstash-test.out || true
  fi
else
  warn "Logstash binary not installed; runtime config test skipped."
fi

for svc in elasticsearch logstash kibana; do
  if systemctl list-unit-files "${svc}.service" >/dev/null 2>&1; then
    if systemctl is-active --quiet "${svc}"; then
      pass "Service active: ${svc}"
    else
      fail "Service inactive: ${svc}"
    fi
  fi
done

if command -v ss >/dev/null 2>&1; then
  ss -lntu | grep -qE '[:.]5140[[:space:]]' \
    && pass "Syslog port 5140 listening" \
    || fail "Syslog port 5140 not listening"

  ss -lnt | grep -qE '[:.]5601[[:space:]]' \
    && pass "Kibana port 5601 listening" \
    || warn "Kibana port 5601 not listening"
fi

if grep -R --line-number -E \
    'password[[:space:]]*=>[[:space:]]*"(changeme|REPLACE_WITH_STRONG_RANDOM_SECRET)"|ELASTIC_PASSWORD=(changeme|REPLACE_WITH_STRONG_RANDOM_SECRET)|KIBANA_PASSWORD=(changeme|REPLACE_WITH_STRONG_RANDOM_SECRET)' \
    "${PFELK_HOME}" 2>/dev/null; then
  fail "Unsafe default/example credentials found under ${PFELK_HOME}"
else
  pass "No unsafe default credentials under ${PFELK_HOME}"
fi

if grep -R --line-number -E 'network\]\[protocol\].*(tcp|udp)' \
    "${PFELK_HOME}/conf.d" "${PFELK_HOME}/patterns" 2>/dev/null; then
  fail "TCP/UDP still mapped to network.protocol"
else
  pass "ECS transport mapping"
fi

if grep -q 'event\]\[type.*error' "${PFELK_HOME}/conf.d/50-outputs.pfelk" 2>/dev/null; then
  fail "pipeline_error routing still sets event.type=error"
else
  pass "Pipeline-error ECS categorization"
fi

if grep -q '^KEADHCP6[[:space:]].*GREEDYDATA' "${PFELK_HOME}/patterns/pfelk.grok" 2>/dev/null; then
  fail "Kea DHCPv6 still has a catch-all success pattern"
else
  pass "Kea DHCPv6 unsupported-format handling"
fi

if grep -q 'dead_letter_queue.retain.age' "${LOGSTASH_SETTINGS}/logstash.yml" 2>/dev/null; then
  pass "DLQ age retention configured"
else
  fail "DLQ age retention is not configured"
fi

# Native installs keep bootstrap credentials root-only so we can validate that
# the component/index templates exist without printing a password.
credentials="${PFELK_HOME}/secrets/credentials.txt"
if [[ -r "${credentials}" && -f /etc/elasticsearch/certs/http_ca.crt ]]; then
  es_url="$(awk -F': ' '/^Elasticsearch URL:/ {print $2; exit}' "${credentials}")"
  es_password="$(awk -F': ' '/^elastic password:/ {print $2; exit}' "${credentials}")"

  if [[ -n "${es_url}" && -n "${es_password}" ]]; then
    for endpoint in \
      '/_component_template/pfelk-mappings' \
      '/_index_template/pfelk-logs' \
      '/_index_template/pfelk-pipeline-error'
    do
      if curl -fsS \
          --cacert /etc/elasticsearch/certs/http_ca.crt \
          -u "elastic:${es_password}" \
          "${es_url}${endpoint}" >/dev/null; then
        pass "Elasticsearch template present: ${endpoint}"
      else
        fail "Elasticsearch template missing/unreadable: ${endpoint}"
      fi
    done
  fi
fi

if (( FAILURES > 0 )); then
  printf '\n%s validation failure(s).\n' "${FAILURES}"
  exit 1
fi

printf '\nAll mandatory checks passed.\n'

#!/usr/bin/env bash
# Version | 26.10.0
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
  "${PFELK_HOME}/conf.d/49-cleanup.pfelk"
  "${PFELK_HOME}/conf.d/50-outputs.pfelk"
  "${PFELK_HOME}/patterns/pfelk.grok"
  "${PFELK_HOME}/patterns/openvpn.grok"
  "${LOGSTASH_SETTINGS}/pipelines.yml"
  "${LOGSTASH_SETTINGS}/logstash.yml"
)

for f in "${required[@]}"; do
  [[ -r "$f" ]] && pass "Readable: $f" || fail "Missing/unreadable: $f"
done

if command -v /usr/share/logstash/bin/logstash >/dev/null 2>&1 || [[ -x /usr/share/logstash/bin/logstash ]]; then
  if /usr/share/logstash/bin/logstash \
      --path.settings "${LOGSTASH_SETTINGS}" \
      --config.test_and_exit >/tmp/pfelk-logstash-test.out 2>&1; then
    pass "Logstash --config.test_and_exit"
  else
    fail "Logstash config test"
    tail -50 /tmp/pfelk-logstash-test.out || true
  fi
else
  warn "Logstash binary not installed; config runtime test skipped."
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
  ss -lntu | grep -qE '[:.]5140[[:space:]]' && pass "Syslog port 5140 listening" || fail "Syslog port 5140 not listening"
  ss -lnt  | grep -qE '[:.]5601[[:space:]]' && pass "Kibana port 5601 listening" || warn "Kibana port 5601 not listening"
fi

if grep -R --line-number -E 'password[[:space:]]*=>[[:space:]]*"changeme"|ELASTIC_PASSWORD=changeme|KIBANA_PASSWORD=changeme' \
    "${PFELK_HOME}" 2>/dev/null; then
  fail "Example/default credentials found under ${PFELK_HOME}"
else
  pass "No changeme credentials found under ${PFELK_HOME}"
fi

if grep -R --line-number 'network\]\[protocol.*tcp\|network\]\[protocol.*udp' \
    "${PFELK_HOME}/conf.d" "${PFELK_HOME}/patterns" 2>/dev/null; then
  fail "TCP/UDP still mapped to network.protocol"
else
  pass "Transport protocol ECS check"
fi

if (( FAILURES > 0 )); then
  printf '\n%s validation failure(s).\n' "${FAILURES}"
  exit 1
fi

printf '\nAll mandatory checks passed.\n'

#!/usr/bin/env bash
# Version | 26.10.1
# Repository | https://github.com/4n6-monster/pfelk
set -Eeuo pipefail
umask 077

OUT_DIR="${PFELK_SUPPORT_DIR:-/etc/pfelk/logs}"
OUT="${OUT_DIR}/error.pfelk.log"
mkdir -p "${OUT_DIR}"
: > "${OUT}"

section() {
  printf '\n################################################################################\n' >> "${OUT}"
  printf '# %s\n' "$1" >> "${OUT}"
  printf '################################################################################\n' >> "${OUT}"
}

safe_cat() {
  local f="$1"
  [[ -r "${f}" ]] || return 0
  printf '\n--- %s ---\n' "${f}" >> "${OUT}"
  sed -E \
    -e 's/((password|passwd|license[_ -]?key|api[_ -]?key|token)[^:=]*[:=][[:space:]]*)[^[:space:]]+/\1[REDACTED]/Ig' \
    -e 's/(Authorization:[[:space:]]*(Basic|Bearer|ApiKey)[[:space:]]+)[^[:space:]]+/\1[REDACTED]/Ig' \
    "${f}" >> "${OUT}"
}

section "pfELK support bundle"
printf 'Generated: %s\n' "$(date --iso-8601=seconds)" >> "${OUT}"
printf 'Hostname: %s\n' "$(hostname -f 2>/dev/null || hostname)" >> "${OUT}"

section "Operating system"
uname -a >> "${OUT}" 2>&1 || true
cat /etc/os-release >> "${OUT}" 2>&1 || true
free -h >> "${OUT}" 2>&1 || true
df -h >> "${OUT}" 2>&1 || true

section "pfELK file tree"
find /etc/pfelk -maxdepth 3 -type f -printf '%p\n' 2>/dev/null | sort >> "${OUT}" || true

section "Logstash configuration (redacted)"
for f in /etc/pfelk/conf.d/*.pfelk /etc/pfelk/patterns/*.grok /etc/pfelk/templates/*.json /etc/logstash/pipelines.yml /etc/logstash/logstash.yml; do
  [[ -e "${f}" ]] && safe_cat "${f}"
done

section "Versions"
dpkg-query -W -f='${Package}\t${Version}\n' elasticsearch logstash kibana 2>/dev/null >> "${OUT}" || true
/usr/share/logstash/bin/logstash --version >> "${OUT}" 2>&1 || true

section "Logstash config validation"
PFELK_ES_PASSWORD='[REDACTED]' /usr/share/logstash/bin/logstash \
  --path.settings /etc/logstash --config.test_and_exit >> "${OUT}" 2>&1 || true

section "Service status"
for svc in elasticsearch logstash kibana; do
  printf '\n### %s ###\n' "${svc}" >> "${OUT}"
  systemctl status "${svc}" --no-pager -l >> "${OUT}" 2>&1 || true
done

section "Recent Logstash journal"
journalctl -u logstash -n 150 --no-pager >> "${OUT}" 2>&1 || true

section "Listening sockets"
ss -lntup >> "${OUT}" 2>&1 || true

section "Kernel settings"
sysctl vm.max_map_count >> "${OUT}" 2>&1 || true

chmod 0600 "${OUT}"
printf 'Support data created: %s\n' "${OUT}"
printf 'Review the file before sharing. Automated redaction is best-effort, not a guarantee.\n'

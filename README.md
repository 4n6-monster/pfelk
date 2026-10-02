![Elastic](https://img.shields.io/badge/Elastic-9.5.4-blue.svg)
![pfELK](https://img.shields.io/badge/pfELK-26.10.1-green.svg)

# pfELK — pfSense/OPNsense + Elastic Stack

pfELK ingests, normalizes, enriches, and visualizes pfSense/OPNsense and related
network-security logs with Elasticsearch, Logstash, and Kibana.

This fork targets Elastic 9.5.4, ECS-oriented data streams, least-privilege
runtime ingestion, parser-failure visibility, durable Logstash buffering, and
repeatable native/Docker deployments.

## Highlights

- pfSense / OPNsense `filterlog`
- IPv4 / IPv6, TCP / UDP, structured ICMP and CARP parsing
- Unbound DNS including modern `query:` / `reply:` records
- OpenVPN
- Suricata and Snort
- HAProxy / NGINX / Squid
- Captive Portal
- ISC DHCP (legacy) and Kea DHCPv4
- Kea DHCPv6 is explicitly marked unsupported until fixture-backed parsing exists
- ECS `network.transport`, firewall `event.type`, `observer.*`, and `related.ip`
- dataset-oriented data streams
- dedicated `pfelk.pipeline_error` data stream
- configurable data-stream lifecycle retention
- persistent Logstash queue and dead-letter queue
- least-privilege `pfelk_writer`; Logstash does not run as `elastic`
- Docker TLS for Elasticsearch **and Kibana browser traffic**
- GitHub Actions syntax/config/parser-fixture validation

## Requirements

### Native

- Debian 12/13 or Ubuntu 22.04/24.04/26.04
- systemd
- 8 GiB RAM minimum; 16+ GiB recommended
- SSD-backed storage sized for event volume and retention

### Docker

- Docker Engine + Compose v2
- 8 GiB RAM minimum; 16+ GiB recommended
- `vm.max_map_count=262144`

## Native quick start

```bash
curl -fsSLO \
  https://raw.githubusercontent.com/4n6-monster/pfelk/main/etc/pfelk/scripts/pfelk-installer.sh
chmod +x pfelk-installer.sh

sudo ./pfelk-installer.sh \
  --stack-version 9.5.4 \
  --timezone America/Chicago \
  --retention 30d \
  --error-retention 14d
```

Optional enrichment files/dictionaries:

```bash
sudo ./pfelk-installer.sh \
  --timezone America/Chicago \
  --enrichments
```

The installer configures the signed Elastic 9.x APT repository, Elasticsearch,
Logstash, Kibana enrollment, pfELK templates/retention, the `pfelk_writer`
identity, the Logstash keystore, PQ/DLQ durability, and performs
`logstash --config.test_and_exit` before restart.

Validate at any time:

```bash
sudo /etc/pfelk/scripts/pfelk-validate.sh
```

See [install/install.md](install/install.md).

## Docker quick start

Clone the fork and generate a private `.env`:

```bash
git clone https://github.com/4n6-monster/pfelk.git
cd pfelk

./etc/pfelk/scripts/pfelk-docker-init.sh
```

Review `.env`, especially:

```text
PFELK_TIMEZONE
PFELK_RETENTION
PFELK_ERROR_RETENTION
PFELK_REPLICAS
KIBANA_SERVER_NAME
KIBANA_BIND
SYSLOG_BIND
ES_MEM_LIMIT
LS_MEM_LIMIT
```

`KIBANA_SERVER_NAME` must resolve to the Docker host. The default is
`pfelk.local`; add a local DNS record or change it before the first certificate
bootstrap.

Then:

```bash
sudo sysctl -w vm.max_map_count=262144
docker compose config --quiet
docker compose up -d
docker compose ps
```

Open Kibana at:

```text
https://<KIBANA_SERVER_NAME>:5601
```

The Docker CA is private/self-managed. Trust the generated CA in your browser or
OS trust store if you want the browser to show the connection as trusted.

See [install/docker.md](install/docker.md).

## Data streams and retention

Application/source identity is the ECS dataset:

```text
logs-pfelk.firewall-default
logs-pfelk.unbound-default
logs-pfelk.openvpn-default
logs-pfelk.suricata-default
logs-pfelk.pipeline_error-default
```

`PFELK_NAMESPACE` groups deployments (`default`, `home`, `lab`, `production`,
etc.). The setup process installs pfELK component/index templates before
Logstash starts writing.

Defaults:

```text
PFELK_RETENTION=30d
PFELK_ERROR_RETENTION=14d
PFELK_REPLICAS=0
```

Increase `PFELK_REPLICAS` for a multi-node Elasticsearch deployment.

## Parser failures

Main parser failures receive both:

```text
pfelk_pipeline_error
_pfelk_<parser>_..._failure
```

and are routed to:

```text
logs-pfelk.pipeline_error-<namespace>
```

This preserves the original event while making upstream log-format changes easy
to detect.

## Firewall forwarding

Configure pfSense/OPNsense to forward syslog to the pfELK host on port `5140`.
UDP is the common default; TCP is also accepted.

See [install/configuration.md](install/configuration.md).

## Security

- `.env` is local-only and gitignored; only `.env.example` belongs in Git.
- Docker fails closed if required passwords are missing.
- Elasticsearch is loopback-bound on the Docker host by default.
- Docker Kibana uses HTTPS.
- Restrict Kibana/syslog binds and host firewall rules to appropriate networks.
- `elastic` is bootstrap/admin only; Logstash uses `pfelk_writer`.
- Native Logstash stores its writer password in the Logstash keystore.
- Review `error-data.sh` output manually before sharing support data.

See [install/security.md](install/security.md).

## Validation and development

Local static checks:

```bash
bash -n etc/pfelk/scripts/*.sh
python3 tests/validate_repository.py
./etc/pfelk/scripts/pfelk-docker-init.sh
docker compose config --quiet
```

GitHub Actions additionally runs:

- ShellCheck
- Logstash `--config.test_and_exit` using Logstash 9.5.4
- representative fixture replay through the actual pfELK filters
- assertions for TCP/ICMP firewall normalization, Unbound, NGINX timestamps,
  and explicit Kea DHCPv6 pipeline-error handling

## License

Apache License 2.0. See the repository license file.

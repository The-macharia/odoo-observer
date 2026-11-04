#!/usr/bin/env bash
# Validates the observer config with each component's own checker (needs docker).
set -euo pipefail

here=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
img() { grep -ohE "image: \S*$1\S*" "$here/stack.yml" "$here/alertmanager-stack.yml" | head -1 | cut -d' ' -f2; }
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT

cp -r "$here/config/." "$here/alerting/." "$here/hub/." "$tmp/"
grep -rl '__[A-Z_]*__' "$tmp" | xargs sed -i \
    -e 's|__CLIENT__|test|g' -e 's|__STACK__|test|g' -e 's|__DB__|test|g' -e 's|__HUB__|hub.example.com|g' \
    -e 's|__DB_HOST__|test_db|g' -e 's|__DB_PORT__|5432|g' -e 's|__DB_SSLMODE__|disable|g' \
    -e 's|__URL__|https://hub.example.com|g' -e 's|__AM_SCHEME__|http|g' -e "s|__AM_TARGETS__|'alertmanager:9093'|g" \
    -e 's|__AM_URL__|http://alertmanager:9093/alertmanager|g' \
    -e 's|__TELEGRAM_CHAT__|-1001234567890|g' -e 's|__HEARTBEAT_RECEIVER__|heartbeat|g'
mkdir -p "$tmp/prometheus/fleet"
echo "- {targets: ['erp.example.com:443'], labels: {client: example}}" > "$tmp/prometheus/fleet/federate.yml"
cp "$tmp/prometheus/fleet/federate.yml" "$tmp/prometheus/fleet/probe.yml"
echo secret > "$tmp/fleet_password"

check_prometheus() {
    docker run --rm --entrypoint promtool -v "$tmp/prometheus:/etc/prometheus:ro" \
        -v "$tmp/fleet_password:/etc/observer/fleet_password:ro" "$(img prometheus)" check config --lint-fatal /etc/prometheus/prometheus.yml
}
check_loki() {
    docker run --rm -e FLEET_PASSWORD=x -v "$tmp/loki:/etc/loki:ro" "$(img loki)" \
        -config.file=/etc/loki/loki.yml -config.expand-env=true -verify-config
}
check_prometheus
docker run --rm --entrypoint promtool -v "$here:/src:ro" -w /src/test "$(img prometheus)" test rules rules.test.yml
docker run --rm --entrypoint amtool -v "$tmp/alertmanager:/etc/alertmanager:ro" "$(img alertmanager)" \
    check-config /etc/alertmanager/alertmanager.yml
check_loki
# a standalone server, with no hub to send alerts to
sed -i "s|targets: \['alertmanager:9093'\]|targets: []|" "$tmp/prometheus/prometheus.yml"
sed -i 's|alertmanager_url: .*|alertmanager_url: |' "$tmp/loki/loki.yml"
grep -q 'targets: \[\]' "$tmp/prometheus/prometheus.yml"
check_prometheus
check_loki
docker run --rm -v "$tmp/alloy:/etc/alloy:ro" "$(img alloy)" fmt /etc/alloy/config.alloy > /dev/null
# both /monitor files inside a bare server{}, as the Odoo nginx includes them
printf 'events {}\nhttp { server { listen 8080; include /etc/nginx/monitor/*.locations; } }\n' > "$tmp/nginx/test.conf"
docker run --rm -v "$tmp/nginx:/etc/nginx/monitor:ro" nginx:1.28-alpine nginx -t -q -c /etc/nginx/monitor/test.conf
for f in "$tmp"/grafana/dashboards/*.json; do
    python3 -m json.tool "$f" > /dev/null || { echo "bad json: $f"; exit 1; }
done
echo "observer config OK"

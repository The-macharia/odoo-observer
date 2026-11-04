#!/usr/bin/env bash
# Deploys (or removes) swarm stack "observer" next to the Odoo stack $STACK. All input comes from the
# environment, documented in README.md under "Deploy interface"; any caller (the odoo-actions observer
# action, or a shell) may run it. The server whose DOMAIN is the HUB also federates every server in
# FLEET_FILE and serves Grafana at the hub domain's root. What else runs is chosen by HUB, EXPORT and
# the Telegram settings; README.md, "Choosing what runs".
set -euo pipefail

SRC=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
OBS=$PROJECT_DIR/observer
NGINX_SVC=${STACK}_nginx
hub=false
[ "$DOMAIN" = "$HUB" ] && hub=true

die() { echo "::error::$*"; exit 1; }
running() { docker ps -q -f "label=com.docker.swarm.service.name=$1" | head -1; }
mount_src() {
    docker service inspect "$1" \
        --format "{{range .Spec.TaskTemplate.ContainerSpec.Mounts}}{{if eq .Target \"$2\"}}{{.Source}}{{end}}{{end}}"
}
nginx_reload() {
    local ctr
    ctr=$(running "$NGINX_SVC")
    [ -n "$ctr" ] || { echo "::warning::$NGINX_SVC is not running; it reads the files on its next start"; return 0; }
    docker exec "$ctr" nginx -t && docker exec "$ctr" nginx -s reload
}
# config lives in bind mounts, so a config-only change leaves every service spec as it was
restart_all() {
    for svc in $(docker stack services observer --format '{{.Name}}'); do
        docker service update --force --detach=true -q "$svc" >/dev/null
    done
}

case $ACTION in
    restart)
        [ -n "$(docker stack services -q observer)" ] || die "stack observer is not deployed"
        restart_all
        exit 0 ;;
    # data volumes and nginx paths stay, so /monitor answers 502 until the next deploy
    stop)
        docker stack rm observer
        exit 0 ;;
esac

conf=$(mount_src "$NGINX_SVC" /etc/nginx/conf.d)
[ -n "$conf" ] || die "$NGINX_SVC mounts nothing at /etc/nginx/conf.d"

if [ "$ACTION" = down ]; then
    docker stack rm observer
    rm -rf "$conf/monitor" "$conf/monitor-hub.conf"
    nginx_reload
    exit 0
fi

# a hub's servers export by default, since the hub reads their data
case ${EXPORT:-} in
    true | false) export_api=$EXPORT ;;
    '') if [ -n "$HUB" ] && ! $hub; then export_api=true; else export_api=false; fi ;;
    *) die "EXPORT must be true, false or empty, got '$EXPORT'" ;;
esac
# alerts are delivered from here on the hub, and on a standalone server given a Telegram bot; a hub's
# servers send theirs to the hub
local_am=$hub
if [ -z "$HUB" ] && [ -n "$TELEGRAM_BOT_TOKEN" ]; then local_am=true; fi

[ -n "$PROJECT_DIR" ] || die "PROJECT_DIR is not set"
[ -n "$MONITOR_PASSWORD" ] || die "secret MONITOR_PASSWORD is not set"
# an empty password would let anyone in as "fleet"
if [ -n "$HUB" ] || $export_api; then
    [ -n "$FLEET_PASSWORD" ] || die "secret MONITOR_FLEET_PASSWORD is not set; a hub, its servers and EXPORT need it"
fi
if $local_am; then
    [ -n "$TELEGRAM_BOT_TOKEN" ] || die "secret MONITOR_TELEGRAM_BOT_TOKEN is not set"
    [[ $TELEGRAM_CHAT_ID =~ ^-?[0-9]+$ ]] || die "variable MONITOR_TELEGRAM_CHAT_ID must be the numeric chat id"
    [ -n "$HEARTBEAT_URL" ] \
        || echo "::warning::secret MONITOR_HEARTBEAT_URL is not set, so nothing reports this server's alerting going down"
fi
if $hub; then [ -f "$FLEET_FILE" ] || die "$FLEET_FILE is missing from the repo"; fi
# pg <psql args>: psql as the Postgres admin, on database postgres
if docker service inspect "${STACK}_db" >/dev/null 2>&1; then
    db_ctr=$(running "${STACK}_db")
    [ -n "$db_ctr" ] || die "no running ${STACK}_db container"
    DB_HOST=${STACK}_db DB_PORT=5432 DB_SSLMODE=disable
    pg() { docker exec -i "$db_ctr" sh -c 'exec psql -X -U "${POSTGRES_USER:-postgres}" -d postgres "$@"' psql "$@"; }
else
    # external Postgres (Azure, RDS): reached the way Odoo reaches it, with the login in its rendered config
    odoo_conf=$(mount_src "${STACK}_odoo" /etc/odoo)/odoo.conf
    [ -f "$odoo_conf" ] || die "no ${STACK}_db service, and no odoo.conf mounted into ${STACK}_odoo to find Postgres in"
    mapfile -t pgconf < <(python3 - "$odoo_conf" <<'PY'
import configparser, sys
c = configparser.ConfigParser(interpolation=None, strict=False)
c.read(sys.argv[1])
o = c['options']
print(o.get('db_host', ''), o.get('db_port', '5432'), o.get('db_user', ''), o.get('db_password', ''), sep='\n')
PY
)
    [ -n "${pgconf[0]:-}" ] && [ -n "${pgconf[3]:-}" ] || die "$odoo_conf has no db_host or db_password"
    DB_HOST=${pgconf[0]} DB_PORT=${pgconf[1]} DB_SSLMODE=require
    pg() {
        docker run --rm -i -e PGHOST="$DB_HOST" -e PGPORT="$DB_PORT" -e PGUSER="${pgconf[2]}" \
            -e PGPASSWORD="${pgconf[3]}" -e PGSSLMODE=require postgres:17-alpine psql -X -d postgres "$@"
    }
fi

# --- config ---------------------------------------------------------------------------------
mkdir -p "$OBS/etc" "$OBS/secrets"
# files are rebuilt so a part turned off leaves nothing behind; directories stay, since running
# services bind-mount them and would see them empty until restarted
find "$OBS/etc" -type f -delete
chmod 700 "$OBS/secrets"
cp -r "$SRC/config/." "$OBS/etc/"
cp "$SRC/stack.yml" "$SRC/alertmanager-stack.yml" "$OBS/"
# the calling repo's own dashboards, from beside its fleet file
if [ -d monitor/dashboards ]; then cp -r monitor/dashboards "$OBS/etc/grafana/dashboards/client"; fi
if $local_am; then cp -r "$SRC/alerting/." "$OBS/etc/"; fi

if $local_am; then
    am_scheme=http am_targets="'alertmanager:9093'" am_url=http://alertmanager:9093/alertmanager alerts=Telegram
elif [ -n "$HUB" ]; then
    am_scheme=https am_targets="'$HUB:443'" am_url=https://$HUB/alertmanager alerts="sent to $HUB"
else
    # rules still evaluate and show in Grafana, but no alert leaves the server
    am_scheme=http am_targets= am_url= alerts=off
fi

if $hub; then
    url=https://$HUB sub_path=false home=fleet
    cp -r "$SRC/hub/." "$OBS/etc/"
    mkdir -p "$OBS/etc/prometheus/fleet"
    federate=$OBS/etc/prometheus/fleet/federate.yml
    probe=$OBS/etc/prometheus/fleet/probe.yml
    sources=$OBS/etc/grafana/provisioning/datasources/fleet.yml
    : > "$federate"
    : > "$probe"
    printf 'apiVersion: 1\n\ndatasources:\n' > "$sources"
    # "<client> <domain> [probe]": probe-only lines are checked from outside but not federated
    while read -r client domain kind _; do
        [[ -z $client || $client == \#* ]] && continue
        echo "- {targets: ['$domain'], labels: {client: '$client'}}" >> "$probe"
        [ "$kind" = probe ] && continue
        echo "- {targets: ['$domain:443'], labels: {client: '$client'}}" >> "$federate"
        cat >> "$sources" <<EOF
  - {name: '$client', uid: 'fleet-$client-prom', type: prometheus, url: 'https://$domain/monitor/prometheus',
     basicAuth: true, basicAuthUser: fleet, jsonData: {timeInterval: 30s},
     secureJsonData: {basicAuthPassword: \$FLEET_PASSWORD}}
  - {name: '$client logs', uid: 'fleet-$client-loki', type: loki, url: 'https://$domain/monitor/loki',
     basicAuth: true, basicAuthUser: fleet, jsonData: {maxLines: 5000},
     secureJsonData: {basicAuthPassword: \$FLEET_PASSWORD}}
EOF
    done < "$FLEET_FILE"
else
    url=https://$DOMAIN/monitor sub_path=true home=server
fi

{ grep -rl '__[A-Z_]*__' "$OBS/etc" || true; } | xargs -r sed -i \
    -e "s|__CLIENT__|$CLIENT|g" -e "s|__STACK__|$STACK|g" -e "s|__DB__|$DB|g" -e "s|__HUB__|$HUB|g" \
    -e "s|__DB_HOST__|$DB_HOST|g" -e "s|__DB_PORT__|$DB_PORT|g" -e "s|__DB_SSLMODE__|$DB_SSLMODE|g" \
    -e "s|__URL__|$url|g" -e "s|__AM_SCHEME__|$am_scheme|g" -e "s|__AM_TARGETS__|$am_targets|g" \
    -e "s|__AM_URL__|$am_url|g" \
    -e "s|__TELEGRAM_CHAT__|${TELEGRAM_CHAT_ID:-0}|g" \
    -e "s|__HEARTBEAT_RECEIVER__|$([ -n "$HEARTBEAT_URL" ] && echo heartbeat || echo discard)|g"

# --- secrets: files, because Prometheus and Alertmanager only read secrets from files ---------
[ -s "$OBS/secrets/db_password" ] \
    || python3 -c 'import secrets; print(secrets.token_hex(16), end="")' > "$OBS/secrets/db_password"
DB_PASSWORD=$(cat "$OBS/secrets/db_password")
printf %s "$FLEET_PASSWORD" > "$OBS/secrets/fleet_password"
if $local_am; then
    printf %s "$TELEGRAM_BOT_TOKEN" > "$OBS/secrets/telegram_token"
    printf %s "$HEARTBEAT_URL" > "$OBS/secrets/heartbeat_url"
fi
# containers run as other uids; the 700 directory keeps other host users out
chmod 644 "$OBS/secrets/"*

# --- database: read-only monitoring role that may use the reserved connection slots ----------
pg -q -v ON_ERROR_STOP=1 -v pw="$DB_PASSWORD" -v db="$DB" <<'SQL'
SELECT 'CREATE ROLE observer' WHERE NOT EXISTS (SELECT FROM pg_roles WHERE rolname = 'observer') \gexec
ALTER ROLE observer WITH LOGIN PASSWORD :'pw' CONNECTION LIMIT 6;
-- monitoring must never queue behind the locks it is there to report
ALTER ROLE observer SET lock_timeout = '2s';
ALTER ROLE observer SET statement_timeout = '20s';
GRANT pg_monitor TO observer;
-- a managed Postgres's admin may not hold this role to grant it
DO $$ BEGIN GRANT pg_use_reserved_connections TO observer; EXCEPTION WHEN others THEN RAISE WARNING '%', SQLERRM; END $$;
\connect :"db"
CREATE EXTENSION IF NOT EXISTS pg_stat_statements;
SQL
settings=$(pg -Atq <<'SQL'
SELECT current_setting('shared_preload_libraries') || ' ' || current_setting('reserved_connections');
SQL
)
[[ $settings == *pg_stat_statements* ]] \
    || echo "::warning::pg_stat_statements is not preloaded; deploy the app with the observer db flags"
[[ $settings != *" 0" ]] \
    || echo "::warning::reserved_connections is 0; monitoring cannot connect while Postgres is full"

# --- hub certificate (renewed afterwards by the ssl-renew action) ----------------------------
if $hub; then
    le=$(mount_src "$NGINX_SVC" /etc/letsencrypt)
    [ -n "$le" ] || die "$NGINX_SVC mounts no /etc/letsencrypt"
    # live/ is root-only, so look from inside a container
    if ! docker run --rm --entrypoint test -v "$le:/etc/letsencrypt:ro" certbot/certbot \
        -e "/etc/letsencrypt/live/$HUB/fullchain.pem"; then
        docker run --rm -v "$le:/etc/letsencrypt" -v "${le%/etc/letsencrypt}/var/lib/letsencrypt:/var/lib/letsencrypt" \
            -p 80:80 certbot/certbot certonly --standalone -n --agree-tos --register-unsafely-without-email -d "$HUB"
    fi
fi

# --- stack ------------------------------------------------------------------------------------
# node-exporter's textfile folder; must exist before the bind mount
mkdir -p -m 755 "$BACKUP_DIR/metrics"
files=(-c stack.yml)
if $local_am; then files+=(-c alertmanager-stack.yml); fi
cd "$OBS"
export STACK DB HUB NETWORK BACKUP_DIR MONITOR_PASSWORD FLEET_PASSWORD DB_PASSWORD DB_HOST DB_PORT DB_SSLMODE
export MONITOR_URL=$url GF_SUB_PATH=$sub_path HOME_DASHBOARD=$home
timeout 10m docker stack deploy "${files[@]}" --prune --detach=false observer
restart_all

# --- nginx ------------------------------------------------------------------------------------
rm -rf "$conf/monitor"
mkdir -p "$conf/monitor"
if $hub || $export_api; then
    python3 -c 'import base64, hashlib, os
salt = os.urandom(8)
digest = hashlib.sha1(os.environ["FLEET_PASSWORD"].encode() + salt).digest()
print("fleet:{SSHA}" + base64.b64encode(digest + salt).decode())' > "$conf/monitor/htpasswd"
fi
if $hub; then
    cp "$OBS/etc/nginx/monitor-hub.conf" "$conf/monitor-hub.conf"
else
    cp "$OBS/etc/nginx/monitor.locations" "$conf/monitor/"
    if $export_api; then cp "$OBS/etc/nginx/export.locations" "$conf/monitor/"; fi
    grep -qs 'conf.d/monitor/\*.locations' "$conf"/*.conf \
        || echo "::warning::no server{} includes /etc/nginx/conf.d/monitor/*.locations, so /monitor is not served"
fi
if ! nginx_reload; then
    rm -rf "$conf/monitor" "$conf/monitor-hub.conf"
    nginx_reload || true
    die "nginx rejected the monitor config, removed it again"
fi

# GF_SECURITY_ADMIN_PASSWORD only applies to a fresh Grafana database
for _ in $(seq 24); do
    ctr=$(running observer_grafana)
    if [ -n "$ctr" ] && printf %s "$MONITOR_PASSWORD" \
        | docker exec -i "$ctr" grafana cli admin reset-admin-password --password-from-stdin >/dev/null 2>&1; then
        synced=1
        break
    fi
    sleep 5
done
[ -n "${synced:-}" ] || echo "::warning::could not set the Grafana admin password; it keeps its previous value"

echo "Grafana: $url/ (user admin); alerts: $alerts; export: $export_api"

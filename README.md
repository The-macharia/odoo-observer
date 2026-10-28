# odoo-observer

Monitoring, logs and alerting for Odoo servers that run as Docker Swarm stacks. Every server runs
its own small observer stack (Prometheus, Loki, Grafana and exporters) and serves Grafana at
`https://<its domain>/monitor/`. One server is the **hub**. It shows every server in one Grafana,
holds the only Alertmanager, and posts alerts to Telegram.

This repo holds the stack, its configuration, the dashboards and alert rules, and `deploy.sh`, which
installs all of it on a server. It does not run by itself. A caller runs `deploy.sh` on the server: usually the
`observer` action in [odoo-actions](https://github.com/The-macharia/odoo-actions), from each client
repo's Observer workflow.

- [Dashboards](docs/dashboards.md): what each one answers
- [Alerts](docs/alerts.md): every rule, its threshold and the first thing to check
- [Runbooks](docs/runbooks.md): connection leaks, stuck vacuums, corruption checks, Telegram failures
- [Development](docs/development.md): layout, tests, adding rules and dashboards, releasing

## Architecture

```
 client server (one per Odoo client)                     hub server (monitor.<domain>)
┌──────────────────────────────────────────┐            ┌───────────────────────────────────────┐
│ Odoo stack <STACK>: odoo, db, nginx       │            │ Odoo stack + observer stack, plus:    │
│                                           │  federate  │  Prometheus ── scrapes every client's │
│ observer stack:                           │◀───────────│   /monitor/prometheus/federate        │
│  Prometheus ◀─ node-exporter, cadvisor,   │  (fleet    │  blackbox ── probes every client's    │
│              postgres-exporter, blackbox  │  password) │   /web/health from outside            │
│  Loki ◀─ Alloy (all container logs)       │            │  Grafana ── one datasource pair per   │
│       ◀─ recorder (pg_stat_activity/30s)  │   alerts   │   client, Fleet dashboard             │
│  Grafana at https://<domain>/monitor/     │───────────▶│  Alertmanager ─▶ Telegram group       │
│  (nginx: include monitor/*.locations)     │  (fleet    │              ─▶ healthchecks.io ping  │
└──────────────────────────────────────────┘  password) └───────────────────────────────────────┘
```

- **Per server.** Prometheus keeps 15 days (capped at 4 GB) and Loki 14 days. Grafana reads both,
  plus the Odoo database directly for the live session view.
- **Hub.** Each server's Prometheus and Loki ruler send alerts to the hub's Alertmanager. The hub
  federates only the `observer:*` summaries and `ALERTS` from each client, and queries everything
  else on demand through per-client datasources. A client the hub cannot reach raises
  `ClientUnreachable`. The `Watchdog` alert pings a dead-man URL every minute, so the hub going down
  is noticed too.
- **Which server is the hub.** The server whose `DOMAIN` equals `HUB`. It serves Grafana at the root
  of its own domain instead of under `/monitor`.

## What is implemented

| Service | Image | Role |
|---|---|---|
| prometheus | `prom/prometheus:v3.13.4` | Metrics and alert rules; 30s scrape, 15d / 4 GB retention |
| loki | `grafana/loki:3.7.8` | Logs, 14d retention; its ruler alerts on log patterns |
| grafana | `grafana/grafana:13.2.3` | Dashboards at `/monitor/` (hub: at the root) |
| alloy | `grafana/alloy:v1.20.1` | Ships every container's log to Loki. Joins Odoo tracebacks into one entry and extracts the level (global service) |
| node-exporter | `prom/node-exporter:v1.12.1` | Host CPU, memory, disk, OOM kills, backup timestamp file (global) |
| cadvisor | `ghcr.io/google/cadvisor:v0.60.6` | CPU, memory and restarts per swarm service (global) |
| postgres-exporter | `quay.io/prometheuscommunity/postgres-exporter:v0.20.1` | Postgres stats, `pg_stat_statements`, vacuum progress, checkpoints, plus custom queries |
| recorder | `postgres:17-alpine` | Logs every non-idle session to Loki every 30s (all sessions once Postgres is 80% full) |
| blackbox | `prom/blackbox-exporter:v0.29.0` | Probes Odoo's `/web/health` from inside the swarm |
| alertmanager (hub) | `prom/alertmanager:v0.34.1` | Groups alerts by server and alert, posts to Telegram, pings the heartbeat |

**Telling which Odoo process holds a connection.** Odoo is started with
`ODOO_PGAPPNAME='{{.Service.Name}}.{{.Task.Slot}}-{pid}'`, so every Postgres connection carries its
service, replica and worker pid (`gass_odoo.1-4242`). The exporter's `pg_holder` query splits that
into `holder` and `opid` labels. That pid is the one Odoo prints on each log line, so a connection
leads straight to the worker's log in Loki.

Custom exporter queries (`config/postgres-exporter/queries.yml`):

- `pg_holder`: connections and oldest transaction, by holder, pid, state, database, user and client address.
- `pg_blocked`: sessions waiting on another session's lock, and the longest wait.
- `pg_wraparound`: transaction id age per database.
- `pg_table`: the 30 largest tables, from `pg_class` page estimates. `pg_total_relation_size` would
  wait on table locks.

**Recording rules** (federated to the hub):

- `observer:pg_connections_usable`, `observer:pg_connections:ratio`
- `observer:cpu:ratio`, `observer:memory:ratio`, `observer:disk:ratio`
- `observer:odoo:up`

**Security:**

- Grafana requires a login: `admin` and `MONITOR_PASSWORD`.
- Behind the `fleet` basic-auth user (`MONITOR_FLEET_PASSWORD`):
  - Prometheus (GET/POST only; its admin and lifecycle APIs are off);
  - Loki's query endpoints;
  - the hub's Alertmanager.
- The `observer` database role is read-only (`pg_monitor`), with a connection limit of 6,
  `lock_timeout` 2s and `statement_timeout` 20s, so monitoring never queues behind the locks it
  reports. It may use the slots kept by `reserved_connections`, so it can still connect when Odoo
  has filled Postgres.
- Secrets live as files in `$PROJECT_DIR/observer/secrets/`, a directory only the owner can read
  (mode 700).

## Using it from odoo-actions

The client repo's `.github/workflows/observer.yml` (from `templates/observer.yml` in odoo-actions)
calls `The-macharia/odoo-actions/observer@v1` with one line naming this repo and version:

```
observer: The-macharia/odoo-observer@v1
```

The action fetches that repo at that ref and runs `deploy.sh`. The format is
`<owner/repo or git URL>@<tag, branch or commit>`. Edit the line in a server's workflow to:

- **pin it** so later releases don't reach it: `@v1.0.1`;
- **roll it back:** the previous version;
- **switch it to a fork** that keeps the deploy interface below:
  `other-owner/odoo-observer@v1` or `https://git.example.com/odoo-observer.git@main`.

Then rerun Observer.

### Setting up a server

Once per server:

1. **Repo variables:**
   - `MONITOR_DOMAIN`: the domain whose nginx serves `/monitor`; the hub domain on the hub.
   - `MONITOR_HUB`: the hub domain.
   - `STACK`, `MAIN_DB`, `RUNNER`, and optionally `NETWORK`, `PROJECT_DIR` and `BACKUP_DIR`.
2. **Repo secrets:** `MONITOR_PASSWORD` (Grafana admin) and `MONITOR_FLEET_PASSWORD` (the same on
   every server).
   - The hub also needs secrets `MONITOR_TELEGRAM_BOT_TOKEN` and `MONITOR_HEARTBEAT_URL`, and
     variable `MONITOR_TELEGRAM_CHAT_ID`, the group's numeric id (`-100…` for supergroups).
3. **The compose file:**
   - Odoo services: `ODOO_PGAPPNAME: '{{.Service.Name}}.{{.Task.Slot}}-{pid}'`.
   - Postgres, started with:

     ```
     -c max_connections=100 -c shared_preload_libraries=pg_stat_statements -c reserved_connections=5
     -c log_lock_waits=on -c log_connections=on -c log_disconnections=on
     -c log_min_duration_statement=2s -c "log_line_prefix=%m [%p] app=%a user=%u db=%d client=%h "
     ```

   - **The connection budget.** Odoo connects as a superuser and can take the reserved slots too. So
     every Odoo instance on that Postgres together must stay under `max_connections - 8`, each
     counting `(workers + max_cron_threads) * db_maxconn + db_maxconn_gevent`. The clients use
     `db_maxconn = 8` and `db_maxconn_gevent = 32`.
   - Container logs capped: `json-file` with `max-size`.
   - **Never switch a running db service's port between ingress and `mode: host`.** The new task
     cannot bind while the old one holds the port, and the stack is left without a database.
4. **nginx:** in the Odoo `server{}`, add `include /etc/nginx/conf.d/monitor/*.locations;`. The hub
   needs nothing; `deploy.sh` writes its `server{}` once the certificate is issued.
5. **Hub only:** list the servers in the hub repo's `monitor/fleet.txt`:

   ```
   # client             domain                           [probe = outside check only]
   gass                 erp.gasstransport.com
   ruman                ruman.muritechnologies.com       probe
   ```

6. **Run the Observer workflow.** Rerun it after any change; it applies config changes in place.
   `down` removes the stack and the nginx paths but keeps the data volumes.

## Deploy interface

`deploy.sh` takes everything from the environment. Set every variable; leave it empty where it
doesn't apply. A fork that keeps these names, and the paths `deploy.sh`, `stack.yml`,
`hub-stack.yml`, `config/` and `hub/`, can replace this repo through the `observer:` line.

| Variable | Used on | Meaning |
|---|---|---|
| `ACTION` | all | `deploy` or `down` |
| `STACK` | all | Swarm stack of the Odoo app. Needs `<STACK>_db`, plus `<STACK>_nginx` mounting `/etc/nginx/conf.d` (and `/etc/letsencrypt` on the hub) |
| `CLIENT` | all | Name the server reports as (the `client` label) |
| `DOMAIN` | all | Domain whose nginx serves `/monitor`; equal to `HUB` on the hub |
| `HUB` | all | Hub domain; alerts go to `https://$HUB/alertmanager` |
| `DB` | all | Odoo database for the exporter, `pg_stat_statements` and Grafana's live view |
| `NETWORK` | all | Overlay network the Odoo stack uses (the observer joins it) |
| `PROJECT_DIR` | all | The observer keeps `etc/` and `secrets/` in `$PROJECT_DIR/observer` |
| `BACKUP_DIR` | all | The backup job writes `metrics/odoo_backup.prom` (`odoo_backup_last_success_timestamp_seconds`) here. node-exporter mounts only `metrics/`, so the dumps stay private |
| `MONITOR_PASSWORD` | all | Grafana `admin` password, re-applied on every run |
| `FLEET_PASSWORD` | all | Basic-auth password of user `fleet` between the hub and every server |
| `FLEET_FILE` | hub | Path to the fleet file (format above) |
| `TELEGRAM_BOT_TOKEN` | hub | Bot that posts the alerts |
| `TELEGRAM_CHAT_ID` | hub | Numeric chat or group id |
| `HEARTBEAT_URL` | hub, optional | Dead-man URL pinged each minute by the `Watchdog` alert |

**What a run does:**

1. Copies `config/` (plus `hub/` on the hub) to `$PROJECT_DIR/observer/etc`, fills the
   `__PLACEHOLDERS__`, and on the hub generates the fleet scrape targets and Grafana datasources.
2. Writes the secret files. The `observer` role's password is generated once.
3. Creates or updates the `observer` role and `pg_stat_statements`. It warns if Postgres runs
   without the flags above.
4. On the hub, gets a Let's Encrypt certificate the first time.
5. Deploys swarm stack `observer` and restarts its services, since config lives in bind mounts.
6. Writes the nginx files and reloads nginx. If `nginx -t` rejects them, it removes them again.
7. Sets Grafana's admin password.

## Versioning

Releases are semver tags (`v1.2.0`). A release workflow publishes the GitHub release from
`CHANGELOG.md` and moves the major tag (`v1`) to it. Servers following `v1` pick a release up on
their next Observer run. A change that breaks the deploy interface or needs new client settings
gets a new major (`v2`). See [docs/development.md](docs/development.md#releasing).

## License

GPL-3.0, as odoo-actions.

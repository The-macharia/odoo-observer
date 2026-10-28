# Changelog

## v1.2.0

- **Backups are tracked per database.** Several databases can share a server (muritechnologies, ruman
  and edgescor on the hub).
  - The backup job writes `BACKUP_DIR/metrics/odoo_backup_<db>.prom` instead of one shared file,
    where the last database to finish hid the others.
  - `BackupTooOld` fires per database.
  - "Last backup" shows one value per database.
  - Needs odoo-actions edffe57 or later, which also keeps each database's zips in `BACKUP_DIR/<db>/`.
- `deploy.sh` no longer moves a top-level `odoo_backup.prom`. That one-time move ran on every server
  in v1.1.0.

## v1.1.0

- **Fix: "Last backup" showed "never"** on every server whose home directory is private.
  - node-exporter runs as `nobody` and got "permission denied" on `/home/odoo/backups`.
  - It now mounts only `BACKUP_DIR/metrics`, so the dumps beside it stay private.
  - `deploy.sh` creates that folder and moves an existing `odoo_backup.prom` into it.
  - **Backup jobs must write `BACKUP_DIR/metrics/odoo_backup.prom`.** The odoo-actions backup
    action does from fff2bfa on.

## v1.0.1

- **Docs:** the odoo-actions observer action takes one line, `observer: <repo>@<ref>`, written into
  each client workflow.

## v1.0.0

The observer as a standalone repo. It was the `observer/` directory of odoo-actions, which now
fetches this repo at the ref given by its `observer:` line.

- **Per-server stack:**
  - Prometheus, Loki, Grafana, Alloy, node-exporter, cadvisor, postgres-exporter and blackbox;
  - a session recorder that keeps `pg_stat_activity` history in Loki.
- **The hub:** fleet federation, outside probes, per-server datasources and the Fleet dashboard.
  Alertmanager posts to Telegram, with a dead-man heartbeat.
- **Dashboards:** Server, Postgres connections, Postgres live, Locks & deadlocks, Postgres
  performance, Odoo and Fleet.
- **Alerts:**
  - host, Odoo, Postgres, backup and hub rules;
  - `PostgresVacuumStuck` and `PostgresCheckpointStuck` catch a vacuum looping on a damaged page;
  - `ServiceRestarting` counts restarted containers by name, not by series.
- **Telegram messages:** at most 8 alerts per group, so a large group stays under Telegram's
  4096-character limit.
- `deploy.sh` (was `observer.sh`). Its environment is documented as the deploy interface, so a fork
  can replace this repo.

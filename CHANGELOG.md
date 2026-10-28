# Changelog

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

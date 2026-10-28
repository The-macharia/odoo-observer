# Alerts

Every server evaluates its own rules and sends them to the hub's Alertmanager, which posts to the
Telegram group:

- **Grouping.** Alerts are grouped by `client` and `alertname`. The first message waits 30s, updates
  follow at most every 5 min, and a still-firing group repeats every 4h.
- **Inhibition.** A critical alert mutes the warning of the same alert on the same server.
- **Message size.** A message lists at most 8 alerts of its group and shows the total (`×64`).
  Telegram refuses messages over 4096 characters.

The summaries and descriptions are the ones the alerts carry. "First check" is where to start.
`__URL__` in the rules becomes that server's Grafana.

## Host (Prometheus, `config/prometheus/rules/observer.yml`)

| Alert | Severity | Fires when | First check |
|---|---|---|---|
| HostCpuHigh | warning | CPU busy above 85% for 10 min | Server → CPU per service; long Odoo requests and crons are the usual cause |
| HostMemoryLow | critical | Memory used above 90% for 5 min | Server → Memory per service; Odoo worker recycling (`limit_memory_soft`) |
| HostOomKill | critical | The kernel killed a process for lack of memory | The service that restarted at the same time |
| HostDiskUsageHigh | warning | A filesystem above 85% for 10 min | Backups, docker images, filestore |
| HostDiskFillingUp | critical | The 6h trend reaches zero free within 24h and the disk is over 75% full, for 30 min | A backup step inside the 6h window can trigger it; check whether usage keeps growing between steps |
| ServiceRestarting | critical | A swarm service started more than 5 containers in 15 min (a deploy starts up to 4) | The service's last log lines before each replacement |

## Odoo

| Alert | Severity | Fires when | First check |
|---|---|---|---|
| OdooDown | critical | `/web/health` failing from inside the swarm for 2 min | Postgres connections first, then the Odoo log |
| OdooSlow | warning | The health check takes over 5s for 5 min | All workers busy: slow requests and crons on the Odoo dashboard |
| OdooErrorSpike (Loki) | warning | Over 20 ERROR/CRITICAL lines in 5 min from an Odoo service | Odoo dashboard → errors by module |
| OdooWorkerKilled (Loki) | warning | Odoo killed a worker for exceeding `limit_time_real` or `limit_time_cpu` | The killed pid in the Odoo log. A cron killed every 20 min is the signature of a connection leak ([runbook](runbooks.md#connections-climbing-in-steps)) |
| OdooPoolFull (Loki) | critical | "The Connection Pool Is Full" in an Odoo log | Which process: Postgres connections → connections by Odoo process |

## Postgres

| Alert | Severity | Fires when | First check |
|---|---|---|---|
| PostgresDown | critical | The exporter cannot reach Postgres for 1 min | The db service log |
| PostgresConnectionsHigh | warning / critical | Over 80% (2 min) / 90% (1 min) of usable connections taken | Postgres connections → holders table. Steps of +2 every 20 min mean a leak, not load |
| PostgresTooManyClients (Loki) | critical | "too many clients" or "remaining connection slots are reserved" in any log | Postgres is already refusing; same as above |
| PostgresIdleInTransaction | warning | A session idle inside a transaction for over 5 min | Look up the pid in the Odoo log; it holds its locks until it commits |
| PostgresLongTransaction | warning | One transaction active for over 15 min (pg_dump excluded) | Postgres live → sessions |
| PostgresBlocked | warning | A session has waited over 2 min on another session's lock | Postgres live → blocking chain |
| PostgresVacuumStuck | critical | A vacuum in "scanning heap" has scanned no page for 30 min | Usually a looping vacuum on a damaged page ([runbook](runbooks.md#a-stuck-vacuum)) |
| PostgresCheckpointStuck | critical | The checkpointer has not started a checkpoint for 45 min | Something holds a page lock forever; look for a stuck vacuum |
| PostgresDeadlock | warning | A deadlock in the last 5 min | Locks & deadlocks → deadlock reports name both statements |
| PostgresWraparound | warning | Transaction id age above 1 billion for 1h | Autovacuum is not freezing; run `VACUUM FREEZE` |
| PostgresErrorSpike (Loki) | warning | Over 10 ERROR/FATAL/PANIC lines in 5 min | Locks & deadlocks → Postgres errors |

`PostgresBlocked` only sees row and table locks (`pg_blocking_pids`). A session stuck behind a
*page* lock (`LWLock:BufferContent`) shows up only through `PostgresVacuumStuck`,
`PostgresCheckpointStuck`, or the connection count climbing.

## Platform

| Alert | Severity | Fires when | First check |
|---|---|---|---|
| BackupTooOld | critical | The last recorded good backup is over 26h old | The Database Backup workflow runs |
| BackupMissing | critical | No backup has been recorded on this server for 26h | The backup job must write `odoo_backup.prom` into `BACKUP_DIR/metrics` (mode 644) |
| MonitoringTargetDown | warning | An exporter or the probe has not reported for 5 min | Its panels and alerts are blind until it is back |

## Hub (`hub/prometheus/rules/hub.yml`)

| Alert | Severity | Fires when | First check |
|---|---|---|---|
| Watchdog | none | Always | Not an incident: it pings `MONITOR_HEARTBEAT_URL` every minute. Silence from healthchecks.io means the hub is down |
| ClientUnreachable | critical | The hub cannot federate a client for 3 min | That client's nginx and observer stack; its own alerts may not arrive either |
| OdooUnreachableFromOutside | critical | A domain in the fleet file fails `/web/health` from the hub for 3 min | DNS, certificate, nginx |
| SslCertExpiring | warning / critical | A certificate expires within 14 / 3 days | The ssl-renew job on that server |

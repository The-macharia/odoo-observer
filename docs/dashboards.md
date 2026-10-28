# Dashboards

Each server's Grafana (`https://<domain>/monitor/`) has the six dashboards below. The hub's Grafana
has them too, plus **Fleet**.

On the hub, the `ds` variable picks a server. The `logs` variable follows it automatically: a
Prometheus source named `gass` pairs with the Loki source named `gass logs`, so keep that naming when
adding sources.

## Server (`server`, the home page on clients)

Is this machine healthy, and which service is to blame?

- **Top row:** Odoo up and response time, CPU, memory, disk, Postgres connections, last backup,
  uptime, firing alerts.
- **CPU, memory and network per swarm service.** These name the heavy service, not just the host.
- **Containers per service.** Each restart shows as a step.
- **Out-of-memory kills.**

## Postgres connections (`pg-connections`)

Who holds the connections, and is it load or a leak?

- **Usage and pressure:** usable connections taken, idle in transaction, oldest open transaction,
  blocked sessions.
- **Who holds them:** the holders table at the end of the range (a pid opens that worker's Odoo
  log), and connections by holder, Odoo process, state and client address.
- **Refused connections and full Odoo pools**, taken from the logs.
- **Session recorder:** every non-idle session every 30s, and every session once Postgres is past
  80% full. It is the history of `pg_stat_activity`, so it shows what was running before an outage.
- **Connects and disconnects.** A disconnection line carries the session length.

## Postgres live (`pg-live`)

What is running right now? It queries Postgres directly as `observer` and covers this server only.

- **Sessions,** oldest transaction first, with their wait events.
- **Blocking chain:** who waits on whom.
- **Connections by holder.**
- **Top statements** since the last stats reset.

## Locks & deadlocks (`pg-locks`)

- **Now:** blocked sessions, the longest lock wait, locks held by mode.
- **Deadlock reports:** the ERROR line names the aborted process (`app=`), and DETAIL lists every
  process and its statement.
- **History:** lock waits over 1s (`log_lock_waits`), and Postgres errors.

## Postgres performance (`pg-performance`)

Is the database slow, and which statements cost the most?

- **Activity:** transactions, rows, commits and rollbacks per second.
- **Cache hit ratio.** A low ratio on a large database usually means `shared_buffers` is still at
  its 128 MB default.
- **Temp files.** These are sorts and hashes that overflow `work_mem`.
- **Growth and age:** database size, the largest tables, and transaction id wraparound age.
- **Statements:**
  - top statements by total time over the range (`pg_stat_statements`);
  - statement time by queryid;
  - statements slower than 2s, from the log, where `app=` names the Odoo process.

## Odoo (`odoo`)

Built from Odoo's own log lines. Filter by service, worker pid and level.

- **Requests:** per minute by status, request time split into SQL and Python, requests slower than
  3s (the number after the pid is the worker), and SQL queries per request (p95).
- **Errors** per minute by module.
- **Worker lifecycle:** spawns, recycling at the memory or request limit, and workers killed for
  time limits.
- **Crons:** run counts and durations.
- **The raw log,** filtered by the pid and level above.

## Fleet (`fleet`, hub only, its home page)

- **One row per server:**
  - whether the hub can reach it;
  - Odoo up, from inside and outside;
  - connections, CPU, memory and disk;
  - certificate days left;
  - firing alerts.

  Clicking a name opens that server's dashboards.
- **Firing alerts across the fleet**, with connections and memory used over time.

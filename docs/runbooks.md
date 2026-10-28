# Runbooks

Playbooks for the incidents this stack was built around. Commands run on the affected server;
replace `gass` and `gasstransport` with that server's stack and database.

```
db() { docker exec -i "$(docker ps -q -f name=gass_db | head -1)" psql -U odoo -d gasstransport "$@"; }
```

## Connections climbing in steps

**Signature.** `PostgresConnectionsHigh` fires in the early morning. On Postgres connections the count
rises in steps of +2 every 20 minutes, all from one holder, and the sessions sit `active` with wait
event `LWLock:BufferContent` running the same query. `OdooWorkerKilled` fires every 20 minutes.

**Cause.** Odoo kills a cron worker that exceeds `limit_time_real` (1200s here). But the Postgres
backend serving it is stuck in a wait that cannot be cancelled, so it stays open. Each kill
leaks one connection per cron thread, until Postgres refuses everyone ("too many clients"). Raising
`max_connections` or `db_maxconn` only delays the outage.

**Case: gass, 2026-10-27/28.**

1. 17:03 UTC: autovacuum on `ir_cron`, a two-page table, started looping on page 0 at 100% of one
   core, holding the page's lock.
2. Every cron worker's "ready jobs" query froze behind it, and so did the nightly `pg_dump` and the
   checkpointer.
3. Usage reached 86% by 05:25 EAT, and Postgres would have been full mid-morning.
4. Two earlier backups had failed with "too many clients", so it had happened before.

**What to do:**

1. Confirm the cause. Postgres connections → the session recorder shows the stuck query, and
   `pg_stat_progress_vacuum_*` shows a vacuum that does not move.
2. Restart the stack (Restart Stack workflow). It's the only thing that clears these sessions:
   `pg_terminate_backend` does not interrupt them. Postgres recovers from WAL on start; nothing is lost.
3. Before the next autovacuum reaches the table (it took 2h20m on gass), check and rebuild it:
   [A stuck vacuum](#a-stuck-vacuum).

## A stuck vacuum

**Signature.** `PostgresVacuumStuck`, often followed by `PostgresCheckpointStuck`. The vacuum shows
"scanning heap" with no progress, and Postgres CPU sits at exactly one core.

**Cause.** A damaged heap page, typically an orphaned heap-only tuple. PostgreSQL 16's vacuum retries
such a page forever while holding its lock.

**What to do:**

1. Restart the stack. See above for why only a restart works.
2. Find the damage. It's read-only and takes seconds on small databases:

   ```
   db -c "CREATE EXTENSION IF NOT EXISTS amcheck" \
      -c "SELECT c.relname, v.blkno, v.offnum, v.msg FROM pg_class c CROSS JOIN LATERAL verify_heapam(c.oid) v
          WHERE c.relkind IN ('r','m','t') AND c.relpersistence <> 't'"
   ```

3. Rewrite each damaged table. It's short, with an exclusive lock:
   `db -c "SET lock_timeout='5s'" -c "VACUUM FULL ir_cron"`.
4. Check the indexes too. Damaged indexes return wrong results silently. The check stops with an
   ERROR naming a damaged index; fix it with `REINDEX INDEX <name>`:

   ```
   db -c "SELECT c.relname, bt_index_check(c.oid, true) FROM pg_index i JOIN pg_class c ON c.oid = i.indexrelid
          JOIN pg_am a ON a.oid = c.relam WHERE a.amname = 'btree' AND c.relpersistence <> 't' AND i.indisvalid"
   ```

5. Run `verify_heapam` again; 0 rows means clean.

The images run without data checksums, so Postgres does not report disk-level damage when it reads
it. Enabling them needs Postgres stopped while `pg_checksums --enable` runs.

## Telegram alerts stop arriving

1. **Is the hub alive?** Silence from healthchecks.io (the `Watchdog` heartbeat) means the hub's
   Alertmanager is down.
2. **Read the Alertmanager log** on the hub: `docker service logs observer_alertmanager --since 1h`.
   - *"message length exceeds Telegram limits":* a group rendered over 4096 characters. The
     template lists 8 alerts per message; check that a custom template keeps that limit.
   - *"Bad Request: can't parse entities":* an annotation contains `<` or `&`, and Telegram's
     HTML mode rejects the whole message. Reword the annotation.
   - *"chat not found" or "Forbidden":* the bot was removed from the group, or
     `MONITOR_TELEGRAM_CHAT_ID` is wrong. A supergroup id starts with `-100`.
3. **Check what is active:** `https://<hub>/alertmanager/#/alerts`. The hub's Grafana also has an
   Alertmanager datasource.

## A client shows `ClientUnreachable`

The hub federates `https://<domain>/monitor/prometheus/federate` as user `fleet`. Check, in order:

1. `curl -u fleet:<password> https://<domain>/monitor/prometheus/-/ready`.
   - **401:** the fleet password differs between the hub and that server.
   - **404:** the nginx include line is missing, or Observer never ran there.
   - **502:** `observer_prometheus` is down.
2. On the server, `docker stack services observer`. Every service should show `1/1`, or one per
   node for the global services.
3. Rerun Observer on that server.

## Grafana keeps restarting

Look for `HostOomKill` and Server → memory per service. The hub's Grafana renders every server's
dashboards and needs more memory than a client's; its limit is in `stack.yml`. It was OOM-killed at
384M, and it peaks near 600M.

## The db port publish mode

Never switch a running db service's port between ingress and `mode: host` in a rolling deploy. The
new task cannot bind while the old one holds the port, and the stack is left without a database. On
gass this left a stale address that Odoo and nginx kept resolving. The Restart Stack workflow
(`stack rm` plus deploy) heals it. To change the mode, take the stack down and up.

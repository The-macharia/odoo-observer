# Development

## Layout

```
deploy.sh                   installs or removes the stack on a server (see README → Deploy interface)
stack.yml                   every server's swarm stack
hub-stack.yml               added on the hub: Alertmanager
config/                     copied to $PROJECT_DIR/observer/etc on every server
  prometheus/               prometheus.yml, rules/observer.yml (recording rules and alerts)
  loki/                     loki.yml, rules/fake/observer.yml (log alerts; "fake" is Loki's single-tenant id)
  alloy/config.alloy        container log shipping, multiline and level extraction
  postgres-exporter/        custom queries (pg_holder, pg_blocked, pg_wraparound, pg_table)
  recorder/recorder.sql     the 30s session snapshot
  blackbox/, grafana/       probe modules, datasources and dashboards
  nginx/monitor.locations   the /monitor paths included into the Odoo server{}
hub/                        copied over config/ on the hub only
  prometheus/               fleet federation and outside probes, hub alerts
  alertmanager/             routing, Telegram receiver and message template
  grafana/                  Fleet dashboard, Alertmanager datasource
  nginx/monitor-hub.conf    the hub's server{}
test/check.sh               validates everything with each component's own checker
test/rules.test.yml         promtool unit tests for the alert rules
```

**Placeholders.** `deploy.sh` replaces these in every copied file. Use them instead of hard-coding
anything server-specific:

| Placeholder | Becomes |
|---|---|
| `__CLIENT__`, `__STACK__`, `__DB__`, `__HUB__` | the deploy variables of the same names |
| `__URL__` | that server's Grafana (`https://<domain>/monitor`, or `https://<hub>` on the hub) |
| `__AM_SCHEME__`, `__AM_HOST__` | how Prometheus and Loki reach the Alertmanager |
| `__TELEGRAM_CHAT__` | the Telegram chat id |
| `__HEARTBEAT_RECEIVER__` | `heartbeat`, or `discard` without a heartbeat URL |

## Testing

```
bash test/check.sh
```

It runs promtool `check config --lint-fatal`, the rule unit tests, `amtool check-config`, Loki's
`-verify-config`, `alloy fmt` and a JSON check of every dashboard. It needs docker and uses the image
versions from `stack.yml`. CI runs it on every push and pull request, and the release workflow runs
it before publishing.

## Adding or changing an alert

1. Add the rule to `config/prometheus/rules/observer.yml`. Use a Loki rule for log patterns, and
   `hub/prometheus/rules/hub.yml` for hub-only checks.
2. Give it `severity` (`warning` or `critical`), and `summary`, `description` and `dashboard`
   annotations.
   - Annotations must not contain `<` or `&`: Telegram's HTML mode rejects the whole message.
3. Add a test to `test/rules.test.yml` that shows it firing on the bad case and staying quiet on a
   healthy one.
4. Describe it in [alerts.md](alerts.md).

## Adding a dashboard

Save the JSON into `config/grafana/dashboards/` (`hub/grafana/dashboards/` for hub-only ones):

- give it a fixed `uid` and the tag `observer`;
- use the `ds` (Prometheus) and `logs` (Loki) variables, so it works on the hub for every server.

Describe it in [dashboards.md](dashboards.md).

## Releasing

1. Add a `## vX.Y.Z` section to `CHANGELOG.md`. The release fails without it.
2. Tag and push:

   ```
   git tag vX.Y.Z && git push origin vX.Y.Z
   ```

3. The Release workflow runs the checks, publishes the GitHub release with that section as notes,
   and moves `vX` to the new tag. It doesn't move it when the tag is a patch to an older line.
4. Servers following `vX` pick the release up on their next Observer run. Rerun Observer on every
   server to roll it out now.

| Change | Version |
|---|---|
| New alerts, dashboards, fixes, image upgrades | minor or patch |
| Renamed or removed deploy variables, a new required client setting (compose flag, nginx line, secret), layout changes a fork relies on | major |

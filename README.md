# MySQL Long-Query Killer

A cron-safe guard that kills MySQL/MariaDB queries running longer than N
seconds — the classic hosting-server rescue against a stuck plugin, a bad
import, or a runaway report query pinning all your CPU.

## Why not just `max_execution_time`?

`max_execution_time` aborts statements server-wide and breaks replication
appliers and long admin imports too. This script lets you:

- **Kill only real runaway queries** — replication threads, event-scheduler
  jobs, `Sleep`/`Connect`/`Binlog Dump` states and `system user` threads are
  never touched.
- **Whitelist users** — e.g. your backup or reporting user keeps its long
  queries: `--whitelist-user reporting`.
- **Kill the query, not the connection** — `KILL QUERY` stops the statement
  while the app connection stays alive.
- **Re-verify before killing** — a query that finished between the list and
  the kill is skipped, not killed by ID reuse.
- **Audit everything** — log file + `--json` output with the killed SQL.

## Usage

```bash
chmod +x kill-long-queries.sh

# Preview what would be killed (safe first run)
./kill-long-queries.sh --max-seconds 300 --dry-run --verbose

# Really kill anything running ≥ 5 minutes, keep the backup user safe
./kill-long-queries.sh --max-seconds 300 \
    --whitelist-user backup \
    --log /var/log/long-query-killer.log

# Cron, every 5 minutes
*/5 * * * * /opt/scripts/kill-long-queries.sh --max-seconds 600 --log /var/log/lqk.log
```

## Options

| Flag | Description |
|---|---|
| `--max-seconds N` | Kill threshold (default 300) |
| `--dry-run` | Report only, kill nothing |
| `--whitelist-user NAME` | Repeatable — never kill this user's queries |
| `--log FILE` | Append timestamped actions to FILE |
| `--json` | Emit a JSON summary of matched queries |
| `--defaults-file PATH` | MySQL option file (default: `~/.my.cnf`, chmod 600) |
| `--host`, `--port` | Remote server |
| `--verbose` | Also print log lines to stderr |

Exit codes: `0` ok (or only dry-run/kill successes), `1` a kill failed,
`2` usage/connection error — safe for cron alerting and Nagios checks.

MIT licensed.

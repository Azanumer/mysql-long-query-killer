#!/usr/bin/env bash
#
# kill-long-queries.sh — Kill MySQL/MariaDB queries running longer than N seconds.
#
# Designed as a cron guard against runaway queries (bad plugins, stuck imports)
# on shared/hosting servers. Uses the client's own processlist so no extra
# privileges beyond PROCESS + SUPER/CONNECTION_ADMIN are needed.
#
# Safety:
#   - never kills replication, event-scheduler or system threads
#   - user whitelist (--whitelist-user, repeatable)
#   - excluded commands list (defaults: Binlog Dump, Sleep, Connect, Daemon)
#   - KILL QUERY (not KILL CONNECTION) so only the statement is stopped
#   - --dry-run shows what WOULD be killed
#
# Credentials: ~/.my.cnf (recommended, chmod 600), or --defaults-file.
#
# Usage:
#   ./kill-long-queries.sh --max-seconds 300 --log /var/log/long-query-killer.log
#   ./kill-long-queries.sh --max-seconds 120 --dry-run --verbose
#   crontab: */5 * * * * /opt/scripts/kill-long-queries.sh --max-seconds 600 --log /var/log/lqk.log
#
# Exit codes: 0 = ok (nothing killed or kills succeeded), 1 = a kill failed,
#             2 = usage/connection error.

set -euo pipefail

MAX_SECONDS=300
DRY_RUN=0
VERBOSE=0
LOG_FILE=""
DEFAULTS_FILE=""
HOST=""
PORT=""
USER_EXTRA=""
JSON_OUT=0
declare -a WHITELIST_USERS=()

# Commands (processlist COMMAND column) that are never killable.
EXCLUDED_COMMANDS="Binlog Dump|Sleep|Connect|Daemon|Binlog Dump GTID"

usage() {
    sed -n '2,20p' "$0"
}

log() {
    local msg="$1"
    local ts
    ts="$(date '+%Y-%m-%d %H:%M:%S')"
    if [[ -n "$LOG_FILE" ]]; then
        printf '%s %s\n' "$ts" "$msg" >>"$LOG_FILE"
    fi
    if [[ "$VERBOSE" -eq 1 ]]; then
        printf '%s %s\n' "$ts" "$msg" >&2
    fi
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --max-seconds)      MAX_SECONDS="$2"; shift 2 ;;
        --dry-run)         DRY_RUN=1; shift ;;
        --verbose)         VERBOSE=1; shift ;;
        --log)             LOG_FILE="$2"; shift 2 ;;
        --defaults-file)   DEFAULTS_FILE="$2"; shift 2 ;;
        --host)            HOST="$2"; shift 2 ;;
        --port)            PORT="$2"; shift 2 ;;
        --whitelist-user)  WHITELIST_USERS+=("$2"); shift 2 ;;
        --json)            JSON_OUT=1; shift ;;
        --help|-h)         usage; exit 0 ;;
        *) echo "Unknown option: $1" >&2; usage; exit 2 ;;
    esac
done

if ! [[ "$MAX_SECONDS" =~ ^[0-9]+$ ]] || [[ "$MAX_SECONDS" -lt 1 ]]; then
    echo "--max-seconds must be a positive integer" >&2
    exit 2
fi

MYSQL_OPTS=(-N -B)
[[ -n "$DEFAULTS_FILE" ]] && MYSQL_OPTS+=(--defaults-file="$DEFAULTS_FILE")
[[ -n "$HOST" ]] && MYSQL_OPTS+=(--host="$HOST")
[[ -n "$PORT" ]] && MYSQL_OPTS+=(--port="$PORT")
[[ -n "$USER_EXTRA" ]] && MYSQL_OPTS+=(--user="$USER_EXTRA")

# Pre-flight: can we reach the server at all?
if ! mysql "${MYSQL_OPTS[@]}" -e "SELECT 1" >/dev/null 2>&1; then
    echo "ERROR: cannot connect to MySQL/MariaDB with the given credentials" >&2
    exit 2
fi

# Own connection id, so we never match ourselves even under load.
SELF_ID="$(mysql "${MYSQL_OPTS[@]}" -e "SELECT CONNECTION_ID()" 2>/dev/null || echo 0)"

QUERY="
SELECT ID, USER, HOST, TIME, COMMAND, LEFT(INFO, 120)
FROM information_schema.processlist
WHERE ID <> ${SELF_ID}
  AND TIME >= ${MAX_SECONDS}
  AND COMMAND NOT REGEXP '${EXCLUDED_COMMANDS}'
  AND USER NOT LIKE 'system user%'
  AND INFO IS NOT NULL"

mapfile -t ROWS < <(mysql "${MYSQL_OPTS[@]}" -e "$QUERY" 2>/dev/null | sed 's/\t/|/g' || true)

killed=0
failed=0
declare -a JSON_ROWS=()

for row in "${ROWS[@]}"; do
    id="${row%%|*}"; rest="${row#*|}"
    user="${rest%%|*}"; rest="${rest#*|}"
    host="${rest%%|*}"; rest="${rest#*|}"
    secs="${rest%%|*}"; rest="${rest#*|}"
    cmd="${rest%%|*}"; info="${rest#*|}"

    # Apply user whitelist.
    skip=0
    for w in "${WHITELIST_USERS[@]:-}"; do
        if [[ "$user" == "$w" ]]; then skip=1; break; fi
    done
    if [[ "$skip" -eq 1 ]]; then
        log "SKIP whitelisted user $user (id=$id, ${secs}s)"
        continue
    fi

    # Double-check the query is still running right before killing it
    # (avoids racing a query that finished between listing and killing).
    still="$(mysql "${MYSQL_OPTS[@]}" -N -B -e \
        "SELECT COUNT(*) FROM information_schema.processlist WHERE ID=${id} AND TIME >= ${MAX_SECONDS}" 2>/dev/null || echo 0)"
    if [[ "$still" -eq 0 ]]; then
        log "SKIP id=$id already finished"
        continue
    fi

    info_oneline="$(echo "$info" | tr '\n' ' ' | sed 's/"/\\"/g')"
    if [[ "$DRY_RUN" -eq 1 ]]; then
        log "DRY-RUN would KILL QUERY id=$id user=$user host=$host time=${secs}s cmd=$cmd info=\"$info_oneline\""
    else
        if mysql "${MYSQL_OPTS[@]}" -e "KILL QUERY ${id}" >/dev/null 2>&1; then
            log "KILLED id=$id user=$user host=$host time=${secs}s cmd=$cmd info=\"$info_oneline\""
            killed=$((killed + 1))
        else
            log "FAILED to kill id=$id user=$user (${secs}s)"
            failed=$((failed + 1))
        fi
    fi
    JSON_ROWS+=("{\"id\":${id},\"user\":\"${user}\",\"host\":\"${host}\",\"seconds\":${secs},\"command\":\"${cmd}\",\"info\":\"${info_oneline}\",\"dry_run\":${DRY_RUN}}")
done

log "Summary: scanned, threshold=${MAX_SECONDS}s, killed=${killed}, failed=${failed}, dry_run=${DRY_RUN}"

if [[ "$JSON_OUT" -eq 1 ]]; then
    printf '{\n  "threshold_seconds": %s,\n  "killed": %d,\n  "failed": %d,\n  "dry_run": %d,\n  "queries": [\n' \
        "$MAX_SECONDS" "$killed" "$failed" "$DRY_RUN"
    for i in "${!JSON_ROWS[@]}"; do
        if [[ "$i" -gt 0 ]]; then printf ',\n'; fi
        printf '    %s' "${JSON_ROWS[$i]}"
    done
    printf '\n  ]\n}\n'
fi

[[ "$failed" -gt 0 ]] && exit 1
exit 0

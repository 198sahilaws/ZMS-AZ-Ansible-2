#!/usr/bin/env bash
# Record a converge result and optionally raise a failure alert. The region
# and target are derived from the environment - nothing is hardcoded.
#
# Usage: notify-result.sh <status> <unit>
#   <status> is systemd's $EXIT_STATUS ("0"/"success" on success).
set -uo pipefail

ENV_FILE=/etc/ansible/estate.env
if [ -f "$ENV_FILE" ]; then
  set -a
  # shellcheck disable=SC1090
  . "$ENV_FILE"
  set +a
fi

STATUS="${1:-unknown}"
UNIT="${2:-ansible}"
LOG_DIR=/var/log/ansible
STATUS_LOG="$LOG_DIR/converge-status.log"
FAIL_LOG="$LOG_DIR/converge-failures.log"
TS="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
HOST="$(hostname)"

mkdir -p "$LOG_DIR"
echo "$TS unit=$UNIT status=$STATUS host=$HOST" >>"$STATUS_LOG"

if [ "$STATUS" != "0" ] && [ "$STATUS" != "success" ]; then
  echo "$TS unit=$UNIT status=$STATUS host=$HOST" >>"$FAIL_LOG"

  # Optional Event Grid alert (only if a topic + key are configured).
  if [ -n "${ALERT_EVENTGRID_TOPIC_URL:-}" ] && [ -n "${ALERT_EVENTGRID_KEY:-}" ]; then
    uuid="$(cat /proc/sys/kernel/random/uuid)"
    payload="$(printf '[{"id":"%s","eventType":"zms.converge.failure","subject":"ansible/%s","eventTime":"%s","dataVersion":"1.0","data":{"unit":"%s","status":"%s","host":"%s"}}]' \
      "$uuid" "$UNIT" "$TS" "$UNIT" "$STATUS" "$HOST")"
    curl -sS -X POST "$ALERT_EVENTGRID_TOPIC_URL" \
      -H "aeg-sas-key: $ALERT_EVENTGRID_KEY" \
      -H "Content-Type: application/json" \
      -d "$payload" || echo "notify-result: alert POST failed"
  fi
fi

#!/bin/sh
# Entry point of the alertmanager container.
# Alertmanager does not expand environment variables in its YAML, so this script writes the
# config before starting it:
# - with a Telegram bot token (compose secret, /run/secrets/telegram_bot_token) and an integer
#   SVP_ALERT_TELEGRAM_CHAT_ID, severity="page" goes to Telegram; the token is copied to a mode
#   600 file read through bot_token_file, so it is never in the YAML, the logs or the environment;
# - otherwise every alert stays in the UI-only receiver (http://127.0.0.1:9093).
# severity="ticket" always stays in the UI: the 1d/3d SLO windows keep firing for days after a
# drill, and a message every 4 hours would only be noise.
# The values of the two variables are never printed.
set -eu
umask 077

token_secret=/run/secrets/telegram_bot_token
token_file=/tmp/telegram/bot_token
config=/tmp/alertmanager.yml
chat_id=${SVP_ALERT_TELEGRAM_CHAT_ID:-}

telegram=off
if [ -s "$token_secret" ] && [ -n "$chat_id" ]; then
  # chat_id is an integer in Alertmanager's config; anything else would stop it from starting.
  if printf '%s' "$chat_id" | grep -Eqx -- '-?[0-9]+'; then
    telegram=on
  else
    echo "alertmanager-entrypoint: SVP_ALERT_TELEGRAM_CHAT_ID is not an integer; Telegram receiver off" >&2
  fi
fi

if [ "$telegram" = on ]; then
  mkdir -p "$(dirname "$token_file")"
  cp "$token_secret" "$token_file"
  chmod 600 "$token_file"
  page_receiver=telegram
  echo "alertmanager-entrypoint: Telegram receiver on for severity=page"
else
  page_receiver=ui-only
  echo "alertmanager-entrypoint: Telegram receiver off (SVP_ALERT_TELEGRAM_BOT_TOKEN or SVP_ALERT_TELEGRAM_CHAT_ID empty); alerts are only shown at http://127.0.0.1:9093"
fi

cat > "$config" <<EOF
route:
  receiver: ui-only
  group_by: [alertname, severity]
  group_wait: 10s
  group_interval: 1m
  repeat_interval: 4h
  routes:
    - matchers: ['severity="page"']
      receiver: $page_receiver
receivers:
  # No integration: alerts routed here are only listed in the UI and API.
  - name: ui-only
EOF

if [ "$telegram" = on ]; then
  cat >> "$config" <<EOF
  - name: telegram
    telegram_configs:
      - bot_token_file: $token_file
        chat_id: $chat_id
        send_resolved: true
EOF
fi

# One replica: no cluster listener.
exec /bin/alertmanager --config.file="$config" --storage.path=/alertmanager --cluster.listen-address= "$@"

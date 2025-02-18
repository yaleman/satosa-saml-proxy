#!/bin/sh

set -eu

# This entrypoint exists to set gunicorn flags from ENV.
# Any arguments are interpreted as gunicorn flags to allow fine tuning, say for adding TLS.

# SATOSA is particular about log levels being uppercase, gunicorn doesn't care
LOG_LEVEL="$(echo "$LOG_LEVEL" | tr [:lower:] [:upper:])"
export LOG_LEVEL

exec gunicorn --log-level="$LOG_LEVEL" --bind="$LISTEN_ADDR"  "$@" "satosa.wsgi:app"

#!/bin/sh

# This entrypoint exists to set gunicorn flags from ENV.
# Any arguments are interpreted as gunicorn flags to allow fine tuning, say for adding TLS.

set -eu

exec gunicorn --log-level="$LOG_LEVEL" --bind="$LISTEN_ADDR"  "$@" "satosa.wsgi:app"

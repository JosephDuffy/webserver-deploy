#!/usr/bin/env bash

# Only used by test-bootstrap.sh, through a temporary PATH.
set -Eeuo pipefail
printf '%s\n' "$@" >"$BOOTSTRAP_TEST_SSH_ARGS"
tar -xzf - -C "$BOOTSTRAP_TEST_PAYLOAD"
exit "${BOOTSTRAP_TEST_SSH_STATUS:-0}"

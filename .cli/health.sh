#!/usr/bin/env bash
# health is now an alias for status
exec "$(dirname "$0")/status.sh" "$@"

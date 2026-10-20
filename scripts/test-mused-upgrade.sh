#!/bin/sh
# Compatibility wrapper: this script was renamed to test-ottod-upgrade.sh.
exec "$(dirname "$0")/test-ottod-upgrade.sh" "$@"

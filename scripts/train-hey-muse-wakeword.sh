#!/usr/bin/env bash
# Compatibility wrapper: this script was renamed to train-hey-otto-wakeword.sh.
exec "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/train-hey-otto-wakeword.sh" "$@"

#!/usr/bin/env bash
set -euo pipefail
root=/var/lib/hermes/workspace/dreamer
exec bash "$root/python-with-source.sh" "$root/dreamer.py" "$@"

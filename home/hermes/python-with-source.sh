#!/usr/bin/env bash
set -euo pipefail
: "${HERMES_PYTHON:?HERMES_PYTHON must name the packaged interpreter}"
: "${HERMES_PYTHON_SRC_ROOT:?HERMES_PYTHON_SRC_ROOT must name the selected source}"
if [[ ! -x "$HERMES_PYTHON" || ! -f "$HERMES_PYTHON_SRC_ROOT/tools/memory_tool.py" ]]; then
  printf 'Packaged Python or selected Hermes source is unavailable.\n' >&2
  exit 1
fi
export PYTHONPATH="$HERMES_PYTHON_SRC_ROOT${PYTHONPATH:+:$PYTHONPATH}"
exec "$HERMES_PYTHON" "$@"

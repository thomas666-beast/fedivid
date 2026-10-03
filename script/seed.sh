#!/usr/bin/env bash
set -euo pipefail

instance="${1:?usage: $0 <instance-name> [extra args]}"
shift || true
env_file="instances/${instance}.env"

[[ -f "$env_file" ]] || { echo "missing $env_file"; exit 1; }

set -a
# shellcheck disable=SC1090
source "$env_file"
set +a

exec carton exec -- perl script/seed.pl "$@"

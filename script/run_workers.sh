#!/usr/bin/env bash
set -euo pipefail

instance="${1:?usage: $0 <instance-name>}"
env_file="instances/${instance}.env"

[[ -f "$env_file" ]] || { echo "missing $env_file"; exit 1; }

set -a
# shellcheck disable=SC1090
source "$env_file"
set +a

log_dir="/tmp/fedivid-${instance}"
mkdir -p "$log_dir"

echo "Starting workers for $instance (logs in $log_dir)"
echo "  base_url:  $FEDIVID_BASE_URL"
echo "  database:  $FEDIVID_DATABASE_URL"
echo

carton exec -- perl script/transcode_worker.pl --loop --verbose \
    > "$log_dir/transcode.log" 2>&1 &
echo "  transcode PID: $!"

carton exec -- perl script/delivery_worker.pl --loop --verbose \
    > "$log_dir/delivery.log" 2>&1 &
echo "  delivery  PID: $!"

echo
echo "Logs:"
echo "  tail -f $log_dir/transcode.log"
echo "  tail -f $log_dir/delivery.log"
echo
echo "Press Ctrl+C to stop all three workers."

# Stop all children on exit
trap 'kill $(jobs -p) 2>/dev/null' EXIT

wait

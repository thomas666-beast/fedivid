#!/usr/bin/env bash
set -euo pipefail

instance="${1:?usage: $0 <instance-name>}"
env_file="instances/${instance}.env"

if [[ ! -f "$env_file" ]]; then
    echo "env file not found: $env_file"
    exit 1
fi

# Export env vars from the file
set -a
# shellcheck disable=SC1090
source "$env_file"
set +a

echo "Starting instance: $instance"
echo "  base_url:     $FEDIVID_BASE_URL"
echo "  listen:       $FEDIVID_LISTEN"
echo "  database:     $FEDIVID_DATABASE_URL"
echo "  upload_dir:   $FEDIVID_UPLOAD_DIR"
echo

exec carton exec -- morbo -l "$FEDIVID_LISTEN" script/fedivid
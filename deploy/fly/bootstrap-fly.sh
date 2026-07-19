#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
APP_PREFIX="lattice-bootstrap"
REGIONS=("iad" "ams" "sjc")
IMAGE="ghcr.io/adalinxx/lattice-node:main"
P2P_PORT=4001

usage() {
    echo "Usage: $0 {deploy|peers|status|update|destroy}"
    exit 1
}

app_name() {
    echo "${APP_PREFIX}-${1}"
}

get_ip() {
    fly ips list --app "$1" --json 2>/dev/null \
        | jq -r '.[] | select(.type == "v4") | .address' \
        | head -1
}

get_process_key() {
    fly logs --app "$1" --no-tail 2>/dev/null \
        | sed -n 's/.*process:[[:space:]]*//p' \
        | head -1
}

peers() {
    local region app ip key
    for region in "${REGIONS[@]}"; do
        app=$(app_name "$region")
        ip=$(get_ip "$app")
        key=$(get_process_key "$app")
        echo "--peer ${key}@${ip}:${P2P_PORT}"
    done
}

deploy() {
    local region app
    for region in "${REGIONS[@]}"; do
        app=$(app_name "$region")
        fly apps create "$app" 2>/dev/null || true
        if ! fly volumes list --app "$app" --json 2>/dev/null \
            | jq -e 'length > 0' >/dev/null; then
            fly volumes create lattice_data \
                --app "$app" --region "$region" --size 1 --yes
        fi
        fly ips allocate-v4 --shared --app "$app" 2>/dev/null || true
        fly deploy \
            --app "$app" \
            --image "$IMAGE" \
            --primary-region "$region" \
            --ha=false \
            --strategy immediate \
            --config "$SCRIPT_DIR/fly.toml" \
            --yes
    done
    peers
}

status() {
    local region app
    for region in "${REGIONS[@]}"; do
        app=$(app_name "$region")
        fly status --app "$app"
    done
}

update() {
    local region app
    for region in "${REGIONS[@]}"; do
        app=$(app_name "$region")
        fly deploy \
            --app "$app" \
            --image "$IMAGE" \
            --config "$SCRIPT_DIR/fly.toml" \
            --strategy immediate \
            --yes
    done
}

destroy() {
    local region app
    for region in "${REGIONS[@]}"; do
        app=$(app_name "$region")
        fly apps destroy "$app" --yes
    done
}

case "${1:-}" in
    deploy) deploy ;;
    peers) peers ;;
    status) status ;;
    update) update ;;
    destroy) destroy ;;
    *) usage ;;
esac

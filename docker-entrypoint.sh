#!/bin/sh

set -eu

CONFIG_FILE="/usr/local/etc/haproxy/haproxy.cfg"
LISTEN_PORT="${PORT:-10000}"

if [ -z "${TYPESENSE_BACKENDS:-}" ]; then
    echo "ERROR: TYPESENSE_BACKENDS is not set."
    exit 1
fi

cat > "$CONFIG_FILE" <<EOF
global
    log stdout format raw local0
    maxconn 4096

defaults
    log global
    mode http

    option httplog
    option dontlognull

    timeout connect 5s
    timeout client 60s
    timeout server 60s
    timeout http-request 15s

resolvers render_dns
    parse-resolv-conf

    resolve_retries 3
    timeout resolve 1s
    timeout retry 1s

    hold valid 10s
    hold other 30s
    hold refused 30s
    hold nx 30s
    hold timeout 30s
    hold obsolete 30s

frontend typesense_frontend
    bind 0.0.0.0:${LISTEN_PORT}
    default_backend typesense_backends

backend typesense_backends
    balance roundrobin

    option httpchk GET /health
    http-check expect status 200

    default-server inter 3s fall 3 rise 2
EOF

old_ifs="$IFS"
IFS=","

index=1

for backend in $TYPESENSE_BACKENDS; do
    # Remove surrounding whitespace.
    backend="$(echo "$backend" | xargs)"

    if [ -z "$backend" ]; then
        continue
    fi

    # Only allow hostname:port characters.
    case "$backend" in
        *[!A-Za-z0-9._:-]*)
            echo "ERROR: Invalid backend value: $backend"
            exit 1
            ;;
    esac

    echo "    server typesense_${index} ${backend} check resolvers render_dns init-addr last,libc,none" \
        >> "$CONFIG_FILE"

    index=$((index + 1))
done

IFS="$old_ifs"

if [ "$index" -eq 1 ]; then
    echo "ERROR: No valid Typesense backends were configured."
    exit 1
fi

echo "Generated HAProxy configuration:"
cat "$CONFIG_FILE"

echo "Validating HAProxy configuration..."

haproxy -c -f "$CONFIG_FILE"

echo "Starting HAProxy..."

exec haproxy -W -db -f "$CONFIG_FILE"
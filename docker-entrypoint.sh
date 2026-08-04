#!/bin/sh

set -eu

CONFIG_FILE="/usr/local/etc/haproxy/haproxy.cfg"
LISTEN_PORT="${PORT:-10000}"

if [ -z "${TYPESENSE_BACKENDS:-}" ]; then
    echo "ERROR: TYPESENSE_BACKENDS is not set."
    exit 1
fi

echo "TYPESENSE_BACKENDS=${TYPESENSE_BACKENDS}"
echo "HAProxy listen port: ${LISTEN_PORT}"

cat > "$CONFIG_FILE" <<EOF
global
    log stdout format raw local0
    maxconn 40000

defaults
    log global
    mode http

    option httplog
    option dontlognull

    timeout connect 5s
    timeout check 10s
    timeout client 60s
    timeout server 60s
    timeout http-request 15s

frontend typesense_frontend
    bind 0.0.0.0:${LISTEN_PORT}
    default_backend typesense_backends

backend typesense_backends
    balance roundrobin

    option httpchk GET /health
    http-check expect status 200
    option log-health-checks

    # Temporary debugging header showing which Typesense server responded.
    http-response set-header X-Typesense-Backend %[srv_name]

    default-server inter 1s fall 3 rise 2
EOF

OLD_IFS="$IFS"
IFS=","

index=1

for backend in $TYPESENSE_BACKENDS; do
    # Remove leading and trailing whitespace.
    backend="$(echo "$backend" | xargs)"

    if [ -z "$backend" ]; then
        continue
    fi

    # Validate hostname:port characters.
    case "$backend" in
        *[!A-Za-z0-9._:-]*)
            echo "ERROR: Invalid backend value: $backend"
            exit 1
            ;;
    esac

    echo "Adding backend typesense_${index}: ${backend}"

    # Do not use HAProxy's custom resolvers section.
    # HAProxy will resolve the hostname through the container's normal libc DNS.
    echo "    server typesense_${index} ${backend} check" \
        >> "$CONFIG_FILE"

    index=$((index + 1))
done

IFS="$OLD_IFS"

if [ "$index" -eq 1 ]; then
    echo "ERROR: No valid Typesense backends were configured."
    exit 1
fi

echo ""
echo "Generated HAProxy configuration:"
echo "--------------------------------"
cat "$CONFIG_FILE"
echo "--------------------------------"
echo ""

echo "Validating HAProxy configuration..."

haproxy -c -f "$CONFIG_FILE"

echo "Starting HAProxy..."

exec haproxy -W -db -f "$CONFIG_FILE"

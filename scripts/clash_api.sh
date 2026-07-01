clash_api() {
    local method="GET"
    local data=""
    local url=""
    local endpoint
    local hostport
    local host
    local port
    local path
    local status

    while [ "$#" -gt 0 ]; do
        case "$1" in
            -X)
                method="$2"
                shift 2
                ;;
            -d)
                data="$2"
                shift 2
                ;;
            http://*)
                url="$1"
                shift
                ;;
            *)
                shift
                ;;
        esac
    done

    if [ -z "$url" ]; then
        return 2
    fi

    endpoint="${url#http://}"
    hostport="${endpoint%%/*}"
    path="/${endpoint#*/}"
    if [ "$path" = "/$endpoint" ]; then
        path="/"
    fi

    host="$hostport"
    port="80"
    case "$hostport" in
        *:*)
            host="${hostport%:*}"
            port="${hostport##*:}"
            ;;
    esac

    # Local HTTP only; avoids shipping curl and its TLS dependencies at runtime.
    status="$(
        {
            printf '%s %s HTTP/1.1\r\n' "$method" "$path"
            printf 'Host: %s\r\n' "$hostport"
            if [ -n "$CLASH_WEB_PASSWORD" ]; then
                printf 'Authorization: Bearer %s\r\n' "$CLASH_WEB_PASSWORD"
            fi
            if [ -n "$data" ]; then
                printf 'Content-Type: application/json\r\n'
                printf 'Content-Length: %s\r\n' "${#data}"
            fi
            printf 'Connection: close\r\n\r\n'
            if [ -n "$data" ]; then
                printf '%s' "$data"
            fi
        } | busybox nc -w 5 "$host" "$port" | sed -n '1s/^[^ ]* \([0-9][0-9][0-9]\).*/\1/p'
    )"

    case "$status" in
        2*) return 0 ;;
        *) return 1 ;;
    esac
}

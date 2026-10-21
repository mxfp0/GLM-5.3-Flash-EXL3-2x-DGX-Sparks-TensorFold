#!/usr/bin/env bash
set -euo pipefail
root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)
source "$root/site/sparks.env"
hosts=(192.168.0.112 192.168.0.180 192.168.0.244 192.168.0.25)
ssh_args=(-o BatchMode=yes -o StrictHostKeyChecking=yes -o ConnectTimeout=10
          -o ServerAliveInterval=5 -o ServerAliveCountMax=2)
child=''

absent() {
    local name=$1 ip found failed=0
    [[ "$name" =~ ^[a-zA-Z0-9][a-zA-Z0-9_.-]+$ ]] || return 1
    for ip in "${hosts[@]}"; do
        if ! found=$(timeout 20 ssh "${ssh_args[@]}" "spark@$ip" \
            "docker ps -aq --filter 'name=^/${name}$'"); then
            failed=1
        elif [[ -n "$found" ]]; then
            echo "$name remains on $ip" >&2
            failed=1
        fi
    done
    return "$failed"
}

stop() {
    timeout 60 "$root/stop.sh" || true
    absent "$CONTAINER_NAME"
}

cleanup() {
    trap - EXIT TERM INT HUP
    if [[ -n "$child" ]]; then
        kill -- "-$child" 2>/dev/null || true
        for _ in {1..5}; do
            kill -0 "$child" 2>/dev/null || break
            sleep 1
        done
        kill -KILL -- "-$child" 2>/dev/null || true
        wait "$child" 2>/dev/null || true
        child=''
    fi
    stop
}

case ${1:-} in
    --stop) stop; exit ;;
    '') ;;
    *) echo 'Use no arguments or --stop' >&2; exit 2 ;;
esac

state=/home/spark/.local/state/glm53-tensorfold
mkdir -p "$state"
exec 9>"$state/launcher.lock"
flock -w 180 9 || exit 1
trap cleanup EXIT
trap 'exit 143' TERM
trap 'exit 130' INT
trap 'exit 129' HUP
stop
cd "$root"
setsid "$root/start-tp4-switchless.sh" 9>&- &
child=$!
deadline=$((SECONDS + 3300))
until curl --fail --silent --max-time 5 "http://127.0.0.1:$PORT/health" >/dev/null; do
    if ! kill -0 "$child" 2>/dev/null; then
        wait "$child" || true
        exit 1
    fi
    (( SECONDS < deadline )) || { echo 'GLM startup timed out' >&2; exit 1; }
    sleep 3
done
curl --fail --silent --show-error --max-time 180 "http://127.0.0.1:$PORT/v1/chat/completions" \
    -H 'Content-Type: application/json' \
    -d '{"model":"GLM-5.3-Flash-EXL3","max_tokens":32,"temperature":0,"chat_template_kwargs":{"enable_thinking":false},"messages":[{"role":"user","content":"Reply with OK."}]}' \
    > "$state/startup-smoke.json"
python3 -c 'import json,sys; r=json.load(open(sys.argv[1])); assert r["choices"][0]["message"].get("content", "").strip()' "$state/startup-smoke.json"
wait "$child"

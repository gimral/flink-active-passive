#!/bin/sh
# check-redis-key.sh
# POSIX shell script used by an init container to verify a Redis key's value.
# Exits 0 if the key's value equals the expected value, 1 otherwise.

set -u

usage() {
  cat <<EOF >&2
Usage: $0 [options]

Options:
  -H HOST        Redis host (or REDIS_HOST)
  -P PORT        Redis port (or REDIS_PORT)
  -a PASSWORD    Redis password (or REDIS_PASSWORD)
  -n DB          Redis database number (or REDIS_DB)
  -k KEY         Key to check (or KEY)
  -e EXPECTED    Expected value (or EXPECTED)
  -r RETRIES     Number of attempts (default: 1) (or RETRIES)
  -i INTERVAL    Seconds between retries (default: 1) (or INTERVAL)
  -h             Show this help

Exit codes:
  0 - key exists and value equals EXPECTED
  1 - key missing, value differs, redis-cli missing, or other error

Examples:
  # simple single check
  CHECK_REDIS_HOST=redis CHECK_REDIS_KEY=mykey CHECK_REDIS_EXPECTED=ready \ 
    sh ./init-check.sh

  # using flags and retrying
  sh ./init-check.sh -H redis -P 6379 -k mykey -e ready -r 5 -i 2
EOF
  exit 1
}

# defaults from environment or sensible defaults
# REDIS_HOST may be a single host or comma-separated list. Alternatively set REDIS_HOSTS.
REDIS_HOST=${REDIS_HOST:-127.0.0.1}
REDIS_HOSTS=${REDIS_HOSTS:-}
REDIS_PORT=${REDIS_PORT:-6379}
REDIS_PASSWORD=${REDIS_PASSWORD:-}
REDIS_DB=${REDIS_DB:-0}
KEY=${KEY:-}
EXPECTED=${EXPECTED:-}
RETRIES=${RETRIES:-1}
INTERVAL=${INTERVAL:-1}
CONFIG_MAP_PATH=${CONFIG_MAP_PATH:-/etc/flink-cluster-config}

# allow flag overrides
while [ "$#" -gt 0 ]; do
  case "$1" in
    -H) shift; REDIS_HOST=$1; shift ;;
    -P) shift; REDIS_PORT=$1; shift ;;
    -a) shift; REDIS_PASSWORD=$1; shift ;;
    -n) shift; REDIS_DB=$1; shift ;;
    -k) shift; KEY=$1; shift ;;
    -e) shift; EXPECTED=$1; shift ;;
    -r) shift; RETRIES=$1; shift ;;
    -i) shift; INTERVAL=$1; shift ;;
    -h) usage ;;
    --) shift; break ;;
    *) echo "Unknown option: $1" >&2; usage ;;
  esac
done


# If the cluster ConfigMap isn't mounted, treat this as "not required" and succeed.
if [ ! -e "$CONFIG_MAP_PATH" ]; then
  echo "Cluster config not present at '$CONFIG_MAP_PATH' — skipping Redis check and succeeding." >&2
  exit 0
fi

# Look specifically for files whose names start with 'executionPlan-'.
# Kubernetes mounts may place files at the top level or inside the special '..data' directory.
# If no 'executionPlan-' file is found, skip the Redis check and succeed.
found=0
if [ -d "$CONFIG_MAP_PATH" ]; then
#maybe check org.apache.flink.k8s.leader.job-*
  if ls "$CONFIG_MAP_PATH"/executionPlan-* >/dev/null 2>&1; then
    echo Found at 1
    found=1
  fi
  # Check top-level entries (ignore k8s metadata names starting with '..')
  # if find "$CONFIG_MAP_PATH" -mindepth 1 -maxdepth 1 -not -name '..*' -name 'executionPlan-*' -print -quit >/dev/null 2>&1; then
  #   echo "Found at 1"
  #   found=1
  # else
  #   # Check inside the '..data' directory that k8s uses for the actual files
  #   if [ -d "$CONFIG_MAP_PATH/..data" ] && find "$CONFIG_MAP_PATH/..data" -mindepth 1 -maxdepth 1 -name 'executionPlan-*' -print -quit >/dev/null 2>&1; then
  #     found=1
  #     echo "Found at 2"
  #   fi
  # fi
fi

if [ "$found" -ne 1 ]; then
  echo "No 'executionPlan-' files found under '$CONFIG_MAP_PATH' — skipping Redis check and succeeding." >&2
  exit 0
fi

echo "Found 'executionPlan-' file(s) in '$CONFIG_MAP_PATH' — proceeding to Redis check." >&2

# From here on the cluster config exists, so KEY and EXPECTED are required
if [ -z "$KEY" ] || [ -z "$EXPECTED" ]; then
  echo "ERROR: KEY and EXPECTED must be set (via env or flags) when cluster config is present." >&2
  usage
fi

# check redis-cli presence
if ! command -v redis-cli >/dev/null 2>&1; then
  echo "ERROR: redis-cli not found in PATH" >&2
  exit 1
fi

try=0
# prepare hosts list (space-separated)
# precedence: explicit REDIS_HOSTS, then REDIS_HOST (which may contain commas)
if [ -n "$REDIS_HOSTS" ]; then
  hosts_raw="$REDIS_HOSTS"
else
  hosts_raw="$REDIS_HOST"
fi

# convert commas to spaces; users should not include spaces around commas but we handle them
HOSTS=$(echo "$hosts_raw" | tr ',' ' ')

# count hosts
num_hosts=0
for _h in $HOSTS; do
  num_hosts=$((num_hosts + 1))
done

# fallback: ensure at least one host
if [ "$num_hosts" -eq 0 ]; then
  HOSTS="$REDIS_HOST"
  num_hosts=1
fi
while :; do
  try=$((try + 1))

  # choose host for this attempt (cycle through hosts for failover)
  idx=$(( (try - 1) % num_hosts + 1 ))
  cur=0
  chosen_host=""
  for h in $HOSTS; do
    cur=$((cur + 1))
    if [ "$cur" -eq "$idx" ]; then
      chosen_host=$h
      break
    fi
  done

  echo "Attempt ${try}/${RETRIES}: checking key '$KEY' on host '${chosen_host}' (db=${REDIS_DB})" >&2

  # Execute redis-cli and capture stdout (value) and stderr (err) into a temp file to report diagnostics
  tmperr=$(mktemp /tmp/redis_err.XXXXXX 2>/dev/null || printf '/tmp/redis_err.%s' "$$")
  if [ -n "$REDIS_PASSWORD" ]; then
    value=$(redis-cli -h "$chosen_host" -p "$REDIS_PORT" -a "$REDIS_PASSWORD" -n "$REDIS_DB" GET "$KEY" 2>"$tmperr")
    rc=$?
  else
    value=$(redis-cli -h "$chosen_host" -p "$REDIS_PORT" -n "$REDIS_DB" GET "$KEY" 2>"$tmperr")
    rc=$?
  fi
  err=$(cat "$tmperr" 2>/dev/null || printf '')
  rm -f "$tmperr" 2>/dev/null || true

  # normalize to empty string if redis returned (nil)
  value=${value:-}

  if [ "$rc" -ne 0 ]; then
    # Provide richer diagnostics to help debugging network/auth errors
    echo "Attempt ${try}/${RETRIES}: redis-cli failed on host='${chosen_host}' port=${REDIS_PORT} db=${REDIS_DB} rc=${rc}" >&2
    if [ -n "$err" ]; then
      echo "redis-cli stderr: $err" >&2
    else
      echo "redis-cli produced no stderr output." >&2
    fi
  else
    if [ "$value" = "$EXPECTED" ]; then
      echo "MATCH: key '$KEY' has expected value." >&2
      exit 0
    else
      echo "Attempt ${try}/${RETRIES}: value mismatch for key '$KEY' (got: '$value' expected: '$EXPECTED')" >&2
    fi
  fi

  if [ "$try" -ge "$RETRIES" ]; then
    echo "Giving up after ${try} attempt(s)." >&2
    exit 1
  fi

  # sleep before next retry
  # support fractional intervals in shells that support it via sleep
  sleep "$INTERVAL"
done

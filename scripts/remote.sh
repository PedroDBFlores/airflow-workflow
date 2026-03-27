#!/usr/bin/env bash
# scripts/remote.sh
# ~~~~~~~~~~~~~~~~~~
# Helper script for interacting with a remote Apache Airflow instance.
#
# Reads connection settings from the .env file in the repository root.
# Requires: curl, rsync (optional – only needed for the `sync` command).
#
# Usage (called via the Makefile):
#   scripts/remote.sh check
#   scripts/remote.sh sync
#   DAG_ID=example_kubernetes_dag scripts/remote.sh unpause
#   DAG_ID=example_kubernetes_dag scripts/remote.sh trigger
#   DAG_ID=example_kubernetes_dag scripts/remote.sh status

set -euo pipefail

# ---------------------------------------------------------------------------
# Resolve script and repository root paths
# ---------------------------------------------------------------------------
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

# ---------------------------------------------------------------------------
# Load .env from the repository root (if present)
# ---------------------------------------------------------------------------
ENV_FILE="${REPO_ROOT}/.env"
if [[ -f "${ENV_FILE}" ]]; then
  # Export only non-empty, non-comment lines
  set -o allexport
  # shellcheck disable=SC1090
  source <(grep -E '^[A-Za-z_][A-Za-z0-9_]*=' "${ENV_FILE}" | grep -v '^#')
  set +o allexport
fi

# ---------------------------------------------------------------------------
# Required settings
# ---------------------------------------------------------------------------
AIRFLOW_REMOTE_URL="${AIRFLOW_REMOTE_URL:-}"
AIRFLOW_REMOTE_USERNAME="${AIRFLOW_REMOTE_USERNAME:-}"
AIRFLOW_REMOTE_PASSWORD="${AIRFLOW_REMOTE_PASSWORD:-}"

# Optional SSH settings (only required for the `sync` command)
AIRFLOW_REMOTE_SSH_HOST="${AIRFLOW_REMOTE_SSH_HOST:-}"
AIRFLOW_REMOTE_SSH_USER="${AIRFLOW_REMOTE_SSH_USER:-ubuntu}"
AIRFLOW_REMOTE_SSH_KEY="${AIRFLOW_REMOTE_SSH_KEY:-${HOME}/.ssh/id_rsa}"
AIRFLOW_REMOTE_DAG_FOLDER="${AIRFLOW_REMOTE_DAG_FOLDER:-/opt/airflow/dags}"

# DAG_ID can be overridden from the environment (the Makefile passes it)
DAG_ID="${DAG_ID:-example_kubernetes_dag}"

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------
_check_required_vars() {
  local missing=0
  for var in AIRFLOW_REMOTE_URL AIRFLOW_REMOTE_USERNAME AIRFLOW_REMOTE_PASSWORD; do
    if [[ -z "${!var}" ]]; then
      echo "ERROR: ${var} is not set. Edit .env and set a value for it." >&2
      missing=1
    fi
  done
  [[ ${missing} -eq 0 ]] || exit 1
}

# Perform an Airflow REST API call.
# Usage: _api <METHOD> <PATH> [curl extra args …]
_api() {
  local method="$1"
  local path="$2"
  shift 2
  curl --silent --show-error --fail \
    --user "${AIRFLOW_REMOTE_USERNAME}:${AIRFLOW_REMOTE_PASSWORD}" \
    --header "Content-Type: application/json" \
    --request "${method}" \
    "${AIRFLOW_REMOTE_URL}/api/v1${path}" \
    "$@"
}

# ---------------------------------------------------------------------------
# Commands
# ---------------------------------------------------------------------------

cmd_check() {
  _check_required_vars
  echo "Checking connectivity to ${AIRFLOW_REMOTE_URL} …"
  local response
  response=$(_api GET /health)
  echo "${response}" | python3 -m json.tool 2>/dev/null || echo "${response}"
  echo ""
  echo "Connection successful."
}

cmd_sync() {
  if [[ -z "${AIRFLOW_REMOTE_SSH_HOST}" ]]; then
    echo "AIRFLOW_REMOTE_SSH_HOST is not set – skipping rsync." >&2
    echo "Set AIRFLOW_REMOTE_SSH_HOST in .env to enable DAG sync over SSH." >&2
    exit 1
  fi

  local src="${REPO_ROOT}/dags/"
  local dest="${AIRFLOW_REMOTE_SSH_USER}@${AIRFLOW_REMOTE_SSH_HOST}:${AIRFLOW_REMOTE_DAG_FOLDER}/"

  echo "Syncing ${src} → ${dest} …"
  rsync --archive --verbose --compress \
    --exclude '__pycache__/' \
    --exclude '*.pyc' \
    -e "ssh -i ${AIRFLOW_REMOTE_SSH_KEY} -o StrictHostKeyChecking=accept-new" \
    "${src}" "${dest}"
  echo "Sync complete."
}

cmd_unpause() {
  _check_required_vars
  echo "Unpausing DAG '${DAG_ID}' on ${AIRFLOW_REMOTE_URL} …"
  local response
  response=$(_api PATCH "/dags/${DAG_ID}" \
    --data '{"is_paused": false}')
  echo "${response}" | python3 -m json.tool 2>/dev/null || echo "${response}"
}

cmd_trigger() {
  _check_required_vars
  echo "Triggering DAG '${DAG_ID}' on ${AIRFLOW_REMOTE_URL} …"
  local logical_date
  logical_date="$(date -u +"%Y-%m-%dT%H:%M:%SZ")"
  local response
  response=$(_api POST "/dags/${DAG_ID}/dagRuns" \
    --data "{\"logical_date\": \"${logical_date}\"}")
  echo "${response}" | python3 -m json.tool 2>/dev/null || echo "${response}"
}

cmd_status() {
  _check_required_vars
  echo "Recent DAG runs for '${DAG_ID}' on ${AIRFLOW_REMOTE_URL} …"
  local response
  response=$(_api GET "/dags/${DAG_ID}/dagRuns?order_by=-logical_date&limit=5")
  echo "${response}" | python3 -m json.tool 2>/dev/null || echo "${response}"
}

# ---------------------------------------------------------------------------
# Dispatch
# ---------------------------------------------------------------------------
COMMAND="${1:-help}"

case "${COMMAND}" in
  check)    cmd_check ;;
  sync)     cmd_sync ;;
  unpause)  cmd_unpause ;;
  trigger)  cmd_trigger ;;
  status)   cmd_status ;;
  help|*)
    echo "Usage: $(basename "$0") <command>"
    echo ""
    echo "Commands:"
    echo "  check    Verify connectivity to the remote Airflow instance"
    echo "  sync     Rsync DAG files to the remote host over SSH"
    echo "  unpause  Unpause a DAG (set DAG_ID env var to override the default)"
    echo "  trigger  Trigger a DAG run  (set DAG_ID env var to override the default)"
    echo "  status   Show the last 5 DAG runs (set DAG_ID env var to override)"
    echo ""
    echo "Connection settings are read from .env in the repository root."
    ;;
esac

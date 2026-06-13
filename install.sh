#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "${SCRIPT_DIR}"

ENV_FILES="${ENV_FILES:-env/release.env env/10-db.env env/20-storage.env env/30-platform.env}"
STACK_FILES="${STACK_FILES:-stack/00-foundation.yml stack/10-db.yml stack/20-storage.yml stack/30-platform.yml}"
STACK_NAME="${STACK_NAME:-os7}"

usage() {
  cat <<USAGE
Usage: ./install.sh

Create missing deploy env files from examples, ensure Docker Swarm is active,
and validate the production stack configuration.

Environment:
  ENV_FILES     Space-separated env files to load.
  STACK_FILES   Space-separated stack files to validate.
  STACK_NAME    Docker Swarm stack name. Default: os7.
USAGE
}

if [[ "${1:-}" == "-h" || "${1:-}" == "--help" ]]; then
  usage
  exit 0
fi

if ! command -v docker >/dev/null 2>&1; then
  echo "Docker is required before installing deploy configuration." >&2
  exit 1
fi

swarm_state="$(docker info --format '{{.Swarm.LocalNodeState}}' 2>/dev/null || true)"
if [[ "${swarm_state}" != "active" ]]; then
  docker swarm init >/dev/null
fi

for file in ${ENV_FILES}; do
  if [[ -f "${file}" ]]; then
    continue
  fi

  if [[ -f "${file}.example" ]]; then
    cp "${file}.example" "${file}"
    echo "Created ${file} from ${file}.example"
    continue
  fi

  echo "Missing required env file: ${file}" >&2
  exit 1
done

set -a
for file in ${ENV_FILES}; do
  # shellcheck disable=SC1090
  . "./${file}"
done
set +a

stack_args=()
for file in ${STACK_FILES}; do
  stack_args+=("-c" "${file}")
done

STACK_NAME="${STACK_NAME}" docker stack config "${stack_args[@]}" >/dev/null

cat <<DONE
Deploy configuration is installed and valid.

Next:
  1. Edit secrets/domains in deploy/env/*.env.
  2. Run: make up
DONE

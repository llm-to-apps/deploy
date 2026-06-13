#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "${SCRIPT_DIR}"

ENV_FILES="${ENV_FILES:-env/release.env env/10-db.env env/20-storage.env env/30-platform.env}"
STACK_FILES="${STACK_FILES:-stack/00-foundation.yml stack/10-db.yml stack/20-storage.yml stack/30-platform.yml}"
STACK_NAME="${STACK_NAME:-os7}"
POSTGRES_SERVICE="${STACK_NAME}_postgres"
POSTGRES_READY_TIMEOUT_SECONDS="${POSTGRES_READY_TIMEOUT_SECONDS:-120}"

usage() {
  cat <<USAGE
Usage: ./install.sh

Create missing deploy env files from examples, ensure Docker Swarm is active,
generate local secrets when placeholders are still present, require initialized
database services, create missing databases, and validate the production stack
configuration.

Environment:
  ENV_FILES     Space-separated env files to load.
  STACK_FILES   Space-separated stack files to validate.
  STACK_NAME    Docker Swarm stack name. Default: os7.
  POSTGRES_READY_TIMEOUT_SECONDS
                Seconds to wait for PostgreSQL readiness. Default: 120.
USAGE
}

random_secret() {
  if command -v openssl >/dev/null 2>&1; then
    openssl rand -hex 32
    return
  fi

  LC_ALL=C tr -dc 'a-f0-9' </dev/urandom | head -c 64
}

env_value() {
  local file="$1"
  local key="$2"

  grep -E "^${key}=" "${file}" | tail -n 1 | cut -d '=' -f 2- || true
}

set_env_value() {
  local file="$1"
  local key="$2"
  local value="$3"
  local tmp

  tmp="$(mktemp)"

  if grep -qE "^${key}=" "${file}"; then
    awk -v key="${key}" -v value="${value}" '
      BEGIN { replaced = 0 }
      $0 ~ "^" key "=" {
        if (!replaced) {
          print key "=" value
          replaced = 1
        }
        next
      }
      { print }
    ' "${file}" > "${tmp}"
  else
    cat "${file}" > "${tmp}"
    printf '\n%s=%s\n' "${key}" "${value}" >> "${tmp}"
  fi

  mv "${tmp}" "${file}"
}

is_placeholder_value() {
  local value="$1"

  [[ -z "${value}" || "${value}" == change-me* || "${value}" == sk-or-v1-change-me ]]
}

ensure_secret() {
  local file="$1"
  local key="$2"
  local current

  current="$(env_value "${file}" "${key}")"

  if ! is_placeholder_value "${current}"; then
    return
  fi

  set_env_value "${file}" "${key}" "$(random_secret)"
  echo "Generated ${key} in ${file}"
}

generate_secrets() {
  ensure_secret env/10-db.env POSTGRES_PASSWORD
  ensure_secret env/10-db.env MYSQL_ROOT_PASSWORD
  ensure_secret env/20-storage.env FORGEJO_POSTGRES_PASSWORD
  ensure_secret env/20-storage.env FORGEJO_SECRET_KEY
  ensure_secret env/20-storage.env FORGEJO_INTERNAL_TOKEN
  ensure_secret env/20-storage.env FORGEJO_ADMIN_PASSWORD
  ensure_secret env/30-platform.env AUTH_SECRET
}

postgres_container_id() {
  docker ps \
    --filter "label=com.docker.swarm.service.name=${POSTGRES_SERVICE}" \
    --format '{{.ID}}' \
    | head -n 1
}

require_postgres_service() {
  if docker service inspect "${POSTGRES_SERVICE}" >/dev/null 2>&1; then
    return
  fi

  cat >&2 <<MSG
Database services are not initialized yet.

Run:
  make init

Then re-run:
  ./install.sh
MSG
  exit 2
}

wait_for_postgres() {
  local container_id=""
  local deadline=$((SECONDS + POSTGRES_READY_TIMEOUT_SECONDS))

  while (( SECONDS < deadline )); do
    container_id="$(postgres_container_id)"

    if [[ -n "${container_id}" ]] &&
      docker exec "${container_id}" pg_isready --username "${POSTGRES_USER:-os7}" --dbname postgres >/dev/null 2>&1; then
      printf '%s\n' "${container_id}"
      return
    fi

    sleep 2
  done

  cat >&2 <<MSG
PostgreSQL service exists, but it did not become ready within ${POSTGRES_READY_TIMEOUT_SECONDS}s.

Check:
  docker service ps ${POSTGRES_SERVICE}
  docker service logs ${POSTGRES_SERVICE}
MSG
  exit 1
}

sql_literal() {
  printf "%s" "$1" | sed "s/'/''/g"
}

sql_identifier() {
  printf "%s" "$1" | sed 's/"/""/g'
}

ensure_postgres_databases() {
  local container_id

  require_postgres_service
  container_id="$(wait_for_postgres)"

  local postgres_user="${POSTGRES_USER:-os7}"
  local postgres_db="${POSTGRES_DATABASE:-os7_platform}"
  local forgejo_db="${FORGEJO_POSTGRES_DATABASE:-forgejo}"
  local forgejo_user="${FORGEJO_POSTGRES_USER:-forgejo}"
  local forgejo_password="${FORGEJO_POSTGRES_PASSWORD}"

  docker exec -i "${container_id}" psql \
    -q \
    -v ON_ERROR_STOP=1 \
    --username "${postgres_user}" \
    --dbname postgres >/dev/null <<SQL
SELECT pg_advisory_lock(77007001);

SELECT 'CREATE DATABASE "$(sql_identifier "${postgres_db}")"'
WHERE NOT EXISTS (
  SELECT FROM pg_database WHERE datname = '$(sql_literal "${postgres_db}")'
)\\gexec

DO
\$do\$
BEGIN
  IF NOT EXISTS (
    SELECT FROM pg_catalog.pg_roles WHERE rolname = '$(sql_literal "${forgejo_user}")'
  ) THEN
    CREATE ROLE "$(sql_identifier "${forgejo_user}")" LOGIN PASSWORD '$(sql_literal "${forgejo_password}")';
  END IF;
END
\$do\$;

SELECT 'CREATE DATABASE "$(sql_identifier "${forgejo_db}")" OWNER "$(sql_identifier "${forgejo_user}")"'
WHERE NOT EXISTS (
  SELECT FROM pg_database WHERE datname = '$(sql_literal "${forgejo_db}")'
)\\gexec

GRANT ALL PRIVILEGES ON DATABASE "$(sql_identifier "${forgejo_db}")" TO "$(sql_identifier "${forgejo_user}")";

SELECT pg_advisory_unlock(77007001);
SQL

  echo "PostgreSQL databases are ready."
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

generate_secrets

set -a
for file in ${ENV_FILES}; do
  # shellcheck disable=SC1090
  . "./${file}"
done
set +a

ensure_postgres_databases

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

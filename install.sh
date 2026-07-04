#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "${SCRIPT_DIR}"

DEPLOY_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
ENV_FILES="${ENV_FILES:-env/release.env env/10-db.env env/20-storage.env env/30-platform.env}"
STACK_FILES="${STACK_FILES:-stack/00-foundation.yml stack/10-db.yml stack/20-storage.yml stack/30-platform.yml}"
STACK_NAME="${STACK_NAME:-os7}"
POSTGRES_SERVICE="${STACK_NAME}_postgres"
POSTGRES_READY_TIMEOUT_SECONDS="${POSTGRES_READY_TIMEOUT_SECONDS:-120}"
MANAGER_READY_TIMEOUT_SECONDS="${MANAGER_READY_TIMEOUT_SECONDS:-180}"
DEPLOY_USER="${DEPLOY_USER:-deploy}"
DEPLOY_GROUP="${DEPLOY_GROUP:-devops}"
POSTGRES_INIT_SCRIPT="${POSTGRES_INIT_SCRIPT:-${DEPLOY_ROOT}/docker/postgres/init-forgejo-db.sh}"
FORGEJO_BOOTSTRAP_SCRIPT="${FORGEJO_BOOTSTRAP_SCRIPT:-${DEPLOY_ROOT}/docker/forgejo/bootstrap.sh}"

usage() {
  cat <<USAGE
Usage: ./install.sh [--bootstrap-storage-only|--ensure-env-only]

Create missing deploy env files from examples, ensure Docker Swarm is active,
generate local secrets when placeholders are still present, require initialized
database services, create missing databases, and validate the production stack
configuration.

With --ensure-env-only, create missing env files from examples, append newly
introduced keys from examples, and generate missing local secrets without
touching Docker, PostgreSQL, or object storage.

With --bootstrap-storage-only, call the internal manager API to create the
shared web SeaweedFS bucket and scoped credentials, then write them to
env/30-platform.env.

Environment:
  ENV_FILES     Space-separated env files to load.
  STACK_FILES   Space-separated stack files to validate.
  STACK_NAME    Docker Swarm stack name. Default: os7.
  DEPLOY_USER   Server deploy user to create. Default: deploy.
  DEPLOY_GROUP  Server deploy group to create. Default: devops.
  POSTGRES_INIT_SCRIPT
                Host path mounted into PostgreSQL for one-time Forgejo DB
                bootstrap. Default: ../docker/postgres/init-forgejo-db.sh.
  FORGEJO_BOOTSTRAP_SCRIPT
                Host path mounted into Forgejo for startup admin bootstrap.
                Default: ../docker/forgejo/bootstrap.sh.
  POSTGRES_READY_TIMEOUT_SECONDS
                Seconds to wait for PostgreSQL readiness. Default: 120.
  MANAGER_READY_TIMEOUT_SECONDS
                Seconds to wait for manager readiness during storage bootstrap.
                Default: 180.
USAGE
}

require_command() {
  local command_name="$1"
  local install_hint="$2"

  if command -v "${command_name}" >/dev/null 2>&1; then
    return
  fi

  echo "${command_name} is required before installing deploy configuration." >&2
  if [[ -n "${install_hint}" ]]; then
    echo "${install_hint}" >&2
  fi
  exit 1
}

require_root_access() {
  if [[ "${EUID}" -eq 0 ]]; then
    return
  fi

  if ! command -v sudo >/dev/null 2>&1; then
    echo "Root privileges or sudo are required to create the deploy user." >&2
    exit 1
  fi

  sudo -v
}

as_root() {
  if [[ "${EUID}" -eq 0 ]]; then
    "$@"
    return
  fi

  sudo "$@"
}

random_secret() {
  if command -v openssl >/dev/null 2>&1; then
    openssl rand -hex 32
    return
  fi

  LC_ALL=C tr -dc 'a-f0-9' </dev/urandom | head -c 64
}

random_base64_secret() {
  if command -v openssl >/dev/null 2>&1; then
    openssl rand -base64 32
    return
  fi

  LC_ALL=C tr -dc 'A-Za-z0-9+/=' </dev/urandom | head -c 44
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

ensure_base64_secret() {
  local file="$1"
  local key="$2"
  local current

  current="$(env_value "${file}" "${key}")"

  if ! is_placeholder_value "${current}"; then
    return
  fi

  set_env_value "${file}" "${key}" "$(random_base64_secret)"
  echo "Generated ${key} in ${file}"
}

ensure_env_defaults() {
  local file="$1"
  local example="${file}.example"
  local line
  local key

  if [[ ! -f "${example}" ]]; then
    return
  fi

  while IFS= read -r line || [[ -n "${line}" ]]; do
    if [[ ! "${line}" =~ ^[A-Za-z_][A-Za-z0-9_]*= ]]; then
      continue
    fi

    key="${line%%=*}"

    if grep -qE "^${key}=" "${file}"; then
      continue
    fi

    printf '\n%s\n' "${line}" >> "${file}"
    echo "Added ${key} to ${file} from ${example}"
  done < "${example}"
}

ensure_env_files() {
  local file

  for file in ${ENV_FILES}; do
    if [[ ! -f "${file}" ]]; then
      if [[ -f "${file}.example" ]]; then
        cp "${file}.example" "${file}"
        echo "Created ${file} from ${file}.example"
      else
        echo "Missing required env file: ${file}" >&2
        exit 1
      fi
    fi

    ensure_env_defaults "${file}"
  done
}

generate_secrets() {
  ensure_secret env/10-db.env POSTGRES_PASSWORD
  ensure_secret env/10-db.env MYSQL_ROOT_PASSWORD
  ensure_secret env/20-storage.env FORGEJO_POSTGRES_PASSWORD
  ensure_secret env/20-storage.env FORGEJO_SECRET_KEY
  ensure_secret env/20-storage.env FORGEJO_INTERNAL_TOKEN
  ensure_secret env/20-storage.env FORGEJO_ADMIN_PASSWORD
  ensure_secret env/20-storage.env SEAWEEDFS_POSTGRES_PASSWORD
  ensure_secret env/20-storage.env SEAWEEDFS_S3_ACCESS_KEY
  ensure_secret env/20-storage.env SEAWEEDFS_S3_SECRET_KEY
  ensure_base64_secret env/20-storage.env SEAWEEDFS_IAM_SIGNING_KEY
  ensure_secret env/10-db.env CANVAS_POSTGRES_PASSWORD
  ensure_secret env/30-platform.env AUTH_SECRET
  ensure_secret env/30-platform.env CANVAS_INTERNAL_TOKEN
}

ensure_postgres_init_script() {
  local init_dir
  local tmp

  init_dir="$(dirname "${POSTGRES_INIT_SCRIPT}")"
  require_root_access

  if [[ -f "${POSTGRES_INIT_SCRIPT}" ]]; then
    echo "PostgreSQL init script already exists at ${POSTGRES_INIT_SCRIPT}."
    return
  fi

  as_root mkdir -p "${init_dir}"

  tmp="$(mktemp)"
  cat > "${tmp}" <<'SCRIPT'
#!/usr/bin/env bash
set -euo pipefail

psql -v ON_ERROR_STOP=1 --username "${POSTGRES_USER}" --dbname postgres <<SQL
DO
\$do\$
BEGIN
  IF NOT EXISTS (
    SELECT FROM pg_catalog.pg_roles WHERE rolname = '${FORGEJO_POSTGRES_USER:-forgejo}'
  ) THEN
    CREATE ROLE "${FORGEJO_POSTGRES_USER:-forgejo}" LOGIN PASSWORD '${FORGEJO_POSTGRES_PASSWORD}';
  END IF;
END
\$do\$;

SELECT 'CREATE DATABASE "${FORGEJO_POSTGRES_DATABASE:-forgejo}" OWNER "${FORGEJO_POSTGRES_USER:-forgejo}"'
WHERE NOT EXISTS (
  SELECT FROM pg_database WHERE datname = '${FORGEJO_POSTGRES_DATABASE:-forgejo}'
)\gexec

GRANT ALL PRIVILEGES ON DATABASE "${FORGEJO_POSTGRES_DATABASE:-forgejo}" TO "${FORGEJO_POSTGRES_USER:-forgejo}";

DO
\$do\$
BEGIN
  IF NOT EXISTS (
    SELECT FROM pg_catalog.pg_roles WHERE rolname = '${SEAWEEDFS_POSTGRES_USER:-seaweedfs}'
  ) THEN
    CREATE ROLE "${SEAWEEDFS_POSTGRES_USER:-seaweedfs}" LOGIN PASSWORD '${SEAWEEDFS_POSTGRES_PASSWORD}';
  END IF;
END
\$do\$;

SELECT 'CREATE DATABASE "${SEAWEEDFS_POSTGRES_DATABASE:-seaweedfs}" OWNER "${SEAWEEDFS_POSTGRES_USER:-seaweedfs}"'
WHERE NOT EXISTS (
  SELECT FROM pg_database WHERE datname = '${SEAWEEDFS_POSTGRES_DATABASE:-seaweedfs}'
)\gexec

GRANT ALL PRIVILEGES ON DATABASE "${SEAWEEDFS_POSTGRES_DATABASE:-seaweedfs}" TO "${SEAWEEDFS_POSTGRES_USER:-seaweedfs}";

DO
\$do\$
BEGIN
  IF NOT EXISTS (
    SELECT FROM pg_catalog.pg_roles WHERE rolname = '${CANVAS_POSTGRES_USER:-canvas}'
  ) THEN
    CREATE ROLE "${CANVAS_POSTGRES_USER:-canvas}" LOGIN PASSWORD '${CANVAS_POSTGRES_PASSWORD}';
  END IF;
END
\$do\$;

SELECT 'CREATE DATABASE "${CANVAS_POSTGRES_DATABASE:-canvas}" OWNER "${CANVAS_POSTGRES_USER:-canvas}"'
WHERE NOT EXISTS (
  SELECT FROM pg_database WHERE datname = '${CANVAS_POSTGRES_DATABASE:-canvas}'
)\gexec

GRANT ALL PRIVILEGES ON DATABASE "${CANVAS_POSTGRES_DATABASE:-canvas}" TO "${CANVAS_POSTGRES_USER:-canvas}";
SQL

psql -v ON_ERROR_STOP=1 --username "${POSTGRES_USER}" --dbname "${SEAWEEDFS_POSTGRES_DATABASE:-seaweedfs}" <<SQL
CREATE TABLE IF NOT EXISTS filemeta (
  dirhash BIGINT,
  name VARCHAR(65535) COLLATE "C",
  directory VARCHAR(65535),
  meta bytea,
  PRIMARY KEY (dirhash, name)
);
ALTER TABLE filemeta
  ALTER COLUMN name TYPE VARCHAR(65535) COLLATE "C";
GRANT ALL PRIVILEGES ON TABLE filemeta TO "${SEAWEEDFS_POSTGRES_USER:-seaweedfs}";
SQL
SCRIPT

  as_root install -m 0755 -o root -g root "${tmp}" "${POSTGRES_INIT_SCRIPT}"
  rm -f "${tmp}"
  echo "Created PostgreSQL init script at ${POSTGRES_INIT_SCRIPT}."
}

ensure_forgejo_bootstrap_script() {
  local bootstrap_dir
  local tmp

  bootstrap_dir="$(dirname "${FORGEJO_BOOTSTRAP_SCRIPT}")"
  require_root_access

  as_root mkdir -p "${bootstrap_dir}"

  tmp="$(mktemp)"
  cat > "${tmp}" <<'SCRIPT'
#!/usr/bin/env bash
set -euo pipefail

/usr/bin/entrypoint "$@" &
forgejo_pid="$!"

gitea_admin() {
  /sbin/su-exec git /usr/local/bin/gitea admin "$@"
}

finish() {
  kill -TERM "$forgejo_pid" 2>/dev/null || true
  wait "$forgejo_pid" 2>/dev/null || true
}

trap finish TERM INT

for _ in $(seq 1 120); do
  if gitea_admin user list >/dev/null 2>&1; then
    break
  fi

  if ! kill -0 "$forgejo_pid" 2>/dev/null; then
    wait "$forgejo_pid"
    exit $?
  fi

  sleep 1
done

admin_user="${FORGEJO_ADMIN_USER:-root}"
admin_password="${FORGEJO_ADMIN_PASSWORD:-admin1234}"
admin_email="${FORGEJO_ADMIN_EMAIL:-root@example.local}"

if gitea_admin user list | awk 'NR > 1 {print $2}' | grep -Fxq "$admin_user"; then
  gitea_admin user change-password \
    --username "$admin_user" \
    --password "$admin_password" \
    --must-change-password=false
else
  gitea_admin user create \
    --admin \
    --username "$admin_user" \
    --password "$admin_password" \
    --email "$admin_email" \
    --must-change-password=false
fi

wait "$forgejo_pid"
SCRIPT

  if [[ -f "${FORGEJO_BOOTSTRAP_SCRIPT}" ]] && cmp -s "${tmp}" "${FORGEJO_BOOTSTRAP_SCRIPT}"; then
    echo "Forgejo bootstrap script is up to date at ${FORGEJO_BOOTSTRAP_SCRIPT}."
    rm -f "${tmp}"
    return
  fi

  as_root install -m 0755 -o root -g root "${tmp}" "${FORGEJO_BOOTSTRAP_SCRIPT}"
  rm -f "${tmp}"
  echo "Installed Forgejo bootstrap script at ${FORGEJO_BOOTSTRAP_SCRIPT}."
}

ensure_deploy_user() {
  local sudoers_file="/etc/sudoers.d/os7-${DEPLOY_USER}"
  local sudoers_rule="%${DEPLOY_GROUP} ALL=(ALL) NOPASSWD:ALL"
  local current_shell

  require_root_access

  if getent group "${DEPLOY_GROUP}" >/dev/null; then
    echo "Group ${DEPLOY_GROUP} already exists."
  else
    as_root groupadd "${DEPLOY_GROUP}"
    echo "Created group ${DEPLOY_GROUP}."
  fi

  if id -u "${DEPLOY_USER}" >/dev/null 2>&1; then
    echo "User ${DEPLOY_USER} already exists."
  else
    as_root useradd --create-home --shell /bin/bash --gid "${DEPLOY_GROUP}" "${DEPLOY_USER}"
    echo "Created user ${DEPLOY_USER}."
  fi

  if id -nG "${DEPLOY_USER}" | tr ' ' '\n' | grep -qx "${DEPLOY_GROUP}"; then
    echo "User ${DEPLOY_USER} is already in group ${DEPLOY_GROUP}."
  else
    as_root usermod --append --groups "${DEPLOY_GROUP}" "${DEPLOY_USER}"
    echo "Added user ${DEPLOY_USER} to group ${DEPLOY_GROUP}."
  fi

  current_shell="$(getent passwd "${DEPLOY_USER}" | cut -d ':' -f 7)"
  if [[ "${current_shell}" != "/bin/bash" ]]; then
    as_root usermod --shell /bin/bash "${DEPLOY_USER}"
    echo "Set /bin/bash shell for user ${DEPLOY_USER}."
  fi

  if [[ -f "${sudoers_file}" ]] && as_root grep -qxF "${sudoers_rule}" "${sudoers_file}"; then
    echo "Sudo rights for group ${DEPLOY_GROUP} are already configured."
    return
  fi

  local tmp
  tmp="$(mktemp)"
  printf '%s\n' "${sudoers_rule}" > "${tmp}"

  if ! as_root visudo -cf "${tmp}" >/dev/null; then
    rm -f "${tmp}"
    echo "Generated sudoers rule is invalid." >&2
    exit 1
  fi

  as_root install -m 0440 -o root -g root "${tmp}" "${sudoers_file}"
  rm -f "${tmp}"
  echo "Configured passwordless sudo for group ${DEPLOY_GROUP}."
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
  sudo apt install -y make   # if make is not installed yet
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
  local seaweedfs_db="${SEAWEEDFS_POSTGRES_DATABASE:-seaweedfs}"
  local seaweedfs_user="${SEAWEEDFS_POSTGRES_USER:-seaweedfs}"
  local seaweedfs_password="${SEAWEEDFS_POSTGRES_PASSWORD}"
  local canvas_db="${CANVAS_POSTGRES_DATABASE:-canvas}"
  local canvas_user="${CANVAS_POSTGRES_USER:-canvas}"
  local canvas_password="${CANVAS_POSTGRES_PASSWORD}"

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

DO
\$do\$
BEGIN
  IF NOT EXISTS (
    SELECT FROM pg_catalog.pg_roles WHERE rolname = '$(sql_literal "${seaweedfs_user}")'
  ) THEN
    CREATE ROLE "$(sql_identifier "${seaweedfs_user}")" LOGIN PASSWORD '$(sql_literal "${seaweedfs_password}")';
  END IF;
END
\$do\$;

SELECT 'CREATE DATABASE "$(sql_identifier "${seaweedfs_db}")" OWNER "$(sql_identifier "${seaweedfs_user}")"'
WHERE NOT EXISTS (
  SELECT FROM pg_database WHERE datname = '$(sql_literal "${seaweedfs_db}")'
)\\gexec

GRANT ALL PRIVILEGES ON DATABASE "$(sql_identifier "${seaweedfs_db}")" TO "$(sql_identifier "${seaweedfs_user}")";

DO
\$do\$
BEGIN
  IF NOT EXISTS (
    SELECT FROM pg_catalog.pg_roles WHERE rolname = '$(sql_literal "${canvas_user}")'
  ) THEN
    CREATE ROLE "$(sql_identifier "${canvas_user}")" LOGIN PASSWORD '$(sql_literal "${canvas_password}")';
  END IF;
END
\$do\$;

SELECT 'CREATE DATABASE "$(sql_identifier "${canvas_db}")" OWNER "$(sql_identifier "${canvas_user}")"'
WHERE NOT EXISTS (
  SELECT FROM pg_database WHERE datname = '$(sql_literal "${canvas_db}")'
)\\gexec

GRANT ALL PRIVILEGES ON DATABASE "$(sql_identifier "${canvas_db}")" TO "$(sql_identifier "${canvas_user}")";

SELECT pg_advisory_unlock(77007001);
SQL

  docker exec -i "${container_id}" psql \
    -q \
    -v ON_ERROR_STOP=1 \
    --username "${postgres_user}" \
    --dbname "${seaweedfs_db}" >/dev/null <<SQL
CREATE TABLE IF NOT EXISTS filemeta (
  dirhash BIGINT,
  name VARCHAR(65535) COLLATE "C",
  directory VARCHAR(65535),
  meta bytea,
  PRIMARY KEY (dirhash, name)
);
ALTER TABLE filemeta
  ALTER COLUMN name TYPE VARCHAR(65535) COLLATE "C";
GRANT ALL PRIVILEGES ON TABLE filemeta TO "$(sql_identifier "${seaweedfs_user}")";
SQL

  echo "PostgreSQL databases are ready."
}

if [[ "${1:-}" == "-h" || "${1:-}" == "--help" ]]; then
  usage
  exit 0
fi

require_command docker "On Ubuntu, install it with: sudo apt install -y docker.io docker-compose-v2 docker-buildx"
require_command jq "On Ubuntu, install it with: sudo apt install -y jq"

manager_service_name() {
  printf '%s_manager' "${STACK_NAME}"
}

wait_for_manager_http() {
  local deadline=$((SECONDS + MANAGER_READY_TIMEOUT_SECONDS))

  while (( SECONDS < deadline )); do
    if docker run --rm \
      --network "${STACK_NAME}_internal" \
      curlimages/curl:8.11.1 \
      -fsS "http://manager/health" >/dev/null 2>&1; then
      return
    fi

    sleep 3
  done

  cat >&2 <<MSG
Manager service exists, but it did not become ready within ${MANAGER_READY_TIMEOUT_SECONDS}s.

Check:
  docker service ps $(manager_service_name)
  docker service logs $(manager_service_name)
MSG
  exit 1
}

bootstrap_platform_storage() {
  if ! docker service inspect "$(manager_service_name)" >/dev/null 2>&1; then
    cat >&2 <<MSG
Manager is not deployed yet, so storage credentials cannot be bootstrapped.

Run:
  make up

Then re-run:
  ./install.sh --bootstrap-storage-only
MSG
    return 2
  fi

  wait_for_manager_http

  bootstrap_storage_bucket \
    "web" \
    "$(env_value env/30-platform.env STORAGE_S3_BUCKET)" \
    "${STORAGE_WEB_IAM_USER:-web-platform}" \
    "STORAGE_S3_BUCKET" \
    "STORAGE_S3_ACCESS_KEY_ID" \
    "STORAGE_S3_SECRET_ACCESS_KEY" \
    "os7-web"

  bootstrap_storage_bucket \
    "Canvas" \
    "$(env_value env/30-platform.env CANVAS_S3_BUCKET)" \
    "${STORAGE_CANVAS_IAM_USER:-canvas-runtime}" \
    "CANVAS_S3_BUCKET" \
    "CANVAS_S3_ACCESS_KEY_ID" \
    "CANVAS_S3_SECRET_ACCESS_KEY" \
    "os7-canvas"
}

bootstrap_storage_bucket() {
  local label="$1"
  local bucket="$2"
  local user="$3"
  local bucket_env_key="$4"
  local access_env_key="$5"
  local secret_env_key="$6"
  local fallback_bucket="$7"
  local response
  local access_key
  local secret_key

  bucket="${bucket:-${fallback_bucket}}"

  echo "Bootstrapping ${label} SeaweedFS bucket ${bucket} through manager."

  response="$(
    docker run --rm \
      --network "${STACK_NAME}_internal" \
      curlimages/curl:8.11.1 \
      -fsS \
      -X POST "http://manager/storage/platform-bucket" \
      -H 'Accept: application/json' \
      -H 'Content-Type: application/json' \
      -d "{\"bucket\":\"${bucket}\",\"user\":\"${user}\"}"
  )"

  access_key="$(jq -r '.accessKeyId // empty' <<<"${response}")"
  secret_key="$(jq -r '.secretAccessKey // empty' <<<"${response}")"

  if [[ -z "${access_key}" || -z "${secret_key}" ]]; then
    echo "Manager did not return ${label} SeaweedFS credentials." >&2
    echo "${response}" >&2
    exit 1
  fi

  set_env_value env/30-platform.env "${bucket_env_key}" "${bucket}"
  set_env_value env/30-platform.env "${access_env_key}" "${access_key}"
  set_env_value env/30-platform.env "${secret_env_key}" "${secret_key}"

  echo "Stored scoped ${label} SeaweedFS credentials in env/30-platform.env."
}

if [[ "${1:-}" == "--ensure-env-only" ]]; then
  ensure_env_files
  generate_secrets
  echo "Deploy env files are present and contain current defaults."
  exit 0
fi

if [[ "${1:-}" == "--bootstrap-storage-only" ]]; then
  ensure_env_files

  set -a
  for file in ${ENV_FILES}; do
    # shellcheck disable=SC1090
    . "./${file}"
  done
  set +a

  bootstrap_platform_storage
  exit 0
fi

ensure_deploy_user

swarm_state="$(docker info --format '{{.Swarm.LocalNodeState}}' 2>/dev/null || true)"
if [[ "${swarm_state}" != "active" ]]; then
  docker swarm init >/dev/null
fi

ensure_env_files

generate_secrets
ensure_postgres_init_script
ensure_forgejo_bootstrap_script

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

bootstrap_platform_storage || true

cat <<DONE
Deploy configuration is installed and valid.

Next:
  1. Edit secrets/domains in deploy/env/*.env.
  2. Run: make up
  3. If web storage was bootstrapped after manager started, run: make up
DONE

#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

ENV_FILE="${ENV_FILE:-${REPO_ROOT}/env/release.env}"
ENV_EXAMPLE_FILE="${ENV_EXAMPLE_FILE:-${REPO_ROOT}/env/release.env.example}"
MANAGER_REPO="${MANAGER_REPO:-os7/manager}"
GITHUB_API_URL="${GITHUB_API_URL:-https://api.github.com}"
TAG_PATTERN="${TAG_PATTERN:-^v?[0-9]+(\\.[0-9]+)*$}"
DRY_RUN=false

usage() {
  cat <<USAGE
Usage: ./update.sh [options]

Fetch the latest platform Git tag from GitHub and write it to platform image tags.

Options:
  --env-file PATH       Env file to update. Default: env/release.env
  --env-example-file PATH
                        Env example file to copy when --env-file does not exist.
                        Default: env/release.env.example
  --repo OWNER/REPO     GitHub repo to read tags from. Default: os7/manager
  --tag-pattern REGEX   Tag filter regex. Default: ^v?[0-9]+(\\.[0-9]+)*$
  --dry-run             Print the chosen tag without changing files.
  -h, --help            Show this help.

Environment:
  GITHUB_TOKEN          Optional token for private repos or higher rate limits.
  GITHUB_API_URL        Optional GitHub API base URL.
USAGE
}

set_env_value() {
  local file="$1"
  local key="$2"
  local value="$3"

  if grep -q "^${key}=" "${file}"; then
    sed -i.bak "s/^${key}=.*/${key}=${value}/" "${file}"
  else
    printf '\n%s=%s\n' "${key}" "${value}" >> "${file}"
  fi
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --env-file)
      ENV_FILE="$2"
      shift 2
      ;;
    --env-example-file)
      ENV_EXAMPLE_FILE="$2"
      shift 2
      ;;
    --repo)
      MANAGER_REPO="$2"
      shift 2
      ;;
    --tag-pattern)
      TAG_PATTERN="$2"
      shift 2
      ;;
    --dry-run)
      DRY_RUN=true
      shift
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      echo "Unknown argument: $1" >&2
      usage >&2
      exit 2
      ;;
  esac
done

fetch_tags() {
  local headers=(
    -H "Accept: application/vnd.github+json"
    -H "X-GitHub-Api-Version: 2022-11-28"
  )

  if [[ -n "${GITHUB_TOKEN:-}" ]]; then
    headers+=(-H "Authorization: Bearer ${GITHUB_TOKEN}")
  fi

  curl -fsSL "${headers[@]}" \
    "${GITHUB_API_URL}/repos/${MANAGER_REPO}/tags?per_page=100"
}

tags_json="$(fetch_tags)"

latest_tag="$(printf '%s' "${tags_json}" \
  | sed -n 's/.*"name"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' \
  | grep -E "${TAG_PATTERN}" \
  | sort -V \
  | tail -n 1 \
  || true)"

if [[ -z "${latest_tag}" ]]; then
  echo "No GitHub tags matched TAG_PATTERN=${TAG_PATTERN} in ${MANAGER_REPO}" >&2
  exit 1
fi

if [[ "${DRY_RUN}" == "true" ]]; then
  echo "${latest_tag}"
  exit 0
fi

if [[ ! -f "${ENV_FILE}" ]]; then
  if [[ -f "${ENV_EXAMPLE_FILE}" ]]; then
    cp "${ENV_EXAMPLE_FILE}" "${ENV_FILE}"
  else
    touch "${ENV_FILE}"
  fi
fi

set_env_value "${ENV_FILE}" "MANAGER_IMAGE_TAG" "${latest_tag}"
set_env_value "${ENV_FILE}" "SITE_IMAGE_TAG" "${latest_tag}"
set_env_value "${ENV_FILE}" "WEB_IMAGE_TAG" "${latest_tag}"
set_env_value "${ENV_FILE}" "AGENT_IMAGE_TAG" "${latest_tag}"

rm -f "${ENV_FILE}.bak"

echo "Updated ${ENV_FILE}: MANAGER_IMAGE_TAG=${latest_tag}, SITE_IMAGE_TAG=${latest_tag}, WEB_IMAGE_TAG=${latest_tag}, AGENT_IMAGE_TAG=${latest_tag}"

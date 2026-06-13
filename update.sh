#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

ENV_FILE="${ENV_FILE:-${REPO_ROOT}/env/release.env}"
ENV_EXAMPLE_FILE="${ENV_EXAMPLE_FILE:-${REPO_ROOT}/env/release.env.example}"
GITHUB_API_URL="${GITHUB_API_URL:-https://api.github.com}"
GITHUB_OWNER="${GITHUB_OWNER:-llm-to-apps}"
GHCR_OWNER="${GHCR_OWNER:-${GITHUB_OWNER}}"
BRANCH="${BRANCH:-main}"
SHORT_SHA_LENGTH="${SHORT_SHA_LENGTH:-7}"
VERIFY_IMAGE_TAGS="${VERIFY_IMAGE_TAGS:-true}"

MANAGER_REPO="${MANAGER_REPO:-${GITHUB_OWNER}/manager}"
WEB_REPO="${WEB_REPO:-${GITHUB_OWNER}/web}"
SITE_REPO="${SITE_REPO:-${GITHUB_OWNER}/site}"
AGENT_REPO="${AGENT_REPO:-${GITHUB_OWNER}/agent}"

DRY_RUN=false

usage() {
  cat <<USAGE
Usage: ./update.sh [options]

Resolve the latest successful main-branch image tag for each platform service and
write pinned sha-* tags to env/release.env.

Options:
  --env-file PATH          Env file to update. Default: env/release.env
  --env-example-file PATH  Env example file to copy when --env-file does not exist.
  --github-owner OWNER     GitHub owner for default repos. Default: llm-to-apps
  --ghcr-owner OWNER       GHCR owner for image tag verification. Default: GitHub owner
  --branch BRANCH          Branch to inspect. Default: main
  --manager-repo OWNER/REPO
  --web-repo OWNER/REPO
  --site-repo OWNER/REPO
  --agent-repo OWNER/REPO
  --skip-verify           Do not verify that resolved tags exist in GHCR.
  --dry-run               Print resolved tags without changing files.
  -h, --help              Show this help.

Environment:
  GITHUB_TOKEN             Optional token for private repos or higher rate limits.
  GITHUB_API_URL           Optional GitHub API base URL.
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

github_headers() {
  printf '%s\n' \
    -H "Accept: application/vnd.github+json" \
    -H "X-GitHub-Api-Version: 2022-11-28"

  if [[ -n "${GITHUB_TOKEN:-}" ]]; then
    printf '%s\n' -H "Authorization: Bearer ${GITHUB_TOKEN}"
  fi
}

fetch_latest_success_sha() {
  local repo="$1"
  local headers=()

  while IFS= read -r header; do
    headers+=("${header}")
  done < <(github_headers)

  curl -fsSL "${headers[@]}" \
    "${GITHUB_API_URL}/repos/${repo}/actions/runs?branch=${BRANCH}&status=success&event=push&per_page=20" \
    | sed -n 's/.*"head_sha"[[:space:]]*:[[:space:]]*"\([0-9a-f]\{40\}\)".*/\1/p' \
    | head -n 1
}

ghcr_token() {
  local package="$1"
  curl -fsSL "https://ghcr.io/token?service=ghcr.io&scope=repository:${GHCR_OWNER}/${package}:pull" \
    | sed -n 's/.*"token"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p'
}

verify_ghcr_tag() {
  local package="$1"
  local tag="$2"
  local token

  token="$(ghcr_token "${package}")"

  if [[ -z "${token}" ]]; then
    echo "Failed to obtain GHCR token for ${GHCR_OWNER}/${package}" >&2
    return 1
  fi

  curl -fsSI \
    -H "Authorization: Bearer ${token}" \
    -H "Accept: application/vnd.oci.image.index.v1+json, application/vnd.docker.distribution.manifest.v2+json" \
    "https://ghcr.io/v2/${GHCR_OWNER}/${package}/manifests/${tag}" >/dev/null
}

resolve_tag() {
  local name="$1"
  local repo="$2"
  local package="$3"
  local sha
  local tag

  sha="$(fetch_latest_success_sha "${repo}")"

  if [[ -z "${sha}" ]]; then
    echo "No successful push workflow run found for ${repo} on branch ${BRANCH}" >&2
    exit 1
  fi

  tag="sha-${sha:0:${SHORT_SHA_LENGTH}}"

  if [[ "${VERIFY_IMAGE_TAGS}" == "true" ]]; then
    if ! verify_ghcr_tag "${package}" "${tag}"; then
      echo "Resolved ${name} tag ${tag}, but ghcr.io/${GHCR_OWNER}/${package}:${tag} was not found" >&2
      exit 1
    fi
  fi

  printf '%s\n' "${tag}"
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
    --github-owner)
      GITHUB_OWNER="$2"
      MANAGER_REPO="${GITHUB_OWNER}/manager"
      WEB_REPO="${GITHUB_OWNER}/web"
      SITE_REPO="${GITHUB_OWNER}/site"
      AGENT_REPO="${GITHUB_OWNER}/agent"
      GHCR_OWNER="${GITHUB_OWNER}"
      shift 2
      ;;
    --ghcr-owner)
      GHCR_OWNER="$2"
      shift 2
      ;;
    --branch)
      BRANCH="$2"
      shift 2
      ;;
    --manager-repo)
      MANAGER_REPO="$2"
      shift 2
      ;;
    --web-repo)
      WEB_REPO="$2"
      shift 2
      ;;
    --site-repo)
      SITE_REPO="$2"
      shift 2
      ;;
    --agent-repo)
      AGENT_REPO="$2"
      shift 2
      ;;
    --skip-verify)
      VERIFY_IMAGE_TAGS=false
      shift
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

manager_tag="$(resolve_tag "manager" "${MANAGER_REPO}" "manager")"
web_tag="$(resolve_tag "web" "${WEB_REPO}" "web")"
site_tag="$(resolve_tag "site" "${SITE_REPO}" "site")"
agent_tag="$(resolve_tag "agent" "${AGENT_REPO}" "agent")"

if [[ "${DRY_RUN}" == "true" ]]; then
  printf 'MANAGER_IMAGE_TAG=%s\n' "${manager_tag}"
  printf 'WEB_IMAGE_TAG=%s\n' "${web_tag}"
  printf 'SITE_IMAGE_TAG=%s\n' "${site_tag}"
  printf 'AGENT_IMAGE_TAG=%s\n' "${agent_tag}"
  exit 0
fi

if [[ ! -f "${ENV_FILE}" ]]; then
  if [[ -f "${ENV_EXAMPLE_FILE}" ]]; then
    cp "${ENV_EXAMPLE_FILE}" "${ENV_FILE}"
  else
    touch "${ENV_FILE}"
  fi
fi

set_env_value "${ENV_FILE}" "MANAGER_IMAGE_TAG" "${manager_tag}"
set_env_value "${ENV_FILE}" "WEB_IMAGE_TAG" "${web_tag}"
set_env_value "${ENV_FILE}" "SITE_IMAGE_TAG" "${site_tag}"
set_env_value "${ENV_FILE}" "AGENT_IMAGE_TAG" "${agent_tag}"

rm -f "${ENV_FILE}.bak"

cat <<RESULT
Updated ${ENV_FILE}:
  MANAGER_IMAGE_TAG=${manager_tag}
  WEB_IMAGE_TAG=${web_tag}
  SITE_IMAGE_TAG=${site_tag}
  AGENT_IMAGE_TAG=${agent_tag}
RESULT

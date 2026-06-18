# Production Server

This document describes the current OS7 production deployment and the normal way
to deliver changes to it.

## Host

- SSH alias: `os7`
- Deploy path: `/opt/os7/deploy`
- Stack name: `os7`
- Public domains:
  - platform: `https://os7.dev/`
  - site: `https://www.os7.dev/`
  - git storage: `https://git.os7.dev/`

Cloudflare terminates HTTPS. The server exposes HTTP only on port `80`, and
Traefik routes requests to internal services. Production HTTP services must
listen inside their containers on port `80`.

## Repositories

GitHub owner is `llm-to-apps`.

Main runtime repositories:

- `llm-to-apps/deploy`
- `llm-to-apps/manager`
- `llm-to-apps/web`
- `llm-to-apps/site`
- `llm-to-apps/agent`

Images are published to GHCR under the same owner:

- `ghcr.io/llm-to-apps/manager`
- `ghcr.io/llm-to-apps/web`
- `ghcr.io/llm-to-apps/site`
- `ghcr.io/llm-to-apps/agent`

Do not use the old `os7` GitHub/GHCR namespace for production deploy.

## Stack Layout

The production stack is Docker Swarm, assembled from:

- `stack/00-foundation.yml`: networks and volumes
- `stack/10-db.yml`: PostgreSQL, MySQL, Redis
- `stack/20-storage.yml`: Forgejo, SeaweedFS
- `stack/30-platform.yml`: Traefik, site, manager, web, worker, agent

Environment files:

- `env/release.env`: image names and pinned image tags
- `env/10-db.env`: database settings and resources
- `env/20-storage.env`: Forgejo and SeaweedFS settings, metadata database settings, and secrets
- `env/30-platform.env`: domains, auth, URLs, model settings, service resources

`env/*.env` are server-local configuration files. Preserve their secrets and do
not overwrite them from examples.

## Services

The stack currently runs:

- `os7_traefik`: public HTTP entrypoint on host port `80`
- `os7_site`: public marketing site, routed by `SITE_DOMAIN`
- `os7_web`: main platform UI/API, routed by `PLATFORM_DOMAIN`
- `os7_worker`: background jobs from the web image
- `os7_manager`: Swarm/project service manager
- `os7_agent`: Mastra agent runtime
- `os7_forgejo`: Git storage
- `os7_seaweedfs`: SeaweedFS 4.34 S3-compatible object storage, internal endpoint `http://seaweedfs:8333`, PostgreSQL-backed filer metadata, writable embedded IAM, `leveldbMedium` volume indexes, shared web bucket from `STORAGE_S3_BUCKET`
- `os7_manager`: the only platform service with SeaweedFS admin credentials; it provisions the shared web bucket credentials and per-project bucket credentials.
- `os7_postgres`: platform and Mastra database
- `os7_mysql`: customer app databases
- `os7_redis`: queues

Traefik routes to platform services on internal container port `80`.

## Delivery Flow

Normal delivery is:

1. Push application changes to the relevant repository.
2. Wait for GitHub Actions to build and publish the GHCR image.
3. SSH to the server.
4. Pull the latest deploy repo.
5. Run `make update`.

Commands:

```bash
ssh os7
cd /opt/os7/deploy
git pull --ff-only
make update
```

`make update` runs `update.sh`, pulls images, and redeploys the stack.
Use this path for normal production delivery so service images stay pinned.

`update.sh` does not use `latest` for platform services. It resolves the latest
successful `push` workflow on `main` for each service repository, verifies that
the matching GHCR tag exists, and writes pinned `sha-*` tags to
`env/release.env`.

Do not run `docker stack deploy` directly without loading `env/release.env`; the
stack defaults can fall back to `latest`. Use `make up` when redeploying the
current pinned release without changing tags.

Current tag keys managed by `update.sh`:

- `MANAGER_IMAGE_TAG`
- `WEB_IMAGE_TAG`
- `SITE_IMAGE_TAG`
- `AGENT_IMAGE_TAG`

Preview the tag update without changing files:

```bash
./update.sh --dry-run
```

Use a GitHub token only when needed for private access or API rate limits:

```bash
GITHUB_TOKEN=github_pat_... make update
```

## Application Template Manifest Updates

Application templates are registered in the platform database table
`app_templates`. Do not hand-edit template manifests in production. Use the web
CLI so manifests are fetched, validated, diffed, and written with the same
`ApiResponse`/manifest contract used by the platform.

Template repositories should publish an update source in `manifest.json`:

```json
{
  "updates": {
    "github": {
      "repository": "llm-to-apps/money-template",
      "ref": "main",
      "path": "manifest.json"
    }
  }
}
```

The template release flow is:

1. Build and publish the new template image.
2. Update the template repository `manifest.json` with the new image and any
   runtime/env changes.
3. Push the template repository.
4. Deploy the latest web image if the production web CLI has changed.
5. Run the template update CLI from a running `os7_web` container.

Get a running web container:

```bash
WEB_CONTAINER="$(docker ps --filter name=os7_web -q | head -n1)"
```

Preview available manifest updates:

```bash
docker exec -it "$WEB_CONTAINER" npm run cli -- templates check-updates
```

Apply all detected updates:

```bash
docker exec -it "$WEB_CONTAINER" npm run cli -- templates check-updates --apply
```

Update one template from its configured update source:

```bash
docker exec -it "$WEB_CONTAINER" npm run cli -- templates update money
```

Update one template from an explicit manifest URL:

```bash
docker exec -it "$WEB_CONTAINER" npm run cli -- templates update money \
  --manifest-url https://raw.githubusercontent.com/llm-to-apps/money-template/main/manifest.json
```

Notes:

- `local:*` manifests are intentionally skipped unless an explicit
  `--manifest-url` is provided.
- Pinned CDN URLs such as `cdn.jsdelivr.net/gh/...@<commit>/manifest.json` do
  not move by themselves. The CLI needs `updates.github` in the stored manifest,
  or an explicit `--manifest-url`.
- The manifest is the source of truth for the template image. Do not infer image
  versions from GHCR tags by hand.
- The CLI updates only future installs. Existing deployed projects keep their
  current image/runtime until project-level upgrade tooling exists.

## Manual Commands

Check services:

```bash
make status
docker stack services os7
docker stack ps os7
```

Deploy the current env and stack without changing image tags:

```bash
make up
```

Pull images listed in the current env files without changing tags:

```bash
make pull
```

Check a public route through the local Traefik entrypoint:

```bash
curl -I http://127.0.0.1/ -H 'Host: os7.dev'
curl -I http://127.0.0.1/ -H 'Host: www.os7.dev'
curl -I http://127.0.0.1/ -H 'Host: git.os7.dev'
```

## Rollout Notes

- `site` uses `start-first` Swarm updates and has an HTTP healthcheck.
- Other services should be changed carefully if zero-downtime rollout is needed.
- Do not manually build production images on the server.
- Do not hand-edit image tags for normal deploys. Use `make update`.
- Never deploy platform services with `latest` in production. Keep
  `env/release.env` pinned to explicit `sha-*` tags.
- Do not change Traefik service ports away from `80`.
- If an image is missing, fix CI/CD for that repository and wait for GHCR.
- If deploy behavior is unclear or risky, stop and ask the architect.

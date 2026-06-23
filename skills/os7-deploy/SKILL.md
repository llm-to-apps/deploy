---
name: os7-deploy
description: Use when deploying or updating all OS7 production components, including manager, web, worker, templates, template manifests, and existing app services. Covers the safe end-to-end release flow with GitHub Actions, GHCR sha tags, server make update, template registry updates, and post-deploy health checks.
---

# OS7 Deploy

Use this skill for full OS7 production updates: platform services, app templates, and existing deployed app services. Do not use it for ordinary local development or one-off local container rebuilds.

## Hard Rules

- Read `deploy/AGENT.md` and the relevant sections of `deploy/SERVER.md` before production actions.
- Production platform services must use pinned `sha-*` image tags from `deploy/env/release.env`.
- Do not deploy platform services with `latest`.
- Do not run raw `docker stack deploy` for normal delivery. Use the existing server flow.
- Do not hand-edit production template rows in the database. Use the web CLI.
- Preserve server secrets, env files, volumes, databases, buckets, and user app data.
- If CI, image publication, server update, or health checks fail, stop and inspect exact state before retrying.

## Repositories

The workspace is a multi-repository checkout. Treat each nested repo separately:

- `manager` -> `ghcr.io/llm-to-apps/manager`
- `web` -> `ghcr.io/llm-to-apps/web` and production `worker`
- `site` -> `ghcr.io/llm-to-apps/site`
- `agent` -> `ghcr.io/llm-to-apps/agent`
- `templates/gpt-card-template` -> `ghcr.io/llm-to-apps/gpt-card-template`
- `templates/money` -> `ghcr.io/llm-to-apps/money-template`
- `templates/money/ui-kit` may be a submodule and must be committed/pushed before committing the parent template pointer.
- `deploy` contains production stack scripts and server runbooks.

Always check dirty state per repo with `git -C <repo> status -sb`.

## Local Preflight

Before pushing, run relevant checks in each changed repo.

Manager:

```bash
cd manager
npm run typecheck
```

Web:

```bash
cd web
npm run format:check
npm run lint
npm run typecheck
npm run worker:build
npm run build
```

Templates:

```bash
cd templates/gpt-card-template
npm run format:check
npm run lint
npm run typecheck
npm run build

cd templates/money
npm run format:check
npm run lint
npm run typecheck
```

If `web` build needs environment values, use the same safe local placeholders already used by CI or the repo scripts. Do not use production secrets locally.

## Commit And Push

Commit each nested repo independently. Do not mix unrelated repos in one commit.

Typical order:

1. Submodules such as `templates/money/ui-kit`.
2. Templates that depend on those submodules.
3. `manager`.
4. `web`.
5. Other changed platform repos, if any.

Push to `main` only after local checks pass.

## Wait For CI And GHCR

After push, wait for GitHub Actions on the relevant repositories.

Useful command:

```bash
gh run list -R llm-to-apps/<repo> --branch main --limit 3 \
  --json databaseId,headSha,status,conclusion,workflowName,displayTitle,url
```

Do not deploy a repo until its latest `main` run completed successfully.

Verify template image tags exist before pinning manifests:

```bash
docker manifest inspect ghcr.io/llm-to-apps/gpt-card-template:sha-<commit>
docker manifest inspect ghcr.io/llm-to-apps/money-template:sha-<commit>
```

## Template Two-Step Release

Template `manifest.json` is the source of truth for future installs. Template CI publishes an image tagged with the commit SHA. Therefore template releases usually need two commits:

1. Code commit: template source changes. CI publishes `sha-<code_commit>`.
2. Pin commit: update `manifest.json` `image` to the new `sha-<code_commit>`.

Do not change `manifest.dev.json` production image pins; dev manifests may intentionally point to local `:dev` images.

After the pin commit is pushed, no new template image is needed for the pin commit itself unless source code changed again.

## Server Platform Update

Use the documented server flow:

```bash
ssh os7
cd /opt/os7/deploy
git pull --ff-only
make update
```

`make update` resolves latest successful platform image tags, writes pinned tags to `env/release.env`, pulls images, and redeploys the stack.

Expected platform images after update should include the pushed `sha-*` tags for changed platform repos, for example:

- `os7_manager`: `ghcr.io/llm-to-apps/manager:sha-...`
- `os7_web`: `ghcr.io/llm-to-apps/web:sha-...`
- `os7_worker`: `ghcr.io/llm-to-apps/web:sha-...`

## Template Registry Update

After the latest `web` image is running, update production template registry from a running `os7_web` container:

```bash
WEB_CONTAINER="$(docker ps --filter name=os7_web -q | head -n1)"
docker exec "$WEB_CONTAINER" npm run cli -- templates check-updates --apply
docker exec "$WEB_CONTAINER" npm run cli -- templates check-updates
```

The second command should report no remaining template updates.

## Existing App Services

Template registry updates affect future installs only. Existing deployed app services keep their current image until updated separately.

List existing app services:

```bash
docker service ls --format "table {{.Name}}\t{{.Image}}\t{{.Replicas}}" | grep -E "^(NAME|app-)"
```

Inspect rollout mode:

```bash
docker service inspect app-... \
  --format 'image={{.Spec.TaskTemplate.ContainerSpec.Image}} update={{.Spec.UpdateConfig.Order}} rollback={{.Spec.RollbackConfig.Order}} replicas={{.Spec.Mode.Replicated.Replicas}}'
```

For an explicit user/app update, use `start-first`:

```bash
docker service update \
  --image ghcr.io/llm-to-apps/<template-image>:sha-<commit> \
  --update-order start-first \
  --rollback-order start-first \
  app-...
```

Wait for convergence before continuing. Temporary `2/1` or `3/2` replica counts can be normal during `start-first` rollout.

## Post-Deploy Checks

Check Swarm:

```bash
cd /opt/os7/deploy
make status
docker stack services os7
docker stack ps os7
```

Check externally reachable endpoints:

```bash
curl -fsSIL --max-time 15 https://os7.dev/api/health
curl -fsSIL --max-time 15 https://www.os7.dev/
curl -fsSIL --max-time 15 https://<app-domain>/api/health
curl -fsSIL --max-time 15 https://<app-dev-domain>/api/health
```

Report:

- pushed commits per repo;
- CI status;
- deployed platform image tags;
- template registry update result;
- existing app service image/order status;
- health check results;
- any old failed Swarm tasks that predate this deploy and are not current regressions.

## Symlink Install

For local Codex discovery, symlink this file into the Codex skills folder:

```bash
mkdir -p ~/.codex/skills/os7-deploy
ln -sf /Users/anton/projects/orchestra/deploy/skills/os7-deploy/SKILL.md \
  ~/.codex/skills/os7-deploy/SKILL.md
```


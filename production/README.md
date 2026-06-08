# Production Deploy

This folder contains the production Docker Compose entrypoint for the LLAgents runtime host.

The Compose stack starts:

- Traefik reverse proxy
- LLAgents manager
- MySQL

The manager then creates user application instances as Docker Swarm services through the Docker Engine API.

## Server bootstrap

Run these commands on the production Docker host:

```bash
docker swarm init
docker network create --driver overlay --attachable llagents_public
docker network create --driver overlay --attachable llagents_internal
```

Copy the environment example and edit secrets/domains:

```bash
cp deploy/production/.env.example deploy/production/.env
```

Start production services:

```bash
docker compose --env-file deploy/production/.env -f deploy/production/docker-compose.yml up -d --build
```

Update the manager image tag from the latest GitHub tag:

```bash
deploy/scripts/update-manager-image-tag.sh
```

This expects the manager repo to have release tags such as `v0.1.0`.

For private repos or higher GitHub API rate limits, provide:

```bash
GITHUB_TOKEN=github_pat_... deploy/scripts/update-manager-image-tag.sh
```

Check manager health:

```bash
docker compose --env-file deploy/production/.env -f deploy/production/docker-compose.yml exec manager wget -qO- http://localhost:8080/health
```

## Important notes

- The manager mounts `/var/run/docker.sock`, so treat it as root-level cluster control.
- Do not expose the manager publicly.
- User app services should join both `llagents_public` and `llagents_internal`.
- Traefik uses the Swarm provider and reads labels from Swarm services.
- Keep `llagents_public` and `llagents_internal` as attachable overlay networks so Compose services and Swarm services can share them.

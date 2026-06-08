# Production Deploy

This repository contains the production Docker Compose entrypoint for the LLAgents runtime host.

The Compose stack starts:

- Traefik reverse proxy
- LLAgents manager
- MySQL

The manager then creates user application instances as Docker Swarm services through the Docker Engine API.

## Server Bootstrap

Run these commands on the production Docker host:

```bash
docker swarm init
docker network create --driver overlay --attachable llagents_public
docker network create --driver overlay --attachable llagents_internal
```

Copy the environment example and edit secrets/domains:

```bash
cp .env.example .env
```

Start production services:

```bash
make up
```

Update the manager to the latest GitHub tag:

```bash
make update
```

This expects the manager repo to have release tags such as `v0.1.0`.

For private repos or higher GitHub API rate limits, provide:

```bash
GITHUB_TOKEN=github_pat_... make update
```

Check manager health:

```bash
docker compose --env-file .env -f docker-compose.yml exec manager wget -qO- http://localhost:8080/health
```

## Important Notes

- The manager mounts `/var/run/docker.sock`, so treat it as root-level cluster control.
- Do not expose the manager publicly.
- User app services should join both `llagents_public` and `llagents_internal`.
- Traefik uses the Swarm provider and reads labels from Swarm services.
- Cloudflare terminates TLS, so Traefik only exposes HTTP on port 80.
- Keep `llagents_public` and `llagents_internal` as attachable overlay networks so Compose services and Swarm services can share them.

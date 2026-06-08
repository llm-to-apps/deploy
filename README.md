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
make ensure-networks
```

Copy the environment example and edit secrets/domains:

```bash
cp .env.example .env
```

`MYSQL_ROOT_USER` is used by the manager to connect to MySQL. With the official `mysql` image, keep it as `root` unless you also change the database image/bootstrap.

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
- MySQL runs in `llagents_db`.
- Traefik and user app services join `llagents_ingress`.
- Web-facing internal platform services use `llagents_internal`.
- Traefik uses the Swarm provider and reads labels from Swarm services.
- Cloudflare terminates TLS, so Traefik only exposes HTTP on port 80.
- Keep `llagents_db` and `llagents_ingress` attachable so Compose services and Swarm services can share them.

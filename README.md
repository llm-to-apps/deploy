# Production Deploy

This repository contains the production Docker Swarm entrypoint for the OS7 runtime host.

The stack is assembled from component files in `deploy/stack`:

- `00-foundation.yml` for shared networks and volumes
- `10-db.yml` for PostgreSQL, MySQL, and Redis
- `20-storage.yml` for Forgejo-backed Git storage
- `30-platform.yml` for Traefik, site, manager, web, worker, and agent

Environment is split into component files in `deploy/env`:

- `release.env` for image names and tags shared by the whole release
- `10-db.env` for PostgreSQL, MySQL, Redis, and their resources
- `20-storage.env` for Forgejo, its database bootstrap, secrets, and resources
- `30-platform.env` for public domains, auth, Traefik, site, manager, web, worker, agent, model provider settings, and their resources

Together they start:

- Traefik reverse proxy
- OS7 public site
- OS7 manager
- OS7 web and worker
- OS7 agent
- PostgreSQL for platform data and Mastra memory
- MySQL for customer application databases
- Redis for queues
- Forgejo for per-project Git repositories

The manager also creates user application instances as Docker Swarm services through the Docker Engine API.

## Server Bootstrap

Run these commands on the production Docker host:

```bash
sudo apt install -y docker.io docker-compose-v2 docker-buildx make
docker swarm init
```

Install local deploy configuration files from examples and validate the stack:

```bash
./install.sh
```

`install.sh` also prepares the server deploy identity:

- creates the `devops` group when it is missing
- creates the `deploy` user when it is missing
- adds `deploy` to `devops`
- grants passwordless sudo to the `devops` group through `/etc/sudoers.d/os7-deploy`
- creates the PostgreSQL host init script mounted by `stack/10-db.yml`

Override the defaults with `DEPLOY_USER=...` and `DEPLOY_GROUP=...` when needed.
Override the PostgreSQL init script location with `POSTGRES_INIT_SCRIPT=...` when the stack mount path changes.

If database services are not initialized yet, start only the foundation and database stack:

```bash
make init
./install.sh
```

Then edit secrets/domains in `deploy/env/*.env` before starting the full platform.
`install.sh` generates local passwords and tokens only when values are empty or still use `change-me...` placeholders. Existing values are left untouched.
When the PostgreSQL service is running, `install.sh` ensures the platform and Forgejo databases exist.

`MYSQL_ROOT_USER` is used by the manager to connect to MySQL. With the official `mysql` image, keep it as `root` unless you also change the database image/bootstrap.
`POSTGRES_*` is used by web, worker, and agent for platform state and Mastra Memory.

Start production services:

```bash
make up
```

`make up` loads the component env files and deploys the component stack files as a Swarm stack named `os7`.
Override the stack name with `STACK_NAME=... make up` when needed.
Override the component list with `STACK_FILES="..." make up` for advanced maintenance.
Override the environment list with `ENV_FILES="..." make up` when needed.

Update platform services:

```bash
make update
```

This updates the configured image tags and redeploys the Swarm stack.

For private repos or higher GitHub API rate limits, provide:

```bash
GITHUB_TOKEN=github_pat_... make update
```

Check manager health:

```bash
docker stack services os7
docker stack ps os7
```

## Important Notes

- The manager mounts `/var/run/docker.sock`, so treat it as root-level cluster control.
- Do not expose the manager publicly.
- PostgreSQL and MySQL run in the stack `db` network.
- MySQL is reserved for customer app databases provisioned by the manager.
- PostgreSQL stores platform data and Mastra Memory.
- Traefik and user app services join the stack `ingress` network.
- Web-facing internal platform services use the stack `internal` network.
- Traefik uses the Swarm provider and reads labels from Swarm services.
- Cloudflare terminates TLS, so Traefik only exposes HTTP on port 80.
- Keep `db` and `ingress` attachable so manager-created app services can join them.

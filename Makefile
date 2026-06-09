ENV_FILE ?= .env
COMPOSE_FILE ?= docker-compose.yml
DOCKER_COMPOSE ?= docker compose

.PHONY: update config pull up ensure-networks

update:
	./update.sh --env-file $(ENV_FILE)
	$(DOCKER_COMPOSE) --env-file $(ENV_FILE) -f $(COMPOSE_FILE) pull manager web worker agent
	$(DOCKER_COMPOSE) --env-file $(ENV_FILE) -f $(COMPOSE_FILE) up -d manager web worker agent

config:
	$(DOCKER_COMPOSE) --env-file $(ENV_FILE) -f $(COMPOSE_FILE) config

pull:
	$(DOCKER_COMPOSE) --env-file $(ENV_FILE) -f $(COMPOSE_FILE) pull

up: ensure-networks
	$(DOCKER_COMPOSE) --env-file $(ENV_FILE) -f $(COMPOSE_FILE) up -d

ensure-networks:
	@if [ ! -f "$(ENV_FILE)" ]; then cp .env.example "$(ENV_FILE)"; fi
	@set -a; . ./$(ENV_FILE); set +a; \
	for network in "$${DB_NETWORK_ID:-llagents_db}" "$${INGRESS_NETWORK_ID:-llagents_ingress}" "$${INTERNAL_NETWORK_ID:-llagents_internal}"; do \
		docker network inspect "$$network" >/dev/null 2>&1 || docker network create --driver overlay --attachable "$$network" >/dev/null; \
	done

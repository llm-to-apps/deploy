ENV_FILE ?= .env
COMPOSE_FILE ?= docker-compose.yml
DOCKER_COMPOSE ?= docker compose

.PHONY: update config pull up

update:
	./scripts/update-manager-image-tag.sh --env-file $(ENV_FILE)
	$(DOCKER_COMPOSE) --env-file $(ENV_FILE) -f $(COMPOSE_FILE) pull manager
	$(DOCKER_COMPOSE) --env-file $(ENV_FILE) -f $(COMPOSE_FILE) up -d manager

config:
	$(DOCKER_COMPOSE) --env-file $(ENV_FILE) -f $(COMPOSE_FILE) config

pull:
	$(DOCKER_COMPOSE) --env-file $(ENV_FILE) -f $(COMPOSE_FILE) pull

up:
	$(DOCKER_COMPOSE) --env-file $(ENV_FILE) -f $(COMPOSE_FILE) up -d

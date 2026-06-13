ENV_FILES ?= env/release.env env/10-db.env env/20-storage.env env/30-platform.env
IMAGE_ENV_FILE ?= env/release.env
STACK_FILES ?= stack/00-foundation.yml stack/10-db.yml stack/20-storage.yml stack/30-platform.yml
DOCKER_COMPOSE ?= docker compose
STACK_NAME ?= os7
STACK_DEPLOY_FILES := $(foreach file,$(STACK_FILES),-c $(file))
COMPOSE_FILES := $(foreach file,$(STACK_FILES),-f $(file))
LOAD_ENV = set -a; for file in $(ENV_FILES); do . ./$$file; done; set +a

.PHONY: update config pull up ensure-env services ps rm

update: ensure-env
	./update.sh --env-file $(IMAGE_ENV_FILE) --env-example-file $(IMAGE_ENV_FILE).example
	@$(LOAD_ENV); \
		$(DOCKER_COMPOSE) $(COMPOSE_FILES) pull manager site web worker agent
	@$(LOAD_ENV); STACK_NAME="$(STACK_NAME)"; export STACK_NAME; \
		docker stack deploy --with-registry-auth $(STACK_DEPLOY_FILES) $(STACK_NAME)

config: ensure-env
	@$(LOAD_ENV); STACK_NAME="$(STACK_NAME)"; export STACK_NAME; \
		docker stack config $(STACK_DEPLOY_FILES)

pull: ensure-env
	@$(LOAD_ENV); STACK_NAME="$(STACK_NAME)"; export STACK_NAME; \
		$(DOCKER_COMPOSE) $(COMPOSE_FILES) pull

up: ensure-env
	@$(LOAD_ENV); STACK_NAME="$(STACK_NAME)"; export STACK_NAME; \
		docker stack deploy --with-registry-auth $(STACK_DEPLOY_FILES) $(STACK_NAME)

services:
	docker stack services $(STACK_NAME)

ps:
	docker stack ps $(STACK_NAME)

rm:
	docker stack rm $(STACK_NAME)

ensure-env:
	@for file in $(ENV_FILES); do \
		if [ ! -f "$$file" ]; then \
			if [ -f "$$file.example" ]; then \
				cp "$$file.example" "$$file"; \
			else \
				echo "Missing required env file: $$file"; \
				exit 1; \
			fi; \
		fi; \
	done

ENV_FILES ?= env/release.env env/10-db.env env/20-storage.env env/30-platform.env
IMAGE_ENV_FILE ?= env/release.env
STACK_FILES ?= stack/00-foundation.yml stack/10-db.yml stack/20-storage.yml stack/30-platform.yml
INIT_STACK_FILES ?= stack/00-foundation.yml stack/10-db.yml
DOCKER_COMPOSE ?= docker compose
STACK_NAME ?= os7
STACK_DEPLOY_FILES := $(foreach file,$(STACK_FILES),-c $(file))
INIT_STACK_DEPLOY_FILES := $(foreach file,$(INIT_STACK_FILES),-c $(file))
COMPOSE_FILES := $(foreach file,$(STACK_FILES),-f $(file))
LOAD_ENV = set -a; for file in $(ENV_FILES); do . ./$$file; done; set +a

.PHONY: update install init pull up ensure-env status services ps ps-full rm

update: ensure-env
	./update.sh --env-file $(IMAGE_ENV_FILE) --env-example-file $(IMAGE_ENV_FILE).example
	@$(LOAD_ENV); \
		$(DOCKER_COMPOSE) $(COMPOSE_FILES) pull manager site web worker agent
	@$(LOAD_ENV); STACK_NAME="$(STACK_NAME)"; export STACK_NAME; \
		docker stack deploy --with-registry-auth $(STACK_DEPLOY_FILES) $(STACK_NAME)

install:
	./install.sh

init: ensure-env
	@$(LOAD_ENV); STACK_NAME="$(STACK_NAME)"; export STACK_NAME; \
		docker stack deploy --with-registry-auth $(INIT_STACK_DEPLOY_FILES) $(STACK_NAME)

pull: ensure-env
	@$(LOAD_ENV); STACK_NAME="$(STACK_NAME)"; export STACK_NAME; \
		$(DOCKER_COMPOSE) $(COMPOSE_FILES) pull

up: ensure-env
	@$(LOAD_ENV); STACK_NAME="$(STACK_NAME)"; export STACK_NAME; \
		docker stack deploy --with-registry-auth $(STACK_DEPLOY_FILES) $(STACK_NAME)

status:
	@echo "Services for stack $(STACK_NAME):"
	@docker stack services --format "table {{.Name}}\t{{.Image}}\t{{.Replicas}}\t{{.Ports}}" $(STACK_NAME)
	@echo
	@echo "Running tasks for stack $(STACK_NAME):"
	@docker stack ps \
		--filter desired-state=running \
		--format "table {{.Name}}\t{{.Image}}\t{{.CurrentState}}\t{{.Error}}" \
		$(STACK_NAME)
	@echo
	@echo "Recent failed tasks:"
	@docker stack ps \
		--filter desired-state=shutdown \
		--format "{{.Name}}\t{{.Image}}\t{{.CurrentState}}\t{{.Error}}" \
		$(STACK_NAME) \
		| awk 'BEGIN { found = 0 } /Failed|Rejected/ { if (!found) { print "NAME\tIMAGE\tCURRENT STATE\tERROR"; found = 1 } print } END { if (!found) print "none" }'

services:
	docker stack services $(STACK_NAME)

ps:
	docker stack ps $(STACK_NAME)

ps-full:
	docker stack ps --no-trunc $(STACK_NAME)

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

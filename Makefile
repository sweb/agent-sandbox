IMAGE     := stackable-agent-sandbox
TAG       := latest
HOST_UID  := $(shell id -u)
HOST_GID  := $(shell id -g)
HOST_USER := $(shell id -un)

BUILD_ARGS := \
	--network=host \
	--build-arg UID=$(HOST_UID) \
	--build-arg GID=$(HOST_GID) \
	--build-arg USERNAME=$(HOST_USER) \
	--label sandbox.uid=$(HOST_UID) \
	--label sandbox.gid=$(HOST_GID) \
	--label sandbox.username=$(HOST_USER) \
	-t $(IMAGE):$(TAG)

.PHONY: help build rebuild clean clean-home clean-nix size inspect shell

help: ## Show this help
	@awk 'BEGIN {FS = ":.*?## "} /^[a-zA-Z_-]+:.*?## / {printf "  \033[36m%-10s\033[0m %s\n", $$1, $$2}' $(MAKEFILE_LIST)

build: ## Build the image (Docker layer cache used; run if Dockerfile or args changed)
	docker build $(BUILD_ARGS) .

rebuild: ## Full rebuild ignoring the Docker layer cache
	docker build --no-cache $(BUILD_ARGS) .

clean: ## Remove the image
	-docker image rm $(IMAGE):$(TAG)

clean-home: ## Remove the persistent $HOME volume (forces fresh tool caches and bash history next run)
	-docker volume rm agent-sandbox-home-$(HOST_USER)

clean-nix: ## Remove the persistent /nix volume (forces nix to re-fetch closures; needed after NIX_VERSION bump)
	-docker volume rm agent-sandbox-nix-$(HOST_USER)

size: ## Print image size
	@docker image inspect $(IMAGE):$(TAG) --format '{{.Size}}' \
		| numfmt --to=iec-i --suffix=B

inspect: ## Print image labels
	@docker image inspect $(IMAGE):$(TAG) \
		--format 'tag={{index .RepoTags 0}} uid={{index .Config.Labels "sandbox.uid"}} gid={{index .Config.Labels "sandbox.gid"}} username={{index .Config.Labels "sandbox.username"}}'

shell: ## Open a bash shell in a running sandbox container (auto-detects the first one)
	@cid=$$(docker ps --filter ancestor=$(IMAGE):$(TAG) -q | head -1); \
	if [ -z "$$cid" ]; then \
		echo "no running $(IMAGE):$(TAG) container found"; exit 1; \
	fi; \
	docker exec -it "$$cid" bash

.DEFAULT_GOAL := help

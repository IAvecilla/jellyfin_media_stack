COMPOSE_CMD = docker compose -f docker-compose.yml
ifdef GPU
	COMPOSE_CMD += -f docker-compose.gpu.yml
endif

.PHONY: up down restart logs status pull setup setup-gpu configure refresh-env bootstrap help

help: ## Show available commands
	@echo "Usage: make <target> [GPU=1]"
	@echo ""
	@echo "Targets:"
	@grep -E '^[a-zA-Z_-]+:.*?## .*$$' $(MAKEFILE_LIST) | awk 'BEGIN {FS = ":.*?## "}; {printf "  %-12s %s\n", $$1, $$2}'
	@echo ""
	@echo "Examples:"
	@echo "  make up          Start all services (no GPU)"
	@echo "  make up GPU=1    Start all services with NVIDIA GPU support"

up: ## Start all services (add GPU=1 for NVIDIA support)
	$(COMPOSE_CMD) up -d

down: ## Stop and remove all services
	$(COMPOSE_CMD) down

restart: ## Restart all services
	$(COMPOSE_CMD) restart

logs: ## Show logs (use SERVICE=name to filter, e.g. make logs SERVICE=jellyfin)
	$(COMPOSE_CMD) logs -f $(SERVICE)

status: ## Show status of all services
	$(COMPOSE_CMD) ps

pull: ## Pull latest images
	$(COMPOSE_CMD) pull

configure: ## Configure running services from config.toml
	@test -f config.toml || { echo "config.toml not found. Copy config.toml.example to config.toml and edit it."; exit 1; }
	./configure.sh

refresh-env: ## Regenerate .env from config.toml without touching running services
	@test -f config.toml || { echo "config.toml not found."; exit 1; }
	./configure.sh --env-only

setup: ## Initial setup - create .env from example
	@test -f .env && echo ".env already exists, skipping" || cp .env.example .env && echo "Created .env from .env.example - edit it with your settings"

bootstrap: ## One-shot install on a fresh machine: copy config.toml, start stack, configure
	@for cmd in docker curl jq yq python3; do \
		command -v $$cmd >/dev/null 2>&1 || { echo "Error: $$cmd is required but not installed."; exit 1; }; \
	done
	@docker compose version >/dev/null 2>&1 || { echo "Error: 'docker compose' plugin is required."; exit 1; }
	@if [ ! -f config.toml ]; then \
		cp config.toml.example config.toml; \
		echo ""; \
		echo "==> Created config.toml from config.toml.example."; \
		echo "==> EDIT config.toml NOW with your VPN credentials, passwords, and indexers."; \
		echo "==> Then re-run: make bootstrap"; \
		exit 0; \
	fi
	@echo "==> Starting stack..."
	$(COMPOSE_CMD) up -d
	@echo "==> Configuring services from config.toml..."
	./configure.sh
	@echo ""
	@echo "==> Bootstrap complete."
	@echo "==> Open Homepage at http://localhost:3010"

setup-gpu: ## Install NVIDIA Container Toolkit for GPU support
	@echo "Installing NVIDIA Container Toolkit..."
	@command -v nvidia-smi >/dev/null 2>&1 || { echo "Error: NVIDIA drivers not found. Install them first."; exit 1; }
	curl -fsSL https://nvidia.github.io/libnvidia-container/gpgkey | sudo gpg --dearmor -o /usr/share/keyrings/nvidia-container-toolkit-keyring.gpg
	curl -s -L https://nvidia.github.io/libnvidia-container/stable/deb/nvidia-container-toolkit.list | \
		sed 's#deb https://#deb [signed-by=/usr/share/keyrings/nvidia-container-toolkit-keyring.gpg] https://#g' | \
		sudo tee /etc/apt/sources.list.d/nvidia-container-toolkit.list
	sudo apt-get update
	sudo apt-get install -y nvidia-container-toolkit
	sudo nvidia-ctk runtime configure --runtime=docker
	sudo systemctl restart docker
	@echo "NVIDIA Container Toolkit installed. Verify with: docker run --rm --gpus all nvidia/cuda:12.0-base nvidia-smi"

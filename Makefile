# Makefile – Apache Airflow workflow management
#
# Three deployment modes are supported:
#   1. Local Docker Compose   (docker-*)
#   2. Kubernetes             (k8s-*)
#   3. Remote Airflow instance (remote-*)
#
# Run `make help` to list all available targets.
#
# Connection settings for the remote mode are read from .env.
# Copy .env and fill in the AIRFLOW_REMOTE_* variables before using
# the remote-* targets.

-include .env
export

.DEFAULT_GOAL := help

DAG_ID ?= example_kubernetes_dag

# Colour helpers
BOLD  := \033[1m
CYAN  := \033[36m
RESET := \033[0m

# ============================================================================
# Help
# ============================================================================

.PHONY: help
help: ## Show this help message
	@echo ""
	@echo "$(BOLD)Airflow Workflow – available targets$(RESET)"
	@echo ""
	@echo "$(BOLD)Docker (local)$(RESET)"
	@grep -E '^docker[a-zA-Z_-]+:.*?## .*$$' Makefile | \
		awk 'BEGIN {FS = ":.*?## "}; {printf "  $(CYAN)%-22s$(RESET) %s\n", $$1, $$2}'
	@echo ""
	@echo "$(BOLD)Kubernetes$(RESET)"
	@grep -E '^k8s[a-zA-Z_-]+:.*?## .*$$' Makefile | \
		awk 'BEGIN {FS = ":.*?## "}; {printf "  $(CYAN)%-22s$(RESET) %s\n", $$1, $$2}'
	@echo ""
	@echo "$(BOLD)Remote Airflow instance$(RESET)"
	@grep -E '^remote[a-zA-Z_-]+:.*?## .*$$' Makefile | \
		awk 'BEGIN {FS = ":.*?## "}; {printf "  $(CYAN)%-22s$(RESET) %s\n", $$1, $$2}'
	@echo ""
	@echo "DAG_ID defaults to '$(DAG_ID)'. Override with: make <target> DAG_ID=your_dag"
	@echo ""

# ============================================================================
# Docker targets (local development)
# ============================================================================

.PHONY: docker-up
docker-up: ## Start the local Airflow stack (detached)
	docker compose up -d

.PHONY: docker-down
docker-down: ## Stop the local Airflow stack (keep volumes)
	docker compose down

.PHONY: docker-destroy
docker-destroy: ## Stop the local stack and remove all volumes
	docker compose down -v

.PHONY: docker-logs
docker-logs: ## Follow logs from all containers
	docker compose logs -f

.PHONY: docker-ps
docker-ps: ## Show status of local Docker containers
	docker compose ps

# ============================================================================
# Kubernetes targets
# ============================================================================

.PHONY: k8s-deploy
k8s-deploy: ## Deploy Airflow to Kubernetes (applies all manifests in order)
	kubectl apply -f kubernetes/namespace.yaml
	kubectl apply -f kubernetes/rbac.yaml
	kubectl apply -f kubernetes/secrets.yaml
	kubectl apply -f kubernetes/configmap.yaml
	kubectl apply -f kubernetes/postgres.yaml
	kubectl apply -f kubernetes/airflow.yaml

.PHONY: k8s-teardown
k8s-teardown: ## Remove all Airflow Kubernetes resources
	kubectl delete -f kubernetes/ --ignore-not-found

.PHONY: k8s-status
k8s-status: ## Show pod and service status in the airflow namespace
	kubectl get pods,svc -n airflow

.PHONY: k8s-forward
k8s-forward: ## Port-forward the webserver to http://localhost:8080
	kubectl port-forward svc/airflow-webserver 8080:8080 -n airflow

.PHONY: k8s-logs-scheduler
k8s-logs-scheduler: ## Follow the scheduler logs
	kubectl logs -f deployment/airflow-scheduler -n airflow

.PHONY: k8s-logs-webserver
k8s-logs-webserver: ## Follow the webserver logs
	kubectl logs -f deployment/airflow-webserver -n airflow

# ============================================================================
# Remote Airflow targets
# ============================================================================

.PHONY: remote-check
remote-check: ## Check connectivity to the remote Airflow instance
	@bash scripts/remote.sh check

.PHONY: remote-sync
remote-sync: ## Sync DAG files to the remote host over SSH (requires AIRFLOW_REMOTE_SSH_HOST)
	@bash scripts/remote.sh sync

.PHONY: remote-unpause
remote-unpause: ## Unpause DAG_ID on the remote Airflow instance
	@DAG_ID=$(DAG_ID) bash scripts/remote.sh unpause

.PHONY: remote-trigger
remote-trigger: ## Trigger a run of DAG_ID on the remote Airflow instance
	@DAG_ID=$(DAG_ID) bash scripts/remote.sh trigger

.PHONY: remote-status
remote-status: ## Show the last 5 runs of DAG_ID on the remote Airflow instance
	@DAG_ID=$(DAG_ID) bash scripts/remote.sh status

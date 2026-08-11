.PHONY: up down toolbox-up toolbox-down cluster-up cluster-down rebuild


# ==========================================
# 🏗️ TOOLBOX & CLUSTER LIFECYCLE
# ==========================================

up: cluster-up ## Start up the entire project

down: ## Delete the entire project
	@bash cluster_down.sh

toolbox-up: ## Start the containerized k8s-toolbox
	@cd k8s && $(DOCKER) compose up -d --build

toolbox-down: ## Tear down the k8s-toolbox
	@cd k8s && $(DOCKER) compose down

cluster-up: ## Deploy from UPSTREAM (production-like)
	@echo "🚀 Deploying from UPSTREAM (production-like)..."
	@bash cluster_up.sh

cluster-up-%: ## Deploy from a personal fork (e.g. make cluster-up-sean)
	@echo "🚀 Deploying from $*'s fork..."
	@bash cluster_up.sh $*

cluster-down: ## Delete the local k3d dev cluster
	-$(DOCKER) exec k8s-toolbox k3d cluster delete dev-cluster

rebuild: cluster-down toolbox-down ## Nuke everything and rebuild from scratch (sean)
	@sleep 2
	$(MAKE) --no-print-directory cluster-up-sean

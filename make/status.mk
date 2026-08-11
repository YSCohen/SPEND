.PHONY: ks events status status-wide status-svc check-sync sync status-images watch-frontend

# ==========================================
# 📊 CLUSTER STATUS
# ==========================================

ks: check-sync      ## Super short alias for flux get kustomizations

events: ## ⚠️  Show recent cluster events sorted by time
	@echo "⚠️  RECENT CLUSTER EVENTS:"
	@$(DOCKER) exec k8s-toolbox bash -c 'kubectl get events --sort-by=".metadata.creationTimestamp" -A | tail -n 30'

status: ## 🟢 Show current pod status across all namespaces
	@echo "🟢 CURRENT POD STATUS:"
	@$(DOCKER) exec k8s-toolbox kubectl get pods -A

status-wide: ## 🌐 Show pod status with node/IP details
	@echo "🌐 WIDE POD OVERVIEW:"
	@$(DOCKER) exec k8s-toolbox kubectl get pods -A -o wide

watch-frontend: ## 👀 Watch all pods in the frontend namespace
	@echo "👀 Watching frontend namespace (Press Ctrl+C to stop)..."
	@$(DOCKER) exec k8s-toolbox kubectl get pods -n frontend -w

status-svc: ## 🔌 Show active network services
	@echo "🔌 ACTIVE NETWORK SERVICES:"
	@$(DOCKER) exec k8s-toolbox kubectl get svc -A

status-postgres: ## 🐘 Show detailed Postgres cluster health and replication status
	@echo "🐘 POSTGRES CLUSTER STATUS:"
	@$(DOCKER) exec k8s-toolbox kubectl get cluster -n data
	@echo ""
	@echo "🐘 POSTGRES INSTANCES:"
	@$(DOCKER) exec k8s-toolbox kubectl get pods -n data -l cnpg.io/cluster=trading-db -L cnpg.io/podRole

check-sync: ## Verify all sync stages are Ready
	@$(DOCKER) exec k8s-toolbox flux get kustomizations

sync: ## Force Flux to reconcile (Accepts LAYER=all, apps, or data-layer)
	@echo "🔄 Forcing Flux to synchronize Git..."
	@REPO=$$( $(DOCKER) exec k8s-toolbox kubectl get gitrepositories -n flux-system -o jsonpath='{.items[0].metadata.name}' ); \
	if [ -n "$$REPO" ]; then \
		echo "Found repo: $$REPO, reconciling..."; \
		$(DOCKER) exec k8s-toolbox flux reconcile source git $$REPO -n flux-system; \
	else \
		echo "⚠️ No GitRepository found in flux-system, skipping source sync."; \
	fi
	@if [ "$(LAYER)" = "all" ] || [ -z "$(LAYER)" ]; then \
		echo "🔄 Syncing all Kustomizations in dependency order..."; \
		$(DOCKER) exec k8s-toolbox flux reconcile kustomization 1-infra --with-source; \
		$(DOCKER) exec k8s-toolbox flux reconcile kustomization 2-data --with-source; \
		$(DOCKER) exec k8s-toolbox flux reconcile kustomization 3-apps --with-source; \
	elif [ "$(LAYER)" = "apps" ]; then \
		$(DOCKER) exec k8s-toolbox flux reconcile kustomization 3-apps --with-source; \
	elif [ "$(LAYER)" = "data-layer" ]; then \
		$(DOCKER) exec k8s-toolbox flux reconcile kustomization 2-data --with-source; \
	fi

status-images: ## 🏷️  Check the exact Docker images running for our custom apps
	@echo "🏷️  CUSTOM APP IMAGE VERSIONS:"
	@$(MAKE) --no-print-directory kubectl CMD="get pods -A -l 'app in (fastapi, streamlit, trade-writer, db-syncer, price-cacher, redis-populator)' -o custom-columns=NAMESPACE:.metadata.namespace,POD:.metadata.name,IMAGE:.spec.containers[*].image"

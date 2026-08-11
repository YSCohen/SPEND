.PHONY: chaos-kill chaos restore-all chaos-node-stop chaos-node-start chaos-kill-redis scale-streamlit

# ==========================================
# 🌪️ CHAOS ENGINEERING (SCALE & KILL)
# ==========================================
SHELL := /bin/bash
SCALE_APPS_BANK = fastapi streamlit locust adminer db-syncer trade-writer price-cacher
SCALE_DATA_BANK = redis trading-db trading-pooler
KILL_BANK = fastapi streamlit locust adminer db-syncer trade-writer price-cacher redis trading-db grafana

# ------------------------------------------
# 💀 KILL (Simulate Pod Crash)
# ------------------------------------------
chaos-kill: ## 💀 Interactive menu to delete pods for a specific app
	@echo "============================================="
	@echo "    💥 EQUITY TRADING APP - KILL SIMULATOR"
	@echo "============================================="
	@PS3="Select an app to kill (or select Exit): "; \
	select app in $(KILL_BANK) "Exit"; do \
		if [ "$$app" = "Exit" ]; then echo "Gracefully exiting kill menu."; break; fi; \
		if [ -n "$$app" ]; then \
			ns=$$(case $$app in \
				grafana) echo "monitoring";; \
				locust) echo "load-testing";; \
				streamlit) echo "frontend";; \
				adminer|redis|trading-db|trading-pooler) echo "data";; \
				*) echo "backend";; \
			esac); \
			label=$$(case $$app in \
				grafana) echo "app.kubernetes.io/name=grafana";; \
				trading-db) echo "cnpg.io/cluster=trading-db";; \
				trading-pooler) echo "cnpg.io/poolerName=trading-pooler";; \
				redis) echo "app.kubernetes.io/name=redis";; \
				*) echo "app=$$app";; \
			esac); \
			echo "💀 Killing pods for $$app (Label: $$label) in namespace $$ns..."; \
			$(DOCKER) exec k8s-toolbox kubectl delete pods -l "$$label" -n "$$ns"; \
			break; \
		fi; \
	done

# ------------------------------------------
# 📉 SCALE DOWN (Simulate Outage)
# ------------------------------------------
chaos: ## 💥 Interactive menu to scale components down to 0
	@echo "============================================="
	@echo "    💥 EQUITY TRADING APP - CHAOS SCALE DOWN"
	@echo "============================================="
	@echo "Remember: This will suspend Flux! Use 'make restore-all' to resume."
	@PS3="Select a layer to disrupt (1-3, or type '3' to gracefully exit): " ;\
	select layer in "Application Layer (KEDA/Deployments)" "Data Layer (StatefulSets)" "Exit"; do \
		case $$layer in \
			"Application Layer (KEDA/Deployments)") \
				PS3="Select an app to scale down (1-8, or type '8' to go back): "; \
				select app in $(SCALE_APPS_BANK) "Back"; do \
					if [ "$$app" = "Back" ]; then break; fi; \
					if [ -n "$$app" ]; then \
						deploy_name=$$app; ns="backend"; scale_name=""; \
						if [ "$$app" = "locust" ]; then deploy_name="locust-load-tester"; ns="load-testing"; fi; \
						if [ "$$app" = "streamlit" ]; then ns="frontend"; fi; \
						if [ "$$app" = "adminer" ]; then ns="data"; fi; \
						if [ "$$app" = "fastapi" ]; then deploy_name="fastapi-api"; scale_name="fastapi-scaler"; fi; \
						if [ "$$app" = "trade-writer" ]; then scale_name="trade-writer-scaler"; fi; \
						echo "⏸️  Suspending Flux 3-apps kustomization..."; \
						$(DOCKER) exec k8s-toolbox flux suspend kustomization 3-apps; \
						echo "🔫 Scaling $$app down to 0 in namespace $$ns..."; \
						if [ "$$app" = "fastapi" ] || [ "$$app" = "trade-writer" ]; then \
							$(DOCKER) exec k8s-toolbox kubectl annotate scaledobject $$scale_name -n $$ns autoscaling.keda.sh/paused-replicas="0" --overwrite; \
						else \
							$(DOCKER) exec k8s-toolbox kubectl scale deployment $$deploy_name -n $$ns --replicas=0; \
						fi; \
						echo "=========================================================="; \
						echo "⚠️  WARNING: Flux is SUSPENDED. The cluster is in CHAOS mode."; \
						echo "👉  Run 'make restore-all' to resume Flux and recover."; \
						echo "=========================================================="; \
						break 2; \
					fi; \
				done ;; \
			"Data Layer (StatefulSets)") \
				PS3="Select a component to scale down (1-4, or type '4' to go back): "; \
				select data_app in $(SCALE_DATA_BANK) "Back"; do \
					if [ "$$data_app" = "Back" ]; then break; fi; \
					if [ -n "$$data_app" ]; then \
						echo "⏸️  Suspending Flux 2-data kustomization..."; \
						$(DOCKER) exec k8s-toolbox flux suspend kustomization 2-data; \
						echo "🔫 Scaling $$data_app down to 0 in namespace data..."; \
						if [ "$$data_app" = "trading-pooler" ]; then \
							$(DOCKER) exec k8s-toolbox kubectl scale deployment trading-pooler -n data --replicas=0; \
						elif [ "$$data_app" = "trading-db" ]; then \
							$(DOCKER) exec k8s-toolbox kubectl patch cluster trading-db -n data --type merge -p '{"spec":{"instances":0}}'; \
						elif [ "$$data_app" = "redis" ]; then \
							REDIS_STS=$$($(DOCKER) exec k8s-toolbox kubectl get sts -n data -l 'app.kubernetes.io/name=redis' -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || echo "redis"); \
							$(DOCKER) exec k8s-toolbox kubectl scale statefulset $$REDIS_STS -n data --replicas=0; \
						else \
							$(DOCKER) exec k8s-toolbox kubectl scale statefulset $$data_app -n data --replicas=0; \
						fi; \
						echo "=========================================================="; \
						echo "⚠️  WARNING: Flux is SUSPENDED. The cluster is in CHAOS mode."; \
						echo "👉  Run 'make restore-all' to resume Flux and recover."; \
						echo "=========================================================="; \
						break 2; \
					fi; \
				done ;; \
			"Exit") echo "Gracefully exiting chaos menu."; break ;; \
		esac; \
	done

# ------------------------------------------
# 📈 CUSTOM SCALE
# ------------------------------------------
scale-streamlit: ## 📈 Interactively scale the streamlit UI replica count
	@echo "============================================="
	@echo "    📈 EQUITY TRADING APP - SCALE UI"
	@echo "============================================="
	@read -p "Enter desired number of streamlit replicas: " replicas; \
	if [ -n "$$replicas" ]; then \
		echo "⏸️  Suspending Flux 3-apps kustomization..."; \
		$(DOCKER) exec k8s-toolbox flux suspend kustomization 3-apps; \
		echo "🔫 Scaling streamlit to $$replicas in namespace frontend..."; \
		$(DOCKER) exec k8s-toolbox kubectl scale deployment streamlit -n frontend --replicas=$$replicas; \
		echo "=========================================================="; \
		echo "⚠️  WARNING: Flux is SUSPENDED for 3-apps."; \
		echo "👉  Run 'make restore-all' to resume Flux and recover original state."; \
		echo "=========================================================="; \
	else \
		echo "Operation cancelled."; \
	fi

# ------------------------------------------
# 🚑 RESTORE & NODE CONTROL
# ------------------------------------------
restore-all: ## 🚑 Resume Flux to naturally restore all chaos components
	@echo "🚑 Removing any active KEDA pause annotations..."
	@$(DOCKER) exec k8s-toolbox kubectl annotate scaledobject fastapi-scaler -n backend autoscaling.keda.sh/paused-replicas- 2>/dev/null || true
	@$(DOCKER) exec k8s-toolbox kubectl annotate scaledobject trade-writer-scaler -n backend autoscaling.keda.sh/paused-replicas- 2>/dev/null || true
	@echo "▶️  Resuming Flux reconciliations..."
	@$(DOCKER) exec k8s-toolbox flux resume kustomization 2-data 2>/dev/null || true
	@$(DOCKER) exec k8s-toolbox flux resume kustomization 3-apps 2>/dev/null || true
	@echo "🔄 Forcing a Flux sync to immediately recover replica counts..."
	@$(MAKE) --no-print-directory sync LAYER=all
	@echo "📦 Forcing HelmRelease reconciliations (to restore Redis/StatefulSets)..."
	@$(DOCKER) exec k8s-toolbox flux reconcile helmrelease -n data --all 2>/dev/null || true

chaos-node-stop: ## 🔥 Stop the primary K3s node (simulates a server crash)
	@echo "🔥 Stopping the primary K3s node (Simulating Server Crash)..."
	@$(DOCKER) exec k8s-toolbox k3d node stop k3d-dev-cluster-server-0

chaos-node-start: ## 🚑 Reboot the primary K3s node
	@echo "🚑 Rebooting the primary K3s node..."
	@$(DOCKER) exec k8s-toolbox k3d node start k3d-dev-cluster-server-0

# ------------------------------------------
# ⚡ RANDOM REDIS KILL (Sentinel Testing)
# ------------------------------------------

chaos-kill-redis: ## ⚡ Randomly kill one Redis Sentinel pod
	@echo "🎲 Selecting a random Redis pod to disrupt..."
	@$(DOCKER) exec k8s-toolbox /bin/bash -c \
	"POD=\$$(kubectl get pods -n data -l app.kubernetes.io/name=redis -o jsonpath='{.items[*].metadata.name}' | tr ' ' '\n' | shuf -n 1); \
	echo '💀 Killing \$$POD...'; \
	kubectl delete pod \$$POD -n data"

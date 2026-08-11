# This file is downloaded standalone to ~/Makefile on remote K3s nodes
# (via k3s_manager.sh "Setup Make Toolbox"), where there is no k8s-toolbox
# container - so it calls kubectl/flux directly and intentionally duplicates
# targets from the other make/*.mk files.

.PHONY: all help status events ks sync logs db-backup db-restore db-clear bounce st-status st-restart st-scale

all: help

SHELL := /bin/bash
BOUNCE_BANK = fastapi streamlit locust adminer db-syncer trade-writer price-cacher poolers grafana

help: ## Show this dynamic help menu
	@echo "=========================================================="
	@echo "🚀 EQUITY TRADING SYSTEM - K3S MENU"
	@echo "=========================================================="
	@echo "Usage: make [target]"
	@echo ""
	@grep -h -E '^[a-zA-Z_-]+:.*?## .*$$' $(MAKEFILE_LIST) | \
	awk 'BEGIN {FS = ":.*?## "}; {printf "\033[36m%-30s\033[0m %s\n", $$1, $$2}'

bounce: ## 🔄 Interactive menu to safely restart a deployment
	@echo "============================================="
	@echo "    🔄 EQUITY TRADING APP - BOUNCER"
	@echo "============================================="
	@PS3="Select an app to safely rollout restart (or type a number to exit): "; \
	select app in $(BOUNCE_BANK) "Exit"; do \
		if [ "$$app" = "Exit" ]; then echo "Gracefully exiting bouncer."; break; fi; \
		if [ -n "$$app" ]; then \
			ns=$$(case $$app in \
				locust) echo "load-testing";; \
				streamlit) echo "frontend";; \
				adminer|poolers) echo "data";; \
				grafana) echo "monitoring";; \
				*) echo "backend";; \
			esac); \
			if [ "$$app" = "poolers" ]; then \
				echo "♻️ Bouncing both Read-Write and Read-Only poolers..."; \
				kubectl rollout restart deployment/trading-pooler -n data; \
				kubectl rollout restart deployment/trading-pooler-ro -n data; \
			elif [ "$$app" = "fastapi" ]; then \
				echo "♻️ Bouncing fastapi-api in backend..."; \
				kubectl rollout restart deployment/fastapi-api -n backend; \
			elif [ "$$app" = "grafana" ]; then \
				echo "♻️ Bouncing loki-stack-grafana in monitoring..."; \
				kubectl rollout restart deployment/loki-stack-grafana -n monitoring; \
			else \
				echo "♻️ Bouncing $$app in $$ns..."; \
				kubectl rollout restart deployment/$$app -n $$ns; \
			fi; \
			break; \
		fi; \
	done

# ===============================================
# 🚀 K3S CONTROL PANEL (DEBIAN) SPECIFIC COMMANDS
# ===============================================


status: ## 🟢 CURRENT POD STATUS (K3s):
	@echo "🟢 CURRENT POD STATUS (K3s):"
	@kubectl get pods -A

events: ## ⚠️  Show recent cluster events sorted by time (K3s)
	@echo "⚠️  RECENT CLUSTER EVENTS (K3s):"
	@kubectl get events --sort-by=".metadata.creationTimestamp" -A | tail -n 30

ks: ## Verify all sync stages are Ready (K3s)
	@flux get kustomizations

sync: ## Force Flux to reconcile (K3s)
	@echo "🔄 Forcing Flux to synchronize Git..."
	@flux reconcile source git flux-system -n flux-system
	@echo "🔄 Syncing Kustomizations..."
	@flux reconcile kustomization 1-infra --with-source || true
	@flux reconcile kustomization 2-data --with-source || true
	@flux reconcile kustomization 3-apps --with-source || true

logs: ## 📜 Stream logs for a specific pod (K3s)
	@if [ -z "$(POD)" ] && [ -z "$(APP)" ]; then \
		echo "❌ Please specify an app or pod. Example: make logs APP=fastapi"; \
	elif [ -n "$(APP)" ]; then \
		kubectl logs -f -l app=$(APP) --all-containers=true --max-log-requests=6; \
	else \
		kubectl logs -f $(POD); \
	fi

db-backup: ## 💾 Take a snapshot of the trading DB and save to current directory (K3s)
	@echo "============================================="
	@echo "    💾 DATABASE BACKUP MENU (K3s)"
	@echo "============================================="
	@read -p "Enter backup name (default: trading_backup): " input; \
	bname="trading_backup"; \
	if [ -n "$$input" ]; then bname="$$input"; fi; \
	bname=$${bname// /_}; \
	while [ -f "$${bname}.dump" ]; do \
		read -p "⚠️  File $${bname}.dump exists! (o)verwrite, (a)utoincrement, (r)ename, or (c)ancel? " choice; \
		case "$$choice" in \
			[Oo]*) break ;; \
			[Aa]*) \
				i=1; \
				while [ -f "$${bname}_$${i}.dump" ]; do i=$$((i+1)); done; \
				bname="$${bname}_$${i}"; \
				echo "✅ Autoincremented to $${bname}.dump"; \
				break ;; \
			[Rr]*) \
				read -p "Enter new backup name: " input; \
				if [ -n "$$input" ]; then bname="$$input"; fi; \
				;; \
			*) echo "Aborted."; exit 1 ;; \
		esac; \
	done; \
	echo "💾 Taking snapshot of 'trading' database from primary node..."; \
	POD=$$(kubectl get pods -n data -l "cnpg.io/cluster=trading-db,cnpg.io/instanceRole=primary" -o jsonpath="{.items[0].metadata.name}") && \
	echo "📦 Creating dump inside pod $$POD..." && \
	kubectl exec -n data $$POD -- pg_dump -U postgres -d trading -F c -f /dev/shm/dump.tmp && \
	echo "⬇️ Copying backup to host as \"$$bname.dump\"..." && \
	kubectl cp data/$$POD:/dev/shm/dump.tmp "./$$bname.dump"; \
	echo "✅ Backup successfully saved to ./$$bname.dump!"

db-restore: ## ⚠️ RESTORE snapshot to the trading DB (Destructive) (K3s)
	@echo "============================================="
	@echo "    ⚠️  DATABASE RESTORE MENU (K3s)"
	@echo "============================================="
	@DUMPS=$$(ls *.dump 2>/dev/null); \
	if [ -z "$$DUMPS" ]; then \
		echo "❌ No .dump files found in the current directory!"; \
		exit 1; \
	fi; \
	PS3="Select a backup file to restore (or type a number to exit): "; \
	select file in $$DUMPS "Exit"; do \
		if [ "$$file" = "Exit" ]; then echo "Gracefully exiting."; break; fi; \
		if [ -n "$$file" ]; then \
			echo "⚠️  WARNING: This will drop and replace the current 'trading' database!"; \
			echo "⏳ Copying $$file into the primary pod and restoring..."; \
			POD=$$(kubectl get pods -n data -l "cnpg.io/cluster=trading-db,cnpg.io/instanceRole=primary" -o jsonpath="{.items[0].metadata.name}") && \
			echo "⬆️ Copying backup file into pod $$POD..." && \
			kubectl cp "./$$file" data/$$POD:/dev/shm/trading_backup.dump && \
			echo "🔥 Restoring database (with clean)..." && \
			kubectl exec -n data $$POD -- pg_restore -U postgres -d trading --clean --if-exists /dev/shm/trading_backup.dump; \
			echo "✅ Database restored successfully!"; \
			echo "🧹 Flushing Redis Cache completely to remove stale streams..."; \
			REDIS_POD=$$(kubectl get pods -n data -l "app.kubernetes.io/name=redis" -o jsonpath="{.items[0].metadata.name}" 2>/dev/null || kubectl get pods -n data -l "app=redis" -o jsonpath="{.items[0].metadata.name}") && \
			kubectl exec -n data $$REDIS_POD -- sh -c "redis-cli --scan | xargs -r redis-cli del"; \
			echo "🚀 Triggering redis-populator job to rebuild caches..."; \
			JOB_NAME="redis-populator-manual-$$(date +%s)"; \
			kubectl create job --from=cronjob/redis-populator $$JOB_NAME -n backend; \
			echo "⏳ Waiting for redis-populator to finish..."; \
			kubectl wait --for=condition=complete job/$$JOB_NAME -n backend --timeout=60s; \
			echo "♻️ Restarting dependent deployments in correct sequence..."; \
			kubectl rollout restart deployment/trading-pooler -n data; \
			kubectl rollout restart deployment/trading-pooler-ro -n data; \
			kubectl rollout restart deployment/price-cacher -n backend; \
			kubectl rollout restart deployment/fastapi-api -n backend; \
			kubectl rollout restart deployment/trade-writer -n backend; \
			kubectl rollout restart deployment/db-syncer -n backend; \
			kubectl rollout restart deployment/adminer -n data; \
			kubectl rollout restart deployment/streamlit -n frontend; \
			kubectl rollout restart deployment/locust-load-tester -n load-testing; \
			break; \
		fi; \
	done

db-clear: ## ⚠️ WIPE the entire trading database (Destructive) (K3s)
	@echo "============================================="
	@echo "    ⚠️  DATABASE WIPE MENU (K3s)"
	@echo "============================================="
	@echo "WARNING: This will permanently DROP all tables and data!"
	@read -p "Are you absolutely sure? (y/N): " confirm; \
	case "$$confirm" in [Yy]) \
		echo "💥 Truncating all data in the public schema..."; \
		POD=$$(kubectl get pods -n data -l "cnpg.io/cluster=trading-db,cnpg.io/instanceRole=primary" -o jsonpath="{.items[0].metadata.name}") && \
		kubectl exec -n data $$POD -- psql -U postgres -d trading -c "TRUNCATE TABLE trades, accounts, users, positions, users_sync_stage, accounts_sync_stage, positions_sync_stage CASCADE;"; \
		echo "✅ Database data completely cleared!"; \
		echo "🧹 Flushing Redis Cache completely..."; \
		REDIS_POD=$$(kubectl get pods -n data -l "app.kubernetes.io/name=redis" -o jsonpath="{.items[0].metadata.name}" 2>/dev/null || kubectl get pods -n data -l "app=redis" -o jsonpath="{.items[0].metadata.name}") && \
		kubectl exec -n data $$REDIS_POD -- sh -c "redis-cli --scan | xargs -r redis-cli del"; \
		echo "🚀 Triggering redis-populator job (to rebuild empty caches)..."; \
		JOB_NAME="redis-populator-manual-$$(date +%s)"; \
		kubectl create job --from=cronjob/redis-populator $$JOB_NAME -n backend; \
		echo "⏳ Waiting for redis-populator to finish..."; \
		kubectl wait --for=condition=complete job/$$JOB_NAME -n backend --timeout=60s; \
		echo "♻️ Restarting dependent deployments in correct sequence..."; \
		kubectl rollout restart deployment/trading-pooler -n data; \
		kubectl rollout restart deployment/trading-pooler-ro -n data; \
		kubectl rollout restart deployment/price-cacher -n backend; \
		kubectl rollout restart deployment/fastapi-api -n backend; \
		kubectl rollout restart deployment/trade-writer -n backend; \
		kubectl rollout restart deployment/db-syncer -n backend; \
		kubectl rollout restart deployment/adminer -n data; \
		kubectl rollout restart deployment/streamlit -n frontend; \
		kubectl rollout restart deployment/locust-load-tester -n load-testing; \
		;; \
	*) \
		echo "Aborted."; \
		;; \
	esac

# ==========================================
# 📊 STREAMLIT HELPER COMMANDS (K3s)
# ==========================================

st-status: ## 👀 View Streamlit pods (K3s)
	@echo "📊 STREAMLIT PODS:"
	@kubectl get pods -n frontend -l app=streamlit

st-restart: ## ♻️ Rolling-restart the Streamlit deployment (K3s)
	@echo "♻️ Restarting Streamlit deployment..."
	@kubectl rollout restart deployment/streamlit -n frontend

st-scale: ## ⚖️ Scale Streamlit deployment (usage: make st-scale REPLICAS=3) (K3s)
	@if [ -z "$(REPLICAS)" ]; then \
		echo "❌ Please specify REPLICAS. Example: make st-scale REPLICAS=3"; \
	else \
		echo "⚖️ Scaling Streamlit to $(REPLICAS) replicas..."; \
		kubectl scale deployment/streamlit -n frontend --replicas=$(REPLICAS); \
	fi

.PHONY: bounce

# ==========================================
# 🔄 ROLLING RESTARTS (BOUNCING)
# ==========================================
BOUNCE_BANK = fastapi streamlit locust adminer db-syncer trade-writer price-cacher poolers grafana

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
				$(DOCKER) exec k8s-toolbox kubectl rollout restart deployment/trading-pooler -n data; \
				$(DOCKER) exec k8s-toolbox kubectl rollout restart deployment/trading-pooler-ro -n data; \
			elif [ "$$app" = "fastapi" ]; then \
				echo "♻️ Bouncing fastapi-api in backend..."; \
				$(DOCKER) exec k8s-toolbox kubectl rollout restart deployment/fastapi-api -n backend; \
			elif [ "$$app" = "grafana" ]; then \
				echo "♻️ Bouncing loki-stack-grafana in monitoring..."; \
				$(DOCKER) exec k8s-toolbox kubectl rollout restart deployment/loki-stack-grafana -n monitoring; \
			else \
				echo "♻️ Bouncing $$app in $$ns..."; \
				$(DOCKER) exec k8s-toolbox kubectl rollout restart deployment/$$app -n $$ns; \
			fi; \
			break; \
		fi; \
	done

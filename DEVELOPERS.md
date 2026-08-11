---
# Developer Guide

How to build, run, and debug the Equity Trading System.

> **Note:** Use the `Makefile` wrappers for cluster operations. Without `make`, run `./cluster_up.sh` directly.

---

## 1. Environment Setup & Overlays
Every developer has their own namespace (e.g., `dev-sean`, `dev-max`) to work in.

### How to use your Overlay:
1. **Push to GitHub**: Flux only reconciles what's in the repository - `git push` before your changes appear in the cluster.
2. **Changing Images**: to use a personal image instead of the org default, edit `kustomization.yaml` in your overlay directory (`k8s/manifests/overlays/dev-<name>/`):
   * Uncomment the `images` section.
   * Update `newName` to point to your registry.
   * Run `make sync` to trigger a Flux reconciliation.
3. **Overwriting**: any base config (resources, replicas, env vars) can be overridden in your `kustomization.yaml`.

---

## 2. The "Make" Toolbox (Debugging)
All `kubectl` operations are mapped to `Makefile` targets - no need to memorize the raw commands.

* **See all available commands**: Run `make help` to see the full list of targets and descriptions.
* **Check System Health**:
    * `make status`: View the status of all pods across all namespaces.
    * `make status-wide`: View pod status with node/IP details.
* **Direct Access**: 
    * `make shell-api` / `make shell-ui`: Hop into a container shell if you need to inspect files.
    * `make psql`: Jump straight into the Postgres console.
    * `make redis-cli`: Open the Redis CLI.
* **Database Operations**:
    * `make db-backup`: Takes a full snapshot of the Postgres trading database and saves it to the project root.
    * `make db-restore`: Wipes the database and interactively restores it from a selected snapshot file.
    * `make db-clear`: Wipes the entire database cleanly and rebuilds the Redis caches.
* **Chaos & Restarting**:
    * `make bounce`: Interactive menu to safely restart any deployment.
    * `make chaos`: Interactive menu to scale components down to 0 to simulate failures.

---

## 3. Logging & Observability
We use **Loki** to aggregate logs.

### Standard Output (stdout) Requirements
* **Everything must be JSON**: logs to `stdout` must be serialized as JSON - the collectors parse JSON automatically for Grafana.
* **Push URL**: to push logs manually: `http://loki-stack.monitoring.svc.cluster.local:3100/loki/api/v1/push`

### Debugging Logs in Grafana
* **URL**: `http://grafana.localhost:8080`
* **Workflow**: check `make logs-api` or `make logs-ui` first, then query the error history in Grafana.

---

## 4. Need Help?
* **Flux Stuck?**: run `make sync` to force an immediate reconciliation.
* **Load Testing**: use `./locust_reload.sh` to push local `locustfile.py` changes to the cluster without waiting for the full GitOps cycle.
* **Containers sometimes lose internet (systemd-resolved hosts)**: on hosts where systemd-resolved provides the local DNS stub (127.0.0.53), Docker containers can fail to resolve DNS. Point Docker at upstream servers in `/etc/docker/daemon.json` - e.g. `{ "dns": ["1.1.1.1", "1.0.0.1"] }` - then `sudo systemctl restart docker`.

---

## 5. Remote Development & Tailscale

### K3S Manager
If you need to deploy and manage a distributed remote cluster, use the interactive manager script:
```sh 
curl -sSL "https://raw.githubusercontent.com/SM26-Industrial-Software-Dev/SPEND/main/k3s_manager.sh" -o k3s_manager.sh && chmod +x k3s_manager.sh
```

### Tailscale Kubernetes Operator
The K3s environment uses the Tailscale Kubernetes Operator to connect the cluster to the Tailnet securely.
This requires an OAuth client ID and secret, provisioned in the Tailscale Admin Console and injected into the cluster as a secret (`operator-oauth` in the `tailscale` namespace).

**Required Tailscale OAuth Permissions (Scopes):**
When generating the OAuth client in Tailscale, you must grant it the following permissions:

| Permission / Scope | Access Level | Tags Applied |
| :--- | :--- | :--- |
| **DNS** | Write | |
| **Services** | Write | `tag:k8s-operator` |
| **Core** | Write | `tag:k8s-operator` |
| **Routes** | Write | |
| **Device invites** | Write | |
| **Auth keys** | Write | `tag:k8s-operator` |

<div align="center">

# SPEND

### **S**calable **P**arallel **E**quity, **N**etworked & **D**istributed

*A Kubernetes-native, GitOps-managed equity position management platform — built from scratch by four first-year CS students.*

![Rust](https://img.shields.io/badge/Rust-000000?style=flat&logo=rust&logoColor=white)
![Python](https://img.shields.io/badge/Python-3776AB?style=flat&logo=python&logoColor=white)
![Kubernetes](https://img.shields.io/badge/Kubernetes-326CE5?style=flat&logo=kubernetes&logoColor=white)
![Flux](https://img.shields.io/badge/Flux-5468FF?style=flat&logo=flux&logoColor=white)
![Redis](https://img.shields.io/badge/Redis-DC382D?style=flat&logo=redis&logoColor=white)
![PostgreSQL](https://img.shields.io/badge/PostgreSQL-4169E1?style=flat&logo=postgresql&logoColor=white)
![License](https://img.shields.io/badge/License-Apache%202.0-blue.svg)

</div>

---

## What it is

SPEND is a **position management system**. Users open accounts and book trades (long and short) one at a time or thousands at a time; SPEND records each one, derives the resulting positions and cost basis, and marks them to market against live prices.

The interesting part isn't the domain — it's the machine underneath it. SPEND is a genuinely distributed system: a **split hot/cold data path** where every write lands in Redis and is drained into Postgres asynchronously by a fleet of **Rust workers** that autoscale on queue depth. Every component is replicated, every failure mode is something we deliberately tested, and the entire cluster is defined declaratively and reconciled by **Flux** — no human ever runs `kubectl apply` against a real environment.

It runs identically on a laptop (k3d) or across a fleet of networked physical machines (K3s).

---

## Architecture

![Architecture Diagram](Architecture%20Diagram.png)

### The write path (hot)

A booked trade never touches Postgres synchronously. The API validates it, updates the appropriate position hash in Redis, and appends the trade to a Redis stream, then returns. Durable persistence happens out of band:

- **`trade-writer`**: a consumer-group worker that batches the trade stream into Postgres using a staging table plus upsert, so replays and retries are idempotent, and edits update. KEDA watches the stream's consumer lag and scales the worker pool 1 → 5 when a batch submission floods the queue.
- **`db-syncer`**: continuously mirrors users, accounts, positions and the username map from Redis into Postgres.

This is what makes bulk booking work: the user's request is bounded by a Redis round trip, not by Postgres write throughput, and the backlog is absorbed by workers that materialize on demand.

### The read path (cold)

Anything that needs individual trade data (single trade lookups, paginated trade history) reads Postgres directly through a PgBouncer pooler. Everything else (e.g. positions, accounts, ticker validation, live prices) reads Redis.

### Market data

`price-cacher` polls the Yahoo Finance API for the full S&P 500 and keeps current prices in Redis, so ticker validation and mark-to-market P&L are local lookups rather than outbound HTTP calls on the request path.

### Cold start & recovery

`redis-populator` is the inverse of `db-syncer`: a run-once Job that rebuilds the entire Redis cache from Postgres. It's how the system recovers from a total cache loss, and how a restored database dump gets promoted back into the hot path.

---

## Stack

| Layer | Technology |
| :--- | :--- |
| **API** | FastAPI · Pydantic · async Postgres + Redis pools · cookie session auth · request-timing middleware |
| **Web UI** | Streamlit · AG Grid · yfinance · multipage navigation with an auth guard |
| **Workers** | Rust — `trade-writer`, `db-syncer`, `price-cacher`, `redis-populator` |
| **Data** | Redis + Sentinel (HAProxy proxy) · PostgreSQL via CloudNativePG · PgBouncer · Adminer · RedisInsight |
| **Orchestration** | Kubernetes (k3d local / K3s distributed) · Kustomize · Flux CD · Traefik ingress · KEDA · Reloader |
| **Observability** | Loki · Prometheus · Grafana |
| **Testing & CI** | Locust · GitHub Actions (full cluster bootstrap per PR, multi-arch image publishing) |
| **Networking** | Tailscale Kubernetes Operator |

---

## Repository layout

```
├── api/         FastAPI backend
├── web-ui/      Streamlit frontend
├── db/          Schema + Rust syncers
├── k8s/         Manifests, overlays, Flux
├── locust/      Load testing
├── make/        Modular developer toolbox
└── cluster_up.sh · cluster_down.sh · k3s_manager.sh
```

---

## Quickstart

Bring up the whole system locally — k3d cluster, Flux bootstrap, and every service:

```sh
make cluster-up
make status      # watch it come alive
make down
```

There is nothing to install first. Every cluster command runs inside a containerized `k8s-toolbox` that carries its own `kubectl`, `k3d` and `flux` and mounts the host's Docker/Podman socket — so no host-level Kubernetes tooling is required.

`make help` lists the full toolbox: `make logs-api`, `make psql`, `make redis-cli`, `make db-backup`, `make bounce`, `make chaos`, and more.

**Deploying a distributed K3s cluster?** Use the interactive manager:

```sh
curl -sSL "https://raw.githubusercontent.com/SM26-Industrial-Software-Dev/SPEND/main/k3s_manager.sh" -o k3s_manager.sh && chmod +x k3s_manager.sh
```

Full setup, overlay and debugging documentation lives in **[DEVELOPERS.md](DEVELOPERS.md)**.

---

## The team

#### [Sean Alter](https://github.com/thegreatestgiant) — Kubernetes, GitOps & distributed infrastructure

Built the Kubernetes layer: the base/overlay Kustomize structure, the staged Flux reconciliation targets, and the per-developer environments. Owns the data layer — Redis Sentinel and its HAProxy proxy, the CloudNativePG cluster and poolers — plus liveness probes, anti-affinity and eviction tuning. Wrote `cluster_up.sh` and the interactive `k3s_manager.sh`, stood up the distributed K3s cluster and its Tailscale operator integration, hardened session cookies at the ingress, and built the chaos and database backup/restore tooling. Contributed UI work throughout.

#### [Yehuda Cohen](https://github.com/YSCohen) — Rust workers, data model & CI

Wrote the Rust syncer binaries: the `trade-writer` consumer-group worker with its staging-table upsert strategy, `db-syncer`, `price-cacher`, and the `redis-populator` bootstrap Job. Owns the Postgres schema (including the `NUMERIC` cost-basis and realized-gains model and the username map), and the project's documentation and licensing.

#### [Max Rabinowitz](https://github.com/MaxRabz) — FastAPI backend

Built the API: routers, services, models, and the core Redis/Postgres connection layer. Implemented authentication, account creation and cross-user account permission sharing, P&L calculation for both long and short positions, trade editing that also corrects the affected position, batch booking with per-trade failure reporting, and cursor-based pagination over trade history. Wrote the request-logging middleware, moved ticker validation from a CSV to Redis, and authored the Locust scenarios that drive the load tests.

#### [William Trump](https://github.com/WilliamTrump) — Streamlit web UI

Built the frontend: the filterable AG Grid position and trade views, the mass trade booker, account management flows, and persistent login that survives refreshes and deep links. Did the performance work that made a heavyweight JS grid viable in Streamlit — gzip-compressing the AG Grid bundle at the ingress, deferring imports, and stopping the grid from fully reinitializing on every auto-refresh cycle.

---

## License

[Apache 2.0](LICENSE)

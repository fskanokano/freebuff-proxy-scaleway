---
name: freebuff-proxy-scaleway
description: Port freebuff-proxy (Go OpenAI gateway) to Scaleway Serverless Containers with minimal changes. Use for PORT fallback (LISTEN_ADDR vs $PORT), 3-var env alias (AUTH_TOKENS/FREEBUFF_TOKEN, API_KEYS/API_KEY, ADMIN_TOKEN), Dockerfile PORT/EXPOSE, GitHub Actions build-push-redeploy pipeline, console form filling (Scaleway Images, Port 8080, resources, scaling, env/secrets), billing free-tier (400k GB·s + 200k vCPU·s) and datacenter egress (limited tier) caveats.
---

# freebuff-proxy-scaleway Skill

Minimal-change port of `trefeon/freebuff-proxy` (Go 1.26, `internal/config` + `Dockerfile` + `cmd/freebuff-proxy`) to **Scaleway Serverless Containers** (Knative, scale-to-zero, `PORT` injection). No logic rewrite: 2 files patched, 1 workflow added; all proxy logic (pooled/bridge, session/run, stealth, dashboard) kept byte-identical.

## When to Use

- User asks: "freebuff-proxy scaleway / deploy freebuff-proxy to Scaleway Containers / PORT env / LISTEN_ADDR 8080 / 3 env vars / scaleway.yml workflow / 截图怎么填 / 是否免费"
- Need to explain `internal/config/config_env.go` PORT fallback and `FREEBUFF_TOKEN`→`AUTH_TOKENS` alias, or `Dockerfile` `ENV PORT/EXPOSE`, or `.github/workflows/scaleway.yml` build→push→redeploy pipeline
- Fill Scaleway Console "Deploy a Container" form (screenshot with Registry region, Port, Resources, Autoscaling, Environment variables, Secrets)
- Answer billing: personal proxy in free tier = **€0** (400k GB·s + 200k vCPU·s/month, `min_scale=0` no idle cost), overage pricing, how to check via Cost Manager / Invoice / Billing alerts
- Troubleshoot `container not ready (PORT)` / `401` / `country_blocked` (Scaleway egress is datacenter IP → limited tier) / image pull 403 / workflow redeploy 409

## Decision Trees

### Minimal changes?

```
Need Scaleway Containers support?
├─ Keep proxy logic untouched
│  ├─ Dockerfile: ENV PORT=8080 + EXPOSE 3457 8080 (minimal, not replacing 3457)
│  └─ internal/config/config_env.go:
│     ├─ PORT fallback: if LISTEN_ADDR default (127.0.0.1:3457) && $PORT set → LISTEN_ADDR=:$PORT (0.0.0.0:$PORT)
│     ├─ AUTH_TOKENS alias: AUTH_TOKENS || FREEBUFF_TOKEN || FREEBUFF_TOKENS || TOKEN (presence-sensitive, keeps bridge-mode empty)
│     ├─ API_KEYS alias: API_KEYS || API_KEY || FREEBUFF_API_KEY || PROXY_API_KEY
│     └─ ADMIN_TOKEN alias: ADMIN_TOKEN || ADMIN_PASSWORD
│  └─ .github/workflows/scaleway.yml (new, no existing file touched)
└─ Everything else (convert, pool, upstream, dashboard, server) → 0 change
```

### Env vars (3-var UX)?

```
Need env?
├─ FREEBUFF_TOKEN (or AUTH_TOKENS) → AUTH_TOKENS → Secret (comma-separate multi)
├─ API_KEY (or API_KEYS) → API_KEYS → Secret or Env (client Bearer)
├─ ADMIN_TOKEN (or ADMIN_PASSWORD) → ADMIN_TOKEN → Secret (dashboard /admin)
├─ PORT (injected by Scaleway, do not set manually; binary falls back automatically)
└─ Optional: AUTO_DISCOVER_TOKEN=false, SAFE_MODE, LOG_LEVEL etc unchanged
```

### Deploy path?（当前控制台 Image* 必选，先推镜像再建容器）

```
Need deploy?
├─ First push (Image* 必选为空则无法提交)
│  ├─ 本机：docker login → docker build → docker push rg.fr-par.scw.cloud/<ns>/freebuff-proxy:latest
│  └─ 或 GitHub：先填 SCW_SECRET_KEY+SCW_REGISTRY_ENDPOINT → Actions Run workflow → 镜像出现在下拉
├─ Then console → Create namespace → Deploy a Container（此时 Image* 可选，选 freebuff-proxy/latest，Port 8080，512MB/500mCPU，min 0 max 3，3 Secrets）→ get URL
└─ After：GitHub push → scaleway.yml（login → build linux/amd64 → push → PATCH + /redeploy）→ auto update
```

## Key References

| Path | Role |
|------|------|
| `Dockerfile:20` | `ENV PORT=8080` + `EXPOSE 3457 8080` — Scaleway PORT contract (listen on 0.0.0.0:$PORT) |
| `internal/config/config_env.go:32` | `PORT` fallback (`LISTEN_ADDR=:$PORT` when default & `$PORT` set) |
| `internal/config/config_env.go:41` | `AUTH_TOKENS` alias chain (`FREEBUFF_TOKEN`, `FREEBUFF_TOKENS`, `TOKEN`) + `AuthTokensSet` presence |
| `internal/config/config_env.go:56` | `API_KEYS` alias `lookupFirstEnv(API_KEYS, API_KEY, FREEBUFF_API_KEY, PROXY_API_KEY)` |
| `internal/config/config_env.go:58` | `ADMIN_TOKEN` alias `ADMIN_TOKEN||ADMIN_PASSWORD` |
| `internal/config/config_env.go:569` | `applyDotenv` same aliases for `.env` (symmetry) |
| `.github/workflows/scaleway.yml:1` | GitHub Actions: `docker/login` (nologin) → `build-push` (linux/amd64, gha cache) → `curl PATCH /containers/v1/... + /redeploy` |
| `docs/scaleway-containers.md` | Console step-by-step + screenshot fill guide + billing calculator |

## Minimal Patches (diff vs upstream)

### 1. `Dockerfile` (3 lines)

```diff
+ENV PORT=8080
-EXPOSE 3457
+EXPOSE 3457 8080
+# comment: binary falls back to $PORT when LISTEN_ADDR default
```

### 2. `internal/config/config_env.go` (~35 lines, 2 sites)

- **Load**: before `AuthTokens` block, insert PORT fallback; replace single `AUTH_TOKENS` lookup with 4-way else-chain; replace `overrideCSV(API_KEYS)` + `overrideString(ADMIN_TOKEN)` with `lookupFirstEnv` + `overrideStringAlias(ADMIN_TOKEN,ADMIN_PASSWORD)`.
- **applyDotenv**: same 4-way/lookup logic for `.env`; add 3 helper funcs `lookupFirstEnv`, `lookupFirstFromMap`, `overrideStringAliasFromVals` at bottom.

All other 22 internal packages unchanged; proxy still validates `LISTEN_ADDR`, `AUTH_TOKENS` etc exactly as before.

### 3. `.github/workflows/scaleway.yml` (new, 60 lines)

- Trigger `push: main` + `workflow_dispatch`
- `docker/login-action@v3` with `rg.fr-par.scw.cloud` / `nologin` / `SCW_SECRET_KEY`
- `docker/build-push-action@v6` with `linux/amd64`, `push: true`, tag `${SCW_REGISTRY_ENDPOINT}/freebuff-proxy:latest`, `cache gha`, `VERSION=${github.sha}`
- `curl PATCH /containers/v1/regions/${REGION}/containers/${ID}` with `{"registry_image": "$IMAGE"}` (v1 auto-deploys), then `POST .../redeploy` for mutable tag (best-effort)

## Console Form Fill (screenshot 306821f4-...jpg)

> Screenshot shows Scaleway Console → Serverless → Containers → Deploy a Container.

| Field (UI) | What to select/fill | Why |
|------------|---------------------|-----|
| Source | **Scaleway Images from your Scaleway Container Registry** (first radio, selected) | External is for Docker Hub; Quickstart is hello-world |
| Registry region* | `AMS` or `PAR` — pick `PAR` (`fr-par`) if your token tier needs EU, or `AMS` (as screenshot). Must match `SCW_REGISTRY_ENDPOINT` region | Your namespace region; `rg.fr-par.scw.cloud` vs `rg.nl-ams.scw.cloud` |
| Registry namespace* | dropdown → your namespace (e.g. `freebuff`) — create first via **Container Registry → Create namespace** if empty | Namespace holds image `freebuff-proxy` |
| Image* | `freebuff-proxy`（**必先推送，否则必填项为空、表单无法提交**） | `docker push` 或 `Actions Run workflow` 后才出现在下拉 |
| Tag* | `latest`（或 `main-<sha>`） | Workflow 推送 `:latest`，与 `SCW_REGISTRY_ENDPOINT` 前缀一致 |
| Port* | `8080` (keep, do not change to 3457) | Must match `Dockerfile ENV PORT=8080` and binary's `$PORT` fallback; Scaleway injects `PORT=8080` and probes it |
| Container name* | `freebuff-proxy` (or keep generated `container-flamboyant-wilson`) | DNS subdomain; lowercase + dashes |
| Resources | **CPU 500 mVCPU**, **Memory 512 MB** (NOT 1000/2048 as screenshot default) | 256–512 MB + 140–500 mVCPU enough for Go; 2048/1000 exceeds free tier; 128 MB may OOM with dashboard |
| Autoscaling → Request concurrency | `Instances thresholds` **minimum 0**, **maximum 3**, **Maximum concurrent requests per instance 80** | `0` enables scale-to-zero (no idle cost); `5` as screenshot wastes; `80` is platform max |
| Advanced → Environment variables | **Classic → + Add variable** (non-secret): none needed beyond `PORT` (auto). Optional `LOG_LEVEL=info`, `SAFE_MODE=true` | Only 3 secrets needed |
| Advanced → Secrets | **+ Add secret** 3 rows: `FREEBUFF_TOKEN` (or `AUTH_TOKENS`) = `cb_xxx` ; `API_KEY` (or `API_KEYS`) = `your-proxy-key` ; `ADMIN_TOKEN` = `random-hex` | Secrets are encrypted, not shown after save; `SCW_*` and `PORT` are reserved, do not use |
| Region (top/secret) | Keep `fr-par` or `nl-ams` consistent across registry + container + `SCW_REGION` secret | Mismatch → 404 image not found |

After Deploy, Console gives `https://freebuff-proxy-xxxx.containers.<region>.scw.cloud` — test `/healthz` then `/v1/models` with `Authorization: Bearer <API_KEY>`.

## Billing: Is It Free? (2026-08-12 pricing, before tax)

**Scaleway Containers free tier per account/month (not per container):**

| Dimension | Free tier | Over free (HT) |
|-----------|-----------|----------------|
| Memory | **400,000 GB·s** | €0.000002 / GB·s (€0.20 /100k) |
| vCPU | **200,000 vCPU·s** | €0.00001 / vCPU·s (€1.00 /100k) |
| Requests / storage / egress | — | **Free** (ephemeral storage free, ingress/egress free) |

GB·s = `GB × seconds active` (only when handling requests; `min_scale=0` → idle = €0). No min_scale → no "provisioned"保温费 (Functions有，Containers无).

**Personal proxy estimate (512MB/0.5 vCPU, 3s/req):**

- 30k req/mo (≈1k/day) → 45k GB·s / 45k vCPU·s → **€0** (well below free)
- 100k req/mo → 150k GB·s / 50k vCPU·s → **€0**
- 300k req/mo → 460k GB·s (60k over → €0.12) → **≈€0.12**
- Screenshot default 2048MB/1vCPU, 12h/day active (1.3M s/mo) → 2.6M GB·s → **≈€4 + €11 = €15** → why we recommend 512MB/500mCPU + scale-to-zero.

**How to check if you exceed (same as Functions but Containers category):**

- **Cost Manager**: Console → Billing → Cost Manager → filter `Serverless Containers` + current month; free tier shown as `Free Tier` deduction
- **Invoice**: `Billing → Invoices → current month → Serverless Containers Free Tier` block (no block = within free)
- **Billing Alerts**: `Billing → Billing alerts → + Create` (e.g. €1, €5 → Email/SMS/Webhook)
- **Cockpit / Metrics**: Container → Metrics (requests, memory, error rate)
- **Tooltip in screenshot**: "This estimate does not take into account the free tier…" — final bill < estimate until you cross free tier.

**Datacenter caveat (non-billing):** Scaleway egress IPs are French/Dutch datacenter ASNs (MaxMind/Spur) → upstream Cloudflare classifies as `ipPrivacySignals: ["hosting"]` / `vpn` → **restricted cohort** (`limited` tier, $0.50/day spend ceiling, `mimo/mimo-v2.5` may be only allowed, `/v1/models` shows `region_limited`). Not yet `banned`, but expect `429` after few sessions. Mitigation: use `mimo` model, `SAFE_MODE=true`, avoid many tokens on one IP. See README hygiene section.

## Local Test (before cloud)

```bash
# 3-var dry-run locally (PORT fallback check)
PORT=8080 FREEBUFF_TOKEN=cb_test API_KEY=test ADMIN_TOKEN=123456 go run ./cmd/freebuff-proxy -doctor
# or docker:
docker build -t freebuff-proxy:local .
docker run --rm -p 8080:8080 -e PORT=8080 -e FREEBUFF_TOKEN=cb_test -e API_KEY=test -e ADMIN_TOKEN=123456 freebuff-proxy:local
curl http://localhost:8080/healthz
curl http://localhost:8080/v1/models -H "Authorization: Bearer test"
```

## Scaleway CLI Alternative (if not using workflow)

```bash
scw container namespace create name=freebuff region=fr-par
# docker login rg.fr-par... -u nologin --password-stdin <<< "$SCW_SECRET_KEY"
# docker push rg.fr-par.scw.cloud/freebuff/freebuff-proxy:latest
scw container container create namespace-id=<ns-id> name=freebuff-proxy registry-image=rg.fr-par.scw.cloud/freebuff/freebuff-proxy:latest port=8080 memory-limit=512 cpu-limit=500 min-scale=0 max-scale=3 region=fr-par environment-variables.PASSWORD=...
scw container container deploy container-id=<id> region=fr-par
```

## Troubleshooting

- `container not ready, healthcheck failed on PORT 8080`: binary still on `127.0.0.1:3457` → ensure image built from this branch (`Dockerfile ENV PORT` + patched `config_env.go`); `docker logs` should show `listen_addr=:8080` / `0.0.0.0:8080`
- `401 Invalid API key`: check `API_KEY` secret vs client `Authorization: Bearer <same>` (plural vs singular aliased; both work but must match)
- `403 banned / country_blocked`: Scaleway IP flagged; try `mimo/mimo-v2.5` only; reduce token count; do not use VPN on top
- `403 image pull failed / 403 registry`: Secret `SCW_SECRET_KEY` lacks `ContainerRegistry` `read` + `Containers` `manage`; recreate API key with `Project` scope
- `409 resource in transient state` on PATCH → POST /redeploy too soon: workflow sleeps 3s; retry; v1 PATCH alone auto-deploys so POST is optional
- `Workflow pushed image but console still old`: mutable tag cache — workflow does `PATCH + redeploy`; if still old, wait 1-2 min or retag with `github.sha`
- `Bill not €0`: check Cost Manager → if >400k GB·s → reduce memory/CPU or requests; ensure `min_scale=0`

## Repo Layout (delta)

```
freebuff-proxy-scaleway/
├── Dockerfile                         # +ENV PORT, +EXPOSE 8080 (3 lines)
├── internal/config/config_env.go       # +PORT fallback, +3-var aliases, +3 helpers (35 lines)
├── .github/workflows/scaleway.yml     # NEW: build-push-redeploy (60 lines)
├── docs/scaleway-containers.md        # NEW: step-by-step + screenshot fill + billing
├── skill.md                           # this file (top-level)
└── .opencode/skills/freebuff-proxy-scaleway/SKILL.md  # same as skill.md (opencode discovery)
```

Full guide: `docs/scaleway-containers.md`; console screenshots in `/tmp/*.jpg`.

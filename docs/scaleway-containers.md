# Scaleway Serverless Containers 部署指南（freebuff-proxy 最小改动版）

> 基于 `trefeon/freebuff-proxy`（Go 1.26）→ Scaleway Containers 的 3 变量、一键 CI 方案。截图对应控制台 `Serverless → Containers → Deploy a Container`；计费结论：**个人代理在免费额度内 = €0**。

## 1. 最小改动清单（2 文件 + 1 workflow）

| 变更 | 行数 | 为什么 |
|------|------|--------|
| `Dockerfile` `ENV PORT=8080` + `EXPOSE 3457 8080` | 3 | Scaleway 以 `PORT` 注入并探测；保持 3457 兼容本地 |
| `internal/config/config_env.go` PORT 回退 + 3 变量别名 | ~35 | `LISTEN_ADDR` 在默认且 `$PORT` 存在时自动 `:$PORT`；`FREEBUFF_TOKEN→AUTH_TOKENS`、`API_KEY→API_KEYS`、`ADMIN_PASSWORD→ADMIN_TOKEN` |
| `.github/workflows/scaleway.yml` 新增 | 60 | `push main` → `docker login (nologin)` → `build linux/amd64 → push rg.fr-par.scw.cloud/<ns>/freebuff-proxy:latest` → `PATCH + /redeploy` |

其它 `internal/*`、`cmd/*`、`frontend/*` 完全未动，`docker-compose.yml` 仍可在本地用。

## 2. 免费吗？（结论先行）

**是 “每月免费额度 + 超额按量”，个人用 = €0。** 按账户每月，非按容器：

| 维度 | 免费/月 | 超额（税前，2026-08-12）|
|------|---------|------------------------|
| 内存 `GB·s` | **400,000 GB·s** | €0.000002 / GB·s（€0.20/100k）|
| vCPU `vCPU·s` | **200,000 vCPU·s** | €0.00001 / vCPU·s（€1.00/100k）|
| 流量/临时盘 | — | **免费**（入/出免费，22GB 临时盘免费）|

- `min_scale=0`（截图中 0）时空闲不计费；Scaleway 提示 “This estimate does not take into account the free tier…”（图中右下角黑浮层）即此含义——估算 €18 扣掉免费后实付远更低。
- **算例**（建议配置 512MB/500mCPU，请求 3s 含流式）：
  - 日均 1k 次（月 30k）→ 45k GB·s + 15k vCPU·s → **€0**
  - 月 100k 次 → 150k + 50k → **€0**
  - 月 300k 次 → 460k GB·s 超 60k → **~€0.12**
  - 若按截图默认 2048MB/1000mCPU 且 12h/天常驻（1.3M s/月）→ 2.6M GB·s → **€4 + €11 ≈ €15**——所以请改小规格。
- **如何自查是否超额**：
  1. **Cost Manager**：控制台 `Billing → Cost Manager → Filter: Serverless Containers + 本月`，`Free Tier` 行显示抵扣，`Consumptions` 下无抵扣即未超。
  2. **账单**：`Billing → Invoices → 当月 → Serverless Containers Free Tier` 区块（无此块 = 未超）。
  3. **Billing alerts**：`Billing → Billing alerts → Create` 设 €1/€5 多档（Email/SMS/Webhook），超阈值实付触发。
  4. 容器页 `Metrics` 看 GB·s 趋势。
- **额外限制**：Scaleway 出口为法/荷机房 IP，upstream 按 Cloudflare L4 GeoIP + MaxMind/Spur ASN 识别为 `hosting/vpn` → 只给 `limited` 档（`mimo/mimo-v2.5` 唯一可用，或 `429` 额度），非 `banned`；这是网络归因非平台计费，`SAFE_MODE=true` 缓解但不消除。参见主 README Key Hygiene。

## 3. 截图逐项怎么填（对应 `/tmp/306821f4-...jpg`）

> 截图 UI：`Deploy a Container` → Source / Registry region / Registry namespace / Image:Tag / Port / Enter a name / Resources / Autoscaling / Configure advanced options (Data/Private Networks/Security/More)。

| 区域 | 字段 | 填什么（推荐） | 备注 |
|------|------|----------------|------|
| **Source** | 顶部三选一 | **Scaleway Images from your Scaleway Container Registry**（已选中第一项为正确） | `External` 用于 Docker Hub，`Quickstart` 是 hello-world |
| **Registry region*** | `AMS` 下拉 | 建议切 `PAR`（`fr-par` 对应 `rg.fr-par.scw.cloud`）| 要与之后 `SCW_REGISTRY_ENDPOINT` 前缀一致；图中 `AMS`（阿姆斯特丹）亦可，但法区更常用且 workflow 示例用 `fr-par` |
| **Registry namespace*** | `Registry namespace` 下拉 | 选或新建 `freebuff`（例: `freebuff`）| 先去 **Container Registry → Create namespace** 建 `freebuff`，类型选 `Private`（Scaleway 私有镜像需鉴权，容器可拉取） |
| **Image*** / **Tag*** | `Image` / `Tag` 下拉 | `freebuff-proxy` / `latest` | **必须先推送镜像（见 §4 步骤2），否则此必填项为空、表单无法提交** |
| **Port*** | 输入框 `8080` | **保持 `8080`，不要改 3457** | 必须与 `Dockerfile ENV PORT=8080` 一致；Scaleway 注入 `PORT=8080` 并以它做 TCP 健康检查；本分支已做 `LISTEN_ADDR`→`$PORT` 回退 |
| **Enter a name** | `Container name*` | `freebuff-proxy`（或保留自动 `container-flamboyant-wilson`） | 仅小写字母数字+连字符，暴露为子域 `...containers.<region>.scw.cloud` |
| **Container description/tags** | 可空 | 留空或 `freebuff proxy scaleway` | 不影响计费 |
| **Resources** | CPU* `1000 mVCPU` / Memory* `2048 MB` | **改小：CPU 500 mVCPU，Memory 512 MB**（极简可用 256MB/140mCPU）| 图中 1000/2048 是估算器默认偏大；Go 网关常驻 <100MB，流式 burst 亦不需 2GB，改小省免费额度 |
| **Autoscaling** | `Request concurrency` 选中；`Instances thresholds` `minimum (0)` `maximum (50)` `Maximum concurrent requests per instance 80` | **minimum 0，maximum 3，concurrent 80** | `0` 启用 scale-to-zero（空闲 €0）；图中 0/5/80 亦可，设 3 更省并发；`CPU/RAM percentage` 模式勿用 |
| **Configure advanced options → Data** | `Environment variables` Classic/JSON；`+ Add variable` | **无需普通变量**（`PORT` 自动）| 如需 `LOG_LEVEL=info` 可加普通变量； |
| **Secrets** | `+ Add secret` | **加 3 行 Secrets**（见下表）| Secrets 加密存储，保存后不回显；`SCW_*` 和 `PORT` 为保留前缀，勿用 |
| **Estimated cost / Average active time** | 右侧估算 | 无需改 | 忽略 €18 估算，看左侧免费额度扣除后实付 |

**Secrets 三行（Classic → + Add secret，Key=Value）：**

| Key（任选其一别名） | Value 示例 | 说明（必填） |
|---------------------|------------|--------------|
| `FREEBUFF_TOKEN` （或 `AUTH_TOKENS`） | `cb_abcdef123...` 多个逗号分隔亦可 | FreeBuff 上游 token，`cb_` 前缀；多 token 逗号分隔自动轮询；此为 3 变量之 1 |
| `API_KEY` （或 `API_KEYS` / `FREEBUFF_API_KEY`） | `sk-my-proxy-xxxx` 自定的强随机串 | 代理对外鉴权，客户端 `Authorization: Bearer <此值>`；为空则开放（不建议）；此为 3 变量之 2 |
| `ADMIN_TOKEN` （或 `ADMIN_PASSWORD`） | `$(openssl rand -hex 16)` 生成 32 位 | `/admin` 控制台与 `POST /admin/reload` 鉴权；留空走默认 `123456`（不安全）；此为 3 变量之 3 |

> 可选普通变量（+ Add variable）：`SAFE_MODE=true`（已默认 `true`，勿设 `false`）；`LOG_LEVEL=info`；调试 `LOG_FORMAT=json`；其它保持默认。

## 4. 分步：从零到可调用（含 workflow 一键更新）

### A. 控制台一次性建容器（5 分钟，必先推镜像）

1. **建 Container Registry Namespace**：控制台 → Storage → Container Registry → Create namespace；Region 选 `PAR`，Name `freebuff`，Privacy `Private`。
2. **先推送镜像（否则下一步的 `Image*` 为空、无法提交）**——二选一：
   - **本机推送（最快）**：于本仓库根执行（已含 `Dockerfile:23` 的 `ENV PORT=8080`）：
     ```bash
     docker login rg.fr-par.scw.cloud -u nologin --password-stdin <<< "$SCW_SECRET_KEY"
     docker build -t rg.fr-par.scw.cloud/freebuff/freebuff-proxy:latest .
     docker push rg.fr-par.scw.cloud/freebuff/freebuff-proxy:latest
     ```
     亦可 `SCW_SECRET_KEY` 取自控制台 `IAM → API keys`（`ContainerRegistry pull/push` + `Containers manage`）。
   - **用 GitHub 工作流推送**：先在你的 GitHub `Settings → Secrets → Actions` 填 `SCW_SECRET_KEY` 与 `SCW_REGISTRY_ENDPOINT=rg.fr-par.scw.cloud/freebuff`（`SCW_CONTAINER_ID` 留空），然后 `Actions → Deploy to Scaleway Containers → Run workflow`，待 `Build and push` 绿勾，镜像即出现在控制台下拉。
3. **建 Container**（即截图 `Deploy a Container` 页，此时 `Image*` 可选）：
   - 按上表选 `freebuff-proxy`/`latest`，填完 3 个 Secrets，点击 `Deploy container`。
   - 记下 `Container ID`（URL 中 `.../containers/<region>/<uuid>`）和 `Endpoint`（如 `https://freebuff-proxy-xxxxx.containers.par.scw.cloud`）。
4. **补齐 GitHub Secrets 供后续自动重部署**：回 GitHub `Settings → Secrets` 追加/更新：
   - `SCW_CONTAINER_ID` = 上一步的容器 UUID
   - `SCW_REGION` = `fr-par`（与 namespace 一致；留空默认 `fr-par`）
   - 已有 `SCW_SECRET_KEY` / `SCW_REGISTRY_ENDPOINT` 无需重建
5. **验证**：浏览器打开 `https://<your-endpoint>/healthz` → `{"status":"ok",...}`；再：
   ```bash
   curl https://<endpoint>/v1/models -H "Authorization: Bearer <API_KEY>"
   curl -N https://<endpoint>/v1/chat/completions \
     -H "Authorization: Bearer <API_KEY>" -H "Content-Type: application/json" \
     -d '{"model":"mimo/mimo-v2.5","messages":[{"role":"user","content":"hi"}],"stream":true}'
   ```
   Dashboard：`https://<endpoint>/admin` 用 `ADMIN_TOKEN` 登录。

### B. 以后：一推即更（workflow 已配好）

- 本仓库 `.github/workflows/scaleway.yml` 已在 `push: main` 时自动：
  1. `docker/login-action@v3` 登录 `rg.fr-par.scw.cloud`（`nologin` + `SCW_SECRET_KEY`）
  2. `docker/build-push-action@v6` 构建 `linux/amd64` → `push rg.fr-par.scw.cloud/freebuff/freebuff-proxy:latest`（`gha` 缓存 + `VERSION=<sha>`）
  3. `curl PATCH /containers/v1/...` 更 `registry_image`（v1 自动部署）→ `POST .../redeploy`（mutable tag 强制刷新，可选）
- 控制台 `Containers → 该容器 → Deployments` 看滚动更新（无 downtime，旧实例 draining 后切新）。

### C. 本地 docker 自检（未上云前可跑）

```bash
docker build -t freebuff-proxy:local .
docker run --rm -p 8080:8080 \
  -e PORT=8080 -e FREEBUFF_TOKEN=cb_test -e API_KEY=test -e ADMIN_TOKEN=123456 \
  freebuff-proxy:local
curl http://localhost:8080/healthz
# 期望 listen :8080, healthz 200
```

## 5. 常见排障（对应线上问题）

| 现象 | 原因 | 解法 |
|------|------|------|
| `container not ready` / `healthcheck failed on PORT 8080` | 镜像未更新到本分支或仍监听 `127.0.0.1:3457` | 确保 workflow 推送的是本分支镜像；`docker logs` 启动行应含 `listen_addr=:8080`；本地 `PORT=8080 go run ./cmd/freebuff-proxy -doctor` 验证端口 |
| `401 Unauthorized` 调 `/v1/models` | `API_KEY` 不一致 | Secrets 中 `API_KEY` 与客户端 `Authorization: Bearer <同一值>` 必须一致；空值则鉴权跳过但不推荐 |
| `403 country_blocked / banned` | Scaleway 机房 IP 被识别为 `hosting/vpn` | 仅请求 `mimo/mimo-v2.5`（limited 档可用）；勿配多 token 单 IP 高频；`SAFE_MODE=true` |
| `403 registry pull` / `image not found` | `SCW_SECRET_KEY` 权限或 region 前缀错 | IAM API key 赋 `ContainerRegistry` 读 + `Containers` 写；`rg.fr-par` vs `rg.nl-ams` 必须与 namespace/容器 region 一致 |
| `409 resource in transient state` 推送时 | PATCH 与 POST /redeploy 竞态 | 工作流已 `sleep 3`；重试；v1 PATCH 已 auto-deploy，POST 可忽略失败 |
| 更新后仍旧版 | 可变标签缓存 | 工作流做 `PATCH + redeploy` 强制刷新；或改 tag 为 `github.sha` 并 PATCH 新 tag |

## 6. 与上游同步（后续 `git pull`）

本分支仅对 `trefeon/freebuff-proxy` 增量：`git remote add upstream https://github.com/trefeon/freebuff-proxy` → `git fetch upstream` → `git merge upstream/main` → 解决 `Dockerfile`/`config_env.go` 冲突后 `git push` 即可自动重建镜像；漂移检测见 `.github/workflows/upstream-drift.yml`。

---
© MIT，沿用上游许可；计费以 [Scaleway Pricing](https://www.scaleway.com/en/pricing/serverless/) 与控制台估算器为准（2026-08-12）。

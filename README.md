# dsh on Render — DeepSeek Harness Web UI 部署包

把 DeepSeek Harness（`dsh`）以 Web Service 形式部署到 Render 的现成仓库文件包。

钉版：`@deepseek-ai/dsh 0.2.2-rc.5`（与自有 Ubuntu 主机上已验证的版本一致）、Node 24、Caddy 2.11.2、pnpm 12.21.0。

## 为什么需要这个包装

官方 dsh 只绑 `127.0.0.1`、明确拒绝 `--host 0.0.0.0`，且官方仓库没有 Dockerfile。本包的做法（与 Railway 社区模板的思路一致）：

- dsh 在容器内继续只听 `127.0.0.1:3080`
- Caddy 监听 Render 分配的 `$PORT`，做 HTTP Basic Auth 密码门，再反代到 dsh
- 启动时用 Render 自动提供的 `RENDER_EXTERNAL_URL` 给 dsh 传 `--public-url` + `--trusted-host`，这样日志里打印的 token 链接能直接打开，Settings → Models 也能正常用
- 状态（`~/.dsh`、工作区）全部落在 Render 持久盘 `/data` 上，重新部署不丢

> ⚠️ **安全边界就只有那道密码门。** 能通过 Basic Auth 的人就能让 agent 在这个容器里执行 shell 命令、读到你的模型 API key。`DSH_UI_PASSWORD` 必须用长随机密码，并存进你的密码管理器，不要复用其他密码。

## 部署步骤

1. **推到 GitHub**：把本包所有文件放在一个新仓库根目录，推到你的 GitHub 账号下，例如 `anothersday/dsh-render`。
2. **在 Render 创建**：Render Dashboard → **New → Blueprint** → 选这个仓库。Render 会读 `render.yaml`，创建 1 个 Web Service（Standard 套餐，新加坡区）+ 1 块 2 GB 持久盘。
   - 也可以不用 Blueprint：New → Web Service → 选仓库 → Runtime 选 Docker，再手动加盘（挂载点 `/data`）和下面的环境变量，效果相同。
3. **填两个 secret**（创建时 Render 会问，`sync: false` 的项不会进 git）：
   - `DSH_UI_PASSWORD`：密码门的密码（必填，没填容器会拒绝启动）
   - `DEEPSEEK_API_KEY`：可空。空着也能部署，首次登录后在 **Settings → Models** 里贴
   - `DSH_PUBLIC_URL`：可空。用 Render 默认域名时留空（自动用 `RENDER_EXTERNAL_URL`）；以后绑了自定义域名再填，如 `https://dsh.example.com`，然后重新部署一次
4. **首次登录**：部署完成后打开 Render 的 **Logs**，找 dsh 打印的这一行：
   `dsh web: https://<你的服务>.onrender.com/?token=...`
   打开这个链接 → 先过 Basic Auth 弹窗（用户 `admin`，或你改的 `DSH_UI_USERNAME`；密码是第 3 步那个）→ 进入 UI。token 换成会话 cookie（约 30 天），之后直接开域名即可。
   - 注意：**每次重启 token 都会变**。cookie 过期或换浏览器后，再去 Logs 里抄新链接。
   - 进 UI 后顺手在设置里关掉「发送会话日志给 DeepSeek」那个默认开启的开关（遥测本身已通过 `DSH_TELEMETRY_MODE=DISABLED` 关掉）。
5. **选工作区**：默认工作区在 `/data/workspace`。要让 agent 干活，把项目 clone 到 `/data` 下面再在 UI 里选目录——`/data` 之外写的东西重新部署就没了。

## 费用与套餐

- 必须用**付费套餐**：免费 Web Service 没有持久盘、闲置 15 分钟会休眠。`render.yaml` 里选的是 Standard（2 GB 内存）——dsh 本体空闲约占 430 MB，512 MB 的 Starter 跑 agent 任务容易爆内存。另加持久盘 2 GB 的费用。
- 区域选了 Singapore（离国内最近的 Render 区）；想换在 `render.yaml` 改 `region`。

## 环境变量一览

| 变量 | 必填 | 说明 |
|---|---|---|
| `DSH_UI_PASSWORD` | ✅ | Basic Auth 密码，唯一的门 |
| `DSH_UI_USERNAME` | 否 | 默认 `admin` |
| `DEEPSEEK_API_KEY` | 否 | 不填就部署后在 Settings → Models 贴 |
| `DSH_PUBLIC_URL` | 否 | 自定义域名时填；默认域名留空 |
| `DSH_TELEMETRY_MODE` | 否 | 已在 render.yaml / Dockerfile 里设为 `DISABLED` |

## 本地验证（可选）

本包在交付前已用同版本 dsh + Caddy 在本地实测过完整链路：`/healthz` 200、无密码 401、Basic Auth 过但无 token 401、带 token 303 换 cookie 后 UI 200、错密码 401。

有 Docker 的机器上可复现：

```bash
docker compose up --build
# 然后看日志里的 token 链接（本地版 public-url 是 http://127.0.0.1:10000）
```

## 升级 dsh

改 `Dockerfile` 顶部的 `ARG DSH_VERSION` 到新版本，推送，Render 自动重新部署。dsh 仍是 developer preview，版本间可能有破坏性变更，升级前看官方 release notes；持久盘里的数据保留，但重要工作请另外备份（容器能执行命令，盘不是备份）。

## 文件清单

| 文件 | 作用 |
|---|---|
| `Dockerfile` | Node 24 + dsh + pnpm + Caddy 的包装镜像 |
| `Caddyfile` | `$PORT` 上的 Basic Auth + 反代 + `/healthz` |
| `entrypoint.sh` | 生成密码哈希、推导 public-url/trusted-host、先起 dsh 再起 Caddy |
| `render.yaml` | Render Blueprint：套餐、区域、持久盘、环境变量 |
| `docker-compose.yml` | 仅本地验证用，Render 不读它 |

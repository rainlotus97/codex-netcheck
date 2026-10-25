---
name: codex-netcheck
description: "Codex 网络与代理链路自检/自愈。当 Codex 出现 `stream disconnected before completion: Connection reset by peer (os error 54)`、Responses WebSocket 连接失败、每轮先 Reconnecting 5/5 再降级 HTTPS、400「model requires a newer version of Codex」，或用户说 Codex 断流 / 连不上 / 要自检网络时使用。"
---

# Codex 网络自检（codex-netcheck）

Codex 的 Responses WebSocket 和 HTTPS 请求可能来自终端、IDE 或 Dock/Finder 启动的 GUI App。代理链路分三层，任何一层缺失都可能导致断流：

1. **config 层**：`$CODEX_HOME/config.toml` 的 `[features] respect_system_proxy = true`，让 WebSocket 首包就走系统代理。
2. **shell 层**：`~/.zshenv` 中带端口探活的自动代理块，覆盖终端、IDE 集成终端、脚本和 MCP / npx 子进程。
3. **GUI 层**：macOS LaunchAgent `com.codex-netcheck.proxy-sync` 用 `launchctl setenv` 同步代理变量，覆盖 Dock/Finder 启动的 App。

`codex-netcheck` 一次查完三层；`--fix` 幂等修复 config、shell 和 GUI 层。默认按 macOS 的 `scutil --proxy` 探测本地代理端口，其次使用 `--port` / `CODEX_NETCHECK_PORT`，最后回退到 `7897`。

## 用法

已安装到 PATH 时：

```bash
codex-netcheck --json            # 只读自检（2-4 秒），优先用这个
codex-netcheck                   # 人类可读版
codex-netcheck --doctor          # 追加 codex doctor 体检（WebSocket 期望 HTTP 101）
codex-netcheck --live            # 真实端到端 exec（一次很小的模型调用，让用户终端跑）
codex-netcheck --fix             # 幂等修复：config / ~/.zshenv / 重装 GUI 同步器
codex-netcheck --fix --update    # 版本过旧时顺带升级 codex
codex-netcheck --port 8080       # 非默认代理端口（仅在没有系统代理时作为回退）
```

未安装到 PATH 时，直接调用 skill 内脚本：

```bash
"${CODEX_HOME:-$HOME/.codex}/skills/codex-netcheck/scripts/netcheck.sh" --json
```

退出码：`0` 全绿 / `1` 有警告 / `2` 有失败。`--json` 的 stdout 是纯 JSON，包含 `{level, counts, proxy, checks[], fixes[], advice[]}`，人类提示走 stderr。

## 处理流程

1. 先跑 `codex-netcheck --json`，读 `level`、`counts` 和 `checks[]`。
2. 按 `checks[].id` 定位问题：

| id | 失败/警告含义 | 处理 |
|---|---|---|
| `codex_bin` | PATH 里找不到 `codex` | 安装 Codex CLI 或修正 PATH |
| `codex_version` | 版本过旧（400 model requires newer） | `--fix --update` |
| `config_proxy` | 缺 `respect_system_proxy`（断流主因） | 让用户在普通终端跑 `--fix` |
| `system_proxy` | macOS 系统代理未开启 | 在代理客户端打开「系统代理」 |
| `proxy_port` | 代理客户端未启动 / 端口被改 | 启动代理，或确认 `--port` |
| `proxy_https` | 端口通但出网失败（节点 / 规则） | 换节点或检查规则后重跑 |
| `shell_env` | 当前终端没有代理变量 | 新开终端，或加载 shell 配置 |
| `zshenv` / `gui_env` / `sync_agent` | 环境层缺失 | 让用户跑 `--fix` |
| `recent_errors` | 近 30 分钟有断流日志 | 其它项全 ok → 旧进程残留，重启 App / 终端 |
| `big_threads` | 有 >50MB 的超大会话（含大量截图） | 恢复它们会重传 MB 级请求体 |
| `large_requests` | 近 30 分钟 `tls handshake eof` / `Broken pipe` | 大请求 + 上行慢，不是配置问题 |
| `upload` | `--speed` 测得的代理上行速度 | <100KB/s 时换上行更快的节点 |
| `handshake` | `--handshake` 的握手成功率 / 抖动 | 成功率不满或抖动大 → 换稳定节点 |
| `live` | 端到端仍失败 | 再跑 `--doctor` 看 WebSocket 明细 |
| `doctor_websocket` | WebSocket 未连接 | 期望 `HTTP 101 Switching Protocols` |
| `system_proxy` / `gui_env` 等 info | 非 macOS 的降级项 | 按所用 shell 手动配置环境变量 |

3. **修复要写 `$CODEX_HOME/`、`~/.zshenv`、`~/Library/LaunchAgents/`，Codex 沙箱内通常不可写。不要绕过沙箱，把命令交给用户在普通终端执行：**
   - `codex-netcheck --fix`
   - 版本过旧时：`codex-netcheck --fix --update`
4. 修完用 `codex-netcheck --doctor` 复验，`doctor_websocket` 应为 ok（`HTTP 101 Switching Protocols`）。
5. 告诉用户：**新开终端** + **重启 ChatGPT / Codex App**，旧进程的残留断流才会消失。

## 平台差异

- **macOS**：完整支持 config、shell、GUI 三层，以及 `scutil --proxy` 自动探测。
- **Linux / Windows（WSL、Git Bash）**：可运行降级检查；没有 `scutil` / `launchctl`，`system_proxy`、`zshenv`、`gui_env`、`sync_agent` 会以 info 跳过，`--fix` 只修改 config。请让用户按自己的 shell 手动配置 `http_proxy` / `https_proxy` / `no_proxy`。

## 任务中途断流（`tls handshake eof` / `websocket closed by server`）

用户反馈"跑到一半弹出 `stream disconnected before completion: tls handshake eof`"时，**不要查配置**——这是连接建立阶段被对端关闭，属于节点/链路瞬时故障。Codex 每轮请求都会新建 TLS 连接，节点一抖就会撞上。

按这个顺序做：

```bash
codex-netcheck --handshake   # 连续 6 次握手：成功率 / 耗时范围 / 抖动
codex-netcheck --speed       # 上行带宽（大上下文请求的瓶颈）
```

判定与处理：

| 探针结果 | 结论 | 处理 |
|---|---|---|
| 6/6 成功，1–3s | 节点健康 | 偶发 1–2 次可忽略，Codex 会自动重试 |
| 6/6 成功，最大 ≥6s 或抖动 ≥4s | 节点拥塞 | 换更稳的节点 |
| 出现失败 | 节点在丢握手，中途断流高发 | 换节点 |
| 全失败 | 节点不可用 | 先换节点 |

告诉用户：**固定一个稳定节点，不要用 `url-test` / 自动选择这类会中途切换的分组**（长任务中途切换必然打断正在建立的握手）。同一轮连续 5 次失败才是真正致命，偶发重试恢复的不用处理。

## 老会话恢复仍然断流（重要）

如果用户说"新会话正常，但恢复旧会话还是断流/卡住"，**不要再查 respect_system_proxy**——先跑：

```bash
codex-netcheck --speed     # 代理上行速度
codex-netcheck --handshake # 连续 6 次 TLS 握手：成功率 + 耗时抖动（诊断中途断流）
codex-netcheck             # 看 big_threads / large_requests
```

- 原因通常是：老会话含大量截图（单个会话可达数十上百 MB），恢复/预压缩时要重传 MB 级请求体；而代理节点**上行**可能只有几十 KB/s（下行正常不代表上行正常）。
- 处理：让用户换一个上行更快的节点后 `--speed` 复测；或在**新会话**继续（新会话请求体小）。
- 可选缓解：`[features] compaction_image_budget = false`（减少压缩请求里的图片）。
- 这类问题用 `--fix` 修不了，不要反复改配置。

## 硬性约束

- 不要手改 `$CODEX_HOME/config.toml`，也不要用临时 `export` 代理应付；统一走 `codex-netcheck --fix`。
- 不要在 Codex 会话里跑 `--live`（会嵌套 codex 进程）；让用户在普通终端跑。
- 不要重启用户的 App，不要 kill 进程。
- 不要把 `--json` 的人类提示混进 stdout；需要展示给用户时读 stderr 或直接跑人类可读模式。
- 完整背景、原理与回滚：项目仓库的 `docs/TROUBLESHOOTING.md`。

# codex-netcheck

**Codex 网络 / 代理链路自检与自愈。**

一条命令检查 Codex CLI、Codex App（ChatGPT.app 内置引擎）和 VS Code Codex 的代理配置、环境变量与出网能力；在 macOS 上还能用 `--fix` 幂等补齐三层代理链路。

[中文](#它解决什么问题) · [English summary](#english-summary) · [License](#license)

---

## 它解决什么问题

Codex 走 `wss://chatgpt.com/backend-api/codex/responses` 时，如果 Responses WebSocket 没有走代理，常见表现是：

```text
ERROR codex_api::endpoint::responses_websocket: failed to connect to websocket:
IO error: Connection reset by peer (os error 54)
ERROR: Reconnecting... 1/5 ... 5/5
warning: Falling back from WebSockets to HTTPS transport.
stream disconnected before completion: Connection reset by peer (os error 54)
```

每轮先空转重试，最后才降级到 HTTPS；有时能继续对话，但首字延迟明显变长。另一类问题是 Codex 版本过旧，即使网络已通也会返回：

```text
400 The '...' model requires a newer version of Codex
```

`codex-netcheck` 把这两类问题拆成可观察、可修复的检查项：先定位是哪一层没把代理交给 Codex，再给出下一步命令。它不替代代理客户端，也不会修改代理软件的路由规则。

## 三层代理链路

Codex 的请求可能来自终端、IDE 或 Dock/Finder 启动的 GUI App，因此需要同时检查三层：

| 层 | 作用范围 | 关键位置 |
|---|---|---|
| **config 层** | Codex 自身是否读取系统代理 | `$CODEX_HOME/config.toml` 中的 `[features] respect_system_proxy = true` |
| **shell 层** | 终端、IDE 集成终端、脚本、MCP 子进程 | `~/.zshenv` 中的自动代理块（端口探活后才注入变量） |
| **GUI 层** | Dock/Finder 启动的 App | macOS LaunchAgent 定期用 `launchctl setenv` 同步代理变量 |

```text
Codex / ChatGPT.app / VS Code
        │
        ├── config 层：respect_system_proxy
        ├── shell 层：http(s)_proxy / all_proxy / no_proxy
        └── GUI 层：launchctl setenv（macOS）
                    │
                    ▼
        本地代理客户端（HTTP / SOCKS 混合端口，默认 7897）
                    │
                    ▼
            chatgpt.com / npm registry
```

脚本只依赖系统命令（`bash`、`curl`、`nc`，部分功能用 `python3`），可被任意 Agent 直接调用。

## 检查项

| id | 检查内容 | 常见处理 |
|---|---|---|
| `codex_bin` | `codex` 是否在 PATH 中 | 安装 Codex CLI，或修正 PATH |
| `codex_version` | 是否落后于 npm 最新稳定版 | `codex-netcheck --fix --update` |
| `config_proxy` | `respect_system_proxy = true` 是否写入且生效 | `--fix` |
| `config_quiet` | 是否关闭开发特性启动警告 | 可选，不影响链路 |
| `system_proxy` | macOS 系统代理是否开启（自动读取 `scutil --proxy`） | 在代理客户端打开「系统代理」 |
| `proxy_port` | 本地代理端口是否可连通 | 启动代理客户端，或改用 `--port` |
| `shell_env` | 当前 shell 是否已有代理变量、是否排除 localhost | 新开终端，或加载 shell 配置 |
| `zshenv` | `~/.zshenv` 是否含自动代理块 | `--fix` |
| `gui_env` | GUI 会话是否有 `https_proxy` | `--fix` |
| `sync_agent` | LaunchAgent 是否安装并运行 | `--fix` |
| `proxy_https` | 经代理访问 `chatgpt.com` 的状态 | 检查代理节点 / 规则 |
| `direct` | 不经代理直连的对照结果 | 国内被重置属预期，仅作信息 |
| `recent_errors` | 近 30 分钟 Codex 日志中的断流次数 | 重启 App / 终端，排除旧进程残留 |
| `big_threads` | 是否存在 >50MB 的历史会话（多为截图） | 恢复这类会话会重传 MB 级请求体 |
| `large_requests` | 近 30 分钟 `tls handshake eof` / `Broken pipe` 次数 | 大请求 + 上行慢，见 FAQ |
| `upload` | 代理**上行**速度（`--speed`，1MB 实测） | 换上行更快的节点 |
| `remote_control` | 近 30 分钟 remote-control WebSocket 失败 | App 后台进程问题，重启 App |
| `doctor_websocket` | `codex doctor` 的 WebSocket 状态 | 期望 `HTTP 101 Switching Protocols` |
| `doctor_reach` | provider 端点可达性 | 检查节点 / DNS / 规则 |
| `doctor_respect` | doctor 报告的 respect system proxy | 与 `config_proxy` 对照 |
| `live` | 真实端到端请求（一次很小的模型调用） | 失败时再跑 `--doctor` |

在非 macOS 平台上，macOS 专属项会以 `info` 跳过；请改用 shell / 进程环境变量。

退出码：`0` 全绿 · `1` 有警告 · `2` 有失败。

## 安装

### 环境要求

- **macOS**：完整支持 config / shell / GUI 三层。建议 macOS 12+。
- **Linux / Windows（WSL、Git Bash）**：可运行降级检查；没有 `scutil` / `launchctl`，不会安装 GUI 同步器。
- `bash` 3.2+（macOS 自带版本即可）、`curl`、`nc`。
- `codex` 可选：没有安装时只跳过 Codex 相关检查。
- `python3` 可选：用于版本比较、读取日志和 `--json`；没有时 `--json` 会明确报错。

### 从仓库安装

```bash
git clone <your-repository-url> codex-netcheck
cd codex-netcheck
./scripts/install.sh
```

安装脚本只做两件事：

1. 把 `SKILL.md` 与 `scripts/` 复制到 `${CODEX_HOME:-$HOME/.codex}/skills/codex-netcheck/`；
2. 创建 `~/.local/bin/codex-netcheck` 符号链接，指向已安装的主脚本。

它**不会**修改 `config.toml`、`~/.zshenv` 或 LaunchAgent；这些改动只会在你显式运行 `codex-netcheck --fix` 时发生。

如果 `~/.local/bin` 不在 PATH 中：

```bash
export PATH="$HOME/.local/bin:$PATH"
```

建议把上面一行加入自己的 shell 配置。然后验证：

```bash
codex-netcheck --json
```

### 可选：安装 `/netcheck` slash 命令

```bash
mkdir -p "${CODEX_HOME:-$HOME/.codex}/prompts"
cp prompts/netcheck.md "${CODEX_HOME:-$HOME/.codex}/prompts/"
```

之后可在 Codex TUI 中输入 `/netcheck`。

## 用法

```bash
codex-netcheck                  # 快速自检（约 2-4 秒）
codex-netcheck --json           # 机器可读输出（适合 Agent 解析）
codex-netcheck --doctor         # 追加 codex doctor 体检（约 15-20 秒）
codex-netcheck --live           # 追加真实端到端 exec（会产生一次很小的模型调用）
codex-netcheck --speed          # 只测代理上行速度（恢复大历史会话的关键指标）
codex-netcheck --all            # 快速自检 + doctor + live + speed
codex-netcheck --fix            # 幂等修复 config / ~/.zshenv / GUI 同步器（macOS）
codex-netcheck --fix --update   # 若版本落后，顺带升级 codex
codex-netcheck --port 8080      # 指定本地代理端口（默认 7897）
codex-netcheck --version        # 输出版本号
```

`--json` 的 stdout 是纯 JSON，人类提示全部走 stderr：

```bash
codex-netcheck --json | python3 -m json.tool
```

输出包含 `version`、`level`、`exit`、`counts`、`proxy`、`checks[]`、`fixes[]`、`advice[]`。

### 端口配置

代理端口按以下优先级确定：

1. **`scutil --proxy` 自动探测**（macOS 系统代理开启时）；
2. `--port <n>` 或环境变量 `CODEX_NETCHECK_PORT`；
3. 默认 `7897`。

因此，如果 macOS 系统代理已开启，脚本会以系统代理实际端口为准；`--port` 主要在没有系统代理时使用。

```bash
CODEX_NETCHECK_PORT=1080 codex-netcheck --json
codex-netcheck --port 1080
```

### 建议的处理顺序

1. 先跑 `codex-netcheck --json`，读 `level` 和 `checks[]`。
2. 先处理 `config_proxy`、`proxy_port`、`system_proxy`，再处理环境层。
3. 需要修复时，在**普通终端**运行 `codex-netcheck --fix`；不要让 Agent 绕过 Codex 的沙箱去改 `~/.codex`。
4. 修复后新开终端，并重启 ChatGPT / Codex App，让旧进程重新读取环境。
5. 用 `codex-netcheck --doctor` 复验；`doctor_websocket` 为 `HTTP 101` 即正常。

### macOS 上的代理客户端

脚本不绑定某个代理软件。Clash、Clash Verge、V2Ray、Stash 等只要提供一个本地 HTTP / SOCKS 混合端口即可；默认按 `7897` 处理，端口不同就用 `--port` 或 `CODEX_NETCHECK_PORT` 指定。

- 需要打开代理客户端的「系统代理」，config 层和系统代理检测都依赖它。
- `--fix` 会写入一个 `launchctl` 同步器，使 Dock/Finder 启动的 App 也能拿到代理变量。
- 如果端口只支持 HTTP、不支持 SOCKS，`all_proxy` 可能不可用；`http_proxy` / `https_proxy` 仍会生效。

### Linux / Windows 的降级行为

macOS 以外的平台没有 `scutil` 和 `launchctl`，脚本会：

- 跳过 `system_proxy`、`zshenv`、`gui_env`、`sync_agent` 这些 macOS 专属检查，并以 `info` 标注；
- 继续检查 `codex`、config、端口连通性、经代理出网、版本与日志；
- `--fix` 在非 macOS 上只修改 `config.toml`，不会写 LaunchAgent，也不会自动写 `~/.zshenv`。

请按所用 shell 手动配置代理，例如：

```bash
export http_proxy="http://127.0.0.1:7897"
export https_proxy="$http_proxy"
export no_proxy="localhost,127.0.0.1,::1,.local,192.168.0.0/16,10.0.0.0/8,172.16.0.0/12"
```

Windows 原生 PowerShell 没有完整支持；建议在 WSL 或 Git Bash 中使用，并把端口和代理地址替换为 Windows 主机上的实际值。Linux 下如使用 zsh，也可以把等价配置写入自己的 shell 启动文件。

## 安全、隐私与回滚

- 脚本不发送遥测，不上传任何文件；联网请求只用于检查 npm 版本和 `chatgpt.com` 连通性。
- `--live` 会产生一次真实的模型调用，请只在普通终端按需运行。
- `--fix` 只改与代理相关的文件，并在改 `config.toml` 前保留带时间戳的备份。
- 脚本不会 kill 进程、不会重启 App、不会修改代理软件配置。
- 完整根因、验证命令和回滚步骤见 [docs/TROUBLESHOOTING.md](docs/TROUBLESHOOTING.md)。

## FAQ

**Q：`--json` 显示 0 fail，但 App 还是断流？**

A：旧进程可能仍在使用修复前的环境。新开终端，并完全退出后重启 ChatGPT / Codex App；必要时再跑一次 `--doctor`。

**Q：为什么没有 fail 还有 warn？**

A：`warn` 通常来自当前终端没有加载代理变量，或近 30 分钟日志里还有旧进程的断流记录。它们不影响脚本继续检查，但值得按 `advice` 处理。

**Q：新会话正常，但恢复旧的超长会话还是断流/卡住？**

A：这不是代理配置问题，而是**上行带宽**。老会话里常有大量截图（实测一个会话可含 240 张、322MB 图片），恢复时要把当前上下文重新上传，请求体可达数 MB；如果代理节点下行 2MB/s 但上行只有 60KB/s，几 MB 的请求要传一分钟以上，Codex 会超时并报 `tls handshake eof` / `Broken pipe` / `stream disconnected`。处理方法：

1. 跑 `codex-netcheck --speed`；上行 <100KB/s 基本无法恢复大历史会话，换一个上行更快的节点后重测；
2. 或在**新会话**里继续（新会话请求体小，通常正常）；
3. 工具会用 `big_threads` / `large_requests` 把这两类问题标出来。

**Q：`--fix` 安全吗？**

A：它是幂等的，只修改代理相关文件；`config.toml` 会先备份。它不会重启 App 或 kill 进程。首次使用前建议阅读 [故障排查与回滚](docs/TROUBLESHOOTING.md)。

**Q：没有安装 Codex CLI 能用吗？**

A：可以。`codex_bin`、`codex_version`、`doctor_*`、`live` 会跳过或显示信息；代理端口、系统代理和环境层检查仍会运行。

**Q：为什么不直接开 TUN 模式？**

A：TUN 会改变整机路由，通常需要系统服务和管理员权限。本工具优先用 config + 环境变量做小范围、可回滚的修复；TUN 可以作为其它 GUI 程序也受影响的兜底方案。详见故障排查文档。

**Q：JSON 为什么有中文？**

A：输出使用 UTF-8 和 `ensure_ascii=False`，便于人和 Agent 阅读；字段名保持英文稳定。

## License

[MIT](LICENSE)。版权与许可文本见 `LICENSE`。

---

## English summary

`codex-netcheck` is a small, dependency-light Bash diagnostic tool for Codex network and proxy problems. It targets the common `stream disconnected before completion: Connection reset by peer (os error 54)` loop and the `400 ... requires a newer version of Codex` error.

It inspects three layers: Codex's `respect_system_proxy` config, shell proxy variables (`~/.zshenv`), and—on macOS—a LaunchAgent that propagates proxy variables to GUI apps via `launchctl setenv`. The optional `--fix` mode repairs the three layers idempotently.

```bash
./scripts/install.sh
codex-netcheck --json
codex-netcheck --fix
```

- Full support: macOS.
- Degraded mode: Linux / Windows (WSL or Git Bash); GUI-layer and system-proxy checks are skipped.
- Exit codes: `0` healthy, `1` warnings, `2` failures.
- Port precedence: `scutil --proxy` > `--port` / `CODEX_NETCHECK_PORT` > `7897`.
- License: MIT.

See [docs/TROUBLESHOOTING.md](docs/TROUBLESHOOTING.md) for root-cause analysis and rollback steps.

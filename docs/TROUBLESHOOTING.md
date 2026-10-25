# Codex 断流与代理故障排查

本文说明 `stream disconnected before completion: Connection reset by peer (os error 54)`、Responses WebSocket 反复重连、以及 `400 ... requires a newer version of Codex` 的常见根因、三层修复思路和回滚步骤。内容面向 macOS，Linux / Windows 的降级行为在文末单独说明。

## 1. 典型现象

Codex 每轮请求先尝试 WebSocket，失败后重试：

```text
ERROR codex_api::endpoint::responses_websocket: failed to connect to websocket:
IO error: Connection reset by peer (os error 54), url: wss://chatgpt.com/backend-api/codex/responses
ERROR: Reconnecting... 1/5
...
ERROR: Reconnecting... 5/5
warning: Falling back from WebSockets to HTTPS transport.
stream disconnected before completion: Connection reset by peer (os error 54)
```

常见伴随现象：

- 每轮对话开始前空等数秒，最后才降级到 HTTPS；
- 网络本身能打开网页，但 Codex 的 WebSocket 始终连不上；
- 代理软件显示系统代理已开启，GUI App 仍然直连；
- 某次升级模型后所有请求返回 `400`，提示当前 Codex 版本太旧；
- Codex App 后台日志持续出现 `remote/control` WebSocket 重连。

## 2. 根因分析

这类问题通常不是单个原因，而是「网络路径」和「客户端版本」叠加。两个根因缺一不可地检查：

### 2.1 Responses WebSocket 没有拿到代理

`wss://chatgpt.com/backend-api/codex/responses` 是 WebSocket 连接。它不一定会自动继承以下任一项：

- macOS 的「系统代理」设置；
- 当前 shell 的 `http_proxy` / `https_proxy`；
- 从 Dock / Finder 启动的 GUI App 的进程环境。

如果 Codex 版本中的 `respect_system_proxy` 为 `false`，且进程环境也没有代理变量，WebSocket 就可能裸连。链路上的 TCP 重置会表现为 `ECONNRESET`，也就是 `os error 54`。

可以用两个对照确认方向：

```bash
# 直连：在受限网络里可能超时或被重置
curl -sS -o /dev/null -w '%{http_code}\n' --noproxy '*' --max-time 8 \
  https://chatgpt.com/backend-api/

# 经本地代理：401 / 403 / 200 / 204 / 405 都说明「代理链路可达」
curl -sS -o /dev/null -w '%{http_code}\n' --max-time 8 \
  -x http://127.0.0.1:7897 https://chatgpt.com/backend-api/
```

如果直连失败、经代理可达，问题基本在代理继承，而不是代理客户端本身。

### 2.2 Codex 版本与模型不匹配

即使代理已经正常，过旧的 Codex 仍可能返回：

```text
400 The '...' model requires a newer version of Codex
```

这类错误和断流是两回事。先修网络，再升级客户端；或者直接使用：

```bash
codex-netcheck --fix --update
```

`--fix --update` 会经代理检查 npm 最新稳定版并调用 `codex update`。升级过程中需要代理可用。

## 3. 三层代理链路

代理只在某一个入口生效是不够的，因为 Codex 可能从不同上下文启动。

| 层 | 覆盖对象 | 实现 |
|---|---|---|
| config 层 | Codex 自身 | `$CODEX_HOME/config.toml` 的 `respect_system_proxy = true` |
| shell 层 | 终端、IDE 集成终端、脚本、MCP / npx 子进程 | `~/.zshenv` 自动注入代理变量 |
| GUI 层 | Dock / Finder 启动的 App | LaunchAgent 定期 `launchctl setenv` |

### 3.1 config 层

在 `$CODEX_HOME/config.toml` 中：

```toml
suppress_unstable_features_warning = true

[features]
respect_system_proxy = true
```

`respect_system_proxy` 是让 Codex 的 WebSocket / HTTPS 从首包开始就考虑系统代理的关键。`suppress_unstable_features_warning` 只是减少启动提示，不是链路必需项。

`codex-netcheck --fix` 会幂等补全这两项；写入前会在同一目录生成 `config.toml.bak.<timestamp>` 备份。不要在 Codex 沙箱里直接改这个文件，也不要用临时 `export` 代替持久配置。

### 3.2 shell 层

`--fix` 会向 `~/.zshenv` 追加类似下面的块（端口以实际配置为准）：

```sh
# >>> 自动代理：Codex 断流修复（本地代理端口 7897）>>>
if command -v nc >/dev/null 2>&1 && nc -z -G 1 127.0.0.1 7897 >/dev/null 2>&1; then
  export http_proxy="http://127.0.0.1:7897"
  export https_proxy="$http_proxy"
  export all_proxy="socks5://127.0.0.1:7897"
  export HTTP_PROXY="$http_proxy"
  export HTTPS_PROXY="$http_proxy"
  export ALL_PROXY="$all_proxy"
  export no_proxy="localhost,127.0.0.1,::1,.local,192.168.0.0/16,10.0.0.0/8,172.16.0.0/12"
  export NO_PROXY="$no_proxy"
fi
# <<< 自动代理 <<<
```

设计要点：

- 先探测端口，代理没启动就跳过，不会把流量导向死端口；
- `no_proxy` 只包含本地与私有网段，避免内网服务被代理；
- 覆盖大小写变量，兼容不同工具链；
- 只对 zsh 的 `.zshenv` 自动写入；bash / fish 用户需要自行配置。

`.zshenv` 只在新启动的 zsh 进程中自动加载。已有终端不会重新读取，所以修复后必须**新开终端**，或者手动 `source ~/.zshenv`。

### 3.3 GUI 层（仅 macOS）

`codex-netcheck --fix` 会创建并加载：

| 项目 | 路径 / 值 |
|---|---|
| LaunchAgent label | `com.codex-netcheck.proxy-sync` |
| 同步脚本 | `~/.local/bin/codex-netcheck-proxy-sync.sh` |
| plist | `~/Library/LaunchAgents/com.codex-netcheck.proxy-sync.plist` |
| 日志 | `~/Library/Logs/codex-netcheck-proxy-sync.log` |

同步脚本每 20 秒探测一次本地代理端口：

- 端口可用：`launchctl setenv` 写入 `http_proxy` / `https_proxy` / `all_proxy` / `no_proxy` 及大写变量；
- 端口不可用：`launchctl unsetenv` 清除这些变量。

它解决的是 Dock / Finder 启动的 App 不读 `~/.zshenv` 的问题。即使以后 Codex 移除了 `respect_system_proxy`，GUI 层提供的环境变量仍能作为兜底。

这是可选层：如果系统里已经通过其它方式给 GUI 会话设置了代理，脚本会把 `sync_agent` 标为 `info`，而不是强制要求安装本项目的 LaunchAgent。

### 3.4 生效条件

1. 新开终端；
2. 完全退出并重启 ChatGPT / Codex App，让旧后台进程重新读取 config 和环境；
3. 保持代理客户端的「系统代理」开启；
4. 如果希望重启电脑后仍可用，考虑让代理客户端开机自启。

旧进程可能仍持有修复前的环境。日志里看到的断流记录不一定代表修复失败，先重启再判断。

## 4. 检查项与处理

| id | 含义 | 处理 |
|---|---|---|
| `codex_bin` | `codex` 是否在 PATH | 安装 CLI 或修正 PATH |
| `codex_version` | 是否落后于 npm 最新版 | `codex-netcheck --fix --update` |
| `config_proxy` | `respect_system_proxy` 是否生效 | `codex-netcheck --fix` |
| `config_quiet` | 是否关闭开发特性警告 | 可选 |
| `system_proxy` | macOS 系统代理是否开启 | 在代理客户端打开「系统代理」 |
| `proxy_port` | 本地端口是否连通 | 启动代理，或用 `--port` 指定 |
| `shell_env` | 当前终端是否有代理、是否排除 localhost | 新开终端 / 加载配置 |
| `zshenv` | 自动代理块是否存在 | `codex-netcheck --fix` |
| `gui_env` | GUI 会话是否有代理变量 | `codex-netcheck --fix` |
| `sync_agent` | LaunchAgent 是否安装并在运行 | `codex-netcheck --fix` |
| `proxy_https` | 经代理访问 chatgpt.com 的 HTTP 状态 | 换节点 / 查规则 |
| `direct` | 直连对照结果 | 通常只作信息，不单独作为失败依据 |
| `recent_errors` | 近 30 分钟断流日志数 | 若其它都正常，重启 App / 终端 |
| `remote_control` | 近 30 分钟 remote-control 失败数 | 重启 App |
| `doctor_websocket` | codex doctor 的 WebSocket 状态 | 期望 `HTTP 101 Switching Protocols` |
| `doctor_reach` | provider 端点可达性 | 检查节点 / DNS |
| `doctor_respect` | doctor 看到的 respect 状态 | 与 config 对照 |
| `live` | 真实端到端请求 | 失败时看 doctor 明细 |

## 5. 验证命令

```bash
# 版本与特性
codex --version
codex features list | grep respect

# WebSocket / 连通性（期望 101）
codex doctor | sed -n '/^Connectivity/,/^Background/p'

# GUI 会话变量（macOS）
launchctl getenv https_proxy

# 新 shell 的变量
zsh -c 'echo "$https_proxy"'

# 同步器日志
tail -n 20 ~/Library/Logs/codex-netcheck-proxy-sync.log

# 脚本自己的结构化结论
codex-netcheck --json | python3 -m json.tool
```

在干净环境（清掉相关代理变量）下运行 `codex exec "Reply with exactly: OK"`，如果直接返回 `OK`，且没有 `Reconnecting... / stream disconnected`，说明链路已经恢复。

## 6. 回滚

### 6.1 恢复 config

```bash
# 找到最近的备份（由 --fix 在写入前生成）
ls -lt "$HOME/.codex"/config.toml.bak.* | head

# 恢复指定备份
cp "$HOME/.codex/config.toml.bak.<timestamp>" "$HOME/.codex/config.toml"
```

删除 `respect_system_proxy` 会回到旧行为：WebSocket 可能先直连重试，再降级 HTTPS。只应在确认需要回滚时操作。

### 6.2 移除 GUI 同步器

```bash
launchctl bootout "gui/$(id -u)/com.codex-netcheck.proxy-sync" 2>/dev/null || true
rm -f "$HOME/Library/LaunchAgents/com.codex-netcheck.proxy-sync.plist"
rm -f "$HOME/.local/bin/codex-netcheck-proxy-sync.sh"

for k in http_proxy https_proxy all_proxy HTTP_PROXY HTTPS_PROXY ALL_PROXY no_proxy NO_PROXY; do
  launchctl unsetenv "$k" 2>/dev/null || true
done
```

注意：如果这些变量原本由其它工具设置，`unsetenv` 会同时清掉它们；回滚前先确认来源。

### 6.3 移除 shell 自动代理块

编辑 `~/.zshenv`，删除从 `# >>> 自动代理` 到 `# <<< 自动代理 <<<` 的整段内容（包含起止行）。然后新开终端或重新登录。

## 7. 端口与平台

### 7.1 端口优先级

`codex-netcheck` 的端口解析顺序：

1. macOS `scutil --proxy` 检测到系统代理时，使用系统代理的 host / port；
2. 否则使用 `--port <n>`；
3. 否则使用环境变量 `CODEX_NETCHECK_PORT`；
4. 否则使用 `7897`。

因此，系统代理开启时以系统实际端口为准；没有系统代理时，`--port` / 环境变量才作为回退。

`--fix` 生成的 shell 自动代理块和 GUI 同步器会使用当次探测到的端口。改变代理端口后，重新运行 `--fix` 让生成的文件同步更新，或手动修改 `.zshenv` 与同步脚本。

### 7.2 Linux / Windows

macOS 的完整能力依赖 `scutil` 和 `launchctl`。其它平台会降级：

- 跳过系统代理、`~/.zshenv`、GUI 环境、LaunchAgent 检查，并标记为 `info`；
- 继续检查 Codex 版本、config、端口连通性、出网和日志；
- `--fix` 只修改 `config.toml`，不安装 GUI 同步器，不自动写 shell 配置。

Linux 请按所用 shell 手动配置代理变量；Windows 建议在 WSL 或 Git Bash 中运行，并把 `127.0.0.1` 替换为 Windows 主机的实际地址（WSL 通常需要主机 IP 或镜像网络配置）。原生 PowerShell 没有完整支持。

## 8. 为什么优先不用 TUN 模式

TUN 模式通过虚拟网卡接管所有 TCP 流量，确实能让不读代理设置的 App 也走代理，但它通常需要安装系统服务、管理员权限，并改变整机路由。对于只是 Codex 断流的场景，改动面过大。

本工具优先采用：

1. Codex 自己的 `respect_system_proxy`；
2. shell 代理变量；
3. macOS GUI 同步器作为兜底。

这三层都不需要提权，且可以逐层回滚。只有当其它 GUI 程序也出现同类直连问题时，再考虑 TUN 或系统级 VPN。

## 9. 安全边界

- 不发送遥测，不上传文件。
- `--live` 会产生一次真实的模型调用；在 Codex 会话内会自动跳过嵌套 exec。
- 不 kill 进程，不重启 App，不修改代理软件自身配置。
- `--fix` 只改代理相关文件；改 `config.toml` 前先生成带时间戳的备份。
- `--update` 会执行 `codex update`，是否升级由用户显式触发。

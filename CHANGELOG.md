# Changelog

本项目遵循 [Keep a Changelog](https://keepachangelog.com/zh-CN/1.1.0/) 的结构，版本号遵循 [Semantic Versioning](https://semver.org/lang/zh-CN/)。

## [1.3.1] - 2026-10-25

### Fixed

- `--json` 的 `version` 字段改为读取脚本真实版本（此前固定为 `1.0`）。
- 握手抖动告警阈值从 ≥5s 收紧到 ≥4s，更早暴露拥塞节点。

## [1.3.0] - 2026-10-25

### Added

- `--handshake`：经代理连续 6 次 TLS 握手探针，输出成功率、耗时范围与抖动；成功率不满 / 最大耗时 ≥6s / 抖动 ≥5s 时给出换节点建议。
- 检查项 `handshake`，用于诊断任务中途出现的 `stream disconnected before completion: tls handshake eof`、`websocket closed by server before response.completed` 这类连接建立阶段的瞬时故障。
- `CODEX_NETCHECK_HS_ROUNDS` 可调整握手探针轮数（默认 6）。

### Changed

- `--all` 现在同时包含 `--handshake`。
- SKILL.md / prompts / README / TROUBLESHOOTING 增加「中途断流」分支与判定标准。
- 建议固定稳定节点，避免长任务中途被自动切换的代理分组打断握手。

## [1.2.0] - 2026-10-25

### Added

- `--speed`：通过代理实测**上行**速度（1MB POST），并在 &lt;100KB/s / &lt;300KB/s 时给出换节点建议。
- 检查项 `big_threads`：统计 >50MB 的超大历史会话（多为截图），提示恢复时会重传 MB 级请求体。
- 检查项 `large_requests`：从 Codex 日志识别 `tls handshake eof` / `Broken pipe (os error 32)`。

### Changed

- `--all` 现在同时包含 `--speed`。
- README / TROUBLESHOOTING 补充「新会话正常但老会话恢复断流」的完整解释与处理步骤。

## [1.1.0] - 2026-10-25

### Added

- 初始公开版本。
- `netcheck.sh`：检查 Codex 的 config、shell、GUI 三层代理链路，以及代理端口、出网、版本和近期日志。
- `--fix`：幂等补齐 `respect_system_proxy`、`~/.zshenv` 自动代理块和 macOS GUI 代理同步器。
- `--doctor` / `--live` / `--all`：可选的深入体检与真实端到端请求。
- `--json`：稳定的机器可读输出，便于 Agent 和其它工具解析。
- `--port <n>` / `CODEX_NETCHECK_PORT`：可配置本地代理端口（默认 `7897`）；macOS 系统代理开启时仍优先自动探测。
- `--version`：输出版本号。
- `install.sh`：安装 Codex skill，并创建 `~/.local/bin/codex-netcheck`。
- `SKILL.md`、`prompts/netcheck.md` 与完整故障排查文档。
- macOS 以外的降级检查；macOS 专属的 `scutil`、`launchctl` 检查会明确跳过。

### Changed

- LaunchAgent、同步脚本和日志统一使用 `codex-netcheck` 命名：
  - label：`com.codex-netcheck.proxy-sync`
  - 脚本：`~/.local/bin/codex-netcheck-proxy-sync.sh`
  - 日志：`~/Library/Logs/codex-netcheck-proxy-sync.log`
- 默认 `no_proxy` 只保留通用本地/内网地址段，不含任何个人域名。
- 修改 `config.toml` 时改为在写入前备份，避免备份到已修改内容。


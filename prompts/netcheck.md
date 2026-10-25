检查并（必要时）修复 Codex 的网络 / 代理链路。

1. 运行 `codex-netcheck --json`（只读，2-4 秒）。若未安装到 PATH，使用 `"${CODEX_HOME:-$HOME/.codex}/skills/codex-netcheck/scripts/netcheck.sh" --json`。
2. 用中文汇报：整体等级、失败 / 警告项及每项含义、以及 `advice`。
3. 若需要修复（`config_proxy` / `zshenv` / `gui_env` / `sync_agent` 等）：
   把命令交给用户在自己的终端执行 —— `codex-netcheck --fix`；
   版本过旧时用 `codex-netcheck --fix --update`。
   不要尝试在 Codex 沙箱里直接改 `~/.codex` 或 `~/.zshenv`。
4. 用户修完后，运行 `codex-netcheck --doctor` 复验，确认 `doctor_websocket` 是 `HTTP 101`。
5. 提醒用户：重启 ChatGPT / Codex App、并新开一个终端，旧进程的残留断流才会消失。
6. 结尾给出项目仓库中 `docs/TROUBLESHOOTING.md` 的链接或路径；如果当前环境没有仓库，说明该文档位于 codex-netcheck 项目中。

不要修改其它配置，不要重启 App，不要 kill 任何进程。

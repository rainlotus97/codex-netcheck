#!/bin/bash
# 安装 codex-netcheck 到 Codex skill 目录，并创建 PATH 入口。
# 不修改 config.toml、~/.zshenv 或 LaunchAgent；这些只由 `codex-netcheck --fix` 操作。
set -eu

SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)
REPO_DIR=$(cd "$SCRIPT_DIR/.." && pwd)
CODEX_HOME="${CODEX_HOME:-$HOME/.codex}"
SKILL_DIR="$CODEX_HOME/skills/codex-netcheck"
BIN_DIR="$HOME/.local/bin"
LINK="$BIN_DIR/codex-netcheck"

if [ ! -f "$REPO_DIR/SKILL.md" ] || [ ! -f "$REPO_DIR/scripts/netcheck.sh" ]; then
  printf '安装失败：找不到 SKILL.md 或 scripts/netcheck.sh（请从仓库根目录运行 scripts/install.sh）\n' >&2
  exit 1
fi

mkdir -p "$SKILL_DIR/scripts" "$BIN_DIR"
cp "$REPO_DIR/SKILL.md" "$SKILL_DIR/SKILL.md"
cp "$REPO_DIR/scripts/netcheck.sh" "$SKILL_DIR/scripts/netcheck.sh"
cp "$REPO_DIR/scripts/install.sh" "$SKILL_DIR/scripts/install.sh"
chmod +x "$SKILL_DIR/scripts/netcheck.sh" "$SKILL_DIR/scripts/install.sh"
ln -sfn "$SKILL_DIR/scripts/netcheck.sh" "$LINK"

printf 'codex-netcheck 已安装。\n\n'
printf '  skill:   %s\n' "$SKILL_DIR"
printf '  命令:    %s\n' "$LINK"

case ":$PATH:" in
  *":$BIN_DIR:"*) ;;
  *)
    printf '\n注意：%s 不在 PATH 中，请加入 shell 配置：\n' "$BIN_DIR"
    printf '  export PATH="%s:$PATH"\n' "$BIN_DIR"
    ;;
esac

printf '\n下一步：\n'
printf '  1. 只读自检：codex-netcheck --json\n'
printf '  2. 需要修复时（macOS）：codex-netcheck --fix\n'
printf '  3. 修复后新开终端，并重启 ChatGPT / Codex App\n'
printf '  4. 深入体检：codex-netcheck --doctor\n'
printf '\n可选：安装 /netcheck slash 命令\n'
printf '  mkdir -p "%s/prompts"\n' "$CODEX_HOME"
printf '  cp "%s/prompts/netcheck.md" "%s/prompts/"\n' "$REPO_DIR" "$CODEX_HOME"
printf '\n故障排查与回滚：%s/docs/TROUBLESHOOTING.md\n' "$REPO_DIR"

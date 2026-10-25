#!/bin/bash
# codex-netcheck —— Codex 网络 / 代理链路自检与自愈
#
# 适用：Codex CLI、Codex App（ChatGPT.app 内置引擎）、VS Code Codex。
# 也可以被任意 Agent（DSH / Claude Code 等）直接调用，因为它只依赖系统命令。
#
#   codex-netcheck              快速自检（默认，约 2-4 秒）
#   codex-netcheck --doctor     追加 codex doctor 的 WebSocket / 连通性体检（约 15-20 秒）
#   codex-netcheck --live       追加真实端到端请求（会产生一次很小的模型调用）
#   codex-netcheck --all        以上全部
#   codex-netcheck --fix        自动补齐配置 / ~/.zshenv / GUI 代理同步器（幂等）
#   codex-netcheck --fix --update  顺带把 codex 升级到最新版
#   codex-netcheck --json       机器可读输出（便于 Agent 解析），人类提示走 stderr
#   codex-netcheck --port 8080  指定本地代理端口（默认 7897，也可用 CODEX_NETCHECK_PORT）
#   codex-netcheck --version    输出版本号
#
# 退出码：0 = 全绿；1 = 有警告；2 = 有失败

set -u

VERSION="1.3.0"

CODEX_HOME="${CODEX_HOME:-$HOME/.codex}"
CONFIG="$CODEX_HOME/config.toml"
ZSHENV="$HOME/.zshenv"
SYNC_SCRIPT="$HOME/.local/bin/codex-netcheck-proxy-sync.sh"
SYNC_PLIST="$HOME/Library/LaunchAgents/com.codex-netcheck.proxy-sync.plist"
SYNC_LABEL="com.codex-netcheck.proxy-sync"
MARK_ZS="# >>> 自动代理"
NO_PROXY_LIST="localhost,127.0.0.1,::1,.local,192.168.0.0/16,10.0.0.0/8,172.16.0.0/12"
DEFAULT_PORT="${CODEX_NETCHECK_PORT:-7897}"
PLATFORM="$(uname -s 2>/dev/null || printf 'unknown')"
IS_MACOS=0
[ "$PLATFORM" = "Darwin" ] && IS_MACOS=1

DO_DOCTOR=0
DO_LIVE=0
DO_SPEED=0
DO_HANDSHAKE=0
DO_FIX=0
DO_JSON=0
DO_UPDATE=0

CHECKS=()
FIXES=()
ADVICE=()

# ---------- 输出 ----------
if [ -t 1 ] && [ -z "${NO_COLOR:-}" ]; then
  C_OK=$'\033[32m'; C_WARN=$'\033[33m'; C_FAIL=$'\033[31m'; C_INFO=$'\033[36m'; C_DIM=$'\033[2m'; C_RST=$'\033[0m'
else
  C_OK=""; C_WARN=""; C_FAIL=""; C_INFO=""; C_DIM=""; C_RST=""
fi

# json 模式下人类输出走 stderr，保证 stdout 是纯 JSON
say() { if [ "$DO_JSON" = "1" ]; then printf '%s\n' "$*" >&2; else printf '%s\n' "$*"; fi; }

add() { CHECKS+=("$1"$'\t'"$2"$'\t'"$3"); }
add_fix() { FIXES+=("$1"$'\t'"$2"); }

icon_of() {
  case "$1" in
    ok) printf '%s✓%s' "$C_OK" "$C_RST" ;;
    warn) printf '%s!%s' "$C_WARN" "$C_RST" ;;
    fail) printf '%s✗%s' "$C_FAIL" "$C_RST" ;;
    *) printf '%s·%s' "$C_INFO" "$C_RST" ;;
  esac
}

# ---------- 基础工具 ----------
valid_port() {
  case "$1" in
    ''|*[!0-9]*) return 1 ;;
  esac
  [ "$1" -ge 1 ] 2>/dev/null && [ "$1" -le 65535 ] 2>/dev/null
}

run_timeout() { # 秒数 命令...
  local secs="$1"; shift
  local out; out=$(mktemp "${TMPDIR:-/tmp}/netcheck.XXXXXX")
  "$@" >"$out" 2>&1 &
  local pid=$!
  ( sleep "$secs"; kill -TERM "$pid" 2>/dev/null; sleep 3; kill -KILL "$pid" 2>/dev/null ) >/dev/null 2>&1 &
  local watchdog=$!
  wait "$pid" 2>/dev/null
  local rc=$?
  kill -TERM "$watchdog" 2>/dev/null
  cat "$out" 2>/dev/null
  rm -f "$out"
  return $rc
}

port_open() {
  if [ "$IS_MACOS" = "1" ]; then
    nc -z -G 1 "$PROXY_HOST" "$PROXY_PORT" >/dev/null 2>&1
  else
    nc -z -w 1 "$PROXY_HOST" "$PROXY_PORT" >/dev/null 2>&1
  fi
}

http_code() { # 参数：额外 curl 参数...；输出 HTTP 状态码（000=失败）
  local c
  c=$(curl -s -o /dev/null -w '%{http_code}' --max-time 15 "$@" 2>/dev/null)
  [ -z "$c" ] && c=000
  printf '%s' "$c"
}

ver_gt() { # $1 > $2 ? 输出 1/0
  command -v python3 >/dev/null 2>&1 || { printf '0'; return; }
  python3 - "$1" "$2" <<'PY' 2>/dev/null
import sys
def key(v):
    core = v.split('-')[0]
    out = []
    for part in core.split('.'):
        out.append(int(part) if part.isdigit() else 0)
    return tuple(out)
try:
    print('1' if key(sys.argv[1]) > key(sys.argv[2]) else '0')
except Exception:
    print('0')
PY
}

level_of() { # 查某个 check 的等级
  local want="$1" c lvl id
  for c in "${CHECKS[@]:-}"; do
    [ -z "$c" ] && continue
    lvl="${c%%$'\t'*}"
    id="${c#*$'\t'}"; id="${id%%$'\t'*}"
    if [ "$id" = "$want" ]; then printf '%s' "$lvl"; return; fi
  done
}

format_epoch() { # 兼容 BSD / GNU date
  if [ "$IS_MACOS" = "1" ]; then
    date -r "$1" '+%H:%M:%S' 2>/dev/null
  else
    date -d "@$1" '+%H:%M:%S' 2>/dev/null
  fi
}

# ---------- 代理探测 ----------
# 端口优先级：scutil --proxy 自动探测 > --port / CODEX_NETCHECK_PORT > 7897
detect_proxy() {
  PROXY_HOST="127.0.0.1"
  PROXY_PORT="$DEFAULT_PORT"
  SYS_PROXY_ON=0
  SYS_PROXY_DETAIL="未开启"
  local out https_en https_host https_port http_en http_host http_port
  out=$(scutil --proxy 2>/dev/null || true)
  https_en=$(printf '%s\n' "$out" | awk -F' : ' '/HTTPSEnable/{gsub(/[[:space:]]/,"",$2);print $2;exit}')
  https_host=$(printf '%s\n' "$out" | awk -F' : ' '/HTTPSProxy/{gsub(/[[:space:]]/,"",$2);print $2;exit}')
  https_port=$(printf '%s\n' "$out" | awk -F' : ' '/HTTPSPort/{gsub(/[[:space:]]/,"",$2);print $2;exit}')
  http_en=$(printf '%s\n' "$out" | awk -F' : ' '/HTTPEnable/{gsub(/[[:space:]]/,"",$2);print $2;exit}')
  http_host=$(printf '%s\n' "$out" | awk -F' : ' '/HTTPProxy/{gsub(/[[:space:]]/,"",$2);print $2;exit}')
  http_port=$(printf '%s\n' "$out" | awk -F' : ' '/HTTPPort/{gsub(/[[:space:]]/,"",$2);print $2;exit}')
  if [ "${https_en:-0}" = "1" ] && [ -n "${https_host:-}" ]; then
    SYS_PROXY_ON=1; PROXY_HOST="$https_host"; PROXY_PORT="${https_port:-$DEFAULT_PORT}"
    SYS_PROXY_DETAIL="$PROXY_HOST:${PROXY_PORT}（HTTPS）"
  elif [ "${http_en:-0}" = "1" ] && [ -n "${http_host:-}" ]; then
    SYS_PROXY_ON=1; PROXY_HOST="$http_host"; PROXY_PORT="${http_port:-$DEFAULT_PORT}"
    SYS_PROXY_DETAIL="$PROXY_HOST:${PROXY_PORT}（HTTP）"
  fi
  PROXY_URL="http://$PROXY_HOST:$PROXY_PORT"
}

# ---------- 各项检查 ----------
check_codex_bin() {
  CODEX_BIN=$(command -v codex 2>/dev/null || true)
  CODEX_VER=""
  if [ -n "$CODEX_BIN" ]; then
    CODEX_VER=$("$CODEX_BIN" --version 2>/dev/null | sed -n 's/.*codex-cli[[:space:]]\{1,\}\([^[:space:]]*\).*/\1/p' | tail -1)
    add ok codex_bin "codex-cli ${CODEX_VER:-?} → $CODEX_BIN"
  else
    add fail codex_bin "PATH 里找不到 codex 命令"
  fi
}

check_codex_latest() {
  LATEST_VER=""
  [ -z "${CODEX_BIN:-}" ] && { add info codex_version "跳过（codex 未找到）"; return; }
  LATEST_VER=$(curl -s -x "$PROXY_URL" --max-time 8 "https://registry.npmjs.org/@openai%2Fcodex/latest" 2>/dev/null \
    | python3 -c 'import json,sys;print(json.load(sys.stdin).get("version",""))' 2>/dev/null || true)
  if [ -z "$LATEST_VER" ]; then
    add info codex_version "无法查询最新版（代理不通或网络受限），不影响其它检查"
  elif [ "${LATEST_VER}" = "${CODEX_VER}" ]; then
    add ok codex_version "已是最新（${CODEX_VER}）"
  elif [ "$(ver_gt "$LATEST_VER" "$CODEX_VER")" = "1" ]; then
    add warn codex_version "可升级 $CODEX_VER → ${LATEST_VER}（旧版可能报 400『model requires a newer version』，用 --fix --update）"
  else
    add ok codex_version "版本 ${CODEX_VER}（远端 ${LATEST_VER}）"
  fi
}

check_config() {
  if [ ! -f "$CONFIG" ]; then
    add fail config_proxy "$CONFIG 不存在"
    return
  fi
  if grep -qE '^[[:space:]]*respect_system_proxy[[:space:]]*=[[:space:]]*true' "$CONFIG" 2>/dev/null; then
    local eff=""
    if [ -n "${CODEX_BIN:-}" ]; then
      eff=$("$CODEX_BIN" features list 2>/dev/null | awk '/^respect_system_proxy/{print $NF}' | tail -1)
    fi
    if [ "$eff" = "true" ] || [ -z "$eff" ]; then
      add ok config_proxy "respect_system_proxy = true（生效：${eff:-未知}）"
    else
      add fail config_proxy "配置写了但未生效（features list 显示 ${eff}）"
    fi
  else
    add fail config_proxy "config.toml 缺少 respect_system_proxy = true ← 断流主因，用 --fix"
  fi
  if grep -qE '^[[:space:]]*suppress_unstable_features_warning[[:space:]]*=[[:space:]]*true' "$CONFIG" 2>/dev/null; then
    add ok config_quiet "已关闭 under-development 特性告警"
  else
    add info config_quiet "未设置 suppress_unstable_features_warning（只是启动时多一行提示）"
  fi
}

check_system_proxy() {
  if [ "$IS_MACOS" != "1" ]; then
    add info system_proxy "非 macOS：跳过系统代理检查（请依赖 shell / 进程环境变量）"
  elif [ "$SYS_PROXY_ON" = "1" ]; then
    add ok system_proxy "macOS 系统代理：$SYS_PROXY_DETAIL"
  else
    add fail system_proxy "macOS 系统代理未开启（在代理客户端里打开『系统代理』）"
  fi
}

check_proxy_port() {
  if port_open; then
    add ok proxy_port "混合端口 $PROXY_HOST:$PROXY_PORT 可连通"
  else
    add fail proxy_port "端口 $PROXY_HOST:$PROXY_PORT 不通（代理客户端未启动 / 端口被改）"
  fi
}

check_shell_env() {
  local h="${https_proxy:-${HTTPS_PROXY:-}}" nh="${no_proxy:-${NO_PROXY:-}}"
  if [ -n "$h" ]; then
    if printf '%s' "$nh" | grep -q '127\.0\.0\.1'; then
      add ok shell_env "当前 shell 代理：${h}（localhost 已排除）"
    else
      add warn shell_env "当前 shell 代理：${h}，但 no_proxy 没排除 127.0.0.1"
    fi
  else
    add warn shell_env "当前 shell 没有 http(s)_proxy（老终端未加载 ~/.zshenv；新开终端或 source ~/.zshenv）"
  fi
}

check_zshenv() {
  if [ "$IS_MACOS" != "1" ]; then
    add info zshenv "非 macOS：跳过 ~/.zshenv 自动代理检查（请按所用 shell 手动配置代理变量）"
    return
  fi
  if [ -f "$ZSHENV" ] && grep -qF "$MARK_ZS" "$ZSHENV" 2>/dev/null; then
    add ok zshenv "~/.zshenv 已含自动代理块（所有 zsh 进程生效）"
  else
    add fail zshenv "~/.zshenv 缺少自动代理块（用 --fix 补）"
  fi
}

check_gui_env() {
  if [ "$IS_MACOS" != "1" ]; then
    add info gui_env "非 macOS：跳过 launchctl GUI 环境检查"
    return
  fi
  local v=""
  v=$(launchctl getenv https_proxy 2>/dev/null || true)
  if [ -n "$v" ]; then
    add ok gui_env "GUI 会话变量：https_proxy=$v"
  else
    add warn gui_env "GUI 会话没有 https_proxy（Dock/Finder 启动的 App 拿不到代理；用 --fix 重装同步器）"
  fi
}

check_sync_agent() {
  local uid state="" gui_proxy=""
  if [ "$IS_MACOS" != "1" ]; then
    add info sync_agent "非 macOS：跳过 launchctl GUI 同步器检查"
    return
  fi
  if [ ! -f "$SYNC_PLIST" ]; then
    gui_proxy=$(launchctl getenv https_proxy 2>/dev/null || true)
    if [ -n "$gui_proxy" ]; then
      add info sync_agent "本项目同步器未安装，但 GUI 会话已有代理变量（由其它方式设置）"
    else
      add warn sync_agent "未安装 GUI 代理同步器（Dock/Finder 启动的 App 可能拿不到代理；用 --fix 安装）"
    fi
    return
  fi
  uid=$(id -u)
  state=$(launchctl print "gui/$uid/$SYNC_LABEL" 2>/dev/null | awk '/^[[:space:]]*state = /{print $3;exit}')
  if [ "$state" = "running" ]; then
    add ok sync_agent "GUI 代理同步器运行中（${SYNC_LABEL}）"
  else
    add fail sync_agent "GUI 代理同步器未运行（state=${state:-未加载}）"
  fi
}

check_proxy_reachable() {
  local code
  code=$(http_code -x "$PROXY_URL" https://chatgpt.com/backend-api/)
  case "$code" in
    000) add fail proxy_https "经代理访问 chatgpt.com 失败（节点/规则问题）" ;;
    401|403|200|204|405) add ok proxy_https "经代理访问 chatgpt.com 正常（HTTP ${code}）" ;;
    *) add warn proxy_https "经代理访问 chatgpt.com 返回 HTTP ${code}（非预期但不一定是断流）" ;;
  esac
}

check_direct() {
  local code
  code=$(curl -s -o /dev/null -w '%{http_code}' --max-time 6 --noproxy '*' https://chatgpt.com/backend-api/ 2>/dev/null)
  [ -z "$code" ] && code=000
  case "$code" in
    000) add info direct "直连 chatgpt.com 被重置/超时（国内预期，靠代理即可）" ;;
    401|403|200|204|405) add ok direct "直连也可用（TUN 或 VPN 生效，代理非必需）" ;;
    *) add info direct "直连返回 HTTP $code" ;;
  esac
}

check_recent_errors() {
  local p="$CODEX_HOME/logs_2.sqlite"
  if [ ! -f "$p" ] || ! command -v python3 >/dev/null 2>&1; then
    add info recent_errors "跳过（无日志库或 python3）"
    return
  fi
  local out model_cnt model_last remote_cnt big_cnt
  out=$(python3 - "$p" <<'PY' 2>/dev/null
import sqlite3, sys, time
p = sys.argv[1]
cut = int(time.time()) - 1800
try:
    con = sqlite3.connect("file:%s?mode=ro" % p, uri=True)
    cur = con.cursor()
    model = cur.execute(
        "select count(*), max(ts) from logs where ts>? and feedback_log_body like '%stream disconnected%'",
        (cut,)).fetchone()
    remote = cur.execute(
        "select count(*) from logs where ts>? and feedback_log_body like '%remote/control%' and (level='WARN' or level='ERROR')",
        (cut,)).fetchone()
    big = cur.execute(
        "select count(*) from logs where ts>? and (feedback_log_body like '%tls handshake eof%' or feedback_log_body like '%Broken pipe (os error 32)%')",
        (cut,)).fetchone()
    print(model[0] or 0, model[1] or 0, remote[0] or 0, big[0] or 0)
except Exception:
    print("0 0 0")
PY
)
  model_cnt=$(printf '%s' "$out" | awk '{print $1}')
  model_last=$(printf '%s' "$out" | awk '{print $2}')
  remote_cnt=$(printf '%s' "$out" | awk '{print $3}')
  big_cnt=$(printf '%s' "$out" | awk '{print $4}')
  local last_txt=""
  [ "${model_last:-0}" != "0" ] && last_txt="，最近 $(format_epoch "${model_last}" 2>/dev/null || echo '?')"
  if [ "${model_cnt:-0}" -gt 0 ] 2>/dev/null; then
    add warn recent_errors "近 30 分钟有 $model_cnt 次断流${last_txt}（若来自未重启的旧进程，重启 App/终端即可）"
  else
    add ok recent_errors "近 30 分钟无断流日志"
  fi
  if [ "${big_cnt:-0}" -gt 0 ] 2>/dev/null; then
    add warn large_requests "近 30 分钟有 ${big_cnt} 次 tls handshake eof / Broken pipe：多为恢复大历史（含截图）时请求体过大 + 上行慢，用 --speed 测上行"
  fi
  if [ "${remote_cnt:-0}" -gt 0 ] 2>/dev/null; then
    add info remote_control "近 30 分钟 remote-control WebSocket 失败 $remote_cnt 次（Codex App 后台进程，重启 App 后消失）"
  fi
}

check_doctor() {
  [ -z "${CODEX_BIN:-}" ] && { add info doctor "跳过（codex 未找到）"; return; }
  local out conn
  out=$(run_timeout 90 "$CODEX_BIN" doctor 2>&1 || true)
  conn=$(printf '%s\n' "$out" | sed -n '/^Connectivity/,/^Background/p')
  local ws_resp reach respect
  ws_resp=$(printf '%s\n' "$conn" | grep -E '^[[:space:]]*[✓✗⚠]?[[:space:]]*websocket' | head -1)
  reach=$(printf '%s\n' "$conn" | grep -E '^[[:space:]]*[✓✗⚠]?[[:space:]]*reachability' | head -1)
  respect=$(printf '%s\n' "$conn" | sed -n 's/^.*respect system proxy[[:space:]]\{1,\}//p' | head -1)

  case "$ws_resp" in
    *"connected (HTTP 101"*) add ok doctor_websocket "doctor：WebSocket 已连接（HTTP 101）" ;;
    *"✓"*)                  add ok doctor_websocket "doctor：WebSocket 正常" ;;
    *"⚠"*)                  add warn doctor_websocket "doctor：WebSocket 警告（HTTPS 可降级，但会先空转重试）" ;;
    *"✗"*)                  add fail doctor_websocket "doctor：WebSocket 连接失败" ;;
    "")                     add info doctor_websocket "doctor：未输出 websocket 项" ;;
    *)                      add warn doctor_websocket "doctor：WebSocket 状态无法判定" ;;
  esac

  case "$reach" in
    *"✓"*) add ok doctor_reach "doctor：provider 端点可达" ;;
    *"⚠"*) add warn doctor_reach "doctor：provider 端点可达但可选 CDN 抖动（不影响对话）" ;;
    *"✗"*) add fail doctor_reach "doctor：provider 端点不可达" ;;
    "")    add info doctor_reach "doctor：未输出 reachability 项" ;;
    *)     add info doctor_reach "doctor：reachability 状态无法判定" ;;
  esac

  add info doctor_respect "doctor：respect system proxy = ${respect:-未知}"
}

check_live() {
  [ -z "${CODEX_BIN:-}" ] && { add info live "跳过（codex 未找到）"; return; }
  if [ -n "${CODEX_THREAD_ID:-}" ]; then
    add info live "在 Codex 会话内，跳过嵌套 exec（请在普通终端运行 --live）"
    return
  fi
  local tmp out
  tmp=$(mktemp -d "${TMPDIR:-/tmp}/netcheck-live.XXXXXX")
  out=$(cd "$tmp" && run_timeout 180 env \
      -u http_proxy -u https_proxy -u all_proxy -u HTTP_PROXY -u HTTPS_PROXY -u ALL_PROXY -u no_proxy -u NO_PROXY \
      "$CODEX_BIN" exec --skip-git-repo-check -c 'mcp_servers={}' -c 'model_reasoning_effort="low"' \
      "Reply with exactly: OK" </dev/null 2>&1 || true)
  rm -rf "$tmp"
  if printf '%s' "$out" | grep -q 'stream disconnected'; then
    add fail live "端到端请求仍断流（--live 失败）"
  elif printf '%s' "$out" | grep -q 'Reconnecting'; then
    add warn live "端到端请求出现重连但最终完成（网络抖动）"
  elif printf '%s' "$out" | grep -qE '(^|[[:space:]])OK([[:space:]]|$)'; then
    add ok live "端到端 exec 正常（无断流、无重连）"
  else
    add warn live "端到端输出无法判定：$(printf '%s' "$out" | tr '\n' ' ' | cut -c1-120)"
  fi
}

check_big_threads() {
  local n
  n=$(find "$CODEX_HOME/sessions" -name '*.jsonl' -size +50M 2>/dev/null | wc -l | tr -d ' ')
  if [ "${n:-0}" -gt 0 ]; then
    add info big_threads "有 $n 个 >50MB 的超大会话（多为截图）；恢复它们会重传 MB 级请求体，上行慢的节点会超时/断流"
  else
    add ok big_threads "没有超大历史会话"
  fi
}

check_upload_speed() {
  local tmp speed kbs
  tmp=$(mktemp "${TMPDIR:-/tmp}/netcheck-up.XXXXXX")
  head -c 1048576 /dev/urandom > "$tmp" 2>/dev/null || true
  speed=$(curl -s -o /dev/null -w '%{speed_upload}' --max-time 20 -x "$PROXY_URL" \
    -X POST --data-binary @"$tmp" https://speed.cloudflare.com/__up 2>/dev/null)
  rm -f "$tmp"
  case "${speed:-}" in
    ''|*[!0-9.]*)
      add warn upload "代理上行测速失败（节点可能限制 POST 或屏蔽测速域名）"
      return ;;
  esac
  kbs=$(( ${speed%.*} / 1024 ))
  if [ "$kbs" -lt 100 ]; then
    add warn upload "代理上行 ${kbs} KB/s（极慢）：恢复含图片的老会话必然超时/断流，建议换节点"
  elif [ "$kbs" -lt 300 ]; then
    add warn upload "代理上行 ${kbs} KB/s（偏慢）：大历史会话可能超时；建议换更快的节点"
  else
    add ok upload "代理上行 ${kbs} KB/s（够用）"
  fi
}

check_handshake() {
  command -v openssl >/dev/null 2>&1 || { add info handshake "跳过（无 openssl）"; return; }
  [ -z "${PROXY_URL:-}" ] && { add info handshake "跳过（未探测到代理）"; return; }
  local rounds="${CODEX_NETCHECK_HS_ROUNDS:-6}"
  local ok=0 fail=0 i t0 t1 out dur durs=""
  for i in $(seq 1 "$rounds"); do
    t0=$(python3 -c 'import time;print(time.time())' 2>/dev/null || echo 0)
    out=$(run_timeout 12 openssl s_client -proxy "$PROXY_HOST:$PROXY_PORT" \
      -connect chatgpt.com:443 -servername chatgpt.com </dev/null 2>&1 || true)
    t1=$(python3 -c 'import time;print(time.time())' 2>/dev/null || echo 0)
    if printf '%s' "$out" | grep -q 'Verify return code: 0'; then
      ok=$((ok+1))
      dur=$(python3 -c "print(round(float('${t1}') - float('${t0}'), 2))" 2>/dev/null || echo 0)
      durs="$durs $dur"
    else
      fail=$((fail+1))
    fi
  done
  local stats min max avg
  stats=$(printf '%s' "$durs" | awk '{n=NF; if(n==0){print "0 0 0"; exit} min=$1; max=$1; s=0; for(i=1;i<=NF;i++){if($i<min)min=$i; if($i>max)max=$i; s+=$i}; printf "%.2f %.2f %.2f", min, max, s/n}')
  min=$(printf '%s' "$stats" | awk '{print $1}')
  max=$(printf '%s' "$stats" | awk '{print $2}')
  avg=$(printf '%s' "$stats" | awk '{print $3}')
  local jitter
  jitter=$(python3 -c "print(round(float('${max}') - float('${min}'), 2))" 2>/dev/null || echo 0)
  if [ "$fail" -ge "$rounds" ]; then
    add fail handshake "TLS 握手 ${ok}/${rounds} 成功：节点基本不可用，先换节点"
  elif [ "$fail" -gt 0 ]; then
    add warn handshake "TLS 握手 ${ok}/${rounds} 成功（失败 ${fail} 次，耗时 ${min}–${max}s）：节点在丢握手，中途断流高发"
  elif [ "$(python3 -c "print(1 if float('${max}') >= 6 else 0)" 2>/dev/null || echo 0)" = "1" ]; then
    add warn handshake "TLS 握手 ${ok}/${rounds} 成功，但耗时抖动大（${min}–${max}s，平均 ${avg}s）：节点拥塞，容易撞上 tls handshake eof"
  elif [ "$(python3 -c "print(1 if float('${jitter}') >= 5 else 0)" 2>/dev/null || echo 0)" = "1" ]; then
    add warn handshake "TLS 握手 ${ok}/${rounds} 成功，抖动 ${jitter}s（${min}–${max}s）：建议换更稳的节点"
  else
    add ok handshake "TLS 握手 ${ok}/${rounds} 成功，耗时 ${min}–${max}s（抖动 ${jitter}s）"
  fi
}

# ---------- 修复 ----------
fix_config() {
  if [ ! -f "$CONFIG" ]; then
    add_fix fail "config.toml 不存在：$CONFIG"
    return
  fi
  if [ ! -w "$CONFIG" ]; then
    add_fix fail "config.toml 不可写（Codex 沙箱内请让用户在普通终端运行 --fix）"
    return
  fi
  if ! command -v python3 >/dev/null 2>&1; then
    add_fix fail "缺少 python3，无法安全修改 config.toml"
    return
  fi
  local changed backup rc
  backup="$CONFIG.bak.$(date +%Y%m%d%H%M%S)"
  cp -p "$CONFIG" "$backup" 2>/dev/null || backup=""
  changed=$(python3 - "$CONFIG" <<'PY' 2>/dev/null
import re, sys
p = sys.argv[1]
s = open(p, encoding='utf-8').read()
changed = []
if not re.search(r'^\s*respect_system_proxy\s*=\s*true\s*$', s, re.M):
    m = re.search(r'^\[features\]\s*$', s, re.M)
    if m:
        s = s[:m.end()] + '\nrespect_system_proxy = true' + s[m.end():]
    else:
        s = s.rstrip('\n') + '\n\n[features]\nrespect_system_proxy = true\n'
    changed.append('respect_system_proxy')
if not re.search(r'^\s*suppress_unstable_features_warning\s*=\s*true\s*$', s, re.M):
    lines = s.split('\n')
    idx = len(lines)
    for i, line in enumerate(lines):
        if re.match(r'^\s*\[', line):
            idx = i
            break
    lines.insert(idx, 'suppress_unstable_features_warning = true')
    lines.insert(idx + 1, '')
    s = '\n'.join(lines)
    changed.append('suppress_unstable_features_warning')
if changed:
    open(p, 'w', encoding='utf-8').write(s)
print(','.join(changed))
PY
)
  rc=$?
  if [ "$rc" -ne 0 ]; then
    add_fix fail "修改 config.toml 失败（Python 退出码 ${rc}${backup:+，备份：$backup}）"
    return
  fi
  if [ -n "${changed:-}" ]; then
    add_fix ok "config.toml 已补：$changed"
    [ -n "$backup" ] && add_fix info "原配置已备份：$backup"
  else
    [ -n "$backup" ] && rm -f "$backup"
    add_fix ok "config.toml 已满足要求（无需改动）"
  fi
}

fix_zshenv() {
  if [ "$IS_MACOS" != "1" ]; then
    add_fix info "非 macOS：跳过 ~/.zshenv 自动代理层（请按所用 shell 手动配置）"
    return
  fi
  if [ -f "$ZSHENV" ] && grep -qF "$MARK_ZS" "$ZSHENV" 2>/dev/null; then
    add_fix ok "~/.zshenv 自动代理块已存在"
    return
  fi
  if [ ! -w "$HOME" ]; then
    add_fix fail "无法写 ${ZSHENV}（无写权限）"
    return
  fi
  cat >> "$ZSHENV" <<EOF

# >>> 自动代理：Codex 断流修复（本地代理端口 ${PROXY_PORT}）>>>
# 本地代理在跑时，为所有 zsh 进程（交互/非交互、IDE 终端、脚本）注入代理变量；
# 代理没跑时自动跳过，不会把流量导向死端口。
# 临时关闭：在当前 shell 执行 proxy_off（需在 .zshrc 中自行定义）。
if command -v nc >/dev/null 2>&1 && nc -z -G 1 127.0.0.1 "$PROXY_PORT" >/dev/null 2>&1; then
  export http_proxy="http://127.0.0.1:$PROXY_PORT"
  export https_proxy="\$http_proxy"
  export all_proxy="socks5://127.0.0.1:$PROXY_PORT"
  export HTTP_PROXY="\$http_proxy"
  export HTTPS_PROXY="\$http_proxy"
  export ALL_PROXY="\$all_proxy"
  export no_proxy="$NO_PROXY_LIST"
  export NO_PROXY="\$no_proxy"
fi
# <<< 自动代理 <<<
EOF
  add_fix ok "已写入 ~/.zshenv 自动代理块"
}

fix_sync_agent() {
  if [ "$IS_MACOS" != "1" ]; then
    add_fix info "非 macOS：跳过 GUI 代理同步器（仅 macOS 支持 launchctl 层）"
    return
  fi
  mkdir -p "$(dirname "$SYNC_SCRIPT")" "$(dirname "$SYNC_PLIST")"
  cat > "$SYNC_SCRIPT" <<EOF
#!/bin/bash
# codex-netcheck-proxy-sync.sh —— 让 GUI 应用也继承代理环境变量（由 codex-netcheck 维护）
set -u
HOST="$PROXY_HOST"
PORT="$PROXY_PORT"
P="http://\$HOST:\$PORT"
S="socks5://\$HOST:\$PORT"
NO_PROXY_LIST="$NO_PROXY_LIST"
KEYS="http_proxy https_proxy HTTP_PROXY HTTPS_PROXY all_proxy ALL_PROXY no_proxy NO_PROXY"
log() { echo "[\$(date '+%Y-%m-%d %H:%M:%S')] \$*"; }
apply_on() {
  launchctl setenv http_proxy "\$P"; launchctl setenv https_proxy "\$P"
  launchctl setenv HTTP_PROXY "\$P"; launchctl setenv HTTPS_PROXY "\$P"
  launchctl setenv all_proxy "\$S"; launchctl setenv ALL_PROXY "\$S"
  launchctl setenv no_proxy "\$NO_PROXY_LIST"; launchctl setenv NO_PROXY "\$NO_PROXY_LIST"
  log "proxy ON  -> \$P"
}
apply_off() {
  for k in \$KEYS; do launchctl unsetenv "\$k" 2>/dev/null; done
  log "proxy OFF -> 端口 \$PORT 不可用，已清除 GUI 代理变量"
}
state="unknown"
while true; do
  if nc -z -G 1 "\$HOST" "\$PORT" >/dev/null 2>&1; then want="on"; else want="off"; fi
  if [ "\$want" != "\$state" ]; then
    if [ "\$want" = "on" ]; then apply_on; else apply_off; fi
    state="\$want"
  fi
  sleep 20
done
EOF
  chmod +x "$SYNC_SCRIPT"

  cat > "$SYNC_PLIST" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key><string>$SYNC_LABEL</string>
    <key>ProgramArguments</key>
    <array>
        <string>/bin/bash</string>
        <string>$SYNC_SCRIPT</string>
    </array>
    <key>RunAtLoad</key><true/>
    <key>KeepAlive</key><true/>
    <key>ThrottleInterval</key><integer>30</integer>
    <key>ProcessType</key><string>Background</string>
    <key>StandardOutPath</key><string>$HOME/Library/Logs/codex-netcheck-proxy-sync.log</string>
    <key>StandardErrorPath</key><string>$HOME/Library/Logs/codex-netcheck-proxy-sync.log</string>
</dict>
</plist>
EOF

  local uid; uid=$(id -u)
  launchctl bootout "gui/$uid/$SYNC_LABEL" >/dev/null 2>&1
  launchctl bootstrap "gui/$uid" "$SYNC_PLIST" >/dev/null 2>&1 \
    || launchctl load -w "$SYNC_PLIST" >/dev/null 2>&1
  sleep 1
  launchctl kickstart -k "gui/$uid/$SYNC_LABEL" >/dev/null 2>&1
  add_fix ok "GUI 代理同步器已写入并加载（${SYNC_LABEL}）"
}

fix_update() {
  if [ -z "${LATEST_VER:-}" ] || [ -z "${CODEX_VER:-}" ] || [ "$LATEST_VER" = "$CODEX_VER" ]; then
    add_fix info "codex 已是最新或无法判断版本，跳过升级"
    return
  fi
  add_fix info "开始升级 codex $CODEX_VER → ${LATEST_VER}（经代理，约 1-2 分钟）"
  local out
  out=$(run_timeout 600 env \
      HTTPS_PROXY="$PROXY_URL" HTTP_PROXY="$PROXY_URL" https_proxy="$PROXY_URL" http_proxy="$PROXY_URL" \
      "$CODEX_BIN" update 2>&1 || true)
  if printf '%s' "$out" | grep -qE 'installed successfully|Update ran successfully'; then
    add_fix ok "codex 升级完成"
  else
    add_fix fail "codex 升级失败：$(printf '%s' "$out" | tail -2 | tr '\n' ' ' | cut -c1-160)"
  fi
}

run_fixes() {
  say "${C_DIM}── 修复动作 ──${C_RST}"
  fix_config
  fix_zshenv
  fix_sync_agent
  [ "$DO_UPDATE" = "1" ] && fix_update
  local f f_lvl f_msg
  for f in "${FIXES[@]:-}"; do
    [ -z "$f" ] && continue
    f_lvl="${f%%$'\t'*}"
    f_msg="${f#*$'\t'}"
    say "  $(icon_of "$f_lvl") $f_msg"
  done
  say ""
}

# ---------- 检查调度 ----------
run_checks() {
  CHECKS=()
  check_codex_bin
  check_codex_latest
  check_config
  check_system_proxy
  check_proxy_port
  check_shell_env
  check_zshenv
  check_gui_env
  check_sync_agent
  check_proxy_reachable
  check_direct
  check_recent_errors
  check_big_threads
  [ "$DO_DOCTOR" = "1" ] && check_doctor
  [ "$DO_LIVE" = "1" ] && check_live
  [ "$DO_SPEED" = "1" ] && check_upload_speed
  [ "$DO_HANDSHAKE" = "1" ] && check_handshake
}

# ---------- 汇总 ----------
build_advice() {
  ADVICE=()
  local l
  l=$(level_of config_proxy);   [ "$l" = "fail" ] && ADVICE+=("补配置：codex-netcheck --fix（写入 respect_system_proxy）")
  l=$(level_of system_proxy);   [ "$l" = "fail" ] && ADVICE+=("在代理客户端里打开『系统代理』开关")
  l=$(level_of proxy_port);     [ "$l" = "fail" ] && ADVICE+=("启动代理客户端，或确认端口 ${PROXY_PORT} 正确")
  l=$(level_of zshenv);         [ "$l" = "fail" ] && ADVICE+=("补 shell 层：codex-netcheck --fix（写入 ~/.zshenv）")
  l=$(level_of gui_env);        [ "$l" = "warn" ] && ADVICE+=("补 GUI 层：codex-netcheck --fix（重装代理同步器）")
  l=$(level_of sync_agent);     { [ "$l" = "fail" ] || [ "$l" = "warn" ]; } && ADVICE+=("修复同步器：codex-netcheck --fix")
  l=$(level_of shell_env);      [ "$l" = "warn" ] && ADVICE+=("新开一个终端，或加载 shell 配置后再试")
  l=$(level_of codex_version);  [ "$l" = "warn" ] && ADVICE+=("升级 codex：codex-netcheck --fix --update（需代理）")
  l=$(level_of proxy_https);    [ "$l" = "fail" ] && ADVICE+=("检查代理客户端的节点 / 规则：系统代理通但经代理访问失败")
  l=$(level_of live);           [ "$l" = "fail" ] && ADVICE+=("端到端仍失败：跑 codex-netcheck --doctor 看 WebSocket 明细")
  if [ "$(level_of recent_errors)" = "warn" ] && [ "$(level_of proxy_https)" = "ok" ] && [ "$(level_of config_proxy)" = "ok" ]; then
    ADVICE+=("断流日志来自旧进程的残留：重启 ChatGPT/Codex App、新开终端后再看")
  fi
  l=$(level_of upload);           [ "$l" = "warn" ] && ADVICE+=("换一个上行更快的代理节点，然后 codex-netcheck --speed 复测（下行快 ≠ 上行快）")
  l=$(level_of handshake);        { [ "$l" = "warn" ] || [ "$l" = "fail" ]; } && ADVICE+=("握手不稳 → 换一个稳定的固定节点（别用会中途切换的自动分组），再跑 codex-netcheck --handshake 复测")
  l=$(level_of large_requests);   [ "$l" = "warn" ] && ADVICE+=("老会话含大量截图，恢复时请求体达数 MB：换上行快的节点，或在新会话继续")
  [ ${#ADVICE[@]} -eq 0 ] && ADVICE+=("无需操作，链路正常")
}

print_human() {
  local ok_n=0 warn_n=0 fail_n=0 info_n=0 c lvl msg
  say "Codex 网络自检 v$VERSION  ${C_DIM}$(date '+%Y-%m-%d %H:%M:%S')${C_RST}"
  say "${C_DIM}────────────────────────────────────────${C_RST}"
  for c in "${CHECKS[@]:-}"; do
    [ -z "$c" ] && continue
    lvl="${c%%$'\t'*}"
    msg="${c#*$'\t'}"; msg="${msg#*$'\t'}"
    case "$lvl" in
      ok) ok_n=$((ok_n+1)) ;;
      warn) warn_n=$((warn_n+1)) ;;
      fail) fail_n=$((fail_n+1)) ;;
      *) info_n=$((info_n+1)) ;;
    esac
    say "  $(icon_of "$lvl") $msg"
  done
  say "${C_DIM}────────────────────────────────────────${C_RST}"
  local summary="结果：${C_OK}${ok_n} ok${C_RST}"
  [ "$warn_n" -gt 0 ] && summary="$summary · ${C_WARN}${warn_n} warn${C_RST}"
  [ "$fail_n" -gt 0 ] && summary="$summary · ${C_FAIL}${fail_n} fail${C_RST}"
  say "$summary"
  local a
  for a in "${ADVICE[@]:-}"; do [ -n "$a" ] && say "  → $a"; done
  if [ "$fail_n" -eq 0 ] && [ "$warn_n" -eq 0 ]; then
    say "  ${C_OK}§ 一切正常${C_RST}"
  fi
}

print_json() {
  local exit_code="$1"
  {
    for c in "${CHECKS[@]:-}"; do [ -n "$c" ] && printf 'C%s\n' "$c"; done
    for f in "${FIXES[@]:-}"; do [ -n "$f" ] && printf 'F%s\n' "$f"; done
    for a in "${ADVICE[@]:-}"; do [ -n "$a" ] && printf 'A%s\n' "$a"; done
    printf 'V%s\n' "$VERSION"
    printf 'P%s|%s|%s\n' "$PROXY_HOST" "$PROXY_PORT" "$SYS_PROXY_ON"
    printf 'X%s\n' "$exit_code"
  } | python3 -c '
import sys, json
checks, fixes, advice = [], [], []
proxy = {}
version = "unknown"
exit_code = 0
for line in sys.stdin:
    line = line.rstrip("\n")
    if not line:
        continue
    tag, body = line[0], line[1:]
    if tag == "C":
        parts = body.split("\t", 2)
        while len(parts) < 3:
            parts.append("")
        checks.append({"level": parts[0], "id": parts[1], "message": parts[2]})
    elif tag == "F":
        parts = body.split("\t", 1)
        fixes.append({"level": parts[0], "message": parts[1] if len(parts) > 1 else ""})
    elif tag == "A":
        advice.append(body)
    elif tag == "V":
        version = body
    elif tag == "P":
        parts = body.split("|")
        proxy = {"host": parts[0], "port": parts[1], "system_proxy_enabled": parts[2] == "1"}
    elif tag == "X":
        exit_code = int(body or 0)
levels = [c["level"] for c in checks]
fails = levels.count("fail"); warns = levels.count("warn")
out = {
    "version": version,
    "level": "fail" if fails else ("warn" if warns else "ok"),
    "exit": exit_code,
    "counts": {"ok": levels.count("ok"), "warn": warns, "fail": fails, "info": levels.count("info")},
    "proxy": proxy,
    "checks": checks,
    "fixes": fixes,
    "advice": advice,
}
print(json.dumps(out, ensure_ascii=False, indent=2))
'
}

# ---------- 参数 ----------
usage() {
  cat <<'USAGE'
codex-netcheck —— Codex 网络 / 代理链路自检与自愈

适用：Codex CLI、Codex App（ChatGPT.app 内置引擎）、VS Code Codex。
也可被任意 Agent（DSH / Claude Code 等）直接调用，只依赖系统命令。

  codex-netcheck                 快速自检（默认，约 2-4 秒）
  codex-netcheck --doctor        追加 codex doctor 的 WebSocket / 连通性体检（约 15-20 秒）
  codex-netcheck --live          追加真实端到端请求（会产生一次很小的模型调用）
  codex-netcheck --all           以上全部（含 --speed 上行测速）
  codex-netcheck --speed         只测代理上行速度（恢复大历史会话的关键指标）
  codex-netcheck --handshake     连续 N 次 TLS 握手探针：成功率 + 耗时抖动（诊断中途断流）
  codex-netcheck --fix           自动补齐配置 / ~/.zshenv / GUI 代理同步器（幂等）
  codex-netcheck --fix --update  顺带把 codex 升级到最新版
  codex-netcheck --json          机器可读输出（便于 Agent 解析），人类提示走 stderr
  codex-netcheck --port 8080     指定本地代理端口（默认 7897，也可用 CODEX_NETCHECK_PORT）
  codex-netcheck --version       输出版本号

端口优先级：scutil --proxy 自动探测 > --port / CODEX_NETCHECK_PORT > 7897。
macOS 完整支持 config / shell / GUI 三层；Linux / Windows 仅做降级检查。
退出码：0 = 全绿；1 = 有警告；2 = 有失败
USAGE
}

while [ $# -gt 0 ]; do
  case "$1" in
    --doctor) DO_DOCTOR=1 ;;
    --live) DO_LIVE=1 ;;
    --speed) DO_SPEED=1 ;;
    --handshake) DO_HANDSHAKE=1 ;;
    --all) DO_DOCTOR=1; DO_LIVE=1; DO_SPEED=1; DO_HANDSHAKE=1 ;;
    --fix) DO_FIX=1 ;;
    --update) DO_UPDATE=1 ;;
    --json) DO_JSON=1 ;;
    --port)
      if [ $# -lt 2 ]; then
        printf '参数 --port 需要一个端口号（用 --help）\n' >&2
        exit 2
      fi
      DEFAULT_PORT="$2"
      shift
      ;;
    --port=*) DEFAULT_PORT="${1#*=}" ;;
    -V|--version) printf 'codex-netcheck %s\n' "$VERSION"; exit 0 ;;
    -h|--help) usage; exit 0 ;;
    *) printf '未知参数：%s（用 --help）\n' "$1" >&2; exit 2 ;;
  esac
  shift
done

if ! valid_port "$DEFAULT_PORT"; then
  printf '端口无效：%s（应为 1-65535 的整数，用 --help）\n' "$DEFAULT_PORT" >&2
  exit 2
fi

if [ "$DO_JSON" = "1" ] && ! command -v python3 >/dev/null 2>&1; then
  printf '--json 需要 python3（用 --help）\n' >&2
  exit 2
fi

detect_proxy

if [ "$DO_FIX" = "1" ]; then
  run_fixes
  detect_proxy
fi

run_checks
build_advice

fail_n=0; warn_n=0
for c in "${CHECKS[@]:-}"; do
  [ -z "$c" ] && continue
  case "${c%%$'\t'*}" in
    fail) fail_n=$((fail_n+1)) ;;
    warn) warn_n=$((warn_n+1)) ;;
  esac
done

exit_code=0
[ "$warn_n" -gt 0 ] && exit_code=1
[ "$fail_n" -gt 0 ] && exit_code=2

if [ "$DO_JSON" = "1" ]; then
  print_json "$exit_code"
else
  print_human
fi

exit "$exit_code"

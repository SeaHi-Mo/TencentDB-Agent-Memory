#!/usr/bin/env bash
# 单独拉起 proxy（context-proxy，端口 8096）。
#
# proxy 的转发上游走 PROXY_UPSTREAM_URL（与 memory 组的 MEMORY_LLM_* 独立）。
# proxy 会调 memory:8420 做鉴权 / skill / tdai memory 注入；调 memory-hub:8125
# 做 sessionInit control plane。可以单跑 proxy 但相关能力会降级 / 关闭。
#
# 用法：
#   ./start-proxy.sh
#
# 需要以下 proxy 组参数（写在 .env）：
#   PROXY_UPSTREAM_URL / PROXY_UPSTREAM_API_KEY / PROXY_UPSTREAM_MODEL

set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=./_lib.sh
source "$SCRIPT_DIR/_lib.sh"

load_env
require_vars \
  PROXY_IMAGE PROXY_PORT \
  PROXY_UPSTREAM_URL PROXY_UPSTREAM_MODEL

# PROXY_UPSTREAM_API_KEY 允许留空 —— 留空 / REPLACE_ME 时上游鉴权透传客户端
# 请求里自带的 key（BYOK），proxy 不再用服务端统一 key 覆盖。
# 见 config.example.yaml `upstream` 段：apiKey 为空即 passthrough。
PROXY_UPSTREAM_API_KEY="${PROXY_UPSTREAM_API_KEY:-}"
if [[ "$PROXY_UPSTREAM_API_KEY" == "REPLACE_ME" ]]; then
  warn "PROXY_UPSTREAM_API_KEY 仍是 REPLACE_ME，按留空处理（透传客户端自带 key）"
  PROXY_UPSTREAM_API_KEY=""
fi
if [[ -z "$PROXY_UPSTREAM_API_KEY" ]]; then
  warn "PROXY_UPSTREAM_API_KEY 为空 → 上游鉴权走透传（BYOK）：客户端必须在 Authorization / x-api-key 里带自己的 provider key。"
fi

# 与 memory-core 保持一致的 gateway 内部凭据（默认 local，仅本地体验）
MEMORY_CORE_GATEWAY_API_KEY="${MEMORY_CORE_GATEWAY_API_KEY:-local}"

CONTAINER=tdai-proxy
NETWORK=tdai-memory-stack

if ! $DOCKER network inspect "$NETWORK" >/dev/null 2>&1; then
  info "创建 docker 网络 $NETWORK"
  $DOCKER network create "$NETWORK" >/dev/null
fi

# 依赖检查（不阻塞，仅提醒）
if ! $DOCKER ps --format '{{.Names}}' 2>/dev/null | grep -qx "tdai-memory-core"; then
  warn "memory-core 容器未运行，proxy 的 auth / tdai memory / skill 注入将全部降级。"
fi
if ! $DOCKER ps --format '{{.Names}}' 2>/dev/null | grep -qx "tdai-memory-hub"; then
  warn "memory-hub 容器未运行，proxy 的 sessionInit control plane 不可达。"
fi

pull_image "$PROXY_IMAGE"
rm_container_if_exists "$CONTAINER"

# proxy 只从 YAML 读上游 URL / API key（不认 PROXY_UPSTREAM_URL 环境变量），
# 所以我们从 .env 生成一个最小 config.yaml 挂到容器 /data/config.yaml。
# 容器 CMD 已经是 [--config /data/config.yaml]。
CONFIG_DIR="${PROXY_CONFIG_DIR:-$SCRIPT_DIR/.proxy-config}"
mkdir -p "$CONFIG_DIR"
CONFIG_FILE="$CONFIG_DIR/config.yaml"

# ── 三大能力开关（默认最小可用；打开时自动串联依赖）──
# PROXY_ENABLE_AUTH        : 客户端凭 x-tdai-user-key 走内核 auth/verify → user_id
# PROXY_ENABLE_SESSION_INIT: 首轮弹表单选 team/agent/task；依赖 auth+tdai
# PROXY_ENABLE_TDAI        : L2/L3 记忆注入 + L1 召回；依赖 memory-core
#
# 便捷开关 PROXY_FULL_STACK=1 一键把三个都开。
if [[ "${PROXY_FULL_STACK:-0}" == "1" ]]; then
  PROXY_ENABLE_AUTH=1
  PROXY_ENABLE_TDAI=1
  PROXY_ENABLE_SESSION_INIT=1
fi
PROXY_ENABLE_AUTH="${PROXY_ENABLE_AUTH:-0}"
PROXY_ENABLE_TDAI="${PROXY_ENABLE_TDAI:-0}"
PROXY_ENABLE_SESSION_INIT="${PROXY_ENABLE_SESSION_INIT:-0}"

# sessionInit 依赖 auth 拿 user_id；开 sessionInit 时自动补 auth
if [[ "$PROXY_ENABLE_SESSION_INIT" == "1" && "$PROXY_ENABLE_AUTH" != "1" ]]; then
  warn "PROXY_ENABLE_SESSION_INIT=1 需要 auth；自动打开 PROXY_ENABLE_AUTH"
  PROXY_ENABLE_AUTH=1
fi

# skillRuntime.allowLlmWrite —— 是否允许 LLM 经 skill-bridge 创建/修改 skill。
# 默认关闭（消融实验口径）；置 1 时 patch/create/update/delete/files-write 才可用。
PROXY_ENABLE_SKILL_WRITE="${PROXY_ENABLE_SKILL_WRITE:-0}"

bool() { [[ "$1" == "1" ]] && echo "true" || echo "false"; }

# ── YAML 小工具 ─────────────────────────────────────────────────────────────
# 双引号标量转义：先转义反斜杠，再转义双引号（顺序不能反）。
yaml_quote() {
  local s="$1"
  s="${s//\\/\\\\}"
  s="${s//\"/\\\"}"
  printf '"%s"' "$s"
}

# ── Per-agent 上游覆盖（可选）───────────────────────────────────────────────
# PROXY_UPSTREAM_AGENTS 格式（多条用 `;` 分隔，字段用 `|` 分隔）：
#
#   <agent>=<url>|<apiKey>
#   <agent>=<url>              # 不带 key → 该 agent 透传客户端自己的 key
#
# 例：
#   PROXY_UPSTREAM_AGENTS="claude-code=https://api.deepseek.com/v1|sk-aaa;\
#                          codebuddy=https://api.moonshot.cn/v1|sk-bbb"
#
# 语义与 MemoryProxy/src/types.ts 的 AgentUpstreamEntry 完全一致：一旦某个
# agent 出现在这张表里，全局 upstream.apiKey 的兜底就被切断（要么用这里配的
# key，要么透传客户端 key）。收益：按客户端族群隔离额度 / 单独限流 / 单独看账。
UPSTREAM_AGENTS_YAML=""
render_upstream_agents() {
  local spec="${PROXY_UPSTREAM_AGENTS:-}"
  [[ -z "$spec" ]] && return 0
  local entries=() entry agent rest url apikey
  IFS=';' read -r -a entries <<< "$spec"
  local rendered=""
  for entry in "${entries[@]}"; do
    # 去掉首尾空白
    entry="${entry#"${entry%%[![:space:]]*}"}"
    entry="${entry%"${entry##*[![:space:]]}"}"
    [[ -z "$entry" ]] && continue
    if [[ "$entry" != *"="* ]]; then
      warn "PROXY_UPSTREAM_AGENTS 条目缺少 '='，已跳过：$entry"
      continue
    fi
    agent="${entry%%=*}"
    rest="${entry#*=}"
    agent="${agent//[[:space:]]/}"
    url="${rest%%|*}"
    if [[ "$rest" == *"|"* ]]; then
      apikey="${rest#*|}"
    else
      apikey=""
    fi
    if [[ -z "$agent" || -z "$url" ]]; then
      warn "PROXY_UPSTREAM_AGENTS 条目 agent/url 为空，已跳过：$entry"
      continue
    fi
    rendered+="    $(yaml_quote "$agent"):"$'\n'
    rendered+="      url: $(yaml_quote "$url")"$'\n'
    if [[ -n "$apikey" ]]; then
      rendered+="      apiKey: $(yaml_quote "$apikey")"$'\n'
    fi
    if [[ -z "$apikey" ]]; then
      info "  upstream.agents.${agent} → ${url}（透传客户端 key）"
    else
      info "  upstream.agents.${agent} → ${url}（服务端 key）"
    fi
  done
  if [[ -n "$rendered" ]]; then
    UPSTREAM_AGENTS_YAML="  agents:"$'\n'"$rendered"
  fi
}
render_upstream_agents

# ── 降本开关（全部可选；不设时行为与历史完全一致）─────────────────────────
# PROXY_INJECTORS：逗号分隔的注入器白名单。默认三个全开。
#   关掉 knowledge / skill 能显著压低每请求 input token（见 README「降本」段）。
PROXY_INJECTORS="${PROXY_INJECTORS:-skill,knowledge,tdai-memory}"
PROXY_INJECTION_ENABLED="${PROXY_INJECTION_ENABLED:-1}"
INJECTORS_YAML=""
_inj_trimmed="$(printf '%s' "$PROXY_INJECTORS" | tr -d '[:space:]')"
if [[ -z "$_inj_trimmed" ]]; then
  PROXY_INJECTION_ENABLED=0
  warn "PROXY_INJECTORS 为空 → 关闭上下文注入（injection.enabled=false）"
else
  IFS=',' read -r -a _inj_list <<< "$PROXY_INJECTORS"
  for _inj in "${_inj_list[@]}"; do
    _inj="${_inj//[[:space:]]/}"
    [[ -z "$_inj" ]] && continue
    INJECTORS_YAML+="    - ${_inj}"$'\n'
  done
fi

# PROXY_ASSET_REFLECTION=0 → 关掉 /analyse marker 下的 <asset_reflection> 块
# （内部效果评估用；开着会让模型在最终回答末尾追加一段复盘）。
PROXY_ASSET_REFLECTION="${PROXY_ASSET_REFLECTION:-1}"

# PROXY_EXTRACTION_ENABLED / PROXY_EXTRACTORS：写侧（对话回流内核）。
# 关掉 = 完全不写 L0 / 不归档 skill，后台抽取成本归零，但记忆也不再增长。
EXTRACTION_YAML=""
if [[ -n "${PROXY_EXTRACTION_ENABLED:-}" || -n "${PROXY_EXTRACTORS:-}" ]]; then
  EXTRACTION_YAML="extraction:
  enabled: $(bool "${PROXY_EXTRACTION_ENABLED:-1}")
  extractors: [${PROXY_EXTRACTORS:-skill,tdai-memory}]
"
fi

info "生成 proxy config → $CONFIG_FILE  (auth=$(bool $PROXY_ENABLE_AUTH) session-init=$(bool $PROXY_ENABLE_SESSION_INIT) tdai=$(bool $PROXY_ENABLE_TDAI) skill-write=$(bool $PROXY_ENABLE_SKILL_WRITE) injectors=${PROXY_INJECTORS:-none})"
cat > "$CONFIG_FILE" <<YAML
# 由 start-proxy.sh 自动生成 —— 每次启动覆盖，请不要手动改。
server:
  host: 0.0.0.0
  port: 8096
  forwardTimeoutMs: 600000

upstream:
  url: "${PROXY_UPSTREAM_URL}"
  apiKey: "${PROXY_UPSTREAM_API_KEY}"
${UPSTREAM_AGENTS_YAML}

log:
  file: ""
  level: info
  backend: console

# tdai 内核对接（用于 injection / skill / auth 拉取）
tdai:
  enabled: $(bool $PROXY_ENABLE_TDAI)
  endpoint: "http://memory-core:8420"
  apiKey: "${MEMORY_CORE_GATEWAY_API_KEY}"
  serviceId: default
  memory:
    enabled: true
    inject: true
    writeL0: true
    recallL1: true
    injectL2L3: true

skill:
  endpoint: "http://memory-core:8420"
  serviceToken: "${MEMORY_CORE_GATEWAY_API_KEY}"

# knowledge 注入器的注册门槛（shouldRegisterKnowledgeInjector）：
# injectors 含 knowledge + knowledge.enabled + knowledge.serviceToken 三者同时满足。
# 缺了这一段时注入器静默不注册，<knowledge_tools> 永远不会出现。
knowledge:
  enabled: $(bool $PROXY_ENABLE_TDAI)
  endpoint: "http://memory-core:8420"
  serviceToken: "${MEMORY_CORE_GATEWAY_API_KEY}"
  serviceId: default

auth:
  enabled: $(bool $PROXY_ENABLE_AUTH)
  url: "http://memory-core:8420"
  timeoutMs: 5000

sessionInit:
  enabled: $(bool $PROXY_ENABLE_SESSION_INIT)
  maxRetries: 3
  injectAgentContext: true
  injectTaskContext: true
  headerAutoSelect:
    enabled: true
    teamHeader: "x-team-id"
    agentHeader: "x-agent-id"
    taskHeader: "x-task-id"
    onMismatch: "form"

costGuard:
  enabled: false

# 注入器白名单由 .env 的 PROXY_INJECTORS 控制（默认三个全开）。
# knowledge 依赖 memory-hub 起来，否则 hook 内部会降级为空块。
# 降本提示：每请求注入的 system 块约 4k–10k tokens，去掉 knowledge 省 ~1k–1.8k，
# 去掉 skill 省 ~1.8k–3.7k（详见 deploy/global-images/README.md「降本」段）。
injection:
  enabled: $(bool "$PROXY_INJECTION_ENABLED")
  injectors:
${INJECTORS_YAML}  assetReflection:
    markerOptIn: $(bool "$PROXY_ASSET_REFLECTION")

# skill-bridge 的写权限：false 时 patch / create / update / delete / files-write 一律 40302。
# 打开后主模型可直接创建、修改 skill（见 MemoryProxy/config.example.yaml skillRuntime）。
skillRuntime:
  allowLlmWrite: $(bool $PROXY_ENABLE_SKILL_WRITE)

# 写侧（对话回流内核 + skill 归档）。只有显式设置 PROXY_EXTRACTION_ENABLED /
# PROXY_EXTRACTORS 时才写这一段，未设置时沿用镜像内默认（enabled=true）。
${EXTRACTION_YAML}
redis:
  enabled: false
YAML

# ── 本地源码热修挂载（可选）─────────────────────────────────────────────
# 容器 ENTRYPOINT 是 `node --import tsx/esm src/index.ts`（Dockerfile:105），
# 直接执行 TS 源码、不预编译 —— 所以把改过的源文件只读挂进去就生效，无需重建镜像。
#
# 修的是 session-init 的 `getLastUserMessageText`（session/*/cleaner.ts）：
# dsh 原生 `ask_user_question` 的回答，tool_call_id 是上游 LLM 的普通 id
# （`call_00_…`），不带 proxy 伪造表的 `call_dsh_session_init_` 前缀。旧逻辑
# 不认领它 → 扫描回退到上一阶段（team_select）的旧回答 → extractAgentOnly
# 永远抽不到 agent → attemptCount 到 maxRetries → status:initialized +
# bypassed:true → 整个会话 L0 一条都不写。
#
# 源码目录不存在时（例如只拷了 deploy/ 目录单独部署）静默跳过，保持镜像原行为。
SRC_ROOT="$SCRIPT_DIR/../../MemoryProxy/src"
SRC_MOUNTS=()
if [[ -f "$SRC_ROOT/session/codebuddy/cleaner.ts" ]]; then
  SRC_MOUNTS+=(-v "$SRC_ROOT/session/codebuddy/cleaner.ts:/app/src/session/codebuddy/cleaner.ts:ro")
  SRC_MOUNTS+=(-v "$SRC_ROOT/session/claude-code/cleaner.ts:/app/src/session/claude-code/cleaner.ts:ro")
  info "挂载本地源码热修 → cleaner.ts (codebuddy + claude-code)"
else
  warn "未找到 $SRC_ROOT，跳过源码热修挂载（沿用镜像内源码）"
fi

info "启动 proxy (image=$PROXY_IMAGE, port=$PROXY_PORT)"
$DOCKER run -d --name "$CONTAINER" \
  --network "$NETWORK" \
  --network-alias proxy \
  --add-host=host.docker.internal:host-gateway \
  -p "${PROXY_PORT}:8096" \
  -v "$CONFIG_FILE:/data/config.yaml:ro" \
  ${SRC_MOUNTS[@]+"${SRC_MOUNTS[@]}"} \
  "$PROXY_IMAGE" >/dev/null

wait_healthy "$CONTAINER" 90
ok "proxy 已启动 → http://localhost:${PROXY_PORT}/"
ok "  用法：把 coding agent 的 API base 指向 http://localhost:${PROXY_PORT}"

#!/usr/bin/env bash
# 管理「实例级上游 LLM 配置」：
#     租户(spaceId) × 客户端族群(agent_source) × 用途(conversation|extraction)
#     → 覆盖 proxy 的上游 base_url / api_key / model_id
#
# 写入 memory-core 的 meta_instance_upstream_config 表；proxy 侧
# instance-upstream-cache 每 5 分钟拉取一次（TTL 5min + stale-if-error），
# 所以改完不需要重启 proxy，最多等 5 分钟生效。
#
# 为什么需要它：
#   1) 隔离 key —— 不再让所有接入的 agent 共用一把全局 upstream.apiKey，
#      每个 team / 每种客户端可以走自己的 provider 账号与额度；
#   2) 分离计费 —— 把后台记忆抽取(extraction)指到便宜模型，coding agent 的
#      对话(conversation)保留贵模型，两边账单和限流互不影响。
#
# 用法：
#   ./set-instance-upstream.sh list  --space default
#   ./set-instance-upstream.sh get   --space default [--agent default] [--type conversation]
#   ./set-instance-upstream.sh set   --space default [--agent default] [--type extraction] \
#                                    --mode custom_unified --base-url https://api.deepseek.com/v1 \
#                                    --api-key sk-xxx [--model-id deepseek-chat] [--dry-run]
#   ./set-instance-upstream.sh reset --space default [--agent default] [--type conversation]
#   ./set-instance-upstream.sh split --space default \
#                                    [--conv-url U --conv-key K --conv-model M] \
#                                    [--extr-url U --extr-key K --extr-model M]
#
# 说明：
#   - --space   = 请求路径里的 spaceId（如 /claude-code/<space>），也是 x-tdai-service-id；
#   - --agent   = URL 路径首段（claude-code / codebuddy / dsh / codex / opencode / pi …），
#                 填 default 表示该实例的兜底行（精确匹配失败时回落）；
#   - --mode    = official（走 proxy 全局上游）| custom_unified（用这里的 url+key）|
#                 custom_passthrough（用客户端自带的 key，注意 extraction 不支持）；
#   - --api-key 会明文写进 memory-core 的元数据库，请确保该库的访问权限可控。
#
# 鉴权：需要 system admin 的 user_key（即 start-memory-core.sh 生成的 .admin-key）。

set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=./_lib.sh
source "$SCRIPT_DIR/_lib.sh"

# .env 可选：只为拿 MEMORY_CORE_PORT / MEMORY_CORE_GATEWAY_API_KEY / admin key 路径。
if [[ -f "$ENV_FILE" ]]; then
  load_env
else
  warn ".env 不存在，使用环境变量或默认值（core 默认 http://localhost:8420）"
fi

MEMORY_CORE_PORT="${MEMORY_CORE_PORT:-8420}"
CORE_URL="${MEMORY_CORE_URL:-http://localhost:${MEMORY_CORE_PORT}}"
ADMIN_KEY_FILE="${MEMORY_CORE_ADMIN_KEY_FILE:-$SCRIPT_DIR/.admin-key}"

CMD="${1:-}"
[[ -n "$CMD" ]] || die "缺少子命令。可用：list | get | set | reset | split（-h 查看用法）"
shift || true

SPACE="default"
AGENT="default"
TYPE="conversation"
MODE=""
BASE_URL=""
API_KEY=""
MODEL_ID=""
DESCRIPTION=""
CONV_URL=""; CONV_KEY=""; CONV_MODEL=""
EXTR_URL=""; EXTR_KEY=""; EXTR_MODEL=""
ADMIN_KEY_ARG=""
DRY_RUN=0

usage() {
  sed -n '3,40p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'
}

while (( $# > 0 )); do
  case "$1" in
    --space)      SPACE="${2:?--space 需要值}"; shift 2 ;;
    --agent)      AGENT="${2:?--agent 需要值}"; shift 2 ;;
    --type)       TYPE="${2:?--type 需要值}"; shift 2 ;;
    --mode)       MODE="${2:?--mode 需要值}"; shift 2 ;;
    --base-url)   BASE_URL="${2:?--base-url 需要值}"; shift 2 ;;
    --api-key)    API_KEY="${2:?--api-key 需要值}"; shift 2 ;;
    --model-id)   MODEL_ID="${2:?--model-id 需要值}"; shift 2 ;;
    --description) DESCRIPTION="${2:?--description 需要值}"; shift 2 ;;
    --conv-url)   CONV_URL="${2:?--conv-url 需要值}"; shift 2 ;;
    --conv-key)   CONV_KEY="${2:?--conv-key 需要值}"; shift 2 ;;
    --conv-model) CONV_MODEL="${2:?--conv-model 需要值}"; shift 2 ;;
    --extr-url)   EXTR_URL="${2:?--extr-url 需要值}"; shift 2 ;;
    --extr-key)   EXTR_KEY="${2:?--extr-key 需要值}"; shift 2 ;;
    --extr-model) EXTR_MODEL="${2:?--extr-model 需要值}"; shift 2 ;;
    --admin-key)  ADMIN_KEY_ARG="${2:?--admin-key 需要值}"; shift 2 ;;
    --core-url)   CORE_URL="${2:?--core-url 需要值}"; shift 2 ;;
    --dry-run)    DRY_RUN=1; shift ;;
    -h|--help)    usage; exit 0 ;;
    *)            die "未知参数：$1（-h 查看用法）" ;;
  esac
done

ADMIN_KEY="${ADMIN_KEY_ARG:-${MEMORY_CORE_ADMIN_KEY:-}}"
if [[ -z "$ADMIN_KEY" ]]; then
  if [[ -s "$ADMIN_KEY_FILE" ]]; then
    ADMIN_KEY="$(cat "$ADMIN_KEY_FILE")"
  else
    die "找不到 admin user_key。用 --admin-key 传入，或确认 $ADMIN_KEY_FILE 存在（先跑 ./start-memory-core.sh）"
  fi
fi

# spaceId 会被 Core 静默规范化（[/\."$ 空格 \0] → _），提前提醒避免"配了没生效"。
if printf '%s' "$SPACE" | grep -q '[/\\."$ ]'; then
  warn "spaceId '${SPACE}' 含特殊字符，Core 会静默改写为 '$(printf '%s' "$SPACE" | tr '/\\."$ ' '_')'，请尽量用纯字母数字-_ 的名字。"
fi

# JSON 字符串转义（值里出现 \ 或 " 时不至于拼出非法 JSON）。
json_escape() {
  local s="$1"
  s="${s//\\/\\\\}"
  s="${s//\"/\\\"}"
  printf '%s' "$s"
}

# 组装 body：只放非空字段，避免把空串写进库里。
build_body() {
  local agent="$1" type="$2" mode="$3" base_url="$4" api_key="$5" model_id="$6" desc="$7"
  local parts=()
  parts+=("\"agent_source\":\"$(json_escape "$agent")\"")
  parts+=("\"type\":\"$(json_escape "$type")\"")
  parts+=("\"mode\":\"$(json_escape "$mode")\"")
  [[ -n "$base_url" ]] && parts+=("\"base_url\":\"$(json_escape "$base_url")\"")
  [[ -n "$api_key" ]]  && parts+=("\"api_key\":\"$(json_escape "$api_key")\"")
  [[ -n "$model_id" ]] && parts+=("\"model_id\":\"$(json_escape "$model_id")\"")
  [[ -n "$desc" ]]     && parts+=("\"description\":\"$(json_escape "$desc")\"")
  local IFS=,
  printf '{%s}' "${parts[*]}"
}

api_call() {
  local path="$1" body="$2"
  local -a headers=(
    -H "Content-Type: application/json"
    -H "x-tdai-user-key: ${ADMIN_KEY}"
    -H "x-tdai-service-id: ${SPACE}"
  )
  # gateway 的 Bearer 门（server.apiKey）留空时是默认放行的，可以不传。
  [[ -n "${MEMORY_CORE_GATEWAY_API_KEY:-}" ]] && headers+=(-H "Authorization: Bearer ${MEMORY_CORE_GATEWAY_API_KEY}")

  if (( DRY_RUN )); then
    info "[dry-run] POST ${CORE_URL}${path}"
    info "           x-tdai-service-id: ${SPACE}"
    info "           body: ${body}"
    return 0
  fi

  local tmp status
  tmp="$(mktemp -t tdai-upstream.XXXXXX)"
  status="$($CURL -sS -o "$tmp" -w "%{http_code}" --max-time 10 \
    -X POST "${headers[@]}" \
    --data "$body" \
    "${CORE_URL}${path}" 2>/dev/null || echo "000")"

  if [[ "$status" == "000" ]]; then
    rm -f "$tmp"
    die "连不上 memory-core（${CORE_URL}）。确认容器在跑：docker ps | grep tdai-memory-core"
  fi
  if [[ "$status" != "200" ]]; then
    warn "memory-core 返回 HTTP ${status}："
    cat "$tmp" 2>/dev/null; echo
    rm -f "$tmp"
    case "$status" in
      401) die "鉴权失败：admin user_key 无效（检查 $ADMIN_KEY_FILE 或 --admin-key）" ;;
      403) die "权限不足：该接口要求 system admin 用户" ;;
      400) die "参数不合法（见上方 message；常见：custom_unified 必须给 base_url + api_key，extraction 不支持 custom_passthrough）" ;;
      *)   die "调用失败（HTTP ${status}）" ;;
    esac
  fi

  if command -v python3 >/dev/null 2>&1; then
    python3 -m json.tool < "$tmp" 2>/dev/null || cat "$tmp"
    echo
  else
    cat "$tmp"; echo
  fi
  rm -f "$tmp"
}

# get / reset 的选择器 body：只放 agent_source + type（多余字段虽会被 zod strip，
# 但不依赖这一点更稳）。
selector_body() {
  printf '{"agent_source":"%s","type":"%s"}' "$(json_escape "$1")" "$(json_escape "$2")"
}

validate_type() {
  case "$1" in
    conversation|extraction) ;;
    *) die "--type 只能是 conversation 或 extraction" ;;
  esac
}

validate_mode() {
  case "$1" in
    official|custom_unified|custom_passthrough) ;;
    *) die "--mode 只能是 official / custom_unified / custom_passthrough" ;;
  esac
}

case "$CMD" in
  list)
    api_call "/v3/meta/instance-upstream/list" "{}"
    ;;

  get)
    validate_type "$TYPE"
    api_call "/v3/meta/instance-upstream/get" "$(selector_body "$AGENT" "$TYPE")"
    ;;

  reset)
    validate_type "$TYPE"
    api_call "/v3/meta/instance-upstream/reset" "$(selector_body "$AGENT" "$TYPE")"
    ;;

  set)
    validate_type "$TYPE"
    [[ -n "$MODE" ]] || die "set 需要 --mode"
    validate_mode "$MODE"
    if [[ "$TYPE" == "extraction" && "$MODE" == "custom_passthrough" ]]; then
      die "extraction 不支持 custom_passthrough（Core 侧会拒绝）：后台抽取必须走服务端 key，请用 custom_unified"
    fi
    if [[ "$MODE" != "official" && -z "$BASE_URL" ]]; then
      die "${MODE} 需要 --base-url"
    fi
    if [[ "$MODE" == "custom_unified" && -z "$API_KEY" ]]; then
      die "custom_unified 需要 --api-key"
    fi
    api_call "/v3/meta/instance-upstream/set" \
      "$(build_body "$AGENT" "$TYPE" "$MODE" "$BASE_URL" "$API_KEY" "$MODEL_ID" "$DESCRIPTION")"
    ;;

  split)
    touched=0
    if [[ -n "$CONV_URL" || -n "$CONV_KEY" || -n "$CONV_MODEL" ]]; then
      [[ -n "$CONV_URL" ]] || die "split 传了 --conv-* 就必须给 --conv-url"
      [[ -n "$CONV_KEY" ]] || die "split 的 conversation 侧需要 --conv-key（custom_unified 必填）"
      info "写入 conversation（客户端对话）→ ${CONV_URL}"
      api_call "/v3/meta/instance-upstream/set" \
        "$(build_body "$AGENT" "conversation" "custom_unified" "$CONV_URL" "$CONV_KEY" "$CONV_MODEL" "$DESCRIPTION")"
      touched=1
    fi
    if [[ -n "$EXTR_URL" || -n "$EXTR_KEY" || -n "$EXTR_MODEL" ]]; then
      [[ -n "$EXTR_URL" ]] || die "split 传了 --extr-* 就必须给 --extr-url"
      [[ -n "$EXTR_KEY" ]] || die "split 的 extraction 侧需要 --extr-key（custom_unified 必填）"
      info "写入 extraction（后台记忆抽取）→ ${EXTR_URL}"
      api_call "/v3/meta/instance-upstream/set" \
        "$(build_body "$AGENT" "extraction" "custom_unified" "$EXTR_URL" "$EXTR_KEY" "$EXTR_MODEL" "$DESCRIPTION")"
      touched=1
    fi
    (( touched )) || die "split 至少要给一组 --conv-* 或 --extr-*"
    ok "已写入。proxy 最多 5 分钟后生效（instance-upstream 缓存 TTL）。"
    ;;

  -h|--help|help)
    usage
    ;;

  *)
    die "未知子命令：${CMD}（可用：list | get | set | reset | split）"
    ;;
esac

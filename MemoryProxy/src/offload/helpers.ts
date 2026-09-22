/**
 * Context offload — pure helpers (no runtime imports, so they can be unit-tested
 * standalone with `bun`).
 *
 * 背景：proxy 只做"客户端"这一半 —— 把工具调用结果推给 Core 的 offload server
 * （/v2/offload/ingest 触发 L1 摘要），再在上下文超过阈值时请服务端压缩
 * （/v2/offload/compact，把旧工具结果换成摘要 + 注入 MMD 任务图）。
 *
 * 这里只负责：算 token 估算 / 抽取 tool pair / 决定压缩档位，保持零依赖。
 */

/** offload server 的压缩档位（由 ratio = total/context_window 决定）。 */
export type OffloadLevel = "mild" | "aggressive" | "emergency";

/** 各档位对应的 ratio —— 服务端 resolveLevel 的阈值是 0.5 / 0.85 / 0.95。 */
export const LEVEL_RATIO: Record<OffloadLevel, number> = {
  mild: 0.6,
  aggressive: 0.9,
  emergency: 0.98,
};

export interface OffloadToolPair {
  tool_name: string;
  tool_call_id: string;
  params: unknown;
  result: unknown;
  timestamp: string;
}

/** 默认字符/token 比：中英混排 ≈2.6，纯英文 ≈4，纯中文 ≈1.6。取 3 做保守估算。 */
const DEFAULT_CHARS_PER_TOKEN = 3;

/**
 * 估算任意 JSON 值的 token 数（按字符数 / charsPerToken）。
 *
 * 刻意不引 tiktoken：proxy 在热路径上，每个请求都要估一次；误差对"是否越过
 * 阈值"这个判断足够（阈值本身是保守值，且压缩失败会 fail-open）。
 */
export function estimateTokens(value: unknown, charsPerToken = DEFAULT_CHARS_PER_TOKEN): number {
  const chars = countChars(value);
  return Math.ceil(chars / Math.max(1, charsPerToken));
}

function countChars(value: unknown): number {
  if (value == null) return 0;
  if (typeof value === "string") return value.length;
  if (typeof value === "number" || typeof value === "boolean") return 8;
  if (Array.isArray(value)) {
    let n = 2; // []
    for (const item of value) n += countChars(item) + 1;
    return n;
  }
  if (typeof value === "object") {
    let n = 2; // {}
    for (const [k, v] of Object.entries(value as Record<string, unknown>)) {
      n += k.length + 3 + countChars(v);
    }
    return n;
  }
  return 0;
}

/** 取消息的纯文本（OpenAI 的 string content / Anthropic 的 text block 数组）。 */
export function messageText(msg: unknown): string {
  const m = msg as Record<string, unknown> | null | undefined;
  if (!m) return "";
  const content = (m.content ?? (m.message as Record<string, unknown> | undefined)?.content) as unknown;
  if (typeof content === "string") return content;
  if (Array.isArray(content)) {
    const parts: string[] = [];
    for (const block of content) {
      const b = block as Record<string, unknown> | null;
      if (b && typeof b.text === "string") parts.push(b.text);
    }
    return parts.join("\n");
  }
  return "";
}

/** 该消息是否携带工具调用结果（OpenAI `role:tool` / Anthropic tool_result block）。 */
export function isToolResultMessage(msg: unknown): boolean {
  const m = msg as Record<string, unknown> | null | undefined;
  if (!m) return false;
  if (m.role === "tool") return true;
  if (typeof m.tool_call_id === "string" && m.tool_call_id) return true;
  if (typeof m.tool_use_id === "string" && m.tool_use_id) return true;
  const content = m.content;
  if (Array.isArray(content)) {
    return content.some((b) => (b as Record<string, unknown> | null)?.type === "tool_result");
  }
  return false;
}

/** 取工具结果的 tool_call_id / tool_use_id。 */
export function toolResultId(msg: unknown): string | null {
  const m = msg as Record<string, unknown> | null | undefined;
  if (!m) return null;
  if (typeof m.tool_call_id === "string" && m.tool_call_id) return m.tool_call_id;
  if (typeof m.tool_use_id === "string" && m.tool_use_id) return m.tool_use_id;
  const content = m.content;
  if (Array.isArray(content)) {
    for (const b of content) {
      const block = b as Record<string, unknown> | null;
      if (block?.type === "tool_result" && typeof block.tool_use_id === "string") {
        return block.tool_use_id;
      }
    }
  }
  return null;
}

/** 取工具结果的正文（字符串原样 / Anthropic tool_result.content）。 */
function toolResultContent(msg: unknown): unknown {
  const m = msg as Record<string, unknown> | null | undefined;
  if (!m) return "";
  if (Array.isArray(m.content)) {
    for (const b of m.content) {
      const block = b as Record<string, unknown> | null;
      if (block?.type === "tool_result") return block.content ?? "";
    }
  }
  return typeof m.content === "string" ? m.content : (m.content ?? "");
}

/** 从 assistant 消息里收集 tool_call_id → {name, arguments}。 */
function collectToolCalls(messages: unknown[]): Map<string, { name: string; params: unknown }> {
  const out = new Map<string, { name: string; params: unknown }>();
  for (const msg of messages) {
    const m = msg as Record<string, unknown> | null | undefined;
    if (!m) continue;
    // OpenAI: assistant.tool_calls[]
    const openaiCalls = m.tool_calls;
    if (Array.isArray(openaiCalls)) {
      for (const c of openaiCalls) {
        const call = c as Record<string, unknown> | null;
        const id = typeof call?.id === "string" ? call.id : null;
        if (!id) continue;
        const fn = (call?.function ?? {}) as Record<string, unknown>;
        let params: unknown = fn.arguments ?? {};
        if (typeof params === "string") {
          try {
            params = JSON.parse(params);
          } catch {
            /* 保持原始字符串 */
          }
        }
        out.set(id, { name: typeof fn.name === "string" ? fn.name : "unknown", params });
      }
    }
    // Anthropic: assistant.content[].type === "tool_use"
    if (Array.isArray(m.content)) {
      for (const b of m.content) {
        const block = b as Record<string, unknown> | null;
        if (block?.type !== "tool_use") continue;
        const id = typeof block.id === "string" ? block.id : null;
        if (!id) continue;
        out.set(id, {
          name: typeof block.name === "string" ? block.name : "unknown",
          params: block.input ?? {},
        });
      }
    }
  }
  return out;
}

/**
 * 抽取 (tool_call, tool_result) 对，供 /v2/offload/ingest 使用。
 *
 * `skipIds` 里已推过的 pair 会被跳过（proxy 侧按会话记录，避免重复 ingest）。
 * 返回顺序保持对话顺序；最多返回 `maxPairs` 条（从最新的往回取，保证长会话
 * 里推给 L1 的是最近、最相关的工具结果）。
 */
export function extractToolPairs(
  messages: unknown[],
  opts: { skipIds?: Set<string>; maxPairs?: number; nowIso?: string } = {},
): OffloadToolPair[] {
  const calls = collectToolCalls(messages);
  const pairs: OffloadToolPair[] = [];
  const now = opts.nowIso ?? chinaIsoNow();
  for (const msg of messages) {
    if (!isToolResultMessage(msg)) continue;
    const id = toolResultId(msg);
    if (!id) continue;
    if (opts.skipIds?.has(id)) continue;
    const call = calls.get(id);
    pairs.push({
      tool_name: call?.name ?? "unknown",
      tool_call_id: id,
      params: call?.params ?? {},
      result: toolResultContent(msg),
      timestamp: now,
    });
  }
  const maxPairs = opts.maxPairs ?? 40;
  return pairs.length > maxPairs ? pairs.slice(pairs.length - maxPairs) : pairs;
}

/** 最近若干轮 user/assistant 纯文本（服务端 L1/L1.5 用来理解任务意图）。 */
export function recentTextMessages(
  messages: unknown[],
  limit = 6,
): Array<{ role: "user" | "assistant"; content: string }> {
  const out: Array<{ role: "user" | "assistant"; content: string }> = [];
  for (let i = messages.length - 1; i >= 0; i--) {
    const m = messages[i] as Record<string, unknown> | null | undefined;
    const role = m?.role;
    if (role !== "user" && role !== "assistant") continue;
    if (isToolResultMessage(m)) continue;
    const text = messageText(m).trim();
    if (!text) continue;
    out.push({ role, content: text.slice(0, 2000) });
    if (out.length >= limit) break;
  }
  return out.reverse();
}

/** ratio = total_tokens / context_window。默认按档位反推 window，保证落到目标档。 */
export function buildCompactParams(
  totalTokens: number,
  level: OffloadLevel,
  contextWindow?: number,
): { ratio: number; contextWindow: number; totalTokens: number } {
  const window = contextWindow && contextWindow > 0
    ? contextWindow
    : Math.max(1, Math.round(totalTokens / LEVEL_RATIO[level]));
  return { ratio: totalTokens / window, contextWindow: window, totalTokens };
}

/** 东八区 ISO8601（服务端 L1 提示词要求 +08:00 形状）。 */
export function chinaIsoNow(date = new Date()): string {
  const shifted = new Date(date.getTime() + 8 * 3600 * 1000);
  return `${shifted.toISOString().slice(0, 19)}+08:00`;
}

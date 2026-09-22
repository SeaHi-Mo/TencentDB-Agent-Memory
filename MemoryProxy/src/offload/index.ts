/**
 * Context offload 客户端（proxy 侧）。
 *
 * 职责（对照 MemoryCore/src/offload_server 的服务端契约）：
 *   1. ingest：把本轮新出现的 (tool_call, tool_result) 对推给 Core
 *      `/v2/offload/ingest` → 服务端排 L1 任务，用 LLM 产出摘要 + 落 ref 文件。
 *   2. compact：当上下文 token 超过阈值且过了冷却期，把整段 messages 交给
 *      `/v2/offload/compact` → 返回"旧工具结果已被摘要替换 / 历史 MMD 已注入"的
 *      messages，proxy 用它替换原始 body 再转发上游。
 *
 * 为什么必须"低频 + 冷却"：
 *   改写历史会让上游的 prompt cache 整段失效。以 deepseek-flash 为例，
 *   缓存命中 ¥0.02/M vs 未命中 ¥1/M（相差 50 倍），每次压缩都要付一次
 *   "压缩后上下文 × 未命中价"的重定价成本。盈亏平衡轮数
 *   T ≈ C_after/(C_before−C_after) × 50，典型值 ~12 轮，所以默认
 *   cooldownTurns=40 远高于平衡点。
 *
 * 失败一律 fail-open：任何异常/超时都返回 null，调用方继续用原始 body。
 */

import type { AgentContext } from "../injection/types.js";
import {
  buildCompactParams,
  estimateTokens,
  extractToolPairs,
  recentTextMessages,
  type OffloadLevel,
} from "./helpers.js";

const TAG = "[offload]";

export interface OffloadClientConfig {
  /** 总开关；false 时 runOffload 直接返回 null（零开销）。 */
  enabled: boolean;
  /** Core 地址，如 http://memory-core:8420 */
  endpoint: string;
  /** Core 的 Bearer（与 skill.serviceToken 同源：MEMORY_CORE_GATEWAY_API_KEY） */
  serviceToken: string;
  /** x-tdai-service-id，即 spaceId（如 default） */
  serviceId: string;
  /** 压缩档位：mild（默认，只换摘要）| aggressive | emergency */
  level: OffloadLevel;
  /** 超过多少 token 才考虑压缩。默认 120k —— 远低于 1M 窗口，但足够摊平重定价成本。 */
  triggerTokens: number;
  /** 两次压缩之间至少间隔多少轮（防止每轮改写历史把缓存打碎）。默认 40。 */
  cooldownTurns: number;
  /** 单次 ingest 最多推多少对（服务端 L1 每批上限 20）。默认 40。 */
  maxIngestPairs: number;
  /** HTTP 超时（ms）。默认 20000（含服务端 L1 摘要等待）。 */
  timeoutMs: number;
  /** 只统计不修改：用于上线前评估收益。 */
  dryRun: boolean;
  /** 覆盖 context_window（不设则按档位反推出 ratio）。 */
  contextWindow?: number;
  /** 每会话状态缓存上限。默认 512。 */
  maxSessions: number;
}

export const DEFAULT_OFFLOAD_CONFIG: OffloadClientConfig = {
  enabled: false,
  endpoint: "",
  serviceToken: "",
  serviceId: "default",
  level: "mild",
  triggerTokens: 120_000,
  cooldownTurns: 40,
  maxIngestPairs: 40,
  timeoutMs: 20_000,
  dryRun: false,
  maxSessions: 512,
};

export interface OffloadOutcome {
  /** 压缩后的 messages（dryRun 或未压缩时为 null）。 */
  messages: unknown[] | null;
  beforeTokens: number;
  afterTokens: number;
  savedTokens: number;
  level: OffloadLevel;
  dryRun: boolean;
  report?: Record<string, unknown>;
}

interface SessionState {
  ingestedIds: Set<string>;
  turn: number;
  lastCompactTurn: number;
  compactions: number;
}

const sessions = new Map<string, SessionState>();

function getState(sessionKey: string, maxSessions: number): SessionState {
  let state = sessions.get(sessionKey);
  if (!state) {
    if (sessions.size >= maxSessions) {
      const oldest = sessions.keys().next().value as string | undefined;
      if (oldest !== undefined) sessions.delete(oldest);
    }
    state = { ingestedIds: new Set(), turn: 0, lastCompactTurn: Number.NEGATIVE_INFINITY, compactions: 0 };
    sessions.set(sessionKey, state);
  }
  return state;
}

/** 仅供测试/排障。 */
export function resetOffloadSessions(): void {
  sessions.clear();
}

/**
 * offload server 的 session_id 只接受 `[A-Za-z0-9_.:-]`、≤500 字符。
 * proxy 的 sessionKey 可能是 `${agentSource}:${uuid}` 或客户端自带的任意串，
 * 这里做确定性归一，保证同一会话每次都映射到同一个 id。
 */
export function normalizeOffloadSessionId(sessionKey: string): string {
  const cleaned = sessionKey.replace(/[^A-Za-z0-9_.:-]/g, "-").slice(0, 500);
  return cleaned.length > 0 ? cleaned : "anonymous";
}

function authHeaders(cfg: OffloadClientConfig): Record<string, string> {
  const headers: Record<string, string> = {
    "Content-Type": "application/json",
    "x-tdai-service-id": cfg.serviceId || "default",
  };
  if (cfg.serviceToken) headers.Authorization = `Bearer ${cfg.serviceToken}`;
  return headers;
}

/** fire-and-forget：推新出现的工具对，触发服务端 L1 摘要。 */
function ingestToolPairs(
  cfg: OffloadClientConfig,
  sessionId: string,
  messages: unknown[],
  state: SessionState,
  prompt: unknown,
): void {
  const pairs = extractToolPairs(messages, {
    skipIds: state.ingestedIds,
    maxPairs: cfg.maxIngestPairs,
  });
  if (pairs.length === 0) return;
  // 先记账再发请求：即使请求失败也不重复推送，避免热路径上反复重试。
  for (const p of pairs) state.ingestedIds.add(p.tool_call_id);

  const body: Record<string, unknown> = {
    session_id: sessionId,
    tool_pairs: pairs,
  };
  const recent = recentTextMessages(messages);
  if (recent.length > 0) body.recent_messages = recent;
  // 调用方传进来的可能是数组/对象（不同 handler 的 user 文案提取结果不同），
  // 只接受字符串，避免 `.trim is not a function`。
  if (typeof prompt === "string" && prompt.trim()) body.prompt = prompt.slice(0, 4000);

  void fetch(`${cfg.endpoint.replace(/\/$/, "")}/v2/offload/ingest`, {
    method: "POST",
    headers: authHeaders(cfg),
    body: JSON.stringify(body),
    signal: AbortSignal.timeout(cfg.timeoutMs),
  })
    .then((resp) => {
      if (!resp.ok) {
        console.warn(`${TAG} ingest HTTP ${resp.status} session=${sessionId} pairs=${pairs.length}`);
      }
    })
    .catch((err: unknown) => {
      console.warn(`${TAG} ingest failed session=${sessionId}: ${err instanceof Error ? err.message : String(err)}`);
    });
}

/**
 * 主入口。返回 null 表示"不压缩"（未启用/未达阈值/冷却中/失败/dryRun），
 * 调用方保持原 body 不动。
 */
export async function runOffload(params: {
  config: OffloadClientConfig;
  sessionKey: string;
  messages: unknown[];
  systemPrompt?: string | null;
  userPrompt?: string | null;
  /** 请求路径里的 spaceId（多租户时用它做 x-tdai-service-id 路由）。 */
  spaceId?: string | null;
}): Promise<OffloadOutcome | null> {
  const baseCfg = params.config;
  const cfg: OffloadClientConfig = params.spaceId
    ? { ...baseCfg, serviceId: params.spaceId }
    : baseCfg;
  if (!cfg.enabled || !cfg.endpoint) return null;

  const sessionId = normalizeOffloadSessionId(params.sessionKey);
  const state = getState(sessionId, cfg.maxSessions);
  state.turn += 1;

  try {
    ingestToolPairs(cfg, sessionId, params.messages, state, params.userPrompt ?? null);
  } catch (err) {
    console.warn(`${TAG} ingest error: ${err instanceof Error ? err.message : String(err)}`);
  }

  const before = estimateTokens(params.messages) + estimateTokens(params.systemPrompt ?? "");
  if (before < cfg.triggerTokens) return null;
  if (state.turn - state.lastCompactTurn < cfg.cooldownTurns) return null;

  if (cfg.dryRun) {
    console.log(
      `${TAG} dry-run session=${sessionId} turn=${state.turn} tokens≈${before} >= ${cfg.triggerTokens}（未修改请求）`,
    );
    return {
      messages: null,
      beforeTokens: before,
      afterTokens: before,
      savedTokens: 0,
      level: cfg.level,
      dryRun: true,
    };
  }

  const { ratio, contextWindow, totalTokens } = buildCompactParams(before, cfg.level, cfg.contextWindow);
  const started = Date.now();
  try {
    const resp = await fetch(`${cfg.endpoint.replace(/\/$/, "")}/v2/offload/compact`, {
      method: "POST",
      headers: authHeaders(cfg),
      body: JSON.stringify({
        session_id: sessionId,
        messages: params.messages,
        ratio,
        context_window: contextWindow,
        total_tokens: totalTokens,
      }),
      signal: AbortSignal.timeout(cfg.timeoutMs),
    });
    if (!resp.ok) {
      console.warn(`${TAG} compact HTTP ${resp.status} session=${sessionId}`);
      return null;
    }
    const envelope = (await resp.json()) as {
      code?: number;
      data?: { messages?: unknown[]; report?: Record<string, unknown> };
    };
    const compacted = envelope?.data?.messages;
    if (!Array.isArray(compacted) || compacted.length === 0) return null;

    const after = estimateTokens(compacted) + estimateTokens(params.systemPrompt ?? "");
    if (after >= before) {
      console.log(
        `${TAG} compact 无收益（${before} → ${after}），保持原请求 session=${sessionId}`,
      );
      return null;
    }

    state.lastCompactTurn = state.turn;
    state.compactions += 1;
    const report = envelope?.data?.report ?? {};
    console.log(
      `${TAG} compact ok session=${sessionId} turn=${state.turn} level=${cfg.level} ` +
        `tokens≈${before}→${after} (省 ${((1 - after / before) * 100).toFixed(1)}%) ` +
        `report=${JSON.stringify(report)} took=${Date.now() - started}ms`,
    );
    return {
      messages: compacted,
      beforeTokens: before,
      afterTokens: after,
      savedTokens: before - after,
      level: cfg.level,
      dryRun: false,
      report,
    };
  } catch (err) {
    console.warn(
      `${TAG} compact failed session=${sessionId}: ${err instanceof Error ? err.message : String(err)}`,
    );
    return null;
  }
}

/** helper：从 AgentContext 里取物化后的 session 键（与代理其他地方一致）。 */
export function offloadSessionKey(ctx: AgentContext | null | undefined): string | null {
  if (!ctx) return null;
  const metadata = ctx.metadata as unknown as Record<string, unknown> | undefined;
  const sessionKey = metadata?.sessionKey;
  if (typeof sessionKey === "string" && sessionKey.length > 0) return sessionKey;
  const custom = (metadata?.custom ?? {}) as Record<string, unknown>;
  const session = (custom.session ?? {}) as Record<string, unknown>;
  const id = session.session_id ?? session.sessionId;
  return typeof id === "string" && id.length > 0 ? id : null;
}

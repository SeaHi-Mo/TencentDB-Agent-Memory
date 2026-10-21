/**
 * CodeBuddy Session Init — LastUser text extractor.
 *
 * 曾经这个文件里有 `stripInitArtifacts` 用来在 session_init 完成后剥离
 * 假表单对话（避免 LLM 看到 form 交互）。**该功能已删除**——现在永远保留
 * 用户的所有真实对话（含 session_init form 交互），不做任何删除。
 *
 * 目前只剩一个 export: `getLastUserMessageText`，用于在 session_init
 * state machine 里读最后一条 user / tool 消息的文本以解析用户选择。
 *
 * ── CodeBuddy ask_followup_question 回写格式(openai 分支) ──
 *
 * 用户点击表单后，CodeBuddy 下一条请求中问答所在的消息结构：
 *
 *   [N-2] role=assistant  tool_calls=[{id:"call_session_init_...", function:{name:"ask_followup_question"}}]
 *   [N-1] role=tool       tool_call_id=call_session_init_...  content=<multi_question_result JSON>
 *   [N]   role=user       content=<additional_data> 或其他普通 user 消息
 *
 * multi_question_result JSON（实际抓包格式）：
 *   空壳中间态（表单刚展示，用户还没点）：
 *     {"status":"success","success":true,"result":{"type":"multi_question_result",
 *      "questions":[{"id":"team","options":[...],"multiSelect":false}],
 *      "answers":{},
 *      "message":"Questions displayed. User response will be in <que"}}
 *
 *   真实答案（用户点击后）：
 *     {"status":"success","success":true,"result":{"type":"multi_question_result",
 *      "questions":[{"id":"team","answer":"Team名 (id尾8位)",...}],
 *      "answers":{"team":"Team名 (id尾8位)"}}}
 *
 * ── dsh v0.2+ 回写格式(anthropic 分支) ──
 *
 * dsh v0.2 换 anthropic /v1/messages 协议后,tool_result 载体从 openai 的
 *   `role: "tool" + tool_call_id + content: <JSON>`
 * 变成 anthropic 的
 *   `role: "user" + content: [{type:"tool_result", tool_use_id, content}]`
 *
 * getMessageText 必须能扫出 tool_result 块的内容(和 CC 的
 * claude-code/cleaner.ts:66-74 完全对称)。
 */

import { containsFormTitle } from "./form.js";

interface RawMessage {
  role?: string;
  content?: unknown;
  tool_calls?: unknown;
  [key: string]: unknown;
}

interface AnthropicBlock {
  type?: unknown;
  text?: unknown;
  /**
   * Anthropic `tool_result` 块的内容载体：string 或 blocks 数组。
   * Messages 协议下用户的表单回答走这里（role=user + tool_result），
   * 不是 OpenAI 的 role=tool + tool_call_id。
   */
  content?: unknown;
  /** Anthropic `tool_result` 指向的 tool_use id（对应 OpenAI 的 tool_call_id）。 */
  tool_use_id?: unknown;
}

// ── Public API ─────────────────────────────────────────────────────────────────

/**
 * Get text from last user or tool message containing form answer data.
 *
 * 载体两种(与协议相关):
 *   1. openai(CB / WB / opencode / dsh v0.1.x): `role: "tool"` 消息,
 *      `tool_call_id` 匹配 session-init 前缀 → content 就是 tool_result JSON。
 *   2. anthropic(CC / dsh v0.2+): `role: "user"` 消息,`content[]` 里的
 *      `type: "tool_result"` block,其 `tool_use_id` 匹配 session-init 前缀
 *      → block.content 才是 tool_result JSON。
 */
export function getLastUserMessageText(messages: RawMessage[]): string {
  // Sweep from end: the last message (user or tool) that relates to
  // session init is what we want. Tool messages are preferred because
  // CB writes "是，关联团队资产" etc. into tool_result content.
  let best = "";
  for (let i = messages.length - 1; i >= 0; i--) {
    const role = messages[i].role;
    if (role !== "user" && role !== "tool") continue;

    const text = getMessageText(messages[i]);
    if (!text) continue;

    // openai 分支:role=tool + top-level tool_call_id 匹配 session-init 前缀
    // 兼容四种前缀：CB 的 `call_session_init_`、WB 的 `call_wb_session_init_`
    // （workbuddy/form.ts 里 TOOLCALL_PREFIX = "call_wb_session_init_"）、
    // dsh 的 `call_dsh_session_init_`（dsh/form.ts TOOLCALL_PREFIX）、
    // opencode 的 `call_oc_session_init_`（opencode/form.ts TOOLCALL_PREFIX）。
    const tcid = (messages[i] as any).tool_call_id as string | undefined;
    if (role === "tool" && tcid && /call_(wb_|dsh_|oc_)?session_init_/.test(tcid)) {
      return text;
    }

    // Anthropic Messages 协议：回答装在 role=user 的 tool_result 块里，靠
    // tool_use_id（`toolu_…`）指回 form 的 tool_use，没有 tool_call_id 字段。
    if (role === "user" && hasSessionInitToolResult(messages[i])) {
      return text;
    }

    // dsh 原生 `ask_user_question`（本地 harness 执行）的回答，形状为
    //   {"answers":[{"id":"agent_select","selected":["dsh-cli开发 (agent-216adc4a)"]}]}
    // 两种协议下它的 tool id 都可能是上游 LLM 的普通 id（`call_00_…` /
    // `toolu_00_…`），不匹配上面的 session-init 前缀。若不在此认领，扫描会继续
    // 往前回退到上一阶段（team_select）那份带前缀的旧回答 —— extractAgentOnly
    // 于是永远拿 team 文本去 matchAgentInTeam，抽不到 agent → attemptCount 累到
    // maxRetries → bypass（status:initialized + bypassed:true）→ L0 一条都不写。
    // 返回原文即可：matchAgentInTeam 的 `text.includes(agent_name)` 能从 JSON
    // 里命中 agent 名。
    // 不限定 role：OpenAI 是 tool 消息，Anthropic 是 user + tool_result，两者
    // 都要认领（上面已把 role 收敛为 user / tool）。
    if (
      /"id"\s*:\s*"(asset_confirm|team_select|agent_select|task_select)"/.test(text)
    ) {
      return text;
    }

    // User messages with form markers have highest priority for old format
    if (role === "user" && (text.includes("<question_answer") || containsFormTitle(text))) {
      return text;
    }

    // Remember the last user/tool text as fallback
    if (!best && role === "user") {
      best = text;
    }
  }
  return best;
}

function getMessageText(msg: RawMessage): string {
  const content = msg.content;
  if (typeof content === "string") return content;
  if (Array.isArray(content)) {
    const parts: string[] = [];
    for (const raw of content as AnthropicBlock[]) {
      const type = raw.type;
      if (type === "text" && typeof raw.text === "string") {
        parts.push(raw.text);
      } else if (raw.type === "tool_result") {
        // Anthropic Messages 协议下回答装在 tool_result 块里。不提取就等于
        // 把用户的选择整条丢掉：扫描会继续往前回退到上一阶段的旧答案 →
        // extractAgentOnly 拿 team 文本去 matchAgentInTeam 永远抽不到 agent →
        // attemptCount 累到 maxRetries → bypass，L0 一条都不写。
        // （与 1a66bab 修的 OpenAI 侧同因异形。）
        parts.push(toolResultText(raw.content));
      }
    }
    return parts.join("\n");
  }
  return JSON.stringify(content ?? "");
}

/**
 * Anthropic `tool_result.content` 允许是 string，也允许是 blocks 数组
 * （通常一个 text block）。两种情况都要能取出文本。
 */
function toolResultText(content: unknown): string {
  if (typeof content === "string") return content;
  if (Array.isArray(content)) {
    const parts: string[] = [];
    for (const raw of content as AnthropicBlock[]) {
      if (raw.type === "text" && typeof raw.text === "string") {
        parts.push(raw.text);
      }
    }
    return parts.join("\n");
  }
  if (content == null) return "";
  return JSON.stringify(content);
}

/**
 * true = 这条消息里带一个指向 session-init form 的 Anthropic tool_result
 * （`toolu_dsh_session_init_…` / `toolu_session_init_…` / `toolu_wb_…` / `toolu_oc_…`）。
 */
function hasSessionInitToolResult(msg: RawMessage): boolean {
  const content = msg.content;
  if (!Array.isArray(content)) return false;
  return (content as AnthropicBlock[]).some(
    (raw) =>
      raw.type === "tool_result"
      && typeof raw.tool_use_id === "string"
      && /toolu_(wb_|dsh_|oc_)?session_init_/.test(raw.tool_use_id),
  );
}

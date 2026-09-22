# TDAI 全局镜像本地部署

全局三件套镜像的本地拉起脚本 —— `memory-core` + `memory-hub` + `proxy`，可各自独立运行，也能一条命令全部启动。

## 组件与端口

| 组件 | 容器名 | 镜像（Docker Hub 公开） | 宿主机端口 | 用途 |
|---|---|---|---|---|
| **memory-core** | `tdai-memory-core` | [`agentmemory/memory-core`](https://hub.docker.com/r/agentmemory/memory-core) | `8420` | 内核 gateway，记忆读写、鉴权、skill/RAG 数据面 |
| **memory-hub**  | `tdai-memory-hub`  | [`agentmemory/memory-hub`](https://hub.docker.com/r/agentmemory/memory-hub)   | `8125` / `8424` | 管理面板 (Panel) + 知识服务 (Knowledge) 合并镜像 |
| **proxy**       | `tdai-proxy`       | [`agentmemory/memory-proxy`](https://hub.docker.com/r/agentmemory/memory-proxy) | `8096` | LLM 请求转发代理，coding agent 的 API 入口 |

> 三个镜像都发布在 Docker Hub 的 [`agentmemory`](https://hub.docker.com/u/agentmemory) 命名空间下，
> 多架构（`linux/amd64` + `linux/arm64`），公开可拉、无需登录。想固定版本时把 `.env` 里的 tag 从
> `:latest` 换成具体版本即可，例如 `:1.0.0-beta.1`。
>
> 腾讯内部同事也可以覆盖到内网私仓 `mirrors.tencent.com/memory-team-control/` —— 见 `.env.example` 里
> 注释掉的备选块。

## 环境要求

- macOS / Linux
- Docker（Docker Desktop / colima / OrbStack 任一）
- `bash` 4+（macOS 自带 3.2 也能跑）

## 快速开始

```bash
cd TencentDB-Agent-Memory/deploy/global-images

# 一条命令：自动复制 .env → 交互式填 LLM → 自动校验通路 → 拉起三件套
./start-all.sh
```

`start-all.sh` 现在是**交互式**的，运行时会：

1. `.env` 不存在时，自动从 `.env.example` 复制一份（无需手动 `cp`）
2. 引导你填写两组 LLM（**回车 = 保留当前默认值**）：
   - `memory 组`：`BASE_URL` / `API_KEY` / `MODEL`（协议默认 `openai`）
   - `proxy 组`：先问「是否复用 memory 组配置」，复用则跳过
3. 填完**立即检查 LLM 通路是否通**，不通会提示重新输入，直到通过
4. 把填写值**写回 `.env`** 持久化（下次启动默认复用）
5. 通过后一键拉起三件套

> 想跳过交互、直接读 `.env` 也可以：手动 `cp .env.example .env` 并填好 LLM 后，
> 运行 `./start-all.sh` 一路回车确认即可（默认值就是 `.env` 里的值）。

### MongoDB 存储后端（试验特性，可选）

默认存储仍是 **sqlite**（零依赖，数据落容器卷）。MongoDB 数据面是**试验特性**，
默认关闭，不建议作为生产默认后端。开启后走 L0/L1/profile/skill 文档 + mongot
原生 BM25 检索，元数据默认同步落 Mongo：

```bash
./start-all-mongo.sh    # 与 start-all.sh 流程完全一致；写入 MEMORY_CORE_STORE_MODE=mongodb 到 .env
```

- 脚本会把 `MEMORY_CORE_STORE_MODE=mongodb` 写入 `.env`，此后 `./start-all.sh`
  也会保持 MongoDB，不会静默回退到 sqlite。要回 sqlite：注释掉该行或改为
  `sqlite`，再跑 `./start-all.sh`；
- 未设 `MONGODB_ENDPOINT` 时，脚本会自动起一个本地 `mongodb-atlas-local` 容器
  （mongod + mongot 一体，**不是**云上 Atlas；数据卷 `mongo-local-*` 持久化，
  `stop-all.sh --purge` 一并清理）；
- 想用外部 Mongo（云 Atlas / 自建带 mongot 的副本集），在 `.env` 填
  `MONGODB_ENDPOINT` 即可；
- **切换存储后端不会迁移已有数据。** sqlite 在 `MEMORY_CORE_VOLUME` 卷，mongo
  在 `mongo-local-*` 卷（或外部实例），切换后原数据仍留在原后端。当前版本需
  自行备份并手工迁移；后续版本将提供官方迁移工具。L2/L3 文件两种模式都在
  `MEMORY_CORE_VOLUME` 卷。

### 干跑校验（可选）

`verify.sh` 仍可单独使用，只检查环境不启动容器：

```bash
./verify.sh              # 默认全检（含 LLM 通路预检）
./verify.sh --skip-llm   # 跳过 LLM 检查（离线环境）
```

## LLM 通路预检

`verify.sh` 默认会预检两组 LLM 通路（`--skip-llm` 关掉）：

- **OpenAI 兼容协议**：`GET {base}/models`，只验证 API key + URL，**不消耗任何 token**
- **Anthropic 协议**：`POST {base}/v1/messages` 发 `max_tokens=1` 的最小消息，消耗 ≤ 10 token
- **memory 组** 与 **proxy 组** 独立验；若两组配置完全相同，自动跳过重复检查
- **容器已运行时**，额外从容器内 exec 一次 curl，验证"容器 → LLM"的网络可达性（一些企业代理/DNS 隔离环境下宿主机可达但容器不可达）

失败例子：

```
[error] memory 组 API key 无效（HTTP 401）：https://api.deepseek.com/v1/models
{"error":{"message":"Authentication Fails, Your api key: ****abcd is invalid",...}}
```

—— API key 错、URL 错、模型名错都会在启动前拦下，不会等到 wiki ingest / chat 时才 401。

启动完成后：

- Panel UI：<http://localhost:8125/>
- Knowledge API：<http://localhost:8424/v3/>
- Knowledge Swagger：<http://localhost:8424/docs>
- Memory Gateway：<http://localhost:8420/>
- Proxy：<http://localhost:8096/>

## 两组独立参数

**这是脚本设计的核心** —— memory 组和 proxy 组的 LLM 完全独立，可以指向不同供应商 / 不同模型。

### memory 组（memory-core + memory-hub 使用）

内核记忆 embed/summarize、knowledge 的 wiki ingest / 总结走这组配置。

| 变量 | 说明 | 示例 |
|---|---|---|
| `MEMORY_LLM_BASE_URL` | OpenAI 兼容 base URL | `https://api.deepseek.com/v1` |
| `MEMORY_LLM_API_KEY` | 上述端点的 API Key | `sk-xxxxxxxx` |
| `MEMORY_LLM_MODEL` | 模型 ID | `deepseek-chat` |
| `MEMORY_LLM_PROTOCOL` | `openai` 或 `anthropic`，默认 `openai` | `openai` |

### proxy 组（proxy 使用）

proxy 接到用户请求后转发到这组端点。

| 变量 | 说明 | 示例 |
|---|---|---|
| `PROXY_UPSTREAM_URL` | 转发目标 base URL | `https://api.deepseek.com/v1` |
| `PROXY_UPSTREAM_API_KEY` | 转发用 API Key | `sk-xxxxxxxx` |
| `PROXY_UPSTREAM_MODEL` | 面向用户的模型 ID | `deepseek-chat` |

> 两组可以填相同值（都指向同一个 LLM），也可以完全不同：例如 memory 组用便宜模型做 embedding，proxy 组用强模型做主对话。

参数缺失时脚本会**在启动前一次性列出所有缺失项**并 `exit 1`，不会跑到一半才失败。

## 记忆提示词模式（chat / code）

memory-core 通过 `MEMORY_PROMPT_MODE` 切换 L1/L2/L3 pipeline 的提示词族：

| 模式 | `.env` 值 | 抽取内容 | L3 产物 | 适用场景 |
|---|---|---|---|---|
| **code**（默认） | `MEMORY_PROMPT_MODE=code` | 项目事实 / 任务 / 决策 / SOP / 禁忌 | Team Operating Doctrine | coding agent、团队协作、工程项目 |
| chat | `MEMORY_PROMPT_MODE=chat` | persona / episodic / instruction | persona.md（个人画像） | 个人助手、闲聊、教学 |

> **注意**：`code` 模式下纯闲聊可能抽出 0 条记忆（LLM 认为没有可沉淀的工程内容）。如果 L1 一直没产出，先检查 `MEMORY_PROMPT_MODE` 是否与实际对话场景匹配。

## 内部凭据（生产环境必看）

三件套之间用 `MEMORY_CORE_GATEWAY_API_KEY` 互相认证，首次启动还会通过
`init-admin` 建一个 `system_admin` 账户。为了**零配置本地体验**，脚本默认值是：

| 变量 | 默认值 | 用途 |
|---|---|---|
| `MEMORY_CORE_GATEWAY_API_KEY` | `local` | memory-hub / proxy → memory-core 的 Bearer |
| `MEMORY_CORE_ADMIN_USERNAME` | `admin` | 初始化的 system_admin 用户名 |
| `MEMORY_CORE_ADMIN_USER_KEY` | `admin` | 该 admin 用户的登录 key |

> 这三个默认值只适合个人本地跑通流程。**生产/联调/公网暴露前必须替换成随机长串**，
> 否则任何拿到端口的人都能拿到 system_admin 权限。
>
> 在 `.env` 里取消对应三行的注释并覆盖即可（`_lib.sh` 会 `require_vars`
> 校验其他必填项，但这三个变量因为有默认兜底，脚本会在启动时打 `[warn]` 提醒你换）。

## 独立使用每个组件

三个脚本可以单独执行，方便调试或只需要部分能力时：

```bash
./start-memory-core.sh       # 只跑内核 gateway（8420）
./start-memory-hub.sh   # 只跑面板 + 知识（8125 + 8424）；需要 MEMORY_LLM_* 参数
./start-proxy.sh        # 只跑 proxy（8096）；需要 PROXY_UPSTREAM_* 参数
```

依赖关系：

- **memory-core**：无外部依赖，可以独立起
- **memory-hub**：能独立启动（LLM_MODE=custom 直连 LLM），但内部 knowledge 调 memory-core 做 RAG 时会失败 → 建议 memory-core 先起
- **proxy**：能独立启动（cost-guard 不可用时自动降级 passthrough，直接转发），但 auth / tdai memory / skill 注入需要 memory-core 才有效

任意组件缺失时脚本会 `warn` 提醒但不阻塞。

## 数据持久化

- `tdai-memory-core-data`（named volume）→ memory-core 的 SQLite / 记忆数据
- `tdai-panel-data`（named volume）→ memory-hub 里 knowledge 的 SQLite / git clone / wiki 文件

`docker volume rm` 之前数据一直保留。改名可在 `.env` 里改 `MEMORY_CORE_VOLUME` / `PANEL_VOLUME`。

## 停止 / 清理

```bash
./stop-all.sh            # 停容器，保留 volume（下次启动数据还在）
./stop-all.sh --purge    # 停容器 + 删 volume + 删网络（彻底清理）
```

## 查看日志

```bash
docker logs -f tdai-memory-core
docker logs -f tdai-memory-hub
docker logs -f tdai-proxy
```

memory-hub 内部有两个进程（panel + knowledge），日志分别在容器内 `/data/knowledge/logs/panel.log` 和 `.../knowledge.log`。

## 端口冲突

如果 `8125` / `8420` / `8424` / `8096` 与本地已有服务冲突，直接在 `.env` 改：

```bash
MEMORY_CORE_PORT=18420
PANEL_PORT=18125
KNOWLEDGE_PORT=18424
PROXY_PORT=18096
# knowledge 对外可达地址要跟着 KNOWLEDGE_PORT 走
KNOWLEDGE_PUBLIC_BASE_URL=http://host.docker.internal:18424/v3
```

## 使用 proxy 作为 coding agent 的 API base

以 Claude Code 为例：

```bash
export ANTHROPIC_BASE_URL=http://localhost:8096
export ANTHROPIC_API_KEY=any-string-if-auth-disabled
# 使用 openai 协议的客户端类似：OPENAI_BASE_URL=http://localhost:8096/v1
```

Panel UI "客户端接入地址" 卡片会自动拼上宿主机的 LAN IP + `PROXY_PORT`（例如
`http://192.168.1.100:8096/codebuddy/default`），别人的电脑复制过去就能直接连过来。
由 `MEMORY_HUB_PROXY_PUBLIC_URL`（未设时脚本用 `hostname -I` / macOS `ipconfig getifaddr en0`
自动探测，探不到才回落 `localhost`）注入到 memory-hub 里的 `metadata-instances.json.proxy_endpoint`。
Panel 后端 → Kernel 的转发不受此变量影响（始终走 `REMOTE_INSTANCE_URL` → memory-core:8420）。
自动探测的地址不对时（多网卡 / 公网域名 / 反代前置），在 `.env` 显式设
`MEMORY_HUB_PROXY_PUBLIC_URL=http://<真值>:8096`。想让 UI 卡片走老行为（回落到
gateway_endpoint）就把 `MEMORY_HUB_PROXY_PUBLIC_URL` 显式设为空字符串。

`proxy` 默认关闭 `auth` / `sessionInit` / `costGuard`（这些依赖内部服务），只做纯转发 + `tdai-memory` 上下文注入（injector 名称，非容器名）。要开启完整流水线，需要另行配置 —— 参见 `context_proxy/config.example.yaml`。

## 降本与多租户 key

默认部署下所有接入的 agent 共用一把上游 key（`PROXY_UPSTREAM_API_KEY`）。隔离粒度不够时，
按下面的顺序逐层打开。三层解析优先级（高 → 低）：

1. cost-guard 路由自带凭据（需私有扩展包）
2. `upstream.agents[<agent>]` —— 客户端族群级，proxy 的 YAML 配置
3. 实例级上游配置（memory-core 的 `meta_instance_upstream_config`）—— 租户 × 族群 × 用途
4. `upstream.url` + `upstream.apiKey` —— 全局兜底

> 客户端那把 `sk-mem-...` 本来就是按用户隔离的（`auth/verify` 换 `user_id`）；
> 这里说的"共用一把 key"指的是**转发给 provider 的那把上游 key**。

### 1. 按客户端族群分 key（改 .env 即可，零代码）

```bash
# 多条用分号分隔，整行用引号包住；省略 |apiKey 的条目 = 透传客户端自己的 key
PROXY_UPSTREAM_AGENTS="claude-code=https://api.deepseek.com/v1|sk-aaa"
```

注意：某族群一旦出现在这张表里，全局 `PROXY_UPSTREAM_API_KEY` 对它就不再兜底。
把 `PROXY_UPSTREAM_API_KEY` 留空则全局走 BYOK（客户端自带 provider key）。

### 2. 按租户 / 用途分 key（`set-instance-upstream.sh`）

写入 memory-core 的实例级上游配置，proxy 每 5 分钟自动拉取一次（无需重启 proxy）。

| 命令 | 作用 |
|---|---|
| `./set-instance-upstream.sh list --space <space>` | 列出该实例的所有覆盖行（key 已脱敏） |
| `./set-instance-upstream.sh set --space <space> --agent <agent> --type <conversation\|extraction> --mode <official\|custom_unified\|custom_passthrough> --base-url <url> --api-key <key> [--model-id <model>]` | 写入/覆盖一行 |
| `./set-instance-upstream.sh split --space <space> --conv-url <u> --conv-key <k> --extr-url <u> --extr-key <k>` | 一次配好"对话用贵模型 + 后台抽取用便宜模型" |
| `./set-instance-upstream.sh reset --space <space> --type <t>` | 恢复 official（conversation）/ 删除该行（extraction） |

要点：

- `--space` 就是请求路径里的 spaceId（如 `/claude-code/<space>`），同时也是 `x-tdai-service-id`；
- `--agent` 填 URL 路径首段（claude-code / codebuddy / dsh / codex / opencode / pi），
  填 `default` 表示该实例的兜底行（精确匹配失败时回落）；
- `extraction` **不支持** `custom_passthrough`（Core 侧会拒绝）：后台抽取必须走服务端 key；
- 走 custom upstream 时，请求会跳过模型别名改写与 credit 上报；
- api_key 目前**明文**存在 memory-core 的元数据库里，请确保该库的访问权限可控；
- 鉴权用 `.admin-key`（system admin）；`--core-url` / `--admin-key` / `--dry-run` 可覆盖默认行为。

### 3. 降本旋钮与预期效果

proxy 侧（`.env`）：

| 变量 | 默认 | 省下的量 |
|---|---|---|
| `PROXY_INJECTORS` 去掉 `knowledge` | 全开 | 每请求约 1k - 1.8k tokens |
| `PROXY_INJECTORS` 去掉 `skill` | 全开 | 每请求约 1.8k - 3.7k tokens |
| `PROXY_INJECTORS` 留空 | 全开 | 关闭全部注入，省约 4k - 10k tokens/请求 |
| `PROXY_EXTRACTION_ENABLED=0` | 开 | 后台回流/归档归零 |

memory 侧（`.env`，只改频率不改功能）：

| 变量 | 默认 | 调到 | 预期效果 |
|---|---|---|---|
| `MEMORY_L1_EVERY_N` | 5 | 20 | L1 抽取调用次数约 -75% |
| `MEMORY_ENABLE_WARMUP` | 1 | 0 | 长会话更快进入低频（前期调用变少） |
| `MEMORY_L2_MAX_INTERVAL_SECONDS` | 3600 | 21600 | L2 场景重建约 -83% |
| `MEMORY_PERSONA_TRIGGER_EVERY_N` | 50 | 200 | L3 persona 重建约 -75% |
| `MEMORY_SKILL_TOP_K` | 20 | 6 | `<available_skills>` 注入量约 -70% |
| `MEMORY_LLM_MODEL` | - | 便宜模型 | **单项收益最大**：后台管线全部走它 |

最省事的组合：`MEMORY_LLM_MODEL` 指向便宜模型 + `MEMORY_L1_EVERY_N=20` +
`PROXY_INJECTORS=skill,tdai-memory`。想量化真实用量请先打开用量统计
（`CLICKHOUSE_ENABLED=1`，需要一个 ClickHouse 实例），否则没有任何数据支撑判断。

## 常见问题

**Q: `./start-all.sh` 卡在 wait_healthy？**
镜像可能还在拉取。用 `docker pull <IMAGE>` 手动预拉一次再跑脚本。

**Q: memory-hub 起来但 Panel 打不开？**

检查 `.env` 里 `KNOWLEDGE_PUBLIC_BASE_URL` 是不是含 `/v3` —— 缺 `/v3` panel 会报错。

**Q: proxy 转发返回 401？**
`PROXY_UPSTREAM_API_KEY` 无效或 `PROXY_UPSTREAM_URL` 不匹配。用 `docker logs tdai-proxy` 看错误。

**Q: 如何在容器外访问宿主机上其它服务（Ollama、Langfuse 等）？**
脚本已默认 `--add-host=host.docker.internal:host-gateway`。容器内用 `http://host.docker.internal:<port>` 即可。

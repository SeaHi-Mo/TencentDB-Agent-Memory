---
name: deploy-port-preflight
description: 修复/排查本地 Docker 部署 start-all.sh 在「端口预检」阶段中止的问题——典型报错 `[error] 端口 8125 (PANEL_PORT) 已被占用` → `die "存在端口冲突"`，容器一个都没起。核心是分清 PANEL_PORT（容器内端口）与 PANEL_HOST_PORT（宿主机发布端口），以及 wsl-relay 合法占用 8125 造成的假冲突、lsof 假空闲。当 start-all.sh 报端口冲突、或提示某端口被占用但 docker ps 里没有对应容器时使用。
triggers:
  - start-all 端口冲突
  - 端口预检
  - 端口被占用
  - 8125 被占用
  - start-all 起不来
  - 端口冲突
---

# 本地部署端口预检（start-all.sh 端口冲突）

对象是 `deploy/global-images/` 这套 shell 部署脚本（`.env` + `start-*.sh` / `stop-all.sh` / `verify.sh` / `_lib.sh`），
不是 docker-compose。

## 症状

```
$ ./start-all.sh
[error] 端口 8125 (PANEL_PORT) 已被占用，请释放该端口或在 .env 改端口。
[error] 存在端口冲突，请先释放端口后重试。
```

**容器一个都没起**（`docker ps` 里还是旧栈或空的）。这一步死在 `check_ports`，发生在任何 `docker run` 之前。

## 5 分钟定位

1. 谁占着这个端口、是不是自己人：

   ```bash
   ss -ltnp | grep -E ':8125|:18125'
   pgrep -af wsl-relay            # 命中的话就是 WSL 原生转发
   docker ps --format '{{.Names}}\t{{.Ports}}'
   ```

2. 分清两个端口（本仓库最容易搞混的一处）：

   | 变量 | 含义 | 本例取值 |
   |---|---|---|
   | `PANEL_PORT` | **容器内** Panel 监听口 | 8125 |
   | `PANEL_HOST_PORT` | Docker **发布到宿主机**的口 | 18125 |

   `start-memory-hub.sh` 发布的是 `-p "${PANEL_HOST_PORT:-${PANEL_PORT}}:8125"`。
   所以设了 `PANEL_HOST_PORT` 时，**8125 上就不该有 Docker 的监听**——监听它的应该是
   `wsl-relay/wsl-relay.py`（WSL2 mirrored 模式下 Windows 访问不到 Docker 发布口，
   于是把 18125 挪走、8125 交给 WSL 原生进程转发）。
   该目录是**可选的本地绕法，默认不纳入版本管理**（见其 `README.md`：装到仓库外后即可删除）；
   没有它时把 `PANEL_HOST_PORT` 从 `.env` 删掉，恢复成直接发布 `PANEL_PORT` 的上游行为。

3. 结论判据：**8125 被 wsl-relay 占着是预期状态，不是端口冲突**；真正需要空闲的是 18125。

## 正确口径（`_lib.sh`）

`check_ports` 必须满足两条规则：

1. **硬冲突检查以「宿主机实际发布端口」为准**：Panel 用 `${PANEL_HOST_PORT:-${PANEL_PORT}}`，
   其余为 `MEMORY_CORE_PORT / KNOWLEDGE_PORT / PROXY_PORT`。已由 tdai 旧容器占用的端口继续跳过
   （启动时会被重建，见 `tdai_self_ports`）。
2. **`PANEL_HOST_PORT` 与 `PANEL_PORT` 不同时，单独看 PANEL_PORT**：被 wsl-relay 占用 → `ok`；
   没人监听 → `warn`（Windows 侧访问不到 Panel）；被别的进程占 → `warn`。**三种都不 `die`**。

没有设 `PANEL_HOST_PORT`（上游默认行为）时，第 2 条整段跳过，行为与上游完全一致。

配套三个 helper（都在 `_lib.sh`）：

```bash
# 端口是否处于 LISTEN。lsof、ss 各试一次 —— 只信 lsof 会得到「假空闲」：
# lsof 看不到别的 PID/网络命名空间、或被 root 持有的 socket 时会返回空。
port_in_use() {
  local port="$1"
  if command -v lsof >/dev/null 2>&1 \
     && lsof -iTCP:"$port" -sTCP:LISTEN >/dev/null 2>&1; then return 0; fi
  if command -v ss >/dev/null 2>&1 \
     && ss -ltn 2>/dev/null | awk '{print $4}' | grep -qE ":${port}$"; then return 0; fi
  return 1
}

# 监听该端口的 PID（lsof -t，取不到再用 ss -ltnp 抠 pid=）
port_listen_pids() {
  local port="$1" pids=""
  if command -v lsof >/dev/null 2>&1; then
    pids="$(lsof -tiTCP:"$port" -sTCP:LISTEN 2>/dev/null | tr '\n' ' ' || true)"
  fi
  if [[ -z "${pids// /}" ]] && command -v ss >/dev/null 2>&1; then
    pids="$(ss -ltnp 2>/dev/null | awk -v p=":$port" '$4 ~ (p "$")' \
      | grep -oE 'pid=[0-9]+' | cut -d= -f2 | sort -u | tr '\n' ' ' || true)"
  fi
  printf '%s' "$pids"
}

# 监听者是不是 wsl-relay.py；读 /proc/<pid>/cmdline 匹配 *wsl-relay*
# 判定不了（读不到 /proc）就返回非 0 → 调用方只 warn，绝不拦
port_owned_by_relay() {
  local port="$1" pid cmdline
  for pid in $(port_listen_pids "$port"); do
    cmdline="$(tr '\0' ' ' < "/proc/$pid/cmdline" 2>/dev/null || true)"
    if [[ "$cmdline" == *wsl-relay* ]]; then
      return 0
    fi
  done
  return 1
}
```

> 原实现是 `if lsof ...; elif ss ...`：lsof 存在但看不见 owner 时**直接走不到 ss**，
> 于是把被占的端口报成空闲。改成两个都试。

## `verify.sh` §5

同源问题，口径要一致：同样按宿主发布端口遍历，并加上上面第 2 条的三分支提示（仅 `warn`/`ok`，
verify 本来就是干跑检查，不拦人）。

## 验证（不启容器，安全）

```bash
cd deploy/global-images
bash -n _lib.sh && bash -n verify.sh          # 语法

# 预检本身（容器在跑时，自己容器的端口会被正确跳过）
bash -c 'source ./_lib.sh; load_env; check_ports; echo rc=$?'

# 造一个「假 wsl-relay」验证识别分支：起个同名监听再断言 port_owned_by_relay
```

改完跑一次 `./start-all.sh`，预检应打印
`[ok] 端口 8125 由 wsl-relay 原生转发占用（预期）` 后继续往下起容器。

## Pitfalls

- **别把 relay 占用当冲突**，也别反过来据此判断 relay 坏了：`docker ps` 看不到 relay 是正常的，
  它是 WSL 原生进程，查 `pgrep -af wsl-relay` / `systemctl --user status wsl-relay`。
- **别用 `PANEL_PORT` 做宿主端口预检**：设了 `PANEL_HOST_PORT` 时这是「构造性错误」。
- **容器重建不需要重启 relay**：relay 是每个新连接现拨 `127.0.0.1:<PANEL_HOST_PORT>`，
  重建瞬间已建立的长连接断，新连接照通。反向：relay 没跑 → Windows `localhost:8125` 直接没人应答
  （预检会给「无人监听」提示），`systemctl --user start|restart wsl-relay`。
- 端口占用检查不要只看 `lsof`，也不要只看 `docker ps`——`docker-proxy` 由 root 持有，
  普通用户 `lsof` 常常看不到。
- `PANEL_PORT` 与 `PANEL_HOST_PORT` 混用的排查记录、以及 relay 的端口表，见
  `deploy/global-images/wsl-relay/README.md`。

## Related

- `agents/skills/setup-proxy/SKILL.md` —— 把 agent 客户端接到 Memory Proxy（配置侧，不是部署侧）。
- 部署拓扑、admin key、`40101 session not initialized`：本仓库 `deploy/global-images/README.md`。

# Tailcat agent skill (archived)

> **Status: ARCHIVED 2026-09-02** — Tailcat itself is immature, so the project is
> paused. This is a verbatim copy of the `tailcat` AI-agent skill that lived at
> `~/.agents/skills/tailcat/SKILL.md`. It is preserved here as R&D foundation so
> the operational knowledge is not lost. To resume, restore it to
> `~/.agents/skills/tailcat/SKILL.md` (or any agent skill dir) and rebuild/reinstall
> the `omarchy-tailcat` backend + `tailcat` CLI first.

---

---
name: tailcat
description: >
  管理本机的 Tailcat（"去 Tailscale 的 Tailscale"：点对点 WireGuard 直连、无控制面、
  无中心服务）。启动/停止/查看监听、分享与校验 tc… 地址、保存设备、身份管理、
  ping/打通隧道、在终端里收发文件、诊断与排障。触发词：tailcat、tailcat 监听/
  启动/关闭、用 tailcat 传文件/发文件/收文件、tc… token/地址、点对点连接、
  "帮我管理 tailcat"。
---

# Tailcat 管理

[Tailcat](https://github.com/tailscale/tailcat) 是 Tailscale 官方的去控制面方案：
两台机器各自生成密钥与"地址令牌（tc…）"，通过 WireGuard 数据面 + NAT 穿透
（DERP 中继）直接建立点对点隧道，不需要中心服务。**令牌即能力**：拿到 tc…
令牌的人就能连上你的机器，必须当作凭据对待。

本机有两个工具，都用 **argv 数组**调用、绝不拼 shell 字符串：

| 工具 | 用途 |
|---|---|
| `omarchy-tailcat` | 管理器后端（本项目 Go 二进制）。监听生命周期、配置、设备登记、诊断，每个子命令输出一个 JSON |
| `tailcat` | 上游 CLI。传文件（`recv`/`cp`）、SSH、端口转发等底层能力 |

## 安全红线（必须遵守）

1. **tc… 令牌 = 能力凭据**：绝不打印完整令牌到对话/日志；需要展示时截断
   （`tc…末4位`）。校验用 `validate`（本地解码，无网络）。
2. **密钥在 `~/.config/tailcat/keys/`（0600）**：永不读取/修改其内容；身份操作
   一律走 `omarchy-tailcat identities`。
3. **管理器配置在 `~/.config/omarchy-tailcat/`**（0700/0600）：用它的子命令改，
   不要手改文件。
4. 要把完整 tc… 地址分享给用户时，提醒这是敏感凭据，建议走即时通讯、别贴公共频道。

## 命令参考

`omarchy-tailcat`（stdout 一个 JSON；失败 exit 1 + `{"error":{kind,message,detail}}`）：

```sh
omarchy-tailcat version                          # 可用性 + 版本（minOK=false 说明过旧）
omarchy-tailcat status                           # backend + listener 快照（addr/运行状态）
omarchy-tailcat validate <tc…或DNS名>            # 本地解码校验令牌（无网络）
omarchy-tailcat serve status                     # 监听器状态
omarchy-tailcat serve start [服务...] [--key=名] # 无服务 = 转发本机全部端口；服务：端口号 | no-auth-ssh | files | exit-node
omarchy-tailcat serve stop
omarchy-tailcat serve restart [服务...] [--key=名]
omarchy-tailcat identities list                  # 保存的身份 + 虚拟 ephemeral 身份
omarchy-tailcat identities create <名> [--client] [--region=X]
omarchy-tailcat identities delete <名>
omarchy-tailcat identities pub                   # 当前客户端公钥（nodekey:...，用于 --allow 白名单）
omarchy-tailcat ping <目标> [--until-direct] [--timeout=D]
omarchy-tailcat devices list | add <名> <目标> | remove <id> | rename <id> <名> | touch <id>
omarchy-tailcat diagnostics                      # 脱敏的诊断快照 + 日志尾部
```

`tailcat`（默认无参 = 一次性 stdout 管道，只连一次就退出；传文件等用显式子命令）：

```sh
tailcat recv <目录>                              # 接收：起一个 write-only 投件箱，输出 tc… 地址
tailcat cp <本地文件> <tc…地址>:                 # 发送：经系统 scp 封装，终端里带进度
tailcat parse <tc…>                              # 解码令牌（等价 omarchy-tailcat validate）
tailcat ping <tc…>                               # 快速连通测试（stderr 行式结果）
```

## 常用工作流

### 1. 查看状态
```sh
omarchy-tailcat status
```
`listener.running == true` 表示正在监听；`addr` 是要分享的地址；`keyInUse` 为固定身份名或
`ephemeral`；`broad == true` 表示在转发全部端口（要注意提示）。

### 2. 启动 / 停止 / 重启监听
```sh
omarchy-tailcat serve start                     # 默认转发全部本地端口（最省事）
omarchy-tailcat serve start 8080 --key=work     # 只转发某端口 + 固定身份（地址稳定）
omarchy-tailcat serve stop
omarchy-tailcat serve restart 8080
```
用户说"开/关 tailcat"就用 `serve start`/`serve stop`；做完用 `serve status` 复核。

### 3. 分享地址
```sh
omarchy-tailcat status    # 取 listener.addr
```
按安全红线第 4 条提示用户私下分享。

### 4. 校验 / 解析目标
```sh
omarchy-tailcat validate <tc…或DNS名>
```

### 5. 连接 / 打通某台设备
```sh
omarchy-tailcat ping <tc…> --until-direct --timeout=30s
```
`ok:true` 且 `direct:true` = 直连；DERP 中继也能通。用户说"连上某设备"通常就是用
`--until-direct` 的 ping 打通隧道。

### 6. 保存设备（记住常用目标）
```sh
omarchy-tailcat devices list
omarchy-tailcat devices add "张三的笔记本" <tc…>
omarchy-tailcat devices rename <id> 新名
omarchy-tailcat devices remove <id>
```

### 7. 身份管理
```sh
omarchy-tailcat identities list
omarchy-tailcat identities create work --region=304    # 服务端身份（区域填常用 DERP）
omarchy-tailcat identities create peer --client        # 客户端身份（用于 --allow 白名单）
omarchy-tailcat identities delete work
```
注意：`--region=list` 是列区域模式、不会建身份；`create --client` 无 DERP 区域。
用固定身份启动监听能让地址保持稳定（`serve start 8080 --key=work`）。

### 8. 发送文件（终端）
1. 先让接收方启动接收：`tailcat recv ~/Downloads`（拿到它的 tc… 地址）。
2. 发送方发文件：`tailcat cp ./report.pdf <接收方地址>:`（进度由 scp 输出，失败看 stderr）。

### 9. 接收文件（终端）
```sh
tailcat recv ~/Downloads
```
等对端 `tailcat cp` 推送；投件箱只接受文件（write-only）。要主动收文件时先把该地址分享给发送方。

### 10. 诊断
```sh
omarchy-tailcat diagnostics
```
版本、监听状态、脱敏日志。ping 不通先 `validate` 目标，再 `serve status` 看本机是否在监听。

## 排障速查

- **validate 通过但 ping 不通**：令牌若嵌了 DERP 区域（"full address" 形态）且区域≠1 会
  路由错。服务端用默认短令牌（区域引用），客户端用 `tailcat parse` 复核。
- **`derp-N does not know about peer`**：常见于同一进程里跑两个 magicsock。服务器与客户端
  必须是两个独立进程（本工具每个子命令天然一个进程，符合）。
- **找不到 `omarchy-tailcat`**：在 `~/.local/bin/omarchy-tailcat`（quick-install 装的），或插件
  目录 `~/.config/omarchy/plugins/dev.omarchy.tailcat/bin/`。都没有就先在项目
  `backend/` 下 `go build -o ~/.local/bin/omarchy-tailcat ./cmd/omarchy-tailcat`。
- **`tailcat` 未安装**：`paru -S tailcat`（或 `tailcat-bin`），装完重启 shell/重开终端。
- **版本过旧**：`omarchy-tailcat version` 报 `minOK=false`，升级 `tailcat` 后再看。

## 参考
- 项目：`/home/max/tailcat-manager`（`docs/architecture.md`、`docs/file-transfer.md`）
- 上游源码分析：`docs/tailcat-analysis.md`；上游参考副本 `upstream-tailcat/`（勿改）

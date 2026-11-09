# wgmesh Hub 中转增量开发计划

日期：2026-11-09

状态：实现中；Unix Hub forwarding 已接入并通过本地 smoke，Windows Hub
forwarding 已接入，待 PowerShell/目标机检查；跨平台端到端验收未完成。

## 1. 与基础计划的关系

`01-wgmesh-base-development-plan.md` 保留基础脚本的命令合同、Node 加入、
Hub peer 登记、状态、卸载和跨平台 WireGuard 生命周期。

本计划只增加 Hub 的跨平台转发能力，不重做基础开发，也不改变现有命令：

```text
Node A → Hub → Node B
```

Node 不保存其他 Node 的公钥或 endpoint。Hub 仍由管理员在本机登记每个
Node，数据面只使用 Hub 的 `/32 AllowedIPs` peer。

## 2. 目标与角色范围

| 平台 | Hub | Node | 入口 |
| --- | --- | --- | --- |
| Linux | 支持 | 支持 | `wgmesh.sh` |
| macOS | 支持 | 支持 | `wgmesh.sh` |
| Windows | 支持 | 支持 | `wgmesh.ps1` |

三种平台的 Hub 都遵循同一网络模型：

- Hub 为每个 Node 保存独立的 `AllowedIPs = <NODE_IP>/32`；
- Node 只保存 Hub peer，并把 overlay 网段交给 Hub；
- Hub 开启本机 IPv4 转发，使 Node A 的 overlay 流量可以到达 Node B；
- Hub 只转发 `--overlay-cidr`，不转发默认路由或局域网网段。

## 3. 明确不做

- Node↔Node 直连 peer、full-mesh、peer 自动同步；
- LAN 路由、默认路由、full-tunnel、NAT 出口、原地址透明转发；
- 自动创建或接管 `iptables`、`nftables`、`pf` 或 Windows 防火墙规则；
- 常驻 relay 服务、SSH 远程操作、额外配置文件或新运行时；
- 新增 `node add-peer`、`node remove-peer` 或其他 CLI；
- 单独的 CLI runbook；命令示例继续维护在 `README.md`；
- 为三种平台和两种 transport 建立全量组合验收矩阵；
- 吞吐基准、抓包、故障注入、规则备份恢复和独立 `doctor` 命令。

Hub 所在机器的既有防火墙必须允许 WireGuard UDP 和 overlay 转发。脚本只
开启系统转发，不修改防火墙策略。脚本不在卸载时强制关闭 Linux/macOS 的
全局 forwarding，避免影响其他系统用途；Windows 只配置当前 WireGuard
接口，卸载时不接管其他接口设置。

## 4. 最小实现方式

### 4.1 公共 Hub 数据面

继续复用基础计划的配置生成逻辑：

```text
Hub peer:
  PublicKey = <NODE_PUBLIC_KEY>
  AllowedIPs = <NODE_IP>/32

Node peer:
  PublicKey = <HUB_PUBLIC_KEY>
  AllowedIPs = <OVERLAY_CIDR>
  Endpoint = <HUB_ENDPOINT>
  PersistentKeepalive = 25
```

`host add-node` 添加第二个 Node 时必须保留已有 peer。`host remove-node`
只移除 Hub 本机的 peer，不远程修改 Node。

### 4.2 平台转发接线

转发接线只使用系统已有能力，不引入新服务：

| Hub 平台 | 接线位置 | 目标动作 |
| --- | --- | --- |
| Linux | 现有 `wg-quick` Hub 配置的 `PostUp`，以及重复执行时的恢复路径 | `sysctl -w net.ipv4.ip_forward=1` |
| macOS | 现有 `wg-quick` Hub 配置的 `PostUp`，以及重复执行时的恢复路径 | `sysctl -w net.inet.ip.forwarding=1` |
| Windows | 现有 WireGuard Tunnel Service 启动/刷新完成后 | 使用 `Set-NetIPInterface -InterfaceAlias <WG_INTERFACE> -AddressFamily IPv4 -Forwarding Enabled -PolicyStore PersistentStore`，将该 WireGuard 接口的 IPv4 forwarding 写入持久策略；不创建额外服务 |

实现要求：

1. `host init` 在配置或服务启动前检查对应系统命令可用，并在启动后确认转发开关已生效。
2. 已存在的同参数 `host init` 走现有 `NOOP`/恢复路径，同时重新确认转发开关。
3. `host add-node` 刷新 Hub 配置后，不重复生成同一转发动作。
4. `node join`、Node 配置、Hub peer 状态格式和现有服务管理保持不变。
5. 转发命令失败时停止本次 Hub 初始化或刷新，并保留明确错误；不静默改用防火墙、
   NAT 或其他路由方案。
6. Windows 不支持持久策略或无法确认接口 forwarding 已启用时，Hub 初始化失败；
   不通过计划任务或额外服务补偿。

## 5. 修改路径

需要修改：

- `wgmesh/wgmesh.sh`
  - Hub 配置按平台加入唯一的 forwarding 接线；
  - Linux/macOS 初始化、恢复和 Hub peer 刷新时检查对应 `sysctl`；
  - 保持现有 Node/Hub 配置、状态和卸载行为。
- `wgmesh/wgmesh.ps1`
  - 增加 Windows Hub forwarding 设置与检查；
  - 在 Tunnel Service 首次安装、恢复和 peer 刷新后调用该设置；
  - 保持现有 Node/Hub 配置、状态和服务生命周期。
- `wgmesh/README.md`
  - 更新平台角色矩阵、转发前置条件和命令说明；
  - 删除“仅 Linux Hub”的旧描述。
- `wgmesh/tests/smoke.sh`
  - 只增加 Unix Hub forwarding 命令的最小 mock 断言；
  - 不把 mock 输出当成真实网络验收。

不修改：

- 基础命令参数和 `--network-name` 合同；
- Node 只保存 Hub peer 的模型；
- 现有状态目录和 WireGuard `.conf` 运行文件格式；
- 现有本机卸载语义；
- 不新增依赖、常驻服务、配置文件格式或独立 runbook。

## 6. 执行任务

### TASK-02A：跨平台 Hub forwarding 接线（实现中）

目标：在三种平台的现有 Hub 生命周期中接入系统 IPv4 转发。

步骤：

1. 在 `host init` 前检查平台所需的 `sysctl` 或 PowerShell NetTCPIP 命令。
2. Linux/macOS 将唯一的 `PostUp` 写入 Hub 配置；Windows 在 Tunnel Service
   启动或刷新后设置 WireGuard 接口 forwarding。
3. 让相同参数重复执行进入既有恢复路径，并再次确认转发状态。
4. 保持 `host add-node` 的 `/32` peer 生成和既有服务刷新逻辑。
5. 不保存或恢复用户系统的全局 forwarding 原值，不接管防火墙。

成功：

- Linux、macOS、Windows 都能完成 Hub 初始化并启用本机 overlay 转发；
- Hub 配置仍按每个 Node 写入独立 `/32`；
- Node 配置仍只有 Hub peer；
- 缺少系统命令或转发不可写时在写入/刷新完成前报告失败。

失败出口：

- 仅当前平台的 Hub relay 接线失败；不改变其他平台和基础 Node 功能；
- 记录缺失命令、权限或系统返回值，等待平台环境处理后重试；
- Windows 若系统不保留接口 forwarding，提示管理员处理系统设置后重试；
- 不引入替代防火墙、NAT 或常驻进程。

### TASK-02B：最小回归检查（Unix 已通过，Windows 待检查）

只做与本增量直接相关的检查：

1. `sh -n wgmesh/wgmesh.sh`；
2. `dash -n wgmesh/wgmesh.sh`；
3. `./wgmesh/tests/smoke.sh`，确认 Hub forwarding mock 只生成一次且
   Node 仍只有 Hub peer；
4. 在有 PowerShell 的环境运行脚本解析检查；没有 Windows/PowerShell 时
   标记为待目标机检查，不用其他平台结果代替。

不重复基础计划已经覆盖的完整生命周期、重复卸载、重复重启、两种 transport
全量组合和吞吐测试。

### TASK-02C：一次代表性端到端验收（待现场执行）

使用一条跨平台拓扑：

```text
Linux Hub + macOS Node + Windows Node
```

只确认：

1. 两个 Node 都能与 Hub 完成 handshake；
2. Node A 能访问 Node B 的 overlay 地址；
3. `wg` 状态和路由证据表明流量经过 Hub；
4. Hub 上已有防火墙允许该 overlay 转发。

不要求 `iperf3`、抓包、LAN/full-tunnel/NAT 验收，也不要求为每个平台和每种
transport 重复整套端到端流程。macOS Hub、Windows Hub 只需完成 TASK-02A 的
本机 forwarding 接线检查；若后续选择其一作为实际生产 Hub，再复用同一拓扑做
一次替换 Hub 的现场检查。

## 7. 难度评估

本计划难度：**52/100**。

相较“仅 Linux Hub”的 38/100，增加的实际难点是：

- macOS 和 Windows 的系统 forwarding 接线不同；
- Windows 需要在现有 Tunnel Service 生命周期后设置接口转发；
- 三个平台都要保留相同的命令、状态和失败语义。

没有把难度推高到跨平台网络编排级别的原因：

- 不新增 Node peer、控制面服务或配置同步；
- 不自动管理防火墙、NAT 或 LAN 路由；
- 复用基础计划已有的配置、状态、服务和幂等逻辑；
- 验收只保留一个代表性端到端拓扑和平台本机接线检查。

## 8. 交接结论

代码实现已开始，当前状态为：

```text
TASK-02A（Unix 已完成，Windows 待检查） →
TASK-02B（Unix 已通过） →
TASK-02C（待现场执行）
```

基础开发不推翻；本计划只把现有 Hub 的转发能力扩展到 Linux、macOS、
Windows，并将验收压缩到能证明平台接线和一条真实中转链路成立的最小集合。

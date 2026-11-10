# wgmesh 通用路由与可靠性增量开发计划

日期：2026-11-09

状态：实现中；TASK-03A 至 TASK-03D 的主要代码路径已落地，Unix mock
与 Unix 防火墙 mock 已通过；TASK-03E 的本地 Unix 回归和 PowerShell
解析/行为检查脚本已落地。Windows 现场、真实 nftables/pf 后端、重启恢复和
Hub+两 Node 代表性拓扑仍待现场验证。

## 1. 目标与依据

本计划补齐 wgmesh 的通用 WireGuard 路由与运行生命周期能力，不实施 K3s
配置。目标是让执行者可以：

- 在 Hub 上稳定转发节点间的 overlay IP 流量；
- 显式配置需要经 Hub 到达的其他 peer 自身地址，并持久保存对应路由和
  `AllowedIPs`；
- 防止 WireGuard 外层 Endpoint 流量被新建的隧道路由再次送入同一隧道；
- 让运行态接口、启动服务、脚本状态和磁盘配置保持可判定的一致关系；
- 为 WireGuard 接口提供可选 MTU 设置与状态回读。

依据：

- `01-wgmesh-base-development-plan.md` 定义单 Hub、多节点和 overlay-only 基线，
  并排除 LAN 路由、full-tunnel、full-mesh 与透明转发。
- `02-wgmesh-hub-relay-plan.md` 已定义 Hub 的 IPv4 转发和
  `Node A → Hub → Node B` 数据路径；现有计划不管理主机防火墙。
- 当前 `wgmesh.sh` 的 Hub peer 状态只保存节点 overlay 地址、公钥和节点 ID；
  Hub 配置只写 peer overlay 地址，Node 配置只把 overlay 网段指向 Hub。
- 当前 macOS 实现用运行时 utun 映射辅助接口状态/握手查询，但在线 peer
  增删仍以逻辑接口名执行 `wg set`。
- 当前 Linux 安装先直接启动 `wg-quick`，随后只启用 systemd unit；因此首次安装后
  可能出现接口活动而 `wg-quick@...` unit 未活动。
- 现有脚本没有 WireGuard 接口 MTU 参数；排障材料中出现的 K3s/Flannel 路由、
  主机特定策略路由和运行态 `AllowedIPs` 均不等于 wgmesh 已管理的配置。

上述源码事实描述当前工作树，不代表已在所有目标机器验证。现场排障记录仅用于
识别通用能力缺口；本计划不复制其中的真实地址、主机名或服务配置。

## 2. 范围与设计决定

### 纳入范围

- Linux、macOS、Windows 上的单 Hub IPv4 overlay 路由与 Hub 转发。
- 可选的额外 peer 自身地址路由：目的地址必须是显式声明的 IPv4 `/32`，由管理员
  在 Hub peer 登记和相关 Node 路由配置中维护。这里的地址只能是该 WireGuard
  peer 自身拥有的地址（例如该 peer 的第二个 overlay 地址），不能表示 peer
  后方的主机、LAN 网段或服务地址；它不提供路由自动发现或节点间配置推送。
- 基于 WireGuard 接口和已声明 peer 地址的通用转发策略；策略覆盖符合路由的
  IPv4 协议和端口，不写死应用端口。
- WireGuard Endpoint 的 underlay 路由保护。Tailscale transport 的外层 UDP
  流量必须继续走 Tailscale；它不要求 wgmesh 另行开放公网 WireGuard 端口。
- WireGuard 接口 MTU 的可选设置、持久化和状态回读。
- wgmesh 所有的系统转发设置、路由、peer、配置文件、服务和防火墙对象具有
  明确归属、幂等更新与仅删除自有资源的回滚语义。

### 不纳入范围

- K3s 的 `node-ip`、`K3S_URL`、Flannel 接口、Pod/Service CIDR、VXLAN 路由或
  Pod MTU。
- K3s API、kubelet、VXLAN、NodePort 等应用端口放行；wgmesh 不决定服务监听端口，
  不向目标机器的 INPUT 链开放服务端口。
- 任意 LAN 子网路由、节点后的路由通告、full-tunnel、NAT/DNAT/SNAT、
  full-mesh、透明地址转发。
- Tailscale 安装、ACL、`advertise-routes`、DERP/直连选择或承载链路质量修复。
- 公网 IP、云安全组、上游 NAT/UDP 端口映射。`public` transport 的 Endpoint
  可达性由部署环境提供；`tailscale` transport 不需要公网开放 WG UDP 端口。
- K3s/Kine/SQLite 性能、业务健康、主机上其他服务或现场旧 systemd 路由服务。

## 3. 转发与端口边界

Hub 的三层转发按目的 IP 路由数据包。对 wgmesh 已声明的 peer 地址，它可转发
任意被主机策略允许的 IPv4 协议/端口；应用不需要逐一登记端口。

任务 03C 为 wgmesh peer 间的转发提供可选、范围受限的通用防火墙策略。规则只匹配
wgmesh 接口及 overlay/已登记 peer 地址，不放开主机本地服务，也不配置 NAT。
目标节点自己的 INPUT 防火墙和应用监听策略仍由该服务/主机管理者负责。

为兼容已有手工防火墙，Hub 默认继续使用 `external` 模式，不接管现有策略。选择
`managed` 时只创建 wgmesh 标记的规则；若不能安全识别或管理当前防火墙后端，命令
在变更前失败，提示改用 `external` 并由管理员提供通用转发许可。两种模式均不
开放公网 WireGuard 监听端口。

### 3.1 防火墙后端支持矩阵

`managed` 不是对所有平台的承诺；实现必须按下表报告能力，不能把“命令成功”
当成规则一定生效：

| 平台/后端 | 本计划状态 | `managed` 要求 |
| --- | --- | --- |
| Linux nftables | 支持 | 能读取现有 hook/链顺序，创建独立 wgmesh 链并验证其实际接入路径 |
| Linux 仅有 iptables（legacy 或无法确认 nft 接管关系） | 不支持 | 使用 `external`；不得改写既有 iptables 规则 |
| macOS pf | 支持 | 能通过 `pfctl` 读取并验证 anchor/锚点顺序，规则只写入 wgmesh anchor |
| Windows 防火墙/WFP | 本增量不支持 | 使用 `external`；后续另立适配计划，不以 PowerShell 防火墙规则替代转发验证 |
| 其他或混合后端 | 不支持 | 预检失败并保持原模式和原规则 |

### 3.2 全局转发与卸载语义

Linux 的 `net.ipv4.ip_forward` 和 macOS 的 `net.inet.ip.forwarding` 是主机全局
设置。wgmesh 可以在 Hub 生命周期中确保其为 `1`，但不保存或恢复用户原值；卸载时
不把它关闭。卸载只移除 wgmesh 自己写入的配置 hook、路由、peer 和防火墙对象。
Windows 只处理当前 WireGuard 接口的 forwarding 设置，不接管其他接口；卸载不
修改无法证明由 wgmesh 创建的设置。

## 4. 命令与状态合同

本计划新增以下命令语义；实现时 Unix shell 与 PowerShell 必须保持一致：

```text
host init ... [--forward-firewall external|managed] [--mtu BYTES]
node join ... [--mtu BYTES]
host add-node ... [--peer-address IPv4/32 ...]
host set-routes --network-name ID --node-id ID [--peer-address IPv4/32 ...]
node set-routes --network-name ID [--peer-address IPv4/32 ...]
status [--network-name ID] [--json]
```

- `--forward-firewall` 仅用于 Hub；新安装默认 `external`，重复执行保留已记录
  的模式，模式切换必须显式请求。首次省略时记录 `external`；已有网络再次省略
  时保留现有模式；显式指定当前模式时只做预检和幂等对账；显式指定不同模式时
  采用事务切换，失败则恢复原模式和原有 wgmesh 规则。`managed` 只管理 wgmesh
  peer 转发规则。
- `--peer-address` 可重复指定。Hub 将每个地址关联到一个 peer；Node 将明确的远端
  peer 自身地址路由到 Hub。每个地址必须是该 peer 自己拥有的 IPv4 `/32`，不能
  表示 peer 后方主机、LAN 网段、默认路由或某个应用端口；地址集合由管理员在
  各节点本机维护，不自动同步。
- `host add-node` 登记 peer 时可以同时写入路由；已有 peer 的路由只能通过
  `host set-routes` 完整替换。相同 peer 与相同路由集合重复执行返回 `NOOP`。
- `/32` 地址不能与 overlay、Hub/Node 本机地址或其他 Hub peer 地址冲突；相同
  地址不能登记给多个 peer。不得把默认路由或子网路由混入此接口。
- WireGuard 外层 Endpoint 即使与某个 `--peer-address` 相同，也必须仍经所选
  underlay 发送。平台无法建立并验证该例外路由时，拒绝本次路由变更，不静默绕过。
- `--mtu` 是 WireGuard 接口 MTU；省略时保持当前后端默认，不自动推断或下调。
  配置状态记录请求值，`status` 在平台可查询时同时显示有效接口 MTU。
- 运行态有未登记 peer、AllowedIPs、路由或防火墙对象时，不覆盖或删除；输出
  `CONFIG_DRIFT` 和可核对的对象信息，由管理员先对齐后重试。
- `external` 模式不读取或判断外部防火墙是否放行，`status` 显示
  `firewall=EXTERNAL`、`firewall_check=NOT_CHECKED`；该状态不计为
  `CONFIG_DRIFT`。只有 `managed` 模式下由 wgmesh 创建的对象才参与漂移检查。

`node set-routes` 是完整替换当前 Node 经 Hub 路由的 peer 地址集合；省略所有
`--peer-address` 表示清空该集合。`host set-routes` 对指定 Hub peer 完整替换路由；
移除 peer 时只删除该 peer 所有的 wgmesh 路由与策略对象。

### 4.1 旧状态迁移

状态文件增加 `schema_version`，新字段至少包括 `firewall_mode`、
`peer_addresses` 和 `mtu_configured`。读取旧状态时按以下规则在内存中兼容；
`status` 不自动写回，只有明确的变更命令才提交迁移：

1. 缺少 `firewall_mode` 时导入为 `external`，因为旧版本没有声明防火墙所有权；
2. 缺少 `peer_addresses` 时导入为空集合；不从运行态任意路由或 `AllowedIPs`
   反推 peer 后方网络；
3. 缺少 `mtu_configured` 时，如果受管配置中存在可解析的 wgmesh MTU 就导入该值，
   否则记为 `UNSET` 并保持后端默认；不为了迁移主动改 MTU；
4. 变更命令先在临时文件完成规范化和校验，再原子替换状态文件。迁移只写状态，
   不重复创建路由、防火墙规则或 MTU；后续正常对账再按新字段执行；
5. 字段缺失且现有配置同时出现无法归属的同名对象时，报告
   `STATE_MIGRATION_REQUIRED`，保留现场，不自动接管或删除。

`status` 读取旧状态时报告 `state_migration_required=true`、
`config_consistency=UNKNOWN` 和 `STATE_MIGRATION_REQUIRED`，并保持 state 文件字节
和修改时间不变。迁移成功后重复执行必须返回 `NOOP`；迁移失败不得提交半成品状态。

## 5. 执行任务

| TASK | 状态 | 交付 |
| --- | --- | --- |
| TASK-03A 生命周期与接口一致性 | 已实现；Unix mock 通过；Windows/现场待验证 | Linux unit 成为默认启动生命周期的实际管理者；macOS peer 操作使用解析后的 utun 接口；状态可报告漂移 |
| TASK-03B peer 路由与 Endpoint 保护 | 已实现；Unix 路由 mock 通过；Windows/现场拓扑待验证 | Hub/Node 路由和 AllowedIPs 有持久来源；仅声明 peer 自身 `/32`；Endpoint 外层流量不被路由回 WireGuard |
| TASK-03C 通用转发防火墙策略 | 已实现；Unix 防火墙 mock 通过；真实 nftables/pf 待验证；Windows 固定 `external` | 按后端支持矩阵提供可选 `managed` 模式；`external` 模式不改防火墙 |
| TASK-03D 接口 MTU | 已实现；Unix 参数/配置 mock 覆盖；Windows/真实接口与重启待验证 | MTU 参数、持久化、有效值回读和平台验证 |
| TASK-03E 回归与代表性集成 | 部分完成；Unix smoke 与 firewall-smoke 通过；PowerShell/Windows/真实拓扑待验证 | mock、平台语法/生命周期检查和一条非 K3s overlay 转发验收 |

### 当前实现与验证边界（2026-11-10）

- TASK-03A 的实现路径在 `wgmesh/wgmesh.sh` 和 `wgmesh/wgmesh.ps1`，覆盖
  Linux `systemd` 生命周期、macOS `utunN` 运行时映射、状态一致性/漂移判断、
  以及仅清理可证明归属资源的更新路径。
- TASK-03B 的实现路径在两个入口脚本，覆盖显式 peer `/32`、Hub/Node
  `set-routes`、运行态 `AllowedIPs` 与系统路由对账、Endpoint underlay 保护、
  status 漂移报告和失败回滚。
- TASK-03C 的 Unix 实现由 `wgmesh/firewall-unix.sh` 接入 `wgmesh.sh`；PowerShell
  入口明确拒绝 `managed`，只接受 `external`。`wgmesh/tests/firewall-smoke.sh`
  使用受控的 nftables/pf 命令 mock 验证预检、幂等、漂移检测、原子同步和删除。
- TASK-03D 的 MTU 参数、状态字段、配置写入和 effective 值回读路径已在两个入口
  脚本实现；Unix smoke 覆盖输入、持久化和回滚场景。
- 已实际通过：`sh -n wgmesh/wgmesh.sh`、`dash -n wgmesh/wgmesh.sh`、
  `./wgmesh/tests/smoke.sh`、`./wgmesh/tests/firewall-smoke.sh` 和
  `git diff --check`（命令退出码均为 0；防火墙 smoke 中的失败输出是预期拒绝
  分支）。Unix smoke 已覆盖 status 的 clean、运行态 AllowedIPs 漂移、peer
  路由漂移和 Endpoint 回隧道检查。
- 尚未现场验证：PowerShell parser/行为检查（当前环境无 `pwsh`）、Windows
  Tunnel Service/路由/重启恢复、真实 Linux nftables 接入顺序、真实 macOS pf
  anchor 顺序、重启后的服务/接口/AllowedIPs/MTU 恢复，以及 Hub+两 Node 的非
  K3s overlay 双向流量和 `tailscale` underlay 路径。

### TASK-03A：生命周期与接口一致性

来源：基础计划的启动恢复合同、安装排障记录，以及当前 `wgmesh.sh` 的接口和
systemd/launchd 接线。

路径：

- 修改：`wgmesh/wgmesh.sh`、`wgmesh/wgmesh.ps1`。
- 修改测试：`wgmesh/tests/smoke.sh`；补充不引入第三方测试运行时的 Windows
  PowerShell 解析/行为检查。

步骤：

1. Linux 默认 autostart 安装改由 `systemctl enable --now wg-quick@<interface>`
   建立运行态；不得先用 `wg-quick up` 创建接口再只执行 `systemctl enable`。
   `--no-autostart` 仍使用直接 `wg-quick up`。
2. Linux `status` 明确区分接口状态、unit 活动状态和一致性状态。接口活动但 unit
   非活动且 `autostart=true` 时报告 `DEGRADED`；`autostart=false`（包括
   `--no-autostart` 创建的状态）下这是预期结果，报告
   `EXPECTED_NO_AUTOSTART`，不把它当成漂移或失败；两种情况都不自动关闭活动接口。
3. macOS 状态、握手、peer add/remove 及其补偿回滚统一使用逻辑接口到实际
   `utunN` 的解析结果；映射不存在或目标接口不活动时停止操作。
4. 更新过程中先验证当前运行态仍与 wgmesh 管理的 peer/配置相符；检测到未登记
   对象时保留现场并报告漂移，不清理未知对象。

验收：

- Linux 新安装的 autostart 结果同时为接口 `ACTIVE`、systemd unit `ACTIVE`；
  `--no-autostart` 不创建或启用 unit。
- 模拟接口活动但 unit inactive 时，`autostart=true` 的 `status` 报告
  `DEGRADED`；`autostart=false` 报告 `EXPECTED_NO_AUTOSTART`，两者都没有停止接口。
- macOS mock 将逻辑接口映射为 `utunN` 后，peer add/remove/rollback 均对
  `utunN` 调用 `wg`；无效映射时不改配置或 peer。
- 同参数重复运行幂等；任一步骤失败时恢复本轮创建的服务、配置、peer 和状态。

失败出口：若现有服务状态与接口状态不一致且不能证明接口由 wgmesh 管理，报告
差异、保留运行态资源，并只允许管理员先确认归属后重试；不自动接管接口。

### TASK-03B：peer 主机路由与 Endpoint 保护

来源：01 的 overlay 基线、02 的 Hub `/32 AllowedIPs` relay 模型，以及现场记录中
运行态 AllowedIPs、路由表与磁盘配置不一致的现象。

路径：

- 修改：`wgmesh/wgmesh.sh`、`wgmesh/wgmesh.ps1`。
- 修改测试：`wgmesh/tests/smoke.sh`；增加 PowerShell mock/解析测试。
- 文档：`wgmesh/README.md` 及本计划引用的命令合同。

步骤：

1. 为 Hub peer 状态加入显式 `--peer-address IPv4/32` 列表；为 Hub 和 Node 分别
   增加 `host set-routes`、`node set-routes` 完整替换操作。Hub peer `AllowedIPs`、
   Node 到 Hub 的 `AllowedIPs`、操作系统路由和本机 state/config 使用同一份已验证
   列表。
2. 拒绝 overlay 重叠、默认路由、重复/冲突 peer 地址及无法安全更新的既有路由。
   `--peer-address` 只能声明目标 peer 自身拥有的 `/32`；不自动学习或推送其他
   节点的地址，也不接受 peer 后方主机或网段。
3. 创建 Endpoint 路由保护：WireGuard 加密外层 UDP 必须经 Tailscale 或 public
   underlay；内层目的地址路由可以按已声明 `/32` 送入 WireGuard。实现按平台使用
   可验证的路由/策略路由机制，并将所有自有规则记录到网络状态。
   Windows 首次登记 peer 时尚无运行态 Endpoint，不能在 `host add-node` 同时提交
   额外 `--peer-address`；应先完成无额外地址的登记并等待握手，再由
   `host set-routes` 执行 underlay 可验证的路由变更。
4. `host add-node`、`host remove-node`、`host set-routes`、`node set-routes` 以
   磁盘 state/config 为提交源：先预检并暂存目标 state/config，再更新运行态
   `wg set`、操作系统路由和（若适用）Endpoint 保护，最后原子提交持久配置和
   state；任一步骤失败都恢复运行态、路由、保护规则和文件。失败恢复不删除外部
   规则。
5. `status` 展示已登记 peer 地址、配置路由、有效 endpoint 路径以及是否存在漂移。

验收：

- Hub 对两个 Node 的独立 `/32` peer 与附加 peer 地址，运行态和磁盘配置一致；
  Node 只把 Hub 作为 WireGuard peer。
- 同一目标地址重复登记、不同 peer 前缀重叠、overlay 冲突和默认路由均在修改前
  拒绝。
- 构造 Endpoint 地址同时作为内层 peer 目的地址的测试时，外层 WireGuard UDP
  仍选择 underlay；平台无法确认时命令失败且路由、配置、服务保持原状。
- add/remove/set-routes 的任一步骤模拟失败后，state、磁盘配置、运行态 peer 和
  wgmesh 路由恢复到变更前状态。
- 重启后实际路由及 AllowedIPs 与保存配置一致。

失败出口：若某平台不能可靠区分 Endpoint 外层流量和相同 IP 的内层流量，该平台
拒绝启用会覆盖 Endpoint 的 peer 路由，并保留 overlay-only 功能；不得退化为可能
产生路由自环的普通路由。

### TASK-03C：通用转发防火墙策略

来源：02 当前“Hub 防火墙由外部管理”的边界，以及用户区分“通用 peer 转发”和
“外部服务端口”的需求。

路径：

- 修改：`wgmesh/wgmesh.sh`、`wgmesh/wgmesh.ps1`。
- 修改测试：`wgmesh/tests/smoke.sh` 和 Windows mock/解析测试。
- 文档：`wgmesh/README.md`。

步骤：

1. 增加 Hub 的 `external|managed` 策略。`external` 保持现有行为；`managed` 仅在
   预检确认平台后端可识别、规则可隔离、删除可精确回滚后创建规则。
2. `managed` 规则限制在 wgmesh WireGuard 接口及 overlay/已登记 peer 地址之间，
   允许所有 IPv4 协议/端口的转发；不添加服务 INPUT 规则、WireGuard 公网 UDP
   入站规则或 NAT。
3. 规则使用 wgmesh 可识别的独立链/anchor/策略对象，写入状态并保持幂等；卸载和
   peer 删除只清理其创建的对象。Linux nftables 的独立 forward 链中 `accept`
   不能保证覆盖后续链的 `drop`，因此必须核对现有链顺序并接入可识别的防火墙
   管理器；不能把“规则已创建”当成“转发已放行”。
4. 省略 `--forward-firewall` 的首次初始化固定为 `external`；重复初始化保留
   状态中的模式。显式从 `external` 切到 `managed` 时先完成后端预检，再创建
   wgmesh 对象；显式从 `managed` 切到 `external` 时先确认可删除的 wgmesh 对象，
   删除完成后才提交新模式。任一步骤失败都恢复原模式、规则和 state。
5. 若现有防火墙后端/规则归属不清楚，或策略顺序无法证明转发会生效，
   `managed` 在任何写入前失败；保留原规则，管理员可显式选 `external` 并配置
   所需的通用 WG 转发许可。`status` 对 `external` 输出
   `EXTERNAL/NOT_CHECKED`，不把外部规则未知误报为漂移。

验收：

- Hub→Hub-WG→Node 的已登记 peer 间转发可通过任意测试协议/端口验证；目标主机
  本地服务仍须使用其自己的 INPUT/应用策略。
- 规则不允许 wgmesh 到任意非 WireGuard 接口的转发，不开放具体服务端口，不更改
  UDP listener 的公网暴露。
- 预先存在的防火墙对象逐字保留；重复安装无重复规则；卸载只移除 wgmesh 规则。
- 后端不支持、状态不可读或回滚失败时，操作失败并保留诊断；不得自动切换模式。

### TASK-03D：WireGuard 接口 MTU

来源：排障材料中的 WireGuard 接口 MTU 差异和大包测试，但该材料未证明 MTU 是
当前丢包的唯一根因。

路径：

- 修改：`wgmesh/wgmesh.sh`、`wgmesh/wgmesh.ps1`。
- 修改测试：Unix smoke 和 Windows 参数/配置检查。
- 文档：README 命令参数与已知限制。

步骤：

1. `host init`、`node join` 增加可选 `--mtu BYTES`；不传时保留 WireGuard 后端
   默认值，不自动根据 Tailscale 接口推算。
2. 参数写入 managed WireGuard 配置与 state；重复执行时将 MTU 纳入同参数判断。
3. `status` 回显 configured/effective MTU；平台不能读取 effective 值时明确输出
   `UNKNOWN`，不将请求值冒充实测值。
4. MTU 写入失败时不提交新 state；已有接口变更失败时恢复之前配置和 MTU。

输入合同：`BYTES` 只能是十进制整数，跨平台可接受范围为 `576..65535`（含边界）。
实现先做该通用范围校验，再按平台后端可报告的更窄范围校验；后端无法应用或回读
时返回 `MTU_UNSUPPORTED` 并恢复旧配置。负数、小数、空值、带单位文本、`0`、
小于 `576` 或大于 `65535` 均在修改前拒绝。

验收：

- 正常、边界、非整数和超出平台范围的 MTU 输入均有确定结果；非法输入在修改前
  拒绝。
- Linux/macOS/Windows 各至少一次验证配置持久化、活动接口有效值和重启恢复。
- 大包/DF 双向对照作为现场验收证据；测试结果用于选值，不改变自动默认值。

失败出口：若某后端不接受 MTU 指令，保留之前配置并报告该平台验证结果；不静默
忽略参数，也不因此修改 Pod/Flannel MTU。

### TASK-03E：回归与代表性集成

来源：01、02 的基础回归合同及本计划 TASK-03A 至 TASK-03D。

路径：

- 修改：`wgmesh/tests/smoke.sh`；新增最少量 PowerShell 检查，不引入第三方运行时。
- 运行验收：Linux、macOS、Windows 目标机及两 Node + Hub 的临时/现有授权网络。
- 文档：README 当前状态和限制。

步骤与验收：

1. Shell 静态检查：`sh -n wgmesh/wgmesh.sh`、`dash -n wgmesh/wgmesh.sh`；
   Unix 行为检查：`./wgmesh/tests/smoke.sh`。
2. PowerShell 使用系统 Parser 做语法检查；目标 Windows 检查 Tunnel Service、
   路由、防火墙策略和重启恢复。没有 Windows 时标为待验证，不以 Unix mock 替代。
3. 使用一条代表性拓扑验证 Hub/两个 Node 的握手、overlay 双向路由和普通 IP
   流量；分别验证 `external` 与可用时的 `managed` 防火墙模式。
4. 对 `tailscale` transport 验证 endpoint 走 Tailscale underlay，不要求开放公网
   WG 端口。`public` 只验证配置生成；上游 UDP/NAT/安全组不属于本任务。
5. 重启后检查服务管理器、接口、peer、Endpoint 路由、MTU 和防火墙对象恢复；
   现场结果与 mock 结果分开记录。

失败出口：隔离的 Unix mock 失败时先修复对应 task；目标平台缺失时保留代码与 mock
结果，明确列为待现场验收；真实拓扑失败时保存 `wg show`、系统路由、转发开关和
防火墙状态的脱敏摘要，仅修复 wgmesh 负责的配置，不改 K3s 参数。

## 6. 计划内与计划外的解决内容

### 计划内

| 解决内容 | 对应任务 | 计划结果 |
| --- | --- | --- |
| Linux 接口、systemd unit、`autostart` 状态不一致 | 03A | 默认启动由 unit 管理；`autostart=true` 的异常标为 `DEGRADED`，`--no-autostart` 的接口活动标为预期状态 |
| macOS 逻辑接口名与实际 `utunN` 不一致 | 03A | 状态、握手、peer 增删和回滚统一使用解析后的实际接口 |
| Hub peer、AllowedIPs、系统路由和磁盘 state/config 漂移 | 03B | 使用同一份显式 `/32` 来源，支持完整替换、状态回读和事务回滚 |
| Endpoint 外层流量被内层路由吸回 WireGuard | 03B | 创建并验证 underlay 保护；无法证明时拒绝该路由变更 |
| peer 间通用 IP 转发缺少可选的 wgmesh 基础策略 | 03C | 按支持矩阵提供 `managed`；允许已登记 peer 间任意 IPv4 协议/端口转发，不开放服务 INPUT、NAT 或公网监听 |
| Tailscale transport 是否需要公网 WG 端口 | 03B、03C、03E | 明确外层 UDP 走 Tailscale underlay，不要求额外公网 WireGuard 入站端口 |
| WireGuard MTU 无法声明、持久化和回读 | 03D | 增加 `--mtu`、跨平台输入范围、effective 回读和失败回滚 |
| 旧 state 缺新字段、模式切换和资源归属不清 | 03A、03C | 提供一次性迁移、显式模式切换和只删除 wgmesh 自有对象的语义 |
| 卸载时误改主机已有全局转发 | 03A | Linux/macOS 不关闭全局 forwarding，只清理 wgmesh 自有 hook、路由、peer 和防火墙对象 |
| 计划功能的 mock、语法、重启和代表性 overlay 验收 | 03E | 形成可复现的 Unix/PowerShell/目标机验证记录，现场证据与 mock 结果分开 |

### 计划外

| 内容 | 处理边界 |
| --- | --- |
| K3s 的 `node-ip`、`K3S_URL`、Flannel、Pod/Service CIDR、VXLAN、NodePort、Pod MTU 和 K3s 服务端口 | 由 K3s 或主机服务配置负责；本计划不写入、迁移或回滚 |
| peer 后方主机、LAN 网段、默认路由、full-tunnel、full-mesh、NAT/DNAT/SNAT 和透明转发 | 不接受为 `--peer-address`；需要另立路由/网关方案 |
| Tailscale 安装、ACL、`advertise-routes`、DERP/直连选择和承载链路质量修复 | 由 Tailscale/网络环境负责；本计划只保护 WireGuard Endpoint 的 underlay 选择 |
| 公网 IP、云安全组、上游 NAT、UDP 端口映射和公网可达性 | 由部署环境负责；`public` 仅生成和验证配置输入 |
| 主机包管理器、Homebrew/WinGet、sudo/管理员权限、Docker 或其他业务服务健康 | 属于安装环境或外部服务；不在 wgmesh 计划内 |
| `external` 防火墙模式下已有规则的检查、修改或服务端口放行 | `status` 显示 `EXTERNAL/NOT_CHECKED`；由管理员或服务自身配置 |
| 现场已有的 K3s/HK-WG 策略路由、fwmark、UFW/iptables、Flannel MTU、持久化 systemd 路由服务和旧 NAT 清理 | 本计划不自动还原；应按外部服务依赖单独盘点、验证和决定是否优化 |
| 当前某条真实承载路径的丢包根因及业务可用性 | 03D 可提供 MTU 证据，03B 可消除 wgmesh 路由自环；链路质量和业务健康仍需现场专项排查 |
| Windows `managed` 防火墙/WFP 适配 | 本增量明确使用 `external`，后续另立适配计划 |

本计划不会因为“脚本外”而自动删除已有 K3s 或主机网络改动；只有完成归属、
依赖和回程路径核对后，才应在独立变更中决定回滚或保留。

## 7. 难度评估与文档复评

开发者初评：**76/100**。主要难点是三类平台的 route/Endpoint 处理不同、路由变更
必须与运行态和持久配置原子对齐，以及 managed 防火墙要避免覆盖用户现有策略。
评分基于当前 shell/PowerShell 结构和 01/02 合同，不代表失败概率或工期。

评审后难度仍为：**72/100**。本轮补充了旧状态迁移、`autostart` 预期状态、
防火墙模式事务切换、后端支持矩阵、`host set-routes` 回滚、peer 地址语义和
MTU 跨平台范围，减少了实现者自行选路的空间；Windows `managed` 被明确排除，
抵消了新增合同带来的工作量。三平台路由、Linux/macOS 防火墙实际接入、权限和
真实网络恢复验证仍是主要成本。

## 8. 交接结论

本计划可以进入 wgmesh 实现。实现顺序为：

```text
TASK-03A → TASK-03B → TASK-03C / TASK-03D → TASK-03E
```

TASK-03C 与 TASK-03D 可并行；TASK-03B 的 Endpoint 路由保护必须先在各平台确认
可验证的路由机制，再启用会覆盖 Endpoint 的路由。未完成现场验收前，不将计划或
mock 通过描述为生产网络已修复。

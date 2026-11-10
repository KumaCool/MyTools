# wgmesh

`wgmesh` 是一组直接调用系统 WireGuard 工具的跨平台脚本，用于管理单 Hub、多节点 WireGuard 网络。

## 实现方式

- Linux、macOS 使用 `wgmesh.sh`。
- Windows 使用 `wgmesh.ps1`。
- 脚本直接执行，不需要编译产物或第三方运行库。
- 脚本直接调用 WireGuard 工具和服务管理器。
- Linux/macOS 的 `wgmesh.sh` 必须与同目录的 `firewall-unix.sh` 一起部署；
  两个文件缺一时脚本会在启动前停止。
- 安装命令发现 WireGuard 工具缺失时，只会调用目标机器已经存在的包管理器尝试安装；
  不会假定 Homebrew 或 WinGet 存在，也不会安装包管理器、Tailscale 或其他
  系统组件。

## 首版范围

- Hub 使用 `host init` 初始化。
- 节点使用 `node join` 在节点本机加入。
- Hub 使用 `host add-node` 在 Hub 本机登记节点公钥。
- Hub 使用 `host remove-node` 在 Hub 本机撤销节点 peer。
- 支持安装时选择 `tailscale` 或 `public` endpoint。
- Hub 和节点分别在本机生成私钥，只通过命令参数交换公开密钥。
- 节点之间的 WireGuard overlay 通信经 Hub 转发，数据路径为
  `Node A → Hub → Node B`。
- Linux、macOS、Windows 都可以作为 Hub，也都可以作为 Node。
- Hub 只转发 overlay 网段；不实现 `member_routes`、LAN 路由、full-tunnel、
  full-mesh 或现有地址透明转发。
- 增量计划 03 增加可选接口 MTU、显式 peer `/32` 路由，以及 Hub 通用 peer
  转发防火墙策略；不管理 K3s/Flannel/Pod 网络。
- 不部署常驻 `wgmesh` 服务，不通过 SSH 远程卸载。
- 不提供在线踢出通知或公钥自动过期。

## 依赖

目标机器需要具备下列运行环境；WireGuard 工具可在安装命令中按平台自动补齐：

| 平台 | 脚本 | 需要的已有组件 |
| --- | --- | --- |
| Linux Hub / Node | `wgmesh.sh` | POSIX shell、`wg`、`wg-quick`、`ip`；Hub 还需要已有 `sysctl`；缺少 WireGuard 工具时使用已有的 `apt-get`、`dnf`、`yum`、`apk` 或 `pacman` 安装；启用开机启动时需要 `systemctl` |
| macOS Hub / Node | `wgmesh.sh` | POSIX shell、`ifconfig`/`netstat`；Hub 还需要已有 `sysctl`；缺少 WireGuard 工具时仅在检测到已有 Homebrew 后尝试安装；启用开机启动时需要 `launchctl` |
| Windows Hub / Node | `wgmesh.ps1` | PowerShell、`sc.exe`、系统自带 `Get-NetIPAddress`/`Get-NetRoute`；Hub 还需要 `Set-NetIPInterface` 或等价系统命令；缺少 WireGuard 工具时仅在检测到已有 `winget.exe` 后尝试安装 WireGuard for Windows |

选择 `tailscale` 时，目标机器需要已连通同一 Tailscale 网络；选择 `public` 时，Hub endpoint 需要由公网或 NAT 环境提供可达性。脚本只使用命令中提供的 endpoint，不调用 Tailscale 管理 API。relay 计划中的逻辑路径是 `Node → Hub → Node`。
Hub 所在机器的现有防火墙必须允许 WireGuard 接口上的 overlay 转发。默认
`external` 模式不修改防火墙；Unix 可选的 `managed` 模式只创建和维护带有
wgmesh 标记的 peer 间转发规则，不安装防火墙组件，也不开放主机服务端口或公网
WireGuard 监听端口。Windows 目前只支持 `external`。

macOS 脚本需要命令行中的 `wg`、`wg-quick` 和 `wireguard-go`；仅安装
WireGuard.app 不保证这些命令已经出现在当前 shell 的 `PATH` 中。Homebrew
不是 macOS 的系统默认组件；如果目标机没有 Homebrew，脚本会直接停止并提示
先手动准备 WireGuard 命令行工具，不会替用户安装 Homebrew。
如果以 root 或 `sudo` 执行且没有非 root 的 `SUDO_USER`，脚本不会尝试以 root
调用 Homebrew，而是要求先由登录用户安装 WireGuard 命令行工具。
Windows 同理，`winget.exe`
不是所有 Windows 镜像都保证存在；缺少它时脚本会提示手动安装 WireGuard for
Windows 或 App Installer/WinGet。

## 命令接口

Linux/macOS：

```sh
./wgmesh.sh host init \
  --network-name <NETWORK_ID> \
  --node-id <HUB_ID> \
  --transport tailscale|public \
  --overlay-cidr <WG_CIDR> \
  --address <HUB_WG_CIDR> \
  --endpoint <REACHABLE_HUB_IP_OR_DNS:PORT> \
  [--mtu <BYTES>] [--forward-firewall external|managed]

./wgmesh.sh node join \
  --network-name <NETWORK_ID> \
  --node-id <NODE_ID> \
  --transport tailscale|public \
  --overlay-cidr <WG_CIDR> \
  --address <NODE_WG_CIDR> \
  --hub-endpoint <REACHABLE_HUB_IP_OR_DNS:PORT> \
  --hub-public-key <HUB_WG_PUBLIC_KEY> \
  [--mtu <BYTES>]

./wgmesh.sh host add-node \
  --network-name <NETWORK_ID> \
  --node-id <NODE_ID> \
  --address <NODE_WG_CIDR> \
  --node-public-key <NODE_WG_PUBLIC_KEY> \
  [--peer-address <PEER_OWN_IPV4/32> ...]

./wgmesh.sh host set-routes \
  --network-name <NETWORK_ID> \
  --node-id <NODE_ID> \
  [--peer-address <PEER_OWN_IPV4/32> ...]

./wgmesh.sh node set-routes \
  --network-name <NETWORK_ID> \
  [--peer-address <PEER_OWN_IPV4/32> ...]
```

Windows 使用同样的子命令和参数：

```powershell
.\wgmesh.ps1 host init `
  --network-name <NETWORK_ID> `
  --node-id <HUB_ID> `
  --transport tailscale `
  --overlay-cidr <WG_CIDR> `
  --address <HUB_WG_CIDR> `
  --endpoint <REACHABLE_HUB_IP_OR_DNS:PORT>
```

命令中的 `<...>` 是需要替换的值，`[...]` 表示可选项；`tailscale` 和
`public` 是固定值，不能替换成其他 transport。需要管理员权限的命令在
Linux/macOS 使用 `sudo` 执行，Windows 使用“以管理员身份运行”的
PowerShell。任意命令后追加 `--help` 或 `-h` 可查看该脚本的用法。Linux/macOS
直接部署时应保持 `wgmesh.sh` 与 `firewall-unix.sh` 同目录；常见管理员路径为
Linux `/usr/local/sbin`，macOS `/usr/local/bin`，实际调用路径必须在当前
`PATH` 中或使用绝对路径。

执行 `host init`、`node join`、peer 增删或卸载时，如果缺少 WireGuard 工具，
脚本会先尝试使用已检测到的包管理器安装。Linux 使用可用的 `apt-get`、`dnf`、
`yum`、`apk` 或 `pacman`；macOS 仅使用已有 Homebrew；Windows 仅使用已有
`winget.exe`。包管理器不存在或安装失败时，脚本会在修改配置前停止并报告原因；
不会安装包管理器本身。`status` 只检查工具，不因查询状态而安装软件。
Unix `host init` 和 `node join` 会在检查或安装 WireGuard 依赖前，预检状态、配置
及适用的 LaunchDaemon 路径类型和可写/可遍历权限；预检失败时不会创建目录或触发
包管理器。

## 具体填写示例

下面用一组完整值说明每个占位符。该示例选择 `public`，overlay 使用候选私有
网段 `198.51.100.0/24`。它不是固定答案；脚本会在安装前检查本机地址、路由和
其他 `wgmesh` 状态，发现重叠就停止，实际部署时应换成所有目标机都未使用的
网段。`203.0.113.20` 是 RFC 5737 文档地址，真实部署时必须换成 Node 实际
能够访问的 Hub 公网 IP 或 DNS。

| 文档占位符 | 示例填写值 | 说明 |
| --- | --- | --- |
| `<NETWORK_ID>` | `example-mesh` | 网络名称；Hub、Node、`host add-node` 全部使用同一个值。 |
| `<HUB_ID>` | `hub` | Hub 的节点标识。 |
| `<NODE_ID>` | `node-a` | Node 的节点标识；同一网络中的每个 Node 使用不同值。 |
| `<WG_CIDR>` | `198.51.100.0/24` | 整个 WireGuard overlay 网段；只有确认未占用时才使用。 |
| `<HUB_WG_CIDR>` | `198.51.100.1/24` | Hub 在 overlay 中的地址。 |
| `<NODE_WG_CIDR>` | `198.51.100.2/32` | `node-a` 在 overlay 中的地址。 |
| `<REACHABLE_HUB_IP_OR_DNS:PORT>` | `203.0.113.20:51820` | Node 访问 Hub 的地址和 UDP 端口。 |
| `<HUB_WG_PUBLIC_KEY>` | `host init` 输出的公钥 | 复制 Hub 执行 `host init` 后输出的 `hub_public_key` 值。 |
| `<NODE_WG_PUBLIC_KEY>` | `node join` 输出的公钥 | 复制 Node 执行 `node join` 后输出的 `node_public_key` 值。 |

按上述示例，执行顺序如下。Hub 先执行：

```sh
sudo ./wgmesh.sh host init \
  --network-name example-mesh \
  --node-id hub \
  --transport public \
  --overlay-cidr 198.51.100.0/24 \
  --address 198.51.100.1/24 \
  --endpoint 203.0.113.20:51820
```

记下输出中的 `hub_public_key`，然后在 Node 本机执行：

```sh
sudo ./wgmesh.sh node join \
  --network-name example-mesh \
  --node-id node-a \
  --transport public \
  --overlay-cidr 198.51.100.0/24 \
  --address 198.51.100.2/32 \
  --hub-endpoint 203.0.113.20:51820 \
  --hub-public-key "<替换为上一步的 hub_public_key>"
```

记下 Node 输出中的 `node_public_key`，再回到 Hub 本机执行：

```sh
sudo ./wgmesh.sh host add-node \
  --network-name example-mesh \
  --node-id node-a \
  --address 198.51.100.2/32 \
  --node-public-key "<替换为上一步的 node_public_key>"
```

如果选择 Tailscale，把三条命令中的 `--transport public` 改为
`--transport tailscale`，并把 `203.0.113.20:51820` 改成 Hub 的
Tailscale IP 或 Tailscale DNS 名称加端口；其余 `network`、`node-id`、
overlay 和公钥填写方式不变。

## 参数说明

### 参数通用规则

| 参数 | 通用含义 |
| --- | --- |
| `--network-name <NETWORK_ID>` | 网络标识。它决定本机状态目录、WireGuard 配置文件和接口名称；同一个网络的 Hub、Node、`host add-node` 必须使用同一个值。值必须以小写字母或数字开头，只能包含小写字母、数字、`_`、`-`，最长 48 个字符。 |
| `--node-id <NODE_ID>` | 节点标识，不是 WireGuard 公钥。Hub 的值标识 Hub 本机；Node 的值标识当前 Node；在同一 Hub 上应保持唯一。 |
| `--transport tailscale\|public` | 选择 endpoint 的承载网络。`tailscale` 要求两端通过同一 Tailscale 网络可达；`public` 要求通过公网地址或 NAT 映射可达。该参数只记录部署选择，脚本不会安装、配置或切换 Tailscale、公网 IP 或 NAT；防火墙按 `--forward-firewall` 的规则执行。 |
| `--overlay-cidr <WG_CIDR>` | WireGuard overlay 的 IPv4 网段，例如候选值 `198.51.100.0/24`。Hub 地址和所有 Node 地址必须位于其中；不能使用默认路由 `0.0.0.0/0`，并且安装前必须确认该网段未被本机网络或其他 `wgmesh` 网络使用。 |
| `--address <CIDR>` | 当前 Hub 或 Node 在 WireGuard overlay 上的地址。Hub 使用本机地址（例如 `198.51.100.1/24`）；Node 和 `host add-node` 使用节点地址，并且必须是 `/32`（例如 `198.51.100.2/32`）。 |
| `--no-autostart` | 可选开关。仍会创建配置并立即启动当前隧道，但不登记系统启动恢复；省略时默认启用开机/登录后恢复。该开关只适用于 `host init` 和 `node join`。 |
| `--mtu <BYTES>` | 可选 WireGuard 接口 MTU，十进制整数 `576..65535`；省略时使用 WireGuard 后端默认，不按承载网络 MTU 自动推算。用于 `host init`、`node join`。 |
| `--peer-address <IPv4/32>` | 可重复指定某个 WireGuard peer 自己拥有的额外 IPv4 地址。不能表示 peer 后方主机/LAN、服务端口或子网；地址不能与 overlay、Hub/Node 自身或其他 peer 地址冲突。 |

### `host init`

在当前 Hub 本机创建一个网络实例、WireGuard 接口和仅限 overlay 的
转发能力。Linux、macOS、Windows 都可以执行 `host init` 作为 Hub。

| 参数 | 含义 |
| --- | --- |
| `--network-name <NETWORK_ID>` | 继承通用规则中的网络标识；用于创建 Hub 本机的网络实例。 |
| `--node-id <HUB_ID>` | Hub 在该网络中的节点标识。 |
| `--transport tailscale\|public` | 继承通用规则中的传输选择；它描述 `--endpoint` 的可达网络。 |
| `--overlay-cidr <WG_CIDR>` | Hub 使用的 overlay 网段，必须与所有 Node 的 `node join` 保持一致。 |
| `--address <HUB_WG_CIDR>` | Hub 的 WireGuard 本机地址；地址部分必须位于 `--overlay-cidr` 内。 |
| `--endpoint <HOST:PORT>` | Hub 对 Node 提供的 WireGuard endpoint。`PORT` 同时是 Hub 的 WireGuard UDP 监听端口；IPv6 必须写成 `[IPv6]:PORT`。 |
| `--forward-firewall external\|managed` | 可选 Hub peer 转发防火墙策略；首次省略为 `external`，重复执行省略时保留已记录模式。Linux nftables 和 macOS pf 在后端与规则顺序可验证时支持 `managed`；Windows、iptables legacy、混合或未知后端使用 `external`。 |
| `--mtu <BYTES>` | 可选 WireGuard Hub 接口 MTU，范围 `576..65535`。 |
| `--no-autostart` | 继承通用规则中的可选开关。 |

### `node join`

在 Node 本机创建一个网络实例。该命令只配置 Node，不会修改 Hub 的 peer 列表。
Node 只需要 Hub peer，不需要保存其他 Node 的公钥或 endpoint。

| 参数 | 含义 |
| --- | --- |
| `--network-name <NETWORK_ID>` | 必须与 Hub 使用的网络标识一致。 |
| `--node-id <NODE_ID>` | 当前 Node 的节点标识；同一 Hub 网络内应保持唯一。 |
| `--transport tailscale\|public` | 必须与 Hub 的部署选择一致，用于说明 `--hub-endpoint` 的可达网络。 |
| `--overlay-cidr <WG_CIDR>` | 必须与 Hub 的 overlay 网段一致。 |
| `--address <NODE_WG_CIDR>` | Node 的 WireGuard 本机地址；必须位于 overlay 网段内并使用 `/32`，例如 `198.51.100.2/32`。 |
| `--hub-endpoint <HOST:PORT>` | Node 访问 Hub 的 WireGuard endpoint，通常填写 Hub `host init` 的 `--endpoint` 原值；IPv6 必须写成 `[IPv6]:PORT`。 |
| `--hub-public-key <HUB_WG_PUBLIC_KEY>` | Hub 的 WireGuard 公钥，由 Hub 执行 `host init` 后输出，再通过人工渠道传给 Node；不能填写 Hub 私钥。 |
| `--mtu <BYTES>` | 可选 WireGuard Node 接口 MTU，范围 `576..65535`。 |
| `--no-autostart` | 继承通用规则中的可选开关。 |

### `host add-node`

在 Hub 本机登记一个已经执行过 `node join` 的 Node peer。登记后，Hub
可以把一个 Node 的 overlay 流量转发给另一个已登记 Node。

| 参数 | 含义 |
| --- | --- |
| `--network-name <NETWORK_ID>` | 要修改的 Hub 网络标识，必须是当前 Hub 已通过 `host init` 创建的网络。 |
| `--node-id <NODE_ID>` | 要登记的 Node 标识，必须与该 Node 执行 `node join` 时使用的值一致。 |
| `--address <NODE_WG_CIDR>` | 要登记的 Node 的 overlay 地址，必须位于 Hub 的 overlay 网段内并使用 `/32`；该地址会写入 Hub peer 的 `AllowedIPs`。 |
| `--node-public-key <NODE_WG_PUBLIC_KEY>` | Node 的 WireGuard 公钥，由 Node 执行 `node join` 后输出，再传给 Hub；不能填写 Node 私钥或 Hub 公钥。 |
| `--peer-address <IPv4/32>` | 可重复登记该 Node peer 自己拥有的额外 IPv4 `/32` 地址，写入对应 peer 的 `AllowedIPs`。 |

Windows 首次执行 `host add-node` 时，WireGuard Tunnel Service 尚未产生该
peer 的运行态 Endpoint，脚本无法验证额外 `/32` 路由的 underlay。Windows
应先省略 `--peer-address` 完成登记并等待一次握手，再执行
`host set-routes` 写入额外地址；Linux/macOS 可在 `host add-node` 中直接指定
已能验证的地址。

### `host set-routes` 与 `node set-routes`

```text
host set-routes --network-name <NETWORK_ID> --node-id <NODE_ID> [--peer-address <IPv4/32> ...]
node set-routes --network-name <NETWORK_ID> [--peer-address <IPv4/32> ...]
```

这两个命令完整替换已登记的额外 peer 地址集合；省略所有 `--peer-address` 表示清空。
Hub 侧指定 peer 必须已由 `host add-node` 登记。每个地址必须由对应 peer 自身持有、
使用 `/32`，且不能与 overlay 或其他已登记地址冲突。它不创建 peer 后方主机、
LAN 子网或默认路由。

### 管理命令和通用选项

| 命令或选项 | 含义 |
| --- | --- |
| `host remove-node --network-name <NETWORK_ID> --node-id <NODE_ID>` | 只在 Hub 本机撤销该 Node peer；不会远程操作 Node。 |
| `node uninstall --network-name <NETWORK_ID> --node-id <NODE_ID>` | 只在当前 Node 本机卸载，并校验 `node-id` 与已安装状态一致。 |
| `host uninstall --network-name <NETWORK_ID>` | 只在当前 Hub 本机卸载该网络及其已登记 peer。 |
| `status [--network-name <NETWORK_ID>]` | 查看一个网络或本机全部网络的状态。省略 `--network-name` 时列出全部本机状态。 |
| `--json` | 仅用于 `status`，将状态输出为 JSON；不能用于安装、登记或卸载命令。 |
| `--help` / `-h` | 输出命令用法并退出，不修改本机 WireGuard 或 wgmesh 状态。 |

`status` 中的 `autostart` 表示保存的开机启动设置；`state` 表示 WireGuard 接口
当前是否实际存在（`ACTIVE` 或 `CONFIGURED`）；`service_state` 表示服务管理器报告的
当前状态。Linux 使用 systemd，macOS 使用 launchd，Windows 使用 WireGuard Tunnel
Service。Linux/macOS 的服务管理器不可查询时为 `UNKNOWN`；Windows 尚无对应服务时为
`ABSENT`。`autostart=false` 且接口活动属于预期状态 `EXPECTED_NO_AUTOSTART`；
配置了 `autostart=true` 但 Linux unit 未活动则报告 `DEGRADED`。Hub 状态还显示
`firewall_mode` 和防火墙检查状态；`external` 下显示 `EXTERNAL/NOT_CHECKED`，
不代表外部规则已验证。状态会分别显示配置的 MTU 和可读取时的有效 MTU。
`config_consistency` 表示受管配置、运行态 peer/AllowedIPs、已登记 `/32` 路由和
Endpoint 出口的对账结果：`CONSISTENT`、`CONFIG_DRIFT` 或 `UNKNOWN`；具体对象
写入 `config_drift`。`endpoint_path`（Windows 还包括
`endpoint_path_state`、`endpoint_path_details`）显示 Endpoint 的实际出接口或
无法核验的原因。`status` 只读检查，不会自动修复漂移，也不会自动写回旧状态。
旧状态缺少新字段时，状态会报告 `state_migration_required=true`、
`config_consistency=UNKNOWN` 和 `STATE_MIGRATION_REQUIRED`；后续明确的
`host init`、`node join`、peer 或卸载命令才会执行状态格式迁移。
安装命令的 `interface_state` 也报告 WireGuard 接口当前状态。

脚本会校验 IPv4 CIDR、endpoint 端口（`1-65535`）和 WireGuard 公钥格式
（44 字符 Base64 文本）。参数中的私钥不会被接受；两端私钥都由脚本在各自机器上
本地生成。`host init` 和 `node join` 安装前会检查本机已有 IPv4 地址、非默认路由
以及其他 `wgmesh` 状态是否与 `--overlay-cidr` 重叠；检查命令缺失或发现冲突时会
停止，不会创建隧道。`node join` 完成后不会自动修改 Hub，必须再把 Node 公钥和地址传给
管理员，由管理员在 Hub 本机执行 `host add-node`。

管理命令：

```text
status [--network-name <NETWORK_ID>] [--json]
host set-routes --network-name <NETWORK_ID> --node-id <NODE_ID> [--peer-address <IPv4/32> ...]
node set-routes --network-name <NETWORK_ID> [--peer-address <IPv4/32> ...]
host remove-node --network-name <NETWORK_ID> --node-id <NODE_ID>
node uninstall --network-name <NETWORK_ID> --node-id <NODE_ID>
host uninstall --network-name <NETWORK_ID>
```

`node join` 只配置节点本机，不会自动登记 Hub。管理员需要把节点公钥传给 Hub，并在 Hub 本机执行 `host add-node`。`host remove-node` 只修改 Hub 本机；它不会远程卸载节点，也不会向节点发送“已被踢出”消息。

网络参数不使用 TOML/JSON 文件传入。脚本会生成 WireGuard 后端所需的 `.conf` 文件，并保存本机状态用于 `status`、幂等判断、peer 路由和卸载；这些文件由脚本维护，不作为用户配置接口。`--json` 仅控制 `status` 输出。选择 `tailscale` 时，WireGuard Endpoint 的外层 UDP 走 Tailscale 网络，不要求额外开放公网 WireGuard UDP 端口；选择 `public` 时，上游公网可达性和 NAT/安全组由部署环境负责。

## 当前状态

脚本入口和计划 03 的主要代码路径已实现；Unix mock 已通过，目标机验收状态如下：

1. `wgmesh.sh`：Linux/macOS 的参数解析、配置生成、WireGuard 操作和服务管理。
   已接入 Linux systemd 生命周期、macOS `utunN` 映射、显式 peer `/32` 路由、
   Endpoint 保护、MTU、Hub forwarding、状态对账，以及 Unix
   `external`/`managed` 防火墙策略。
2. `wgmesh.ps1`：Windows Hub/Node 的同等命令接口、WireGuard Tunnel Service、
   路由、MTU、配置/运行态 peer 漂移和 Endpoint 出口状态已接入；PowerShell/Windows
   实机检查待完成，Windows 防火墙继续使用 `external`。
3. `tests/smoke.sh` 和 `tests/firewall-smoke.sh`：不接触真实 WireGuard 或真实
   防火墙的 Unix mock 生命周期、路由、MTU、状态对账、回滚和防火墙后端检查已通过；
   `tests/powershell-parser.ps1` 覆盖 PowerShell AST、状态对账和漂移分支。

真实 nftables/pf、Windows Tunnel Service、重启恢复和 Hub+两 Node 的代表性
overlay 连通性仍按增量开发计划实施和验收；本轮没有修改远端机器或 K3s 配置。

## 文档

- [01 基础开发计划](docs/plans/01-wgmesh-base-development-plan.md)
- [02 Hub 中转增量计划](docs/plans/02-wgmesh-hub-relay-plan.md)
- [03 通用路由与可靠性增量计划](docs/plans/03-wgmesh-routing-and-reliability-plan.md)

## 支持平台

首版目标平台为 Linux、macOS、Windows；Android、iOS、BSD 不在计划内。Tailscale 和 `public` 是安装时二选一的 transport，不做静默 fallback。

## 隐私

示例只使用 `<PLACEHOLDER>`、候选私有网段、RFC 5737 地址和无效的 `FAKE_*`
fixture。候选私有网段仍需在目标机上确认未占用。不要把真实私钥、公钥、账号、
endpoint、token、Cookie、SSH key、主机名或日志写入仓库。

## 许可证

本子项目遵循仓库的 MIT License。

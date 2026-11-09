# wgmesh

`wgmesh` 是一组直接调用系统 WireGuard 工具的跨平台脚本，用于管理单 Hub、多节点 WireGuard 网络。

## 实现方式

- Linux、macOS 使用 `wgmesh.sh`。
- Windows 使用 `wgmesh.ps1`。
- 脚本直接执行，不需要编译产物或第三方运行库。
- 脚本直接调用 WireGuard 工具和服务管理器。
- 安装命令发现 WireGuard 工具缺失时，只会调用目标机器已经存在的包管理器尝试安装；
  不会假定 Homebrew 或 WinGet 存在，也不会安装包管理器、Tailscale、防火墙或其他
  系统组件。

## 首版范围

- Hub 使用 `host init` 初始化。
- 节点使用 `node join` 在节点本机加入。
- Hub 使用 `host add-node` 在 Hub 本机登记节点公钥。
- Hub 使用 `host remove-node` 在 Hub 本机撤销节点 peer。
- 支持安装时选择 `tailscale` 或 `public` endpoint。
- Hub 和节点分别在本机生成私钥，只通过命令参数交换公开密钥。
- Hub 与节点之间的 WireGuard overlay 通信属于首版范围。
- 不实现节点之间经 Hub 转发、`member_routes`、LAN 路由、full-tunnel、full-mesh 或现有地址透明转发。
- 不部署常驻 `wgmesh` 服务，不通过 SSH 远程卸载。
- 不提供在线踢出通知或公钥自动过期。

## 依赖

目标机器需要具备下列运行环境；WireGuard 工具可在安装命令中按平台自动补齐：

| 平台 | 脚本 | 需要的已有组件 |
| --- | --- | --- |
| Linux | `wgmesh.sh` | POSIX shell、`wg`、`wg-quick`、`ip`；缺少 WireGuard 工具时使用已有的 `apt-get`、`dnf`、`yum`、`apk` 或 `pacman` 安装；启用开机启动时需要 `systemctl` |
| macOS | `wgmesh.sh` | POSIX shell、`ifconfig`/`netstat`；缺少 WireGuard 工具时仅在检测到已有 Homebrew 后尝试安装；启用开机启动时需要 `launchctl` |
| Windows | `wgmesh.ps1` | PowerShell、`sc.exe`、系统自带 `Get-NetIPAddress`/`Get-NetRoute`；缺少 WireGuard 工具时仅在检测到已有 `winget.exe` 后尝试安装 WireGuard for Windows |

选择 `tailscale` 时，目标机器需要已连通同一 Tailscale 网络；选择 `public` 时，Hub endpoint 需要由公网或 NAT 环境提供可达性。脚本只使用命令中提供的 endpoint，不调用 Tailscale 管理 API。

macOS 仅安装 WireGuard.app 不满足脚本所需的命令行管理接口；脚本需要
`wireguard-tools` 和 `wireguard-go` 提供的 `wg`、`wg-quick`、`wireguard-go`。
Homebrew 不是 macOS 的系统默认组件；如果目标机没有 Homebrew，脚本会直接停止并
提示先手动准备 WireGuard 命令行工具，不会替用户安装 Homebrew。Windows 同理，
`winget.exe` 不是所有 Windows 镜像都保证存在；缺少它时脚本会提示手动安装
WireGuard for Windows 或 App Installer/WinGet。

## 命令接口

Linux/macOS：

```sh
./wgmesh.sh host init \
  --network-name <NETWORK_ID> \
  --node-id <HUB_ID> \
  --transport tailscale|public \
  --overlay-cidr <WG_CIDR> \
  --address <HUB_WG_CIDR> \
  --endpoint <REACHABLE_HUB_IP_OR_DNS:PORT>

./wgmesh.sh node join \
  --network-name <NETWORK_ID> \
  --node-id <NODE_ID> \
  --transport tailscale|public \
  --overlay-cidr <WG_CIDR> \
  --address <NODE_WG_CIDR> \
  --hub-endpoint <REACHABLE_HUB_IP_OR_DNS:PORT> \
  --hub-public-key <HUB_WG_PUBLIC_KEY>

./wgmesh.sh host add-node \
  --network-name <NETWORK_ID> \
  --node-id <NODE_ID> \
  --address <NODE_WG_CIDR> \
  --node-public-key <NODE_WG_PUBLIC_KEY>
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
PowerShell。任意命令后追加 `--help` 或 `-h` 可查看该脚本的用法。

执行 `host init`、`node join`、peer 增删或卸载时，如果缺少 WireGuard 工具，
脚本会先尝试使用已检测到的包管理器安装。Linux 使用可用的 `apt-get`、`dnf`、
`yum`、`apk` 或 `pacman`；macOS 仅使用已有 Homebrew；Windows 仅使用已有
`winget.exe`。包管理器不存在或安装失败时，脚本会在修改配置前停止并报告原因；
不会安装包管理器本身。`status` 只检查工具，不因查询状态而安装软件。

## 具体填写示例

下面用一组完整值说明每个占位符。该示例选择 `public`，overlay 使用候选私有
网段 `10.250.0.0/24`。它不是固定答案；脚本会在安装前检查本机地址、路由和
其他 `wgmesh` 状态，发现重叠就停止，实际部署时应换成所有目标机都未使用的
网段。`203.0.113.20` 是 RFC 5737 文档地址，真实部署时必须换成 Node 实际
能够访问的 Hub 公网 IP 或 DNS。

| 文档占位符 | 示例填写值 | 说明 |
| --- | --- | --- |
| `<NETWORK_ID>` | `example-mesh` | 网络名称；Hub、Node、`host add-node` 全部使用同一个值。 |
| `<HUB_ID>` | `hub` | Hub 的节点标识。 |
| `<NODE_ID>` | `node-a` | Node 的节点标识；同一网络中的每个 Node 使用不同值。 |
| `<WG_CIDR>` | `10.250.0.0/24` | 整个 WireGuard overlay 网段；只有确认未占用时才使用。 |
| `<HUB_WG_CIDR>` | `10.250.0.1/24` | Hub 在 overlay 中的地址。 |
| `<NODE_WG_CIDR>` | `10.250.0.2/32` | `node-a` 在 overlay 中的地址。 |
| `<REACHABLE_HUB_IP_OR_DNS:PORT>` | `203.0.113.20:51820` | Node 访问 Hub 的地址和 UDP 端口。 |
| `<HUB_WG_PUBLIC_KEY>` | `host init` 输出的公钥 | 复制 Hub 执行 `host init` 后输出的 `hub_public_key` 值。 |
| `<NODE_WG_PUBLIC_KEY>` | `node join` 输出的公钥 | 复制 Node 执行 `node join` 后输出的 `node_public_key` 值。 |

按上述示例，执行顺序如下。Hub 先执行：

```sh
sudo ./wgmesh.sh host init \
  --network-name example-mesh \
  --node-id hub \
  --transport public \
  --overlay-cidr 10.250.0.0/24 \
  --address 10.250.0.1/24 \
  --endpoint 203.0.113.20:51820
```

记下输出中的 `hub_public_key`，然后在 Node 本机执行：

```sh
sudo ./wgmesh.sh node join \
  --network-name example-mesh \
  --node-id node-a \
  --transport public \
  --overlay-cidr 10.250.0.0/24 \
  --address 10.250.0.2/32 \
  --hub-endpoint 203.0.113.20:51820 \
  --hub-public-key "<替换为上一步的 hub_public_key>"
```

记下 Node 输出中的 `node_public_key`，再回到 Hub 本机执行：

```sh
sudo ./wgmesh.sh host add-node \
  --network-name example-mesh \
  --node-id node-a \
  --address 10.250.0.2/32 \
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
| `--transport tailscale\|public` | 选择 endpoint 的承载网络。`tailscale` 要求两端通过同一 Tailscale 网络可达；`public` 要求通过公网地址或 NAT 映射可达。该参数只记录部署选择，脚本不会安装、配置或切换 Tailscale、公网 IP、防火墙或 NAT。 |
| `--overlay-cidr <WG_CIDR>` | WireGuard overlay 的 IPv4 网段，例如候选值 `10.250.0.0/24`。Hub 地址和所有 Node 地址必须位于其中；不能使用默认路由 `0.0.0.0/0`，并且安装前必须确认该网段未被本机网络或其他 `wgmesh` 网络使用。 |
| `--address <CIDR>` | 当前 Hub 或 Node 在 WireGuard overlay 上的地址。Hub 使用本机地址（例如 `10.250.0.1/24`）；Node 和 `host add-node` 使用节点地址，并且必须是 `/32`（例如 `10.250.0.2/32`）。 |
| `--no-autostart` | 可选开关。仍会创建配置并立即启动当前隧道，但不登记系统启动恢复；省略时默认启用开机/登录后恢复。该开关只适用于 `host init` 和 `node join`。 |

### `host init`

在 Hub 本机创建一个网络实例和 WireGuard 接口。

| 参数 | 含义 |
| --- | --- |
| `--network-name <NETWORK_ID>` | 继承通用规则中的网络标识；用于创建 Hub 本机的网络实例。 |
| `--node-id <HUB_ID>` | Hub 在该网络中的节点标识。 |
| `--transport tailscale\|public` | 继承通用规则中的传输选择；它描述 `--endpoint` 的可达网络。 |
| `--overlay-cidr <WG_CIDR>` | Hub 使用的 overlay 网段，必须与所有 Node 的 `node join` 保持一致。 |
| `--address <HUB_WG_CIDR>` | Hub 的 WireGuard 本机地址；地址部分必须位于 `--overlay-cidr` 内。 |
| `--endpoint <HOST:PORT>` | Hub 对 Node 提供的 WireGuard endpoint。`PORT` 同时是 Hub 的 WireGuard UDP 监听端口；IPv6 必须写成 `[IPv6]:PORT`。 |
| `--no-autostart` | 继承通用规则中的可选开关。 |

### `node join`

在 Node 本机创建一个网络实例。该命令只配置 Node，不会修改 Hub 的 peer 列表。

| 参数 | 含义 |
| --- | --- |
| `--network-name <NETWORK_ID>` | 必须与 Hub 使用的网络标识一致。 |
| `--node-id <NODE_ID>` | 当前 Node 的节点标识；同一 Hub 网络内应保持唯一。 |
| `--transport tailscale\|public` | 必须与 Hub 的部署选择一致，用于说明 `--hub-endpoint` 的可达网络。 |
| `--overlay-cidr <WG_CIDR>` | 必须与 Hub 的 overlay 网段一致。 |
| `--address <NODE_WG_CIDR>` | Node 的 WireGuard 本机地址；必须位于 overlay 网段内并使用 `/32`，例如 `10.250.0.2/32`。 |
| `--hub-endpoint <HOST:PORT>` | Node 访问 Hub 的 WireGuard endpoint，通常填写 Hub `host init` 的 `--endpoint` 原值；IPv6 必须写成 `[IPv6]:PORT`。 |
| `--hub-public-key <HUB_WG_PUBLIC_KEY>` | Hub 的 WireGuard 公钥，由 Hub 执行 `host init` 后输出，再通过人工渠道传给 Node；不能填写 Hub 私钥。 |
| `--no-autostart` | 继承通用规则中的可选开关。 |

### `host add-node`

在 Hub 本机登记一个已经执行过 `node join` 的 Node peer。

| 参数 | 含义 |
| --- | --- |
| `--network-name <NETWORK_ID>` | 要修改的 Hub 网络标识，必须是当前 Hub 已通过 `host init` 创建的网络。 |
| `--node-id <NODE_ID>` | 要登记的 Node 标识，必须与该 Node 执行 `node join` 时使用的值一致。 |
| `--address <NODE_WG_CIDR>` | 要登记的 Node 的 overlay 地址，必须位于 Hub 的 overlay 网段内并使用 `/32`；该地址会写入 Hub peer 的 `AllowedIPs`。 |
| `--node-public-key <NODE_WG_PUBLIC_KEY>` | Node 的 WireGuard 公钥，由 Node 执行 `node join` 后输出，再传给 Hub；不能填写 Node 私钥或 Hub 公钥。 |

### 管理命令和通用选项

| 命令或选项 | 含义 |
| --- | --- |
| `host remove-node --network-name <NETWORK_ID> --node-id <NODE_ID>` | 只在 Hub 本机撤销该 Node peer；不会远程操作 Node。 |
| `node uninstall --network-name <NETWORK_ID> --node-id <NODE_ID>` | 只在当前 Node 本机卸载，并校验 `node-id` 与已安装状态一致。 |
| `host uninstall --network-name <NETWORK_ID>` | 只在当前 Hub 本机卸载该网络及其已登记 peer。 |
| `status [--network-name <NETWORK_ID>]` | 查看一个网络或本机全部网络的状态。省略 `--network-name` 时列出全部本机状态。 |
| `--json` | 仅用于 `status`，将状态输出为 JSON；不能用于安装、登记或卸载命令。 |
| `--help` / `-h` | 输出命令用法并退出，不修改本机 WireGuard 或 wgmesh 状态。 |

脚本会校验 IPv4 CIDR、endpoint 端口（`1-65535`）和 WireGuard 公钥格式
（44 字符 Base64 文本）。参数中的私钥不会被接受；两端私钥都由脚本在各自机器上
本地生成。`host init` 和 `node join` 安装前会检查本机已有 IPv4 地址、非默认路由
以及其他 `wgmesh` 状态是否与 `--overlay-cidr` 重叠；检查命令缺失或发现冲突时会
停止，不会创建隧道。`node join` 完成后不会自动修改 Hub，必须再把 Node 公钥和地址传给
管理员，由管理员在 Hub 本机执行 `host add-node`。

管理命令：

```text
status [--network-name <NETWORK_ID>] [--json]
host remove-node --network-name <NETWORK_ID> --node-id <NODE_ID>
node uninstall --network-name <NETWORK_ID> --node-id <NODE_ID>
host uninstall --network-name <NETWORK_ID>
```

`node join` 只配置节点本机，不会自动登记 Hub。管理员需要把节点公钥传给 Hub，并在 Hub 本机执行 `host add-node`。`host remove-node` 只修改 Hub 本机；它不会远程卸载节点，也不会向节点发送“已被踢出”消息。

网络参数不使用 TOML/JSON 文件传入。脚本会生成 WireGuard 后端所需的 `.conf` 文件，并保存最小的本机状态用于 `status`、幂等判断和卸载；这些文件由脚本维护，不作为用户配置接口。`--json` 仅控制 `status` 输出。

## 当前状态

脚本入口已实现；跨平台真实隧道验收仍需在对应目标系统完成：

1. `wgmesh.sh`：Linux/macOS 的参数解析、配置生成、WireGuard 操作和服务管理。
2. `wgmesh.ps1`：Windows 的同等命令接口和 WireGuard Tunnel Service 操作。
3. `tests/smoke.sh`：不接触真实 WireGuard 的 Unix mock 生命周期检查。

首版只保证 Hub↔Node 通信，不实现或验收节点之间经 Hub 转发的 overlay 流量。

## 文档

- [开发计划](docs/plans/wgmesh-development-plan.md)
- [脚本版 CLI runbook](docs/plans/wgmesh-cli-example-runbook.md)

## 支持平台

首版目标平台为 Linux、macOS、Windows；Android、iOS、BSD 不在计划内。Tailscale 和 `public` 是安装时二选一的 transport，不做静默 fallback。

## 隐私

示例只使用 `<PLACEHOLDER>`、候选私有网段、RFC 5737 地址和无效的 `FAKE_*`
fixture。候选私有网段仍需在目标机上确认未占用。不要把真实私钥、公钥、账号、
endpoint、token、Cookie、SSH key、主机名或日志写入仓库。

## 许可证

本子项目遵循仓库的 MIT License。

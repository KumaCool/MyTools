# wgmesh 脚本开发计划

日期：2026-11-09

状态：脚本实现进行中；跨平台实测尚未完成。

## 目标

使用系统自带的脚本运行环境和 WireGuard 工具，在 Linux、macOS、Windows 管理单 Hub、多节点 WireGuard 网络。

- Linux、macOS：`wgmesh.sh`，使用 POSIX shell。
- Windows：`wgmesh.ps1`，使用 Windows PowerShell。
- 两个入口提供相同的子命令和参数语义，平台操作由各自脚本适配。
- 不需要编译步骤、第三方脚本运行时或第三方库；不使用 `jq`、Python 等额外工具。
- 脚本直接调用已安装的 WireGuard 后端及系统服务管理器，不部署常驻 `wgmesh` 服务。

## 网络范围

- 一个 Hub 和多个 Node。
- 每次 `host init` 或 `node join` 通过命令参数选择 `tailscale` 或 `public`，同一网络保持一致。
- `tailscale` endpoint 使用已连通的 Tailscale 网络地址；`public` endpoint 使用可从节点访问的公网 IP/DNS 与 UDP 端口。NAT/端口可达性由部署环境提供。
- Hub 与 Node 通过 WireGuard overlay 地址通信。
- `member_routes`、节点后 LAN 路由、full-tunnel、full-mesh 和原地址透明转发不在首版范围。
- 安装命令发现 WireGuard 工具缺失时，只使用目标机已经存在的包管理器尝试安装；
  不假定 Homebrew 或 WinGet 存在，不安装包管理器、Tailscale 或防火墙组件，
  也不静默切换 transport。没有可用包管理器时在写入配置前停止。
- 不通过 SSH 执行远程卸载；卸载只在被安装的机器本机运行。

首版只实现和验收 Hub↔Node 通信，不配置节点间转发，也不宣称 Node↔Node 互通。

## 依赖

| 平台 | 运行时 | WireGuard 和启动管理组件 |
| --- | --- | --- |
| Linux | POSIX shell | `wg`、`wg-quick`、`ip`；缺少 WireGuard 工具时使用已有 `apt-get`、`dnf`、`yum`、`apk` 或 `pacman` 安装；默认开机启动需要 `systemctl` |
| macOS | POSIX shell | 系统自带 `ifconfig`/`netstat`；缺少 WireGuard 工具时仅在检测到已有 Homebrew 后尝试安装；默认开机启动需要 `launchctl` |
| Windows | PowerShell | `sc.exe`，以及系统自带 `Get-NetIPAddress`/`Get-NetRoute`；缺少 WireGuard 工具时仅在检测到已有 `winget.exe` 后尝试安装 WireGuard for Windows |

macOS 单独安装 WireGuard.app 不够；实现调用命令行工具。Homebrew 不是 macOS
默认组件，没有 Homebrew 时需要先手动安装 WireGuard 命令行工具。Windows 的
`winget.exe` 也按可选工具处理，没有时需要先手动安装 WireGuard for Windows
或 App Installer/WinGet。选择 Tailscale transport 时，机器需预先加入同一
Tailscale 网络。`wgmesh` 不调用 Tailscale 管理接口。

## 命令合同

所有网络参数通过命令行传入，不维护 TOML/JSON 网络配置文件。两个脚本支持相同命令。

```text
host init
  --network-name ID --node-id ID --transport tailscale|public
  --overlay-cidr CIDR --address CIDR --endpoint HOST:PORT [--no-autostart]

node join
  --network-name ID --node-id ID --transport tailscale|public
  --overlay-cidr CIDR --address CIDR --hub-endpoint HOST:PORT
  --hub-public-key KEY [--no-autostart]

host add-node
  --network-name ID --node-id ID --address CIDR --node-public-key KEY

host remove-node --network-name ID --node-id ID
node uninstall --network-name ID --node-id ID
host uninstall --network-name ID
status [--network-name ID] [--json]
```

- `host init` 在 Hub 本机生成并保存私钥，输出 Hub 公钥。
- `node join` 在节点本机生成并保存私钥，接收 Hub 公钥，输出节点公钥。
- 管理员将节点公钥通过已有人工渠道交给 Hub；Hub 本机执行 `host add-node` 后才接受该节点。
- `host remove-node` 只从 Hub 撤销 peer；节点再次加入仍须 Hub 本机重新登记。
- `--json` 仅用于状态输出。
- WireGuard `.conf` 是脚本为系统后端生成和维护的运行文件，不是用户维护的网络配置接口。
- `--network-name` 是唯一的网络参数名称，不再接受 `--network`。
- `status` 只检查当前工具，不因读取状态而安装软件；安装、peer 变更和卸载命令
  缺少 WireGuard 工具时才触发已检测到的包管理器安装，没有包管理器时直接报错。

## 状态和安全行为

- 更改系统前验证参数、管理员权限、平台命令、目标配置、地址/接口冲突和所需启动能力。
- `host init` 和 `node join` 创建隧道前检查本机已有 IPv4 地址、非默认路由以及其他
  `wgmesh` 状态是否与 `--overlay-cidr` 重叠；检查命令缺失时停止，重复执行同一网络
  时跳过对自身已记录状态的误报。
- 只改动脚本创建并记录的资源。遇到未记录或无法确认属于 `wgmesh` 的配置时停止，不接管、不覆盖。
- 相同参数重复运行返回 `NOOP`；删除不存在的 peer 或重复卸载也不造成额外变更。
- 私钥仅在所属机器本地由 `wg` 生成并写入受保护的配置/状态位置；不放入命令参数、普通输出或日志。
- 默认启用系统启动恢复；`--no-autostart` 仅安装当前会话所需配置。
- 失败时清理本次新建的资源，或恢复本次变更前已记录的配置与服务状态。恢复失败时保留必要备份并报告其位置。
- `host remove-node` 不提供在线踢出通知。WireGuard peer 被撤销后，节点侧只能观察到握手/连接不可用；没有管理监听通道就不能可靠判断原因是被踢出还是普通网络故障。
- 首版不设置公钥自动过期；节点重新加入依赖 Hub 本机 `host add-node` 人工登记。

## 开发任务

| TASK | 状态 | 交付 |
| --- | --- | --- |
| TASK-00 命令合同与共享行为 | IMPLEMENTED | 参数、状态、冲突、幂等、私钥和失败恢复约定 |
| TASK-01 Linux/macOS 脚本 | IMPLEMENTED | 根目录 `wgmesh.sh`、Unix mock smoke 和两平台适配代码 |
| TASK-02 Windows 脚本 | IMPLEMENTED_UNVERIFIED | 根目录 `wgmesh.ps1` 与 WireGuard Tunnel Service 适配；待 Windows 实机检查 |
| TASK-03 最小集成与文档 | IN_PROGRESS | 三平台基本生命周期、一次 Hub/Node 连通、runbook 对齐 |

### TASK-00 命令合同与共享行为

- 依照本计划实现严格参数解析、必填项检查、格式校验、帮助和状态输出。
- 限制 ID、地址、endpoint 和公开密钥输入；脚本不得将参数拼接后交给 `eval` 或 PowerShell 动态执行。
- 确定两平台一致的配置命名、状态字段、错误退出码和 `NOOP` 行为。
- 明确安全的临时文件、权限设置和失败清理流程；私钥不得通过进程参数传递。
- 不添加独立 `doctor` 命令、网络配置文件格式或 enrollment 服务。

### TASK-01 Linux/macOS 脚本

- 使用 POSIX shell 实现公共命令解析和本机状态检查；根据 `uname` 进入 Linux 或 macOS 后端。
- Linux 调用 `wg`/`wg-quick`，开机启动调用 `systemctl`；macOS 调用 `wg`/`wg-quick`/`wireguard-go`，开机启动调用 `launchctl`。
- 实现 Hub 初始化、Node 加入、peer 增删、状态、本机卸载。
- 先检查所需工具、权限和资源冲突；仅在 WireGuard 工具缺失时调用已有包管理器，
  不安装包管理器或其他网络组件。
- 用 `sh -n` 检查语法，并在 Linux、macOS 各执行一次最小本机生命周期。
- `tests/smoke.sh` 使用临时 mock 命令覆盖初始化、幂等、peer 增删、状态和卸载；不代表真实隧道已建立。

### TASK-02 Windows 脚本

- 使用 PowerShell 原生命令解析参数并提供与 Unix 脚本一致的命令接口。
- 使用 WireGuard for Windows 安装、启动、查询和移除 tunnel service；不安装其他脚本运行时。
- 实现 Hub 初始化、Node 加入、peer 增删、状态、本机卸载。
- 验证管理员权限、工具存在和目标配置冲突；不改动非 `wgmesh` 服务。
- 在 Windows 上执行脚本解析检查及一次最小本机生命周期。
- 当前开发机没有 PowerShell 和 WireGuard for Windows，因此 Windows 解析和服务生命周期仍待目标机执行。

### TASK-03 最小集成与文档

- Linux、macOS、Windows 分别覆盖一次核心本机生命周期和一次启动恢复路径，不要求每个平台重复 Hub/Node 全拓扑。
- 使用两台可用机器完成一次 Hub/Node 公钥交换、Hub peer 登记和 overlay 地址连通。
- `tailscale` 与 `public` 都检查 endpoint 参数可生成对应配置；只在一个可用 transport 上完成实网互通。
- 验证重复命令、配置冲突和一次失败清理路径；不要求六种 OS/transport 组合全量实测。
- 更新 README 和 runbook，只记录实际观察到的结果；预期输出明确标为示例。

## 首版验收

- 两个脚本都能通过相同参数合同执行 Hub 初始化、Node 加入、Hub 登记/撤销、状态和本机卸载。
- Linux、macOS、Windows 均完成一次本机核心生命周期；启动恢复至少各覆盖一次。
- 至少完成一次 Hub/Node WireGuard 握手及 overlay 地址连通。
- Hub 和 Node 的私钥在各自本机生成；加入和登记只交换公开密钥。
- 缺少系统组件、权限不足或资源冲突时，脚本不覆盖已有配置并返回明确错误。
- 重复执行可识别为 `NOOP`；一次失败变更可清理或恢复本次变更前的状态。
- 不将节点间转发、LAN 路由、full-tunnel、full-mesh、在线踢出通知或自动过期纳入验收。

## 难度与交接

脚本方案开发难度估计为 **65/100**。不需要构建或额外运行库，但要在 POSIX shell 与 PowerShell 间保持一致的命令语义，并分别处理 Linux、macOS、Windows 的 WireGuard 服务生命周期、权限、持久配置和失败恢复。核心难点在系统行为差异与跨平台实测，不在脚本语法本身。

交接结论：TASK-00 和 TASK-01 已实现并完成 Unix mock 检查；TASK-02 已实现但未在 Windows 实机验证；TASK-03 仍需在 Linux、macOS、Windows 目标机完成真实隧道验收。

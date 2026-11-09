# wgmesh 脚本版 CLI 示例执行记录

> 本文是脚本的目标操作顺序。示例输出是格式示例；真实 WireGuard 生命周期仍需在目标系统执行。

## 前置条件

- Linux、macOS、Windows 目标机具备该平台的脚本运行环境。
- Linux 需要 `ip`；缺少 `wg` 或 `wg-quick` 时脚本会使用已有的 `apt-get`、`dnf`、
  `yum`、`apk` 或 `pacman` 安装 `wireguard-tools`；默认开机启动还需要 `systemctl`。
- macOS 需要系统自带的 `ifconfig` 和 `netstat`；缺少 `wg`、`wg-quick` 或
  `wireguard-go` 时脚本仅在检测到已有 Homebrew 后尝试安装；默认开机启动还需要
  `launchctl`。仅安装 WireGuard.app 不保证脚本所需的命令行工具已经出现在当前
  shell 的 `PATH` 中。
- Windows 需要 PowerShell、`sc.exe` 以及系统自带的 `Get-NetIPAddress` 和
  `Get-NetRoute`；缺少 WireGuard 工具时脚本仅在检测到已有 `winget.exe` 后尝试
  安装 WireGuard for Windows。
- 目标机具备管理员权限。Homebrew 和 `winget.exe` 都按可选工具处理；脚本不安装
  包管理器、Tailscale、防火墙或其他系统组件。缺少包管理器时先手动安装
  WireGuard 工具，再重新执行命令。
- `tailscale` transport 要求各机器已连入同一 Tailscale 网络；`public` transport 要求 Hub endpoint 可从节点访问。
- 示例使用候选私有网段 `10.250.0.0/24`；它不是固定答案，脚本安装前会检查本机
  IPv4 地址、非默认路由和其他 `wgmesh` 状态，发现重叠时停止，实际使用时应换成
  所有目标机都未使用的 overlay 网段。
- 本文只包含 Hub↔Node 连通流程；不实现或测试节点间转发、LAN 路由、默认路由或 full-tunnel。

## 示例参数

```text
NETWORK_ID=example-mesh
HUB_ID=hub
TRANSPORT=tailscale        # tailscale 或 public
OVERLAY_CIDR=10.250.0.0/24
HUB_ADDRESS=10.250.0.1/24
NODE_A_ADDRESS=10.250.0.2/32
HUB_ENDPOINT=<TAILSCALE_HUB_IP>:51820
```

公网模式只把 `TRANSPORT` 改为 `public`，并将 endpoint 换成可达的公网地址；示例地址 `203.0.113.20` 仅用于文档。

## 1. 准备脚本

Linux/macOS 将 `wgmesh.sh` 放到目标机并赋予执行权限：

```sh
chmod 0755 ./wgmesh.sh
```

Windows 将 `wgmesh.ps1` 放到目标机，用管理员 PowerShell 执行。脚本直接运行，不需要构建、安装包或额外运行时。

## 2. 在 Hub 本机初始化

Linux/macOS：

```sh
sudo ./wgmesh.sh host init \
  --network-name "$NETWORK_ID" \
  --node-id "$HUB_ID" \
  --transport "$TRANSPORT" \
  --overlay-cidr "$OVERLAY_CIDR" \
  --address "$HUB_ADDRESS" \
  --endpoint "$HUB_ENDPOINT"
```

Windows：

```powershell
.\wgmesh.ps1 host init `
  --network-name $env:NETWORK_ID `
  --node-id $env:HUB_ID `
  --transport $env:TRANSPORT `
  --overlay-cidr $env:OVERLAY_CIDR `
  --address $env:HUB_ADDRESS `
  --endpoint $env:HUB_ENDPOINT
```

目标输出：

```text
network_id=example-mesh
role=host
node_id=hub
transport=tailscale
endpoint=<TAILSCALE_HUB_IP>:51820
address=10.250.0.1/24
hub_public_key=<HUB_WG_PUBLIC_KEY>
autostart=enabled
state=CONFIGURED
```

Hub 私钥只写入 Hub 本机受保护的位置；输出的 `hub_public_key` 用于节点加入。

临时安装可以追加：

```text
--no-autostart
```

## 3. 在节点本机加入

每个节点都在本机执行一次。节点私钥在本机生成，Hub 公钥通过参数传入。

Linux/macOS：

```sh
sudo ./wgmesh.sh node join \
  --network-name "$NETWORK_ID" \
  --node-id node-a \
  --transport "$TRANSPORT" \
  --overlay-cidr "$OVERLAY_CIDR" \
  --address "$NODE_A_ADDRESS" \
  --hub-endpoint "$HUB_ENDPOINT" \
  --hub-public-key "<HUB_WG_PUBLIC_KEY>"
```

Windows：

```powershell
.\wgmesh.ps1 node join `
  --network-name $env:NETWORK_ID `
  --node-id node-a `
  --transport $env:TRANSPORT `
  --overlay-cidr $env:OVERLAY_CIDR `
  --address $env:NODE_A_ADDRESS `
  --hub-endpoint $env:HUB_ENDPOINT `
  --hub-public-key "<HUB_WG_PUBLIC_KEY>"
```

目标输出：

```text
network_id=example-mesh
role=node
node_id=node-a
transport=tailscale
endpoint=<TAILSCALE_HUB_IP>:51820
address=10.250.0.2/32
node_public_key=<NODE_A_WG_PUBLIC_KEY>
autostart=enabled
state=CONFIGURED
```

`node join` 只配置节点本机，不会自动登记 Hub。Node B、Node C 重复同一命令并替换 `node-id`、`address` 和节点公钥。

## 4. 在 Hub 本机登记节点

管理员把节点输出的公钥通过已有人工渠道传到 Hub，然后在 Hub 本机执行：

Linux/macOS：

```sh
sudo ./wgmesh.sh host add-node \
  --network-name "$NETWORK_ID" \
  --node-id node-a \
  --address "$NODE_A_ADDRESS" \
  --node-public-key "<NODE_A_WG_PUBLIC_KEY>"
```

Windows：

```powershell
.\wgmesh.ps1 host add-node `
  --network-name $env:NETWORK_ID `
  --node-id node-a `
  --address $env:NODE_A_ADDRESS `
  --node-public-key "<NODE_A_WG_PUBLIC_KEY>"
```

目标输出：

```text
network_id=example-mesh
node_id=node-a
peer=committed
allowed_ips=10.250.0.2/32
state=CONFIGURED
```

重复提交完全相同的参数返回 `NOOP`；相同 `node-id` 的公钥或地址不同则停止并不覆盖原 peer。

## 5. 状态和最小连通检查

Hub 或节点本机执行：

Linux/macOS：

```sh
sudo ./wgmesh.sh status --network-name "$NETWORK_ID" --json
```

Windows：

```powershell
.\wgmesh.ps1 status --network-name $env:NETWORK_ID --json
```

目标状态字段：

```json
{
  "network_id": "example-mesh",
  "role": "node",
  "node_id": "node-a",
  "transport": "tailscale",
  "interface": "wgmesh-example-mesh",
  "address": "10.250.0.2/32",
  "autostart": true,
  "state": "ACTIVE",
  "handshake": "<timestamp>"
}
```

至少测试 Node 到 Hub 的 WireGuard 地址：

```sh
ping -c 3 10.250.0.1
```

Windows 使用：

```powershell
ping 10.250.0.1
```

Node A 到 Node B 的连通不属于首版验收。

## 6. 启动恢复

默认安装启用系统启动恢复。每个平台完成一次即可：

```text
重启目标机
再次执行 status --network-name <NETWORK_ID> --json
预期 state=ACTIVE 且 autostart=true
```

带 `--no-autostart` 的安装不纳入启动恢复验收，重启后预期为接口未运行。

## 7. 撤销和本机卸载

先在 Hub 本机撤销 peer：

```text
host remove-node --network-name <NETWORK_ID> --node-id node-a
```

预期：

```text
peer_revoked=done
state=CONFIGURED
```

再在 node-a 本机执行：

```text
node uninstall --network-name <NETWORK_ID> --node-id node-a
```

预期：

```text
interface_removed=true
autostart_removed=true
state=ABSENT
```

Hub 本机卸载：

```text
host uninstall --network-name <NETWORK_ID>
```

`host remove-node` 不触发远程卸载，也没有远程 SSH 参数。节点被撤销后没有在线“已被踢出”通知；脚本只能在本机状态查询中显示当前 WireGuard 状态。

## 8. 幂等和冲突

相同命令重复执行：

```text
state=CONFIGURED
result=NOOP
exit_code=0
```

卸载已不存在的网络返回 `state=ABSENT`、`result=NOOP`。

安装前检查本机 IPv4 地址、非默认路由和其他 `wgmesh` 状态是否与
`--overlay-cidr` 重叠。缺少平台检查命令或发现冲突时：

```text
overlay-cidr ... overlaps existing ...
exit_code!=0
```

脚本不得覆盖无法确认归属的配置，也不得自动安装缺少的包管理器或其他系统组件。

## 9. 已执行的检查

在当前 macOS 开发机上已执行：

```sh
sh -n wgmesh.sh
dash -n wgmesh.sh
./tests/smoke.sh
```

结果：Unix shell 语法检查和覆盖 macOS/Linux 分支的 mock 生命周期检查通过。当前开发机没有真实 WireGuard 工具、PowerShell 或 Windows WireGuard，因此没有把真实三平台隧道验收写成已完成。

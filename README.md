# OpenVPN 2.7 服务端部署教程

在 Debian/Ubuntu 服务器上一键部署 OpenVPN 服务端，并用配套脚本管理客户端。克隆到任意目录即可使用，所有命令都在项目目录下用 `./xxx.sh` 运行。

## 最终方案

| 项目 | 配置 |
|---|---|
| 版本 | OpenVPN 2.7.x（官方 apt 源 stable 分支） |
| 监听 | **同一进程**同时监听 UDP 1194 和 TCP 1194 |
| 网段 | `10.93.1.0/24`（可配置，掩码固定 /24），网关 `.1` |
| 地址规划 | `.2–.99` 动态池（可配置）；池外的 `.2–.254` 为固定 IP，`clientN` → `10.93.1.N` |
| 证书 | ECDSA secp384r1，有效期 10 年，带 CRL 吊销列表 |
| 加密 | TLS ≥1.2，`tls-crypt` 保护控制通道，数据通道 AES-256-GCM / AES-128-GCM / CHACHA20-POLY1305 |
| 路由 | 全局代理，推送 DNS 1.1.1.1 / 8.8.8.8 |
| NAT | systemd drop-in，规则随服务启停 |
| 客户端 | 内联式 `.ovpn`，先连 UDP，连不上自动切到 TCP |

## 文件

```
openvpn-deploy/
├── install-openvpn.sh   # 一键部署（运行一次）
├── add-client.sh        # 新增客户端
├── revoke-client.sh     # 吊销客户端并清理残留
├── uninstall-openvpn.sh # 一键卸载（撤销部署的全部改动）
├── clients/             # 生成的客户端 .ovpn（运行后自动创建，已在 .gitignore 中忽略）
└── README.md            # 本教程
```

部署时还会在系统目录写入以下文件，与项目放在哪里无关：

```
/etc/openvpn/easy-rsa/   # PKI（CA、证书、CRL）
/etc/openvpn/server/     # 服务端配置 server.conf、ccd 固定 IP
/etc/openvpn/ovpn.env    # 公网IP/网段/动态池/端口，add-client.sh 从这里读取
```

> 管理脚本通过自身所在路径定位 `clients/`，所以可以在任意目录调用（如 `/opt/openvpn-deploy/add-client.sh 100`），但请不要把脚本单独拷走、和 `clients/` 分开。

---

## 1. 部署

前提：Ubuntu 22.04/24.04 或 Debian 12，用 root 登录，服务器能访问外网。

**① 获取项目**（在服务器上执行，目录随意）

```bash
git clone https://github.com/cjdxb/openvpn-deploy.git openvpn-deploy
cd openvpn-deploy
```

没有 git 的话，也可以在本机 `scp -r openvpn-deploy root@<服务器IP>:<任意目录>` 上传整个目录。

**② 运行**

```bash
./install-openvpn.sh
```

> 如果提示 `Permission denied`（比如用 scp 或 zip 拷贝丢了执行权限），先执行 `chmod +x *.sh`。

运行时会依次询问 **VPN 网段** 和 **客户端动态地址池**，直接回车即用默认值：

```
VPN 网段（掩码固定 /24） [默认 10.93.1.0/24]: 
客户端动态地址池 [默认 10.93.1.2-10.93.1.99]: 
监听端口（UDP+TCP 共用） [默认 1194]: 
```

也可以用参数一次性指定，指定了的项不会再询问：

```bash
./install-openvpn.sh --net 10.93.2.0/24 --pool 10.93.2.2-10.93.2.99 --port 1194
```

| 参数 | 环境变量 | 默认值 | 说明 |
|---|---|---|---|
| `--net` | `VPN_NET`（兼容旧的 `VPN_PREFIX`） | `10.93.1.0/24` | VPN 网段，掩码固定 /24，也可写成 `10.93.1` |
| `--pool` | `VPN_POOL` | `.2-.99` | 动态地址池，写全 IP 或只写最后一段（如 `2-99`）均可；不能占满 `.2-.254` |
| `--port` | `PORT` | `1194` | 监听端口，UDP 和 TCP 共用，范围 1-65535 |

优先级：参数 > 环境变量 > 交互输入 > 默认值。非交互运行（stdin 不是终端，如 `./install-openvpn.sh < /dev/null`）时不询问，直接用默认值。`./install-openvpn.sh --help` 查看用法。

公网 IP 和出口网卡会自动探测。服务器在 NAT 后面（探测到的是内网 IP）或要指定出口网卡时，可以用环境变量指定：

```bash
PUBLIC_IP=1.2.3.4 WAN_IF=eth0 ./install-openvpn.sh --net 10.93.2.0/24
```

| 变量 | 默认值 | 说明 |
|---|---|---|
| `PUBLIC_IP` | 默认路由的源地址 | 写进客户端 `remote` 的地址 |
| `WAN_IF` | 默认路由的网卡 | NAT 出口网卡 |

成功后最后会输出 `==> 部署完成`。如果检测到 `/etc/openvpn/easy-rsa/pki` 已存在，脚本会直接退出，避免覆盖现有证书。

**③ 放行端口**：在云厂商的安全组或防火墙里放行 **UDP 和 TCP 的监听端口（默认 1194）入站**。服务器本机的 ufw 如果开着，脚本会自动放行。

**防火墙后端**：安装时如果检测到 `nftables` 服务在运行，NAT 规则会写进独立的 nftables 表 `ip openvpn`（规则文件 `/etc/openvpn/server/nat.nft`）；否则用 iptables。nftables 模式下，如果你自己的 nftables 配置里 input/forward 链默认 drop，要自己放行监听端口和 `ovpn0` 的转发；执行 `systemctl restart nftables` 会清掉 `ip openvpn` 表，之后需要重启 `openvpn-server@server`。

## 2. 新增客户端

```bash
./add-client.sh 100
```

- 签发证书 `client100`，固定 IP `10.93.1.100`
- 生成 `clients/client100.ovpn`（项目目录下）；加 `--mikrotik` 参数（`./add-client.sh 100 --mikrotik`）时额外生成 MikroTik 专用的 `clients/client100-mikrotik.ovpn`
- 编号可用 2–254 中**动态池以外**的值（默认池 `.2–.99` 时即 100–254）；编号已存在时脚本会报错退出
- **不用重启服务**

下载到本机：

```bash
scp root@<服务器IP>:<项目目录>/clients/client100.ovpn .
```

把 `.ovpn` 导入 OpenVPN Connect（Windows/macOS/iOS/Android）或 Tunnelblick 就能用。**每台设备单独用一个编号**，不要共用。

### MikroTik 路由器

RouterOS 的 OpenVPN 是自己实现的，通用 `.ovpn` 导不进去（不支持 `data-ciphers` 协商、只认一个 `remote`），要用 `./add-client.sh 100 --mikrotik` 生成的 `client100-mikrotik.ovpn`：

- 需要 **RouterOS 7.17 及以上**（tls-crypt 从 7.17 开始支持）
- 只走 UDP，固定 `cipher AES-256-GCM`；需要 TCP 时导入后把接口的 `protocol` 改成 `tcp`
- 把文件传到路由器的 Files 里，然后执行（RouterOS 要求填用户名，TLS 认证下会被忽略，随便填）：

```
/interface/ovpn-client/import-ovpn-configuration file-name=client100-mikrotik.ovpn ovpn-user=client100 skip-cert-import=no
```

服务端推送的 `redirect-gateway` 会把路由器的默认路由切到 VPN，如果只想让部分流量走 VPN，导入后把接口的 `add-default-route` 关掉，再自己配路由。

## 3. 吊销客户端

```bash
./revoke-client.sh client100
```

脚本会做这些事：
1. 吊销证书，重新生成 CRL 并更新到服务端
2. 删除 `.ovpn`、ccd 固定 IP 文件、吊销后的私钥和证书请求（req）
3. 删除 `ipp.txt` 里的记录（会重启服务，断线约 3 秒）

脚本会保留 `pki/index.txt` 里的 `R` 记录和吊销的证书，作为审计记录。**千万不要手动删 `R` 记录**，否则下次生成的 CRL 里会少掉这张证书，等于让它重新能用。

## 4. 验证

```bash
systemctl status openvpn-server@server            # active (running)
ss -lnup | grep 1194; ss -lntp | grep 1194        # UDP 和 TCP 都在监听，同一个 pid
ip -4 addr show ovpn0                             # 10.93.1.1/24
iptables -t nat -S POSTROUTING | grep 10.93.1     # MASQUERADE 规则（iptables 模式）
nft list table ip openvpn                         # MASQUERADE 规则（nftables 模式）
journalctl -u openvpn-server@server -n 30         # 不应有 WARNING / DEPRECATED
```

在服务器本机测试拨号。加了 `--route-nopull`，不改本机路由，SSH 不会断：

```bash
timeout 12 openvpn --config clients/client100.ovpn --route-nopull --dev tun9 | grep -E "ifconfig|Initialization"
# 应看到 ifconfig 10.93.1.100 255.255.255.0 和 Initialization Sequence Completed
```

测试 TCP：把 `.ovpn` 里的 udp 那行 `remote` 删掉，再用上面的命令拨一次。

## 5. 常用运维

| 操作 | 命令 |
|---|---|
| 查看在线客户端 | `cat /var/log/openvpn/openvpn-status.log` |
| 改某客户端的固定 IP | 修改 `/etc/openvpn/server/ccd/clientN`，下次连接时生效 |
| 修改 server.conf 后 | `systemctl restart openvpn-server@server`（所有客户端会断开重连） |
| 修改公网 IP/端口 | 修改 `/etc/openvpn/ovpn.env` 和 `server.conf`，重启服务，重新生成并分发 `.ovpn` |
| 备份 | `tar czf /root/openvpn-backup.tgz /etc/openvpn clients && chmod 600 /root/openvpn-backup.tgz`（在项目目录下执行） |

## 6. 注意事项

- **easy-rsa 3.0.x 不读取 `vars` 文件**，加密参数必须用环境变量传，不然会生成 RSA-2048 证书。脚本已经处理，手动操作时要记得加。
- **2.7 已废弃的选项**：`persist-key`（现在是默认行为）、`ecdh-curve`（OpenSSL 3 下不生效）。服务端配置里不要写，否则会出现 DEPRECATED 或 WARNING。客户端 `.ovpn` 保留了 `persist-key`，是为了兼容旧版客户端。
- **删改 `ipp.txt` 前要先停服务**：运行中的服务会把内存里的记录写回这个文件。
- **吊销不会立刻踢掉在线连接**：CRL 只在握手时检查，要等下次重新协商（默认 1 小时）或重连才生效。需要立刻生效就重启服务。
- **优先用 UDP**：TCP 套 TCP 遇到丢包时会两层一起重传（TCP meltdown），所以 TCP 只作备用。
- **`.ovpn` 和备份文件里都有私钥**，权限要设为 600，不要提交到 git，也不要放到公开的地方。项目的 `.gitignore` 已忽略 `clients/` 和 `*.ovpn`。
- 本机装了 Docker 也没问题，FORWARD 规则用 `-I` 插在链首，不会被 Docker 的规则拦下。

## 7. 卸载

```bash
./uninstall-openvpn.sh        # 输入 yes 确认
./uninstall-openvpn.sh -y     # 跳过确认（非交互运行时必须加）
```

脚本会做这些事：
1. 把 `/etc/openvpn` 和 `clients/` 备份到 `/root/openvpn-backup-<时间>.tgz`（权限 600，内含私钥）
2. 停止并禁用服务（iptables NAT/FORWARD 规则或 nftables 的 `ip openvpn` 表随之删除），删除 systemd drop-in
3. 删除 ufw 放行规则、`/etc/sysctl.d/99-openvpn.conf`
4. 删除 PKI、服务端配置、`ovpn.env`、`/var/log/openvpn`、`clients/`
5. 卸载 `openvpn`、`easy-rsa`，删除官方 apt 源和密钥

注意：
- **卸载后 CA 无法找回，已发出的 `.ovpn` 全部失效**。要恢复只能从备份解压回原位置：`tar xzf /root/openvpn-backup-*.tgz -C /`，再重装软件包。
- IP 转发不会立即关闭（Docker 等可能依赖），重启后恢复系统默认。
- `curl`、`ca-certificates`、`iptables`（如果安装时装了）会保留。
- 云厂商安全组里的 UDP/TCP 1194 规则需要自己去删。

## 8. 回退到发行版自带版本

```bash
rm /etc/apt/sources.list.d/openvpn-aptrepo.list && apt-get update
apt-get install --allow-downgrades openvpn=<apt-cache policy openvpn 里的发行版版本>
```

回退到 2.5 之前，先把 `server.conf` 开头两行 `local` 改回 `port 1194` + `proto udp`（2.5 只支持单协议），并把客户端 `.ovpn` 里 tcp 那行 `remote` 删掉。

#!/bin/bash
# OpenVPN 2.7 服务端一键部署（Ubuntu 22.04/24.04、Debian 12）
#
# 最终方案：
#   - 官方源 OpenVPN 2.7.x，单进程同时监听 UDP+TCP 同一端口
#   - ECDSA secp384r1 PKI + tls-crypt，证书有效期 10 年
#   - VPN 网段 a.b.c.0/24（默认 10.93.1.0/24）：.1 网关，动态池默认 .2-.99，池外 .2-.254 为固定 IP（clientN -> .N）
#   - 全局代理（redirect-gateway），NAT 规则随服务启停
#
# 用法（root）：
#   bash install-openvpn.sh                                   # 未指定的网段/地址池会交互询问，直接回车用默认值
#   bash install-openvpn.sh --net 10.93.2.0/24 --pool 10.93.2.2-10.93.2.99
#   PUBLIC_IP=1.2.3.4 VPN_NET=10.93.1.0/24 VPN_POOL=2-99 PORT=1194 bash install-openvpn.sh
set -euo pipefail

EASYRSA_DIR=/etc/openvpn/easy-rsa
SRV=/etc/openvpn/server
CLIENTS=/root/ovpn-clients

log() { echo -e "\n==> $*"; }
die() { echo "错误: $*" >&2; exit 1; }
usage() {
  cat <<EOF
用法: bash $0 [--net 网段] [--pool 地址池]
  --net   VPN 网段，掩码固定 /24，如 10.93.1.0/24（默认 10.93.1.0/24）
  --pool  客户端动态地址池，如 10.93.1.2-10.93.1.99 或 2-99（默认 .2-.99）
          池外的 .2-.254 留给 add-client.sh 分配固定 IP
未指定的项会交互询问；非交互运行（stdin 不是终端）时直接用默认值。
EOF
}
# ask <变量名> <提示> <默认值>：变量为空时交互询问，无终端或直接回车则用默认值
ask() {
  local ans=""
  [ -n "${!1}" ] && return
  if [ -t 0 ]; then read -rp "$2 [默认 $3]: " ans || true; fi
  printf -v "$1" '%s' "${ans:-$3}"
}

VPN_NET="${VPN_NET:-${VPN_PREFIX:-}}"   # 兼容旧的 VPN_PREFIX 环境变量
VPN_POOL="${VPN_POOL:-}"
while [ $# -gt 0 ]; do
  case "$1" in
    --net)  [ $# -ge 2 ] || die "--net 缺少参数"; VPN_NET=$2; shift 2 ;;
    --pool) [ $# -ge 2 ] || die "--pool 缺少参数"; VPN_POOL=$2; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    *) usage; die "未知参数: $1" ;;
  esac
done

PORT="${PORT:-1194}"
WAN_IF="${WAN_IF:-$(ip -4 route show default | awk '{print $5; exit}')}"
PUBLIC_IP="${PUBLIC_IP:-$(ip -4 route get 1.1.1.1 | awk '{for(i=1;i<NF;i++) if($i=="src") print $(i+1); exit}')}"

# ---------- 0. 前置检查 ----------
[ "$(id -u)" -eq 0 ] || die "请用 root 运行"
command -v apt-get >/dev/null || die "仅支持 Debian/Ubuntu"
[ -e "$EASYRSA_DIR/pki" ] && die "$EASYRSA_DIR/pki 已存在，为防止覆盖现有证书已中止"

# 网段：接受 a.b.c / a.b.c.0 / a.b.c.0/24
ask VPN_NET "VPN 网段（掩码固定 /24）" "10.93.1.0/24"
[[ "$VPN_NET" =~ ^([0-9]{1,3})\.([0-9]{1,3})\.([0-9]{1,3})(\.0)?(/24)?$ ]] \
  || die "网段 $VPN_NET 格式错误，应为 a.b.c.0/24（仅支持 /24）"
for o in "${BASH_REMATCH[@]:1:3}"; do [ "$((10#$o))" -le 255 ] || die "网段 $VPN_NET 不是合法 IP"; done
VPN_PREFIX="$((10#${BASH_REMATCH[1]})).$((10#${BASH_REMATCH[2]})).$((10#${BASH_REMATCH[3]}))"

# 地址池：接受 a.b.c.S-a.b.c.E 或 S-E
ask VPN_POOL "客户端动态地址池" "${VPN_PREFIX}.2-${VPN_PREFIX}.99"
VPN_POOL="${VPN_POOL// /}"
[[ "$VPN_POOL" =~ ^([0-9.]+)-([0-9.]+)$ ]] || die "地址池 $VPN_POOL 格式错误，应为 ${VPN_PREFIX}.2-${VPN_PREFIX}.99 或 2-99"
POOL_START="${BASH_REMATCH[1]#"$VPN_PREFIX".}"
POOL_END="${BASH_REMATCH[2]#"$VPN_PREFIX".}"
[[ "$POOL_START" =~ ^[0-9]{1,3}$ && "$POOL_END" =~ ^[0-9]{1,3}$ ]] || die "地址池 $VPN_POOL 不在网段 ${VPN_PREFIX}.0/24 内"
POOL_START=$((10#$POOL_START)) POOL_END=$((10#$POOL_END))
(( 2 <= POOL_START && POOL_START <= POOL_END && POOL_END <= 254 )) || die "地址池须在 .2-.254 之间且起始不大于结束"
(( POOL_START > 2 || POOL_END < 254 )) || die "地址池不能占满 .2-.254，至少要给固定 IP 留一个地址"
# 第一个可用的固定 IP 编号，用于结尾提示
if [ "$POOL_START" -gt 2 ]; then FIRST_STATIC=2; else FIRST_STATIC=$((POOL_END + 1)); fi

[ -n "$WAN_IF" ] && [ -n "$PUBLIC_IP" ] || die "无法探测出口网卡/公网IP，请手动指定 WAN_IF / PUBLIC_IP"
case "$PUBLIC_IP" in
  10.*|172.1[6-9].*|172.2[0-9].*|172.3[01].*|192.168.*)
    echo "警告: 探测到的地址 $PUBLIC_IP 是内网地址（服务器可能在 NAT 后），客户端配置需要公网 IP，建议用 PUBLIC_IP=... 指定" ;;
esac
. /etc/os-release
CODENAME="${VERSION_CODENAME:?无法识别系统代号}"

echo "公网IP=$PUBLIC_IP  出口网卡=$WAN_IF  网段=${VPN_PREFIX}.0/24  动态池=${VPN_PREFIX}.${POOL_START}-${VPN_PREFIX}.${POOL_END}  端口=$PORT(udp+tcp)  系统=$CODENAME"

# ---------- 1. 安装 OpenVPN 2.7（官方源）与 easy-rsa ----------
log "安装 OpenVPN 2.7 与 easy-rsa"
export DEBIAN_FRONTEND=noninteractive
apt-get update -qq
apt-get install -y -qq curl ca-certificates iptables easy-rsa >/dev/null
mkdir -p /etc/apt/keyrings
curl -fsSL https://swupdate.openvpn.net/repos/repo-public.gpg -o /etc/apt/keyrings/openvpn-repo-public.asc
echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/openvpn-repo-public.asc] https://build.openvpn.net/debian/openvpn/stable $CODENAME main" \
  > /etc/apt/sources.list.d/openvpn-aptrepo.list
apt-get update -qq
apt-get install -y -qq -o Dpkg::Options::=--force-confold openvpn >/dev/null
# openvpn --version 的退出码恒为 1，不能直接放进 pipefail 管道
VER=$(openvpn --version 2>&1 | head -1 || true)
echo "$VER"
[[ "$VER" =~ OpenVPN\ 2\.([7-9]|[1-9][0-9]) ]] || die "OpenVPN 版本低于 2.7，不支持多 socket 监听"

# ---------- 2. PKI（easy-rsa 3.0.x 不读 vars，统一用环境变量）----------
log "生成 PKI（ECDSA secp384r1）"
export EASYRSA_BATCH=1 EASYRSA_ALGO=ec EASYRSA_CURVE=secp384r1 EASYRSA_DIGEST=sha384 \
       EASYRSA_CA_EXPIRE=3650 EASYRSA_CERT_EXPIRE=3650 EASYRSA_CRL_DAYS=3650
make-cadir "$EASYRSA_DIR"
cd "$EASYRSA_DIR"
./easyrsa init-pki >/dev/null
EASYRSA_REQ_CN="OpenVPN-CA" ./easyrsa build-ca nopass >/dev/null 2>&1
./easyrsa build-server-full server nopass >/dev/null 2>&1
./easyrsa gen-crl >/dev/null 2>&1
mkdir -p "$SRV/ccd" /var/log/openvpn "$CLIENTS"
cp pki/ca.crt pki/issued/server.crt pki/private/server.key pki/crl.pem "$SRV/"
chmod 644 "$SRV/crl.pem"
openvpn --genkey secret "$SRV/tc.key"
[[ "$(openssl x509 -in "$SRV/server.crt" -noout -text)" == *secp384r1* ]] || die "服务端证书不是 EC 证书"

# ---------- 3. 服务端配置 ----------
log "写入 $SRV/server.conf"
cat > "$SRV/server.conf" <<EOF
local 0.0.0.0 $PORT udp
local 0.0.0.0 $PORT tcp
dev tun
topology subnet
server ${VPN_PREFIX}.0 255.255.255.0 nopool
ifconfig-pool ${VPN_PREFIX}.${POOL_START} ${VPN_PREFIX}.${POOL_END} 255.255.255.0
client-config-dir $SRV/ccd
ifconfig-pool-persist /var/log/openvpn/ipp.txt

ca ca.crt
cert server.crt
key server.key
dh none
tls-crypt tc.key
crl-verify crl.pem
tls-version-min 1.2
data-ciphers AES-256-GCM:AES-128-GCM:CHACHA20-POLY1305
auth SHA256

push "redirect-gateway def1 bypass-dhcp"
push "dhcp-option DNS 1.1.1.1"
push "dhcp-option DNS 8.8.8.8"

keepalive 10 120
persist-tun
user nobody
group nogroup
status /var/log/openvpn/openvpn-status.log
verb 3
explicit-exit-notify 1
EOF

# ---------- 4. IP 转发 + NAT（随服务启停）----------
log "配置 IP 转发与 NAT（出口 $WAN_IF）"
echo "net.ipv4.ip_forward=1" > /etc/sysctl.d/99-openvpn.conf
sysctl -q -p /etc/sysctl.d/99-openvpn.conf
NET="${VPN_PREFIX}.0/24"
mkdir -p /etc/systemd/system/openvpn-server@server.service.d
cat > /etc/systemd/system/openvpn-server@server.service.d/nat.conf <<EOF
[Service]
ExecStartPost=/usr/sbin/iptables -t nat -A POSTROUTING -s $NET -o $WAN_IF -j MASQUERADE
ExecStartPost=/usr/sbin/iptables -I FORWARD -i tun0 -o $WAN_IF -s $NET -j ACCEPT
ExecStartPost=/usr/sbin/iptables -I FORWARD -i $WAN_IF -o tun0 -m state --state RELATED,ESTABLISHED -j ACCEPT
ExecStopPost=/usr/sbin/iptables -t nat -D POSTROUTING -s $NET -o $WAN_IF -j MASQUERADE
ExecStopPost=/usr/sbin/iptables -D FORWARD -i tun0 -o $WAN_IF -s $NET -j ACCEPT
ExecStopPost=/usr/sbin/iptables -D FORWARD -i $WAN_IF -o tun0 -m state --state RELATED,ESTABLISHED -j ACCEPT
EOF
if command -v ufw >/dev/null && [[ "$(LC_ALL=C ufw status)" == "Status: active"* ]]; then
  ufw allow "$PORT"/udp >/dev/null; ufw allow "$PORT"/tcp >/dev/null
  echo "ufw 已放行 $PORT/udp、$PORT/tcp"
fi

# ---------- 5. 管理脚本 ----------
log "安装管理脚本到 $CLIENTS"
cat > /etc/openvpn/ovpn.env <<EOF
PUBLIC_IP=$PUBLIC_IP
VPN_PREFIX=$VPN_PREFIX
POOL_START=$POOL_START
POOL_END=$POOL_END
PORT=$PORT
EOF

cat > "$CLIENTS/add-client.sh" <<'SCRIPT'
#!/bin/bash
# 用法: add-client.sh <编号 2-254，且不在动态池内>  -> 证书 CN=client<编号>，固定 IP <VPN_PREFIX>.<编号>
set -euo pipefail
. /etc/openvpn/ovpn.env
N="${1:-}"
if ! [[ "$N" =~ ^[0-9]+$ ]] || [ "$N" -lt 2 ] || [ "$N" -gt 254 ] \
   || { [ "$N" -ge "$POOL_START" ] && [ "$N" -le "$POOL_END" ]; }; then
  echo "用法: $0 <编号>，可用 2-254 中除动态池 $POOL_START-$POOL_END 以外的编号"; exit 1
fi
NAME="client$N"
EASYRSA=/etc/openvpn/easy-rsa
PKI=$EASYRSA/pki
OUT=/root/ovpn-clients/$NAME.ovpn
[ -e "$PKI/issued/$NAME.crt" ] && { echo "$NAME 已存在"; exit 1; }

cd $EASYRSA
EASYRSA_BATCH=1 EASYRSA_ALGO=ec EASYRSA_CURVE=secp384r1 EASYRSA_DIGEST=sha384 EASYRSA_CERT_EXPIRE=3650 \
  ./easyrsa build-client-full "$NAME" nopass >/dev/null 2>&1

echo "ifconfig-push $VPN_PREFIX.$N 255.255.255.0" > /etc/openvpn/server/ccd/$NAME
chmod 644 /etc/openvpn/server/ccd/$NAME

{ cat <<CONF
client
dev tun
remote $PUBLIC_IP $PORT udp
remote $PUBLIC_IP $PORT tcp
resolv-retry infinite
nobind
persist-key
persist-tun
remote-cert-tls server
auth SHA256
data-ciphers AES-256-GCM:AES-128-GCM:CHACHA20-POLY1305
verb 3
CONF
echo "<ca>"; cat $PKI/ca.crt; echo "</ca>"
echo "<cert>"; sed -n "/BEGIN CERTIFICATE/,/END CERTIFICATE/p" $PKI/issued/$NAME.crt; echo "</cert>"
echo "<key>"; cat $PKI/private/$NAME.key; echo "</key>"
echo "<tls-crypt>"; cat /etc/openvpn/server/tc.key; echo "</tls-crypt>"; } > $OUT
chmod 600 $OUT
echo "$NAME -> $VPN_PREFIX.$N  配置: $OUT"
SCRIPT

cat > "$CLIENTS/revoke-client.sh" <<'SCRIPT'
#!/bin/bash
# 用法: revoke-client.sh <客户端名，如 client100>
# 吊销证书并清理残留：ovpn、ccd、吊销后的私钥/req、ipp 记录（会重启服务，断线约 3 秒）
set -euo pipefail
NAME="${1:-}"
[ -n "$NAME" ] || { echo "用法: $0 <客户端名，如 client100>"; exit 1; }
EASYRSA=/etc/openvpn/easy-rsa
PKI=$EASYRSA/pki
[ -e "$PKI/issued/$NAME.crt" ] || { echo "$NAME 不存在或已吊销"; exit 1; }
SERIAL=$(openssl x509 -in "$PKI/issued/$NAME.crt" -noout -serial | cut -d= -f2)

cd $EASYRSA
export EASYRSA_BATCH=1 EASYRSA_CRL_DAYS=3650
./easyrsa revoke "$NAME" >/dev/null 2>&1
./easyrsa gen-crl >/dev/null 2>&1
cp "$PKI/crl.pem" /etc/openvpn/server/crl.pem
chmod 644 /etc/openvpn/server/crl.pem

# 保留 index.txt 的 R 记录和吊销证书（审计用），删掉无用的私钥/req
rm -f "/root/ovpn-clients/$NAME.ovpn" "/etc/openvpn/server/ccd/$NAME"
find "$PKI" \( -name "$SERIAL.key" -o -name "$SERIAL.req" -o -name "$NAME.key" -o -name "$NAME.req" \) -delete

# 运行中的服务会回写 ipp.txt，必须停服务后再改
systemctl stop openvpn-server@server
sed -i "/^$NAME,/d" /var/log/openvpn/ipp.txt
systemctl start openvpn-server@server
echo "$NAME 已吊销（serial=$SERIAL）并清理残留"
SCRIPT
chmod 700 "$CLIENTS/add-client.sh" "$CLIENTS/revoke-client.sh"

# ---------- 6. 启动 ----------
log "启动服务"
systemctl daemon-reload
systemctl enable --now openvpn-server@server
sleep 3
systemctl is-active --quiet openvpn-server@server || { journalctl -u openvpn-server@server -n 30 --no-pager; die "服务启动失败"; }
[[ "$(ss -lnu)" == *":$PORT "* && "$(ss -lnt)" == *":$PORT "* ]] || die "未同时监听 UDP/TCP $PORT"

log "部署完成"
echo "  监听: UDP+TCP $PORT    网关: ${VPN_PREFIX}.1    动态池: ${VPN_PREFIX}.${POOL_START}-${VPN_PREFIX}.${POOL_END}"
echo "  新增客户端: $CLIENTS/add-client.sh $FIRST_STATIC      -> ${VPN_PREFIX}.$FIRST_STATIC（编号需在动态池外）"
echo "  吊销客户端: $CLIENTS/revoke-client.sh client$FIRST_STATIC"
echo "  记得在云厂商安全组放行 UDP/TCP $PORT 入站"

#!/bin/bash
# 用法: ./add-client.sh <编号 2-254，且不在动态池内>  -> 证书 CN=client<编号>，固定 IP <VPN_PREFIX>.<编号>
# 配置输出到项目目录下的 clients/<名字>.ovpn
set -euo pipefail
[ "$(id -u)" -eq 0 ] || { echo "请用 root 运行"; exit 1; }
[ -r /etc/openvpn/ovpn.env ] || { echo "未找到 /etc/openvpn/ovpn.env，请先运行 ./install-openvpn.sh"; exit 1; }
. /etc/openvpn/ovpn.env
N="${1:-}"
if ! [[ "$N" =~ ^[0-9]+$ ]] || [ "$N" -lt 2 ] || [ "$N" -gt 254 ] \
   || { [ "$N" -ge "$POOL_START" ] && [ "$N" -le "$POOL_END" ]; }; then
  echo "用法: $0 <编号>，可用 2-254 中除动态池 $POOL_START-$POOL_END 以外的编号"; exit 1
fi
NAME="client$N"
EASYRSA=/etc/openvpn/easy-rsa
PKI=$EASYRSA/pki
CLIENTS="$(cd "$(dirname "$0")" && pwd)/clients"
OUT=$CLIENTS/$NAME.ovpn
[ -e "$PKI/issued/$NAME.crt" ] && { echo "$NAME 已存在"; exit 1; }
mkdir -p "$CLIENTS"
chmod 700 "$CLIENTS"

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
mssfix 1400
verb 3
CONF
echo "<ca>"; cat $PKI/ca.crt; echo "</ca>"
echo "<cert>"; sed -n "/BEGIN CERTIFICATE/,/END CERTIFICATE/p" $PKI/issued/$NAME.crt; echo "</cert>"
echo "<key>"; cat $PKI/private/$NAME.key; echo "</key>"
echo "<tls-crypt>"; cat /etc/openvpn/server/tc.key; echo "</tls-crypt>"; } > "$OUT"
chmod 600 "$OUT"
echo "$NAME -> $VPN_PREFIX.$N  配置: $OUT"

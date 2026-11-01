#!/bin/bash
# 用法: ./revoke-client.sh <客户端名，如 client100>
# 吊销证书并清理残留：ovpn、ccd、吊销后的私钥/req、ipp 记录（会重启服务，断线约 3 秒）
set -euo pipefail
[ "$(id -u)" -eq 0 ] || { echo "请用 root 运行"; exit 1; }
NAME="${1:-}"
[ -n "$NAME" ] || { echo "用法: $0 <客户端名，如 client100>"; exit 1; }
EASYRSA=/etc/openvpn/easy-rsa
PKI=$EASYRSA/pki
CLIENTS="$(cd "$(dirname "$0")" && pwd)/clients"
[ -e "$PKI/issued/$NAME.crt" ] || { echo "$NAME 不存在或已吊销"; exit 1; }
SERIAL=$(openssl x509 -in "$PKI/issued/$NAME.crt" -noout -serial | cut -d= -f2)

cd $EASYRSA
export EASYRSA_BATCH=1 EASYRSA_CRL_DAYS=3650
./easyrsa revoke "$NAME" >/dev/null 2>&1
./easyrsa gen-crl >/dev/null 2>&1
cp "$PKI/crl.pem" /etc/openvpn/server/crl.pem
chmod 644 /etc/openvpn/server/crl.pem

# 保留 index.txt 的 R 记录和吊销证书（审计用），删掉无用的私钥/req
rm -f "$CLIENTS/$NAME.ovpn" "$CLIENTS/$NAME-mikrotik.ovpn" "/etc/openvpn/server/ccd/$NAME"
find "$PKI" \( -name "$SERIAL.key" -o -name "$SERIAL.req" -o -name "$NAME.key" -o -name "$NAME.req" \) -delete

# 运行中的服务会回写 ipp.txt，必须停服务后再改
systemctl stop openvpn-server@server
sed -i "/^$NAME,/d" /var/log/openvpn/ipp.txt
systemctl start openvpn-server@server
echo "$NAME 已吊销（serial=$SERIAL）并清理残留"

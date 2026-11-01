#!/bin/bash
# OpenVPN 一键卸载：撤销 install-openvpn.sh 所做的全部改动
#
# 删除前会把 /etc/openvpn 和 clients/ 打包备份到 /root/openvpn-backup-<时间>.tgz
# 保留 curl、ca-certificates、iptables（常用依赖，可能被其他程序使用）
#
# 用法（root）：
#   ./uninstall-openvpn.sh        # 需输入 yes 确认
#   ./uninstall-openvpn.sh -y     # 跳过确认
set -euo pipefail

SRV=/etc/openvpn/server
CLIENTS="$(cd "$(dirname "$0")" && pwd)/clients"

die() { echo "错误: $*" >&2; exit 1; }
log() { echo -e "\n==> $*"; }

YES=0
case "${1:-}" in
  "") ;;
  -y|--yes) YES=1 ;;
  -h|--help) echo "用法: $0 [-y]   -y 跳过确认"; exit 0 ;;
  *) die "未知参数: $1" ;;
esac

[ "$(id -u)" -eq 0 ] || die "请用 root 运行"
PORT=1194
[ -r /etc/openvpn/ovpn.env ] && . /etc/openvpn/ovpn.env

if [ "$YES" -ne 1 ]; then
  [ -t 0 ] || die "非交互运行请加 -y 确认卸载"
  echo "将停止 OpenVPN 服务，删除 PKI（CA 及全部证书）、服务端配置、NAT/ufw 规则、官方 apt 源，并卸载 openvpn、easy-rsa。"
  echo "已发出的客户端 .ovpn 将全部失效。删除前会自动备份到 /root。"
  ans=""; read -rp "确认卸载请输入 yes: " ans || true
  [ "$ans" = "yes" ] || die "已取消"
fi

# ---------- 1. 备份 ----------
BAK=/root/openvpn-backup-$(date +%Y%m%d%H%M%S).tgz
paths=()
for p in /etc/openvpn "$CLIENTS"; do [ -e "$p" ] && paths+=("$p"); done
if [ ${#paths[@]} -gt 0 ]; then
  log "备份到 $BAK"
  (umask 077; tar czf "$BAK" "${paths[@]}" 2>/dev/null)
fi

# ---------- 2. 停服务（ExecStopPost 会删掉 NAT/FORWARD 规则，必须在删 drop-in 之前）----------
log "停止并禁用 openvpn-server@server"
systemctl disable --now openvpn-server@server 2>/dev/null || true
rm -rf /etc/systemd/system/openvpn-server@server.service.d
systemctl daemon-reload

# ---------- 3. 防火墙与内核转发 ----------
if command -v ufw >/dev/null && [[ "$(LC_ALL=C ufw status)" == "Status: active"* ]]; then
  ufw delete allow "$PORT"/udp >/dev/null 2>&1 || true
  ufw delete allow "$PORT"/tcp >/dev/null 2>&1 || true
  echo "ufw 已删除 $PORT/udp、$PORT/tcp 放行规则"
fi
# 只删配置文件，不立即关闭转发（Docker 等可能依赖），重启后恢复系统默认
rm -f /etc/sysctl.d/99-openvpn.conf

# ---------- 4. 配置、PKI、日志、客户端文件 ----------
log "删除配置与证书"
rm -rf /etc/openvpn/easy-rsa "$SRV" /etc/openvpn/ovpn.env /var/log/openvpn "$CLIENTS"

# ---------- 5. 软件包与 apt 源 ----------
log "卸载 openvpn、easy-rsa 并移除官方 apt 源"
export DEBIAN_FRONTEND=noninteractive
apt-get purge -y -qq openvpn easy-rsa >/dev/null 2>&1 || true
apt-get autoremove -y -qq >/dev/null 2>&1 || true
rm -f /etc/apt/sources.list.d/openvpn-aptrepo.list /etc/apt/keyrings/openvpn-repo-public.asc
apt-get update -qq || true

log "卸载完成"
[ -e "$BAK" ] && echo "  备份: $BAK（内含私钥，用完请妥善删除）"
echo "  记得在云厂商安全组删除 UDP/TCP $PORT 入站规则"

# Run in the gateway after gateway-setup.sh: holds the client to a scope, by hand for now (Rook will compile it).
#   allow *.nmap.org, nmap.org, 192.168.64.1/32; deny www.nmap.org; drop and log the rest.
# dnsmasq puts the addresses it resolves for in-scope names into sets the forward chain allows.
set -eu
apk add -q dnsmasq-dnssec-nftset
nft -f - <<RULES
table inet scope
delete table inet scope
table inet scope {
  set allowed4 { type ipv4_addr; flags timeout; }
  set denied4 { type ipv4_addr; flags timeout; }
  set networks4 { type ipv4_addr; flags interval; elements = { 192.168.64.1/32 } }
  chain forward {
    type filter hook forward priority -10; policy drop;
    iifname "eth0" oifname "eth1" accept
    ip daddr @denied4 log prefix "scope-deny " drop
    ip daddr @allowed4 accept
    ip daddr @networks4 accept
    log prefix "scope-drop " drop
  }
}
RULES
cat > /etc/dnsmasq.conf <<CONF
interface=eth1
bind-interfaces
no-resolv
server=$(awk '/^nameserver/ {print $2; exit}' /etc/resolv.conf)
log-queries
log-facility=/var/log/dnsmasq.log
nftset=/nmap.org/4#inet#scope#allowed4
nftset=/www.nmap.org/4#inet#scope#denied4
CONF
pkill dnsmasq 2>/dev/null || true
sleep 1
dnsmasq
echo "scope ready: $(dnsmasq --version | grep -o nftset | head -1)"

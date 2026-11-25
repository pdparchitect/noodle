# Run in the gateway pod: computer-lab.sh exec gateway -- "$(cat gateway-setup.sh)"
# Routes the client on eth1 out of NAT on eth0 under its own NAT-subnet address (vmnet NATs any address in its
# subnet), so every kind of probe crosses: tracked traffic by SNAT, the probes tracking rejects without state.
set -eu
apk add -q nftables dnsmasq tcpdump nmap
inside=10.66.0.2 outside=192.168.64.200
ip addr add $outside/32 dev eth0 2>/dev/null || true
nft -f - <<RULES
flush ruleset
table inet lab {
  # What connection tracking follows is SNATed as usual, which also rewrites the packet an ICMP error quotes.
  chain nat_out {
    type nat hook postrouting priority srcnat;
    oifname "eth0" ip saddr $inside snat ip to $outside
  }
  # What it calls invalid (FIN, NULL, Xmas and ACK probes, and the RSTs answering them) skips NAT, so it is
  # rewritten without state: out after SNAT has had its turn, in after un-SNAT has had its.
  chain stateless_out {
    type filter hook postrouting priority srcnat + 10;
    oifname "eth0" ip saddr $inside ip saddr set $outside
  }
  chain stateless_in {
    type filter hook prerouting priority dstnat + 10;
    iifname "eth0" ip daddr $outside ip daddr set $inside
  }
  chain forward {
    type filter hook forward priority 0; policy accept;
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
CONF
pkill dnsmasq 2>/dev/null || true
dnsmasq
echo "gateway ready: forwarding=$(cat /proc/sys/net/ipv4/ip_forward)"

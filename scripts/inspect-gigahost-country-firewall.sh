#!/usr/bin/env bash
# Read-only baseline for safely placing country IP blocking on Gigahost.
# No secrets, nft modifications, restarts, services changes, or network operations.
set -uo pipefail
section() { printf '\n========== %s ==========\n' "$1"; }
section "IDENTITY"
hostname; cat /etc/os-release | grep -E '^PRETTY_NAME='; uname -r
section "FIREWALL SERVICE STATUS"
for service in opengov-guard.service crowdsec.service crowdsec-firewall-bouncer.service nftables.service globaleaks.service; do
  printf '%-38s ' "$service"; systemctl is-active "$service" 2>/dev/null || true
  printf 'enabled: '; systemctl is-enabled "$service" 2>/dev/null || true
done
section "OPENGOV GUARD UNIT"
systemctl cat opengov-guard.service 2>/dev/null || true
section "OPENGOV GUARD SCRIPT REFERENCES"
systemctl show opengov-guard.service -p ExecStart -p ExecStartPre -p ExecReload --no-pager
section "NFT TABLE/CHAIN HOOKS"
nft -a list ruleset 2>/dev/null | grep -E '^(table |[[:space:]]*(chain |type filter hook |type nat hook |policy |set |flags |elements =))' | head -n 220 || true
section "OPENGOV GUARD TABLE (rules, no set elements)"
nft -a list table inet opengov_guard 2>/dev/null | sed -E '/^[[:space:]]*elements = \{/,$d' | head -n 240 || true
section "CROWDSEC TABLE HEADERS"
nft -a list table ip crowdsec 2>/dev/null | grep -E '^(table |[[:space:]]*(chain |type |policy |set |flags |elements =))' | head -n 100 || true
nft -a list table ip6 crowdsec6 2>/dev/null | grep -E '^(table |[[:space:]]*(chain |type |policy |set |flags |elements =))' | head -n 100 || true
section "NAT REDIRECTS"
iptables -t nat -S 2>/dev/null | grep -E -- '(^-P |^-[AN] |--dport (80|443|8080|8443)|REDIRECT)' | head -n 120 || true
section "IP FAMILY AND ROUTE"
ip -br address show scope global 2>/dev/null | sed -E 's/([0-9]{1,3}\.){3}[0-9]{1,3}(\/[0-9]+)?/[IPv4]/g; s/[[:xdigit:]:]+\/[0-9]+/[IPv6]/g'
ip -4 route show default; ip -6 route show default
section "ADMIN AND APP LISTENERS (no process arguments)"
ss -H -lnt | awk '{print $4}' | sort -u | head -n 80
section "GUARD RULE SOURCE PATHS"
systemctl show opengov-guard.service -p FragmentPath -p DropInPaths --no-pager
section "RESULT"
echo "Read-only firewall inspection complete. No changes made."

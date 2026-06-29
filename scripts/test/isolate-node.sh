#!/bin/bash
# isolate-node.sh — simulate network partition of a node from etcd.
#
# Usage: ./isolate-node.sh <etcd_lb_ip>
#
# Blocks all outbound traffic to the etcd load balancer, simulating
# a network partition.  After the session TTL (15s) expires, peers
# should detect the failure and fence this node.

set -euo pipefail

ETCD_IP="${1:?Usage: $0 <etcd_lb_ip>}"

ACTION="${2:-drop}"

case "$ACTION" in
    drop)
        echo "Isolating from etcd at $ETCD_IP..."
        iptables -A OUTPUT -d "$ETCD_IP" -j DROP
        iptables -A INPUT  -s "$ETCD_IP" -j DROP
        echo "Traffic to/from $ETCD_IP blocked."
        echo "Session lease will expire in ~15s. Peers should detect failure."
        echo "To restore: $0 $ETCD_IP restore"
        ;;
    restore)
        echo "Restoring connectivity to $ETCD_IP..."
        iptables -D OUTPUT -d "$ETCD_IP" -j DROP 2>/dev/null || true
        iptables -D INPUT  -s "$ETCD_IP" -j DROP 2>/dev/null || true
        echo "Connectivity restored."
        ;;
    *)
        echo "Usage: $0 <etcd_lb_ip> [drop|restore]"
        exit 1
        ;;
esac

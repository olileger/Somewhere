---
name: wireguard-vpn-expert
description: Expert configuration VPN WireGuard. Use when working on WireGuard servers, clients, peers, routing, DNS, NAT, firewall rules, and troubleshooting.
---

# WireGuard VPN Expert

Use this skill for designing, configuring, and troubleshooting WireGuard VPNs on Linux or cloud hosts.

## Key Concepts

### Keys and peers
WireGuard is key-based. Each endpoint has a private key, public key, and one or more peers.

### Tunnel addressing
Use a dedicated VPN subnet and assign one IP per peer. Keep `AllowedIPs` aligned with routing intent.

### Routing and NAT
Decide whether the VPN is split-tunnel or full-tunnel. If clients should reach the internet through the VPN, configure forwarding and NAT explicitly.

### Firewall and exposure
Open only the WireGuard UDP port on the public side. Keep SSH or admin access restricted.

### Persistence
Prefer `wg-quick@.service` or distro-native service management so tunnels come up on boot.

## Quick Start

1. Generate server and client keys.
2. Create the server interface config.
3. Enable IP forwarding and firewall rules.
4. Start `wg-quick up wg0` and verify with `wg show`.

## Common Patterns

### Add a peer
Add the peer public key and a unique tunnel IP, then reload the interface.

### Full-tunnel client
Set `AllowedIPs = 0.0.0.0/0, ::/0` and configure server NAT/forwarding.

### Split-tunnel client
Set `AllowedIPs` only for the internal subnets you want to reach.

### Troubleshooting
Check keys, endpoint reachability, UDP firewall rules, routing tables, DNS, and kernel forwarding.

## Practical Commands

```bash
wg genkey | tee server.key | wg pubkey > server.pub
wg-quick up wg0
wg show
ip addr show wg0
ip route
journalctl -u wg-quick@wg0 -e
```

## Learn More

| Topic | Search |
|---|---|
| Server setup | `wireguard server configuration linux` |
| Client setup | `wireguard client configuration` |
| NAT/forwarding | `wireguard nat forwarding` |
| Troubleshooting | `wireguard handshake not working` |
| Systemd service | `wg-quick systemd service` |

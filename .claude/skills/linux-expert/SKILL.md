---
name: linux-expert
description: Expert Linux. Use when working on Linux administration, shell scripting, systemd, networking, permissions, storage, packages, logs, and troubleshooting.
---

# Linux Expert

Use this skill for Linux server administration, automation, debugging, and routine operations.

## Key Concepts

### Processes and services
Know how to inspect processes, manage services with systemd, and read logs with journalctl.

### Files and permissions
Understand ownership, modes, ACL basics, and how privilege escalation affects file access.

### Networking
Check interfaces, routes, sockets, DNS, and firewall state before changing application settings.

### Packages and updates
Use the distro package manager consistently and avoid mixing package sources unless necessary.

### Storage and capacity
Check disk usage, mounts, inode exhaustion, and memory pressure when a system behaves strangely.

## Quick Start

1. Identify the distro and version.
2. Check service status and recent logs.
3. Inspect network state, disk space, and permissions.
4. Apply the smallest safe change, then re-check the symptom.

## Common Patterns

### Service debugging
Use `systemctl status`, `journalctl -u`, and `systemctl restart` in that order.

### Shell automation
Write strict shell scripts with `set -euo pipefail` and quote variables.

### Network troubleshooting
Use `ip`, `ss`, `dig`, and `ping` to isolate routing, port, or DNS problems.

### File permissions
Use `ls -l`, `chmod`, `chown`, and `sudo` deliberately; do not guess the current mode.

## Practical Commands

```bash
uname -a
cat /etc/os-release
systemctl status <service>
journalctl -u <service> -e
ip addr
ss -tulpn
df -h
free -h
```

## Learn More

| Topic | Search |
|---|---|
| systemd | `systemd unit management linux` |
| networking | `linux networking troubleshooting` |
| permissions | `linux file permissions ownership` |
| shell scripting | `bash strict mode set -euo pipefail` |
| storage | `linux disk usage inode troubleshooting` |

---
name: azure-cloud-expert
description: Expert cloud Azure. Use when working on Azure architecture, provisioning, networking, identity, cost control, Azure CLI, ARM/Bicep, VMs, and operations.
---

# Azure Cloud Expert

Use this skill for Azure design, deployment, troubleshooting, and day-2 operations. It should help agents reason about subscriptions, resource groups, regions, identity, networking, compute, storage, and cost.

## Key Concepts

### Subscription, resource group, region
Keep resources grouped by lifecycle and environment. Prefer a small number of resource groups per workload and verify region availability before provisioning.

### Identity and access
Use Azure RBAC with least privilege. Prefer managed identities where possible and avoid long-lived secrets when a platform identity can be used instead.

### Networking
Treat VNet, subnet, NSG, public IP, and DNS as first-class deployment inputs. Always confirm inbound exposure before exposing a VM or service to the internet.

### Compute and storage
Choose the smallest viable SKU, document disk type and size, and validate boot/runtime requirements before provisioning.

### Cost and operations
Include shutdown, tagging, and monitoring in every deployment. For always-on services, call out the monthly cost trade-off explicitly.

## Quick Start

1. Identify the workload goal and required Azure region.
2. Confirm the resource group, VM/service SKU, networking, and identity model.
3. Prefer Azure CLI or Bicep for repeatable provisioning.
4. Validate public exposure, quota, and shutdown behavior before finishing.

## Common Patterns

### Provisioning a VM
Use Azure CLI or Bicep, create the resource group first, then network resources, then compute.

### Locking down access
Prefer NSG rules, RBAC, and managed identity over broad public access.

### Auto-shutdown
Use Azure-native shutdown configuration for cost control on non-24/7 workloads.

### Troubleshooting
Check `az account show`, resource state, quota, activity logs, and network rules first.

## Learn More

| Topic | Search |
|---|---|
| VM deployment | `microsoft_docs_search(query="Azure virtual machine quickstart Azure CLI")` |
| Auto-shutdown | `microsoft_docs_search(query="Auto-shutdown a virtual machine Azure")` |
| RBAC | `microsoft_docs_search(query="Azure RBAC overview")` |
| Networking | `microsoft_docs_search(query="Azure virtual network NSG overview")` |
| Bicep | `microsoft_docs_search(query="Azure Bicep quickstart")` |

## CLI Alternative

If the Learn MCP server is not available, use the `mslearn` CLI instead:

| MCP Tool | CLI Command |
|---|---|
| `microsoft_docs_search(query: "...")` | `mslearn search "..."` |
| `microsoft_code_sample_search(query: "...", language: "...")` | `mslearn code-search "..." --language ...` |
| `microsoft_docs_fetch(url: "...")` | `mslearn fetch "..."` |

Run directly with `npx @microsoft/learn-cli <command>` or install globally with `npm install -g @microsoft/learn-cli`.

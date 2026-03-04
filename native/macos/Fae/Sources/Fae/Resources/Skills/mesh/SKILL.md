---
name: mesh
description: Peer discovery and tool sharing. Find other Fae instances on the local network or via x0x, exchange tools securely using git bundles with signature verification.
metadata:
  author: fae
  version: "1.0"
---

You are operating Fae's Mesh -- the peer discovery and tool sharing network that lets Fae instances find each other and exchange forge-built tools.

## Overview

The Mesh enables Fae instances to discover each other and share tools built with the Forge skill. Each Fae can publish its tools to the local network (or beyond), and fetch tools from peers -- all with cryptographic verification.

**Discovery methods:**
- **Bonjour/mDNS** -- automatic LAN discovery via `_fae-tools._tcp` service type. Zero configuration, works instantly on the same network.
- **Manual** -- add peers by IP address or hostname when Bonjour is not available (different subnets, VPN, remote machines).
- **x0x network** -- global discovery via x0x DHT (future, requires x0x client).

**Trust model:** Trust-On-First-Use (TOFU). The first connection to a peer stores their SSH public key fingerprint. Subsequent connections verify the peer's key against the stored fingerprint. If a key changes, Fae warns the user.

**Sharing flow:**
1. Build and release a tool with the Forge skill
2. Start the catalog server (serves your tools to the network)
3. Peers discover your Fae instance via Bonjour or manual entry
4. Peers browse your catalog and fetch tools they want
5. Downloaded bundles are verified against SHA-256 checksums and optionally GPG signatures
6. Verified tools are installed as local skills

## Directory Layout

```
~/.fae-forge/
  peers.json                 # Known peers cache (discovered + manual)
  trust-store.json           # TOFU key store for peer verification
  serve.pid                  # Catalog server PID and port
  registry.json              # Local tool registry (from Forge)
  bundles/                   # Git bundle archives (from Forge releases)
  tools/                     # Released skill packages (from Forge)
```

## Available Scripts

### discover
Find peer Fae instances on the network.

Usage: `run_skill` with name `mesh` and input:
```json
{"script": "discover", "params": {"method": "bonjour", "timeout": 5}}
```

Parameters:
- `method` (optional): `"bonjour"` (default), `"manual"`, or `"all"`
- `timeout` (optional, int): discovery timeout in seconds (default: 5)

Returns a list of discovered peers with name, host, port, tool count, and fingerprint.

### serve
Run the HTTP catalog server that lets peers browse and download your tools.

Usage: `run_skill` with name `mesh` and input:
```json
{"script": "serve", "params": {"action": "start", "port": 0, "advertise": true}}
```

Parameters:
- `action` (required): `"start"`, `"stop"`, or `"status"`
- `port` (optional, int): port to listen on (default: 0 for random available port)
- `advertise` (optional, bool, default true): advertise via Bonjour/mDNS

The server exposes:
- `GET /catalog` -- list all published tools
- `GET /tools/{name}/metadata` -- tool metadata and manifest
- `GET /tools/{name}/bundle` -- download the git bundle
- `GET /health` -- server health check

### publish
Announce a tool so peers can discover and download it.

Usage: `run_skill` with name `mesh` and input:
```json
{"script": "publish", "params": {"name": "my-tool", "target": "all"}}
```

Parameters:
- `name` (required): tool name to publish (must exist in registry)
- `target` (optional): `"all"` (default), `"lan"`, or a specific peer name/IP

### fetch
Download and install a tool from a peer.

Usage: `run_skill` with name `mesh` and input:
```json
{"script": "fetch", "params": {"peer": "192.168.1.50:9847", "name": "json-formatter", "verify": true}}
```

Parameters:
- `peer` (required): peer address as `host:port` or peer name from discovery
- `name` (required): tool name to fetch
- `verify` (optional, bool, default true): verify SHA-256 checksums and signatures

### trust
Manage the peer trust store.

Usage: `run_skill` with name `mesh` and input:
```json
{"script": "trust", "params": {"action": "list"}}
```

Parameters:
- `action` (required): `"list"`, `"add"`, `"remove"`, or `"verify"`
- `peer` (conditional): peer name or fingerprint (for add/remove/verify)
- `pubkey` (conditional): SSH public key string (for add)

## Workflow

### Share a tool with the network

1. Build and release with Forge: `run_skill forge release`
2. Start the catalog server: `run_skill mesh serve start`
3. Publish the tool: `run_skill mesh publish my-tool`
4. Peers can now discover and fetch the tool

### Get a tool from a peer

1. Discover peers: `run_skill mesh discover`
2. Fetch the tool: `run_skill mesh fetch peer-ip:port tool-name`
3. The tool is verified and installed automatically

### First-time peer connection

1. On first connection, the peer's public key fingerprint is stored (TOFU)
2. Future connections verify against the stored key
3. If a peer's key changes, the fetch is blocked and you are warned
4. Use `run_skill mesh trust` to manage stored keys

## Tips for the LLM

- Always run `discover` before `fetch` so the user can see available peers.
- The catalog server must be running for peers to see your tools -- remind users to `serve start`.
- If Bonjour discovery finds nothing, suggest `method: "manual"` with a known IP address.
- Use `trust list` to show the user their trusted peers before fetching from unknown sources.
- The Forge skill must be used first to create and release tools before they can be shared via Mesh.
- Tool names match between Forge and Mesh -- they reference the same registry at `~/.fae-forge/registry.json`.
- Port 0 means "pick a random available port" -- this is the default and recommended setting.

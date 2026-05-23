# XHTTP-Wasmer

Automated deployment of **VLESS+XHTTP+TLS** proxy with a relay on **Wasmer Edge**.

> A drop-in replacement for [XHTTP-Installer](https://github.com/avacocloud/XHTTP-Installer) that uses Wasmer Edge instead of Netlify or Vercel.

---

## Architecture

```
Client in Iran
    │  (VLESS+XHTTP+TLS — looks like normal HTTPS)
    ▼
Wasmer Edge Worker
  [WinterCG JS relay — runs on Wasmer distributed infrastructure]
    │  (HTTPS forward to origin server)
    ▼
Your Ubuntu Server
  [Xray-core – VLESS+XHTTP+TLS listener]
    │
    ▼
Open Internet
```

Traffic passes through your Wasmer Edge sub-domain, keeping your server's real IP hidden.

---

## Requirements

| Item | Details |
|------|---------|
| Server | Ubuntu 20.04+, root access |
| Ports | 80 and 443 must be free |
| Resources | Minimum 1 vCPU + 512 MB RAM |
| Domain | Subdomain with DNS A record pointing to server IP |
| Wasmer account | Free account at [wasmer.io](https://wasmer.io) |
| Wasmer token | From [wasmer.io/settings/access-tokens](https://wasmer.io/settings/access-tokens) |

---

## Quick Install

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/YOUR_REPO/main/bootstrap.sh)
```

The script performs eight phases automatically:

1. System and port preflight checks
2. Install Xray-core, acme.sh, Wasmer CLI
3. Collect user input (domain, email, Wasmer token)
4. Issue SSL certificate via Let's Encrypt
5. Configure Xray with VLESS+XHTTP+TLS
6. Deploy relay worker to Wasmer Edge
7. End-to-end relay → Xray health checks
8. Output ready-to-use VLESS link

---

## Project Structure

```
XHTTP-Wasmer/
├── bootstrap.sh              ← entry point (curl | bash)
├── install.sh                ← main install script
├── Deploy-Ubuntu.sh          ← alias to install.sh
├── deploy/
│   └── worker/
│       ├── src/
│       │   └── index.js      ← WinterCG relay worker
│       ├── wasmer.toml       ← Wasmer package manifest
│       └── app.yaml          ← Wasmer Edge app config
├── README.md                 ← Persian documentation
└── README_EN.md              ← this file
```

---

## What is XHTTP?

XHTTP is a custom transport layer in Xray-core that conceals VPN traffic inside ordinary HTTP/HTTPS requests.

Key properties:
- **DPI-resistant**: indistinguishable from regular HTTPS traffic to deep packet inspection
- **CDN-compatible**: can be relayed through Wasmer Edge, Cloudflare Workers, Netlify, etc.
- **Padding**: appends random bytes to packets to prevent traffic-pattern fingerprinting
- **TLS-required**: transport-layer encryption is always enforced

---

## Manual Setup (without the install script)

### 1. Create a Wasmer token

Go to [wasmer.io/settings/access-tokens](https://wasmer.io/settings/access-tokens) and create a new token.

### 2. Edit deploy/worker/app.yaml

```yaml
kind: wasmer.io/App.v0
name: YOUR_NAMESPACE/xhttp-relay

env:
  TARGET_DOMAIN: "vpn.yourdomain.com"   # your Xray server domain
  RELAY_PATH:    "/your-secret-path"    # XHTTP path
  RELAY_KEY:     "your-secret-key"      # optional auth header value
```

### 3. Deploy

```bash
cd deploy/worker
wasmer login YOUR_TOKEN
wasmer deploy
```

### 4. Configure Xray on your server

`/usr/local/etc/xray/config.json`:

```json
{
  "inbounds": [{
    "port": 443,
    "protocol": "vless",
    "settings": {
      "clients": [{"id": "YOUR-UUID", "flow": ""}],
      "decryption": "none"
    },
    "streamSettings": {
      "network": "xhttp",
      "security": "tls",
      "tlsSettings": {
        "certificates": [{
          "certificateFile": "/etc/xray/certs/yourdomain.crt",
          "keyFile":         "/etc/xray/certs/yourdomain.key"
        }]
      },
      "xhttpSettings": {
        "path":          "/your-secret-path",
        "host":          "vpn.yourdomain.com",
        "mode":          "auto",
        "xPaddingBytes": "100-1000",
        "headers":       {"x-relay-key": "your-secret-key"}
      }
    }
  }]
}
```

---

## Client VLESS Link Format

```
vless://UUID@YOUR_APP.wasmer.app:443?encryption=none&security=tls&sni=YOUR_APP.wasmer.app&type=xhttp&path=/your-path&host=YOUR_APP.wasmer.app&xPaddingBytes=100-1000#XHTTP-Wasmer
```

Import this link into:
- **v2rayN** (Windows)
- **Nekoray** (Windows / Linux)
- **Hiddify** (Android / iOS / Windows)
- **V2Box** (iOS)

---

## Troubleshooting

| Problem | Solution |
|---------|----------|
| Xray won't start | `journalctl -u xray -n 50` |
| SSL issuance fails | Port 80 must be open; DNS must point to this server |
| `wasmer deploy` errors | Check token: `wasmer whoami` |
| Relay returns 502 | Verify `TARGET_DOMAIN` in app.yaml |
| Client won't connect | Verify UUID, path and SNI in VLESS link |

---

## License

GPL-3.0 — derived from [avacocloud/XHTTP-Installer](https://github.com/avacocloud/XHTTP-Installer)

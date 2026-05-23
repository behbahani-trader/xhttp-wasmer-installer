#!/usr/bin/env bash
# =============================================================================
# XHTTP-Wasmer Installer
# Automated deployment of VLESS+XHTTP+TLS proxy with Wasmer Edge relay
#
# Copyright (C) 2025 – adapted from avacocloud/XHTTP-Installer (GPL-3.0)
# Build: avc-7f3a92e1-2025-wasmer
#
# Usage:
#   bash <(curl -fsSL https://raw.githubusercontent.com/behbahani-trader/xhttp-wasmer-installer/main/install.sh)
# =============================================================================

set -euo pipefail

# ---------------------------------------------------------------------------
# Colour helpers
# ---------------------------------------------------------------------------
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
CYAN='\033[0;36m'; BOLD='\033[1m'; RESET='\033[0m'

info()    { echo -e "${CYAN}  --> ${RESET}$*"; }
ok()      { echo -e "${GREEN}  ✔  ${RESET}$*"; }
warn()    { echo -e "${YELLOW}  !  ${RESET}$*"; }
die()     { echo -e "${RED}  ✘  ${RESET}$*" >&2; exit 1; }
section() { echo -e "\n${BOLD}══════════════════════════════════════════${RESET}"; \
            echo -e "${BOLD}  $*${RESET}"; \
            echo -e "${BOLD}══════════════════════════════════════════${RESET}"; }

# ---------------------------------------------------------------------------
# Root check
# ---------------------------------------------------------------------------
[[ $EUID -eq 0 ]] || die "Run as root: sudo bash <(curl ...)"

# ---------------------------------------------------------------------------
# Phase 1 – Preflight
# ---------------------------------------------------------------------------
section "Phase 1 – Preflight checks"

OS_ID=$(grep -oP '(?<=^ID=).+' /etc/os-release | tr -d '"' || true)
OS_VER=$(grep -oP '(?<=^VERSION_ID=).+' /etc/os-release | tr -d '"' || true)
[[ "$OS_ID" == "ubuntu" ]] || die "Ubuntu required (detected: $OS_ID)"
[[ "${OS_VER%%.*}" -ge 20 ]] || die "Ubuntu 20.04+ required (detected: $OS_VER)"
ok "OS: Ubuntu $OS_VER"

# Check available RAM and create swap if needed
TOTAL_RAM_MB=$(free -m | awk '/^Mem:/{print $2}')
if [[ $TOTAL_RAM_MB -lt 512 ]]; then
    warn "Low RAM (${TOTAL_RAM_MB} MB). Creating 1 GB swap…"
    if ! swapon --show | grep -q '/swapfile'; then
        fallocate -l 1G /swapfile
        chmod 600 /swapfile
        mkswap /swapfile
        swapon /swapfile
        echo '/swapfile none swap sw 0 0' >> /etc/fstab
    fi
    ok "Swap active"
fi

# Port 80 and 443 must be free (needed for acme.sh and Xray)
for PORT in 80 443; do
    if ss -tlnp | grep -q ":${PORT} "; then
        warn "Port $PORT is in use. Attempting to free it…"
        fuser -k "${PORT}"/tcp 2>/dev/null || true
        sleep 1
        ss -tlnp | grep -q ":${PORT} " && die "Port $PORT still occupied after kill."
        ok "Port $PORT freed"
    else
        ok "Port $PORT is free"
    fi
done

# ---------------------------------------------------------------------------
# Phase 2 – Install dependencies
# ---------------------------------------------------------------------------
section "Phase 2 – Installing dependencies"

apt-get update -qq
apt-get install -y -qq curl git unzip socat nginx
ok "System packages installed"

# Install Xray
if ! command -v xray &>/dev/null; then
    info "Installing Xray-core…"
    bash <(curl -fsSL https://github.com/XTLS/Xray-install/raw/main/install-release.sh)
fi
XRAY_VER=$(xray version 2>&1 | head -1 | grep -oP '\d+\.\d+\.\d+' | head -1 || echo "unknown")
ok "Xray $XRAY_VER installed"

# Install acme.sh
if [[ ! -f ~/.acme.sh/acme.sh ]]; then
    info "Installing acme.sh…"
    curl -fsSL https://get.acme.sh | sh -s email="$CFG_EMAIL" 2>/dev/null
    source ~/.bashrc 2>/dev/null || true
fi
ok "acme.sh ready"

# Install Wasmer CLI
if ! command -v wasmer &>/dev/null; then
    info "Installing Wasmer CLI…"
    curl -fsSL https://get.wasmer.io | sh
    # Re-source PATH so wasmer is available in this session
    export PATH="$HOME/.wasmer/bin:$PATH"
    source "$HOME/.wasmer/wasmer.sh" 2>/dev/null || true
fi
WASMER_VER=$(wasmer --version 2>&1 | head -1 || echo "unknown")
ok "Wasmer $WASMER_VER installed"

# ---------------------------------------------------------------------------
# Phase 3 – User input
# ---------------------------------------------------------------------------
section "Phase 3 – Configuration"

read -rp "  Domain (must point to THIS server's IP via DNS A-record): " CFG_DOMAIN
[[ -n "$CFG_DOMAIN" ]] || die "Domain cannot be empty"

read -rp "  Email (for Let's Encrypt certificate): " CFG_EMAIL
[[ -n "$CFG_EMAIL" ]] || die "Email cannot be empty"

read -rp "  Xray inbound port [default: 443]: " CFG_PORT
CFG_PORT="${CFG_PORT:-443}"

read -rp "  XHTTP path [default: /$(head -c6 /dev/urandom | base64 | tr -dc 'a-z0-9' | head -c6)]: " CFG_PATH
if [[ -z "$CFG_PATH" ]]; then
    CFG_PATH="/$(head -c6 /dev/urandom | base64 | tr -dc 'a-z0-9' | head -c6)"
fi
[[ "$CFG_PATH" == /* ]] || CFG_PATH="/$CFG_PATH"

read -rp "  Wasmer account token (get from https://wasmer.io/settings/access-tokens): " WASMER_TOKEN
[[ -n "$WASMER_TOKEN" ]] || die "Wasmer token cannot be empty"

read -rp "  Wasmer namespace/username (your Wasmer username): " WASMER_NS
[[ -n "$WASMER_NS" ]] || die "Wasmer namespace cannot be empty"

read -rp "  App name on Wasmer Edge [default: xhttp-relay]: " WASMER_APP
WASMER_APP="${WASMER_APP:-xhttp-relay}"

# Generate a random relay key for extra security
RELAY_KEY=$(head -c16 /dev/urandom | base64 | tr -dc 'A-Za-z0-9' | head -c24)

echo ""
ok "Configuration collected"
echo ""
echo "  Domain    : $CFG_DOMAIN"
echo "  Port      : $CFG_PORT"
echo "  Path      : $CFG_PATH"
echo "  Relay key : $RELAY_KEY"
echo "  Wasmer NS : $WASMER_NS"
echo ""

read -rp "  Proceed? [y/N]: " CONFIRM
[[ "${CONFIRM,,}" == "y" ]] || { warn "Aborted."; exit 0; }

# ---------------------------------------------------------------------------
# Phase 4a – SSL certificate via acme.sh
# ---------------------------------------------------------------------------
section "Phase 4a – SSL Certificate"

# Stop nginx temporarily so acme.sh can bind port 80
systemctl stop nginx 2>/dev/null || true

CERT_DIR="/etc/xray/certs"
mkdir -p "$CERT_DIR"

~/.acme.sh/acme.sh --set-default-ca --server letsencrypt 2>/dev/null || true

# Check if certificate already exists
if [[ -f "$CERT_DIR/${CFG_DOMAIN}.crt" && -f "$CERT_DIR/${CFG_DOMAIN}.key" ]]; then
    warn "Certificate already exists for $CFG_DOMAIN — reusing."
    ok "Certificate ready"
else
    info "Issuing certificate for $CFG_DOMAIN…"
    ISSUE_OUTPUT=$(~/.acme.sh/acme.sh --issue --standalone \
        -d "$CFG_DOMAIN" \
        --fullchain-file "$CERT_DIR/${CFG_DOMAIN}.crt" \
        --key-file       "$CERT_DIR/${CFG_DOMAIN}.key" \
        2>&1) || ISSUE_RC=$?

    if echo "$ISSUE_OUTPUT" | grep -q "Domains not changed"; then
        warn "Domains not changed — installing existing certificate…"
        ~/.acme.sh/acme.sh --install-cert -d "$CFG_DOMAIN" \
            --fullchain-file "$CERT_DIR/${CFG_DOMAIN}.crt" \
            --key-file       "$CERT_DIR/${CFG_DOMAIN}.key" 2>&1
    elif [[ "${ISSUE_RC:-0}" -ne 0 ]]; then
        # Force re-issue
        warn "First attempt failed. Retrying with --force…"
        ~/.acme.sh/acme.sh --issue --standalone \
            -d "$CFG_DOMAIN" \
            --fullchain-file "$CERT_DIR/${CFG_DOMAIN}.crt" \
            --key-file       "$CERT_DIR/${CFG_DOMAIN}.key" \
            --force 2>&1 || die "Certificate issuance failed. Check DNS and port 80."
    fi
    ok "Certificate issued"
fi

chmod 600 "$CERT_DIR/${CFG_DOMAIN}.key"
chown root:root "$CERT_DIR/"*

# ---------------------------------------------------------------------------
# Phase 4b – Xray configuration
# ---------------------------------------------------------------------------
section "Phase 4b – Xray configuration"

XRAY_UUID=$(xray uuid)
ok "Generated UUID: $XRAY_UUID"

mkdir -p /usr/local/etc/xray

cat > /usr/local/etc/xray/config.json <<EOF
{
  "log": {
    "loglevel": "warning"
  },
  "inbounds": [
    {
      "port": ${CFG_PORT},
      "protocol": "vless",
      "settings": {
        "clients": [
          {
            "id": "${XRAY_UUID}",
            "flow": ""
          }
        ],
        "decryption": "none"
      },
      "streamSettings": {
        "network": "xhttp",
        "security": "tls",
        "tlsSettings": {
          "certificates": [
            {
              "certificateFile": "${CERT_DIR}/${CFG_DOMAIN}.crt",
              "keyFile":         "${CERT_DIR}/${CFG_DOMAIN}.key"
            }
          ]
        },
        "xhttpSettings": {
          "path":          "${CFG_PATH}",
          "host":          "${CFG_DOMAIN}",
          "mode":          "auto",
          "xPaddingBytes": "100-1000",
          "headers": {
            "x-relay-key": "${RELAY_KEY}"
          }
        }
      },
      "sniffing": {
        "enabled": true,
        "destOverride": ["http","tls"]
      }
    }
  ],
  "outbounds": [
    {
      "protocol": "freedom",
      "tag": "direct"
    },
    {
      "protocol": "blackhole",
      "tag": "blocked"
    }
  ],
  "routing": {
    "domainStrategy": "IPIfNonMatch",
    "rules": [
      {
        "type": "field",
        "ip": ["geoip:private"],
        "outboundTag": "blocked"
      }
    ]
  }
}
EOF

ok "Xray config written to /usr/local/etc/xray/config.json"

# Ensure Xray runs as root (needs port 443)
mkdir -p /etc/systemd/system/xray.service.d
cat > /etc/systemd/system/xray.service.d/override.conf <<'SYSD'
[Service]
User=root
AmbientCapabilities=CAP_NET_BIND_SERVICE
SYSD

systemctl daemon-reload
systemctl enable xray
systemctl restart xray
sleep 2
systemctl is-active xray || die "Xray failed to start. Run: journalctl -u xray -n 50"
ok "Xray service running"

# ---------------------------------------------------------------------------
# Phase 4c – Deploy relay worker to Wasmer Edge
# ---------------------------------------------------------------------------
section "Phase 4c – Deploying to Wasmer Edge"

DEPLOY_DIR="/root/xhttp-wasmer-relay"
mkdir -p "$DEPLOY_DIR/src"

# Copy worker source
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
if [[ -f "$SCRIPT_DIR/deploy/worker/src/index.js" ]]; then
    cp "$SCRIPT_DIR/deploy/worker/src/index.js" "$DEPLOY_DIR/src/index.js"
else
    # Inline the worker source if running directly from curl
    info "Writing worker source inline…"
    cat > "$DEPLOY_DIR/src/index.js" <<'WORKER'
const TARGET_DOMAIN = process.env.TARGET_DOMAIN || "";
const RELAY_PATH    = process.env.RELAY_PATH    || "";
const RELAY_KEY     = process.env.RELAY_KEY     || "";

const STRIP_REQUEST_HEADERS = new Set([
  "host","connection","keep-alive","proxy-connection",
  "proxy-authenticate","proxy-authorization","te","trailer",
  "transfer-encoding","upgrade","x-wasmer-app","x-wasmer-edge",
  "cdn-loop","x-forwarded-proto",
]);

const STRIP_RESPONSE_HEADERS = new Set([
  "transfer-encoding","connection","keep-alive","trailer","te",
]);

async function handler(request) {
  if (!TARGET_DOMAIN)
    return new Response("Relay misconfigured: TARGET_DOMAIN not set.", { status: 503 });

  const method = request.method.toUpperCase();
  if (!["GET","HEAD","POST","PUT"].includes(method))
    return new Response("Method Not Allowed", { status: 405 });

  if (RELAY_KEY) {
    const clientKey = request.headers.get("x-relay-key") || "";
    if (clientKey !== RELAY_KEY) return new Response("Not Found", { status: 404 });
  }

  const url = new URL(request.url);
  if (RELAY_PATH && !url.pathname.startsWith(RELAY_PATH))
    return new Response("Not Found", { status: 404 });

  const upstreamUrl = "https://" + TARGET_DOMAIN + url.pathname + (url.search || "");

  const forwardedHeaders = new Headers();
  for (const [k, v] of request.headers.entries())
    if (!STRIP_REQUEST_HEADERS.has(k.toLowerCase())) forwardedHeaders.set(k, v);

  const clientIp = request.headers.get("x-real-ip") || request.headers.get("x-forwarded-for") || "";
  if (clientIp) forwardedHeaders.set("x-forwarded-for", clientIp);
  forwardedHeaders.set("host", TARGET_DOMAIN);

  let upstreamResponse;
  try {
    upstreamResponse = await fetch(upstreamUrl, {
      method:   request.method,
      headers:  forwardedHeaders,
      body:     ["GET","HEAD"].includes(method) ? undefined : request.body,
      redirect: "manual",
    });
  } catch (err) {
    return new Response("Bad Gateway: upstream unreachable", { status: 502 });
  }

  const responseHeaders = new Headers();
  for (const [k, v] of upstreamResponse.headers.entries())
    if (!STRIP_RESPONSE_HEADERS.has(k.toLowerCase())) responseHeaders.set(k, v);
  responseHeaders.set("cache-control", "no-store, no-cache");

  return new Response(upstreamResponse.body, {
    status:  upstreamResponse.status,
    headers: responseHeaders,
  });
}

addEventListener("fetch", (fetchEvent) => {
  fetchEvent.respondWith(handler(fetchEvent.request));
});
WORKER
fi

# Write wasmer.toml
cat > "$DEPLOY_DIR/wasmer.toml" <<EOF
[package]
name        = "xhttp-relay"
version     = "1.0.0"
description = "XHTTP relay worker"
license     = "GPL-3.0"

[[dependencies]]
name    = "wasmer/winterjs"
version = "^1.1"

[fs]
"/src" = "src"

[[command]]
name   = "script"
module = "wasmer/winterjs:winterjs"
runner = "https://webc.org/runner/wasi"

  [command.annotations.wasi]
  main-args = ["/src/index.js"]
EOF

# Write app.yaml with real values substituted
cat > "$DEPLOY_DIR/app.yaml" <<EOF
---
kind: wasmer.io/App.v0
name: ${WASMER_NS}/${WASMER_APP}
description: "VLESS+XHTTP+TLS relay via Wasmer Edge"
package: .

env:
  TARGET_DOMAIN: "${CFG_DOMAIN}"
  RELAY_PATH:    "${CFG_PATH}"
  RELAY_KEY:     "${RELAY_KEY}"

redirect:
  force_https: true

scaling:
  mode: single_concurrency

locality:
  regions:
    - eu-west
EOF

# Authenticate with Wasmer
info "Logging in to Wasmer Edge…"
export PATH="$HOME/.wasmer/bin:$PATH"
wasmer login "$WASMER_TOKEN" || die "Wasmer login failed. Check your token."
ok "Wasmer authenticated"

# Deploy
info "Deploying to Wasmer Edge (this may take 1-2 minutes)…"
cd "$DEPLOY_DIR"
DEPLOY_OUTPUT=$(wasmer deploy --non-interactive 2>&1) || {
    echo "$DEPLOY_OUTPUT"
    die "Wasmer deploy failed."
}
echo "$DEPLOY_OUTPUT"

# Extract deployed URL
WASMER_URL=$(echo "$DEPLOY_OUTPUT" | grep -oP 'https://[a-z0-9\-]+\.wasmer\.app' | head -1 || true)
[[ -n "$WASMER_URL" ]] || WASMER_URL="https://${WASMER_APP}-${WASMER_NS}.wasmer.app"
ok "Deployed to: $WASMER_URL"

# ---------------------------------------------------------------------------
# Phase 5 – Health checks
# ---------------------------------------------------------------------------
section "Phase 5 – Health checks"

info "Testing direct Xray reachability (HTTPS)…"
HTTP_STATUS=$(curl -so /dev/null -w "%{http_code}" \
    --max-time 10 \
    --resolve "${CFG_DOMAIN}:${CFG_PORT}:127.0.0.1" \
    "https://${CFG_DOMAIN}:${CFG_PORT}${CFG_PATH}" 2>/dev/null || echo "000")
if [[ "$HTTP_STATUS" =~ ^(200|400|404|405)$ ]]; then
    ok "Xray responds (HTTP $HTTP_STATUS)"
else
    warn "Xray returned HTTP $HTTP_STATUS — check logs: journalctl -u xray -n 30"
fi

info "Testing Wasmer relay → Xray chain…"
RELAY_STATUS=$(curl -so /dev/null -w "%{http_code}" \
    -H "x-relay-key: ${RELAY_KEY}" \
    --max-time 15 \
    "${WASMER_URL}${CFG_PATH}" 2>/dev/null || echo "000")
if [[ "$RELAY_STATUS" =~ ^(200|400|404|405)$ ]]; then
    ok "Relay chain responds (HTTP $RELAY_STATUS)"
else
    warn "Relay chain returned HTTP $RELAY_STATUS — CDN propagation may take a few minutes"
fi

# ---------------------------------------------------------------------------
# Phase 6 – Output client configuration
# ---------------------------------------------------------------------------
section "Phase 6 – Client Configuration"

# URL-encode the path (replace / with %2F only if needed — VLESS clients accept raw slash)
WASMER_HOST="${WASMER_URL#https://}"
VLESS_LINK="vless://${XRAY_UUID}@${WASMER_HOST}:443?encryption=none&security=tls&sni=${WASMER_HOST}&type=xhttp&path=${CFG_PATH}&host=${WASMER_HOST}&xPaddingBytes=100-1000#XHTTP-Wasmer"

echo ""
echo -e "${GREEN}╔══════════════════════════════════════════════════════╗${RESET}"
echo -e "${GREEN}║         XHTTP-Wasmer Installation Complete!          ║${RESET}"
echo -e "${GREEN}╚══════════════════════════════════════════════════════╝${RESET}"
echo ""
echo -e "  ${BOLD}Wasmer Edge URL :${RESET} $WASMER_URL"
echo -e "  ${BOLD}Server Domain   :${RESET} $CFG_DOMAIN"
echo -e "  ${BOLD}Xray Port       :${RESET} $CFG_PORT"
echo -e "  ${BOLD}Path            :${RESET} $CFG_PATH"
echo -e "  ${BOLD}UUID            :${RESET} $XRAY_UUID"
echo -e "  ${BOLD}Relay Key       :${RESET} $RELAY_KEY"
echo ""
echo -e "  ${BOLD}${CYAN}VLESS Link (copy to v2rayN / Nekoray / Hiddify):${RESET}"
echo ""
echo "  $VLESS_LINK"
echo ""
echo -e "  ${BOLD}Config saved to:${RESET} /root/xhttp-client-config.txt"

# Save config to file
cat > /root/xhttp-client-config.txt <<EOF
# XHTTP-Wasmer Client Configuration
# Generated: $(date -u +"%Y-%m-%d %H:%M UTC")

Wasmer Edge URL : $WASMER_URL
Server Domain   : $CFG_DOMAIN
Port            : $CFG_PORT
Path            : $CFG_PATH
UUID            : $XRAY_UUID
Relay Key       : $RELAY_KEY

VLESS Link:
$VLESS_LINK
EOF

ok "Done."

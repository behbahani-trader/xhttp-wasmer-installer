/**
 * XHTTP Relay Worker for Wasmer Edge
 *
 * Copyright (C) 2025 avaco_cloud (adapted for Wasmer Edge)
 * License: GPL-3.0
 * Build: avc-7f3a92e1-2025-wasmer
 *
 * This WinterCG-compatible service worker acts as a transparent
 * HTTP relay/proxy. All requests are forwarded to the upstream
 * Xray (VLESS+XHTTP+TLS) server.
 *
 * Environment variables (set in app.yaml → env):
 *   TARGET_DOMAIN  — upstream hostname, e.g. "sub.example.com"
 *   RELAY_PATH     — allowed path prefix, e.g. "/xhttp" (optional)
 *   RELAY_KEY      — shared secret for auth header (optional)
 */

// ---------------------------------------------------------------------------
// Configuration
// ---------------------------------------------------------------------------

const TARGET_DOMAIN = process.env.TARGET_DOMAIN || "";
const RELAY_PATH    = process.env.RELAY_PATH    || "";   // e.g. "/xhttp"
const RELAY_KEY     = process.env.RELAY_KEY     || "";   // optional auth key

// Headers that must never be forwarded upstream (would break the tunnel)
const STRIP_REQUEST_HEADERS = new Set([
  "host",
  "connection",
  "keep-alive",
  "proxy-connection",
  "proxy-authenticate",
  "proxy-authorization",
  "te",
  "trailer",
  "transfer-encoding",
  "upgrade",
  // Wasmer / CDN internal headers
  "x-wasmer-app",
  "x-wasmer-edge",
  "cdn-loop",
  "x-forwarded-proto",
]);

// Headers that must never be forwarded to the client from upstream
const STRIP_RESPONSE_HEADERS = new Set([
  "transfer-encoding",
  "connection",
  "keep-alive",
  "trailer",
  "te",
]);

// ---------------------------------------------------------------------------
// Main fetch handler
// ---------------------------------------------------------------------------

async function handler(request) {
  // ---- 1. Validate configuration -----------------------------------------
  if (!TARGET_DOMAIN) {
    return new Response(
      "Relay misconfigured: TARGET_DOMAIN environment variable is not set.",
      { status: 503 }
    );
  }

  // ---- 2. Only allow methods used by XHTTP (VLESS) ----------------------
  const method = request.method.toUpperCase();
  if (!["GET", "HEAD", "POST", "PUT"].includes(method)) {
    return new Response("Method Not Allowed", { status: 405 });
  }

  // ---- 3. Optional relay-key authentication ------------------------------
  if (RELAY_KEY) {
    const clientKey = request.headers.get("x-relay-key") || "";
    if (clientKey !== RELAY_KEY) {
      // Return generic 404 to avoid leaking that a relay exists
      return new Response("Not Found", { status: 404 });
    }
  }

  // ---- 4. Optional path restriction --------------------------------------
  const url = new URL(request.url);
  if (RELAY_PATH && !url.pathname.startsWith(RELAY_PATH)) {
    return new Response("Not Found", { status: 404 });
  }

  // ---- 5. Build upstream URL ---------------------------------------------
  const upstreamUrl =
    "https://" +
    TARGET_DOMAIN +
    url.pathname +
    (url.search ? url.search : "");

  // ---- 6. Build forwarded headers ----------------------------------------
  const forwardedHeaders = new Headers();

  for (const [key, value] of request.headers.entries()) {
    if (!STRIP_REQUEST_HEADERS.has(key.toLowerCase())) {
      forwardedHeaders.set(key, value);
    }
  }

  // Preserve original client IP for logging on the Xray side
  const clientIp =
    request.headers.get("x-real-ip") ||
    request.headers.get("x-forwarded-for") ||
    "";
  if (clientIp) {
    forwardedHeaders.set("x-forwarded-for", clientIp);
  }

  // Set Host to match upstream TLS SNI
  forwardedHeaders.set("host", TARGET_DOMAIN);

  // ---- 7. Forward request to upstream ------------------------------------
  let upstreamResponse;
  try {
    upstreamResponse = await fetch(upstreamUrl, {
      method:  request.method,
      headers: forwardedHeaders,
      body:    ["GET", "HEAD"].includes(method) ? undefined : request.body,
      // Do not follow redirects — pass them through to the client
      redirect: "manual",
    });
  } catch (err) {
    return new Response("Bad Gateway: upstream unreachable", { status: 502 });
  }

  // ---- 8. Build response headers -----------------------------------------
  const responseHeaders = new Headers();
  for (const [key, value] of upstreamResponse.headers.entries()) {
    if (!STRIP_RESPONSE_HEADERS.has(key.toLowerCase())) {
      responseHeaders.set(key, value);
    }
  }

  // Prevent the CDN from caching VPN tunnel data
  responseHeaders.set("cache-control", "no-store, no-cache");

  // ---- 9. Stream response back to client ---------------------------------
  return new Response(upstreamResponse.body, {
    status:  upstreamResponse.status,
    headers: responseHeaders,
  });
}

// ---------------------------------------------------------------------------
// WinterCG entry point
// ---------------------------------------------------------------------------

addEventListener("fetch", (fetchEvent) => {
  fetchEvent.respondWith(handler(fetchEvent.request));
});

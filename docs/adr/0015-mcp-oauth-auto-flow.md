# ADR-0015: MCP OAuth: v2 Auto Flow (Discovery + DCR + Loopback)

Remote MCP servers that require OAuth are connected via an AUTO-first flow: the user enables the switch and taps 开始授权 — the app discovers the authorization server metadata (RFC 8414 `{origin}/.well-known/oauth-authorization-server`), dynamically registers a public client (RFC 7591 DCR, `token_endpoint_auth_method: none`), starts a loopback callback server (RFC 8252), and completes the exchange automatically when the browser redirect lands. Manual paste remains the fallback.

This supersedes the original v1 decision (static config + manual paste, no discovery/DCR). The v1 shape was validated in real-world testing and found unusable for ordinary users: manual endpoint entry and code copying are acceptable only for power users. The auto flow layers on top without breaking the manual path.

## Considered Options

1. **Full automation (chosen).** Discovery + DCR + loopback in one tap. Costs: servers without a registration endpoint fall back to manual client ID; servers without RFC 8414 metadata fall back to manual endpoints; loopback-hostile environments fall back to paste.
2. **Static config + manual paste (original v1).** Rejected after real-world testing (Tavily): too many fields, DCR still required by the target server, and the paste UX confused users.
3. **Custom URI scheme callback.** Rejected: 5 platform registrations (Android manifest, iOS/macOS `CFBundleURLTypes`, Windows registry, Linux `.desktop`) for a benefit the loopback server already provides.
4. **Reactive 401-retry refresh layer.** Rejected: the vendored `mcp_client` library already implements proactive refresh in both transports (`OAuthTokenManager` timer for Streamable HTTP, 80%-lifetime timer + reconnect for SSE). Only missing pieces were a token persistence hook and surfacing refresh failure as `McpStatus.error`.

## Key implementation details

- **Redirect URI uses `localhost` with a random port**, registered portless (`http://127.0.0.1/callback` + `http://localhost/callback` + OOB) at DCR time. Browsers race `::1` and `127.0.0.1`, so dual-stack loopback binding (IPv4 + IPv6) survives environments that intercept IPv4 loopback (verified against Tavily: both variants must be registered for `localhost` to be accepted; the server must accept the loopback port-wildcard rule).
- **Loopback self-probe**: after binding, the server TCP-connects to itself; unreachable ports (Hyper-V/WSL2 excluded ranges, security software) are abandoned and rebound up to 5 times before falling back to paste.
- **Callback extraction handles relative URIs** (`/callback?code=...` is what `request.uri` yields) — a regression here produced "authorization code does not exist".
- **Exchange retries redirect variants**: authorize-time value → portless localhost → portless 127.0.0.1 → user-configured redirect URI → OOB → none. Some servers validate the token request against the registered (portless) URI.
- **`clientRegistrationVersion` migration**: auto-registered clients from older builds (version 1, IPv4-only variant) are discarded and re-registered once; manually entered client IDs (version 0) are never auto-replaced. Persisted shape stays compatible.

## Consequences

- `McpServerConfig` gains a nested app-level `McpOAuthConfig` DTO + persisted `OAuthToken` (SharedPreferences JSON, included in backups). A secure-storage refactor is planned later.
- OAuth Bearer overwrites any manual `Authorization` header (natural library merge order).
- Re-auth entry point is the existing server-card error state; the edit page hosts the OAuth section (switch-gated, primary 开始授权 button, advanced config collapsed). No mid-conversation blocking dialogs.
- Flow state (PKCE verifier + state + loopback) lives in memory in `OAuthFlowService`; an app restart mid-flow means redoing the browser authorization. Sessions survive exchange failures so a fresh code can be pasted.
- `OAuthFlowService` and `McpOAuthSectionController` are provider-agnostic: a future OAuth LLM provider (e.g. xAI) reuses discovery/DCR/loopback and the section controller by injecting its own begin/complete implementations; its token attach would be a `DioHttpClient` 401-refresh interceptor, parallel to the MCP transport hook.

// GitHub tokens are returned once over TLS to the native Keychain client.
// This service stores only transient PKCE state and encrypted app configuration.
export interface Store {
  get(key: string): Promise<string | null>;
  put(key: string, value: string, options?: { expirationTtl: number }): Promise<void>;
  delete(key: string): Promise<void>;
  consume(key: string, expected: string): Promise<boolean>;
}
export interface AuthContext { STATE: Store; STORAGE_KEY: string; OWNER: string }
interface App { client_id: string; client_secret: string; html_url: string; owner: { login: string } }
interface Session { challenge: string; created: number }
const encoder = new TextEncoder();
const safe = /^[A-Za-z0-9_-]{43}$/;
const callback = "keelmobile://github/callback";
const permissions = { contents: "write", pull_requests: "write", actions: "write", metadata: "read" };
function b64(data: Uint8Array): string { return btoa(String.fromCharCode(...data)).replaceAll("+", "-").replaceAll("/", "_").replaceAll("=", ""); }
function bytes(value: string): Uint8Array { return Uint8Array.from(atob(value.replaceAll("-", "+").replaceAll("_", "/")), c => c.charCodeAt(0)); }
function random(): string { return b64(crypto.getRandomValues(new Uint8Array(32))); }
function headers(extra: Record<string, string> = {}): Record<string, string> {
  return { "Cache-Control": "no-store", "Referrer-Policy": "no-referrer", "X-Content-Type-Options": "nosniff", ...extra };
}
function json(value: unknown, status = 200): Response { return Response.json(value, { status, headers: headers() }); }
function redirect(url: string): Response { return new Response(null, { status: 302, headers: headers({ Location: url }) }); }
function escape(value: string): string { return value.replaceAll("&", "&amp;").replaceAll('"', "&quot;").replaceAll("<", "&lt;").replaceAll(">", "&gt;"); }
function setupFailure(reason: "expired" | "conversion" | "owner" | "unavailable", step = ""): Response {
  const descriptions = {
    expired: "This setup link has expired or was opened in a different browser. Start again below, and finish in the same browser.",
    conversion: "GitHub could not finish creating the connection. Start again below. If GitHub says the app name is already taken, choose a different name on its form.",
    owner: "The GitHub App must be created while signed in as the Keel account owner. Switch to the correct account on GitHub, then start again.",
    unavailable: "The connection could not be saved. Please try setup again. If it fails again, report this message so it can be investigated.",
  };
  return page("GitHub setup needs another try", `<p>${descriptions[reason]}</p><a href="/setup">Restart GitHub setup</a><p><small>Setup status: ${reason}${step ? " (" + escape(step) + ")" : ""}. No GitHub token is needed.</small></p>`);
}
function page(title: string, body: string, extra: Record<string, string> = {}): Response {
  return new Response(`<!doctype html><html lang="en"><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1"><title>${escape(title)}</title><style>body{font:18px system-ui;background:#101718;color:#f4f8f7;max-width:560px;margin:12vh auto;padding:24px;line-height:1.6}h1{line-height:1.15}button,a{display:inline-block;background:#7ce8c2;color:#06251c;border:0;border-radius:12px;padding:14px 20px;font:inherit;text-decoration:none}small{color:#acbdb7}</style><h1>${escape(title)}</h1>${body}</html>`,
    { headers: headers({ "Content-Type": "text/html; charset=utf-8", "Content-Security-Policy": "default-src 'none'; style-src 'unsafe-inline'; form-action https://github.com; frame-ancestors 'none'; base-uri 'none'", ...extra }) });
}
async function key(env: AuthContext): Promise<CryptoKey> {
  return crypto.subtle.importKey("raw", bytes(env.STORAGE_KEY), "AES-GCM", false, ["encrypt", "decrypt"]);
}
async function saveApp(app: App, env: AuthContext): Promise<void> {
  const iv = crypto.getRandomValues(new Uint8Array(12));
  const encrypted = await crypto.subtle.encrypt({ name: "AES-GCM", iv }, await key(env), encoder.encode(JSON.stringify(app)));
  await env.STATE.put("app", JSON.stringify({ iv: b64(iv), data: b64(new Uint8Array(encrypted)) }));
}
async function loadApp(env: AuthContext): Promise<App | null> {
  const value = await env.STATE.get("app"); if (!value) return null;
  const stored = JSON.parse(value);
  const data = await crypto.subtle.decrypt({ name: "AES-GCM", iv: bytes(stored.iv) }, await key(env), bytes(stored.data));
  return JSON.parse(new TextDecoder().decode(data));
}
async function boundedJSON(request: Request | Response, maximum = 4096): Promise<Record<string, string>> {
  const reader = request.body?.getReader(); if (!reader) throw new Error("body");
  let text = ""; const decoder = new TextDecoder(); let size = 0;
  try { while (true) { const part = await reader.read(); if (part.done) break; size += part.value.length;
    if (size > maximum) throw new Error("size"); text += decoder.decode(part.value, { stream: true }); }
  } finally { await reader.cancel(); }
  const value = JSON.parse(text + decoder.decode());
  if (!value || Array.isArray(value) || typeof value !== "object") throw new Error("body");
  return value;
}
async function githubToken(app: App, fields: Record<string, string>, network: typeof fetch): Promise<Response> {
  const response = await network("https://github.com/login/oauth/access_token", {
    method: "POST", redirect: "manual", signal: AbortSignal.timeout(15_000), headers: { Accept: "application/json", "Content-Type": "application/json" },
    body: JSON.stringify({ client_id: app.client_id, client_secret: app.client_secret, ...fields }),
  });
  if (!response.ok) return json({ error: "authorization_failed" }, 401);
  const value = await boundedJSON(response);
  if (typeof value.access_token !== "string" || value.token_type !== "bearer") return json({ error: "authorization_failed" }, 401);
  // Never persist, log, or put a user token in a redirect URL.
  return json({ access_token: value.access_token, refresh_token: value.refresh_token,
    expires_in: value.expires_in, refresh_token_expires_in: value.refresh_token_expires_in, token_type: "bearer" });
}
export async function handle(request: Request, env: AuthContext, network: typeof fetch = fetch): Promise<Response> {
  let stage = "routing";
  try {
    const url = new URL(request.url); const origin = url.origin;
    if (url.protocol !== "https:" && url.hostname !== "localhost") return json({ error: "https_required" }, 400);
    if (request.method === "GET" && ["/", "/health", "/config"].includes(url.pathname)) {
      const app = await loadApp(env);
      if (url.pathname === "/health") {
        // Exercise deployed secret binding + Web Crypto without saving test data.
        const iv = crypto.getRandomValues(new Uint8Array(12));
        const aes = await key(env);
        const sealed = await crypto.subtle.encrypt({ name: "AES-GCM", iv }, aes, encoder.encode("health"));
        const opened = await crypto.subtle.decrypt({ name: "AES-GCM", iv }, aes, sealed);
        return json({ configured: !!app, storage_crypto_ready: new TextDecoder().decode(opened) === "health" });
      }
      if (url.pathname === "/") return page("Connect Keel to GitHub", "<p>Sign in from Keel on your iPhone to choose your repositories.</p><p><small>Account setup is managed by the app owner.</small></p>");
      return json({ configured: !!app, client_id: app?.client_id, install_url: app ? app.html_url + "/installations/new" : undefined });
    }
    if (request.method === "GET" && url.pathname === "/setup") {
      if (await loadApp(env)) return page("GitHub connector is configured", "<p>Return to Keel and tap Connect GitHub.</p>");
      const state = random(); await env.STATE.put("setup:" + state, "pending", { expirationTtl: 3600 });
      const manifest = { name: "Keel Mobile Oliver", url: origin, redirect_url: origin + "/setup/callback",
        callback_urls: [origin + "/oauth/callback"], public: false, request_oauth_on_install: false,
        hook_attributes: { url: origin + "/events", active: false }, default_permissions: permissions, default_events: [] };
      return page("Set up Keel’s GitHub connection", `<p>This one-time step creates a GitHub App owned by <strong>${escape(env.OWNER)}</strong>. No token copying.</p><p>First <a href="https://github.com/login" target="_blank" rel="noopener noreferrer">sign in to GitHub</a> in this browser, then return to this page and use the button below. If GitHub says “We didn’t find an App Manifest,” return here and use the button again after signing in.</p><p>You choose which repositories it can access on GitHub. The app requests repository contents, pull requests and Actions access for reviewed coding tasks.</p><form action="https://github.com/settings/apps/new?state=${state}" method="post"><input type="hidden" name="manifest" value="${escape(JSON.stringify(manifest))}"><button>Create GitHub connection</button></form><p><small>Keel will still ask before applying or publishing a change.</small></p>`,
        { "Set-Cookie": `__Host-keel_setup=${state}; Path=/; Secure; HttpOnly; SameSite=Lax; Max-Age=3600` });
    }
    if (request.method === "GET" && url.pathname === "/setup/callback") {
      const state = url.searchParams.get("state") ?? ""; const code = url.searchParams.get("code") ?? "";
      const cookie = request.headers.get("Cookie")?.split(";").map(s => s.trim()).find(s => s.startsWith("__Host-keel_setup="))?.split("=")[1];
      if (!safe.test(state) || cookie !== state || !/^[a-zA-Z0-9]{20,200}$/.test(code) || await loadApp(env) || !await env.STATE.get("setup:" + state)) return setupFailure("expired");
      await env.STATE.delete("setup:" + state);
      stage = "github_manifest_request";
      const response = await network("https://api.github.com/app-manifests/" + code + "/conversions", {
        method: "POST", redirect: "manual", signal: AbortSignal.timeout(15_000), headers: { Accept: "application/vnd.github+json", "User-Agent": "KeelMobile", "X-GitHub-Api-Version": "2026-03-10" },
      });
      if (!response.ok) return setupFailure("conversion");
      stage = "github_manifest_response";
      const value: unknown = await boundedJSON(response, 65_536);
      if (!value || typeof value !== "object" || !("owner" in value) || !("client_id" in value) || !("client_secret" in value) || !("html_url" in value)) return setupFailure("conversion");
      const result = value as App;
      if (result.owner?.login !== env.OWNER || !result.client_id || !result.client_secret || !result.html_url?.startsWith("https://github.com/apps/")) return setupFailure("owner");
      // Persist only the OAuth configuration. Discard the generated PEM/webhook key.
      stage = "save_app_configuration";
      await saveApp({ client_id: result.client_id, client_secret: result.client_secret, html_url: result.html_url, owner: result.owner }, env);
      return page("Keel’s GitHub connection is ready", `<p>Choose the repositories Keel may access, then return to the app and tap Connect GitHub.</p><a href="${escape(result.html_url)}/installations/new">Choose repositories on GitHub</a>`,
        { "Set-Cookie": "__Host-keel_setup=; Path=/; Secure; HttpOnly; SameSite=Lax; Max-Age=0" });
    }
    const app = await loadApp(env); if (!app) return json({ error: "connector_not_configured" }, 503);
    if (request.method === "GET" && url.pathname === "/start") {
      const state = url.searchParams.get("state") ?? ""; const challenge = url.searchParams.get("challenge") ?? "";
      if (!safe.test(state) || !safe.test(challenge) || await env.STATE.get("oauth:" + state)) return json({ error: "invalid_session" }, 400);
      await env.STATE.put("oauth:" + state, JSON.stringify({ challenge, created: Date.now() }), { expirationTtl: 600 });
      const target = new URL("https://github.com/login/oauth/authorize");
      target.search = new URLSearchParams({ client_id: app.client_id, redirect_uri: origin + "/oauth/callback", state, code_challenge: challenge, code_challenge_method: "S256" }).toString();
      return redirect(target.href);
    }
    if (request.method === "GET" && url.pathname === "/oauth/callback") {
      const state = url.searchParams.get("state") ?? "";
      if (!safe.test(state) || !await env.STATE.get("oauth:" + state)) return json({ error: "invalid_session" }, 400);
      const target = new URL(callback); target.searchParams.set("state", state);
      const code = url.searchParams.get("code");
      if (code && /^[a-zA-Z0-9]{10,200}$/.test(code)) target.searchParams.set("code", code);
      else target.searchParams.set("error", "access_denied");
      return redirect(target.href);
    }
    if (request.method === "POST" && url.pathname === "/exchange") {
      const body = await boundedJSON(request);
      if (!safe.test(body.state ?? "") || !/^[A-Za-z0-9_-]{43,128}$/.test(body.verifier ?? "") || !/^[a-zA-Z0-9]{10,200}$/.test(body.code ?? "")) return json({ error: "invalid_session" }, 400);
      const saved = await env.STATE.get("oauth:" + body.state); if (!saved) return json({ error: "expired_session" }, 401);
      const session: Session = JSON.parse(saved);
      const challenge = b64(new Uint8Array(await crypto.subtle.digest("SHA-256", encoder.encode(body.verifier))));
      if (challenge !== session.challenge || Date.now() - session.created > 600_000) return json({ error: "invalid_session" }, 401);
      if (!await env.STATE.consume("oauth:" + body.state, saved)) return json({ error: "expired_session" }, 401);
      return githubToken(app, { code: body.code, code_verifier: body.verifier, redirect_uri: origin + "/oauth/callback" }, network);
    }
    if (request.method === "POST" && url.pathname === "/refresh") {
      const body = await boundedJSON(request);
      if (!/^ghr_[A-Za-z0-9_]{10,500}$/.test(body.refresh_token ?? "")) return json({ error: "invalid_refresh" }, 400);
      return githubToken(app, { grant_type: "refresh_token", refresh_token: body.refresh_token }, network);
    }
    return json({ error: "not_found" }, 404);
  } catch (error) {
    // Deliberately omit URL, exception message/stack and upstream body: any of
    // those can contain authorization material. Only fixed stages are logged.
    console.error(JSON.stringify({ event: "connector_request_failed", stage, kind: error instanceof Error ? error.name : "unknown" }));
    if (new URL(request.url).pathname === "/setup/callback") return setupFailure("unavailable", stage + ":" + (error instanceof Error ? error.name : "unknown"));
    return json({ error: "request_failed" }, 400);
  }
}

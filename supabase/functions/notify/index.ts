// @ts-nocheck
// =====================================================================
// RUSH · funzione "notify" (Supabase Edge Function)
// Invia le notifiche push ai telefoni dei dipendenti.
// I messaggi li prepara il database (funzioni push_*_msgs); qui si controlla chi chiama,
// si cifrano i messaggi (Web Push, RFC 8291) e si inviano.
//
// Segreti da impostare in Supabase → Edge Functions → Secrets:
//   VAPID_PUBLIC_KEY, VAPID_PRIVATE_KEY, VAPID_SUBJECT (es. mailto:tuo@email), CRON_SECRET
// "Verify JWT" va DISATTIVATO per questa funzione (la verifica la fa il codice qui sotto).
// =====================================================================

const env = (k) => (globalThis.Deno ? Deno.env.get(k) : process.env[k]) || "";
const CORS = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type, x-cron-secret",
  "Access-Control-Allow-Methods": "POST, OPTIONS",
};
const json = (body, status = 200) =>
  new Response(JSON.stringify(body), { status, headers: { ...CORS, "Content-Type": "application/json" } });

const UUID = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;
const enc = new TextEncoder();

// ---------- base64url ----------
function b64u(buf) {
  const b = new Uint8Array(buf);
  let s = "";
  for (let i = 0; i < b.length; i++) s += String.fromCharCode(b[i]);
  return btoa(s).replace(/\+/g, "-").replace(/\//g, "_").replace(/=+$/, "");
}
function unb64u(s) {
  s = String(s).replace(/-/g, "+").replace(/_/g, "/");
  while (s.length % 4) s += "=";
  const bin = atob(s);
  const out = new Uint8Array(bin.length);
  for (let i = 0; i < bin.length; i++) out[i] = bin.charCodeAt(i);
  return out;
}
function concat(...parts) {
  const len = parts.reduce((a, p) => a + p.length, 0);
  const out = new Uint8Array(len);
  let o = 0;
  for (const p of parts) { out.set(p, o); o += p.length; }
  return out;
}

// ---------- crypto ----------
const subtle = crypto.subtle;
async function hmac(key, data) {
  const k = await subtle.importKey("raw", key, { name: "HMAC", hash: "SHA-256" }, false, ["sign"]);
  return new Uint8Array(await subtle.sign("HMAC", k, data));
}

let vapidKey = null;
async function vapidSigningKey() {
  if (vapidKey) return vapidKey;
  const pub = unb64u(env("VAPID_PUBLIC_KEY"));
  const d = env("VAPID_PRIVATE_KEY");
  if (pub.length !== 65 || !d) throw new Error("chiavi VAPID mancanti");
  vapidKey = await subtle.importKey("jwk",
    { kty: "EC", crv: "P-256", x: b64u(pub.slice(1, 33)), y: b64u(pub.slice(33, 65)), d, ext: true },
    { name: "ECDSA", namedCurve: "P-256" }, false, ["sign"]);
  return vapidKey;
}
const jwtCache = new Map();
async function vapidHeader(endpoint) {
  const aud = new URL(endpoint).origin;
  const now = Math.floor(Date.now() / 1000);
  const c = jwtCache.get(aud);
  if (c && c.exp - now > 3600) return c.h;
  const exp = now + 12 * 3600;
  const head = b64u(enc.encode(JSON.stringify({ typ: "JWT", alg: "ES256" })));
  const body = b64u(enc.encode(JSON.stringify({ aud, exp, sub: env("VAPID_SUBJECT") || "mailto:admin@rush.app" })));
  const sig = await subtle.sign({ name: "ECDSA", hash: "SHA-256" }, await vapidSigningKey(), enc.encode(head + "." + body));
  const h = "vapid t=" + head + "." + body + "." + b64u(sig) + ", k=" + env("VAPID_PUBLIC_KEY");
  jwtCache.set(aud, { exp, h });
  return h;
}

// Cifratura aes128gcm (RFC 8188 + RFC 8291)
async function encryptPayload(p256dh, authSecret, payload) {
  const uaPublic = unb64u(p256dh);
  const auth = unb64u(authSecret);
  const local = await subtle.generateKey({ name: "ECDH", namedCurve: "P-256" }, true, ["deriveBits"]);
  const asPublic = new Uint8Array(await subtle.exportKey("raw", local.publicKey));
  const uaKey = await subtle.importKey("raw", uaPublic, { name: "ECDH", namedCurve: "P-256" }, false, []);
  const ecdh = new Uint8Array(await subtle.deriveBits({ name: "ECDH", public: uaKey }, local.privateKey, 256));
  const prkKey = await hmac(auth, ecdh);
  const ikm = await hmac(prkKey, concat(enc.encode("WebPush: info\0"), uaPublic, asPublic, new Uint8Array([1])));
  const salt = crypto.getRandomValues(new Uint8Array(16));
  const prk = await hmac(salt, ikm);
  const cek = (await hmac(prk, concat(enc.encode("Content-Encoding: aes128gcm\0"), new Uint8Array([1])))).slice(0, 16);
  const nonce = (await hmac(prk, concat(enc.encode("Content-Encoding: nonce\0"), new Uint8Array([1])))).slice(0, 12);
  const key = await subtle.importKey("raw", cek, { name: "AES-GCM" }, false, ["encrypt"]);
  const plain = concat(enc.encode(payload), new Uint8Array([2]));
  const cipher = new Uint8Array(await subtle.encrypt({ name: "AES-GCM", iv: nonce }, key, plain));
  const header = new Uint8Array(21);
  header.set(salt, 0);
  new DataView(header.buffer).setUint32(16, 4096);
  header[20] = 65;
  return concat(header, asPublic, cipher);
}

async function sendOne(m) {
  const payload = JSON.stringify({ title: m.title, body: m.body, url: m.url, tag: m.tag });
  const body = await encryptPayload(m.p256dh, m.auth, payload);
  const res = await fetch(m.endpoint, {
    method: "POST",
    headers: {
      "Authorization": await vapidHeader(m.endpoint),
      "Content-Encoding": "aes128gcm",
      "Content-Type": "application/octet-stream",
      "TTL": "86400",
      "Urgency": "normal",
    },
    body,
  });
  return res.status;
}

// ---------- database ----------
const SB_URL = () => env("SUPABASE_URL");
function serviceHeaders() {
  const k = env("RUSH_SERVICE_KEY") || env("SUPABASE_SERVICE_ROLE_KEY");
  const h = { apikey: k, "Content-Type": "application/json" };
  if (k.startsWith("eyJ")) h.Authorization = "Bearer " + k;
  return h;
}
async function rpc(fn, args) {
  const res = await fetch(SB_URL() + "/rest/v1/rpc/" + fn, { method: "POST", headers: serviceHeaders(), body: JSON.stringify(args) });
  const text = await res.text();
  if (!res.ok) {
    const e = new Error("rpc " + fn + ": " + text);
    e.status = /non autorizzato/.test(text) ? 403 : 500;
    throw e;
  }
  return text ? JSON.parse(text) : null;
}
// Admin collegato: verifica il token di accesso con Supabase Auth
async function adminUser(req) {
  const auth = req.headers.get("authorization") || "";
  const jwt = auth.replace(/^Bearer\s+/i, "");
  if (!jwt.startsWith("eyJ")) return null;
  const res = await fetch(SB_URL() + "/auth/v1/user", {
    headers: { Authorization: "Bearer " + jwt, apikey: env("SUPABASE_ANON_KEY") || req.headers.get("apikey") || "" },
  });
  if (!res.ok) return null;
  const u = await res.json();
  return u && UUID.test(u.id || "") ? u.id : null;
}

async function deliver(msgs) {
  msgs = Array.isArray(msgs) ? msgs : [];
  const gone = [];
  let sent = 0, failed = 0;
  const results = await Promise.allSettled(msgs.map((m) => sendOne(m)));
  results.forEach((r, i) => {
    if (r.status === "fulfilled" && r.value >= 200 && r.value < 300) sent++;
    else {
      failed++;
      if (r.status === "fulfilled" && (r.value === 404 || r.value === 410)) gone.push(msgs[i].sub);
      else console.error("push non riuscito", r.status === "fulfilled" ? r.value : String(r.reason));
    }
  });
  if (gone.length) await rpc("push_gone", { p_ids: gone }).catch((e) => console.error(String(e)));
  return { sent, failed, devices: msgs.length, people: new Set(msgs.map((m) => m.url)).size };
}

export async function handle(req) {
  if (req.method === "OPTIONS") return new Response("ok", { headers: CORS });
  if (req.method !== "POST") return json({ error: "metodo" }, 405);
  let b;
  try { b = await req.json(); } catch { return json({ error: "richiesta" }, 400); }
  const action = String(b && b.action || "");
  const id = UUID.test(b.id || "") ? b.id : null;
  const token = UUID.test(b.token || "") ? b.token : null;
  try {
    if (action === "cron") {
      const s = env("CRON_SECRET");
      if (!s || req.headers.get("x-cron-secret") !== s) return json({ error: "non autorizzato" }, 403);
      return json(await deliver(await rpc("push_reminder_msgs", {})));
    }
    if (action === "test") {
      if (!token) return json({ error: "richiesta" }, 400);
      return json(await deliver(await rpc("push_test_msgs", { p_token: token })));
    }
    if (action === "swap" && token) {
      if (!id) return json({ error: "richiesta" }, 400);
      return json(await deliver(await rpc("push_swap_msgs", { p_user: null, p_token: token, p_id: id })));
    }
    // da qui in poi: solo admin collegati
    const user = await adminUser(req);
    if (!user) return json({ error: "non autorizzato" }, 401);
    if (action === "planning") {
      const org = UUID.test(b.org || "") ? b.org : null;
      if (!org) return json({ error: "richiesta" }, 400);
      const r = await rpc("push_planning_msgs", { p_user: user, p_org: org });
      return json({ ...(await deliver(r.msgs)), people: r.people });
    }
    if (!id) return json({ error: "richiesta" }, 400);
    if (action === "request") return json(await deliver(await rpc("push_request_msgs", { p_user: user, p_id: id })));
    if (action === "swap") return json(await deliver(await rpc("push_swap_msgs", { p_user: user, p_token: null, p_id: id })));
    return json({ error: "azione sconosciuta" }, 400);
  } catch (e) {
    console.error(String(e && e.message || e));
    return json({ error: e && e.status === 403 ? "non autorizzato" : "errore" }, e && e.status === 403 ? 403 : 500);
  }
}

if (globalThis.Deno) Deno.serve(handle);

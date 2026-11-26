// Rush · service worker: l'app si apre anche con connessione debole e riceve le notifiche push.
// Strategia: prima la rete, se manca usa la copia salvata. I dati (Supabase) non vengono mai salvati qui.
const CACHE = "rush-v8";
const SHELL = ["./", "index.html", "staff.html", "config.js", "push-config.js", "vendor/supabase.js",
  "manifest.webmanifest", "manifest-staff.webmanifest", "badge.html", "manifest-badge.webmanifest", "icons/icon-192.png", "icons/icon-512.png"];
self.addEventListener("install", e => {
  e.waitUntil(caches.open(CACHE).then(c => c.addAll(SHELL)).then(() => self.skipWaiting()));
});
self.addEventListener("activate", e => {
  e.waitUntil(caches.keys().then(keys => Promise.all(keys.filter(k => k !== CACHE).map(k => caches.delete(k))))
    .then(() => self.clients.claim()));
});
self.addEventListener("fetch", e => {
  const req = e.request;
  if (req.method !== "GET" || new URL(req.url).origin !== self.location.origin) return;
  e.respondWith(
    fetch(req).then(res => {
      if (res.ok) { const copy = res.clone(); caches.open(CACHE).then(c => c.put(req, copy)); }
      return res;
    }).catch(() => caches.match(req, { ignoreSearch: true }).then(r => r || caches.match("index.html")))
  );
});

// ---------- notifiche push (inviate dalla funzione "notify" su Supabase) ----------
self.addEventListener("push", e => {
  let d = {};
  try { d = e.data ? e.data.json() : {}; } catch (_) { d = { body: e.data ? e.data.text() : "" }; }
  e.waitUntil(self.registration.showNotification(d.title || "Rush", {
    body: d.body || "",
    tag: d.tag || undefined,
    renotify: !!d.tag,
    lang: "it",
    icon: "icons/icon-192.png",
    badge: "icons/badge-96.png",
    data: { url: d.url || "staff.html" }
  }));
});
self.addEventListener("notificationclick", e => {
  e.notification.close();
  const url = new URL((e.notification.data && e.notification.data.url) || "staff.html", self.registration.scope).href;
  e.waitUntil(self.clients.matchAll({ type: "window", includeUncontrolled: true }).then(list => {
    const page = list.find(c => c.url.split("#")[0] === url.split("#")[0]);
    if (page) {
      // pagina già aperta: la porta in primo piano (si aggiorna da sola quando torna visibile)
      return (page.url !== url && page.navigate ? page.navigate(url) : Promise.resolve(page)).then(c => (c || page).focus());
    }
    return self.clients.openWindow(url);
  }));
});

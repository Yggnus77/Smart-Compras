// Smart Compras: cache simples para abrir rápido e funcionar como app instalado.
// Dados (Supabase) sempre vêm da rede.
const CACHE = "sc-v5";
const ARQS = ["./", "index.html", "manifest.webmanifest", "img/icon-32.png", "img/icon-192.png", "img/icon-512.png", "img/fundo-m.jpg"];
self.addEventListener("install", e => { e.waitUntil(caches.open(CACHE).then(c => c.addAll(ARQS)).then(() => self.skipWaiting())); });
self.addEventListener("activate", e => {
  e.waitUntil(caches.keys().then(ks => Promise.all(ks.filter(k => k !== CACHE).map(k => caches.delete(k)))).then(() => self.clients.claim()));
});
self.addEventListener("fetch", e => {
  const u = new URL(e.request.url);
  if(e.request.method !== "GET" || u.origin !== location.origin) return;
  // páginas: rede primeiro (pega atualizações), cache se estiver offline
  if(e.request.mode === "navigate"){
    e.respondWith(fetch(e.request).then(r => { const c = r.clone(); caches.open(CACHE).then(x => x.put("index.html", c)); return r; })
      .catch(() => caches.match("index.html")));
    return;
  }
  e.respondWith(caches.match(e.request).then(r => r || fetch(e.request)));
});

// ===== alertas (Web Push) =====
self.addEventListener("push", e => {
  let d = {};
  try{ d = e.data ? e.data.json() : {}; }catch(_){ d = {body: e.data && e.data.text()}; }
  e.waitUntil(self.registration.showNotification(d.title || "Smart Compras", {
    body: d.body || "Você tem um novo alerta.",
    icon: "img/icon-192.png",
    badge: "img/icon-192.png",
    tag: "sc-" + (d.lista_id || "alerta"),
    renotify: true,
    data: {lista_id: d.lista_id}
  }));
});
self.addEventListener("notificationclick", e => {
  e.notification.close();
  const alvo = self.registration.scope + (e.notification.data && e.notification.data.lista_id ? "#lista/" + e.notification.data.lista_id : "");
  e.waitUntil(self.clients.matchAll({type: "window", includeUncontrolled: true}).then(cs => {
    for(const c of cs){ if(c.url.startsWith(self.registration.scope) && "focus" in c){ c.navigate(alvo); return c.focus(); } }
    return self.clients.openWindow(alvo);
  }));
});

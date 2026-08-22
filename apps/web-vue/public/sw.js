const CACHE = "fingerspeak-vue-edge-v1";
const EDGE_ASSETS = [
  "/",
  "/favicon.svg",
  "/og.png",
  "/manifest.webmanifest",
  "/models/hand_landmarker.task",
  "/mediapipe/wasm/vision_wasm_internal.js",
  "/mediapipe/wasm/vision_wasm_internal.wasm",
  "/mediapipe/wasm/vision_wasm_nosimd_internal.js",
  "/mediapipe/wasm/vision_wasm_nosimd_internal.wasm"
];

function isBuildAsset(pathname) {
  return pathname.startsWith("/assets/");
}

async function precacheApplicationShell() {
  const cache = await caches.open(CACHE);
  const shellResponse = await fetch("/", { cache: "reload" });
  if (!shellResponse.ok) throw new Error("Could not fetch the FingerSpeak application shell.");
  const html = await shellResponse.clone().text();
  await cache.put("/", shellResponse);
  const buildAssets = new Set();
  for (const match of html.matchAll(/(?:src|href)=["']([^"'#]+)["']/g)) {
    const url = new URL(match[1], self.location.origin);
    if (url.origin === self.location.origin && isBuildAsset(url.pathname)) buildAssets.add(url.pathname);
  }
  await cache.addAll([...EDGE_ASSETS.filter((path) => path !== "/"), ...buildAssets]);
}

self.addEventListener("install", (event) => {
  event.waitUntil(precacheApplicationShell().then(() => self.skipWaiting()));
});

self.addEventListener("activate", (event) => {
  event.waitUntil(caches.keys().then((keys) => Promise.all(keys.filter((key) => key !== CACHE).map((key) => caches.delete(key)))));
  self.clients.claim();
});

self.addEventListener("fetch", (event) => {
  if (event.request.method !== "GET") return;
  const request = event.request;
  const url = new URL(request.url);
  if (url.origin !== self.location.origin) return;

  if (request.mode === "navigate") {
    event.respondWith(fetch(request).catch(() => caches.match("/")));
    return;
  }

  if (EDGE_ASSETS.includes(url.pathname) || isBuildAsset(url.pathname)) {
    event.respondWith(caches.match(request).then((cached) => cached || fetch(request).then(async (response) => {
      if (response.ok && response.type === "basic") {
        await caches.open(CACHE).then((cache) => cache.put(request, response.clone()));
      }
      return response;
    })));
  }

  // API/auth/profile responses are intentionally never cached here.
});

/** Cloudflare Worker entry point for the vinext-starter template. */
import { handleImageOptimization, DEFAULT_DEVICE_SIZES, DEFAULT_IMAGE_SIZES } from "vinext/server/image-optimization";
import handler from "vinext/server/app-router-entry";

interface Env {
  ASSETS: { fetch(request: Request): Promise<Response> };
  IMAGES: {
    input(stream: ReadableStream): {
      transform(options: Record<string, unknown>): {
        output(options: { format: string; quality: number }): Promise<{ response(): Response }>;
      };
    };
  };
}

interface ExecutionContext {
  waitUntil(promise: Promise<unknown>): void;
  passThroughOnException(): void;
}

function secure(response: Response): Response {
  const headers = new Headers(response.headers);
  const configuredApi = process.env.NEXT_PUBLIC_API_URL ?? "http://localhost:8000/v1";
  let apiOrigin = "http://localhost:8000";
  try { apiOrigin = new URL(configuredApi).origin; } catch { /* Build-time validation handles the configured URL. */ }
  const socketOrigin = apiOrigin.replace(/^http/, "ws");
  const connectSources = ["'self'", apiOrigin, socketOrigin];
  // The controlled local prototype discovers hotspot/USB-tethered Pi addresses at
  // runtime, so their exact origin cannot be known when the development worker is
  // built. Production remains origin-bound and uses WSS or the outbound cloud relay.
  if (process.env.NODE_ENV !== "production") connectSources.push("ws:");
  const configuredPi = process.env.NEXT_PUBLIC_PI_WS_URL;
  if (configuredPi) {
    try { connectSources.push(new URL(configuredPi).origin); } catch { /* Invalid optional Pi URLs are ignored here and rejected by the client. */ }
  }
  headers.set("Content-Security-Policy", [
    "default-src 'self'",
    "base-uri 'self'",
    "frame-ancestors 'none'",
    "object-src 'none'",
    "form-action 'self'",
    "script-src 'self' 'unsafe-inline' 'wasm-unsafe-eval'",
    "style-src 'self' 'unsafe-inline'",
    "img-src 'self' data: blob:",
    "font-src 'self'",
    "media-src 'self' blob:",
    "worker-src 'self' blob:",
    `connect-src ${connectSources.join(" ")}`,
  ].join("; "));
  headers.set("Permissions-Policy", "camera=(self), microphone=(self), geolocation=()");
  headers.set("Referrer-Policy", "no-referrer");
  headers.set("X-Content-Type-Options", "nosniff");
  headers.set("X-Frame-Options", "DENY");
  headers.set("Cross-Origin-Opener-Policy", "same-origin");
  return new Response(response.body, { status: response.status, statusText: response.statusText, headers });
}

// Image security config. SVG sources with .svg extension auto-skip the
// optimization endpoint on the client side (served directly, no proxy).
// To route SVGs through the optimizer (with security headers), set
// dangerouslyAllowSVG: true in next.config.js and uncomment below:
// const imageConfig: ImageConfig = { dangerouslyAllowSVG: true };

const worker = {
  async fetch(request: Request, env: Env, ctx: ExecutionContext): Promise<Response> {
    const url = new URL(request.url);

    if (url.pathname === "/_vinext/image") {
      const allowedWidths = [...DEFAULT_DEVICE_SIZES, ...DEFAULT_IMAGE_SIZES];
      return secure(await handleImageOptimization(request, {
        fetchAsset: (path) => env.ASSETS.fetch(new Request(new URL(path, request.url))),
        transformImage: async (body, { width, format, quality }) => {
          const result = await env.IMAGES.input(body).transform(width > 0 ? { width } : {}).output({ format, quality });
          return result.response();
        },
      }, allowedWidths));
    }

    return secure(await handler.fetch(request, env, ctx));
  },
};

export default worker;

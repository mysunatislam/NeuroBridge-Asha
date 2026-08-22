import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import test from "node:test";

test("phone shell keeps Asha first and respects device safe areas", () => {
  const css = readFileSync(new URL("../app/globals.css", import.meta.url), "utf8");
  assert.match(css, /grid-template-areas:\s*"intro"\s*"asha"\s*"camera"\s*"tools"/);
  assert.match(css, /env\(safe-area-inset-bottom\)/);
  assert.match(css, /\.mode-switch\s*\{[^}]*position:\s*fixed/);
  assert.match(css, /\.asha-composer textarea[\s\S]*?font-size:\s*16px/);
});

test("installable mobile shell includes the offline Asha portrait", () => {
  const manifest = JSON.parse(readFileSync(new URL("../public/manifest.webmanifest", import.meta.url), "utf8")) as {
    display?: string;
    icons?: Array<{ src?: string; purpose?: string }>;
  };
  const worker = readFileSync(new URL("../public/sw.js", import.meta.url), "utf8");
  assert.equal(manifest.display, "standalone");
  assert.ok(manifest.icons?.some((icon) => icon.src === "/asha-avatar-face.webp" && icon.purpose?.includes("maskable")));
  assert.match(worker, /"\/asha-avatar-face\.webp"/);
});

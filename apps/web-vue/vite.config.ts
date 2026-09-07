import { defineConfig } from "vite";
import vue from "@vitejs/plugin-vue";

export default defineConfig({
  base: process.env.GITHUB_ACTIONS ? "/NeuroBridge-Asha/" : "/",
  plugins: [vue()],
  server: { port: 3000 },
  build: { target: "es2022" },
});

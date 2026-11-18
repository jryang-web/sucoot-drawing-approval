import { defineConfig, type Plugin } from "vite";
import react from "@vitejs/plugin-react";
import { execSync } from "node:child_process";
import { readFileSync } from "node:fs";
import pkg from "./package.json";

// 版本資訊：package.json 版本 + 建置來源 commit + 建置時間（台北時間）
function gitSha(): string {
  if (process.env.GITHUB_SHA) return process.env.GITHUB_SHA.slice(0, 7);
  try { return execSync("git rev-parse --short HEAD").toString().trim(); } catch { return "local"; }
}
const sha = gitSha();
const buildTime = new Date().toLocaleString("sv-SE", { timeZone: "Asia/Taipei" }).slice(0, 16);

// 建置時產生 sw.js：快取名稱含版本與 commit，並預先快取本次建置的所有檔案
function serviceWorker(): Plugin {
  return {
    name: "sucoot-service-worker",
    apply: "build",
    generateBundle(_opts, bundle) {
      const files = ["./", "./index.html", "./manifest.webmanifest",
        ...Object.keys(bundle).filter((f) => f !== "index.html").map((f) => `./${f}`),
        "./icons/icon-192.png", "./icons/icon-512.png", "./icons/apple-touch-icon.png"];
      const source = readFileSync("sw-template.js", "utf8")
        .replace("__VERSION__", `${pkg.version}-${sha}-${Date.now()}`)
        .replace("__PRECACHE__", JSON.stringify(files, null, 2));
      this.emitFile({ type: "asset", fileName: "sw.js", source });
    },
  };
}

// base "./"：搭配 HashRouter，可直接部署到 GitHub Pages 子路徑
export default defineConfig({
  server: { host: "127.0.0.1", proxy: Object.fromEntries(
    ["/auth/v1", "/rest/v1", "/functions/v1"].map(path => [path, "http://127.0.0.1:54329"])
  ) },
  base: "./",
  plugins: [react(), serviceWorker()],
  define: {
    __APP_VERSION__: JSON.stringify(pkg.version),
    __BUILD_SHA__: JSON.stringify(sha),
    __BUILD_TIME__: JSON.stringify(buildTime),
  },
});

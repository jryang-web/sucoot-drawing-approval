import { defineConfig, loadEnv, type Plugin } from "vite";
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

function pagesConnection(mode: string) {
  if (mode !== "pages") return null;
  const env = loadEnv(mode, process.cwd(), "VITE_SUPABASE_");
  const url = env.VITE_SUPABASE_URL;
  const key = env.VITE_SUPABASE_PUBLISHABLE_KEY ?? "";
  if (url !== "https://qifjiaxskortyennnpsh.supabase.co")
    throw new Error("Pages 建置需要指定的正式 Supabase URL");
  if (!/^sb_publishable_[A-Za-z0-9_-]+$/.test(key)) {
    const parts = key.split(".");
    let valid = false;
    if (parts.length === 3 && parts.every(part => /^[A-Za-z0-9_-]+$/.test(part))) {
      try {
        const claims = JSON.parse(Buffer.from(parts[1], "base64url").toString());
        valid = claims.role === "anon" && claims.ref === "qifjiaxskortyennnpsh";
      } catch { /* Reject malformed keys before emitting assets. */ }
    }
    if (!valid) throw new Error("Pages 建置需要公開 publishable key 或該專案的 anon JWT");
  }
  return { url, key };
}

// base "./"：搭配 HashRouter，可直接部署到 GitHub Pages 子路徑
export default defineConfig(({ mode }) => ({
  server: { host: "127.0.0.1", proxy: Object.fromEntries(
    ["/auth/v1", "/rest/v1", "/functions/v1"].map(path => [path, "http://127.0.0.1:54329"])
  ) },
  base: "./",
  plugins: [react(), serviceWorker()],
  define: {
    __PAGES_CONNECTION__: JSON.stringify(pagesConnection(mode)),
    __APP_VERSION__: JSON.stringify(pkg.version),
    __BUILD_SHA__: JSON.stringify(sha),
    __BUILD_TIME__: JSON.stringify(buildTime),
  },
}));

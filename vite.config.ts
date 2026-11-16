import { defineConfig } from "vite";
import react from "@vitejs/plugin-react";
import { execSync } from "node:child_process";
import pkg from "./package.json";

// 版本資訊：package.json 版本 + 建置來源 commit + 建置時間（台北時間）
function gitSha(): string {
  if (process.env.GITHUB_SHA) return process.env.GITHUB_SHA.slice(0, 7);
  try { return execSync("git rev-parse --short HEAD").toString().trim(); } catch { return "local"; }
}
const buildTime = new Date().toLocaleString("sv-SE", { timeZone: "Asia/Taipei" }).slice(0, 16);

// base "./"：搭配 HashRouter，可直接部署到 GitHub Pages 子路徑
export default defineConfig({
  base: "./",
  plugins: [react()],
  define: {
    __APP_VERSION__: JSON.stringify(pkg.version),
    __BUILD_SHA__: JSON.stringify(gitSha()),
    __BUILD_TIME__: JSON.stringify(buildTime),
  },
});

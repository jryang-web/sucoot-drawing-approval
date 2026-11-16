import { defineConfig } from "vite";
import react from "@vitejs/plugin-react";

// base "./"：搭配 HashRouter，可直接部署到 GitHub Pages 子路徑
export default defineConfig({
  base: "./",
  plugins: [react()],
});

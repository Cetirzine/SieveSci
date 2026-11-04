import { defineConfig } from "vite";
import react from "@vitejs/plugin-react";

// Tauri serves the built files; in development the window loads the dev server.
export default defineConfig({
  plugins: [react()],
  clearScreen: false,
  server: { host: "127.0.0.1", port: 1420, strictPort: true },
  build: { target: "es2022", outDir: "dist", sourcemap: false },
});

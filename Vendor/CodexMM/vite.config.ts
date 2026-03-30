import react from "@vitejs/plugin-react";
import { defineConfig } from "vite";

export default defineConfig({
  plugins: [react()],
  server: {
    host: "0.0.0.0",
    port: 4173,
    proxy: {
      "/api": "http://127.0.0.1:4318",
    },
  },
  build: {
    outDir: "dist/client",
    emptyOutDir: true,
  },
});

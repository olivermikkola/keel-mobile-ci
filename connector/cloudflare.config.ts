import { bindings, defineConfig, exports } from "cf/config";
import * as entrypoint from "./src/index.ts" with { type: "cf-worker" };
export default defineConfig({
  worker: {
    name: "keel-mobile-github",
    compatibilityDate: "2026-11-11",
    entrypoint,
    observability: { enabled: true, redactQueryString: true, logs: { enabled: true }, traces: { enabled: true, headSamplingRate: 0.1 } },
    exports: { ConnectionStore: exports.durableObject({ storage: "sqlite" }) },
    env: {
      SESSIONS: bindings.durableObject({ worker: "keel-mobile-github", exportName: "ConnectionStore" }),
      STORAGE_KEY: bindings.secret(),
      OWNER: bindings.text("olivermikkola"),
    },
  },
});

import { env, DurableObject } from "cloudflare:workers";
import { handle, type Store } from "./auth.ts";
type Stored = { value: string; expires: number | null };
export class ConnectionStore extends DurableObject<Cloudflare.Env> implements Store {
  async get(key: string): Promise<string | null> {
    const item = await this.ctx.storage.get<Stored>(key);
    if (!item) return null;
    if (item.expires !== null && item.expires < Date.now()) { await this.ctx.storage.delete(key); return null; }
    return item.value;
  }
  async put(key: string, value: string, options?: { expirationTtl: number }): Promise<void> {
    await this.ctx.storage.put(key, { value, expires: options ? Date.now() + options.expirationTtl * 1000 : null });
  }
  async delete(key: string): Promise<void> { await this.ctx.storage.delete(key); }
  async consume(key: string, expected: string): Promise<boolean> {
    return this.ctx.storage.transaction(async txn => {
      const item = await txn.get<Stored>(key);
      if (!item || item.value !== expected || (item.expires !== null && item.expires < Date.now())) return false;
      await txn.delete(key); return true;
    });
  }
  fetch(request: Request): Promise<Response> {
    return handle(request, { STATE: this, STORAGE_KEY: this.env.STORAGE_KEY, OWNER: this.env.OWNER });
  }
}
export default {
  fetch(request: Request) { return env.SESSIONS.getByName("github-connection").fetch(request); },
} satisfies ExportedHandler;

// Keel's shell: just-bash over the task workspace.
//
// Runs inside ScriptRunner's web view after ScriptPrelude, so the only way out
// is keel.* (the task's files). Files load lazily on first read; every path a
// command writes is recorded, and at the end each net change goes back through
// keel.writeFile / keel.deleteFile, where it becomes a reviewed proposal.
// Nothing outside /workspace is kept: /tmp and the rest are scratch.
import { Bash, InMemoryFs } from "just-bash/browser";

const ROOT = "/workspace";
const rel = (p) => (p === ROOT ? "" : p.startsWith(ROOT + "/") ? p.slice(ROOT.length + 1) : null);

class KeelFs extends InMemoryFs {
  constructor(files, dirty) { super(files); this.dirty = dirty; }
  mark(p) { this.dirty.add(p); }
  async writeFile(p, ...a) { this.mark(p); return super.writeFile(p, ...a); }
  async appendFile(p, ...a) { this.mark(p); return super.appendFile(p, ...a); }
  async createExclusive(p, ...a) { this.mark(p); return super.createExclusive(p, ...a); }
  async rm(p, ...a) { this.mark(p); return super.rm(p, ...a); }
  async cp(s, d, ...a) { this.mark(d); return super.cp(s, d, ...a); }
  async mv(s, d) { this.mark(s); this.mark(d); return super.mv(s, d); }
  async symlink(t, p) { this.mark(p); return super.symlink(t, p); }
  async link(e, p) { this.mark(p); return super.link(e, p); }
}

async function filesUnder(fs, path, out) {
  let stat;
  try { stat = await fs.stat(path); } catch { return; }
  if (stat.isDirectory) {
    for (const name of await fs.readdir(path)) await filesUnder(fs, path + "/" + name, out);
  } else out.add(path);
}

globalThis.__keelShell = async function (command) {
  const listed = await keel.listFiles("");
  const original = new Map(); // relative path -> text, once read
  const files = {};
  for (const path of listed) {
    files[ROOT + "/" + path] = async () => {
      const text = await keel.readFile(path);
      original.set(path, text);
      return text;
    };
  }
  const dirty = new Set();
  const fs = new KeelFs(files, dirty);
  const bash = new Bash({
    fs, cwd: ROOT, executionLimitProfile: "hardened",
    env: { HOME: ROOT, PWD: ROOT, USER: "keel" },
  });
  const result = await bash.exec(command);

  // Net changes inside /workspace only.
  const present = new Set();
  const gone = new Set();
  for (const p of dirty) {
    const r = rel(p);
    if (r === null) continue;
    await filesUnder(fs, p, present);
    for (const path of listed) {
      if ((r === "" || path === r || path.startsWith(r + "/")) && !(await fs.exists(ROOT + "/" + path))) gone.add(path);
    }
  }
  const written = [];
  const problems = [];
  for (const p of [...present].sort()) {
    const r = rel(p);
    if (r === null) continue;
    const text = await fs.readFile(p); // a lazy original loads here, so unchanged files compare equal
    if (original.has(r) && original.get(r) === text) continue;
    try { await keel.writeFile(r, text); written.push(r); } catch (e) { problems.push(r + ": " + e.message); }
  }
  for (const r of [...gone].sort()) {
    try { await keel.deleteFile(r); written.push(r); } catch (e) { problems.push(r + ": " + e.message); }
  }
  return JSON.stringify({ stdout: result.stdout, stderr: result.stderr, exitCode: result.exitCode, problems });
};

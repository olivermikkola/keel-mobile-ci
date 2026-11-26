// Runs Resources/KeelShell.js against a fake keel.* workspace and checks what
// it reads, prints and sends back as changes. `npm test` after `npm run build`.
import { readFileSync } from "node:fs";
import assert from "node:assert/strict";

const source = readFileSync(new URL("../../Resources/KeelShell.js", import.meta.url), "utf8");
(0, eval)(source); // a classic script, as the web view loads it

async function run(files, command, refuse = () => null) {
  const store = new Map(Object.entries(files));
  const reads = [], writes = {}, deletes = [];
  const keel = {
    listFiles: async () => [...store.keys()].sort(),
    readFile: async (p) => { if (!store.has(p)) throw new Error(`No file at "${p}" in this task.`); reads.push(p); return store.get(p); },
    writeFile: async (p, t) => { const why = refuse(p); if (why) throw new Error(why); writes[p] = t; },
    deleteFile: async (p) => { deletes.push(p); },
  };
  globalThis.keel = keel;
  const out = JSON.parse(await globalThis.__keelShell(command));
  return { ...out, reads, writes, deletes };
}

const files = {
  "README.md": "# Demo\n",
  "src/app.js": "function add(a, b) {\n  return a + b; // TODO tests\n}\n",
  "src/util.js": "// TODO: remove\nexport const x = 1;\n",
  "data.json": '{"users":[{"age":3},{"age":5}]}',
};
const cases = [];
const check = (name, fn) => cases.push([name, fn]);

check("ls reads no file contents", async () => {
  const r = await run(files, "ls src");
  assert.equal(r.stdout, "app.js\nutil.js\n"); assert.deepEqual(r.reads, []); assert.deepEqual(r.writes, {});
});
check("grep -rn, pipes, sort", async () => {
  const r = await run(files, "grep -rn TODO . | sort");
  // just-bash drops the leading "./" that GNU grep prints; harmless for a model.
  assert.equal(r.stdout, "src/app.js:2:  return a + b; // TODO tests\nsrc/util.js:1:// TODO: remove\n");
});
check("jq", async () => assert.equal((await run(files, "jq '.users | map(.age) | add' data.json")).stdout, "8\n"));
check("sed -i is one changed file", async () => {
  const r = await run(files, "sed -i 's/a + b/Number(a) + Number(b)/' src/app.js");
  assert.deepEqual(Object.keys(r.writes), ["src/app.js"]); assert.match(r.writes["src/app.js"], /Number\(a\)/);
});
check("unchanged rewrite is not a change", async () => {
  const r = await run(files, "sed -i 's/nothing-matches/x/' src/app.js && cp README.md README.md.bak && rm README.md.bak");
  assert.deepEqual(r.writes, {}); assert.deepEqual(r.deletes, []);
});
check("new file in a new folder, and a redirect", async () => {
  const r = await run(files, "mkdir -p docs && echo '# Notes' > docs/notes.md && echo hi >> README.md");
  assert.deepEqual(Object.keys(r.writes).sort(), ["README.md", "docs/notes.md"]);
  assert.equal(r.writes["README.md"], "# Demo\nhi\n");
});
check("mv is a write and a delete", async () => {
  const r = await run(files, "mv src/util.js src/helpers.js");
  assert.deepEqual(Object.keys(r.writes), ["src/helpers.js"]); assert.deepEqual(r.deletes, ["src/util.js"]);
});
check("rm -r deletes every file under it", async () => {
  const r = await run(files, "rm -r src");
  assert.deepEqual(r.deletes.sort(), ["src/app.js", "src/util.js"]);
});
check("/tmp is scratch and is not kept", async () => {
  const r = await run(files, "echo x > /tmp/a && cat /tmp/a");
  assert.equal(r.stdout, "x\n"); assert.deepEqual(r.writes, {});
});
check("errors read like bash", async () => {
  const r = await run(files, "cat missing.txt");
  assert.equal(r.exitCode, 1); assert.match(r.stderr, /cat: missing.txt: No such file or directory/);
});
check("no network commands", async () => {
  const r = await run(files, "curl https://example.com");
  assert.equal(r.exitCode, 127); assert.match(r.stderr, /command not found/);
});
check("a write the host refuses is reported, not lost", async () => {
  const r = await run(files, "echo hi > README.md && echo ok > notes.md",
                      (p) => p === "README.md" ? "This file is over its write budget." : null);
  assert.deepEqual(Object.keys(r.writes), ["notes.md"]);
  assert.deepEqual(r.problems, ["README.md: This file is over its write budget."]);
});

let failed = 0;
for (const [name, fn] of cases) {
  try { await fn(); console.log("ok  ", name); } catch (e) { failed++; console.log("FAIL", name, "\n", e.message); }
}
console.log(`${cases.length - failed}/${cases.length} passed`);
process.exit(failed ? 1 : 0);

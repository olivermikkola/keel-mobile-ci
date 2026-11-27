// Bundles entry.js into ../../Resources/KeelShell.js (one classic script, no imports)
// and writes the licences of every bundled package into KeelShellNotices.txt.
import { build } from "esbuild";
import { readFileSync, writeFileSync, existsSync, readdirSync } from "node:fs";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";

const here = dirname(fileURLToPath(import.meta.url));
const out = join(here, "../../Resources/KeelShell.js");
const result = await build({
  entryPoints: [join(here, "entry.js")], bundle: true, format: "iife", platform: "browser",
  minify: true, legalComments: "none", metafile: true, outfile: out,
  alias: { "node:zlib": join(here, "zlib-stub.js") }, logLevel: "warning",
});

const packages = new Map();
for (const input of Object.keys(result.metafile.inputs)) {
  const match = input.match(/node_modules\/((?:@[^/]+\/)?[^/]+)\//);
  if (match && !packages.has(match[1])) packages.set(match[1], join(here, "node_modules", match[1]));
}
// just-bash's browser build already inlines some of its dependencies (yaml,
// papaparse, re2js and others), which the metafile cannot see. List all of them:
// a notice too many is harmless, a missing one is not.
const jb = JSON.parse(readFileSync(join(here, "node_modules/just-bash/package.json"), "utf8"));
for (const name of Object.keys(jb.dependencies ?? {})) {
  const dir = join(here, "node_modules", name);
  if (existsSync(dir) && !packages.has(name)) packages.set(name, dir);
}
let notices = "Third-party code bundled in KeelShell.js (Keel's shell tool).\n";
for (const [name, dir] of [...packages].sort()) {
  const pkg = JSON.parse(readFileSync(join(dir, "package.json"), "utf8"));
  const licenceFile = readdirSync(dir).find((f) => /^(licen[cs]e|copying)/i.test(f));
  notices += `\n==== ${name} ${pkg.version} (${pkg.license ?? "see text"}) ====\n`;
  notices += licenceFile ? readFileSync(join(dir, licenceFile), "utf8").trim() + "\n" : `No licence file shipped; package.json says ${pkg.license}.\n`;
}
writeFileSync(join(here, "../../Resources/KeelShellNotices.txt"), notices);
console.log(`KeelShell.js ${readFileSync(out).length} bytes; ${packages.size} packages`);

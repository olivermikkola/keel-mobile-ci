# keel-shell

Builds `Resources/KeelShell.js`, the shell tool's bundle: [just-bash](https://github.com/vercel-labs/just-bash)
(Apache-2.0) wired to Keel's task workspace through `keel.*` (see `entry.js` and
`Harness/ShellTool.swift`).

```sh
cd tools/keel-shell
npm ci --ignore-scripts   # install the pinned packages without running their scripts
npm run build             # writes Resources/KeelShell.js and Resources/KeelShellNotices.txt
npm test                  # runs the bundle against a fake workspace in Node
```

Commit both generated files. The app does not run npm; Xcode copies the bundle.
`node:zlib` is stubbed (`zlib-stub.js`), so gzip/tar fail with a message.

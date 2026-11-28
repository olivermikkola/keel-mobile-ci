# Paired mode (Advanced)

Optional. Paired mode lets Keel Mobile pair with **Keel Desktop** (or `keel-desktop-cli host`) on a computer you own via a single QR code scan, so heavy or 24/7 tasks run on your computer while your iPhone stays free for on-device local models. No core feature depends on it, and the app stays fully usable standalone without a computer.

## QR pairing with Keel Desktop

1. On your computer, open **Keel Desktop → Settings → Connect Keel Mobile** and click **Turn on & show QR** (or run `keel-desktop-cli host` on a headless mini PC).
2. On your iPhone, open **Connections → Pair a computer** and tap **Scan QR code** (or paste the `keelpair://v1?...` link).

Keel Desktop generates a local self-signed TLS certificate and 256-bit bearer token stored under its private `secrets/` folder. The QR code carries:
- Your computer's display name
- Ordered HTTPS origins (home Wi-Fi IP first, plus Tailscale IPv4 automatically if installed)
- The leaf certificate's SHA-256 fingerprint (pinned by `PinnedHostDelegate` via `SecTrust` — no manual certificate setup, no plain HTTP, no redirects)
- The bearer token (stored only in iOS Keychain while unlocked; never in `UserDefaults`, logs, or prompts)

Computer threads run independently of `LocalChat`'s on-device runtime, so you can delegate a heavy or scheduled job to your computer and immediately switch back to a fast local model on your phone.

## Manual gateway (legacy)

The manual HTTPS gateway client (`Gateway.swift`, extracted from `webgpu-agent`) remains available in **Pair a computer → Manual gateway** for running raw host commands, approvals, and diffs over a manually entered HTTPS origin and bearer token.

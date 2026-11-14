# Paired mode (Advanced)

Optional. Paired mode connects Keel Mobile to a gateway on a computer you own.
No core feature depends on it, and the app must stay useful without it.

It is the native gateway client extracted from `webgpu-agent` (`apps/ios` @
`e32d726`): Keychain-backed pairing to a Rust gateway over HTTPS, host commands
with optional PTY, approvals and the workspace diff. The **Workspace** and
**Approvals** tabs appear only while a host is connected.

## Pairing

Use the gateway's **HTTPS origin**, with no path, token query or URL fragment.
Bare HTTP is rejected. The bearer credential lives in Keychain and is accessible
only while the device is unlocked. The address alone is in UserDefaults. Tap
Connect to reconnect after launch; Disconnect keeps the pairing, Forget removes
the Keychain entry.

The focused `ios-navigation` workflow runs the unit suite and native
pairing/navigation checks. Connected-layout screenshots use an explicit debug
simulator fixture; they do not prove a live host connection or execution. This
fixture is absent from device builds and creates no gateway client or stored credential.

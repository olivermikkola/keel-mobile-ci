# Keel GitHub connection

Small OAuth broker for the native iOS app. The owner registers a private GitHub
App at `/setup`, installs it on selected repositories, then users connect from
Keel using the system authentication browser. Access is the intersection of
GitHub user permissions and the App installation's selected repositories.

The app's OAuth secret stays on the server, encrypted at rest with `STORAGE_KEY`.
The generated private key and webhook secret are discarded. User access and
refresh tokens are returned to the phone over HTTPS, saved in Keychain, and never
persisted by the broker. OAuth uses state, S256 PKCE and one-time exchange.
Authorization codes in callbacks are short lived; tokens never enter URLs.

`npm ci`, `npm test`, `npm run typecheck`, `npm run build` check the server.
`cf deploy --secrets-file <protected-local-file>` deploys it; the secret file
must supply a random 32-byte base64url `STORAGE_KEY`. Keep that file outside Git
and preserve it across deployments so existing configuration can be decrypted.
Never print it. The Cloudflare account is supplied through the operator's normal
authentication/environment. No credential is checked into this project.

`/health` exercises deployed Web Crypto and the secret binding without saving
test data. `/config` exposes only readiness, the public client ID and install URL.
Errors log fixed stages and exception names; they deliberately omit exception
messages, stack traces, bodies and request URLs. Observability redacts query
strings. Owner setup must finish in the same browser within one hour.

The native simulator tests exercise recorded account/repository responses and
PKCE/refresh validation. They do not prove a real GitHub browser authorization or
a physical iPhone connection. Those require the owner to finish registration and
an actual app sign-in. The TestFlight build must include the native changes.

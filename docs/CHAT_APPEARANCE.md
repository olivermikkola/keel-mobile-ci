# Native chat appearance

This pass brings the supplied Keel jade/rust sail references to the native
iPhone app. The mark follows the existing Keel vector geometry; the source icon
is `docs/brand/mobile-icon.svg`, rendered to the opaque 1024px AppIcon asset.
Reference version labels are not app versions or product names.

The icon keeps the canonical Keel palette — jade `#709C8F`, rust `#B66E4F`,
ink `#101A1C` — on an opaque square, because iOS applies its own icon mask.
Render the SVG with Chromium, WebKit or librsvg. ImageMagick's built-in MSVG
renderer drops the gradient fills and produces a near-black tile, so do not use
`convert mobile-icon.svg AppIcon.png`.

Ink, jade, rust and paper form the palette. Light/dark appearance follows the
iPhone setting. The chat uses stronger model setup hierarchy, quieter message
surfaces, a visible working state, and a larger stop target. Keyboard dismissal
is interactive. Native text scaling and navigation remain in use. Saved tasks
and repository sheets share the same background instead of the system default.

Assistant fenced code blocks scroll horizontally and offer Copy. Code is never
executed, syntax-highlighted by a network service, or treated as an approved
edit. Copy preserves indentation, blank lines and CRLF bytes. Ordinary prose,
including model-produced links, stays literal selectable text.

The simulator-only `--chat-appearance-fixture` loads explicitly recorded content
in an isolated temporary archive; it runs no model, network or publishing tool.
It is absent from device builds. `ChatAppearanceUITests` captures dark/light
conversations, first launch, model setup and the largest Dynamic Type size.
`ChatBlockTests` checks copy content, incomplete streamed code and fence edges.

Run the normal `ios-simulator` workflow for native tests and screenshot artifacts.
These checks do not establish physical-iPhone inference or runtime safety;
the audit fixes are separate work.

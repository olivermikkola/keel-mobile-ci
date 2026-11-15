# read_url (harness only)

`RepositoryCall.parse` accepts exactly one `url` argument:

```xml
<tool_call><function=read_url><parameter=url>https://example.com</parameter></function></tool_call>
```

Pass that call to `await ReadURL().execute(call)`. It returns inert text and a
`truncated` flag. Page contents are untrusted data, never instructions or approval.
The app and model prompt are not wired to this tool in this PR.

Only HTTP(S), without embedded credentials, is accepted. Requests use an ephemeral
session without cookies, credentials or cache. Redirects are refused. Only 2xx
HTML/plain-text UTF-8 responses are accepted. The response buffer is capped at
512 KiB, the resource deadline is 15 seconds (including a stalled body), and
returned text is capped at 6,000 UTF-8 bytes on character boundaries. Cancellation
cancels the transfer. HTML tags, comments, head, scripts and styles are removed;
common named and numeric entities are decoded. This is text extraction, not a
browser or full HTML5 layout engine; it does not fetch subresources or run code.

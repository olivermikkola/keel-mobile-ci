# Product map

What Keel Mobile should grow into, from Oliver's reference screenshots
(2026-11-13): a local-model chat app's attach menu, and a general assistant's
sidebar, apps, connectors and scheduled tasks. Everything runs on the local
model. This is direction, not a status report; see the README for what works.

"Feasible" below is a judgement from the code and iOS rules, not a test. The
target phone is an iPhone 15 Pro (8 GB).

## Shell

| Wanted | Plan | Feasible |
| --- | --- | --- |
| Chat as the home screen with a few starter suggestions | Replace the three tabs with one chat screen | Yes |
| Sidebar: recents, projects, apps, scheduled, customize, search | Recents are today's saved tasks. A project groups tasks and shares files and instructions | Yes |
| Model name in the header, tap to switch | Move the model library behind it | Yes |
| `+` menu: attach file, attach photo, take photo, thinking on/off | See "Inputs" | Yes |
| Customize | Standing instructions the user writes, added to every chat | Yes |

## Inputs

| Wanted | Plan | Feasible |
| --- | --- | --- |
| Attach file | Text, CSV and PDF text go into the task workspace, where the existing tools can read and search them | Yes |
| Attach or take a photo | First: Apple's on-device text recognition turns the photo into text. Later: Bonsai's vision file (0.62 GB extra) for real image understanding | Text: yes. Vision: memory is tight next to the 9B model, unmeasured |
| Thinking toggle | A template switch, capped so a reply cannot run for minutes | Yes |
| Voice | iOS on-device dictation in, system speech out | Yes, later |

## Apps

An app is a preset: instructions, a tool set and a viewer for the result. Not a
separate program.

| App | Plan | Feasible |
| --- | --- | --- |
| Websites | The agent writes HTML, CSS and JavaScript in the workspace; a web view previews it on the phone with no build step; GitHub Pages publishes it | Yes. Best fit for what exists |
| Sheets | CSV in, `run_sql` and scripts to work on it, table viewer, CSV out | Yes |
| Docs | Markdown in the workspace, rendered viewer, export to PDF | Yes. Writing quality is the small model's |
| Study | Flashcards and quizzes from an attached file | Yes |
| Slides | Slides as HTML, shown in the web view, export to PDF | Yes, after Websites |
| Images | Generating images needs a second multi-gigabyte model that cannot share memory with the chat model | Not now |

## Connectors

Notion, Slack, mail, issue trackers and the like, through an MCP client and a
sign-in per service (the GitHub sign-in broker in `connector/` is the pattern).
A connector's tools are loaded only in chats where it is switched on, because
every tool description uses context a small model does not have.

Web search needs a search service: either the user's own API key or a small
server of ours. Reading a page the user links needs neither.

## Scheduled

iOS does not let an app run a model unattended at a set time. What can work: a
notification at the scheduled time, and the task runs when the user taps it.
A true background run is not something to promise.

## Order

1. Shell: one chat screen, sidebar, model in the header, `+` menu.
2. Attach file, and photo as recognised text.
3. The script sandbox's app runner (a web view). Websites, Sheets and Slides
   all need it.
4. Apps as presets: Websites, Sheets, Docs, Study.
5. Connectors through MCP.
6. Web search.
7. Scheduled as tap-to-run notifications.
8. Vision, voice, images.

Keep the rule from AGENTS.md: each capability is a tool with limits and tests.

# Decide

Decide answers the same questions about many documents with a decision
model on the iPhone: add PDFs, text files or pasted text, ask yes/no,
pick-one or scale questions, and get one answer per document with how sure
the model is. It is in Apps, next to Images, Videos and Carousels.

## The model

[LiquidAI d1-2B](https://huggingface.co/LiquidAI/d1-2B), built on LFM3-VL-2B,
as `LiquidAI/d1-2B-GGUF` `d1-2B-Q4_K_M.gguf` (1.10 GB, pinned in
`LocalModel.decide`). It is not a chat model: it writes nothing. For each
question it reads the document and the question once and the answer is read
from the scores it gives each option's label as its next token, turned into
chances with the temperature stored in the file (1.34).

Its picture file is not downloaded: Decide reads text only for now. A PDF
without text (a scan) is refused with a message.

## How it runs

- `Harness/Decision.swift`: questions, the prompt (the model's `systemone`
  template, rendered for a text document), the option labels and the
  scoring. A port of the `lfm3-d1` path of llama.cpp's `/v1/systemone`
  server (`tools/server/server-decision.cpp`, b12367), which is not part of
  the llama.cpp library the app links. Tested in `HarnessTests/DecisionTests.swift`.
- `Sources/DecisionRuntime.swift`: loads the GGUF with llama.cpp, splits long
  documents into parts, reads each question **as one batch** and takes the
  label logits.
- `Sources/DecideView.swift`: the screen. One document at a time, every
  question; the chat model is unloaded first; heat checks before each
  question; Stop and leaving the app interrupt the batch.

### One batch per question

d1 gives different answers when its prompt is read in more than one
`llama_decode` call: its short convolutions keep nothing between batches.
Measured against llama.cpp's server on the same model, splitting the prompt
after the document moved answers by up to 0.79. So:

- a question is never split: `n_batch = n_ubatch = contextSize`;
- a document cannot be read once and reused for several questions; each
  question reads it again (llama.cpp's server does the same).

### Memory, and long documents in parts

Reading one batch needs a working buffer that grows with the batch size,
measured with llama.cpp b12367 (CPU, flash attention on):

| Batch (tokens) | Working buffer |
|---|---|
| 4,096 | 2.2 GB |
| 8,192 | 4.6 GB |
| 16,384 | 9.7 GB (19.2 GB without flash attention) |

So the phone reads at most 4,096 tokens per question (about six pages):
1.1 GB of weights plus 2.2 GB. Decide checks free memory before it starts.
A longer document is split at line breaks into parts that fit
(`DecisionRuntime.parts(of:)`), and every part is answered and shown on its
own ("Lease.pdf · part 2 of 3"). Flash attention is on; it moves answers by
about 0.0005 compared with llama.cpp's server default.

## Limits

- Question kinds: the three llama.cpp supports (yes/no, pick one with up to
  26 options, scale of 2 to 10 levels). Extracting text, numbers or dates,
  boxes and multi-select need d1's Python heads and are not available.
- Up to 50 documents and 10 questions per run, PDFs up to 50 MB.
- A part only sees its own pages: a question whose answer needs two parts
  at once can be answered wrongly in both.
- The model's own benchmarks are its maker's; see the comparison below for
  what was checked here.
- iPhone speed and memory are not measured yet. Reading time grows with
  document length times the number of questions.

## Checking it

`tools/decide-eval` builds `Sources/DecisionRuntime.swift` and the harness
on Linux against a llama.cpp build, so the app's code can be compared with
llama.cpp's server on the same questions. See its README.

import Foundation

/// How a chat file is shown on the phone: a web page runs as written, a
/// Markdown file reads as a document or plays as flashcards, and a CSV file is
/// a table. Every kind becomes one self-contained page behind the same
/// Content Security Policy as `WebPreview`: no network, no frames, no forms.
public enum FileView {
    public enum Kind: Equatable, Sendable {
        case page, document, table, cards

        /// The button that opens it.
        public var action: String {
            switch self {
            case .page: return "Preview page"
            case .document: return "Read document"
            case .table: return "View table"
            case .cards: return "Study cards"
            }
        }
    }

    /// Rows a table shows. The file itself is not limited.
    public static let maxTableRows = 2_000

    public static func kind(path: String, text: String) -> Kind? {
        let lower = path.lowercased()
        if WebPreview.isPage(path) { return .page }
        if lower.hasSuffix(".csv") { return .table }
        if lower.hasSuffix(".md") || lower.hasSuffix(".markdown") {
            return StudyDeck.parse(text).cards.count >= StudyDeck.minimumCards ? .cards : .document
        }
        return nil
    }

    /// The page for `text` at `path`, or nil for a file with no viewer.
    /// `read` returns another chat file's text, for a page's stylesheets and scripts.
    public static func document(path: String, text: String, read: (String) -> String?) -> String? {
        let name = path.split(separator: "/").last.map(String.init) ?? path
        switch kind(path: path, text: text) {
        case .page: return WebPreview.document(html: text, path: path, read: read)
        case .document: return wrap(title: name, body: "<article>" + Markdown.html(text) + "</article>")
        case .table: return wrap(title: name, body: table(text))
        case .cards: return wrap(title: name, body: cards(StudyDeck.parse(text)), script: cardScript)
        case nil: return nil
        }
    }

    private static func wrap(title: String, body: String, script: String? = nil) -> String {
        let page = """
        <!DOCTYPE html><html><head><meta charset="utf-8">
        <meta name="viewport" content="width=device-width, initial-scale=1">
        <title>\(Markdown.escape(title))</title>
        <style>\(style)</style></head>
        <body>\(body)\(script.map { "<script>\($0)</script>" } ?? "")</body></html>
        """
        // WebPreview adds the policy right after the doctype; nothing here links out.
        return WebPreview.document(html: page, path: title) { _ in nil }
    }

    // MARK: - Table

    static func table(_ text: String) -> String {
        var rows = CSVParser.parse(text: text.replacingOccurrences(of: "\r\n", with: "\n"))
        guard !rows.isEmpty else { return "<p class=\"note\">This file has no rows.</p>" }
        let header = FileTables.columnNames(rows.removeFirst())
        let shown = rows.prefix(maxTableRows)
        let numeric = header.indices.map { column in
            let values = shown.compactMap { column < $0.count && !$0[column].isEmpty ? $0[column] : nil }
            return !values.isEmpty && values.allSatisfy { if case .text = SQLSandbox.value($0) { return false } else { return true } }
        }
        var html = "<p class=\"note\">\(rows.count) row\(rows.count == 1 ? "" : "s") · \(header.count) column\(header.count == 1 ? "" : "s")"
        if rows.count > shown.count { html += " · showing the first \(shown.count)" }
        html += "</p><div class=\"scroll\"><table class=\"data\"><thead><tr>"
        html += header.indices.map { "<th\(numeric[$0] ? " class=\"num\"" : "")>\(Markdown.escape(header[$0]))</th>" }.joined()
        html += "</tr></thead><tbody>"
        for row in shown {
            html += "<tr>" + header.indices.map { column in
                let value = column < row.count ? row[column] : ""
                return "<td\(numeric[column] ? " class=\"num\"" : "")>\(Markdown.escape(value))</td>"
            }.joined() + "</tr>"
        }
        return html + "</tbody></table></div>"
    }

    // MARK: - Cards

    static func cards(_ deck: StudyDeck) -> String {
        let data = deck.cards.map { card -> [String: Any] in
            ["q": card.question, "a": card.answer ?? "", "choices": card.isQuiz ? card.choices : [], "correct": card.isQuiz ? card.correct : []]
        }
        let json = (try? JSONSerialization.data(withJSONObject: data)).map { String(decoding: $0, as: UTF8.self) } ?? "[]"
        // Inside a script element, "</" could end it early.
        let safe = json.replacingOccurrences(of: "</", with: "<\\/").replacingOccurrences(of: "<!--", with: "<\\!--")
        return """
        \(deck.title.map { "<h1>\(Markdown.escape($0))</h1>" } ?? "")
        <p class="note" id="progress"></p>
        <div class="card" id="card" role="button" tabindex="0"><div id="question"></div><div id="answer" class="answer"></div><div id="choices"></div></div>
        <p class="note" id="hint"></p>
        <div class="controls"><button id="prev">Previous</button><button id="shuffle">Shuffle</button><button id="next">Next</button></div>
        <script id="deck" type="application/json">\(safe)</script>
        """
    }

    /// Plain DOM work with textContent only, so card text can never become markup.
    static let cardScript = """
    const cards = JSON.parse(document.getElementById('deck').textContent);
    let order = cards.map((_, i) => i), at = 0, shown = false, picked = {};
    const $ = id => document.getElementById(id);
    function score() {
      const quiz = cards.filter(c => c.choices.length), done = Object.keys(picked);
      const right = done.filter(i => cards[i].correct.includes(picked[i])).length;
      return quiz.length && done.length ? ' · ' + right + ' of ' + done.length + ' right' : '';
    }
    function render() {
      const index = order[at], card = cards[index];
      $('progress').textContent = 'Card ' + (at + 1) + ' of ' + cards.length + score();
      $('question').textContent = card.q;
      $('answer').textContent = card.a;
      $('answer').style.display = shown && !card.choices.length ? 'block' : 'none';
      const list = $('choices'); list.textContent = '';
      card.choices.forEach((text, n) => {
        const button = document.createElement('button');
        button.className = 'choice';
        button.textContent = text;
        if (index in picked) {
          if (card.correct.includes(n)) button.classList.add('right');
          else if (picked[index] === n) button.classList.add('wrong');
          button.disabled = true;
        }
        button.onclick = event => { event.stopPropagation(); picked[index] = n; render(); };
        list.appendChild(button);
      });
      $('hint').textContent = card.choices.length ? (index in picked ? '' : 'Pick an answer.') : (shown ? '' : 'Tap the card to see the answer.');
      $('prev').disabled = at === 0;
      $('next').disabled = at === cards.length - 1;
    }
    $('card').onclick = () => { shown = !shown; render(); };
    $('next').onclick = () => { if (at < cards.length - 1) { at++; shown = false; render(); } };
    $('prev').onclick = () => { if (at > 0) { at--; shown = false; render(); } };
    $('shuffle').onclick = () => {
      for (let i = order.length - 1; i > 0; i--) { const j = Math.floor(Math.random() * (i + 1)); [order[i], order[j]] = [order[j], order[i]]; }
      at = 0; shown = false; render();
    };
    render();
    """

    // MARK: - Style

    /// Keel's paper, ink and jade, in light and dark.
    static let style = """
    :root { color-scheme: light dark; --bg: #f7f3e9; --fg: #101a1c; --muted: #5d6668; --line: #d8d2c4; --surface: #ffffff; --accent: #2d5d4f; --right: #2d5d4f; --wrong: #93482d; }
    @media (prefers-color-scheme: dark) { :root { --bg: #101a1c; --fg: #eef0ec; --muted: #9aa5a3; --line: #2c3b3d; --surface: #172426; --accent: #a2d0be; --right: #a2d0be; --wrong: #d38f68; } }
    * { box-sizing: border-box; }
    body { margin: 0; padding: 20px 16px 48px; background: var(--bg); color: var(--fg); font: -apple-system-body; font-family: -apple-system, system-ui, sans-serif; line-height: 1.55; overflow-wrap: anywhere; }
    article { max-width: 42rem; margin: 0 auto; }
    h1, h2, h3, h4, h5, h6 { line-height: 1.25; margin: 1.4em 0 0.5em; }
    h1 { font-size: 1.7em; margin-top: 0.2em; }
    a { color: var(--accent); }
    code { font-family: ui-monospace, Menlo, monospace; font-size: 0.9em; background: var(--surface); padding: 0.1em 0.3em; border-radius: 4px; }
    pre { background: var(--surface); padding: 12px; border-radius: 10px; overflow-x: auto; }
    pre code { padding: 0; }
    blockquote { margin: 1em 0; padding-left: 12px; border-left: 3px solid var(--accent); color: var(--muted); }
    hr { border: 0; border-top: 1px solid var(--line); margin: 1.5em 0; }
    li { margin: 0.2em 0; }
    input[type=checkbox] { margin-right: 0.35em; accent-color: var(--accent); }
    .scroll { overflow-x: auto; margin: 1em 0; }
    table { border-collapse: collapse; font-size: 0.92em; }
    th, td { border: 1px solid var(--line); padding: 6px 10px; text-align: left; vertical-align: top; }
    th { background: var(--surface); position: sticky; top: 0; }
    table.data td, table.data th { white-space: nowrap; }
    .num { text-align: right; font-variant-numeric: tabular-nums; }
    .note { color: var(--muted); font-size: 0.9em; }
    .card { background: var(--surface); border: 1px solid var(--line); border-radius: 16px; padding: 24px 18px; min-height: 180px; font-size: 1.15em; white-space: pre-wrap; cursor: pointer; }
    .answer { margin-top: 18px; padding-top: 14px; border-top: 1px solid var(--line); color: var(--accent); }
    .choice { display: block; width: 100%; margin-top: 10px; padding: 12px; text-align: left; font: inherit; font-size: 0.9em; color: var(--fg); background: var(--bg); border: 1px solid var(--line); border-radius: 10px; }
    .choice.right { border-color: var(--right); color: var(--right); font-weight: 600; }
    .choice.wrong { border-color: var(--wrong); color: var(--wrong); text-decoration: line-through; }
    .controls { display: flex; gap: 8px; margin-top: 12px; }
    .controls button { flex: 1; padding: 12px; font: inherit; font-size: 0.95em; color: var(--accent); background: var(--surface); border: 1px solid var(--line); border-radius: 12px; }
    button:disabled { opacity: 0.45; }
    .choice:disabled { opacity: 1; }
    """
}

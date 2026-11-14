import Foundation

/// An app is a preset for a chat, not a separate program: a few lines of
/// instructions, the tools that job needs, and a viewer for what it makes
/// (`FileView`). Fewer tools also means a shorter prompt to read on the phone.
public enum AppPreset: String, Codable, CaseIterable, Sendable {
    case websites, sheets, docs, study

    public var title: String {
        switch self {
        case .websites: return "Websites"
        case .sheets: return "Sheets"
        case .docs: return "Docs"
        case .study: return "Study"
        }
    }

    /// One line under the title.
    public var summary: String {
        switch self {
        case .websites: return "Build a web page and preview it here"
        case .sheets: return "Ask about a spreadsheet or build a table"
        case .docs: return "Write and revise documents"
        case .study: return "Flashcards and quizzes from your notes"
        }
    }

    /// SF Symbol name.
    public var symbol: String {
        switch self {
        case .websites: return "safari"
        case .sheets: return "tablecells"
        case .docs: return "doc.richtext"
        case .study: return "rectangle.on.rectangle.angled"
        }
    }

    /// Ready-to-send first messages for an empty chat.
    public var starters: [String] {
        switch self {
        case .websites: return ["Make a one-page site for my café, open weekdays 8–16",
                                "Make a countdown page for a birthday on 24 December",
                                "Make a simple to-do list page"]
        case .sheets: return ["Make a monthly budget table with rent, food, transport and savings",
                              "Which row in my spreadsheet has the highest total?",
                              "Summarise my spreadsheet by category"]
        case .docs: return ["Write a short cover letter for a barista job",
                            "Turn my notes into a one-page report",
                            "Write a weekly meal plan for two"]
        case .study: return ["Make flashcards from my notes",
                             "Quiz me with 5 multiple-choice questions about the solar system",
                             "Make 10 flashcards of Spanish phrases for travelling"]
        }
    }

    /// Tool names this app offers. A plain chat offers every local tool.
    var tools: Set<String> {
        let files: Set<String> = ["search_repo", "read_file", "list_files", "propose_edit", "create_file", "delete_file", "rename_file"]
        switch self {
        case .websites: return files.union(["run_js"])
        case .sheets: return files.union(["run_sql", "run_js"])
        case .docs, .study: return files
        }
    }

    /// Read by the model, so short and concrete. Each names the file type
    /// its viewer opens.
    var instructions: String {
        switch self {
        case .websites:
            return "This chat is the Websites app. Build what the user asks as a web page they preview on this iPhone: one index.html with its CSS and JavaScript inside, unless the user wants separate files. Keep it compact: a clean layout for a phone screen, short simple CSS, and real text instead of placeholders. The page cannot load anything from the internet, so use no external fonts, scripts or images. To change a page, read it and use propose_edit."
        case .sheets:
            return "This chat is the Sheets app. Work with tables: the user's .csv files or new ones. To answer a question about a .csv file, query it with run_sql (SELECT ... FROM name.csv) and report the exact numbers from the result. Answers go in your reply. A table the user asks you to make, build or change goes in a new .csv file made with create_file, header row first, quoting any value that has a comma, so the user can open and keep it as a sheet; then say in one sentence what the file holds."
        case .docs:
            return "This chat is the Docs app. Write documents as Markdown .md files: a # title, ## sections, short paragraphs, and lists or tables where they help. The user reads them rendered on this iPhone. Write the full text, never placeholders. To revise a document, read it and use propose_edit on the part that changes."
        case .study:
            return "This chat is the Study app. Help the user learn a topic or the files they attached. Make flashcards as a .md file: a # title, then for each card a line starting Q: and a line starting A:, with a blank line between cards. For a multiple-choice question, write the Q: line, each choice on a line starting with a dash, and always an A: line with the right choice, like this:\nQ: Which planet is closest to the Sun?\n- Venus\n- Mercury\nA: Mercury\nThe answers stay hidden until the user picks a choice. The user studies them on this iPhone. Base the cards on the attached file when there is one. Keep answers short. Make 8 to 12 cards unless asked otherwise."
        }
    }
}

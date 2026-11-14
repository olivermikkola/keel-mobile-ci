import Foundation

/// One eval task. `check` judges the outcome without a model:
/// read tasks by the final answer and what was actually opened, edit tasks by
/// running a hidden Python check against the files the agent left behind.
struct EvalTask {
    enum Kind: String { case read, edit, local }
    let id: String
    let kind: Kind
    /// `repo` is this repository at the pinned commit; `shop` is fixtures/shop.
    let fixture: String
    let prompt: String
    /// Read tasks: the answer must contain one string from every group (ignoring case).
    var answer: [[String]] = []
    /// Read tasks: at least one of these files must have been read or matched by a search.
    var evidence: [String] = []
    /// Local tasks: files attached to the message, as the app sends them.
    var attachments: [(path: String, text: String)] = []
    /// Local tasks: judges the chat's files after every proposal was applied, the final answer and the tool steps taken.
    var check: ((TaskWorkspace, String, Int) -> Bool)? = nil
    /// Local tasks: the app the chat was opened in. `--plain` drops it, to compare.
    var app: AppPreset? = nil
}

private func file(_ workspace: TaskWorkspace, _ path: String) -> String? { try? workspace.read(path).text }
private func htmlFiles(_ workspace: TaskWorkspace) -> [String] {
    workspace.textFiles().filter { $0.path.hasSuffix(".html") }.map(\.text)
}

private let ordersCSV = "order,region,amount\n1000,North,14\n1001,South,67\n1002,East,120\n1003,West,173\n1004,North,26\n1005,East,79\n1006,West,132\n1007,North,185\n1008,South,38\n1009,East,91\n1010,North,144\n1011,South,197\n1012,East,50\n1013,West,103\n1014,North,156\n1015,East,209\n1016,West,62\n1017,North,115\n1018,South,168\n1019,East,21\n1020,North,74\n1021,South,127\n1022,East,180\n1023,West,33\n1024,North,86\n1025,East,139\n1026,West,192\n1027,North,45\n1028,South,98\n1029,East,151\n1030,North,204\n1031,South,57\n1032,East,110\n1033,West,163\n1034,North,16\n1035,East,69\n1036,West,122\n1037,North,175\n1038,South,28\n1039,East,81\n1040,North,134\n1041,South,187\n1042,East,40\n1043,West,93\n1044,North,146\n1045,East,199\n1046,West,52\n1047,North,105\n"

private let regionTotals = ["North": 1625.0, "South": 967.0, "East": 1539.0, "West": 1125.0]

/// A new .csv file holding the total of every region in orders.csv.
private func savedRegionTotals(_ workspace: TaskWorkspace) -> Bool {
    workspace.textFiles().contains { file in
        file.path != "orders.csv" && file.path.hasSuffix(".csv") && regionTotals.allSatisfy { region, total in
            CSVParser.parse(text: file.text).contains { row in
                row.contains(region) && row.contains { Double($0.trimmingCharacters(in: .whitespaces)) == total }
            }
        }
    }
}

/// Files of one kind the agent left, by viewer.
private func viewed(_ workspace: TaskWorkspace, _ kind: FileView.Kind) -> [String] {
    workspace.textFiles().filter { FileView.kind(path: $0.path, text: $0.text) == kind }.map(\.text)
}

/// The commit of this repository that the read tasks ask about. Fixed, so
/// results stay comparable while the code moves on.
let pinnedRepositoryCommit = "64fdebdc617dbaed80927d6fdac202b848ff593d"

let evalTasks: [EvalTask] = [
    EvalTask(id: "readme", kind: .read, fixture: "repo", prompt: "What does this repository do? Answer from the README.",
             answer: [["iphone", "phone"]], evidence: ["README.md"]),
    EvalTask(id: "download-resume", kind: .read, fixture: "repo", prompt: "Where is the model download resumed after a pause?",
             answer: [["ModelTransfer", "ModelLibrary"]], evidence: ["Sources/ModelTransfer.swift", "Sources/ModelLibrary.swift"]),
    EvalTask(id: "github-client", kind: .read, fixture: "repo", prompt: "Which file defines the GitHub repository client?",
             answer: [["GitHubRepository.swift"]], evidence: ["Sources/GitHubRepository.swift"]),
    EvalTask(id: "tool-limit", kind: .read, fixture: "repo", prompt: "How many tool calls can the agent make per message?",
             answer: [["eight", "8", "16", "sixteen"]], evidence: ["Sources/LocalChat.swift", "Sources/RepositoryAgent.swift", "docs/HARNESS.md", "docs/DIRECTOR_MODE.md", "README.md"]),
    EvalTask(id: "kv-budget", kind: .read, fixture: "repo", prompt: "Find where the KV cache memory budget is computed.",
             answer: [["ModelLibrary"]], evidence: ["Sources/ModelLibrary.swift"]),
    EvalTask(id: "models", kind: .read, fixture: "repo", prompt: "What models can I download in the app?",
             answer: [["4B"], ["9B"]], evidence: ["Sources/ModelLibrary.swift", "README.md", "docs/ON_DEVICE_PLAN.md"]),
    EvalTask(id: "simulator-workflow", kind: .read, fixture: "repo", prompt: "Which workflow runs the iOS simulator tests?",
             answer: [["ios-simulator", "ios.yml", "codemagic"]], evidence: ["codemagic.yaml", "ci/mirror/ios.yml", "AGENTS.md", "docs/CI_MIRROR.md"]),
    EvalTask(id: "background-stop", kind: .read, fixture: "repo", prompt: "Where does the app stop generating when it goes to the background?",
             answer: [["LocalChat"]], evidence: ["Sources/LocalChat.swift"]),
    EvalTask(id: "edit-review", kind: .read, fixture: "repo", prompt: "Explain how edit proposals are reviewed before they apply.",
             answer: [["review"], ["apply", "applied"]],
             evidence: ["Sources/LocalChat.swift", "Sources/ProposedFileEdit.swift", "Sources/FileEditReviewView.swift", "Sources/DirectorTools.swift", "docs/REVIEWING_CHANGES.md", "docs/DIRECTOR_MODE.md"]),
    EvalTask(id: "delete-test", kind: .read, fixture: "repo", prompt: "Is there a test for saved task deletion? Show it.",
             answer: [["testDeleteOnlyChosenTaskAndKeepLastTaskUsable", "SavedTaskTests"]], evidence: ["Tests/SavedTaskTests.swift", "UITests/SavedTaskUITests.swift"]),
    EvalTask(id: "license", kind: .read, fixture: "repo", prompt: "What license is this project under?",
             answer: [["all rights reserved", "proprietary"]], evidence: ["LICENSE", "README.md"]),
    EvalTask(id: "director-prompt", kind: .read, fixture: "repo", prompt: "Where is the system prompt for Director mode?",
             answer: [["DirectorTools"]], evidence: ["Sources/DirectorTools.swift"]),

    // A chat with no repository: its own files and the local prompt (Harness/LocalFiles.swift).
    EvalTask(id: "local-greeting", kind: .local, fixture: "local", prompt: "Hi! What can you help me with?",
             check: { _, answer, steps in steps == 0 && !answer.isEmpty }),
    EvalTask(id: "local-capital", kind: .local, fixture: "local", prompt: "What is the capital of Finland?",
             check: { _, answer, steps in steps == 0 && answer.contains("Helsinki") }),
    EvalTask(id: "local-page", kind: .local, fixture: "local",
             prompt: "Make me a simple one-page website for my coffee shop Nordic Bean. Show a menu with three drinks and their prices.",
             check: { workspace, _, _ in htmlFiles(workspace).contains { $0.contains("Nordic Bean") && $0.lowercased().contains("<html") } }),
    EvalTask(id: "local-save-note", kind: .local, fixture: "local",
             prompt: "Write a packing list for a three-day hiking trip and save it as packing-list.md.",
             check: { workspace, _, _ in (file(workspace, "packing-list.md")?.split(separator: "\n").count ?? 0) >= 5 }),
    EvalTask(id: "local-csv-question", kind: .local, fixture: "local",
             prompt: "Which product had the highest total sales in the attached file?",
             attachments: [(path: "sales.csv", text: "date,product,amount\n2026-11-01,Tea,12\n2026-11-01,Coffee,30\n2026-11-02,Cocoa,25\n2026-11-02,Tea,40\n2026-11-03,Coffee,15\n2026-11-03,Cocoa,20\n")],
             check: { _, answer, _ in answer.contains("Tea") && answer.contains("52") }),
    EvalTask(id: "local-csv-count", kind: .local, fixture: "local",
             prompt: "In orders.csv, which region has the most orders with an amount over 100, and how many?",
             attachments: [(path: "orders.csv", text: ordersCSV)],
             check: { _, answer, _ in answer.contains("North") && answer.range(of: #"\b9\b"#, options: .regularExpression) != nil }),
    EvalTask(id: "local-edit-attached", kind: .local, fixture: "local",
             prompt: "In todo.md, mark \"Buy milk\" as done.",
             attachments: [(path: "todo.md", text: "# Todo\n\n- [ ] Buy milk\n- [ ] Call Anna\n- [ ] Book dentist\n")],
             check: { workspace, _, _ in
                 let text = file(workspace, "todo.md") ?? ""
                 return text.contains("- [x] Buy milk") && text.contains("- [ ] Call Anna") && text.contains("- [ ] Book dentist")
             }),

    EvalTask(id: "app-websites", kind: .local, fixture: "local",
             prompt: "Make a one-page site for my café Kahvila Aura in Turku, open weekdays 8–16.",
             check: { workspace, _, _ in
                 viewed(workspace, .page).contains { page in
                     page.contains("Aura") && page.lowercased().contains("<style") && !page.contains("src=\"http") && !page.contains("href=\"http")
                 }
             }, app: .websites),
    EvalTask(id: "app-sheets-table", kind: .local, fixture: "local",
             prompt: "Make a table of the total amount per region in orders.csv.",
             attachments: [(path: "orders.csv", text: ordersCSV)],
             // A correct table in the reply is a fine answer to "make a table".
             check: { workspace, answer, _ in
                 regionTotals.allSatisfy { answer.contains($0.key) && answer.contains(String(Int($0.value))) } || savedRegionTotals(workspace)
             }, app: .sheets),
    EvalTask(id: "app-sheets-save", kind: .local, fixture: "local",
             prompt: "Save a new sheet with the total amount per region from orders.csv.",
             attachments: [(path: "orders.csv", text: ordersCSV)],
             check: { workspace, _, _ in savedRegionTotals(workspace) }, app: .sheets),
    EvalTask(id: "app-docs", kind: .local, fixture: "local",
             prompt: "Write a one-page guide to brewing pour-over coffee at home.",
             check: { workspace, _, _ in
                 viewed(workspace, .document).contains { $0.hasPrefix("# ") && $0.components(separatedBy: "\n## ").count >= 3 }
             }, app: .docs),
    EvalTask(id: "app-study-cards", kind: .local, fixture: "local",
             prompt: "Make flashcards from my notes.",
             attachments: [(path: "biology-notes.md", text: "# Photosynthesis\n\nPlants make glucose from carbon dioxide and water using light. It happens in the chloroplasts, which contain the green pigment chlorophyll. Oxygen is released as a by-product. The light-dependent reactions happen in the thylakoid membranes and make ATP and NADPH. The Calvin cycle happens in the stroma and fixes carbon dioxide into sugar. The enzyme that fixes carbon dioxide is RuBisCO.\n")],
             check: { workspace, _, _ in
                 workspace.textFiles().contains { $0.path != "biology-notes.md" && StudyDeck.parse($0.text).cards.count >= 5 }
             }, app: .study),
    EvalTask(id: "app-study-quiz", kind: .local, fixture: "local",
             prompt: "Quiz me with 5 multiple-choice questions about the solar system.",
             check: { workspace, _, _ in
                 workspace.textFiles().contains { StudyDeck.parse($0.text).cards.filter(\.isQuiz).count >= 5 }
             }, app: .study),

    EvalTask(id: "fix-discount", kind: .edit, fixture: "shop",
             prompt: "apply_discount in shop/pricing.py makes prices higher instead of lower. Fix it."),
    EvalTask(id: "fix-pagination", kind: .edit, fixture: "shop",
             prompt: "Each page of the inventory listing is missing its first product. Find the bug and fix it."),
    EvalTask(id: "add-tax", kind: .edit, fixture: "shop",
             prompt: "Add a function total_with_tax(cart) to shop/pricing.py. It returns cart.total() multiplied by (1 + TAX_RATE), using TAX_RATE from shop/config.py."),
    EvalTask(id: "new-coupons", kind: .edit, fixture: "shop",
             prompt: "Create shop/coupons.py with a function is_valid(code). It returns True only when the code starts with \"KEEL-\" and is exactly 9 characters long, otherwise False."),
    EvalTask(id: "rename-calc", kind: .edit, fixture: "shop",
             prompt: "Rename the function calc to line_total everywhere it is defined, imported or called."),
    EvalTask(id: "remove-legacy", kind: .edit, fixture: "shop",
             prompt: "shop/legacy.py is no longer used. Delete it and remove its import."),
    EvalTask(id: "page-size", kind: .edit, fixture: "shop",
             prompt: "Change the inventory page size from 10 to 20 and update the README, which mentions the page size."),
    EvalTask(id: "currency", kind: .edit, fixture: "shop",
             prompt: "Give format_price in shop/pricing.py an optional second parameter named currency. When it is not given, the default currency from the config is used, as now."),
]

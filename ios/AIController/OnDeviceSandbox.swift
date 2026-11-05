import Foundation

// Everything here lives inside the iPhone IPA. The remote model never executes tools.
struct ModelFunction: Codable {
    var name: String
    var arguments: String
}
struct ModelToolCall: Codable {
    var id: String
    var type: String
    var function: ModelFunction
}
struct ModelMessage: Codable {
    var role: String
    var content: String?
    var tool_call_id: String?
    var tool_calls: [ModelToolCall]?

    init(role: String, content: String? = nil, tool_call_id: String? = nil,
         tool_calls: [ModelToolCall]? = nil) {
        self.role = role
        self.content = content
        self.tool_call_id = tool_call_id
        self.tool_calls = tool_calls
    }
}
struct LocalTask: Codable, Identifiable {
    var id: Int
    var title: String
    var done = false
}
struct LocalAgent: Codable {
    var messages: [ModelMessage] = []
    var notes: [String: String] = [:]
    var tasks: [LocalTask] = []
    var files: [String: String] = [:]
    var nextTaskID = 1
}
struct LocalDocument: Codable {
    var agents: [String: LocalAgent] = ["main": LocalAgent()]
}
struct LocalResult: Decodable {
    var message: ModelMessage
}

enum SandboxError: LocalizedError {
    case denied(String)
    var errorDescription: String? {
        switch self { case .denied(let reason): return reason }
    }
}

@MainActor
final class OnDeviceSandbox {
    private let location: URL
    private(set) var document: LocalDocument
    let importedApps = ImportedAppLibrary()
    static let allowedHosts: Set<String> = ["en.wikipedia.org", "docs.python.org"]

    init() {
        let root = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        self.location = root.appendingPathComponent("LocalSandbox.json")
        if let bytes = try? Data(contentsOf: location),
           let state = try? JSONDecoder().decode(LocalDocument.self, from: bytes),
           !state.agents.isEmpty {
            self.document = state
        } else {
            self.document = LocalDocument()
        }
    }

    var agentNames: [String] {
        ["main"] + document.agents.keys.filter { $0 != "main" }.sorted()
    }
    func agent(_ name: String) -> LocalAgent {
        document.agents[name] ?? LocalAgent()
    }
    private func save() throws {
        let encoded = try JSONEncoder().encode(document)
        try encoded.write(to: location, options: [.atomic, .completeFileProtectionUnlessOpen])
    }
    func update(_ name: String, _ change: (inout LocalAgent) throws -> Void) throws {
        guard var agent = document.agents[name] else {
            throw SandboxError.denied("Unknown local agent.")
        }
        try change(&agent)
        document.agents[name] = agent
        try save()
    }
    func clone(_ name: String) throws {
        guard name.range(of: "^[A-Za-z0-9_-]{1,32}$", options: .regularExpression) != nil else {
            throw SandboxError.denied("Agent name must contain 1-32 letters, digits, _ or -.")
        }
        guard document.agents[name] == nil else {
            throw SandboxError.denied("Agent already exists.")
        }
        guard document.agents.count < 8 else {
            throw SandboxError.denied("Eight-agent limit reached.")
        }
        document.agents[name] = LocalAgent()
        try save()
    }
    func reset(_ name: String) throws {
        try update(name) { $0.messages = [] }
    }

    private func word(_ args: [String: Any], _ key: String, max: Int) throws -> String {
        guard let value = args[key] as? String, value.count <= max else {
            throw SandboxError.denied("Invalid or oversized " + key + ".")
        }
        return value
    }
    private func key(_ value: String, file: Bool = false) throws -> String {
        let pattern = file ? "^[A-Za-z0-9_-]{1,32}\\.(txt|md)$" : "^[A-Za-z0-9_. -]{1,64}$"
        guard value.range(of: pattern, options: .regularExpression) != nil else {
            throw SandboxError.denied("Invalid virtual name.")
        }
        return value
    }

    func execute(agent name: String, call: ModelToolCall) async -> String {
        do {
            guard call.type == "function",
                  let raw = call.function.arguments.data(using: .utf8),
                  raw.count <= 8500,
                  let args = try JSONSerialization.jsonObject(with: raw) as? [String: Any] else {
                throw SandboxError.denied("Invalid tool arguments.")
            }
            let result: Any
            switch call.function.name {
            case "calculate":
                result = try Arithmetic.evaluate(word(args, "expression", max: 200))
            case "notes":
                result = try notes(name, args)
            case "tasks":
                result = try tasks(name, args)
            case "workspace":
                result = try workspace(name, args)
            case "clone_agent":
                let newName = try word(args, "name", max: 32)
                try clone(newName)
                result = "Created local agent " + newName
            case "read_web":
                let url = try word(args, "url", max: 2048)
                result = try await readWeb(url)
            case "app_action":
                result = try importedApps.execute(agent: name, arguments: args)
            default:
                throw SandboxError.denied("Tool is not installed in the IPA.")
            }
            if let text = result as? String { return text }
            let bytes = try JSONSerialization.data(withJSONObject: result, options: [.fragmentsAllowed, .sortedKeys])
            return String(data: bytes, encoding: .utf8) ?? "(Invalid tool output)"
        } catch {
            return "Denied or failed: " + error.localizedDescription
        }
    }

    private func notes(_ name: String, _ args: [String: Any]) throws -> Any {
        let action = try word(args, "action", max: 12)
        if action == "list" { return agent(name).notes.keys.sorted() }
        let title = try key(word(args, "name", max: 64))
        if action == "read" {
            guard let text = agent(name).notes[title] else {
                throw SandboxError.denied("Note not found.")
            }
            return text
        }
        if action == "write" {
            let value = try word(args, "text", max: 4000)
            try update(name) { agent in
                guard agent.notes[title] != nil || agent.notes.count < 32 else {
                    throw SandboxError.denied("32-note limit reached.")
                }
                agent.notes[title] = value
            }
            return "Saved note " + title
        }
        throw SandboxError.denied("Unknown notes action.")
    }

    private func tasks(_ name: String, _ args: [String: Any]) throws -> Any {
        let action = try word(args, "action", max: 12)
        if action == "list" {
            return agent(name).tasks.map { ["id": $0.id, "title": $0.title, "done": $0.done] as [String: Any] }
        }
        if action == "add" {
            let title = try word(args, "title", max: 140).trimmingCharacters(in: .whitespacesAndNewlines)
            guard !title.isEmpty else { throw SandboxError.denied("Empty task title.") }
            var id = 0
            try update(name) { agent in
                guard agent.tasks.count < 32 else { throw SandboxError.denied("32-task limit reached.") }
                id = agent.nextTaskID
                agent.tasks.append(LocalTask(id: id, title: title))
                agent.nextTaskID += 1
            }
            return ["id": id, "title": title] as [String: Any]
        }
        guard let id = args["id"] as? Int else {
            throw SandboxError.denied("Task id must be an integer.")
        }
        guard action == "done" || action == "delete" else {
            throw SandboxError.denied("Unknown task action.")
        }
        try update(name) { agent in
            guard let index = agent.tasks.firstIndex(where: { $0.id == id }) else {
                throw SandboxError.denied("Task not found.")
            }
            if action == "done" { agent.tasks[index].done = true }
            else { agent.tasks.remove(at: index) }
        }
        return action == "done" ? "Completed task \(id)" : "Deleted task \(id)"
    }

    private func workspace(_ name: String, _ args: [String: Any]) throws -> Any {
        let action = try word(args, "action", max: 12)
        if action == "list" { return agent(name).files.keys.sorted() }
        let filename = try key(word(args, "name", max: 36), file: true)
        if action == "read" {
            guard let text = agent(name).files[filename] else {
                throw SandboxError.denied("Virtual file not found.")
            }
            return text
        }
        if action == "write" {
            let text = try word(args, "text", max: 4000)
            try update(name) { agent in
                guard agent.files[filename] != nil || agent.files.count < 16 else {
                    throw SandboxError.denied("16-file limit reached.")
                }
                agent.files[filename] = text
            }
            return "Saved virtual file " + filename
        }
        if action == "delete" {
            try update(name) { agent in
                guard agent.files.removeValue(forKey: filename) != nil else {
                    throw SandboxError.denied("Virtual file not found.")
                }
            }
            return "Deleted virtual file " + filename
        }
        throw SandboxError.denied("Unknown workspace action.")
    }

    private func readWeb(_ address: String) async throws -> Any {
        guard let parsed = URLComponents(string: address),
              parsed.scheme == "https",
              let host = parsed.host?.lowercased(),
              Self.allowedHosts.contains(host),
              parsed.port == nil || parsed.port == 443,
              parsed.user == nil, parsed.password == nil,
              parsed.fragment == nil,
              let url = parsed.url else {
            throw SandboxError.denied("Only allowlisted public HTTPS domains are accessible.")
        }
        let delegate = RefuseRedirects()
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 12
        config.timeoutIntervalForResource = 12
        config.httpCookieAcceptPolicy = .never
        config.httpShouldSetCookies = false
        let session = URLSession(configuration: config, delegate: delegate, delegateQueue: nil)
        defer { session.finishTasksAndInvalidate() }
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue("text/plain, text/html", forHTTPHeaderField: "Accept")
        let (bytes, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            throw SandboxError.denied("HTTPS request failed; redirects are prohibited.")
        }
        let type = http.value(forHTTPHeaderField: "Content-Type")?.lowercased() ?? ""
        guard type.hasPrefix("text/"), bytes.count <= 65536 else {
            throw SandboxError.denied("Only up to 64 KiB of plain text/HTML may be read.")
        }
        return ["untrusted_web_content": String(decoding: bytes, as: UTF8.self)]
    }
}

private final class RefuseRedirects: NSObject, URLSessionTaskDelegate {
    func urlSession(_ session: URLSession, task: URLSessionTask,
                    willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest,
                    completionHandler: @escaping (URLRequest?) -> Void) {
        completionHandler(nil)
    }
}

// No eval(), shell, scripting, or OS execution. Just a bounded arithmetic grammar.
private struct Arithmetic {
    private let chars: [Character]
    private var index = 0
    private var depth = 0

    static func evaluate(_ expression: String) throws -> Double {
        var parser = Arithmetic(chars: Array(expression))
        let result = try parser.parseExpression()
        parser.skipSpaces()
        guard parser.index == parser.chars.count else {
            throw SandboxError.denied("Unsupported calculator syntax.")
        }
        return try parser.checked(result)
    }
    private mutating func skipSpaces() {
        while index < chars.count && chars[index].isWhitespace { index += 1 }
    }
    private func checked(_ number: Double) throws -> Double {
        guard number.isFinite, abs(number) <= 1.0e15 else {
            throw SandboxError.denied("Calculator result exceeds limits.")
        }
        return number
    }
    private mutating func parseExpression() throws -> Double {
        var value = try parseTerm()
        while true {
            skipSpaces()
            if accept("+") { value = try checked(value + parseTerm()) }
            else if accept("-") { value = try checked(value - parseTerm()) }
            else { return value }
        }
    }
    private mutating func parseTerm() throws -> Double {
        var value = try parseFactor()
        while true {
            skipSpaces()
            if accept("*") { value = try checked(value * parseFactor()) }
            else if accept("/") { value = try checked(value / parseFactor()) }
            else if accept("%") { value = try checked(value.truncatingRemainder(dividingBy: parseFactor())) }
            else { return value }
        }
    }
    private mutating func parseFactor() throws -> Double {
        skipSpaces()
        if accept("+") { return try parseFactor() }
        if accept("-") { return try checked(-parseFactor()) }
        if accept("(") {
            depth += 1
            guard depth <= 12 else { throw SandboxError.denied("Expression nested too deeply.") }
            let value = try parseExpression()
            guard accept(")") else { throw SandboxError.denied("Missing closing parenthesis.") }
            depth -= 1
            return value
        }
        let start = index
        while index < chars.count && (chars[index].isNumber || chars[index] == ".") {
            index += 1
        }
        guard start < index, let value = Double(String(chars[start..<index])) else {
            throw SandboxError.denied("Expected number.")
        }
        return try checked(value)
    }
    private mutating func accept(_ symbol: Character) -> Bool {
        skipSpaces()
        guard index < chars.count, chars[index] == symbol else { return false }
        index += 1
        return true
    }
}

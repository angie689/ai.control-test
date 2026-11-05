import Foundation
import SwiftUI
import UniformTypeIdentifiers

// A .aicapp is a JSON *manifest*, never executable code. It only defines
// names/descriptions for safe, predefined virtual-storage operations.
struct ImportedAction: Codable, Identifiable {
    let id: String
    let title: String
    let description: String
    let operation: String
}

struct ImportedApp: Codable, Identifiable {
    let format: Int
    let id: String
    let name: String
    let description: String
    let actions: [ImportedAction]
}

struct InstalledApp: Codable, Identifiable {
    var manifest: ImportedApp
    var enabled: Bool
    var id: String { manifest.id }
}

private struct AppLibraryState: Codable {
    var installed: [InstalledApp] = []
    // agent -> app ID -> virtual record key -> text
    var records: [String: [String: [String: String]]] = [:]
}

@MainActor
final class ImportedAppLibrary {
    private let url: URL
    private var state: AppLibraryState

    init() {
        let directory = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        url = directory.appendingPathComponent("ImportedSandboxApps.json")
        if let data = try? Data(contentsOf: url),
           let stored = try? JSONDecoder().decode(AppLibraryState.self, from: data) {
            state = stored
        } else {
            state = AppLibraryState()
        }
    }

    var installed: [InstalledApp] { state.installed.sorted { $0.manifest.name < $1.manifest.name } }

    private func persist() throws {
        let data = try JSONEncoder().encode(state)
        try data.write(to: url, options: [.atomic, .completeFileProtectionUnlessOpen])
    }

    private func validIdentifier(_ value: String) -> Bool {
        value.range(of: "^[a-z][a-z0-9_]{1,31}$", options: .regularExpression) != nil
    }

    func preview(url incoming: URL) throws -> ImportedApp {
        let ext = incoming.pathExtension.lowercased()
        guard ext == "aicapp" || ext == "json" else {
            throw SandboxError.denied("Import .aicapp or .json sandbox app packages only. Not .ipa files.")
        }
        let scoped = incoming.startAccessingSecurityScopedResource()
        defer { if scoped { incoming.stopAccessingSecurityScopedResource() } }
        let values = try incoming.resourceValues(forKeys: [.fileSizeKey])
        guard (values.fileSize ?? 0) <= 32768 else {
            throw SandboxError.denied("App packages must be 32 KB or smaller.")
        }
        let bytes = try Data(contentsOf: incoming)
        guard bytes.count <= 32768,
              let object = try JSONSerialization.jsonObject(with: bytes) as? [String: Any],
              Set(object.keys) == Set(["format", "id", "name", "description", "actions"]),
              let list = object["actions"] as? [[String: Any]],
              list.allSatisfy({ Set($0.keys) == Set(["id", "title", "description", "operation"]) }) else {
            throw SandboxError.denied("Invalid app manifest. Only the documented fields are allowed.")
        }
        let manifest = try JSONDecoder().decode(ImportedApp.self, from: bytes)
        try validate(manifest)
        return manifest
    }

    private func validate(_ app: ImportedApp) throws {
        guard app.format == 1,
              validIdentifier(app.id),
              (2...40).contains(app.name.count),
              (1...220).contains(app.description.count),
              (1...12).contains(app.actions.count) else {
            throw SandboxError.denied("Unsupported app format, name, or action count.")
        }
        let operations: Set<String> = ["list", "read", "write", "append", "delete"]
        var names: Set<String> = []
        for action in app.actions {
            guard validIdentifier(action.id), !names.contains(action.id),
                  operations.contains(action.operation),
                  (2...50).contains(action.title.count),
                  (1...160).contains(action.description.count) else {
                throw SandboxError.denied("Invalid or duplicate app action.")
            }
            names.insert(action.id)
        }
    }

    func install(_ app: ImportedApp) throws {
        try validate(app)
        guard state.installed.count < 12 else {
            throw SandboxError.denied("Maximum of 12 imported sandbox apps.")
        }
        guard !state.installed.contains(where: { $0.id == app.id }) else {
            throw SandboxError.denied("An app with this ID is already installed.")
        }
        state.installed.append(InstalledApp(manifest: app, enabled: true))
        try persist()
    }

    func setEnabled(_ enabled: Bool, id: String) throws {
        guard let index = state.installed.firstIndex(where: { $0.id == id }) else {
            throw SandboxError.denied("Unknown imported app.")
        }
        state.installed[index].enabled = enabled
        try persist()
    }

    func remove(id: String) throws {
        guard state.installed.contains(where: { $0.id == id }) else {
            throw SandboxError.denied("App is not installed.")
        }
        state.installed.removeAll { $0.id == id }
        for agent in state.records.keys {
            state.records[agent]?.removeValue(forKey: id)
        }
        try persist()
    }

    func promptCatalogue() -> String {
        let enabled = state.installed.filter { $0.enabled }
        guard !enabled.isEmpty else { return "No extra sandbox apps are installed." }
        let descriptions = enabled.map { app in
            let actions = app.manifest.actions.map {
                "\($0.id): \($0.description) [\($0.operation)]"
            }.joined(separator: "; ")
            return "\(app.id) (\(app.manifest.name)): \(app.manifest.description). Actions: \(actions)."
        }
        return String(descriptions.joined(separator: "\n").prefix(7000))
    }

    func execute(agent: String, arguments: [String: Any]) throws -> Any {
        guard let id = arguments["app_id"] as? String,
              let actionID = arguments["action"] as? String,
              let app = state.installed.first(where: { $0.id == id && $0.enabled }),
              let definition = app.manifest.actions.first(where: { $0.id == actionID }) else {
            throw SandboxError.denied("App is not installed, enabled, or action is unavailable.")
        }
        let operation = definition.operation
        var data = state.records[agent]?[id] ?? [:]
        if operation == "list" {
            return data.keys.sorted()
        }
        guard let key = arguments["key"] as? String,
              key.range(of: "^[A-Za-z0-9_. -]{1,50}$", options: .regularExpression) != nil else {
            throw SandboxError.denied("Provide a simple virtual record key.")
        }
        if operation == "read" {
            guard let value = data[key] else {
                throw SandboxError.denied("Record not found.")
            }
            return value
        }
        if operation == "delete" {
            guard data.removeValue(forKey: key) != nil else {
                throw SandboxError.denied("Record not found.")
            }
        } else if operation == "write" || operation == "append" {
            guard let input = arguments["text"] as? String, input.count <= 4000 else {
                throw SandboxError.denied("Input exceeds 4000 characters.")
            }
            guard data[key] != nil || data.count < 30 else {
                throw SandboxError.denied("Maximum 30 records per agent and app.")
            }
            let updated = operation == "append" ? (data[key] ?? "") + input : input
            guard updated.count <= 4000 else {
                throw SandboxError.denied("Stored record exceeds 4000 characters.")
            }
            data[key] = updated
        } else {
            throw SandboxError.denied("Unsupported operation.")
        }
        var agentRecords = state.records[agent] ?? [:]
        agentRecords[id] = data
        state.records[agent] = agentRecords
        try persist()
        return "\(app.manifest.name): \(operation) completed for \(key)"
    }
}

struct ImportedAppsView: View {
    let library: ImportedAppLibrary
    let changed: () -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var importerPresented = false
    @State private var pending: ImportedApp?
    @State private var problem = ""

    var body: some View {
        NavigationStack {
            List {
                Section {
                    Button {
                        importerPresented = true
                    } label: {
                        Label("Import app from Files", systemImage: "square.and.arrow.down")
                    }
                    Text("Apps are .aicapp or JSON manifests. They cannot execute code, launch iOS apps or access other apps' files.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Section("Installed virtual apps") {
                    if library.installed.isEmpty {
                        Text("No imported apps")
                            .foregroundStyle(.secondary)
                    }
                    ForEach(library.installed) { app in
                        VStack(alignment: .leading, spacing: 5) {
                            HStack {
                                Text(app.manifest.name).font(.headline)
                                Spacer()
                                Toggle("Enabled", isOn: Binding(
                                    get: { library.installed.first(where: { $0.id == app.id })?.enabled ?? false },
                                    set: { enabled in
                                        do { try library.setEnabled(enabled, id: app.id); changed() }
                                        catch { problem = error.localizedDescription }
                                    }
                                )).labelsHidden()
                            }
                            Text(app.manifest.description).font(.caption)
                                .foregroundStyle(.secondary)
                            Text(app.manifest.actions.map { $0.title }.joined(separator: " • "))
                                .font(.caption2).foregroundStyle(.secondary)
                        }
                        .swipeActions {
                            Button("Delete", role: .destructive) {
                                do { try library.remove(id: app.id); changed() }
                                catch { problem = error.localizedDescription }
                            }
                        }
                    }
                }
                if !problem.isEmpty {
                    Text(problem).foregroundStyle(.red)
                }
            }
            .navigationTitle("Sandbox Apps")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { dismiss() }
                }
            }
            .fileImporter(
                isPresented: $importerPresented,
                allowedContentTypes: [.json, .data],
                allowsMultipleSelection: false
            ) { result in
                do {
                    guard let url = try result.get().first else { return }
                    pending = try library.preview(url: url)
                } catch {
                    problem = error.localizedDescription
                }
            }
            .sheet(item: $pending) { app in
                NavigationStack {
                    List {
                        Section("App") {
                            Text(app.name).font(.headline)
                            Text(app.description)
                        }
                        Section("Allowed virtual operations") {
                            ForEach(app.actions) { action in
                                VStack(alignment: .leading) {
                                    Text(action.title).font(.headline)
                                    Text(action.description).font(.caption)
                                    Text(action.operation).font(.caption2).foregroundStyle(.secondary)
                                }
                            }
                        }
                        Section {
                            Text("All actions operate only on virtual records stored inside AI Controller. The SLM receives text results; it cannot execute imported code.")
                                .font(.caption)
                        }
                    }
                    .navigationTitle("Review Import")
                    .toolbar {
                        ToolbarItem(placement: .cancellationAction) {
                            Button("Cancel") { pending = nil }
                        }
                        ToolbarItem(placement: .confirmationAction) {
                            Button("Install") {
                                do {
                                    try library.install(app)
                                    pending = nil
                                    changed()
                                } catch {
                                    problem = error.localizedDescription
                                    pending = nil
                                }
                            }
                        }
                    }
                }
            }
        }
    }
}

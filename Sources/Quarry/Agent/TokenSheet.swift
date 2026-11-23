import AppKit
import QuarryKit
import SwiftUI

/// What the token sheet edits (S-064): a new token, or an existing one's name and access.
@MainActor @Observable
final class TokenDraft: Identifiable {
    let id = UUID()
    /// nil for New Token…
    let token: AgentToken?
    var name: String
    var access: AgentAccess
    /// After Create Token: the value, shown this once.
    var createdValue: String?

    init(token: AgentToken?) {
        self.token = token
        name = token?.name ?? ""
        access = token?.access ?? .readOnly
    }

    var isAutomatic: Bool { token?.automatic == true }
    var trimmedName: String { name.trimmingCharacters(in: .whitespaces) }
    var canSave: Bool { isAutomatic || !trimmedName.isEmpty }
}

/// New Token… and Edit…: name, permission and connections; after creating, the value once with Copy.
struct TokenSheet: View {
    @Environment(AppModel.self) private var model
    @Bindable var draft: TokenDraft
    let close: () -> Void
    @State private var copied = false

    var body: some View {
        VStack(alignment: .leading, spacing: Space.lg) {
            Text(title)
                .font(.headline)
                .accessibilityAddTraits(.isHeader)
                .gridProbe("title", area: "token-sheet")
            if let value = draft.createdValue {
                created(value)
            } else {
                editor
            }
        }
        .padding(Space.margin)
        .frame(width: Layout.tokenSheetWidth)
        .gridArea("token-sheet")
        .noInitialFocus()
    }

    private var title: String {
        if draft.createdValue != nil { return "Token “\(draft.trimmedName)” Created" }
        if draft.isAutomatic { return "Automatic Token" }
        return draft.token == nil ? "New Token" : "Edit Token"
    }

    // MARK: Editing

    private var editor: some View {
        VStack(alignment: .leading, spacing: Space.lg) {
            Form {
                if draft.isAutomatic {
                    LabeledContent("Used by", value: "Stdio agents (Quarry mcp)")
                } else {
                    TextField("Name", text: $draft.name, prompt: Text("Claude Code on this Mac"))
                        .help("A name that says which agent uses it")
                }
                Picker("Permission", selection: $draft.access.permission) {
                    ForEach(AgentAccess.Permission.allCases, id: \.self) { Text($0.title).tag($0) }
                }
                .help("Read Only: reads only. Read & Write: write_query and kill_process too. Custom: choose for each connection.")
                if draft.access.permission == .custom {
                    customList
                } else {
                    Picker("Connections", selection: $draft.access.allConnections) {
                        Text("All Connections").tag(true)
                        Text("Chosen Connections").tag(false)
                    }
                    .pickerStyle(.radioGroup)
                    .help("Agents with this token see only these connections in list_connections")
                    if !draft.access.allConnections { chosenList }
                }
            }
            .formStyle(.grouped)
            .fitsContent(max: Layout.tokenFormMaxHeight)
            HStack(spacing: Space.sm) {
                Spacer()
                Button("Cancel", action: close).keyboardShortcut(.cancelAction)
                Button(draft.token == nil ? "Create Token" : "Save", action: save)
                    .keyboardShortcut(.defaultAction)
                    .disabled(!draft.canSave)
            }
            .gridProbe("buttons", area: "token-sheet")
        }
    }

    private var groups: [ConnectionGroup] { model.connectionGroups() }
    private var connections: [SavedConnection] { model.savedConnections() }

    @ViewBuilder private var chosenList: some View {
        ForEach(groups, id: \.uid) { group in
            Toggle(isOn: member(group.uid, in: \.groups)) {
                Label(group.name, systemImage: "folder")
            }
            .help("Every connection in \(group.name), including ones added later")
        }
        ForEach(connections, id: \.uid) { connection in
            Toggle(isOn: member(connection.uid, in: \.connections)) {
                Text(connection.displayName)
                Text(connection.summary)
            }
        }
    }

    @ViewBuilder private var customList: some View {
        if connections.isEmpty {
            Text("No saved connections yet.").foregroundStyle(.secondary)
        }
        ForEach(connections, id: \.uid) { connection in
            Picker(selection: level(connection.uid)) {
                ForEach(AgentAccess.Level.allCases, id: \.self) { Text($0.title).tag($0) }
            } label: {
                Text(connection.displayName)
                Text(connection.summary)
            }
        }
    }

    private func member(_ uid: UUID, in path: WritableKeyPath<AgentAccess, Set<UUID>>) -> Binding<Bool> {
        Binding(get: { draft.access[keyPath: path].contains(uid) },
                set: { on in
                    if on { draft.access[keyPath: path].insert(uid) } else { draft.access[keyPath: path].remove(uid) }
                })
    }

    private func level(_ uid: UUID) -> Binding<AgentAccess.Level> {
        Binding(get: { draft.access.custom[uid] ?? .none },
                set: { draft.access.custom[uid] = $0 == .none ? nil : $0 })
    }

    private func save() {
        guard draft.canSave else { return }
        if let token = draft.token {
            model.updateAgentToken(token, name: draft.trimmedName, access: draft.access)
            close()
        } else {
            draft.createdValue = model.createAgentToken(name: draft.trimmedName, access: draft.access).value
        }
    }

    // MARK: Created

    private func created(_ value: String) -> some View {
        VStack(alignment: .leading, spacing: Space.md) {
            Text("Copy it now. Quarry keeps only a fingerprint, so it can’t show it again.")
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: Space.sm) {
                Text(value)
                    .font(.system(.body, design: .monospaced))
                    .textSelection(.enabled)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .accessibilityLabel("Token value")
                Spacer(minLength: Space.sm)
                Button(copied ? "Copied" : "Copy") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(value, forType: .string)
                    copied = true
                }
                .help("Copy the token; HTTP agents send it as Authorization: Bearer <token>")
            }
            HStack(spacing: Space.sm) {
                Spacer()
                Button("Done", action: close).keyboardShortcut(.defaultAction)
            }
            .gridProbe("buttons", area: "token-sheet")
        }
    }
}

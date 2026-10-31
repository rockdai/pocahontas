import PocahontasKit
import SwiftUI
import UniformTypeIdentifiers

struct ConnectionLibraryView: View {
  @Bindable var library: ConnectionLibrary
  let onConnect: (ConnectionBinding, SSHAuthentication) -> Void
  @Environment(\.dismiss) private var dismiss
  @State private var adding = false
  @State private var editing: StoredRecord?
  @State private var connecting: StoredRecord?
  @State private var reviewing: StoredRecord?
  @State private var deleting: StoredRecord?
  @State private var settings = false
  @State private var identities = false

  var body: some View {
    NavigationStack {
      List {
        Section {
          Button {
            settings = true
          } label: {
            HStack(spacing: 12) {
              Image(systemName: library.syncEnabled ? "icloud" : "internaldrive")
                .font(.title2).foregroundStyle(AppAppearance.accent)
              VStack(alignment: .leading, spacing: 4) {
                Text(library.scope == "local" ? "On this device" : "iCloud connections").font(
                  .headline)
                Text(library.syncStatus).font(.caption).foregroundStyle(.secondary)
              }
              Spacer()
              Image(systemName: "chevron.right").font(.caption).foregroundStyle(.secondary)
            }.padding(.vertical, 6).contentShape(Rectangle())
          }.buttonStyle(.plain).accessibilityIdentifier("library.sync")
        }
        Section("Connections") {
          if library.hosts.isEmpty {
            ContentUnavailableView(
              "Your connections, together", systemImage: "terminal",
              description: Text(
                "Save a development machine here, then pick it up on your other Apple devices with iCloud."
              )
            )
            .padding(.vertical, 12)
            Button("Add Connection", systemImage: "plus") { adding = true }
              .accessibilityIdentifier("library.add.empty")
          }
          ForEach(library.hosts) { row in
            HStack {
              Button {
                connecting = row
              } label: {
                VStack(alignment: .leading, spacing: 5) {
                  Text(row.record?.name ?? "Connection").font(.headline)
                  if let binding = row.record?.binding {
                    Text("\(binding.username)@\(binding.host):\(String(binding.port))")
                      .font(.system(.caption, design: .monospaced)).foregroundStyle(.secondary)
                  }
                  Text(library.credentialStatus(for: row)).font(.caption)
                    .foregroundStyle(
                      row.conflict == nil ? AppAppearance.inactiveKey : AppAppearance.warning)
                }.frame(maxWidth: .infinity, alignment: .leading).padding(.vertical, 6)
                  .contentShape(Rectangle())
              }.buttonStyle(.plain).accessibilityIdentifier("library.host.\(row.id)")
              if row.conflict != nil {
                Button("Review") { reviewing = row }
              }
              Menu {
                Button("Edit", systemImage: "pencil") { editing = row }.disabled(
                  row.conflict != nil)
                Button("Delete Connection", systemImage: "trash", role: .destructive) {
                  deleting = row
                }
              } label: {
                Image(systemName: "ellipsis.circle").font(.title3)
              }
              .menuStyle(.borderlessButton).fixedSize().accessibilityLabel("Connection actions")
            }
          }
        }
        Section {
          Button {
            identities = true
          } label: {
            Label("SSH Identities (\(library.identities.count))", systemImage: "key")
          }.accessibilityIdentifier("library.identities")
          if library.unknownCount > 0 {
            Label(
              "\(library.unknownCount) records need a newer app version. Their data is preserved.",
              systemImage: "arrow.up.circle"
            )
            .font(.caption)
          }
        } footer: {
          Text(
            "Server trust stays on each device. Terminal output and active sessions are never synced."
          )
        }
      }
      .navigationTitle("Saved Connections")
      .toolbar {
        ToolbarItem(placement: .cancellationAction) { Button("Done") { dismiss() } }
        ToolbarItem(placement: .primaryAction) {
          Button("Add Connection", systemImage: "plus") { adding = true }.accessibilityIdentifier(
            "library.add")
        }
      }
      .sheet(isPresented: $adding) { HostEditor(library: library, existing: nil) }
      .sheet(item: $editing) { HostEditor(library: library, existing: $0.record) }
      .sheet(item: $connecting) { row in
        SavedConnectionPrompt(library: library, id: row.id) { binding, auth in
          connecting = nil
          dismiss()
          onConnect(binding, auth)
        }
      }
      .sheet(item: $reviewing) { ConflictReview(library: library, id: $0.id) }
      .sheet(isPresented: $settings) { CloudSettingsView(library: library) }
      .sheet(isPresented: $identities) { IdentityLibraryView(library: library) }
      .confirmationDialog(
        "Delete this connection?",
        isPresented: Binding(
          get: { deleting != nil }, set: { if !$0 { deleting = nil } }), titleVisibility: .visible
      ) {
        Button("Delete Connection", role: .destructive) {
          if let deleting { perform { try library.delete(deleting.id) } }
          deleting = nil
        }
      } message: {
        Text(
          library.scope == "local"
            ? "The saved connection will be removed from this device. SSH keys are retained."
            : "This deletion will sync to your other devices. SSH keys are retained.")
      }
      .libraryError(library)
    }.librarySheetSize()
      .id(library.accountGeneration)
      .onChange(of: library.accountGeneration) { _, _ in
        adding = false
        editing = nil
        connecting = nil
        reviewing = nil
        deleting = nil
        settings = false
        identities = false
      }
  }
  private func perform(_ action: () throws -> Void) {
    do { try action() } catch { library.errorMessage = error.localizedDescription }
  }
}

private struct HostEditor: View {
  let library: ConnectionLibrary
  let existing: LibraryRecord?
  @Environment(\.dismiss) private var dismiss
  @State private var name = ""
  @State private var host = ""
  @State private var port = "22"
  @State private var username = ""
  @State private var tags = ""
  @State private var identityID: UUID?
  @State private var password = ""
  @State private var savePassword = false
  @State private var sharePassword = false
  @State private var useLocalOverride = false
  @State private var error: String?

  var body: some View {
    NavigationStack {
      Form {
        Section("Connection") {
          TextField("Name", text: $name).accessibilityIdentifier("saved.name")
          TextField("Hostname", text: $host).accessibilityIdentifier("saved.host")
          TextField("Port", text: $port).accessibilityIdentifier("saved.port")
          TextField("Username", text: $username).accessibilityIdentifier("saved.username")
          TextField("Tags, separated by commas", text: $tags)
        }
        Section {
          Picker("Authentication", selection: $identityID) {
            Text("Password").tag(UUID?.none)
            ForEach(library.identities) { row in
              Text(row.record?.name ?? "SSH key").tag(Optional(row.id))
            }
          }.accessibilityIdentifier("saved.authentication")
          if identityID == nil {
            Toggle("Save a password in Keychain", isOn: $savePassword)
              .disabled(!library.credentialStorageAvailable).accessibilityIdentifier(
                "saved.remember")
            if savePassword {
              SecureField(
                existing == nil ? "Password" : "New password (leave empty to keep)", text: $password
              )
              .accessibilityIdentifier("saved.password")
              Toggle("Sync this password with iCloud Keychain", isOn: $sharePassword)
                .disabled(library.scope == "local" || !library.cloudConfigured || useLocalOverride)
            }
          }
          if existing != nil, library.scope != "local" {
            Toggle("Use this authentication only on this device", isOn: $useLocalOverride)
          }
        } header: {
          Text("Authentication")
        } footer: {
          Text(
            "Passwords and private keys never enter the connection database. Credentials stay on this device unless you explicitly choose iCloud Keychain. Passphrases are asked for each connection."
          )
          if existing != nil {
            Text(
              "Changing credential storage creates a new revision. Previously shared revisions remain in iCloud Keychain."
            )
          }
        }
        if let error { Section { Text(error).foregroundStyle(AppAppearance.warning) } }
      }.formStyle(.grouped).libraryTextInput()
        .navigationTitle(existing == nil ? "Add Connection" : "Edit Connection")
        .toolbar {
          ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
          ToolbarItem(placement: .confirmationAction) {
            Button("Save") { save() }.disabled(
              name.trimmingCharacters(in: .whitespaces).isEmpty || host.isEmpty || username.isEmpty
            )
            .accessibilityIdentifier("saved.save")
          }
        }
    }.librarySheetSize().onAppear {
      guard let existing, let binding = existing.binding else { return }
      name = existing.name
      host = binding.host
      port = String(binding.port)
      username = binding.username
      tags = existing.tags.joined(separator: ", ")
      useLocalOverride = library.state.localOverrides[existing.id] != nil
      switch library.state.localOverrides[existing.id] ?? binding.authentication {
      case .identity(let id): identityID = id
      case .password(let reference):
        savePassword = reference != nil
        sharePassword = reference?.storage == .iCloud
      }
    }
  }
  private func save() {
    do {
      var auth: SavedAuthentication = .password(nil)
      if let identityID {
        auth = .identity(identityID)
      } else if savePassword {
        if !password.isEmpty {
          auth = .password(
            try library.savePassword(
              password, storage: sharePassword && !useLocalOverride ? .iCloud : .device))
        } else if let existing,
          case .password(let ref) = library.state.localOverrides[existing.id]
            ?? existing.binding?.authentication
        {
          if let ref, ref.storage != (sharePassword && !useLocalOverride ? .iCloud : .device) {
            error =
              "Enter the password again to create a new Keychain revision with this storage choice. Older revisions remain in Keychain."
            return
          }
          auth = .password(ref)
        } else {
          throw LibraryError.missingCredential
        }
      }
      let binding = try ConnectionBinding(
        host: host, port: Int(port) ?? 0, username: username,
        authentication: useLocalOverride ? existing!.binding!.authentication : auth)
      var value = existing ?? LibraryRecord(name: name, binding: binding)
      value.name = name.trimmingCharacters(in: .whitespacesAndNewlines)
      value.binding = binding
      value.tags = tags.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter
      { !$0.isEmpty }
      try library.save(value, localAuthentication: useLocalOverride ? auth : nil)
      password = ""
      dismiss()
    } catch { self.error = error.localizedDescription }
  }
}

private struct SavedConnectionPrompt: View {
  let library: ConnectionLibrary
  let id: UUID
  let onConnect: (ConnectionBinding, SSHAuthentication) -> Void
  @Environment(\.dismiss) private var dismiss
  @State private var password = ""
  @State private var passphrase = ""
  @State private var usePassword = false
  @State private var busy = false
  @State private var error: String?
  private var row: StoredRecord? { library.state.records[id] }
  private var isPassword: Bool {
    if case .password = library.state.localOverrides[id] ?? row?.record?.binding?.authentication {
      return true
    }
    return false
  }
  var body: some View {
    NavigationStack {
      Form {
        Section {
          if let binding = row?.record?.binding {
            LabeledContent("Server", value: binding.host)
            LabeledContent("User", value: binding.username)
            LabeledContent("Port", value: String(binding.port))
          }
          Text(row.map { library.credentialStatus(for: $0) } ?? "Connection unavailable")
            .font(.callout).foregroundStyle(.secondary)
        }
        Section {
          if isPassword {
            Toggle("Enter a password for this connection", isOn: $usePassword)
            if usePassword {
              SecureField("Password", text: $password).accessibilityIdentifier(
                "saved.connect.password")
            }
          } else {
            SecureField("Key passphrase (if encrypted)", text: $passphrase)
          }
        } footer: {
          Text("These inputs are used once and are not saved or synced.")
        }
        if let error { Section { Text(error).foregroundStyle(AppAppearance.warning) } }
      }.formStyle(.grouped)
        .navigationTitle(row?.record?.name ?? "Connect")
        .toolbar {
          ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
          ToolbarItem(placement: .confirmationAction) {
            Button(busy ? "Unlocking…" : "Connect") {
              busy = true
              Task {
                do {
                  let (binding, auth) = try await library.authentication(
                    for: id,
                    passphrase: passphrase, oneTimePassword: usePassword ? password : nil)
                  password = ""
                  passphrase = ""
                  onConnect(binding, auth)
                } catch { self.error = error.localizedDescription }
                busy = false
              }
            }.disabled(busy || row?.conflict != nil || (usePassword && password.isEmpty))
              .accessibilityIdentifier("saved.connect")
          }
        }
    }.librarySheetSize().onAppear {
      if case .password(nil) = library.state.localOverrides[id]
        ?? row?.record?.binding?.authentication
      {
        usePassword = true
      }
    }
  }
}

private struct IdentityLibraryView: View {
  @Bindable var library: ConnectionLibrary
  @Environment(\.dismiss) private var dismiss
  @State private var adding = false
  @State private var editing: StoredRecord?
  @State private var deleting: StoredRecord?
  @State private var reviewing: StoredRecord?
  var body: some View {
    NavigationStack {
      List {
        if library.identities.isEmpty {
          ContentUnavailableView(
            "Your SSH identities", systemImage: "key",
            description: Text(
              "Import an Ed25519 key once and reuse it across your saved connections."))
          Button("Import SSH Key", systemImage: "plus") { adding = true }
        }
        ForEach(library.identities) { row in
          VStack(alignment: .leading, spacing: 8) {
            Text(row.record?.name ?? "SSH key").font(.headline)
            Text(row.record?.identity?.fingerprint ?? "").font(
              .system(.caption, design: .monospaced)
            ).textSelection(.enabled)
            Text(library.credentialStatus(for: row)).font(.caption).foregroundStyle(.secondary)
            HStack {
              if row.conflict != nil {
                Button("Review Changes") { reviewing = row }
              } else {
                Button("Replace Key") { editing = row }
              }
              Spacer()
              Button("Delete Identity", role: .destructive) { deleting = row }
            }
          }.padding(.vertical, 6)
        }
        Section {
          Text(
            "Import defaults to this device. iCloud Keychain sharing is a separate choice for each key. Encrypted keys require their passphrase each time you connect."
          )
          .font(.caption).foregroundStyle(.secondary)
        }
      }
      .navigationTitle("SSH Identities")
      .toolbar {
        ToolbarItem(placement: .cancellationAction) { Button("Done") { dismiss() } }
        ToolbarItem(placement: .primaryAction) {
          Button("Import SSH Key", systemImage: "plus") { adding = true }
        }
      }
      .sheet(isPresented: $adding) { IdentityEditor(library: library, existing: nil) }
      .sheet(item: $editing) { IdentityEditor(library: library, existing: $0.record) }
      .sheet(item: $reviewing) { ConflictReview(library: library, id: $0.id) }
      .confirmationDialog(
        "Delete identity?",
        isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } }),
        titleVisibility: .visible
      ) {
        Button("Delete Identity", role: .destructive) {
          do {
            if let deleting { try library.delete(deleting.id) }
            deleting = nil
          } catch { library.errorMessage = error.localizedDescription }
        }
      } message: {
        let count = library.hosts.filter {
          let selected = deleting.map { SavedAuthentication.identity($0.id) }
          return $0.record?.binding?.authentication == selected
            || library.state.localOverrides[$0.id] == selected
        }.count
        Text(
          "\(count) saved connections use this identity and will need another credential. The identity deletion syncs with the library. Keychain revisions are retained; this does not revoke the key on your servers."
        )
      }
      .libraryError(library)
    }.librarySheetSize()
  }
}

private struct IdentityEditor: View {
  let library: ConnectionLibrary
  let existing: LibraryRecord?
  @Environment(\.dismiss) private var dismiss
  @State private var name = ""
  @State private var key = ""
  @State private var passphrase = ""
  @State private var sharing = false
  @State private var importing = false
  @State private var busy = false
  @State private var error: String?
  var body: some View {
    NavigationStack {
      Form {
        Section("Identity") {
          TextField("Name", text: $name).accessibilityIdentifier("identity.name")
        }
        Section("OpenSSH Ed25519 private key") {
          TextEditor(text: $key).font(.system(.caption, design: .monospaced)).frame(height: 140)
            .accessibilityLabel("Private key").accessibilityIdentifier("identity.key")
          Button("Import Key File", systemImage: "doc.badge.plus") { importing = true }
          SecureField("Passphrase (if encrypted)", text: $passphrase)
        }
        Section {
          Toggle("Sync this key with iCloud Keychain", isOn: $sharing)
            .disabled(library.scope == "local" || !library.cloudConfigured)
        } footer: {
          Text(
            "The private key goes into Keychain. Only its name, public key and fingerprint go into the connection library. The passphrase is used to validate the key and is not saved. Replacing a key creates a new revision; older Keychain revisions are retained."
          )
        }
        if !library.credentialStorageAvailable {
          Text(LibraryError.cloudNotConfigured.localizedDescription).font(.caption)
        }
        if let error { Text(error).foregroundStyle(AppAppearance.warning) }
      }.formStyle(.grouped).libraryTextInput()
        .navigationTitle(existing == nil ? "Import SSH Key" : "Replace SSH Key")
        .toolbar {
          ToolbarItem(placement: .cancellationAction) {
            Button("Cancel") { dismiss() }.disabled(busy)
          }
          ToolbarItem(placement: .confirmationAction) {
            Button(busy ? "Validating…" : "Save Key") {
              busy = true
              Task {
                do {
                  try await library.importIdentity(
                    name: name, privateKey: key, passphrase: passphrase,
                    storage: sharing ? .iCloud : .device, replacing: existing?.id)
                  key = ""
                  passphrase = ""
                  dismiss()
                } catch { self.error = error.localizedDescription }
                busy = false
              }
            }.disabled(busy || key.isEmpty || name.isEmpty || !library.credentialStorageAvailable)
          }
        }
        .fileImporter(isPresented: $importing, allowedContentTypes: [.data, .text]) { result in
          do {
            let file = try result.get()
            let access = file.startAccessingSecurityScopedResource()
            defer { if access { file.stopAccessingSecurityScopedResource() } }
            guard (try file.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0) <= 65536 else {
              throw CocoaError(.fileReadTooLarge)
            }
            key = try String(contentsOf: file, encoding: .utf8)
          } catch { self.error = "Choose an OpenSSH Ed25519 key smaller than 64 KB." }
        }
    }.librarySheetSize().interactiveDismissDisabled(busy).onAppear { name = existing?.name ?? "" }
  }
}

private struct CloudSettingsView: View {
  @Bindable var library: ConnectionLibrary
  @Environment(\.dismiss) private var dismiss
  @State private var recover = false
  @State private var copyLocal = false
  var body: some View {
    NavigationStack {
      Form {
        Section {
          Label("Your Apple devices, one connection library", systemImage: "icloud").font(.headline)
          Text(library.syncStatus).accessibilityIdentifier("sync.status")
          if let lastSync = library.lastSync {
            LabeledContent("Last sync") { Text(lastSync, style: .relative) }
          }
          if library.scope != "local" {
            LabeledContent("Waiting to upload", value: String(library.pendingCount))
            LabeledContent("Conflicts", value: String(library.conflictCount))
          }
        }
        Section("Connection sync") {
          if !library.cloudConfigured {
            Text(LibraryError.cloudNotConfigured.localizedDescription).font(.callout)
              .foregroundStyle(.secondary)
          } else if library.syncEnabled {
            Button("Sync Now", systemImage: "arrow.triangle.2.circlepath") {
              Task { await library.syncNow() }
            }
            .disabled(library.isSyncing)
            Button("Pause Connection Sync") { Task { await library.disableSync() } }
          } else {
            Button("Use iCloud Connections", systemImage: "icloud") {
              run { try await library.enableSync() }
            }
          }
          if library.scope != "local" {
            Button("Copy Local Connections to iCloud") { copyLocal = true }
            Button("Switch to Local Library") { run { try await library.selectLocalLibrary() } }
          }
          Button("Check iCloud Account") { Task { await library.checkAccount() } }.disabled(
            !library.cloudConfigured)
        }
        Section("Credentials") {
          Text(
            "Connection sync and iCloud Keychain are separate. Pausing connection sync does not stop iCloud Keychain from sharing credentials you already chose to sync."
          )
          Text(
            "New passwords and SSH keys default to this device. Missing credentials on another device are shown explicitly. Server trust is always confirmed separately on each device."
          )
        }.font(.callout).foregroundStyle(.secondary)
        if let reason = library.state.recoveryReason {
          Section("Recovery") {
            Text(reason)
            Button("Reload iCloud Library", role: .destructive) { recover = true }
          }
        }
        Section {
          Text(
            "Local changes work offline. Concurrent edits are reviewed before a new connection can use them. Metadata uses encrypted CloudKit fields; iCloud Keychain protects your shared secrets. Use the same Apple Account on each device."
          )
          .font(.caption).foregroundStyle(.secondary)
        }
      }.formStyle(.grouped)
        .navigationTitle("iCloud Sync")
        .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Done") { dismiss() } } }
        .confirmationDialog(
          "Copy local connections?", isPresented: $copyLocal, titleVisibility: .visible
        ) {
          Button("Copy to iCloud") { run { try library.copyLocalConnectionsToCloud() } }
        } message: {
          Text(
            "Creates new copies in this Apple Account. Passwords and keys remain on this device unless you separately choose to share them. Copying again creates another set."
          )
        }
        .confirmationDialog("Reload from iCloud?", isPresented: $recover, titleVisibility: .visible)
      {
        Button("Reload", role: .destructive) { run { try await library.reloadFromCloud() } }
      } message: {
        Text(
          "The current local snapshot will be archived for recovery. Unsynced edits will not be uploaded. The active library will be replaced by a fresh download."
        )
      }
        .libraryError(library)
    }.librarySheetSize()
  }
  private func run(_ action: @escaping @MainActor () async throws -> Void) {
    Task { do { try await action() } catch { library.errorMessage = error.localizedDescription } }
  }
}

private struct ConflictReview: View {
  let library: ConnectionLibrary
  let id: UUID
  @Environment(\.dismiss) private var dismiss
  var body: some View {
    NavigationStack {
      Form {
        if let row = library.state.records[id], let conflict = row.conflict, let record = row.record
        {
          Section {
            Text(
              "Both versions were kept. Review these changes before connecting: \(conflict.fields.joined(separator: ", "))."
            )
          }
          Section("This device") { details(record) }
          Section("iCloud") { details(conflict.remote) }
          Section {
            Button("Keep This Device’s Changes") { resolve(false) }
            Button("Use iCloud Changes") { resolve(true) }
          } footer: {
            Text("Edits to other, non-conflicting fields are kept in either case.")
          }
        }
      }.formStyle(.grouped).navigationTitle("Review Changes")
        .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } } }
    }.librarySheetSize()
  }
  @ViewBuilder private func details(_ record: LibraryRecord) -> some View {
    LabeledContent("Name", value: record.name)
    LabeledContent("Tags", value: record.tags.joined(separator: ", "))
    if let binding = record.binding {
      LabeledContent("Server", value: "\(binding.username)@\(binding.host):\(binding.port)")
      switch binding.authentication {
      case .password(let ref):
        LabeledContent("Authentication", value: ref == nil ? "Ask for password" : "Saved password")
        if let ref { Text("Credential revision: \(ref.revision)").font(.caption) }
      case .identity(let id):
        LabeledContent(
          "SSH identity", value: library.state.records[id]?.record?.name ?? id.uuidString)
      }
    }
    if let identity = record.identity {
      Text(identity.fingerprint).font(.system(.caption, design: .monospaced))
    }
  }
  private func resolve(_ remote: Bool) {
    do {
      try library.resolve(id, useRemote: remote)
      dismiss()
    } catch { library.errorMessage = error.localizedDescription }
  }
}

extension View {
  fileprivate func libraryTextInput() -> some View {
    #if os(iOS)
      self.autocorrectionDisabled().textInputAutocapitalization(.never)
    #else
      self.autocorrectionDisabled()
    #endif
  }
  fileprivate func librarySheetSize() -> some View {
    #if os(macOS)
      self.frame(width: 620, height: 640)
    #else
      self.presentationDetents([.large])
    #endif
  }
  fileprivate func libraryError(_ library: ConnectionLibrary) -> some View {
    alert(
      "Connection Library",
      isPresented: Binding(
        get: { library.errorMessage != nil },
        set: { if !$0 { library.errorMessage = nil } })
    ) {
      Button("OK") { library.errorMessage = nil }
    } message: {
      Text(library.errorMessage ?? "")
    }
  }
}

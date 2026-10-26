import PocahontasKit
import SwiftUI
import UniformTypeIdentifiers

@main
struct PocahontasApp: App {
  @State private var terminal = TerminalController()
  @Environment(\.scenePhase) private var scenePhase
  var body: some Scene {
    WindowGroup {
      ConnectionView(terminal: terminal)
        .preferredColorScheme(.light)
        .tint(AppAppearance.accent)
        .onChange(of: scenePhase) { _, phase in
          GhosttyEngine.shared.setBackgrounded(phase != .active)
          if phase == .background { terminal.suspend() }
        }
    }
  }
}

struct ConnectionView: View {
  @Bindable var terminal: TerminalController
  @Environment(\.scenePhase) private var scenePhase
  @AppStorage("quickConnect.host") private var host = ""
  @AppStorage("quickConnect.port") private var port = "22"
  @AppStorage("quickConnect.username") private var username = ""
  @State private var useKey = false
  @State private var password = ""
  @State private var privateKey = ""
  @State private var passphrase = ""
  @State private var importing = false
  @State private var importError: String?

  var body: some View {
    NavigationStack {
      Form {
        Section {
          VStack(alignment: .leading, spacing: 8) {
            Label("Your agents, within reach.", systemImage: "terminal")
              .font(.title2.weight(.semibold))
            Text(
              "Connect to your development machine. Use tmux on the server to keep work running when you leave."
            )
            .font(.subheadline).foregroundStyle(.secondary)
          }.padding(.vertical, 8)
        }
        Section("Server") {
          TextField("Hostname or IP address", text: $host).accessibilityIdentifier(
            "connection.host"
          )
          .textContentType(.URL).keyboardType(.URL)
          TextField("Port", text: $port).keyboardType(.numberPad).accessibilityIdentifier(
            "connection.port")
          TextField("Username", text: $username).textContentType(.username).accessibilityIdentifier(
            "connection.username")
        }.textInputAutocapitalization(.never).autocorrectionDisabled()
        Section {
          Picker("Authentication", selection: $useKey) {
            Text("Password").tag(false)
            Text("SSH key").tag(true)
          }.pickerStyle(.segmented)
          if useKey {
            TextEditor(text: $privateKey).frame(minHeight: 100)
              .font(.system(.caption, design: .monospaced))
              .accessibilityLabel("OpenSSH private key").accessibilityIdentifier("connection.key")
            Button("Import Ed25519 key from Files", systemImage: "doc.badge.plus") {
              importing = true
            }
            SecureField("Key passphrase (if encrypted)", text: $passphrase)
          } else {
            SecureField("Password", text: $password).textContentType(.password)
              .accessibilityIdentifier("connection.password")
          }
        } header: {
          Text("Authentication")
        } footer: {
          Text(
            "Passwords, private keys and passphrases stay in memory for this connection. This preview saves only the server address and username on this device."
          )
        }.textInputAutocapitalization(.never).autocorrectionDisabled()
        Section {
          Button {
            let authentication: SSHAuthentication =
              useKey
              ? .ed25519(openSSH: privateKey, passphrase: passphrase) : .password(password)
            password = ""
            privateKey = ""
            passphrase = ""
            Task {
              await terminal.connect(
                host: host, port: port, username: username, authentication: authentication)
            }
          } label: {
            HStack {
              Spacer()
              Label("Connect", systemImage: "arrow.up.right")
              Spacer()
            }
          }.accessibilityIdentifier("connection.connect")
            .disabled(
              host.isEmpty || username.isEmpty || (useKey ? privateKey.isEmpty : password.isEmpty))
        }
      }
      .navigationTitle("pocahontas")
      .overlay {
        if scenePhase != .active {
          AppAppearance.background
            .overlay(Label("pocahontas", systemImage: "terminal").font(.title2)).ignoresSafeArea()
        }
      }
      .fullScreenCover(isPresented: $terminal.isPresented, onDismiss: { terminal.disconnect() }) {
        TerminalScreen(terminal: terminal)
      }
      .fileImporter(isPresented: $importing, allowedContentTypes: [.data, .text]) { result in
        do {
          let file = try result.get()
          let access = file.startAccessingSecurityScopedResource()
          defer { if access { file.stopAccessingSecurityScopedResource() } }
          guard (try file.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0) <= 65536 else {
            throw CocoaError(.fileReadTooLarge)
          }
          privateKey = try String(contentsOf: file, encoding: .utf8)
        } catch {
          importError =
            "Unable to read this key file. Choose an OpenSSH Ed25519 private key smaller than 64 KB."
        }
      }
      .alert(
        "Import failed",
        isPresented: Binding(get: { importError != nil }, set: { if !$0 { importError = nil } })
      ) {
        Button("OK") { importError = nil }
      } message: {
        Text(importError ?? "")
      }
    }
  }
}

struct TerminalScreen: View {
  @Bindable var terminal: TerminalController
  @Environment(\.scenePhase) private var scenePhase
  var body: some View {
    NavigationStack {
      VStack(spacing: 0) {
        HStack(spacing: 8) {
          Circle().fill(terminal.state == .ready ? AppAppearance.accent : AppAppearance.warning).frame(
            width: 7, height: 7)
          Text(status).font(.caption).accessibilityIdentifier("terminal.status")
          Spacer()
        }.padding(.horizontal).padding(.vertical, 10)
        if case .failed(let message) = terminal.state {
          Text(message).font(.callout).foregroundStyle(AppAppearance.warning).padding()
            .accessibilityIdentifier("terminal.error")
        }
        TerminalHost(surface: terminal.surface)
        accessory
      }
      .background(AppAppearance.background)
      .navigationTitle(terminal.title).navigationBarTitleDisplayMode(.inline)
      .toolbar {
        ToolbarItem(placement: .topBarLeading) {
          Button("Close", systemImage: "xmark") {
            terminal.disconnect()
            terminal.isPresented = false
          }
        }
        ToolbarItem(placement: .topBarTrailing) {
          Button("Paste", systemImage: "doc.on.clipboard") {
            if let text = UIPasteboard.general.string { terminal.requestPaste(text) }
          }.disabled(terminal.state != .ready)
        }
      }
      .overlay {
        if scenePhase != .active {
          AppAppearance.background
            .overlay(Label("pocahontas", systemImage: "terminal").font(.title2)).ignoresSafeArea()
        }
      }
      .alert(
        "Trust this server?",
        isPresented: Binding(
          get: { terminal.challenge != nil }, set: { if !$0 { terminal.answerTrust(false) } })
      ) {
        Button("Cancel", role: .cancel) { terminal.answerTrust(false) }
        Button("Trust and connect") { terminal.answerTrust(true) }
      } message: {
        if let challenge = terminal.challenge {
          Text(
            "\(challenge.host)\n\n\(challenge.fingerprint)\n\nCompare this fingerprint with the server before trusting it. It will be saved on this device."
          )
        }
      }
      .sheet(
        isPresented: Binding(
          get: { terminal.pastePreview != nil }, set: { if !$0 { terminal.pastePreview = nil } })
      ) {
        NavigationStack {
          ScrollView {
            Text(terminal.pastePreview ?? "").font(.system(.body, design: .monospaced)).padding()
          }
          .navigationTitle("Paste multiple lines?")
          .toolbar {
            ToolbarItem(placement: .cancellationAction) {
              Button("Cancel") { terminal.pastePreview = nil }
            }
            ToolbarItem(placement: .confirmationAction) {
              Button("Paste") { terminal.confirmPaste() }
            }
          }
        }.presentationDetents([.medium, .large])
      }
    }
  }

  private var status: String {
    switch terminal.state {
    case .connecting: "Connecting…"
    case .ready: "Connected"
    case .disconnected: "Disconnected"
    case .failed: "Connection stopped"
    }
  }

  private var accessory: some View {
    ScrollView(.horizontal, showsIndicators: false) {
      HStack(spacing: 8) {
        key("Esc", .escape)
        key("Tab", .tab)
        Button("Ctrl") { terminal.relay.toggle(.ctrl) }
          .tint(terminal.relay.sticky.contains(.ctrl) ? AppAppearance.accent : AppAppearance.inactiveKey)
        Button("Alt") { terminal.relay.toggle(.alt) }
          .tint(terminal.relay.sticky.contains(.alt) ? AppAppearance.accent : AppAppearance.inactiveKey)
        key("↑", .up)
        key("↓", .down)
        key("←", .left)
        key("→", .right)
        key("Enter", .enter)
        Button("History ↑") { terminal.surface.scrollHistory(lines: -10) }
        Button("Keyboard", systemImage: "keyboard") { terminal.relay.toggleKeyboard() }
      }.buttonStyle(.bordered).font(.system(.callout, design: .monospaced)).padding(8)
    }.disabled(terminal.state != .ready)
  }
  private func key(_ label: String, _ key: Ghostty.Key) -> some View {
    Button(label) { terminal.relay.send(key) }
  }
}

private struct TerminalHost: UIViewRepresentable {
  let surface: TerminalSurfaceView
  func makeUIView(context: Context) -> TerminalSurfaceView { surface }
  func updateUIView(_ view: TerminalSurfaceView, context: Context) {}
}

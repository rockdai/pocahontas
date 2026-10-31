import AppKit
import PocahontasKit
import SwiftUI
import UniformTypeIdentifiers

@main
struct PocahontasMacApp: App {
  @NSApplicationDelegateAdaptor(MacApplicationDelegate.self) private var delegate
  @Environment(\.openWindow) private var openWindow

  var body: some Scene {
    WindowGroup("pocahontas", id: "connection") {
      MacConnectionWindow()
        .preferredColorScheme(.light)
        .tint(AppAppearance.accent)
    }
    .defaultSize(width: 960, height: 720)
    .commands {
      CommandGroup(replacing: .newItem) {
        Button("New Connection") { openWindow(id: "connection") }
          .keyboardShortcut("n")
      }
    }
  }
}

final class MacApplicationDelegate: NSObject, NSApplicationDelegate {
  func applicationDidFinishLaunching(_ notification: Notification) {
    NSApp.appearance = NSAppearance(named: .aqua)
  }
  func applicationDidBecomeActive(_ notification: Notification) {
    GhosttyEngine.shared.setBackgrounded(false)
  }
  func applicationDidResignActive(_ notification: Notification) {
    // Losing focus is not iOS background suspension; SSH continues in every window.
    GhosttyEngine.shared.setBackgrounded(true)
  }
}

struct MacConnectionWindow: View {
  @State private var terminal = TerminalController()

  var body: some View {
    Group {
      if terminal.isPresented {
        MacTerminalScreen(terminal: terminal)
      } else {
        MacConnectionForm(terminal: terminal)
      }
    }
    .frame(minWidth: 640, minHeight: 560)
    .background(AppAppearance.background)
    .background(WindowLifetime(onClose: { terminal.disconnect() }))
    .onReceive(
      NSWorkspace.shared.notificationCenter.publisher(for: NSWorkspace.willSleepNotification)
    ) { _ in
      terminal.suspend(
        reason:
          "Disconnected while your Mac was asleep. Connect again to resume your remote tmux session."
      )
    }
  }
}

private struct MacConnectionForm: View {
  let terminal: TerminalController
  @AppStorage("quickConnect.host") private var host = ""
  @AppStorage("quickConnect.port") private var port = "22"
  @AppStorage("quickConnect.username") private var username = ""
  @State private var password = ""
  @State private var privateKey = ""
  @State private var passphrase = ""
  @State private var useKey = false
  @State private var importing = false
  @State private var importError: String?

  var body: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: 24) {
        VStack(alignment: .leading, spacing: 10) {
          Label("Your agents, within reach.", systemImage: "terminal")
            .font(.system(size: 28, weight: .semibold))
          Text(
            "Connect to your development machine. Keep your agents running in a remote tmux session, and pick up from any of your devices."
          )
          .foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
        Form {
          Section("Server") {
            TextField("Hostname", text: $host, prompt: Text("Hostname or IP address"))
              .accessibilityIdentifier("connection.host")
            TextField("Port", text: $port).accessibilityIdentifier("connection.port")
            TextField("Username", text: $username).accessibilityIdentifier("connection.username")
          }
          Section("Authentication") {
            Picker("Method", selection: $useKey) {
              Text("Password").tag(false)
              Text("SSH key").tag(true)
            }.pickerStyle(.segmented).accessibilityIdentifier("connection.method")
            if useKey {
              VStack(alignment: .leading, spacing: 8) {
                Text("OpenSSH Ed25519 private key").font(.caption).foregroundStyle(.secondary)
                TextEditor(text: $privateKey).font(.system(.caption, design: .monospaced))
                  .frame(height: 100).border(.quaternary)
                  .accessibilityLabel("OpenSSH private key").accessibilityIdentifier(
                    "connection.key")
                Button("Import key file…", systemImage: "doc.badge.plus") { importing = true }
                  .accessibilityIdentifier("connection.import")
                SecureField("Passphrase", text: $passphrase, prompt: Text("If encrypted"))
                  .accessibilityIdentifier("connection.passphrase")
              }
            } else {
              SecureField("Password", text: $password).accessibilityIdentifier(
                "connection.password")
            }
          }
        }.formStyle(.grouped).scrollDisabled(true).fixedSize(horizontal: false, vertical: true)
        Text(
          "Passwords, private keys and passphrases stay in memory for this connection. This preview saves only the server address and username on this Mac."
        )
        .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        HStack {
          Text("⌘N opens another connection").font(.caption).foregroundStyle(.secondary)
          Spacer()
          Button("Connect", systemImage: "arrow.up.right") { connect() }
            .buttonStyle(.borderedProminent).controlSize(.large)
            .keyboardShortcut(.defaultAction)
            .accessibilityIdentifier("connection.connect")
            .disabled(
              host.isEmpty || username.isEmpty || (useKey ? privateKey.isEmpty : password.isEmpty))
        }
      }.padding(36).frame(maxWidth: 660)
        .frame(maxWidth: .infinity)
    }
    .navigationTitle("pocahontas")
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
        importError = "Choose an OpenSSH Ed25519 private key smaller than 64 KB."
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
  private func connect() {
    let authentication: SSHAuthentication =
      useKey ? .ed25519(openSSH: privateKey, passphrase: passphrase) : .password(password)
    password = ""
    privateKey = ""
    passphrase = ""
    Task {
      await terminal.connect(
        host: host, port: port, username: username, authentication: authentication)
    }
  }
}

private struct MacTerminalScreen: View {
  @Bindable var terminal: TerminalController
  var body: some View {
    VStack(spacing: 0) {
      HStack(spacing: 8) {
        Circle().fill(terminal.state == .ready ? AppAppearance.accent : AppAppearance.warning)
          .frame(width: 7, height: 7)
        Text(status).font(.callout)
          .accessibilityElement(children: .ignore).accessibilityLabel(status)
          .accessibilityIdentifier("terminal.status")
        Spacer()
        Text(terminal.title).font(.callout).foregroundStyle(.secondary)
      }.padding(14).accessibilityElement(children: .contain)
      Divider()
      if case .failed(let message) = terminal.state {
        Text(message).foregroundStyle(AppAppearance.warning).padding()
          .frame(maxWidth: .infinity, alignment: .leading)
          .accessibilityElement(children: .ignore).accessibilityLabel(message)
          .accessibilityIdentifier("terminal.error")
      }
      MacTerminalHost(surface: terminal.surface).padding(12)
      Divider()
      HStack {
        Text("⌘C Copy  ·  ⌘V Paste  ·  Option = Alt").font(.caption).foregroundStyle(.secondary)
        Spacer()
        Text("SSH · Ghostty").font(.caption).foregroundStyle(.secondary)
      }.padding(12)
    }
    .navigationTitle(terminal.title)
    .toolbar {
      ToolbarItem(placement: .navigation) {
        Button("Close Connection", systemImage: "xmark") {
          terminal.disconnect()
          terminal.isPresented = false
        }.accessibilityIdentifier("terminal.close")
      }
      ToolbarItemGroup {
        Button("Copy", systemImage: "doc.on.doc") { terminal.surface.copy(nil) }
          .accessibilityIdentifier("terminal.copy")
        Button("Paste", systemImage: "doc.on.clipboard") { terminal.surface.paste(nil) }
          .disabled(terminal.state != .ready).accessibilityIdentifier("terminal.paste")
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
          "\(challenge.host)\n\n\(challenge.fingerprint)\n\nCompare this fingerprint with the server before trusting it. It will be saved on this Mac."
        )
      }
    }
    .sheet(
      isPresented: Binding(
        get: { terminal.pastePreview != nil }, set: { if !$0 { terminal.pastePreview = nil } })
    ) {
      VStack(alignment: .leading, spacing: 16) {
        Text("Paste multiple lines?").font(.title2.weight(.semibold))
          .accessibilityElement(children: .ignore).accessibilityLabel("Paste multiple lines?")
        Text("Review these lines before sending them to the remote terminal.").foregroundStyle(
          .secondary)
        ScrollView {
          Text(terminal.pastePreview ?? "").font(.system(.body, design: .monospaced))
            .frame(maxWidth: .infinity, alignment: .leading).padding()
        }.background(Color(nsColor: .textBackgroundColor)).border(.quaternary)
        HStack {
          Spacer()
          Button("Cancel", role: .cancel) { terminal.pastePreview = nil }.keyboardShortcut(
            .cancelAction)
          Button("Paste") { terminal.confirmPaste() }.keyboardShortcut(.defaultAction)
        }
      }.padding(24).frame(width: 540, height: 320).preferredColorScheme(.light)
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
}

private struct MacTerminalHost: NSViewRepresentable {
  let surface: TerminalSurfaceView
  func makeNSView(context: Context) -> TerminalSurfaceView { surface }
  func updateNSView(_ view: TerminalSurfaceView, context: Context) {}
}

/// Each window owns a session, including when closed through the red window button.
private struct WindowLifetime: NSViewRepresentable {
  var onClose: () -> Void
  func makeNSView(context: Context) -> LifetimeView { LifetimeView(onClose: onClose) }
  func updateNSView(_ view: LifetimeView, context: Context) { view.onClose = onClose }

  final class LifetimeView: NSView {
    var onClose: () -> Void
    init(onClose: @escaping () -> Void) {
      self.onClose = onClose
      super.init(frame: .zero)
    }
    required init?(coder: NSCoder) { fatalError("Not supported") }
    override func viewDidMoveToWindow() {
      NotificationCenter.default.removeObserver(self)
      if let window {
        NotificationCenter.default.addObserver(
          self, selector: #selector(close), name: NSWindow.willCloseNotification, object: window)
      }
    }
    @objc private func close() { onClose() }
    deinit { NotificationCenter.default.removeObserver(self) }
  }
}

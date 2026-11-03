import AppKit
import PocahontasKit
import SwiftUI
import UniformTypeIdentifiers

@main
struct PocahontasMacApp: App {
  @NSApplicationDelegateAdaptor(MacApplicationDelegate.self) private var delegate
  @Environment(\.openWindow) private var openWindow

  var body: some Scene {
    WindowGroup("Pocahontas", id: "connection") {
      MacConnectionWindow()
        .preferredColorScheme(.light)
        .tint(AppAppearance.accent)
    }
    .defaultSize(width: 960, height: 720)
    .windowStyle(.hiddenTitleBar)
    .commands {
      CommandGroup(replacing: .newItem) {
        Button("New Window") { openWindow(id: "connection") }
          .keyboardShortcut("n")
      }
      SessionCommands()
    }
  }
}

private struct WorkspaceFocusKey: FocusedValueKey { typealias Value = TerminalWorkspace }
extension FocusedValues {
  fileprivate var terminalWorkspace: TerminalWorkspace? {
    get { self[WorkspaceFocusKey.self] }
    set { self[WorkspaceFocusKey.self] = newValue }
  }
}
private struct SessionCommands: Commands {
  @FocusedValue(\.terminalWorkspace) private var workspace
  var body: some Commands {
    CommandMenu("Session") {
      Button("New Session") { workspace?.showNewConnection() }.keyboardShortcut("t")
        .disabled(workspace == nil)
      Button("Next Session") { workspace?.selectNext() }.keyboardShortcut(.tab, modifiers: .control)
        .disabled(workspace?.sessions.isEmpty != false)
      Button("Previous Session") { workspace?.selectNext(backwards: true) }
        .keyboardShortcut(.tab, modifiers: [.control, .shift])
        .disabled(workspace?.sessions.isEmpty != false)
    }
  }
}

final class MacApplicationDelegate: NSObject, NSApplicationDelegate {
  func applicationDidFinishLaunching(_ notification: Notification) {
    NSApp.appearance = NSAppearance(named: .aqua)
    Task { await LibraryServices.shared.start() }
  }
  func applicationDidBecomeActive(_ notification: Notification) {
    GhosttyEngine.shared.setBackgrounded(false)
    Task {
      await LibraryServices.shared.library?.checkAccount()
      await LibraryServices.shared.library?.syncNow()
    }
  }
  func applicationDidResignActive(_ notification: Notification) {
    // Losing focus is not iOS background suspension; SSH continues in every window.
    GhosttyEngine.shared.setBackgrounded(true)
  }
}

struct MacConnectionWindow: View {
  @State private var workspace = TerminalWorkspace()

  var body: some View {
    VStack(spacing: 0) {
      SessionBar(workspace: workspace)
        .padding(.leading, 78)  // Keep the native traffic lights in the same top row.
        .contentShape(Rectangle())
        .modifier(SessionWindowDrag())
      Divider()
      if let terminal = workspace.selected {
        MacTerminalScreen(terminal: terminal)
          .id(terminal.id)
      } else {
        MacConnectionForm(workspace: workspace)
      }
    }
    .ignoresSafeArea(.container, edges: .top)
    .focusedSceneValue(\.terminalWorkspace, workspace)
    .frame(minWidth: 640, minHeight: 560)
    .background(AppAppearance.background)
    .background(
      WindowLifetime(
        onClose: { workspace.closeAll() },
        onActivate: { workspace.activateSelected() },
        onDeactivate: { workspace.deactivateSelected() })
    )
    .onChange(of: LibraryServices.shared.library?.accountGeneration) { _, _ in
      workspace.suspendAll(
        reason: "The connection library changed. Connect again using the current account.",
        allowReconnect: false)
    }
    .onReceive(
      NSWorkspace.shared.notificationCenter.publisher(for: NSWorkspace.willSleepNotification)
    ) { _ in
      workspace.suspendAll(
        reason:
          "Disconnected while your Mac was asleep. Activate this session to reconnect."
      )
    }
  }
}

private struct MacConnectionForm: View {
  let workspace: TerminalWorkspace
  @AppStorage("quickConnect.host") private var host = ""
  @AppStorage("quickConnect.port") private var port = "22"
  @AppStorage("quickConnect.username") private var username = ""
  @State private var password = ""
  @State private var privateKey = ""
  @State private var passphrase = ""
  @State private var useKey = false
  @State private var importing = false
  @State private var importError: String?
  @State private var showingLibrary = false
  @State private var pendingSavedConnection: PendingSavedConnection?

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
          "Quick Connect keeps credentials in memory until the tab closes, including for reconnecting. Use Saved Connections to save a server or manage account sync."
        )
        .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        HStack {
          Button("Saved Connections", systemImage: "rectangle.stack") { showingLibrary = true }
            .accessibilityIdentifier("library.open")
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
    .sheet(
      isPresented: $showingLibrary,
      onDismiss: {
        guard let pending = pendingSavedConnection else { return }
        pendingSavedConnection = nil
        workspace.openSaved(pending)
      }
    ) {
      if let library = LibraryServices.shared.library {
        ConnectionLibraryView(library: library) { binding, auth in
          pendingSavedConnection = PendingSavedConnection(
            binding: binding, authentication: auth,
            generation: library.accountGeneration)
          showingLibrary = false
        }
      } else {
        Text(LibraryServices.shared.startupError ?? "Library unavailable").padding()
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
    workspace.open(host: host, port: port, username: username, authentication: authentication)
  }
}

private struct MacTerminalScreen: View {
  @Bindable var terminal: TerminalController
  var body: some View {
    VStack(spacing: 0) {
      TerminalConnectionNotice(terminal: terminal)
      MacTerminalHost(surface: terminal.surface).padding(8)
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
}

private struct MacTerminalHost: NSViewRepresentable {
  let surface: TerminalSurfaceView
  func makeNSView(context: Context) -> TerminalSurfaceView { surface }
  func updateNSView(_ view: TerminalSurfaceView, context: Context) {}
}

/// Each window owns all its sessions, including when closed through the red window button.
private struct WindowLifetime: NSViewRepresentable {
  var onClose: () -> Void
  var onActivate: () -> Void
  var onDeactivate: () -> Void
  func makeNSView(context: Context) -> LifetimeView {
    LifetimeView(onClose: onClose, onActivate: onActivate, onDeactivate: onDeactivate)
  }
  func updateNSView(_ view: LifetimeView, context: Context) {
    view.onClose = onClose
    view.onActivate = onActivate
    view.onDeactivate = onDeactivate
  }

  final class LifetimeView: NSView {
    var onClose: () -> Void
    var onActivate: () -> Void
    var onDeactivate: () -> Void
    init(
      onClose: @escaping () -> Void, onActivate: @escaping () -> Void,
      onDeactivate: @escaping () -> Void
    ) {
      self.onClose = onClose
      self.onActivate = onActivate
      self.onDeactivate = onDeactivate
      super.init(frame: .zero)
    }
    required init?(coder: NSCoder) { fatalError("Not supported") }
    override func viewDidMoveToWindow() {
      NotificationCenter.default.removeObserver(self)
      NSWorkspace.shared.notificationCenter.removeObserver(self)
      if let window {
        // A toolbar opts into Tahoe's larger window corners. This window uses the
        // native titlebar-only shape, with content extending behind its hidden title.
        window.toolbar = nil
        window.titlebarAppearsTransparent = true
        window.isMovableByWindowBackground = true
        window.titlebarSeparatorStyle = .none
        window.tabbingMode = .disallowed
        NSWorkspace.shared.notificationCenter.addObserver(
          self, selector: #selector(activate), name: NSWorkspace.didWakeNotification, object: nil)
        NotificationCenter.default.addObserver(
          self, selector: #selector(activate), name: NSApplication.didBecomeActiveNotification,
          object: nil)
        NotificationCenter.default.addObserver(
          self, selector: #selector(activate), name: NSWindow.didBecomeKeyNotification,
          object: window)
        NotificationCenter.default.addObserver(
          self, selector: #selector(deactivate), name: NSWindow.didResignKeyNotification,
          object: window)
        NotificationCenter.default.addObserver(
          self, selector: #selector(close), name: NSWindow.willCloseNotification, object: window)
      }
    }
    @objc private func close() { onClose() }
    @objc private func activate() { if window?.isKeyWindow == true { onActivate() } }
    @objc private func deactivate() { onDeactivate() }
    deinit {
      NotificationCenter.default.removeObserver(self)
      NSWorkspace.shared.notificationCenter.removeObserver(self)
    }
  }
}

private struct SessionWindowDrag: ViewModifier {
  @ViewBuilder func body(content: Content) -> some View {
    if #available(macOS 15, *) {
      content.simultaneousGesture(WindowDragGesture())
    } else {
      content
    }
  }
}

/// A dedicated drag area for macOS 14, which predates WindowDragGesture.
struct WindowDragArea: NSViewRepresentable {
  func makeNSView(context: Context) -> DragView { DragView() }
  func updateNSView(_ view: DragView, context: Context) {}
  final class DragView: NSView {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func mouseDown(with event: NSEvent) { window?.performDrag(with: event) }
  }
}

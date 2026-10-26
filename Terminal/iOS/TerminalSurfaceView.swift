import GhosttyKit
import UIKit

final class TerminalSurfaceView: UIView {
  private let callbackLock = NSLock()
  private nonisolated(unsafe) var output: (@Sendable (Data) -> Void)?
  private nonisolated(unsafe) var resize: (@Sendable (Int, Int) -> Void)?
  nonisolated var onPtyOutput: (@Sendable (Data) -> Void)? {
    get {
      callbackLock.lock()
      defer { callbackLock.unlock() }
      return output
    }
    set {
      callbackLock.lock()
      output = newValue
      callbackLock.unlock()
    }
  }
  nonisolated var onGridResize: (@Sendable (Int, Int) -> Void)? {
    get {
      callbackLock.lock()
      defer { callbackLock.unlock() }
      return resize
    }
    set {
      callbackLock.lock()
      resize = newValue
      callbackLock.unlock()
    }
  }

  private nonisolated(unsafe) var surface: ghostty_surface_t?
  private var visible = false
  private var lastPixelSize = CGSize.zero
  private var lastScale: CGFloat = 0
  let textInput = TerminalTextInputView()
  weak var inputRelay: TerminalInputRelay?
  var onPasteRequest: ((String) -> Void)?
  var inputEnabled = false {
    didSet {
      if !inputEnabled {
        textInput.discardComposition()
        inputRelay?.sticky = .none
        _ = resignFirstResponder()
      }
    }
  }

  init() {
    super.init(frame: CGRect(x: 0, y: 0, width: 390, height: 600))
    backgroundColor = .white
    overrideUserInterfaceStyle = .light
    isOpaque = true
    accessibilityIdentifier = "terminal.surface"
    addSubview(textInput)
    textInput.onCommit = { [weak self] in self?.insertText($0) }
    textInput.onDelete = { [weak self] in self?.sendKey(.backspace) }
    textInput.onPresses = { [weak self] in self?.handlePresses($0) ?? $0 }
    textInput.onPaste = { [weak self] in self?.onPasteRequest?($0) }
    textInput.onFocus = { [weak self] focused in
      if let surface = self?.surface { ghostty_surface_set_focus(surface, focused) }
    }
    addGestureRecognizer(UIPanGestureRecognizer(target: self, action: #selector(pan(_:))))
  }
  required init?(coder: NSCoder) { fatalError("Not supported") }

  private struct Handle: @unchecked Sendable { let pointer: ghostty_surface_t }
  deinit {
    let handle = surface.map(Handle.init)
    let wasVisible = visible
    let release: @Sendable () -> Void = {
      if let handle { ghostty_surface_free(handle.pointer) }
      if wasVisible { MainActor.assumeIsolated { GhosttyEngine.shared.visible(-1) } }
    }
    if Thread.isMainThread { release() } else { DispatchQueue.main.sync(execute: release) }
  }

  func ensureSurface() {
    guard surface == nil else { return }
    let pointer = Unmanaged.passUnretained(self).toOpaque()
    var config = ghostty_surface_config_new()
    config.platform_tag = GHOSTTY_PLATFORM_IOS
    config.platform = ghostty_platform_u(ios: .init(uiview: pointer))
    config.userdata = pointer
    config.scale_factor = Double(window?.screen.scale ?? UIScreen.main.scale)
    config.font_size = 12
    config.io_backend = GHOSTTY_IO_BACKEND_PASSTHRU
    Self.callbacks(&config)
    surface = ghostty_surface_new(GhosttyEngine.shared.app, &config)
    if let surface { ghostty_surface_set_color_scheme(surface, GHOSTTY_COLOR_SCHEME_LIGHT) }
    lastPixelSize = .zero
    lastScale = 0
    updateVisibility()
    setNeedsLayout()
    layoutIfNeeded()
  }

  func destroySurface() {
    inputEnabled = false
    if let surface { ghostty_surface_free(surface) }
    surface = nil
    onPtyOutput = nil
    onGridResize = nil
    for sublayer in layer.sublayers ?? [] where sublayer !== textInput.layer {
      sublayer.removeFromSuperlayer()
    }
    updateVisibility()
  }

  private nonisolated static func callbacks(_ config: inout ghostty_surface_config_s) {
    config.pty_write_cb = { ud, bytes, count in
      guard let ud, let bytes, count > 0 else { return }
      Unmanaged<TerminalSurfaceView>.fromOpaque(ud).takeUnretainedValue()
        .onPtyOutput?(Data(bytes: bytes, count: Int(count)))
    }
    config.pty_resize_cb = { ud, cols, rows, _, _ in
      guard let ud else { return }
      Unmanaged<TerminalSurfaceView>.fromOpaque(ud).takeUnretainedValue()
        .onGridResize?(Int(cols), Int(rows))
    }
  }

  override func didMoveToWindow() {
    super.didMoveToWindow()
    updateVisibility()
    setNeedsLayout()
  }
  private func updateVisibility() {
    let current = window != nil && surface != nil
    guard current != visible else { return }
    visible = current
    GhosttyEngine.shared.visible(current ? 1 : -1)
  }

  override func layoutSubviews() {
    super.layoutSubviews()
    guard let surface else { return }
    let scale = window?.screen.scale ?? UIScreen.main.scale
    let pixels = CGSize(width: max(1, bounds.width * scale), height: max(1, bounds.height * scale))
    if scale != lastScale {
      ghostty_surface_set_content_scale(surface, Double(scale), Double(scale))
      lastScale = scale
    }
    if pixels != lastPixelSize {
      ghostty_surface_set_size(surface, UInt32(pixels.width), UInt32(pixels.height))
      lastPixelSize = pixels
    }
    CATransaction.begin()
    CATransaction.setDisableActions(true)
    for sublayer in layer.sublayers ?? [] where sublayer !== textInput.layer {
      sublayer.frame = bounds
      sublayer.contentsScale = scale
    }
    CATransaction.commit()
  }

  var hasLiveSurface: Bool { surface != nil }
  var gridSize: (columns: Int, rows: Int) {
    guard let surface else { return (80, 24) }
    let size = ghostty_surface_size(surface)
    return (max(1, Int(size.columns)), max(1, Int(size.rows)))
  }
  func inject(_ data: Data) {
    guard let surface else { return }
    data.withUnsafeBytes { bytes in
      guard let base = bytes.bindMemory(to: UInt8.self).baseAddress else { return }
      ghostty_surface_pty_data(surface, base, UInt(data.count))
    }
  }

  override var canBecomeFirstResponder: Bool { inputEnabled }
  override var isFirstResponder: Bool { textInput.isFirstResponder }
  override func becomeFirstResponder() -> Bool { inputEnabled && textInput.becomeFirstResponder() }
  override func resignFirstResponder() -> Bool { textInput.resignFirstResponder() }
  override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent?) {
    super.touchesEnded(touches, with: event)
    _ = becomeFirstResponder()
  }

  func insertText(_ text: String) {
    guard inputEnabled, let surface else { return }
    let sticky = inputRelay?.consumeSticky() ?? .none
    if text.count == 1, let physical = text.first.flatMap(Ghostty.Key.physical), !sticky.isEmpty {
      sendKey(physical.key, mods: physical.shift ? sticky.union(.shift) : sticky)
      return
    }
    for character in text {
      if character == "\n" || character == "\r" {
        sendKey(.enter, mods: sticky)
        continue
      }
      if let physical = Ghostty.Key.physical(for: character) {
        Ghostty.KeyEvent(key: physical.key, text: String(character)).withCValue {
          _ = ghostty_surface_key(surface, $0)
        }
      } else {
        let text = String(character)
        // Text from an IME is committed as a key event, not a paste.
        var event = ghostty_input_key_s()
        event.action = GHOSTTY_ACTION_PRESS
        event.keycode = UInt32.max
        event.composing = false
        text.withCString {
          event.text = $0
          _ = ghostty_surface_key(surface, event)
        }
      }
    }
  }

  func sendKey(_ key: Ghostty.Key, mods: Ghostty.Mods = .none) {
    guard inputEnabled, let surface else { return }
    Ghostty.KeyEvent(key: key, mods: mods).withCValue { _ = ghostty_surface_key(surface, $0) }
  }
  func sendPaste(_ text: String) {
    guard inputEnabled, let surface else { return }
    text.withCString { ghostty_surface_text(surface, $0, UInt(text.utf8.count)) }
  }
  func scrollHistory(lines: Int) {
    guard let surface else { return }
    let action = "scroll_page_lines:\(lines)"
    action.withCString { _ = ghostty_surface_binding_action(surface, $0, UInt(action.utf8.count)) }
  }
  @objc private func pan(_ gesture: UIPanGestureRecognizer) {
    guard inputEnabled, let surface else { return }
    let delta = gesture.translation(in: self).y
    gesture.setTranslation(.zero, in: self)
    let scale = Double(window?.screen.scale ?? UIScreen.main.scale)
    ghostty_surface_mouse_scroll(surface, 0, Double(delta) * scale, 1)
  }

  private func handlePresses(_ presses: Set<UIPress>) -> Set<UIPress> {
    guard inputEnabled else { return [] }
    var unhandled = Set<UIPress>()
    for press in presses {
      guard let key = press.key else {
        unhandled.insert(press)
        continue
      }
      var mods = Ghostty.Mods.none
      if key.modifierFlags.contains(.control) { mods.insert(.ctrl) }
      if key.modifierFlags.contains(.alternate) { mods.insert(.alt) }
      if key.modifierFlags.contains(.shift) { mods.insert(.shift) }
      if key.modifierFlags.contains(.command) {
        if key.charactersIgnoringModifiers.lowercased() == "v" {
          if let text = UIPasteboard.general.string { onPasteRequest?(text) }
          continue
        }
        unhandled.insert(press)
        continue
      }
      let mapped: Ghostty.Key?
      switch key.keyCode {
      case .keyboardEscape: mapped = .escape
      case .keyboardTab: mapped = .tab
      case .keyboardReturnOrEnter: mapped = .enter
      case .keyboardDeleteOrBackspace: mapped = .backspace
      case .keyboardDeleteForward: mapped = .delete
      case .keyboardUpArrow: mapped = .up
      case .keyboardDownArrow: mapped = .down
      case .keyboardLeftArrow: mapped = .left
      case .keyboardRightArrow: mapped = .right
      case .keyboardHome: mapped = .home
      case .keyboardEnd: mapped = .end
      case .keyboardPageUp: mapped = .pageUp
      case .keyboardPageDown: mapped = .pageDown
      default:
        mapped =
          mods.contains(.ctrl) || mods.contains(.alt)
          ? key.charactersIgnoringModifiers.first.flatMap { Ghostty.Key.physical(for: $0)?.key }
          : nil
      }
      if let mapped { sendKey(mapped, mods: mods) } else { unhandled.insert(press) }
    }
    return unhandled
  }
}

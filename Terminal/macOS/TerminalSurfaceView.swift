import AppKit
import GhosttyKit

/// AppKit owns input/selection; Ghostty owns parsing, rendering and PTY encoding.
final class TerminalSurfaceView: NSView, @preconcurrency NSTextInputClient {
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
  private var lastPixelSize = CGSize.zero
  private var lastScale: CGFloat = 0
  private var marked = NSAttributedString(string: "")
  private var markedSelection = NSRange(location: 0, length: 0)
  private var keyText: [String]?
  var onPasteRequest: ((String) -> Void)?
  var inputEnabled = false {
    didSet {
      if !inputEnabled { unmarkText() }
      if let surface {
        ghostty_surface_set_focus(surface, inputEnabled && window?.isKeyWindow == true)
      }
      if inputEnabled { window?.makeFirstResponder(self) }
    }
  }

  init() {
    super.init(frame: NSRect(x: 0, y: 0, width: 900, height: 560))
    wantsLayer = true
    layer?.backgroundColor = NSColor.white.cgColor
    appearance = NSAppearance(named: .aqua)
    setAccessibilityElement(true)
    setAccessibilityRole(.textArea)
    setAccessibilityLabel("SSH terminal")
    setAccessibilityIdentifier("terminal.surface")
  }
  required init?(coder: NSCoder) { fatalError("Not supported") }
  override var isOpaque: Bool { true }
  override var acceptsFirstResponder: Bool { inputEnabled }

  private struct Handle: @unchecked Sendable { let pointer: ghostty_surface_t }
  deinit {
    NotificationCenter.default.removeObserver(self)
    let handle = surface.map(Handle.init)
    let release: @Sendable () -> Void = { if let handle { ghostty_surface_free(handle.pointer) } }
    if Thread.isMainThread { release() } else { DispatchQueue.main.sync(execute: release) }
  }

  func ensureSurface() {
    guard surface == nil else { return }
    let pointer = Unmanaged.passUnretained(self).toOpaque()
    var config = ghostty_surface_config_new()
    config.platform_tag = GHOSTTY_PLATFORM_MACOS
    config.platform = ghostty_platform_u(macos: .init(nsview: pointer))
    config.userdata = pointer
    config.scale_factor = Double(
      window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 2)
    config.font_size = 14
    config.io_backend = GHOSTTY_IO_BACKEND_PASSTHRU
    Self.callbacks(&config)
    surface = ghostty_surface_new(GhosttyEngine.shared.app, &config)
    if let surface { ghostty_surface_set_color_scheme(surface, GHOSTTY_COLOR_SCHEME_LIGHT) }
    lastPixelSize = .zero
    lastScale = 0
    updateWindowState()
    needsLayout = true
    layoutSubtreeIfNeeded()
  }

  func destroySurface() {
    inputEnabled = false
    if let surface { ghostty_surface_free(surface) }
    surface = nil
    onPtyOutput = nil
    onGridResize = nil
    layer?.sublayers?.forEach { $0.removeFromSuperlayer() }
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

  override func viewDidMoveToWindow() {
    super.viewDidMoveToWindow()
    NotificationCenter.default.removeObserver(self)
    if let window {
      for name in [
        NSWindow.didBecomeKeyNotification, NSWindow.didResignKeyNotification,
        NSWindow.didChangeOcclusionStateNotification, NSWindow.didChangeScreenNotification,
      ] {
        NotificationCenter.default.addObserver(
          self, selector: #selector(updateWindowState), name: name, object: window)
      }
      if inputEnabled { window.makeFirstResponder(self) }
    }
    updateWindowState()
    needsLayout = true
  }
  @objc private func updateWindowState() {
    guard let surface else { return }
    ghostty_surface_set_focus(
      surface, inputEnabled && window?.isKeyWindow == true && window?.firstResponder === self)
    ghostty_surface_set_occlusion(surface, window?.occlusionState.contains(.visible) == true)
    if let id = window?.screen?.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")]
      as? NSNumber
    {
      ghostty_surface_set_display_id(surface, id.uint32Value)
    }
  }
  override func becomeFirstResponder() -> Bool {
    guard inputEnabled else { return false }
    if let surface { ghostty_surface_set_focus(surface, true) }
    return true
  }
  override func resignFirstResponder() -> Bool {
    inputContext?.discardMarkedText()
    unmarkText()
    if let surface { ghostty_surface_set_focus(surface, false) }
    return true
  }
  override func viewDidChangeBackingProperties() {
    super.viewDidChangeBackingProperties()
    needsLayout = true
  }
  override func layout() {
    super.layout()
    guard let surface else { return }
    let scale = window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 2
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
    for sublayer in layer?.sublayers ?? [] {
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
  func sendKey(_ key: Ghostty.Key, mods: Ghostty.Mods = .none) {
    guard inputEnabled, let surface else { return }
    Ghostty.KeyEvent(key: key, mods: mods).withCValue { _ = ghostty_surface_key(surface, $0) }
  }
  func sendPaste(_ text: String) {
    guard inputEnabled, let surface else { return }
    text.withCString { ghostty_surface_text(surface, $0, UInt(text.utf8.count)) }
  }
  private func commit(_ text: String) {
    guard inputEnabled, let surface, !text.isEmpty else { return }
    var key = ghostty_input_key_s()
    key.action = GHOSTTY_ACTION_PRESS
    key.keycode = UInt32.max
    text.withCString {
      key.text = $0
      _ = ghostty_surface_key(surface, key)
    }
  }

  override func keyDown(with event: NSEvent) {
    guard inputEnabled, !event.modifierFlags.contains(.command) else { return }
    // Let the current input method own all keys while composing. Outside composition,
    // Ctrl and Option are terminal modifiers, not Cocoa editing/dead-key commands.
    let wasMarked = hasMarkedText()
    if !wasMarked && !event.modifierFlags.intersection([.control, .option]).isEmpty {
      send(event, text: event.charactersIgnoringModifiers, consumed: [])
      return
    }
    keyText = []
    interpretKeyEvents([event])
    let text = keyText ?? []
    keyText = nil
    if wasMarked || hasMarkedText() {
      text.forEach(commit)
      return
    }
    if text.isEmpty {
      send(event, text: event.characters, consumed: [])
    } else {
      for part in text { send(event, text: part, consumed: [.shift]) }
    }
  }
  override func keyUp(with event: NSEvent) {
    guard inputEnabled, !hasMarkedText(), !event.modifierFlags.contains(.command) else { return }
    send(event, text: nil, consumed: [], release: true)
  }
  private func send(
    _ event: NSEvent, text: String?, consumed: NSEvent.ModifierFlags, release: Bool = false
  ) {
    guard let surface else { return }
    var key = ghostty_input_key_s()
    key.action =
      release
      ? GHOSTTY_ACTION_RELEASE : (event.isARepeat ? GHOSTTY_ACTION_REPEAT : GHOSTTY_ACTION_PRESS)
    key.keycode = UInt32(event.keyCode)
    key.mods = Self.mods(event.modifierFlags)
    key.consumed_mods = Self.mods(consumed)
    key.unshifted_codepoint =
      event.characters(byApplyingModifiers: [])?.unicodeScalars.first?.value ?? 0
    // Cocoa function keys occupy the private-use range; Ghostty derives these from keycode.
    let printable = text.flatMap { value -> String? in
      guard let first = value.unicodeScalars.first, first.value >= 0x20,
        !(0xf700...0xf8ff).contains(first.value)
      else { return nil }
      return value
    }
    if let printable {
      printable.withCString {
        key.text = $0
        _ = ghostty_surface_key(surface, key)
      }
    } else {
      _ = ghostty_surface_key(surface, key)
    }
  }
  private static func mods(_ flags: NSEvent.ModifierFlags) -> ghostty_input_mods_e {
    var mods = Ghostty.Mods.none
    if flags.contains(.shift) { mods.insert(.shift) }
    if flags.contains(.control) { mods.insert(.ctrl) }
    if flags.contains(.option) { mods.insert(.alt) }
    if flags.contains(.command) { mods.insert(.super) }
    return mods.cMods
  }

  override func performKeyEquivalent(with event: NSEvent) -> Bool {
    guard window?.firstResponder === self, event.modifierFlags.contains(.command) else {
      return false
    }
    switch event.charactersIgnoringModifiers?.lowercased() {
    case "c": copy(nil)
    case "v": paste(nil)
    case "a": selectAll(nil)
    default: return false
    }
    return true
  }
  @objc func copy(_ sender: Any?) {
    guard let text = selectionText else { return }
    NSPasteboard.general.clearContents()
    NSPasteboard.general.setString(text, forType: .string)
  }
  var selectionText: String? {
    guard let surface else { return nil }
    var text = ghostty_text_s()
    guard ghostty_surface_read_selection(surface, &text) else { return nil }
    defer { ghostty_surface_free_text(surface, &text) }
    guard let pointer = text.text else { return nil }
    return String(
      decoding: UnsafeBufferPointer(
        start: UnsafeRawPointer(pointer).assumingMemoryBound(to: UInt8.self),
        count: Int(text.text_len)), as: UTF8.self)
  }
  @objc func paste(_ sender: Any?) {
    if let text = NSPasteboard.general.string(forType: .string) { onPasteRequest?(text) }
  }
  override func selectAll(_ sender: Any?) { binding("select_all") }
  private func binding(_ action: String) {
    guard let surface else { return }
    action.withCString { _ = ghostty_surface_binding_action(surface, $0, UInt(action.utf8.count)) }
  }

  // NSTextInputClient: preedit is local, and insertText is the sole commit point.
  func hasMarkedText() -> Bool { marked.length > 0 }
  func markedRange() -> NSRange {
    hasMarkedText()
      ? NSRange(location: 0, length: marked.length) : NSRange(location: NSNotFound, length: 0)
  }
  func selectedRange() -> NSRange {
    hasMarkedText() ? markedSelection : NSRange(location: NSNotFound, length: 0)
  }
  func validAttributesForMarkedText() -> [NSAttributedString.Key] { [] }
  func setMarkedText(_ string: Any, selectedRange: NSRange, replacementRange: NSRange) {
    guard inputEnabled else { return }
    marked = (string as? NSAttributedString) ?? NSAttributedString(string: string as? String ?? "")
    markedSelection = selectedRange
    if let surface {
      marked.string.withCString {
        ghostty_surface_preedit(surface, $0, UInt(marked.string.utf8.count))
      }
    }
  }
  func unmarkText() {
    marked = NSAttributedString(string: "")
    markedSelection = NSRange(location: 0, length: 0)
    if let surface { ghostty_surface_preedit(surface, nil, 0) }
  }
  func insertText(_ string: Any, replacementRange: NSRange) {
    guard inputEnabled else { return }
    let text = (string as? NSAttributedString)?.string ?? string as? String ?? ""
    unmarkText()
    if keyText != nil { keyText?.append(text) } else { commit(text) }
  }
  override func doCommand(by selector: Selector)
  { /* Encoded by keyDown after Cocoa input handling. */  }
  func attributedSubstring(forProposedRange range: NSRange, actualRange: NSRangePointer?)
    -> NSAttributedString?
  {
    guard hasMarkedText(), range.location != NSNotFound else { return nil }
    let intersection = NSIntersectionRange(range, markedRange())
    actualRange?.pointee = intersection
    return marked.attributedSubstring(from: intersection)
  }
  func characterIndex(for point: NSPoint) -> Int { NSNotFound }
  func firstRect(forCharacterRange range: NSRange, actualRange: NSRangePointer?) -> NSRect {
    actualRange?.pointee = markedRange()
    guard let surface, let window else { return .zero }
    var x = 0.0
    var y = 0.0
    var width = 0.0
    var height = 0.0
    ghostty_surface_ime_point(surface, &x, &y, &width, &height)
    return window.convertToScreen(
      convert(NSRect(x: x, y: bounds.height - y, width: width, height: height), to: nil))
  }

  private func mousePosition(_ event: NSEvent) {
    guard let surface else { return }
    let point = convert(event.locationInWindow, from: nil)
    ghostty_surface_mouse_pos(
      surface, point.x, bounds.height - point.y, Self.mods(event.modifierFlags))
  }
  override func mouseDown(with event: NSEvent) {
    guard inputEnabled, let surface else { return }
    window?.makeFirstResponder(self)
    mousePosition(event)
    _ = ghostty_surface_mouse_button(
      surface, GHOSTTY_MOUSE_PRESS, GHOSTTY_MOUSE_LEFT, Self.mods(event.modifierFlags))
  }
  override func mouseUp(with event: NSEvent) {
    guard inputEnabled, let surface else { return }
    mousePosition(event)
    _ = ghostty_surface_mouse_button(
      surface, GHOSTTY_MOUSE_RELEASE, GHOSTTY_MOUSE_LEFT, Self.mods(event.modifierFlags))
  }
  override func mouseDragged(with event: NSEvent) { if inputEnabled { mousePosition(event) } }
  override func scrollWheel(with event: NSEvent) {
    guard inputEnabled, let surface else { return }
    var momentum: Int32 = 0
    switch event.momentumPhase {
    case .began: momentum = 1
    case .stationary: momentum = 2
    case .changed: momentum = 3
    case .ended: momentum = 4
    case .cancelled: momentum = 5
    case .mayBegin: momentum = 6
    default: break
    }
    let factor = event.hasPreciseScrollingDeltas ? 2.0 : 1.0
    ghostty_surface_mouse_scroll(
      surface, event.scrollingDeltaX * factor, event.scrollingDeltaY * factor,
      (momentum << 1) | (event.hasPreciseScrollingDeltas ? 1 : 0))
  }
}

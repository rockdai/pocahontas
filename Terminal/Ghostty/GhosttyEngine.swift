import GhosttyKit
import UIKit

@MainActor
final class GhosttyEngine {
  static let shared = GhosttyEngine()
  let app: ghostty_app_t
  private let config: GhosttyConfig
  private var displayLink: CADisplayLink?
  private var visibleSurfaces = 0
  private var backgrounded = false

  private init() {
    guard ghostty_init(UInt(CommandLine.argc), CommandLine.unsafeArgv) == GHOSTTY_SUCCESS else {
      fatalError("Unable to initialize terminal engine")
    }
    config = GhosttyConfig()
    var runtime = Self.runtimeConfiguration()
    guard let app = ghostty_app_new(&runtime, config.handle) else {
      fatalError("Unable to create terminal engine")
    }
    self.app = app
    ghostty_app_set_focus(app, true)
    let link = CADisplayLink(target: self, selector: #selector(tick))
    link.add(to: .main, forMode: .common)
    link.isPaused = true
    displayLink = link
  }

  @objc private func tick() { ghostty_app_tick(app) }

  func visible(_ delta: Int) {
    visibleSurfaces += delta
    updateDisplayLink()
  }

  func setBackgrounded(_ value: Bool) {
    backgrounded = value
    ghostty_app_set_focus(app, !value)
    updateDisplayLink()
  }

  private func updateDisplayLink() { displayLink?.isPaused = backgrounded || visibleSurfaces == 0 }

  // C callbacks are declared outside MainActor isolation, including renderer-thread wakeups.
  private nonisolated static func runtimeConfiguration() -> ghostty_runtime_config_s {
    .init(
      userdata: nil, supports_selection_clipboard: false,
      wakeup_cb: { _ in }, action_cb: { _, _, _ in false },
      read_clipboard_cb: { _, _, _ in false },
      confirm_read_clipboard_cb: { _, _, _, _ in },
      write_clipboard_cb: { _, _, _, _, _ in }, close_surface_cb: { _, _ in })
  }
}

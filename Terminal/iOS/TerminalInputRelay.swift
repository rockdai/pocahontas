// Adapted from baxian-app-ios under Apache-2.0; see Licenses/baxian-app-ios-Apache-2.0.txt.
import Foundation
import Observation

// Bridges the accessory key bar to the live surface: special keys, and
// one-shot sticky Ctrl/Alt that also arms the next system-keyboard character.
@MainActor
@Observable
final class TerminalInputRelay {
  weak var surface: TerminalSurfaceView?
  var sticky: Ghostty.Mods = .none

  func toggle(_ mod: Ghostty.Mods) {
    sticky.formSymmetricDifference(mod)
  }

  func consumeSticky() -> Ghostty.Mods {
    let mods = sticky
    sticky = .none
    return mods
  }

  func send(_ key: Ghostty.Key) {
    // Consume before the optional chain: a nil surface must not leave it armed.
    let mods = consumeSticky()
    surface?.sendKey(key, mods: mods)
  }

  func toggleKeyboard() {
    guard let surface else { return }
    _ = surface.isFirstResponder ? surface.resignFirstResponder() : surface.becomeFirstResponder()
  }
}

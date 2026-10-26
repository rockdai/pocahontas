import Foundation
import GhosttyKit

final class GhosttyConfig {
  let handle: ghostty_config_t
  init() {
    guard let handle = ghostty_config_new() else {
      fatalError("Unable to allocate terminal configuration")
    }
    self.handle = handle
    let text = """
      command = /bin/sh
      working-directory = inherit
      clipboard-read = deny
      clipboard-write = deny
      window-padding-x = 0
      window-padding-y = 0
      font-codepoint-map = U+3000-U+30FF,U+31F0-U+31FF=Hiragino Sans
      font-codepoint-map = U+1F000-U+1FAFF=Apple Color Emoji
      background = #111419
      foreground = #e4e7ec
      cursor-color = #a3e6b1
      selection-background = #344556
      selection-foreground = #ffffff
      """
    let file = FileManager.default.temporaryDirectory.appendingPathComponent(
      "pocahontas-ghostty.conf")
    do {
      try text.write(to: file, atomically: true, encoding: .utf8)
      file.path.withCString { ghostty_config_load_file(handle, $0) }
      try FileManager.default.removeItem(at: file)
    } catch { fatalError("Unable to prepare terminal configuration: \(error)") }
    ghostty_config_finalize(handle)
  }
  deinit { ghostty_config_free(handle) }
}

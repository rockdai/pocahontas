import Foundation
import GhosttyKit

final class GhosttyConfig {
  let handle: ghostty_config_t
  init() {
    guard let handle = ghostty_config_new() else {
      fatalError("Unable to allocate terminal configuration")
    }
    self.handle = handle
    var text = """
      command = /bin/sh
      working-directory = inherit
      clipboard-read = deny
      clipboard-write = deny
      window-padding-x = 0
      window-padding-y = 0
      font-codepoint-map = U+3000-U+30FF,U+31F0-U+31FF=Hiragino Sans
      font-codepoint-map = U+1F000-U+1FAFF=Apple Color Emoji
      background = #ffffff
      foreground = #24292f
      cursor-color = #1a7f37
      cursor-text = #ffffff
      selection-background = #cce8d3
      selection-foreground = #24292f
      minimum-contrast = 3
      palette = 0=#24292f
      palette = 1=#cf222e
      palette = 2=#116329
      palette = 3=#9a6700
      palette = 4=#0969da
      palette = 5=#8250df
      palette = 6=#1b7c83
      palette = 7=#d0d7de
      palette = 8=#57606a
      palette = 9=#a40e26
      palette = 10=#1a7f37
      palette = 11=#7d4e00
      palette = 12=#0550ae
      palette = 13=#6639ba
      palette = 14=#0a6c74
      palette = 15=#ffffff
      """
    #if os(macOS)
    // AppKit owns application shortcuts. Option is the terminal's Alt modifier.
    text += "\nkeybind = clear\nmacos-option-as-alt = true\n"
    #endif
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

import SwiftUI

/// Only interrupted sessions need extra chrome; normal status lives in the tab.
struct TerminalConnectionNotice: View {
  let terminal: TerminalController

  var body: some View {
    if let message {
      HStack(alignment: .top, spacing: 12) {
        Text(message).font(.callout).foregroundStyle(AppAppearance.warning)
          .frame(maxWidth: .infinity, alignment: .leading)
          .accessibilityElement(children: .ignore).accessibilityLabel(message)
          .accessibilityIdentifier("terminal.error")
        if terminal.canReconnect {
          Button("Reconnect", systemImage: "arrow.clockwise") { terminal.reconnect() }
            .accessibilityIdentifier("terminal.reconnect")
        }
      }.padding(12)
    }
  }

  private var message: String? {
    switch terminal.state {
    case .failed(let message): message
    case .disconnected: "Disconnected. Reconnect to open a new remote shell."
    default: nil
    }
  }
}

import SwiftUI

struct SessionBar: View {
  @Bindable var workspace: TerminalWorkspace

  var body: some View {
    HStack(spacing: 0) {
      ScrollViewReader { proxy in
        ScrollView(.horizontal, showsIndicators: false) {
          HStack(spacing: 6) {
            ForEach(workspace.sessions) { terminal in
              HStack(spacing: 2) {
                Button {
                  workspace.select(terminal.id)
                } label: {
                  HStack(spacing: 7) {
                    Image(
                      systemName: terminal.challenge != nil ? "questionmark.shield" : "terminal")
                    VStack(alignment: .leading, spacing: 2) {
                      Text("\(terminal.number) · \(terminal.title)")
                        .font(.subheadline.weight(.medium)).lineLimit(1)
                      Text(terminal.challenge != nil ? "Awaiting trust" : terminal.status)
                        .font(.caption2).foregroundStyle(.secondary)
                    }
                  }.padding(.leading, 10).padding(.vertical, 8)
                    .frame(minWidth: 100, maxWidth: 200, alignment: .leading)
                    .contentShape(Rectangle())
                }
                .accessibilityIdentifier("session.select.\(terminal.number)")
                .accessibilityLabel(
                  "Session \(terminal.number), \(terminal.title), \(terminal.status)"
                )
                .accessibilityAddTraits(workspace.selectedID == terminal.id ? .isSelected : [])
                Button {
                  workspace.close(terminal.id)
                } label: {
                  Image(systemName: "xmark").font(.caption.weight(.semibold))
                    .frame(width: 36, height: 44).contentShape(Rectangle())
                }
                .accessibilityLabel("Close session \(terminal.number)")
                .accessibilityIdentifier("session.close.\(terminal.number)")
              }
              .background(
                workspace.selectedID == terminal.id
                  ? AppAppearance.accent.opacity(0.12) : Color.clear,
                in: RoundedRectangle(cornerRadius: 10)
              )
              .overlay {
                RoundedRectangle(cornerRadius: 10)
                  .strokeBorder(
                    workspace.selectedID == terminal.id
                      ? AppAppearance.accent.opacity(0.3) : Color.secondary.opacity(0.15))
              }
              .id(terminal.id)
            }
            if workspace.sessions.isEmpty {
              Label("Sessions", systemImage: "rectangle.on.rectangle")
                .font(.subheadline).foregroundStyle(.secondary).padding(.horizontal, 8)
            }
          }.padding(8)
        }
        .onChange(of: workspace.selectedID) { _, id in
          if let id { withAnimation { proxy.scrollTo(id, anchor: .center) } }
        }
      }
      Button {
        workspace.showNewConnection()
      } label: {
        Image(systemName: "plus").font(.body.weight(.semibold))
          .frame(width: 44, height: 44).contentShape(Rectangle())
          .background(
            workspace.selectedID == nil ? AppAppearance.accent.opacity(0.12) : Color.clear,
            in: RoundedRectangle(cornerRadius: 10))
      }
      .accessibilityLabel("New Session").accessibilityIdentifier("session.new")
      .padding(.trailing, 8)
    }
    .frame(height: 64)
    .buttonStyle(.plain)
    .foregroundStyle(AppAppearance.accent)
    .background(AppAppearance.background)
    .accessibilityElement(children: .contain)
  }
}

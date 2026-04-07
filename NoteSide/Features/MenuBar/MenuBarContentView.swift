import SwiftUI

struct MenuBarContentView: View {
    @EnvironmentObject private var appState: AppState
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .top, spacing: 12) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("NoteSide")
                        .font(.title3.weight(.semibold))
                    Text("Leave notes for the app, page, or file you are in.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }

                Spacer(minLength: 0)

                Button {
                    dismiss()
                    appState.showInfoWindow()
                } label: {
                    Image(systemName: "info.circle")
                        .font(.system(size: 18, weight: .semibold))
                        .foregroundStyle(NoteSideTheme.primaryText)
                }
                .buttonStyle(.plain)
            }

            Button {
                dismiss()
                appState.openAllNotes()
            } label: {
                Label("View All Notes", systemImage: "square.grid.2x2")
                    .frame(maxWidth: .infinity, alignment: .leading)
            }

            Button {
                dismiss()
                appState.showOnboarding()
            } label: {
                Label("Permissions & Setup", systemImage: "checklist")
                    .frame(maxWidth: .infinity, alignment: .leading)
            }

            VStack(alignment: .leading, spacing: 10) {
                Text("Hotkey")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)

                Text(appState.hotKeyDisplayString)
                    .font(.subheadline.weight(.medium))

                ShortcutRecorderView(displayText: appState.hotKeyDisplayString) { shortcut in
                    appState.setHotKeyShortcut(shortcut)
                }
                .fixedSize()

                Text("Click the box, then press the shortcut you want.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            if let errorMessage = appState.editorErrorMessage {
                Text(errorMessage)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }

            Divider()

            if appState.recentNotes.isEmpty {
                Text("No notes yet.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            } else {
                VStack(alignment: .leading, spacing: 10) {
                    Text("Recent")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)

                    ForEach(appState.recentNotes) { note in
                        Button {
                            dismiss()
                            appState.open(note)
                        } label: {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(note.context.displayName)
                                    .font(.subheadline.weight(.medium))
                                Text(note.body)
                                    .lineLimit(2)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
        }
        .padding(16)
        .frame(width: 340)
    }
}

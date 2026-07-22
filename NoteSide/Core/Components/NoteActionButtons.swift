import SwiftUI

struct NoteSelectionCheckbox: View {
    @Environment(AppState.self) private var appState
    let noteID: UUID

    private var isSelected: Bool {
        appState.notesState.selectedNoteIDs.contains(noteID)
    }

    var body: some View {
        Button {
            appState.notesState.toggleSelection(noteID)
        } label: {
            Image(systemName: isSelected ? "checkmark.square.fill" : "square")
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(isSelected ? NoteSideTheme.accent : NoteSideTheme.secondaryText)
                .frame(width: 22, height: 22)
                .contentShape(Rectangle())
        }
        .buttonStyle(.borderless)
        .accessibilityLabel(isSelected ? "Deselect note" : "Select note")
    }
}

struct NotePinButton: View {
    @Environment(AppState.self) private var appState
    let note: ContextNote

    var body: some View {
        Button {
            appState.togglePin(note)
        } label: {
            Image(systemName: note.isPinned ? "pin.fill" : "pin")
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(note.isPinned ? NoteSideTheme.accent : NoteSideTheme.secondaryText)
                .frame(width: 26, height: 26)
                .contentShape(Rectangle())
        }
        .buttonStyle(.borderless)
        .help(note.isPinned ? "Unpin" : "Pin")
        .accessibilityLabel(note.isPinned ? "Unpin note" : "Pin note")
    }
}

struct NoteDeleteButton: View {
    @Environment(AppState.self) private var appState
    @State private var showingConfirmation = false
    let note: ContextNote

    var body: some View {
        Button(role: .destructive) {
            showingConfirmation = true
        } label: {
            Image(systemName: "trash")
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(NoteSideTheme.secondaryText)
                .frame(width: 26, height: 26)
                .contentShape(Rectangle())
        }
        .buttonStyle(.borderless)
        .help("Delete")
        .accessibilityLabel("Delete note")
        .popover(isPresented: $showingConfirmation, arrowEdge: .bottom) {
            DeleteConfirmationPopover(
                onConfirm: {
                    showingConfirmation = false
                    appState.notesState.delete(note)
                },
                onCancel: {
                    showingConfirmation = false
                }
            )
        }
    }
}

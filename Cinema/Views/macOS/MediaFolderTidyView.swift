/*
See the LICENSE.txt file for licensing information.

Abstract:
What tidying the media folder would rename and move, shown before it happens.
*/

#if os(macOS)
import SwiftData
import SwiftUI

/// The renames tidying would perform, listed so they can be read first.
///
/// Every row is a file that already exists and is already playing. Nothing here fixes a fault — it
/// makes names better — so the whole thing is worth exactly as much as the confidence that it
/// won't break something, and that confidence comes from seeing the list rather than from a
/// sentence promising it's fine.
struct MediaFolderTidyView: View {
    let folder: URL
    @Environment(\.modelContext) private var modelContext
    @Environment(\.dismiss) private var dismiss

    @State private var moves: [MediaFolderTidy.Move] = []
    @State private var outcome: Outcome?
    @State private var isWorking = false

    private struct Outcome {
        let moved: Int
        let failed: [(name: String, reason: String)]
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider()
            content
            Divider()
            footer
        }
        .frame(width: 620, height: 460)
        .task {
            moves = MediaFolderTidy.plannedMoves(
                in: folder, years: MediaFolderTidy.knownYears(in: modelContext))
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Tidy Media Folder")
                .font(.title2.weight(.semibold))
            Text(subtitle)
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(20)
    }

    private var subtitle: String {
        if let outcome {
            // The count is formatted separately rather than pinned into the sentence with an
            // English `"s"`. A ternary picking a suffix is not translatable at all: German needs
            // "Datei"/"Dateien", Japanese needs no plural, and Polish needs three forms — none of
            // which a suffix can express. `inflect` hands the plural to the language.
            let renamed = String(localized: "^[\(outcome.moved) file](inflect: true)")
            return outcome.failed.isEmpty
                ? String(localized: "Renamed \(renamed). Your library now points at the new names.")
                : String(localized: "Renamed \(renamed). \(outcome.failed.count) couldn’t be moved and were left alone.")
        }
        if moves.isEmpty {
            return String(localized: "Every converted video is already named the way Cinema would name it today.")
        }
        return String(localized: "These converted videos would be renamed the way Cinema names them today, and episodes filed under their show and season. Your originals aren’t touched, and the library is updated to match so nothing stops playing.")
    }

    @ViewBuilder private var content: some View {
        if let outcome, !outcome.failed.isEmpty {
            List(outcome.failed, id: \.name) { failure in
                LabeledContent(failure.name) {
                    Text(failure.reason).foregroundStyle(.secondary)
                }
            }
        } else if moves.isEmpty {
            ContentUnavailableView("Nothing to Tidy", systemImage: "checkmark.circle")
        } else {
            List(moves) { move in
                VStack(alignment: .leading, spacing: 2) {
                    Text(move.from.lastPathComponent)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                    Label(move.destination(relativeTo: folder), systemImage: "arrow.turn.down.right")
                        .font(.callout.weight(.medium))
                        .lineLimit(1)
                }
                .padding(.vertical, 2)
            }
            .listStyle(.inset)
        }
    }

    private var footer: some View {
        HStack {
            if outcome == nil, !moves.isEmpty {
                Text("\(moves.count) to rename")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
            Spacer()
            Button(outcome == nil && !moves.isEmpty ? "Cancel" : "Done") { dismiss() }
                .keyboardShortcut(.cancelAction)
            if outcome == nil, !moves.isEmpty {
                Button("Rename") { tidy() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(isWorking)
            }
        }
        .padding(20)
    }

    private func tidy() {
        isWorking = true
        let result = MediaFolderTidy.apply(moves, in: modelContext)
        outcome = Outcome(moved: result.moved.count, failed: result.failed)
        isWorking = false
    }
}
#endif

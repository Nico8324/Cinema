/*
See the LICENSE.txt file for licensing information.

Abstract:
A sheet that adds a YouTube video to the library from a pasted link.
*/

import SwiftUI
import SwiftData

/// A sheet that adds a YouTube video to the library from a pasted link.
struct AddYouTubeVideoView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var context

    @State private var urlText = ""
    @State private var isAdding = false
    @State private var errorMessage: String?

    private var enteredURL: URL? {
        let trimmed = urlText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        return URL(string: trimmed)
    }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    TextField("youtube.com/watch?v=…", text: $urlText)
                        #if !os(macOS)
                        .keyboardType(.URL)
                        .textInputAutocapitalization(.never)
                        #endif
                        .autocorrectionDisabled()
                        .onSubmit(addVideo)
                } header: {
                    Text("YouTube Link")
                } footer: {
                    if let errorMessage {
                        Text(errorMessage)
                            .foregroundStyle(.red)
                    } else {
                        Text("The video streams from YouTube when you play it — nothing is downloaded to your library.")
                    }
                }
            }
            #if os(iOS)
            .listStyle(.insetGrouped)
            #endif
            .navigationTitle("Add from YouTube")
            #if !os(macOS) && !os(tvOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .interactiveDismissDisabled(isAdding)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") {
                        dismiss()
                    }
                    .disabled(isAdding)
                }
                ToolbarItem(placement: .confirmationAction) {
                    if isAdding {
                        ProgressView()
                    } else {
                        Button("Add", action: addVideo)
                            .disabled(enteredURL == nil)
                    }
                }
            }
        }
        .macSheetSize(width: 480, height: 360)
    }

    private func addVideo() {
        guard let url = enteredURL, !isAdding else { return }
        isAdding = true
        errorMessage = nil
        Task {
            do {
                _ = try await VideoImporter.addYouTubeVideo(from: url, to: context)
                dismiss()
            } catch {
                errorMessage = error.localizedDescription
                isAdding = false
            }
        }
    }
}

#Preview(traits: .previewData) {
    AddYouTubeVideoView()
}

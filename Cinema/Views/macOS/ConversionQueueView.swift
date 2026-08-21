/*
See the LICENSE.txt file for licensing information.

Abstract:
The conversion queue: what would be converted, in what order, and what each one costs.
*/

#if os(macOS)
import SwiftUI

/// The films waiting to be converted, shortest first, with what each one would lose.
///
/// The losses are the reason this screen exists rather than a progress bar. Everything it lists —
/// subtitles MP4 can't carry, a soundtrack that has to be re-encoded, a film whose shape changes
/// so it can't be cropped — is invisible once the conversion is done. Saying it beforehand is the
/// difference between a person choosing it and discovering it in a file they can't get back.
struct ConversionQueueView: View {
    static let windowID = "conversion-queue"

    @AppStorage(MediaFolderScanner.folderPathKey) private var mediaFolderPath = ""
    @State private var queue = ConversionQueue()
    @State private var planning: Task<Void, Never>?

    private var folder: URL? {
        mediaFolderPath.isEmpty ? nil : URL(filePath: mediaFolderPath)
    }

    var body: some View {
        Group {
            if folder == nil {
                ContentUnavailableView(
                    "No Media Folder",
                    systemImage: "folder.badge.questionmark",
                    description: Text("Choose a media folder in Settings, and the videos in it that aren’t MP4 will be listed here.")
                )
            } else if queue.plans.isEmpty && queue.progress == nil {
                ContentUnavailableView {
                    Label("Nothing to Convert", systemImage: "checkmark.circle")
                } description: {
                    Text("Every video in your media folder is already MP4, or already has a converted copy beside it.")
                } actions: {
                    Button("Plan Queue") { startPlanning() }
                }
            } else {
                queueList
            }
        }
        .frame(minWidth: 620, minHeight: 460)
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                if queue.progress != nil {
                    Button("Stop") { planning?.cancel() }
                } else if queue.isConverting {
                    Button("Stop Converting", role: .destructive) { queue.stop() }
                } else {
                    Button("Plan Queue") { startPlanning() }
                        .disabled(folder == nil)
                }
            }
            ToolbarItem(placement: .confirmationAction) {
                Button("Convert All") { queue.start() }
                    .disabled(queue.plans.isEmpty || queue.isConverting || queue.progress != nil)
            }
        }
        .task {
            // Plan on opening, so the window is useful the moment it appears.
            if queue.plans.isEmpty { startPlanning() }
        }
        .onDisappear { planning?.cancel() }
    }

    private var queueList: some View {
        List {
            if let progress = queue.progress {
                Section {
                    HStack(spacing: 10) {
                        ProgressView(value: Double(progress.planned), total: Double(max(progress.total, 1)))
                        Text("Measuring \(progress.current)…")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }
            }

            if let running = queue.running {
                Section("Converting") {
                    VStack(alignment: .leading, spacing: 6) {
                        Text(running.plan.source.url.deletingPathExtension().lastPathComponent)
                            .font(.body.weight(.medium))
                        ProgressView(value: running.fraction)
                        Text(remaining(for: running))
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                            .monospacedDigit()
                    }
                    .padding(.vertical, 4)
                }
            }

            if !queue.finished.isEmpty {
                Section("Finished") {
                    ForEach(queue.finished) { item in
                        LabeledContent {
                            if let error = item.error {
                                Text(error).foregroundStyle(.orange)
                            } else {
                                Text(item.originalTrashed
                                     ? String(localized: "\(ConversionQueueView.time(item.elapsed)) · \(item.outputBytes.formatted(.byteCount(style: .file))) · original in Trash")
                                     : String(localized: "\(ConversionQueueView.time(item.elapsed)) · \(item.outputBytes.formatted(.byteCount(style: .file)))"))
                                    .foregroundStyle(.secondary)
                                    .monospacedDigit()
                            }
                        } label: {
                            Label {
                                Text(item.name).lineLimit(1)
                            } icon: {
                                Image(systemName: item.error == nil ? "checkmark.circle.fill" : "xmark.circle.fill")
                                    .foregroundStyle(item.error == nil ? .green : .orange)
                            }
                        }
                    }
                }
            }

            Section {
                ForEach(Array(queue.plans.enumerated()), id: \.element.id) { position, plan in
                    ConversionPlanRow(position: position + 1, plan: plan)
                }
            } header: {
                if !queue.plans.isEmpty {
                    Text("\(queue.plans.count) to convert · \(ConversionQueueView.time(queue.totalEstimate)) · \(queue.totalOutputBytes.formatted(.byteCount(style: .file)))")
                }
            } footer: {
                if !queue.plans.isEmpty {
                    Text("""
                        Shortest first, so the most of your library becomes watchable soonest. \
                        Estimates come from what conversions on this Mac have actually taken, \
                        and are re-measured after each one finishes. A film costing far more than \
                        Apple spends on the same picture is rebuilt to Apple’s own rate and loses \
                        its black bars; one already at or below it is copied untouched.
                        """)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                }
            }

            if !queue.failures.isEmpty {
                Section("Couldn’t Be Read") {
                    ForEach(queue.failures, id: \.name) { failure in
                        LabeledContent(failure.name) {
                            Text(failure.reason).foregroundStyle(.secondary)
                        }
                    }
                }
            }
        }
        .listStyle(.inset)
    }

    /// What's left of the running job, from how far it has actually got rather than from the
    /// estimate — an estimate is a prediction, and this is a measurement.
    private func remaining(for running: ConversionQueue.Running) -> String {
        let elapsed = Date.now.timeIntervalSince(running.started)
        guard running.fraction > 0.01 else {
            return String(localized: "estimated \(ConversionQueueView.time(running.plan.estimate.total))")
        }
        let projected = elapsed / running.fraction
        return String(localized: "\(Int(running.fraction * 100))% · about \(ConversionQueueView.time(projected - elapsed)) left")
    }

    private func startPlanning() {
        guard let folder else { return }
        planning?.cancel()
        planning = Task { await queue.plan(folder: folder) }
    }

    /// A duration in the terms this screen deals in — hours and minutes, never seconds.
    static func time(_ seconds: Double) -> String {
        let total = Int(seconds.rounded())
        let hours = total / 3600
        let minutes = (total % 3600) / 60
        if hours == 0 { return "\(max(minutes, 1)) min" }
        return "\(hours)h \(minutes)m"
    }
}

/// One film in the queue: what it is, what it will cost, and what it will lose.
private struct ConversionPlanRow: View {
    let position: Int
    let plan: ConversionPlan

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Text("\(position)")
                .font(.title3.monospacedDigit())
                .foregroundStyle(.tertiary)
                .frame(width: 22, alignment: .trailing)

            VStack(alignment: .leading, spacing: 4) {
                Text(plan.source.url.deletingPathExtension().lastPathComponent)
                    .font(.body.weight(.medium))
                    .lineLimit(1)

                Text(details)
                    .font(.footnote)
                    .foregroundStyle(.secondary)

                ForEach(plan.notes) { note in
                    Label {
                        Text(text(for: note))
                    } icon: {
                        Image(systemName: note.isLoss ? "exclamationmark.triangle.fill" : "checkmark.seal.fill")
                            .foregroundStyle(note.isLoss ? .orange : .green)
                    }
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                }
            }

            Spacer(minLength: 8)

            VStack(alignment: .trailing, spacing: 4) {
                Text(ConversionQueueView.time(plan.estimate.total))
                    .font(.body.monospacedDigit())
                Text(plan.estimate.outputBytes.formatted(.byteCount(style: .file)))
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 4)
    }

    private var details: String {
        let source = plan.source
        var parts: [String] = []
        if let encode = plan.route.encode {
            parts.append("\(encode.width)×\(encode.height)")
            if encode.isCropping {
                parts.append(String(localized: "cropped from \(source.height)"))
            }
            parts.append(String(localized: "\(encode.bitrate / 1_000_000) Mbps"))
        } else {
            parts.append(String(localized: "Copied — nothing re-encoded"))
        }
        if let dolbyVision = source.dolbyVision {
            parts.append(dolbyVision.needsConversion
                         ? String(localized: "Dolby Vision \(dolbyVision.profile) → 8.1")
                         : String(localized: "Dolby Vision 8.1"))
        } else if source.isHDR {
            parts.append("HDR10")
        }
        parts.append(ConversionQueueView.time(source.duration))
        return parts.joined(separator: " · ")
    }

    private func text(for note: ConversionPlan.Note) -> String {
        switch note {
        case .bitmapSubtitlesDropped(let languages):
            let names = languages.map { Locale.current.localizedString(forLanguageCode: $0) ?? $0 }
            let unique = Array(Set(names)).sorted()
            return String(localized: "\(languages.count) image subtitles dropped (\(unique.formatted(.list(type: .and))))")
        case .aspectRatioVaries:
            return String(localized: "The picture changes shape, so nothing is cropped")
        case .asymmetricLetterbox(let top, let bottom):
            return String(localized: "Uneven letterbox: \(top) above, \(bottom) below")
        case .audioNeedsTranscode(let codec, let channels, let outputChannels):
            let from = TrackPlan.layoutName(forChannels: channels)
            guard outputChannels < channels else {
                return String(localized: "\(from) \(codec.uppercased()) audio has to be re-encoded to play")
            }
            let to = TrackPlan.layoutName(forChannels: outputChannels)
            return String(localized: "\(from) \(codec.uppercased()) audio re-encoded to \(to) — the encoder here cannot write more than \(to)")
        case .atmosPreserved:
            return String(localized: "Dolby Atmos is carried over intact")
        case .atmosLost:
            return String(localized: "TrueHD Atmos can’t be carried; the surround track is used instead")
        case .dolbyVisionWouldFlatten:
            return String(localized: "Dolby Vision would be flattened to HDR10 — dovi_tool and MP4Box aren’t installed")
        case .enhancementLayerLost:
            return String(localized: "Its Dolby Vision enhancement layer carries picture detail that Apple’s format can’t hold, so that detail is lost")
        case .copyWouldNotRender:
            return String(localized: "Copying this film’s picture would leave its Dolby Vision unplayable on Apple devices, so it has to be re-encoded")
        case .matchedToApplesRate(let sourceMbps, let targetMbps):
            return String(localized: "Rebuilt to Apple’s own rate: \(Int(sourceMbps)) Mbps → \(Int(targetMbps)) Mbps")
        case .barsKeptToAvoidAnEncode(let extraSeconds):
            return String(localized: "Keeps its black bars — cropping them would mean re-encoding, and \(ConversionQueueView.time(extraSeconds)) longer")
        case .encodedOnlyToCrop:
            return String(localized: "Re-encoded only to remove its black bars; copying it would be far quicker")
        }
    }
}
#endif

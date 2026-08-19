#if os(macOS)
import Testing
import Foundation
@testable import Cinema

@Suite(.serialized, .enabled(if: ProcessInfo.processInfo.environment["CINEMA_PLAN"] != nil))
struct TempPlanAll {
    @Test @MainActor func planAll() async {
        let queue = ConversionQueue()
        await queue.plan(folder: URL(filePath: "/Users/nicolas/Documents/Downloads"))
        var bytes: Int64 = 0
        for (i, p) in queue.plans.enumerated() {
            let route: String
            switch p.route {
            case .rewrap: route = "copy"
            case .rebuildDolbyVision(let e): route = e == nil ? "copy + DV rebuild" : "encode \(e!.width)x\(e!.height) @\(e!.bitrate/1_000_000)Mbps"
            case .reencode(let e): route = "encode \(e.width)x\(e.height) @\(e.bitrate/1_000_000)Mbps"
            }
            bytes += p.estimate.outputBytes
            print("PLAN \(i+1). \(p.source.url.deletingPathExtension().lastPathComponent) | \(route) | \(Int(p.estimate.total/60))min | \(p.estimate.outputBytes/1_000_000_000)GB | \(p.notes.map(\.id))")
        }
        print("PLAN total \(Int(queue.totalEstimate/3600))h, \(bytes/1_000_000_000)GB")
    }
}
#endif

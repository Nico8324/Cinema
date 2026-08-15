/*
See the LICENSE.txt file for licensing information.

Abstract:
Helper extensions for SwiftData.
*/

import Foundation
import SwiftData

extension ModelContext {
    /// Saves the context, logging failures instead of silently swallowing them.
    /// A failing save (disk full, for example) is a real event for an app that
    /// stores a large local library — it must at least leave a trace.
    @discardableResult
    func saveReportingErrors() -> Bool {
        do {
            try save()
            return true
        } catch {
            logger.error("Couldn't save the video library: \(error.localizedDescription)")
            return false
        }
    }
}

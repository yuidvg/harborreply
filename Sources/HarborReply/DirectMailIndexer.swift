import Foundation

/// Source reading runs in a separate process with all filesystem writes denied.
/// The existing worker owns only the app's derived index, never a Mail writer.
@MainActor final class DirectMailIndexer {
    private let worker: LocalWorker
    init(worker: LocalWorker) { self.worker = worker }
    func run(restart: Bool, progress: (MailArchiveStatus) -> Void) async throws {
        let helper = Bundle.main.executableURL!.deletingLastPathComponent().appendingPathComponent("HarborMailReader")
        let root = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Mail")
        let first = try await worker.call("direct_start", ["helper": helper.path, "root": root.path])
        var status = try MailArchiveStatus.decode(first)
        let scan = status.scanID
        do {
            progress(status)
            while status.status == "running" {
                try Task.checkCancellation()
                status = try MailArchiveStatus.decode(await worker.call("direct_step", ["scan_id": scan]))
                progress(status)
            }
        } catch {
            let worker = worker
            _ = await Task.detached { try? await worker.call("direct_pause", ["scan_id": scan]) }.value
            throw error
        }
    }
}

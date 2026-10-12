import Foundation
import HarborCore

/// Serialized callers in the UI await this actor; Process IO never runs on the UI actor.
actor LocalWorker {
    private let transport = WorkerTransport()
    private var resources: (script: URL, python: String, allowedCodes: Set<String>)?
    let database: URL
    init(database: URL) { self.database = database }
    func call(_ command: String, _ payload: [String: Any] = [:]) async throws -> Any {
        guard let operation = LocalWorkerCommand(rawValue: command) else { throw AppFailure("WORKER_DISPATCH__UNKNOWN_COMMAND", location: .workerRequest) }
        func failure(_ cause: String, _ location: DiagnosticLocation) -> AppFailure {
            AppFailure("WORKER_" + operation.rawValue.uppercased() + "__" + cause, location: location, baseCode: cause)
        }
        var request = payload; request["command"] = command; request["db"] = database.path
        let data: Data
        do {
            let encodeTimer = DiagnosticTimer()
            defer { Diagnostics.timing(.workerEncode, started: encodeTimer, workerCommand: operation) }
            data = try JSONSerialization.data(withJSONObject: request)
        }
        catch { throw failure("IPC_REQUEST_INVALID", .workerRequest) }
        guard data.count <= 2 * 1024 * 1024 else { throw failure("LOCAL_INPUT_SIZE_LIMIT", .workerRequest) }
        if resources == nil {
            guard let script = Bundle.module.url(forResource: "main", withExtension: "py", subdirectory: "Resources/worker"),
                  let codes = Bundle.module.url(forResource: "failure_codes", withExtension: "json", subdirectory: "Resources/worker"),
                  let codeData = try? Data(contentsOf: codes),
                  let codeEnvelope = try? JSONSerialization.jsonObject(with: codeData) as? [String: Any],
                  codeEnvelope["version"] as? Int == 1, let codeList = codeEnvelope["codes"] as? [String] else {
                throw failure("WORKER_RESOURCE_MISSING", .workerRequest)
            }
            let runtime = Bundle.main.url(forResource: "runtime", withExtension: "json")
            let runtimeInfo = runtime.flatMap { try? Data(contentsOf: $0) }.flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: String] }
            #if arch(arm64)
            let architecture = "arm64"
            #else
            let architecture = "x86_64"
            #endif
            let bundled = Bundle.main.bundleURL.appendingPathComponent("Contents/Resources/python-\(architecture)/bin/python3")
            if Bundle.main.url(forResource: "runtime.lock", withExtension: "json") != nil && !FileManager.default.isExecutableFile(atPath: bundled.path) { throw failure("BUNDLED_RUNTIME_MISSING", .workerProcess) }
            let python = FileManager.default.isExecutableFile(atPath: bundled.path) ? bundled.path : runtimeInfo?["python"] ?? "/usr/bin/python3"
            resources = (script, python, Set(codeList))
        }
        guard let resources else { throw failure("WORKER_RESOURCE_MISSING", .workerRequest) }
        let allowedCodes = resources.allowedCodes
        let started = DiagnosticTimer()
        try Task.checkCancellation()
        let bytes: Data
        do { bytes = try await transport.request(data, python: resources.python, script: resources.script.path, operation: operation, queued: started) }
        catch is CancellationError { throw CancellationError() }
        catch { throw failure((error as? AppFailure)?.baseCode ?? "LOCAL_PROCESS_EXIT_FAILED", .workerProcess) }
        do {
            let decodeTimer = DiagnosticTimer()
            defer { Diagnostics.timing(.workerDecode, started: decodeTimer, workerCommand: operation) }
            guard bytes.count < 24_000_000 else { throw failure("LOCAL_OUTPUT_LIMIT", .workerResponse) }
            let value: Any
            do { value = try JSONSerialization.jsonObject(with: bytes) }
            catch { throw failure("LOCAL_RESPONSE_INVALID_JSON", .workerResponse) }
            guard let envelope = value as? [String: Any], let ok = envelope["ok"] as? Bool else { throw failure("LOCAL_RESPONSE_INVALID", .workerResponse) }
            guard ok else {
                let cause = envelope["error"] as? String ?? "LOCAL_OPERATION_FAILED"
                let safeCause = allowedCodes.contains(cause) ? cause : "LOCAL_OPERATION_FAILED"
                throw AppFailure(operation.failureCode(cause, allowed: allowedCodes), location: .workerResponse, baseCode: safeCause)
            }
            guard let result = envelope["result"] else { throw failure("LOCAL_RESPONSE_INVALID", .workerResponse) }
            Diagnostics.record(.workerCompleted, elapsed: Double(started.elapsedMilliseconds) / 1_000, location: .workerResponse)
            return result
        } catch {
            let scoped = error as? AppFailure
            Diagnostics.record(.workerFailed, failure: .localOperation, elapsed: Double(started.elapsedMilliseconds) / 1_000,
                               location: scoped?.location, failureCode: scoped?.diagnosticFailure ?? .unknown)
            throw error
        }
    }
}

private final class WorkerTimeout: @unchecked Sendable {
    private let lock = NSLock()
    private var expired = false
    func mark() { lock.lock(); defer { lock.unlock() }; expired = true }
    var didExpire: Bool { lock.lock(); defer { lock.unlock() }; return expired }
}

/// Owns a single private child and serializes framed requests without blocking
/// MainActor. No automatic replay: a lost response may have committed a write.
private actor WorkerTransport {
    private var process: Process?
    private var input: FileHandle?
    private var output: FileHandle?

    deinit {
        try? input?.close()
        if let process, process.isRunning { process.terminate() }
    }

    private func reset() {
        try? input?.close(); try? output?.close()
        if let process, process.isRunning { process.terminate() }
        process = nil; input = nil; output = nil
    }

    func request(_ data: Data, python: String, script: String, operation: LocalWorkerCommand, queued: DiagnosticTimer) throws -> Data {
        Diagnostics.timing(.workerQueueWait, started: queued, workerCommand: operation)
        try Task.checkCancellation()
        if process?.isRunning != true {
            reset()
            let child = Process(), stdin = Pipe(), stdout = Pipe()
            child.executableURL = URL(fileURLWithPath: python)
            child.arguments = ["-s", "-B", script, "--serve"]
            child.environment = ["PATH": "/usr/bin:/bin", "PYTHONNOUSERSITE": "1", "PYTHONDONTWRITEBYTECODE": "1", "LANG": "en_US.UTF-8"]
            child.standardInput = stdin; child.standardOutput = stdout; child.standardError = FileHandle.nullDevice
            let launch = DiagnosticTimer()
            do { try child.run() } catch { throw AppFailure("LOCAL_PROCESS_LAUNCH_FAILED") }
            Diagnostics.timing(.workerLaunch, started: launch, workerCommand: operation)
            process = child; input = stdin.fileHandleForWriting; output = stdout.fileHandleForReading
        }
        guard let child = process, let input, let output else { throw AppFailure("LOCAL_PROCESS_LAUNCH_FAILED") }
        let expired = WorkerTimeout(), timer = DiagnosticTimer()
        let timeout = DispatchWorkItem { if child.isRunning { expired.mark(); child.terminate() } }
        DispatchQueue.global().asyncAfter(deadline: .now() + 60, execute: timeout)
        defer { timeout.cancel(); Diagnostics.timing(.workerRequest, started: timer, workerCommand: operation) }
        // The child reads the entire bounded request before returning a response.
        // Independent writing avoids pipe deadlocks with an oversized rejection.
        DispatchQueue.global().async { try? input.write(contentsOf: data + Data([10])) }
        var bytes = Data()
        while true {
            let chunk = output.availableData
            if chunk.isEmpty {
                reset()
                throw AppFailure(expired.didExpire ? "LOCAL_WORKER_TIMEOUT" : "LOCAL_PROCESS_EXIT_FAILED")
            }
            bytes.append(chunk)
            guard bytes.count < 24_000_000 else { reset(); throw AppFailure("LOCAL_OUTPUT_LIMIT") }
            if bytes.last == 10 { bytes.removeLast(); return bytes }
        }
    }
}

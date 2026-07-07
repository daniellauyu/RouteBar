import Foundation

struct RuntimeManager {
    let paths: RuntimePaths

    init(settings: RouteBarSettings = RouteBarSettings.defaults()) {
        paths = RuntimePaths(settings: settings)
    }

    func status() -> ServiceState {
        let result = execute("/bin/launchctl", ["print", paths.launchctlTarget])
        return LaunchCtlStatusParser.parse(exitCode: result.0, output: result.1)
    }

    func restart() -> ServiceState {
        let result = execute("/bin/launchctl", ["kickstart", "-k", paths.launchctlTarget])
        return result.0 == 0 ? .running : .failed(result.1)
    }

    func stop() -> ServiceState {
        let result = execute("/bin/launchctl", ["bootout", paths.launchctlTarget])
        return result.0 == 0 ? .stopped : .failed(result.1)
    }

    func install(_ generated: GeneratedConfiguration) throws {
        let singBoxURL = paths.singBoxConfig
        let candidate = paths.home.appendingPathComponent(".config/sing-box/routebar-next.json")
        try generated.singBoxJSON.write(to: candidate, options: .atomic)
        let check = execute(paths.singBoxBinary.path, ["check", "-c", candidate.path])
        guard check.0 == 0 else { throw InstallError.validation(check.1) }

        try backup(singBoxURL)
        try generated.singBoxJSON.write(to: singBoxURL, options: .atomic)
        try? FileManager.default.removeItem(at: candidate)

        let surgeURL = paths.surgeProfile
        let profile = try String(contentsOf: surgeURL, encoding: .utf8)
        let updated = try SurgeProfileUpdater.update(profile, with: generated)
        try backup(surgeURL)
        try Data(updated.utf8).write(to: surgeURL, options: .atomic)
    }

    private func backup(_ url: URL) throws {
        guard FileManager.default.fileExists(atPath: url.path) else { return }
        let backup = url.appendingPathExtension("routebar-backup")
        try? FileManager.default.removeItem(at: backup)
        try FileManager.default.copyItem(at: url, to: backup)
    }

    private func execute(_ path: String, _ arguments: [String]) -> (Int32, String) {
        let process = Process(); let pipe = Pipe()
        process.executableURL = URL(fileURLWithPath: path); process.arguments = arguments
        process.standardOutput = pipe; process.standardError = pipe
        do { try process.run(); process.waitUntilExit() } catch { return (-1, error.localizedDescription) }
        return (process.terminationStatus, String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self))
    }

    enum InstallError: LocalizedError {
        case validation(String)
        var errorDescription: String? { switch self { case .validation(let output): "sing-box 配置校验失败：\(output)" } }
    }
}

struct LatencyTester {
    var testURL = URL(string: "https://www.gstatic.com/generate_204")!
    var timeout: TimeInterval = 8

    func test(_ mapped: [PortMappedNode], maximumConcurrency: Int = 6) async -> [String: LatencyRecord] {
        await withTaskGroup(of: (String, LatencyRecord).self, returning: [String: LatencyRecord].self) { group in
            var iterator = mapped.makeIterator()
            for _ in 0..<min(maximumConcurrency, mapped.count) {
                if let item = iterator.next() { group.addTask { await test(item) } }
            }
            var results: [String: LatencyRecord] = [:]
            while let result = await group.next() {
                results[result.0] = result.1
                if let item = iterator.next() { group.addTask { await test(item) } }
            }
            return results
        }
    }

    func test(_ mapped: PortMappedNode) async -> (String, LatencyRecord) {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = timeout
        configuration.connectionProxyDictionary = [
            "SOCKSEnable": true, "SOCKSProxy": "127.0.0.1", "SOCKSPort": mapped.localPort,
        ]
        let session = URLSession(configuration: configuration)
        let start = ContinuousClock.now
        do {
            let (_, response) = try await session.data(from: testURL)
            let elapsed = start.duration(to: .now)
            let milliseconds = Int(Double(elapsed.components.seconds) * 1000 + Double(elapsed.components.attoseconds) / 1e15)
            let code = (response as? HTTPURLResponse)?.statusCode ?? 0
            let outcome: LatencyOutcome = (200..<400).contains(code) ? .success : .httpFailed
            return (mapped.node.id, LatencyRecord(outcome: outcome, milliseconds: outcome == .success ? milliseconds : nil))
        } catch let error as URLError {
            let outcome: LatencyOutcome = error.code == .timedOut ? .timeout : .connectionFailed
            return (mapped.node.id, LatencyRecord(outcome: outcome, milliseconds: nil))
        } catch {
            return (mapped.node.id, LatencyRecord(outcome: .connectionFailed, milliseconds: nil))
        }
    }
}

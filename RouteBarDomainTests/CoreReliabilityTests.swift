import Foundation
import Testing
@testable import RouteBarDomain

struct CoreReliabilityTests {
    private func temporaryHome() throws -> URL {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("RouteBarTests-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    @Test func corruptSettingsAreNotOverwrittenAtInitialization() async throws {
        let home = try temporaryHome()
        defer { try? FileManager.default.removeItem(at: home) }
        let store = StateStore(home: home)
        try store.saveSettings(.defaults())
        let damaged = Data("{broken".utf8)
        try damaged.write(to: store.settingsURL)
        #expect(throws: (any Error).self) { try store.loadSettings() }
        let coordinator = SubscriptionCoordinator(stateStore: store)
        let state = await coordinator.snapshot()
        #expect(state.autoUpdatePaused)
        #expect(try Data(contentsOf: store.settingsURL) == damaged)
    }

    @Test func corruptStateBlocksLaterWrites() async throws {
        let home = try temporaryHome()
        defer { try? FileManager.default.removeItem(at: home) }
        let store = StateStore(home: home)
        try store.saveSettings(.defaults())
        let damaged = Data("not JSON".utf8)
        try damaged.write(to: store.stateURL)
        let coordinator = SubscriptionCoordinator(stateStore: store)
        let outcome = await coordinator.setAutoUpdatePaused(false)
        #expect(outcome.messages.contains { $0.level == .error })
        #expect(outcome.state.autoUpdatePaused)
        #expect(try Data(contentsOf: store.stateURL) == damaged)
    }

    @Test func failedStateSaveRollsBackEnablement() async throws {
        let home = try temporaryHome()
        defer { try? FileManager.default.removeItem(at: home) }
        let store = StateStore(home: home)
        let record = SubscriptionRecord(name: "test")
        try store.saveSettings(.defaults())
        try store.save(RouteBarState(subscriptions: [record], autoUpdatePaused: false))
        let coordinator = SubscriptionCoordinator(stateStore: store)
        // A directory cannot be atomically replaced by the state JSON file.
        try FileManager.default.removeItem(at: store.stateURL)
        try FileManager.default.createDirectory(at: store.stateURL, withIntermediateDirectories: false)
        let outcome = await coordinator.setSubscriptionEnabled(false, for: record.id)
        #expect(outcome.messages.contains { $0.level == .error })
        #expect(outcome.state.subscriptions.first?.isEnabled == true)
    }

    @Test func privateStorageKeepsPreviousSettingsBackup() throws {
        let home = try temporaryHome()
        defer { try? FileManager.default.removeItem(at: home) }
        let store = StateStore(home: home)
        let first = RouteBarSettings.defaults()
        try store.saveSettings(first)
        let previous = try Data(contentsOf: store.settingsURL)
        var second = first
        second.nodeNameTemplate = "changed"
        try store.saveSettings(second)
        let backup = store.settingsURL.appendingPathExtension("backup")
        #expect(try Data(contentsOf: backup) == previous)
        for url in [store.settingsURL, backup] {
            let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
            #expect((attributes[.posixPermissions] as? NSNumber)?.intValue == 0o600)
        }
    }

    @Test func logReaderRetainsPartialLineUntilCompleted() throws {
        let home = try temporaryHome()
        defer { try? FileManager.default.removeItem(at: home) }
        let file = home.appendingPathComponent("runtime.log")
        try Data("first\npart".utf8).write(to: file)
        let runtime = RuntimeManager()
        let first = runtime.readNewLines(of: file, from: 0)
        #expect(first.text == "first\n")
        #expect(first.offset == 6)
        let handle = try FileHandle(forWritingTo: file)
        try handle.seekToEnd()
        try handle.write(contentsOf: Data("ial\n".utf8))
        try handle.close()
        let second = runtime.readNewLines(of: file, from: first.offset)
        #expect(second.text == "partial\n")
        #expect(second.offset == 14)
    }

    @Test func archivedLogReadsOnlyRequestedTail() throws {
        let home = try temporaryHome()
        defer { try? FileManager.default.removeItem(at: home) }
        let archive = LogArchiveStore(directory: home)
        let date = Date()
        let lines = (0..<1000).map { index in
            SingBoxLogLine(timestamp: date, level: .info, category: "test", message: "line \(index)")
        }
        try archive.append(lines)
        let tail = archive.read(date, limit: 3)
        #expect(tail.map(\.message) == ["line 997", "line 998", "line 999"])
        #expect(archive.read(date, limit: 0).isEmpty)
    }

    @Test func commandTimeoutIsBounded() async throws {
        let start = Date()
        do {
            _ = try await CommandRunner(timeoutSeconds: 0.1).run("/bin/sleep", ["10"])
            Issue.record("Expected command timeout")
        } catch CommandError.timedOut { }
        #expect(Date().timeIntervalSince(start) < 5)
    }

    @Test func inheritedOutputPipeDoesNotWaitForever() async throws {
        let start = Date()
        do {
            _ = try await CommandRunner(timeoutSeconds: 1).run("/bin/sh", ["-c", "sleep 4 & exit 0"])
            Issue.record("Expected inherited pipe timeout")
        } catch CommandError.timedOut { }
        #expect(Date().timeIntervalSince(start) < 3.8)
    }
}

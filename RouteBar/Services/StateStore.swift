import Foundation

struct StateStore {
    let rootURL = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("RouteBar", isDirectory: true)

    var stateURL: URL { rootURL.appendingPathComponent("state.json") }
    var settingsURL: URL { rootURL.appendingPathComponent("settings.json") }
    var updateLogURL: URL { rootURL.appendingPathComponent("update.log") }
    var singBoxURL: URL { rootURL.appendingPathComponent("sing-box.json") }
    var surgeSnippetURL: URL { rootURL.appendingPathComponent("surge-proxies.conf") }

    func load() -> RouteBarState {
        guard let data = try? Data(contentsOf: stateURL) else { return RouteBarState() }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return (try? decoder.decode(RouteBarState.self, from: data)) ?? RouteBarState()
    }

    func save(_ state: RouteBarState) throws {
        try FileManager.default.createDirectory(at: rootURL, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(state).write(to: stateURL, options: .atomic)
    }

    func loadSettings() -> RouteBarSettings {
        guard let data = try? Data(contentsOf: settingsURL) else {
            return RouteBarSettings.defaults()
        }
        return (try? JSONDecoder().decode(RouteBarSettings.self, from: data)) ?? RouteBarSettings.defaults()
    }

    func saveSettings(_ settings: RouteBarSettings) throws {
        try FileManager.default.createDirectory(at: rootURL, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(settings).write(to: settingsURL, options: .atomic)
    }

    func loadUpdateLog() -> String {
        (try? String(contentsOf: updateLogURL, encoding: .utf8)) ?? ""
    }

    func saveUpdateLog(_ text: String) throws {
        try FileManager.default.createDirectory(at: rootURL, withIntermediateDirectories: true)
        try text.write(to: updateLogURL, atomically: true, encoding: .utf8)
    }

    func saveGenerated(_ generated: GeneratedConfiguration) throws {
        try FileManager.default.createDirectory(at: rootURL, withIntermediateDirectories: true)
        try generated.singBoxJSON.write(to: singBoxURL, options: .atomic)
        try Data(generated.surgeProxySection.utf8).write(to: surgeSnippetURL, options: .atomic)
    }
}

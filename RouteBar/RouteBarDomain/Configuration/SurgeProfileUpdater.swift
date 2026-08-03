import Foundation

/// 把生成的代理段写回 Surge 配置。
///
/// 只改 `[Proxy]` 整段和名为「sing-box 节点」的策略组这一行，其余（规则、DNS、
/// 用户自己加的策略组）原样保留——托管的是出口，不是整份配置。
public enum SurgeProfileUpdater {
    public nonisolated static func update(_ profile: String, with generated: GeneratedConfiguration) throws -> String {
        guard let proxyStart = profile.range(of: "[Proxy]"),
              let groupStart = profile.range(of: "[Proxy Group]", range: proxyStart.upperBound..<profile.endIndex) else {
            throw UpdateError.missingSection
        }
        var result = profile
        result.replaceSubrange(proxyStart.lowerBound..<groupStart.lowerBound, with: generated.surgeProxySection + "\n")
        // 名字直接取生成结果里的那一份，不从文本反推：命名规则可配置之后，
        // 按 `RouteBar ` 前缀过滤会漏掉全部自定义名字，策略组会变成空的。
        let names = generated.policyNames.map { "\"\($0)\"" }.joined(separator: ", ")
        let regex = try NSRegularExpression(pattern: #"(?m)^sing-box 节点\s*=.*$"#)
        if let match = regex.firstMatch(in: result, range: NSRange(result.startIndex..., in: result)),
           let range = Range(match.range, in: result) {
            result.replaceSubrange(range, with: "sing-box 节点 = select, \(names)")
        } else if let groups = result.range(of: "[Proxy Group]\n") {
            result.insert(contentsOf: "sing-box 节点 = select, \(names)\n", at: groups.upperBound)
        }
        return result
    }

    public enum UpdateError: LocalizedError {
        case missingSection
        public var errorDescription: String? { "Surge 配置缺少 [Proxy] 或 [Proxy Group] 段" }
    }
}

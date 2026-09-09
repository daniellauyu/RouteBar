import Foundation

/// 一次落地探测的结果。
///
/// 「落地」指的是流量**离开代理之后**在公网上呈现的身份：出口 IP 和它所在的国家。
/// 这和节点名里写的地区是两回事——机场给的名字是宣传语，改一个字符不需要动任何链路，
/// 而落地是可验证的事实。一个叫「新加坡 01」的节点落在香港，只有探测得出来。
public struct GeoRecord: Codable, Hashable, Sendable {
    public var outcome: GeoOutcome
    /// 出口 IP。探测失败时为空。
    public var ip: String
    /// ISO 3166-1 alpha-2 国家码，大写。探测成功但对端没给出地区时为空。
    public var countryCode: String
    public var measuredAt: Date

    public nonisolated init(outcome: GeoOutcome, ip: String = "", countryCode: String = "",
                            measuredAt: Date = .now) {
        self.outcome = outcome
        self.ip = ip
        self.countryCode = countryCode.uppercased()
        self.measuredAt = measuredAt
    }

    /// 国旗表情。由国家码算出来，不查表。
    ///
    /// 两个字母各自映射到「区域指示符号」码位（U+1F1E6 起，对应 A），并排放在一起就是
    /// 系统渲染的国旗。因此它对**任何**合法的两位国家码都成立，不需要维护一份会过时的
    /// 旗帜表——新出现的地区码也能自动显示。
    public nonisolated var flag: String {
        guard countryCode.count == 2 else { return "" }
        var result = ""
        for scalar in countryCode.unicodeScalars {
            guard let indicator = UnicodeScalar(0x1F1E6 + scalar.value - 65),
                  ("A"..."Z").contains(String(scalar)) else { return "" }
            result.unicodeScalars.append(indicator)
        }
        return result
    }

    /// 落地地区的显示名。取系统的地区名，因此中英文都不必自带词表。
    ///
    /// 认不出来的码原样返回，而不是显示「未知」：一个没见过的两位码本身就是信息，
    /// 换成「未知」反而把它抹掉了。
    ///
    /// 判合法性用的是 `isoRegions` 而**不是** `Locale.Region.isISORegion`——后者对 CLDR
    /// 里那个占位码 `ZZ` 也返回真，于是 `ZZ` 会被翻成「未知地区」这样一句正经的地区名，
    /// 看着像探测成功了。实测过：`Locale.Region("ZZ").isISORegion == true`。
    public nonisolated func regionName(locale: Locale = .current) -> String {
        guard !countryCode.isEmpty else { return "" }
        guard Self.assignedRegions.contains(countryCode),
              let name = locale.localizedString(forRegionCode: countryCode) else { return countryCode }
        return name
    }

    /// 真正分配出去的 ISO 3166-1 地区码。算一次存着——地区名在列表里逐行都要取。
    private nonisolated static let assignedRegions: Set<String> =
        Set(Locale.Region.isoRegions.map(\.identifier))

    /// 「🇸🇬 新加坡」这样的一行。国家码缺失时退回出口 IP。
    public nonisolated func label(locale: Locale = .current) -> String {
        let name = regionName(locale: locale)
        guard !name.isEmpty else { return ip }
        let flag = flag
        return flag.isEmpty ? name : "\(flag) \(name)"
    }

    public nonisolated func isStale(at date: Date = .now, maximumAge: TimeInterval = 86_400) -> Bool {
        date.timeIntervalSince(measuredAt) > maximumAge
    }
}

public enum GeoOutcome: String, Codable, Sendable {
    case success
    case failed

    public nonisolated var label: String {
        switch self {
        case .success: "已检测"
        case .failed: "检测失败"
        }
    }
}

/// Cloudflare 的 `cdn-cgi/trace` 响应解析。
///
/// 选它作为落地探测的对端，是因为它在这件事上的代价最小：不需要 key、没有速率限制、
/// 走 HTTPS，而且 Cloudflare 的边缘几乎在所有出口都连得通——这恰恰是最需要探测的
/// 那批线路的前提。代价是它只给出口 IP 和国家码，没有城市与 ISP；对「这个节点是不是
/// 真的在新加坡」这个问题，国家码已经够了。
///
/// 响应是一段 `key=value` 的纯文本，每行一对：
///
/// ```
/// fl=12a34
/// ip=203.0.113.7
/// loc=SG
/// colo=SIN
/// ```
public enum CloudflareTrace {
    public nonisolated static let endpoint = URL(string: "https://www.cloudflare.com/cdn-cgi/trace")!

    /// 解析出口 IP 与国家码。
    ///
    /// 拿不到 `ip` 就算失败：没有出口 IP 的响应说明这根本不是 trace 的输出
    /// （最常见的是被中间设备换成了一张门户页），此时那个 `loc` 即使有也不可信。
    public nonisolated static func parse(_ text: String) -> GeoRecord? {
        let fields = fields(in: text)
        guard let ip = fields["ip"], !ip.isEmpty else { return nil }
        // loc 偶尔会缺（对端判不出地区时给 XX 或干脆不给）。IP 拿到了就算成功，
        // 地区留空——半个答案也比把整次探测判成失败有用。
        let location = fields["loc"] ?? ""
        let countryCode = location.count == 2 && location != "XX" ? location : ""
        return GeoRecord(outcome: .success, ip: ip, countryCode: countryCode)
    }

    nonisolated static func fields(in text: String) -> [String: String] {
        var result: [String: String] = [:]
        for line in text.split(whereSeparator: \.isNewline) {
            guard let separator = line.firstIndex(of: "=") else { continue }
            let key = line[line.startIndex..<separator].trimmingCharacters(in: .whitespaces)
            let value = line[line.index(after: separator)...].trimmingCharacters(in: .whitespaces)
            guard !key.isEmpty, result[key] == nil else { continue }
            result[key] = value
        }
        return result
    }
}

import Foundation

enum AntigravityUsageMapper {
    private static let summaryKinds: [
        String: QuotaKind
    ] = [
        "gemini-5h": .session,
        "gemini-weekly": .weekly,
        "3p-5h": .claudePool,
        "3p-weekly": .claudePoolWeekly
    ]

    static func summary(
        _ data: Data,
        planName: String?,
        now: Date
    ) -> ProviderSnapshot? {
        guard let root = try? ProviderParsing.object(from: data),
              let container = ProviderParsing.object(root["response"])
                ?? Optional(root),
              let groups = container["groups"] as? [[String: Any]]
        else {
            return nil
        }
        var windows: [QuotaWindow] = []
        for group in groups {
            for bucket in ProviderParsing.array(group["buckets"]) {
                guard let identifier = ProviderParsing.string(
                    bucket["bucketId"]
                ),
                    let kind = summaryKinds[identifier],
                    let remaining = ProviderParsing.double(
                        bucket["remainingFraction"]
                    ),
                    remaining.isFinite, (0...1).contains(remaining),
                    !windows.contains(where: { $0.kind == kind })
                else {
                    continue
                }
                windows.append(QuotaWindow(
                    kind: kind,
                    usedPercent: clamp((1 - remaining) * 100).rounded(),
                    resetsAt: ProviderParsing.date(bucket["resetTime"])
                ))
            }
        }
        guard !windows.isEmpty else { return nil }
        return ProviderSnapshot(
            provider: .antigravity,
            planName: planName,
            windows: ordered(windows),
            fetchedAt: now
        )
    }

    // Model quotas do not identify a five-hour or weekly window. Keep them
    // separate from authoritative summary buckets and never replace those.
    static func supplementGemini(
        _ snapshot: ProviderSnapshot?,
        modelsData: Data,
        planName: String?,
        now: Date
    ) -> ProviderSnapshot? {
        if let snapshot, snapshot.windows.contains(where: {
            $0.kind == .session || $0.kind == .weekly
        }) {
            return snapshot
        }
        guard let root = try? ProviderParsing.object(from: modelsData),
              let models = root["models"] as? [String: Any]
        else {
            return snapshot
        }
        var candidates: [(remaining: Double, reset: Date)] = []
        for (identifier, rawModel) in models {
            guard let model = ProviderParsing.object(rawModel),
                  model["isInternal"] as? Bool != true,
                  identifier.lowercased().hasPrefix("gemini-"),
                  let quota = ProviderParsing.object(model["quotaInfo"]),
                  let remaining = ProviderParsing.double(quota["remainingFraction"]),
                  remaining.isFinite, (0...1).contains(remaining),
                  let reset = ProviderParsing.date(quota["resetTime"]),
                  reset > now
            else {
                continue
            }
            candidates.append((remaining, reset))
        }
        // Some accounts receive fabricated all-full model quotas. Without
        // evidence of consumption, do not present that response as zero usage.
        guard let worst = candidates.min(by: { $0.remaining < $1.remaining }),
              worst.remaining < 1 else {
            return snapshot
        }
        var windows = snapshot?.windows ?? []
        windows.append(QuotaWindow(
            kind: .geminiModels,
            usedPercent: clamp((1 - worst.remaining) * 100).rounded(),
            resetsAt: worst.reset
        ))
        return ProviderSnapshot(
            provider: .antigravity,
            planName: planName,
            windows: ordered(windows),
            fetchedAt: now
        )
    }

    static func plan(_ data: Data?) -> String? {
        guard let data,
              let root = try? ProviderParsing.object(from: data)
        else {
            return nil
        }
        let tier = ProviderParsing.object(root["paidTier"])
            ?? ProviderParsing.object(root["currentTier"])
        guard let raw = ProviderParsing.string(tier?["name"]) else {
            return nil
        }
        for name in ["Ultra", "Pro", "Free"]
        where raw.localizedCaseInsensitiveContains(name) {
            return name
        }
        return ProviderParsing.titleCaseIdentifier(raw)
    }

    private static func ordered(
        _ windows: [QuotaWindow]
    ) -> [QuotaWindow] {
        let order: [QuotaKind] = [
            .session, .weekly, .geminiModels, .claudePool, .claudePoolWeekly
        ]
        return windows.sorted {
            (order.firstIndex(of: $0.kind) ?? 99)
                < (order.firstIndex(of: $1.kind) ?? 99)
        }
    }

    private static func clamp(_ value: Double) -> Double {
        min(max(value, 0), 100)
    }
}

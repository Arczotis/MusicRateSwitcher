import Foundation

public enum SampleRateMatcher {
    public static let commonRates: [Double] = [
        8_000, 11_025, 12_000, 16_000, 22_050, 24_000, 32_000,
        44_100, 48_000, 88_200, 96_000, 176_400, 192_000,
        352_800, 384_000, 705_600, 768_000
    ]

    public static func bestRate(for source: Double, supported candidates: [Double]) -> Double? {
        let rates = Array(Set(candidates.filter { $0 > 0 })).sorted()
        guard !rates.isEmpty else { return nil }
        if let exact = rates.first(where: { approximatelyEqual($0, source) }) { return exact }

        let familyBase = is44Family(source) ? 44_100.0 : 48_000.0
        let sameFamily = rates.filter { rate in
            let ratio = rate / familyBase
            return abs(ratio.rounded() - ratio) < 0.0001 || abs((1 / ratio).rounded() - (1 / ratio)) < 0.0001
        }
        if let lower = sameFamily.filter({ $0 < source }).max() { return lower }
        if let higher = sameFamily.filter({ $0 > source }).min() { return higher }

        return rates.min(by: { abs($0 - source) < abs($1 - source) })
    }

    private static func is44Family(_ rate: Double) -> Bool {
        let ratio44 = rate / 44_100.0
        let ratio48 = rate / 48_000.0
        let distance44 = abs(ratio44 - ratio44.rounded())
        let distance48 = abs(ratio48 - ratio48.rounded())
        return distance44 <= distance48
    }

    private static func approximatelyEqual(_ lhs: Double, _ rhs: Double) -> Bool {
        abs(lhs - rhs) < 0.5
    }
}

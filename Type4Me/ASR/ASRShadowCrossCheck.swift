import Foundation

/// Compares the fast streaming transcript with the local Apple shadow result.
/// The shadow is not used as user-visible text. It only decides whether the
/// primary recognizer must re-run once with the complete recording.
enum ASRShadowCrossCheck {
    struct Decision: Equatable, Sendable {
        let shouldRetryWithFullAudio: Bool
        let primaryCharacterCount: Int
        let shadowCharacterCount: Int
        let lengthRatio: Double
        let normalizedDistance: Double
        let reason: String
    }

    private static let minimumShadowCharacters = 8
    private static let minimumLengthRatio = 0.92
    private static let maximumLengthRatio = 1.12
    private static let maximumNormalizedDistance = 0.32

    static func evaluate(primary: String, shadow: String) -> Decision {
        let normalizedPrimary = normalize(primary)
        let normalizedShadow = normalize(shadow)
        let primaryCount = normalizedPrimary.count
        let shadowCount = normalizedShadow.count
        let ratio = shadowCount > 0
            ? Double(primaryCount) / Double(shadowCount)
            : 1
        let distance = normalizedEditDistance(normalizedPrimary, normalizedShadow)

        guard shadowCount >= minimumShadowCharacters else {
            return Decision(
                shouldRetryWithFullAudio: false,
                primaryCharacterCount: primaryCount,
                shadowCharacterCount: shadowCount,
                lengthRatio: ratio,
                normalizedDistance: distance,
                reason: "shadow_too_short"
            )
        }

        let reason: String
        if ratio < minimumLengthRatio {
            reason = "primary_missing_content"
        } else if ratio > maximumLengthRatio {
            reason = "primary_repeated_content"
        } else if max(primaryCount, shadowCount) >= 20,
                  distance > maximumNormalizedDistance {
            reason = "transcripts_diverged"
        } else {
            reason = "consistent"
        }

        return Decision(
            shouldRetryWithFullAudio: reason != "consistent",
            primaryCharacterCount: primaryCount,
            shadowCharacterCount: shadowCount,
            lengthRatio: ratio,
            normalizedDistance: distance,
            reason: reason
        )
    }

    private static func normalize(_ text: String) -> String {
        let digitMap: [Unicode.Scalar: Unicode.Scalar] = [
            "0": "零", "1": "一", "2": "二", "3": "三", "4": "四",
            "5": "五", "6": "六", "7": "七", "8": "八", "9": "九",
        ]
        let ignored = CharacterSet.whitespacesAndNewlines
            .union(.punctuationCharacters)
            .union(.symbols)
        let scalars = text.lowercased().unicodeScalars.compactMap { scalar -> Unicode.Scalar? in
            if let mapped = digitMap[scalar] { return mapped }
            return ignored.contains(scalar) ? nil : scalar
        }
        return String(String.UnicodeScalarView(scalars))
    }

    private static func normalizedEditDistance(_ lhs: String, _ rhs: String) -> Double {
        let left = Array(lhs)
        let right = Array(rhs)
        let denominator = max(left.count, right.count)
        guard denominator > 0 else { return 0 }

        var previous = Array(0...right.count)
        for (leftIndex, leftCharacter) in left.enumerated() {
            var current = [leftIndex + 1]
            current.reserveCapacity(right.count + 1)
            for (rightIndex, rightCharacter) in right.enumerated() {
                current.append(min(
                    current[rightIndex] + 1,
                    previous[rightIndex + 1] + 1,
                    previous[rightIndex] + (leftCharacter == rightCharacter ? 0 : 1)
                ))
            }
            previous = current
        }
        return Double(previous[right.count]) / Double(denominator)
    }
}

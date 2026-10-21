import Foundation

/// Paragraph base direction, resolved the same way HTML dir="auto" does:
/// from the first strong-directional character (Unicode UAX #9 rules P2/P3).
enum BidiDirection {
    case leftToRight
    case rightToLeft
    case neutral

    /// Scans for the first strong character. RTL scripts are matched by
    /// block; any other letter counts as strong LTR. Digits, punctuation and
    /// whitespace are weak/neutral and skipped — exactly like dir="auto".
    ///
    /// Only the letters in an RTL block are strong. The same blocks hold
    /// Arabic-Indic digits (weak), combining marks, the Arabic comma and the
    /// byte-order mark (U+FEFF, at the end of presentation forms B); counting
    /// those set "١٢ apples", or a CSV header behind a BOM, right-to-left.
    static func firstStrong<S: StringProtocol>(in text: S) -> BidiDirection {
        for scalar in text.unicodeScalars {
            switch scalar.value {
            case 0x200E:                    // LRM
                return .leftToRight
            case 0x200F, 0x061C:            // RLM, Arabic letter mark
                return .rightToLeft
            case 0x0590...0x08FF,           // Hebrew, Arabic, Syriac, Thaana, NKo, Samaritan, Mandaic, Arabic Extended
                 0xFB1D...0xFDFF,           // Hebrew + Arabic presentation forms A
                 0xFE70...0xFEFF,           // Arabic presentation forms B
                 0x10800...0x10FFF,         // historic RTL scripts
                 0x1E800...0x1EEBB:         // Adlam, Mende Kikakui, Arabic math symbols
                if isLetter(scalar) { return .rightToLeft }
            default:
                if isLetter(scalar) { return .leftToRight }
            }
        }
        return .neutral
    }

    private static func isLetter(_ scalar: Unicode.Scalar) -> Bool {
        switch scalar.properties.generalCategory {
        case .uppercaseLetter, .lowercaseLetter, .titlecaseLetter,
             .modifierLetter, .otherLetter:
            return true
        default:
            return false
        }
    }
}

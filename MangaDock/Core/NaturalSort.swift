import Foundation

/// Sorts "第2话" before "第10话" — plain string compare gets this wrong and
/// comic readers live or die by page order.
enum NaturalSort {
    enum Token: Equatable {
        case number(Int)
        case text(String)
    }

    static func less(_ lhs: String, _ rhs: String) -> Bool {
        let left = tokens(lhs.lowercased())
        let right = tokens(rhs.lowercased())

        var index = 0
        while index < left.count && index < right.count {
            switch (left[index], right[index]) {
            case let (.number(a), .number(b)):
                if a != b { return a < b }
            case let (.text(a), .text(b)):
                if a != b { return a < b }
            case (.number, .text):
                return true
            case (.text, .number):
                return false
            }
            index += 1
        }
        if left.count != right.count { return left.count < right.count }
        return lhs < rhs
    }

    static func tokens(_ string: String) -> [Token] {
        var result: [Token] = []
        var buffer = ""
        var numberBuffer = ""
        var inNumber = false

        func flushText() {
            if !buffer.isEmpty {
                result.append(.text(buffer))
                buffer = ""
            }
        }
        func flushNumber() {
            if !numberBuffer.isEmpty {
                let digits = numberBuffer.drop(while: { $0 == "0" })
                let trimmed = digits.isEmpty ? "0" : String(digits)
                // Guard against absurdly long digit runs overflowing Int.
                let value = trimmed.count > 9 ? Int.max - 1 : (Int(trimmed) ?? 0)
                result.append(.number(value))
                numberBuffer = ""
            }
        }

        for character in string {
            if character.isNumber {
                if !inNumber {
                    flushText()
                    inNumber = true
                }
                numberBuffer.append(character)
            } else {
                if inNumber {
                    flushNumber()
                    inNumber = false
                }
                buffer.append(character)
            }
        }
        flushNumber()
        flushText()
        return result
    }
}

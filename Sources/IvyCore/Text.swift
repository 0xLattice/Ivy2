/// Text helpers that need no more than the standard library. Full
/// Foundation brings tens of megabytes of Unicode data with it, which a
/// WebAssembly build of the core cannot afford; these keep the core on
/// FoundationEssentials alone.

public func hexByte(_ value: UInt8) -> String {
    let digits: [Character] = Array("0123456789abcdef")
    return String([digits[Int(value >> 4)], digits[Int(value & 0x0f)]])
}

func hexByte(_ value: Int) -> String {
    hexByte(UInt8(truncatingIfNeeded: value))
}

func hexWord(_ value: UInt16) -> String {
    hexByte(UInt8(value >> 8)) + hexByte(UInt8(value & 0xff))
}

/// `string` split at every "::", as `components(separatedBy:)` splits it.
func splitOnDoubleColon(_ string: String) -> [String] {
    var parts: [String] = []
    var current = ""
    var rest = Substring(string)
    while let first = rest.first {
        if first == ":", rest.dropFirst().first == ":" {
            parts.append(current)
            current = ""
            rest = rest.dropFirst(2)
        } else {
            current.append(first)
            rest = rest.dropFirst()
        }
    }
    parts.append(current)
    return parts
}

func isWhitespaceOrNewline(_ scalar: Unicode.Scalar) -> Bool {
    scalar.properties.isWhitespace || scalar.value == 0x200B
}

extension StringProtocol {
    /// Without leading and trailing whitespace and newlines: the scalars
    /// `CharacterSet.whitespacesAndNewlines` holds. Those are the ones with
    /// Unicode's White_Space property, and the zero-width space.
    func trimmingWhitespace() -> String {
        var scalars = Substring(self).unicodeScalars
        while let first = scalars.first, isWhitespaceOrNewline(first) { scalars.removeFirst() }
        while let last = scalars.last, isWhitespaceOrNewline(last) { scalars.removeLast() }
        return String(Substring(scalars))
    }
}

/// The string `bytes` spell in UTF-8, or nil if they are not valid UTF-8.
/// A leading byte-order mark is dropped, as Foundation's decoder drops it.
func validUTF8String(_ bytes: some Sequence<UInt8>) -> String? {
    var decoder = UTF8()
    var iterator = bytes.makeIterator()
    var scalars = String.UnicodeScalarView()
    var atStart = true
    while true {
        switch decoder.decode(&iterator) {
        case .scalarValue(let scalar):
            defer { atStart = false }
            if atStart, scalar.value == 0xFEFF { continue }
            scalars.append(scalar)
        case .emptyInput:
            return String(scalars)
        case .error:
            return nil
        }
    }
}

import Foundation

public enum CompanionFrame {
    public enum Failure: Error, Equatable {
        case invalidHeader, empty, tooLarge
    }

    public static func payloadLength(_ header: Data, maximum: Int) throws(Failure) -> Int {
        guard header.count == 4 else { throw .invalidHeader }
        let length = header.reduce(UInt32(0)) { ($0 << 8) | UInt32($1) }
        guard length > 0 else { throw .empty }
        guard length <= maximum else { throw .tooLarge }
        return Int(length)
    }

    public static func encode(_ payload: Data, maximum: Int) throws(Failure) -> Data {
        guard !payload.isEmpty else { throw .empty }
        guard payload.count <= maximum, let length = UInt32(exactly: payload.count) else { throw .tooLarge }
        var bigEndian = length.bigEndian
        var frame = withUnsafeBytes(of: &bigEndian) { Data($0) }
        frame.append(payload)
        return frame
    }
}

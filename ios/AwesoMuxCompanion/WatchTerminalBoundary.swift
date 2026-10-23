import Foundation

// Tracks parser boundaries only. Modes are read from libghostty reports.
struct WatchTerminalBoundary {
    private enum State {
        case ground, escape, escapeIntermediate, csi, osc, apc
        case dcsEntry, dcsParam, dcsIntermediate, dcsIgnore, dcsPassthrough
    }
    private var state = State.ground
    private var utf8Remaining = 0
    var canProbe: Bool { state == .ground && utf8Remaining == 0 }

    mutating func receive(_ bytes: Data) {
        for byte in bytes { receive(byte) }
    }

    private mutating func receive(_ byte: UInt8) {
        if state == .ground {
            if utf8Remaining > 0 {
                if (0x80...0xbf).contains(byte) { utf8Remaining -= 1; return }
                utf8Remaining = 0
            }
            switch byte {
            case 0xc2...0xdf: utf8Remaining = 1; return
            case 0xe0...0xef: utf8Remaining = 2; return
            case 0xf0...0xf4: utf8Remaining = 3; return
            default: break
            }
        }
        // Ghostty's parser treats ESC and CAN/SUB as global transitions,
        // including inside OSC/DCS. High bytes inside strings are payload.
        if byte == 0x1b { state = .escape; return }
        if byte == 0x18 || byte == 0x1a { state = .ground; return }
        if state != .ground, state != .osc, state != .dcsIgnore, state != .dcsPassthrough,
           (0x80...0x9f).contains(byte) {
            switch byte {
            case 0x9b: state = .csi
            case 0x9d: state = .osc
            case 0x90: state = .dcsEntry
            case 0x98, 0x9e, 0x9f: state = .apc
            default: state = .ground
            }
            return
        }
        switch state {
        case .ground: break
        case .escape:
            switch byte {
            case 0x5b: state = .csi
            case 0x5d: state = .osc
            case 0x50: state = .dcsEntry
            case 0x58, 0x5e, 0x5f: state = .apc
            case 0x20...0x2f: state = .escapeIntermediate
            case 0x30...0x7e: state = .ground
            default: break
            }
        case .escapeIntermediate:
            if (0x30...0x7e).contains(byte) { state = .ground }
        case .csi:
            if (0x40...0x7e).contains(byte) { state = .ground }
        case .osc:
            if byte == 7 { state = .ground }
        case .dcsEntry:
            switch byte {
            case 0x20...0x2f: state = .dcsIntermediate
            case 0x3a: state = .dcsIgnore
            case 0x30...0x39, 0x3b...0x3f: state = .dcsParam
            case 0x40...0x7e: state = .dcsPassthrough
            default: break
            }
        case .dcsParam:
            switch byte {
            case 0x20...0x2f: state = .dcsIntermediate
            case 0x3a, 0x3c...0x3f: state = .dcsIgnore
            case 0x40...0x7e: state = .dcsPassthrough
            default: break
            }
        case .dcsIntermediate:
            if (0x30...0x3f).contains(byte) { state = .dcsIgnore }
            else if (0x40...0x7e).contains(byte) { state = .dcsPassthrough }
        case .apc, .dcsIgnore, .dcsPassthrough: break
        }
    }

}

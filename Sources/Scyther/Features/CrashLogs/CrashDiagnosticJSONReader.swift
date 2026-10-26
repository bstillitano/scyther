//
//  CrashDiagnosticJSONReader.swift
//  Scyther
//
//  Created by Brandon Stillitano on 26/10/26.
//

#if !os(macOS)
import Foundation

/// Reads a MetricKit crash diagnostic's JSON: its threads and frames, and its metadata.
///
/// The call stack tree nests each frame inside the frame above it, two JSON levels per frame.
/// `JSONDecoder` and `JSONSerialization` both refuse input nested more than 512 levels deep, which
/// is about 256 frames — and a stack overflow, exactly the crash a developer most needs to see, is
/// deeper than that. Either of them would lose the whole diagnostic, metadata and all. So this reads
/// the JSON as a stream of tokens instead, keeping only a stack of the containers it is inside. It
/// never builds the nested values, and nothing in it recurses.
///
/// It reads `MXCrashDiagnostic.jsonRepresentation()` and `MXCallStackTree.jsonRepresentation()`
/// alike: the threads are found under any `callStacks` key.
///
/// iOS 27 adds a typed `CallStackTree`, but the deployment target is iOS 16.
enum CrashDiagnosticJSONReader {
    /// What the reader found.
    struct Document: Equatable, Sendable {
        /// Every thread in the call stack tree.
        var threads: [Thread] = []

        /// Every string, number and boolean outside an array, by its dotted key path, such as
        /// `diagnosticMetaData.signal`. Numbers keep their JSON text.
        var values: [String: String] = [:]
    }

    /// One thread in the tree.
    struct Thread: Equatable, Sendable {
        /// Whether the crash is attributed to this thread.
        var isAttributed = false

        /// The thread's frames, top of the stack first.
        var frames: [Frame] = []
    }

    /// One frame.
    struct Frame: Equatable, Sendable {
        var binaryUUID: String?
        var binaryName: String?
        var offsetIntoBinaryTextSegment: UInt64?
        var address: UInt64?

        /// The frame's offset into its binary.
        ///
        /// Despite its name, MetricKit has been seen to put the binary's *load address* in
        /// `offsetIntoBinaryTextSegment`, alongside the frame's absolute `address`. A load address
        /// on arm64 is never below 4 GB, the size of `__PAGEZERO`, and a real offset into one
        /// binary always is, so a value that large is taken as the load address and the offset
        /// recovered from the two.
        var resolvedOffset: UInt64 {
            let field = offsetIntoBinaryTextSegment ?? 0
            if let address, field >= 0x1_0000_0000, address >= field {
                return address - field
            }
            return field
        }
    }

    /// Reads a diagnostic, or a call stack tree on its own.
    ///
    /// Frames are recorded in the order their objects open, which for this tree is top of the stack
    /// first: a thread's root frame, then the frame that called it, and so on. A frame's fields are
    /// filled in whenever they appear, before or after its `subFrames`.
    ///
    /// - Parameter data: The JSON.
    /// - Returns: What was found, or `nil` if the data is not a well-formed JSON object.
    static func read(_ data: Data) -> Document? {
        guard data.first(where: { ![0x20, 0x09, 0x0A, 0x0D].contains($0) }) == UInt8(ascii: "{") else {
            return nil
        }
        var reader = Reader(bytes: [UInt8](data))
        return reader.read()
    }

    /// What an open container is, for the parts of the tree that matter.
    private enum Role {
        case thread(Int)
        case frame(thread: Int, index: Int)
        case other
    }

    /// An open object or array.
    private enum Container {
        /// An object, with the key whose value is being read, if any, and its own key path — `nil`
        /// for an object inside an array, whose members are not collected.
        case object(role: Role, key: String?, path: String?)

        /// An array, with the key it is the value of.
        case array(owner: String?)
    }

    /// A scalar value.
    private enum Scalar {
        case string(String)
        case number(String)
        case bool(Bool)
        case null
    }

    private struct Reader {
        let bytes: [UInt8]
        var position = 0
        var stack: [Container] = []
        var threads: [Thread] = []
        var values: [String: String] = [:]

        init(bytes: [UInt8]) {
            self.bytes = bytes
        }

        mutating func read() -> Document? {
            while true {
                skipWhitespace()
                guard position < bytes.count else { break }
                let byte = bytes[position]
                switch byte {
                case UInt8(ascii: "{"):
                    position += 1
                    openObject()
                case UInt8(ascii: "["):
                    position += 1
                    stack.append(.array(owner: currentKey))
                case UInt8(ascii: "}"), UInt8(ascii: "]"):
                    position += 1
                    guard stack.popLast() != nil else { return nil }
                    finishValue()
                case UInt8(ascii: ","), UInt8(ascii: ":"):
                    position += 1
                case UInt8(ascii: "\""):
                    guard let string = readString() else { return nil }
                    if case .object(let role, nil, let path)? = stack.last {
                        stack[stack.count - 1] = .object(role: role, key: string, path: path)
                    } else {
                        assign(.string(string))
                    }
                case UInt8(ascii: "t"):
                    guard consume("true") else { return nil }
                    assign(.bool(true))
                case UInt8(ascii: "f"):
                    guard consume("false") else { return nil }
                    assign(.bool(false))
                case UInt8(ascii: "n"):
                    guard consume("null") else { return nil }
                    assign(.null)
                case UInt8(ascii: "-"), UInt8(ascii: "0")...UInt8(ascii: "9"):
                    assign(.number(readNumber()))
                default:
                    return nil
                }
            }
            return stack.isEmpty ? Document(threads: threads, values: values) : nil
        }

        /// The key whose value is about to be read: the object's current key, or the key of the
        /// array the value is an element of.
        private var currentKey: String? {
            switch stack.last {
            case .object(_, let key, _)?: return key
            case .array(let owner)?: return owner
            case nil: return nil
            }
        }

        /// The thread the reader is inside, if any.
        private var currentThread: Int? {
            for container in stack.reversed() {
                if case .object(.thread(let index), _, _) = container { return index }
            }
            return nil
        }

        private mutating func openObject() {
            var role = Role.other
            var path: String?
            switch stack.last {
            case nil: path = ""
            case .object(_, let key, let parent)?: path = parent.map { Self.join($0, key ?? "") }
            case .array?: path = nil
            }
            if case .array(let owner)? = stack.last {
                if owner == "callStacks" {
                    threads.append(Thread())
                    role = .thread(threads.count - 1)
                } else if owner == "callStackRootFrames" || owner == "subFrames", let thread = currentThread {
                    threads[thread].frames.append(Frame())
                    role = .frame(thread: thread, index: threads[thread].frames.count - 1)
                }
            }
            stack.append(.object(role: role, key: nil, path: path))
        }

        /// A value has been read in full. If it was an object's member, the object's key is spent.
        private mutating func finishValue() {
            if case .object(let role, _, let path)? = stack.last {
                stack[stack.count - 1] = .object(role: role, key: nil, path: path)
            }
        }

        private mutating func assign(_ scalar: Scalar) {
            defer { finishValue() }
            guard case .object(let role, let key?, let path)? = stack.last else { return }
            if let path {
                switch scalar {
                case .string(let value), .number(let value): values[Self.join(path, key)] = value
                case .bool(let value): values[Self.join(path, key)] = value ? "true" : "false"
                case .null: break
                }
            }
            switch role {
            case .thread(let index):
                if key == "threadAttributed", case .bool(let value) = scalar {
                    threads[index].isAttributed = value
                }
            case .frame(let thread, let index):
                switch (key, scalar) {
                case ("binaryUUID", .string(let value)): threads[thread].frames[index].binaryUUID = value
                case ("binaryName", .string(let value)): threads[thread].frames[index].binaryName = value
                case ("offsetIntoBinaryTextSegment", .number(let value)):
                    threads[thread].frames[index].offsetIntoBinaryTextSegment = Self.unsigned(value)
                case ("address", .number(let value)): threads[thread].frames[index].address = Self.unsigned(value)
                default: break
                }
            case .other:
                break
            }
        }

        private mutating func skipWhitespace() {
            while position < bytes.count, [0x20, 0x09, 0x0A, 0x0D].contains(bytes[position]) {
                position += 1
            }
        }

        private mutating func consume(_ literal: String) -> Bool {
            let literal = Array(literal.utf8)
            guard position + literal.count <= bytes.count,
                  Array(bytes[position..<position + literal.count]) == literal else { return false }
            position += literal.count
            return true
        }

        private mutating func readNumber() -> String {
            let start = position
            while position < bytes.count,
                  "+-.eE0123456789".utf8.contains(bytes[position]) {
                position += 1
            }
            return String(decoding: bytes[start..<position], as: UTF8.self)
        }

        /// Reads a string, starting at its opening quote.
        private mutating func readString() -> String? {
            position += 1
            var scalars = String.UnicodeScalarView()
            var raw: [UInt8] = []

            func flush() {
                scalars.append(contentsOf: String(decoding: raw, as: UTF8.self).unicodeScalars)
                raw.removeAll(keepingCapacity: true)
            }

            while position < bytes.count {
                let byte = bytes[position]
                position += 1
                switch byte {
                case UInt8(ascii: "\""):
                    flush()
                    return String(scalars)
                case UInt8(ascii: "\\"):
                    guard position < bytes.count else { return nil }
                    let escaped = bytes[position]
                    position += 1
                    flush()
                    switch escaped {
                    case UInt8(ascii: "n"): scalars.append("\n")
                    case UInt8(ascii: "t"): scalars.append("\t")
                    case UInt8(ascii: "r"): scalars.append("\r")
                    case UInt8(ascii: "b"): scalars.append("\u{08}")
                    case UInt8(ascii: "f"): scalars.append("\u{0C}")
                    case UInt8(ascii: "u"):
                        guard position + 4 <= bytes.count,
                              let code = UInt32(String(decoding: bytes[position..<position + 4], as: UTF8.self), radix: 16)
                        else { return nil }
                        position += 4
                        scalars.append(Unicode.Scalar(code) ?? "\u{FFFD}")
                    default: scalars.append(Unicode.Scalar(escaped))
                    }
                default:
                    raw.append(byte)
                }
            }
            return nil
        }

        /// A key path with one more key on the end.
        private static func join(_ path: String, _ key: String) -> String {
            path.isEmpty ? key : "\(path).\(key)"
        }

        /// A JSON number as an unsigned integer. Addresses are integers, but a number written with
        /// an exponent is accepted too.
        private static func unsigned(_ text: String) -> UInt64? {
            if let value = UInt64(text) { return value }
            guard let value = Double(text), value >= 0, value < 0x1p64 else { return nil }
            return UInt64(value)
        }
    }
}
#endif

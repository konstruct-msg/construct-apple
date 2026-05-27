import Foundation

// Pure Swift reader for the MaxMind DB binary format (https://maxmind.github.io/MaxMind-DB/).
// Supports IPv4 lookups with record sizes 24, 28, and 32.
// Only decodes types needed for country-code and ASN lookups:
// map, string, uint16, uint32, uint64, pointer, boolean, array.
final class MMDBReader {

    private let data: Data
    private let nodeCount: Int
    private let recordSize: Int
    private let nodeSize: Int       // bytes per node (recordSize * 2 / 8)
    private let dataSectionStart: Int
    private let ipVersion: Int

    enum MMDBError: Error {
        case fileNotFound
        case invalidFormat
        case unsupportedRecordSize
    }

    // MARK: - Init

    init(url: URL) throws {
        let d = try Data(contentsOf: url, options: .mappedIfSafe)
        self.data = d

        // Metadata marker is the last occurrence of 0xABCDEF + "MaxMind.com"
        let markerBytes: [UInt8] = [0xab, 0xcd, 0xef] + Array("MaxMind.com".utf8)
        let marker = Data(markerBytes)
        guard let markerRange = d.range(of: marker, options: .backwards) else {
            throw MMDBError.invalidFormat
        }

        var cursor = markerRange.upperBound
        guard let meta = MMDBReader.decodeValue(data: d, at: &cursor, dataSectionBase: 0),
              case .map(let m) = meta else {
            throw MMDBError.invalidFormat
        }

        guard let nc = m["node_count"]?.uint32Value,
              let rs = m["record_size"]?.uint32Value else {
            throw MMDBError.invalidFormat
        }
        guard rs == 24 || rs == 28 || rs == 32 else { throw MMDBError.unsupportedRecordSize }

        let ipVer = m["ip_version"]?.uint32Value.map(Int.init) ?? 4
        self.ipVersion = ipVer
        self.nodeCount = Int(nc)
        self.recordSize = Int(rs)
        self.nodeSize = Int(rs) * 2 / 8
        self.dataSectionStart = Int(nc) * nodeSize + 16  // 16-byte separator
    }

    // MARK: - Public API

    /// Returns the country ISO code for the given IPv4 string, or nil.
    func countryCode(for ip: String) -> String? {
        guard let record = lookup(ip),
              case .map(let top) = record else { return nil }

        // GeoLite2-Country: top-level "country" key
        if let country = top["country"],
           case .map(let cm) = country,
           case .string(let code) = cm["iso_code"] {
            return code
        }
        // GeoLite2-City also has "country"
        if let registeredCountry = top["registered_country"],
           case .map(let rc) = registeredCountry,
           case .string(let code) = rc["iso_code"] {
            return code
        }
        return nil
    }

    /// Returns (ASN number, org name) for the given IPv4 string, or nil.
    func asn(for ip: String) -> (number: UInt32, org: String?)? {
        guard let record = lookup(ip),
              case .map(let top) = record else { return nil }
        guard case .uint32(let asn) = top["autonomous_system_number"] else { return nil }
        let org = top["autonomous_system_organization"].flatMap {
            if case .string(let s) = $0 { return s } else { return nil }
        }
        return (asn, org)
    }

    // MARK: - Search tree traversal

    private func lookup(_ ipString: String) -> MMDBValue? {
        guard let ipBytes = parseIPv4(ipString) else { return nil }

        var node = (ipVersion == 6) ? 96 : 0  // IPv4-in-IPv6 databases start at node 96

        for byte in ipBytes {
            for shift in stride(from: 7, through: 0, by: -1) {
                let bit = (Int(byte) >> shift) & 1
                node = readRecord(at: node, direction: bit)
                guard node < nodeCount else { break }
            }
            guard node < nodeCount else { break }
        }

        // node == nodeCount → empty record
        guard node > nodeCount else { return nil }
        // nodes nodeCount+1 to nodeCount+15 are reserved
        guard node >= nodeCount + 16 else { return nil }

        let dataOffset = dataSectionStart + (node - nodeCount - 16)
        var cursor = dataOffset
        return MMDBReader.decodeValue(data: data, at: &cursor, dataSectionBase: dataSectionStart)
    }

    private func readRecord(at node: Int, direction: Int) -> Int {
        let base = node * nodeSize
        switch recordSize {
        case 24:
            if direction == 0 {
                return (Int(data[base]) << 16) | (Int(data[base + 1]) << 8) | Int(data[base + 2])
            } else {
                return (Int(data[base + 3]) << 16) | (Int(data[base + 4]) << 8) | Int(data[base + 5])
            }
        case 28:
            if direction == 0 {
                return (Int(data[base]) << 16) | (Int(data[base + 1]) << 8) | Int(data[base + 2])
                    | ((Int(data[base + 3]) & 0xf0) << 20)
            } else {
                return (Int(data[base + 4]) << 16) | (Int(data[base + 5]) << 8) | Int(data[base + 6])
                    | ((Int(data[base + 3]) & 0x0f) << 24)
            }
        case 32:
            if direction == 0 {
                return (Int(data[base]) << 24) | (Int(data[base + 1]) << 16)
                    | (Int(data[base + 2]) << 8) | Int(data[base + 3])
            } else {
                return (Int(data[base + 4]) << 24) | (Int(data[base + 5]) << 16)
                    | (Int(data[base + 6]) << 8) | Int(data[base + 7])
            }
        default:
            return nodeCount
        }
    }

    // MARK: - Data section decoder

    indirect enum MMDBValue {
        case pointer(Int)
        case string(String)
        case double(Double)
        case bytes(Data)
        case uint16(UInt16)
        case uint32(UInt32)
        case int32(Int32)
        case uint64(UInt64)
        case uint128(Data)
        case map([String: MMDBValue])
        case array([MMDBValue])
        case boolean(Bool)
        case float(Float)

        var uint32Value: UInt32? {
            if case .uint32(let v) = self { return v }
            if case .uint16(let v) = self { return UInt32(v) }
            return nil
        }
    }

    // Recursive decoder. `dataSectionBase` is the file offset of the data section start.
    // Pointers inside the data section are absolute offsets within the data section.
    private static func decodeValue(data: Data, at cursor: inout Int, dataSectionBase: Int) -> MMDBValue? {
        guard cursor < data.count else { return nil }
        let ctrl = Int(data[cursor]); cursor += 1

        var typeTag = (ctrl >> 5) & 0x07
        let rawSize = ctrl & 0x1f

        // Extended type: type tag 0 means read next byte for actual type
        if typeTag == 0 {
            guard cursor < data.count else { return nil }
            typeTag = Int(data[cursor]) + 7; cursor += 1
        }

        // Pointer: special handling (size bits encode pointer size class)
        if typeTag == 1 {
            let ptrSize = (ctrl >> 3) & 0x03
            var ptr = (ctrl & 0x07)
            switch ptrSize {
            case 0:
                guard cursor < data.count else { return nil }
                ptr = (ptr << 8) | Int(data[cursor]); cursor += 1
            case 1:
                guard cursor + 1 < data.count else { return nil }
                ptr = (ptr << 16) | (Int(data[cursor]) << 8) | Int(data[cursor + 1])
                ptr += 2048; cursor += 2
            case 2:
                guard cursor + 2 < data.count else { return nil }
                ptr = (ptr << 24) | (Int(data[cursor]) << 16) | (Int(data[cursor + 1]) << 8) | Int(data[cursor + 2])
                ptr += 526336; cursor += 3
            case 3:
                guard cursor + 3 < data.count else { return nil }
                ptr = (Int(data[cursor]) << 24) | (Int(data[cursor + 1]) << 16)
                    | (Int(data[cursor + 2]) << 8) | Int(data[cursor + 3])
                cursor += 4
            default:
                break
            }
            // Follow the pointer
            var ptrCursor = dataSectionBase + ptr
            return decodeValue(data: data, at: &ptrCursor, dataSectionBase: dataSectionBase)
        }

        // Resolve size extensions
        var size = rawSize
        if rawSize == 29 {
            guard cursor < data.count else { return nil }
            size = 29 + Int(data[cursor]); cursor += 1
        } else if rawSize == 30 {
            guard cursor + 1 < data.count else { return nil }
            size = 285 + (Int(data[cursor]) << 8) | Int(data[cursor + 1]); cursor += 2
        } else if rawSize == 31 {
            guard cursor + 2 < data.count else { return nil }
            size = 65821 + (Int(data[cursor]) << 16) | (Int(data[cursor + 1]) << 8) | Int(data[cursor + 2])
            cursor += 3
        }

        switch typeTag {
        case 2:  // UTF-8 string
            guard cursor + size <= data.count else { return nil }
            let s = String(bytes: data[cursor..<cursor + size], encoding: .utf8) ?? ""
            cursor += size
            return .string(s)

        case 3:  // double (64-bit IEEE 754)
            guard size == 8, cursor + 8 <= data.count else { return nil }
            let bits = readUInt64BE(data: data, at: cursor); cursor += 8
            return .double(Double(bitPattern: bits))

        case 4:  // bytes
            guard cursor + size <= data.count else { return nil }
            let d = Data(data[cursor..<cursor + size]); cursor += size
            return .bytes(d)

        case 5:  // uint16
            let v = readUIntBE(data: data, at: cursor, length: size); cursor += size
            return .uint16(UInt16(v))

        case 6:  // uint32
            let v = readUIntBE(data: data, at: cursor, length: size); cursor += size
            return .uint32(UInt32(v))

        case 7:  // map
            var map = [String: MMDBValue]()
            for _ in 0..<size {
                guard let keyVal = decodeValue(data: data, at: &cursor, dataSectionBase: dataSectionBase),
                      case .string(let key) = keyVal else { return nil }
                guard let value = decodeValue(data: data, at: &cursor, dataSectionBase: dataSectionBase) else { return nil }
                map[key] = value
            }
            return .map(map)

        case 8:  // int32
            let v = readUIntBE(data: data, at: cursor, length: size); cursor += size
            return .int32(Int32(bitPattern: UInt32(v)))

        case 9:  // uint64
            let v = readUIntBE(data: data, at: cursor, length: size); cursor += size
            return .uint64(UInt64(v))

        case 10: // uint128 — stored as raw bytes
            guard cursor + size <= data.count else { return nil }
            let d = Data(data[cursor..<cursor + size]); cursor += size
            return .uint128(d)

        case 11: // array
            var arr = [MMDBValue]()
            for _ in 0..<size {
                guard let v = decodeValue(data: data, at: &cursor, dataSectionBase: dataSectionBase) else { break }
                arr.append(v)
            }
            return .array(arr)

        case 13: // end marker
            return nil

        case 14: // boolean
            return .boolean(size != 0)

        case 15: // float (32-bit IEEE 754)
            guard size == 4, cursor + 4 <= data.count else { return nil }
            let bits = UInt32(readUIntBE(data: data, at: cursor, length: 4)); cursor += 4
            return .float(Float(bitPattern: bits))

        default:
            return nil
        }
    }

    // MARK: - Bit helpers

    private static func readUIntBE(data: Data, at offset: Int, length: Int) -> UInt64 {
        guard length > 0, offset + length <= data.count else { return 0 }
        var v: UInt64 = 0
        for i in 0..<length {
            v = (v << 8) | UInt64(data[offset + i])
        }
        return v
    }

    private static func readUInt64BE(data: Data, at offset: Int) -> UInt64 {
        guard offset + 8 <= data.count else { return 0 }
        return (UInt64(data[offset]) << 56) | (UInt64(data[offset+1]) << 48)
            | (UInt64(data[offset+2]) << 40) | (UInt64(data[offset+3]) << 32)
            | (UInt64(data[offset+4]) << 24) | (UInt64(data[offset+5]) << 16)
            | (UInt64(data[offset+6]) << 8)  | UInt64(data[offset+7])
    }

    private func parseIPv4(_ ip: String) -> [UInt8]? {
        let parts = ip.split(separator: ".").compactMap { UInt8($0) }
        guard parts.count == 4 else { return nil }
        return parts
    }
}

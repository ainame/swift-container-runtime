/// Text formats exposed by cgroup v2 interface files.
enum CgroupFile {
    /// runc's GetCgroupParamUint: "max" is UInt64.max, a negative value is 0.
    static func uint(_ text: String, file: String) throws -> UInt64 {
        let value = text.trimmingWhitespace
        if value == "max" { return .max }
        if let parsed = UInt64(value) { return parsed }
        if let signed = Int64(value), signed < 0 { return 0 }
        throw RuntimeError("unable to parse \(file) value \(value.debugDescription)")
    }

    /// "key value" lines (cpu.stat, memory.stat, *.events), in file order.
    static func keyValues(_ text: String, file: String) throws -> [(String, UInt64)] {
        try text.split(separator: "\n").map { line in
            let fields = line.split(separator: " ", omittingEmptySubsequences: false)
            guard fields.count == 2, let value = UInt64(fields[1]) else {
                throw RuntimeError("unable to parse \(file) line \(line.debugDescription)")
            }
            return (String(fields[0]), value)
        }
    }

    /// io.stat: "MAJ:MIN rbytes=N wbytes=N rios=N wios=N ...". Byte and
    /// operation counts become runc's Read/Write serviced tables; other keys
    /// (dbytes, cost.*) are not part of runc's events output.
    static func io(_ text: String) throws -> (serviceBytes: [BlkioEntry], serviced: [BlkioEntry]) {
        var serviceBytes: [BlkioEntry] = []
        var serviced: [BlkioEntry] = []
        for line in text.split(separator: "\n") {
            let fields = line.split(whereSeparator: { $0 == " " || $0 == "\t" })
            guard fields.count >= 2 else { continue }
            let device = fields[0].split(separator: ":", omittingEmptySubsequences: false)
            guard device.count == 2 else { continue }
            guard let major = UInt64(device[0]), let minor = UInt64(device[1]) else {
                throw RuntimeError("unable to parse io.stat device \(String(fields[0]).debugDescription)")
            }
            for item in fields.dropFirst() {
                let pair = item.split(separator: "=", omittingEmptySubsequences: false)
                guard pair.count == 2 else { continue }
                let target: (op: String, bytes: Bool)
                switch pair[0] {
                case "rbytes": target = ("Read", true)
                case "wbytes": target = ("Write", true)
                case "rios": target = ("Read", false)
                case "wios": target = ("Write", false)
                default: continue
                }
                guard let value = UInt64(pair[1]) else {
                    throw RuntimeError("unable to parse io.stat value \(String(item).debugDescription)")
                }
                let entry = BlkioEntry(major: major, minor: minor, op: target.op, value: value)
                if target.bytes { serviceBytes.append(entry) } else { serviced.append(entry) }
            }
        }
        return (serviceBytes, serviced)
    }

    /// *.pressure: "some avg10=0.00 avg60=0.00 avg300=0.00 total=0" and an
    /// optional "full" line (absent for cpu before Linux 5.13).
    static func pressure(_ text: String, file: String) throws -> PSIStats {
        var stats = PSIStats()
        for line in text.split(separator: "\n") {
            let fields = line.split(separator: " ")
            guard let kind = fields.first, kind == "some" || kind == "full" else { continue }
            var data = PSIData()
            for field in fields.dropFirst() {
                let pair = field.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
                guard pair.count == 2 else { throw RuntimeError("\(file): invalid psi data: \(String(field).debugDescription)") }
                switch pair[0] {
                case "avg10", "avg60", "avg300":
                    guard let value = Double(pair[1]) else {
                        throw RuntimeError("\(file): invalid \(pair[0]) PSI value: \(String(pair[1]).debugDescription)")
                    }
                    if pair[0] == "avg10" { data.avg10 = value } else if pair[0] == "avg60" { data.avg60 = value } else { data.avg300 = value }
                case "total":
                    guard let value = UInt64(pair[1]) else {
                        throw RuntimeError("\(file): invalid total PSI value: \(String(pair[1]).debugDescription)")
                    }
                    data.total = value
                default:
                    break
                }
            }
            if kind == "some" { stats.some = data } else { stats.full = data }
        }
        return stats
    }

    /// runc's HugePageSizes naming: "hugepages-2048kB" becomes "2MB", using
    /// Go's %g with binary (1024) steps and B/KB/MB/GB/TB/PB suffixes.
    static func hugePageSize(directoryEntry: String) -> String? {
        guard directoryEntry.hasPrefix("hugepages-"), directoryEntry.hasSuffix("kB"),
              let kilobytes = UInt64(directoryEntry.dropFirst("hugepages-".count).dropLast(2)) else { return nil }
        var size = Double(kilobytes) * 1024
        let suffixes = ["B", "KB", "MB", "GB", "TB", "PB", "EB", "ZB", "YB"]
        var index = 0
        while size >= 1024, index < suffixes.count - 1 {
            size /= 1024
            index += 1
        }
        return JSONObject.float(size) + suffixes[index]
    }
}

extension String {
    fileprivate var trimmingWhitespace: String {
        String(drop(while: { $0.isWhitespace }).reversed().drop(while: { $0.isWhitespace }).reversed())
    }
}

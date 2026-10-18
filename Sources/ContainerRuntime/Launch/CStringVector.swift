/// Owns one initialized byte slab. Raw pointers exist only during the C call.
///
/// Strings are arranged as groups. The pointer vector holds each group's
/// strings followed by a NULL terminator, so a group's start is directly
/// usable as an `argv`/`envp` style vector.
struct CStringVector: ~Copyable {
    private var storage: [CChar]
    private let offsets: [Int?]
    /// Index of each group's first pointer in the vector passed to `withPointers`.
    let groupStarts: [Int]

    init(_ strings: [String]) throws {
        try self.init(groups: [strings])
    }

    init(groups: [[String]]) throws {
        var capacity = 0
        for string in groups.joined() {
            guard !string.utf8.contains(0) else {
                throw RuntimeError("launch strings must not contain NUL")
            }
            let (withTerminator, terminatorOverflow) = string.utf8.count.addingReportingOverflow(1)
            let (total, totalOverflow) = capacity.addingReportingOverflow(withTerminator)
            guard !terminatorOverflow, !totalOverflow else {
                throw RuntimeError("launch strings exceed addressable storage")
            }
            capacity = total
        }
        var layout: [Int?] = []
        var starts: [Int] = []
        // Swift 6.4's OutputSpan tracks initialization; Array owns destruction.
        storage = Array(capacity: capacity) { output in
            for group in groups {
                starts.append(layout.count)
                for string in group {
                    layout.append(output.count)
                    for byte in string.utf8CString { output.append(byte) }
                }
                layout.append(nil)
            }
        }
        offsets = layout
        groupStarts = starts
    }

    @unsafe
    mutating func withPointers<Result>(
        _ body: (UnsafePointer<UnsafeMutablePointer<CChar>?>) throws -> Result
    ) rethrows -> Result {
        let layout = offsets
        return try storage.withUnsafeMutableBufferPointer { bytes in
            // The byte slab cannot resize while borrowed here. All offsets
            // point to initialized, NUL-terminated strings in that slab.
            unsafe try withTemporaryAllocation(of: UnsafeMutablePointer<CChar>?.self, capacity: layout.count) { output in
                for offset in layout {
                    unsafe output.append(offset.map { unsafe bytes.baseAddress!.advanced(by: $0) })
                }
                // Span borrows the initialized pointer vector. Neither the
                // vector nor its pointees may escape this nested callback.
                return unsafe try output.span.withUnsafeBufferPointer { pointers in
                    unsafe try body(pointers.baseAddress!)
                }
            }
        }
    }
}

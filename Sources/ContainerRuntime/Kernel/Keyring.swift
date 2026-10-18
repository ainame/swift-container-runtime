#if os(Linux)
import LinuxAPI
#endif
import SystemPackage

extension Kernel {
    enum Keyring {
        static func joinSession(_ name: [CChar]) throws(Errno) -> Int32 {
            #if os(Linux)
            let key = name.withUnsafeBufferPointer { unsafe linux_join_session_keyring($0.baseAddress) }
            guard key >= 0 else { throw .current }
            return key
            #else
            throw .noFunction
            #endif
        }

        /// Read the permissions without assuming the kernel's default mask.
        /// The container ID is <=1024 bytes, so its description fits this stack
        /// buffer. Any truncation or malformed description fails closed.
        static func permissions(_ key: Int32) throws(Errno) -> UInt32 {
            #if os(Linux)
            var bytes = InlineArray<4096, UInt8>(repeating: 0)
            let count: Int
            do {
                var buffer = bytes.mutableSpan
                count = buffer.withUnsafeMutableBufferPointer {
                    unsafe linux_describe_keyring(key, $0.baseAddress, $0.count)
                }
            }
            guard count >= 0 else { throw .current }
            guard count > 0, count <= 4096, bytes[Int(count) - 1] == 0 else { throw .fileTooLarge }
            var field = 0
            var digits = 0
            var permissions: UInt32 = 0
            for index in 0..<(Int(count) - 1) {
                let byte = bytes[index]
                if byte == 59 { // type;uid;gid;permissions;description
                    if field == 3 {
                        guard digits > 0 else { throw .invalidArgument }
                        return permissions
                    }
                    field += 1
                } else if field == 3 {
                    let nibble: UInt8
                    switch byte {
                    case 48...57: nibble = byte - 48
                    case 65...70: nibble = byte - 65 + 10
                    case 97...102: nibble = byte - 97 + 10
                    default: throw .invalidArgument
                    }
                    guard digits < 8 else { throw .invalidArgument }
                    permissions = (permissions << 4) | UInt32(nibble)
                    digits += 1
                }
            }
            throw .invalidArgument
            #else
            throw .noFunction
            #endif
        }

        static func setPermissions(_ key: Int32, to permissions: UInt32) throws(Errno) {
            #if os(Linux)
            guard linux_set_keyring_permissions(key, permissions) == 0 else { throw .current }
            #else
            throw .noFunction
            #endif
        }
    }
}

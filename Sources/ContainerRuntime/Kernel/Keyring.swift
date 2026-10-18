#if os(Linux)
import LinuxAPI
#endif
import SystemPackage

extension Kernel {
    /// keyctl(2) operations on the calling process's session keyring, called
    /// only by the single-threaded init or exec child before credentials change.
    enum Keyring {
        /// KEY_USR_SEARCH from <keyutils.h>, which is not a dependency: the
        /// key owner's uid may find the keyring by name.
        static let ownerSearch: UInt32 = 0x0008_0000

        /// KEYCTL_JOIN_SESSION_KEYRING: joins the named session keyring,
        /// creating it when it does not exist yet. `name` is NUL-terminated
        /// and prepared before fork. Returns the keyring's serial number.
        static func joinSession(_ name: [CChar]) throws(Errno) -> Int32 {
            #if os(Linux)
            let key = name.withUnsafeBufferPointer { unsafe linux_join_session_keyring($0.baseAddress) }
            guard key >= 0 else { throw .current }
            return key
            #else
            throw .noFunction
            #endif
        }

        /// The keyring's permission mask, read from KEYCTL_DESCRIBE's
        /// `type;uid;gid;perm;description` text (`perm` in hex) rather than
        /// assuming the kernel's default. A container ID is at most 1024
        /// bytes, so the description fits the stack buffer; a truncated or
        /// malformed description fails closed.
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
            guard count > 0, count <= bytes.count, bytes[count - 1] == 0 else { throw .fileTooLarge }

            // Accumulate the hex digits of the fourth field only.
            var field = 0
            var digits = 0
            var permissions: UInt32 = 0
            for index in 0..<(count - 1) {
                let byte = bytes[index]
                if byte == UInt8(ascii: ";") {
                    if field == 3 { break }
                    field += 1
                    continue
                }
                guard field == 3 else { continue }
                guard digits < 8, let nibble = hexValue(byte) else { throw .invalidArgument }
                permissions = permissions << 4 | nibble
                digits += 1
            }
            guard field == 3, digits > 0 else { throw .invalidArgument }
            return permissions
            #else
            throw .noFunction
            #endif
        }

        /// KEYCTL_SETPERM: replaces the keyring's whole permission mask.
        static func setPermissions(_ key: Int32, to permissions: UInt32) throws(Errno) {
            #if os(Linux)
            guard linux_set_keyring_permissions(key, permissions) == 0 else { throw .current }
            #else
            throw .noFunction
            #endif
        }

        private static func hexValue(_ byte: UInt8) -> UInt32? {
            switch byte {
            case UInt8(ascii: "0")...UInt8(ascii: "9"): UInt32(byte - UInt8(ascii: "0"))
            case UInt8(ascii: "a")...UInt8(ascii: "f"): UInt32(byte - UInt8(ascii: "a") + 10)
            case UInt8(ascii: "A")...UInt8(ascii: "F"): UInt32(byte - UInt8(ascii: "A") + 10)
            default: nil
            }
        }
    }
}

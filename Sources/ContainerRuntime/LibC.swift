#if canImport(Musl)
import Musl
#elseif canImport(Glibc)
import Glibc
#elseif canImport(Darwin)
import Darwin
#endif

public enum RuntimeDiagnostics {
    public static func writeError(_ message: String) {
        let bytes = (message + "\n").utf8CString
        bytes.withUnsafeBufferPointer { buffer in
            var written = 0
            // The buffer remains borrowed until all writes finish. Exclude NUL.
            while written < buffer.count - 1 {
                let result = unsafe write(STDERR_FILENO, buffer.baseAddress!.advanced(by: written), buffer.count - 1 - written)
                if result < 0 && errno == EINTR { continue }
                guard result > 0 else { return }
                written += result
            }
        }
    }
}

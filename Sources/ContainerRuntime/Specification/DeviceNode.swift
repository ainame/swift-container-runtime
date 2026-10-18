import SystemPackage

/// One custom OCI device, validated in the supervisor and created by init
/// beneath its pinned rootfs before credentials or read-only settings apply.
struct DeviceNode: Sendable {
    let components: [String]
    /// Linux S_IFCHR, S_IFBLK or S_IFIFO; never inferred from a host pathname.
    let kind: UInt32
    let permissions: UInt16
    let number: UInt64
    let uid: UInt32
    let gid: UInt32

    init(_ device: OCIConfiguration.Device) throws {
        components = try OCIRunPlan.components(device.path, field: "linux.devices.path")
        guard !components.isEmpty else { throw RuntimeError("config.json: device path must not be /") }
        switch device.type {
        case "c", "u": kind = 0o020000
        case "b": kind = 0o060000
        case "p": kind = 0o010000
        default: throw RuntimeError("config.json: device type must be c, b or p")
        }
        let major = device.major ?? 0, minor = device.minor ?? 0
        guard major >= 0, major <= Int64(UInt32.max), minor >= 0, minor <= Int64(UInt32.max) else {
            throw RuntimeError("config.json: device numbers must fit unsigned 32-bit integers")
        }
        guard kind != 0o010000 || (major == 0 && minor == 0) else {
            throw RuntimeError("config.json: a FIFO has no major/minor device number")
        }
        let mode = device.fileMode ?? 0o666
        guard mode <= 0o7777 else { throw RuntimeError("config.json: device fileMode contains non-permission bits") }
        permissions = UInt16(mode)
        uid = device.uid ?? 0
        gid = device.gid ?? 0
        guard uid != UInt32.max, gid != UInt32.max else {
            throw RuntimeError("config.json: device owner IDs must not be -1")
        }
        number = LinuxDevice.number(UInt32(major), UInt32(minor))
    }
}

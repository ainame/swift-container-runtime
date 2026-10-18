import SystemPackage

/// A small, forward-only eBPF program for bpf_cgroup_dev_ctx. Its decisions
/// depend only on the normalized policy; loading/attachment stays in Kernel.
enum DeviceFilter {
    private struct Instruction {
        let code: UInt8
        let destination: UInt8
        let source: UInt8
        var offset: Int16
        let immediate: Int32
    }

    static func bytecode(_ policy: DevicePolicy) -> [UInt8] {
        var code: [Instruction] = []
        func emit(_ opcode: UInt8, _ dst: UInt8 = 0, _ src: UInt8 = 0, _ offset: Int16 = 0, _ immediate: Int32 = 0) {
            code.append(Instruction(code: opcode, destination: dst, source: src, offset: offset, immediate: immediate))
        }
        // R2=type, R3=requested access, R4=major, R5=minor. R1 is the ctx.
        emit(0x61, 2, 1); emit(0x54, 2, 0, 0, 0xffff)
        emit(0x61, 3, 1); emit(0x74, 3, 0, 0, 16)
        emit(0x61, 4, 1, 4); emit(0x61, 5, 1, 8)
        for exception in policy.exceptions {
            var skips: [Int] = []
            func skip(_ opcode: UInt8, _ dst: UInt8, _ src: UInt8 = 0, _ immediate: Int32 = 0) {
                skips.append(code.count)
                emit(opcode, dst, src, 0, immediate)
            }
            let device = exception.device
            skip(0x56, 2, 0, Int32(bitPattern: device.type)) // JMP32 JNE K
            if let major = device.major { skip(0x56, 4, 0, Int32(bitPattern: major)) }
            if let minor = device.minor { skip(0x56, 5, 0, Int32(bitPattern: minor)) }
            emit(0xbc, 1, 3) // MOV32 R1,R3; ctx is no longer needed
            emit(0x54, 1, 0, 0, Int32(bitPattern: exception.access))
            if policy.defaultAllow {
                // Deny any overlapping access, including O_RDWR when only
                // one of read/write is forbidden. Never allow a partial deny
                // to be bypassed by adding another requested access bit.
                skip(0x16, 1) // JMP32 JEQ R1,0
            } else {
                skip(0x5e, 1, 3) // JMP32 JNE R1,R3: need every requested bit
            }
            emit(0xb4, 0, 0, 0, policy.defaultAllow ? 0 : 1)
            emit(0x95)
            for index in skips { code[index].offset = Int16(code.count - index - 1) }
        }
        emit(0xb4, 0, 0, 0, policy.defaultAllow ? 1 : 0)
        emit(0x95)
        // bpf_insn's scalar fields and register nibble layout use host endian.
        return code.flatMap { instruction -> [UInt8] in
            let offset = UInt16(bitPattern: instruction.offset)
            let immediate = UInt32(bitPattern: instruction.immediate)
            #if _endian(little)
            let registers = instruction.destination | (instruction.source << 4)
            let offsets = [UInt8(truncatingIfNeeded: offset), UInt8(truncatingIfNeeded: offset >> 8)]
            let shifts = [0, 8, 16, 24]
            #else
            let registers = (instruction.destination << 4) | instruction.source
            let offsets = [UInt8(truncatingIfNeeded: offset >> 8), UInt8(truncatingIfNeeded: offset)]
            let shifts = [24, 16, 8, 0]
            #endif
            return [instruction.code, registers] + offsets + shifts.map { UInt8(truncatingIfNeeded: immediate >> $0) }
        }
    }

    static func install(_ policy: DevicePolicy, in cgroup: FileDescriptor) throws -> UInt32 {
        var verifier = [UInt8](repeating: 0, count: 65_536)
        let program: OwnedFileDescriptor
        do {
            program = try Kernel.BPF.loadDeviceProgram(bytecode(policy), log: &verifier)
        } catch {
            let detail = String(decoding: verifier.prefix(while: { $0 != 0 }), as: UTF8.self)
            throw RuntimeError("load device BPF filter: \(error)\(detail.isEmpty ? "" : ": " + detail)")
        }
        return try program.withDescriptor { program in
            // Get ownership metadata before attaching: once attachment succeeds
            // there is no throwing step before the caller can record this ID.
            let id = try Kernel.BPF.id(of: program)
            do { try Kernel.BPF.attach(program, to: cgroup) }
            catch { throw RuntimeError("attach device BPF filter: \(error)") }
            return id
        }
    }

    static func remove(_ id: UInt32, from cgroup: FileDescriptor) throws {
        do {
            let program = try Kernel.BPF.openProgram(id)
            try program.withDescriptor { try Kernel.BPF.detach($0, from: cgroup) }
        } catch Errno.noSuchFileOrDirectory {
            // Already detached, or destroyed together with the old cgroup.
        } catch {
            throw RuntimeError("detach owned device BPF filter \(id): \(error)")
        }
    }
}

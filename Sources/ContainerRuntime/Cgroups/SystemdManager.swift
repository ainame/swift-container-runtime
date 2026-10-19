/// systemd's manager object (`org.freedesktop.systemd1.Manager`), reached
/// over its private peer-to-peer socket, as runc's systemd driver reaches
/// it through go-systemd. Used by the supervisor at container creation,
/// update and removal; never by a forked child.
///
/// Unit jobs are asynchronous: a start or stop call returns a job object
/// path at once, and the job's outcome arrives as a `JobRemoved` signal,
/// which this client waits for (runc waits up to 30 seconds).
final class SystemdManager {
    /// Root-only and present whenever systemd is PID 1, unlike the system bus,
    /// which needs a separate bus daemon.
    static let socketPath = "/run/systemd/private"
    private static let destination = "org.freedesktop.systemd1"
    private static let objectPath = "/org/freedesktop/systemd1"
    private static let interface = "org.freedesktop.systemd1.Manager"
    /// libdbus's default method-call timeout.
    private static let callTimeout = Duration.seconds(25)
    /// runc's timeout for a unit job to finish.
    private static let jobTimeout = Duration.seconds(30)

    private let connection: DBusConnection

    private init(connection: DBusConnection) {
        self.connection = connection
    }

    /// Connects and subscribes to manager signals. Direct connections
    /// receive signals without subscribing; the call keeps this client
    /// correct if systemd ever applies the bus rule to them.
    static func connect() throws -> SystemdManager {
        let manager: SystemdManager
        do {
            manager = SystemdManager(connection: try DBusConnection.connect(path: socketPath, timeout: callTimeout))
        } catch {
            throw RuntimeError("--systemd-cgroup needs systemd as the init system: \(error)")
        }
        _ = try? manager.call("Subscribe", [])
        return manager
    }

    /// Starts a transient scope holding `pid` and waits for its job.
    ///
    /// A unit with the same name may be a failed leftover, which systemd
    /// keeps until reset; as runc does, it is reset and the start retried
    /// once. A live unit with that name stays an error.
    func startTransientUnit(_ unit: String, properties: [(String, DBusValue)]) throws {
        let arguments: [DBusValue] = [
            .string(unit), .string("replace"), Self.encode(properties),
            // No auxiliary units.
            .array(element: "(sa(sv))", []),
        ]
        var job: String
        do {
            job = try jobPath(call("StartTransientUnit", arguments))
        } catch let error as DBusError where error.name == "org.freedesktop.systemd1.UnitExists" {
            resetFailedUnit(unit)
            do {
                job = try jobPath(call("StartTransientUnit", arguments))
            } catch let error as DBusError where error.name == "org.freedesktop.systemd1.UnitExists" {
                throw RuntimeError("systemd unit \(unit) already exists; another container may be using the same cgroupsPath")
            }
        }
        try waitForJob(job, unit: unit, action: "start")
    }

    /// Stops `unit` and waits for the job; false when systemd has no such
    /// unit (a scope is removed automatically once its cgroup is empty).
    @discardableResult
    func stopUnit(_ unit: String) throws -> Bool {
        let job: String
        do {
            job = try jobPath(call("StopUnit", [.string(unit), .string("replace")]))
        } catch let error as DBusError where error.name == "org.freedesktop.systemd1.NoSuchUnit" {
            return false
        }
        try waitForJob(job, unit: unit, action: "stop")
        return true
    }

    /// Clears a failed unit's state so systemd unloads it. Best effort:
    /// a missing or not-failed unit is fine.
    func resetFailedUnit(_ unit: String) {
        _ = try? call("ResetFailedUnit", [.string(unit)])
    }

    /// Updates a live unit's stored properties at runtime (not persisted
    /// across reboots), as runc's update does before writing files.
    func setUnitProperties(_ unit: String, _ properties: [(String, DBusValue)]) throws {
        guard !properties.isEmpty else { return }
        do {
            _ = try call("SetUnitProperties", [.string(unit), .boolean(true), Self.encode(properties)])
        } catch let error as DBusError {
            throw RuntimeError("set systemd properties of \(unit): \(error)")
        }
    }

    private func call(_ member: String, _ arguments: [DBusValue]) throws -> DBusMessage {
        try connection.call(
            destination: Self.destination, path: Self.objectPath, interface: Self.interface, member: member,
            arguments: arguments, timeout: Self.callTimeout)
    }

    /// The job object path a start or stop call returns.
    private func jobPath(_ reply: DBusMessage) throws -> String {
        guard case let .objectPath(path)? = try reply.arguments().first else {
            throw DBusProtocolError("systemd returned no job for a unit request")
        }
        return path
    }

    /// Waits for `JobRemoved(u id, o job, s unit, s result)` naming `job`;
    /// any result other than `done` fails, as in runc.
    private func waitForJob(_ job: String, unit: String, action: String) throws {
        let signal = try connection.waitForSignal(timeout: Self.jobTimeout, describing: "systemd job \(job) for \(unit)") { message in
            guard message.interface == Self.interface, message.member == "JobRemoved",
                  let arguments = try? message.arguments(), arguments.count == 4 else { return false }
            return arguments[1] == .objectPath(job)
        }
        let result = (try signal.arguments())[3].stringValue ?? ""
        guard result == "done" else {
            throw RuntimeError("systemd failed to \(action) \(unit): job result \(result.debugDescription)")
        }
    }

    /// An `a(sv)` property list.
    private static func encode(_ properties: [(String, DBusValue)]) -> DBusValue {
        .array(element: "(sv)", properties.map { .structure([.string($0.0), .variant($0.1)]) })
    }
}

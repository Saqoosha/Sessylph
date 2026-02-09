import Foundation
import os.log

private let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "Sessylph", category: "PTYProcess")

@MainActor
protocol PTYProcessDelegate: AnyObject {
    func ptyProcess(_ process: PTYProcess, didReceiveData data: Data)
    func ptyProcess(_ process: PTYProcess, didTerminateWithExitCode exitCode: Int32?)
}

/// Manages a child process connected to a pseudo-terminal.
/// Uses `forkpty` + `DispatchIO` for non-blocking I/O.
final class PTYProcess: @unchecked Sendable {
    private let readSize = 128 * 1024

    /// Master side of the pty. Writable to send data to the child.
    private(set) var childfd: Int32 = -1

    /// PID of the child process.
    private(set) var shellPid: pid_t = 0

    /// Whether the child process is still running.
    private(set) var running: Bool = false

    weak var delegate: (any PTYProcessDelegate)?

    private let dispatchQueue: DispatchQueue
    private let readQueue: DispatchQueue
    private var io: DispatchIO?
    private var childMonitor: DispatchSourceProcess?

    init(dispatchQueue: DispatchQueue = .main) {
        self.dispatchQueue = dispatchQueue
        self.readQueue = DispatchQueue(label: "sh.saqoo.Sessylph.ptyRead")
    }

    // MARK: - Start

    /// Launches a child process inside a pseudo-terminal.
    func startProcess(
        executable: String,
        args: [String],
        environment: [String],
        execName: String? = nil,
        desiredWindowSize: winsize? = nil
    ) {
        guard !running else { return }

        var shellArgs = args
        shellArgs.insert(execName ?? executable, at: 0)

        var size = desiredWindowSize ?? winsize(ws_row: 24, ws_col: 80, ws_xpixel: 0, ws_ypixel: 0)

        guard let (pid, master) = Self.forkAndExec(
            executable: executable,
            args: shellArgs,
            env: environment,
            desiredWindowSize: &size
        ) else {
            logger.error("forkpty failed")
            dispatchQueue.async { [weak self] in
                guard let self else { return }
                Task { @MainActor in self.delegate?.ptyProcess(self, didTerminateWithExitCode: nil) }
            }
            return
        }

        self.childfd = master
        self.shellPid = pid
        self.running = true

        // Monitor child exit
        let monitor = DispatchSource.makeProcessSource(identifier: pid, eventMask: .exit, queue: dispatchQueue)
        monitor.setEventHandler { [weak self] in self?.handleProcessTerminated() }
        monitor.activate()
        self.childMonitor = monitor

        // Non-blocking reads via DispatchIO
        let fdToClose = master
        let channel = DispatchIO(type: .stream, fileDescriptor: master, queue: dispatchQueue) { _ in
            close(fdToClose)
        }
        channel.setLimit(lowWater: 1)
        channel.setLimit(highWater: readSize)
        self.io = channel
        channel.read(offset: 0, length: readSize, queue: readQueue, ioHandler: childProcessRead)

        logger.info("Started process pid=\(pid) fd=\(master)")
    }

    // MARK: - Send

    func send(data: Data) {
        guard running, childfd >= 0, !data.isEmpty else { return }
        data.withUnsafeBytes { rawBuf in
            let dispatchData = DispatchData(bytes: rawBuf.bindMemory(to: UInt8.self))
            DispatchIO.write(
                toFileDescriptor: childfd,
                data: dispatchData,
                runningHandlerOn: .global(qos: .userInitiated)
            ) { _, errno in
                if errno != 0 {
                    logger.warning("PTY write error: errno=\(errno)")
                }
            }
        }
    }

    // MARK: - Window Size

    func setWindowSize(_ size: winsize) {
        guard childfd >= 0 else { return }
        var ws = size
        _ = ioctl(childfd, TIOCSWINSZ, &ws)
    }

    func getWindowSize() -> winsize {
        guard childfd >= 0 else {
            return winsize(ws_row: 24, ws_col: 80, ws_xpixel: 0, ws_ypixel: 0)
        }
        var ws = winsize()
        _ = ioctl(childfd, TIOCGWINSZ, &ws)
        return ws
    }

    // MARK: - Terminate

    func terminate() {
        io?.close()
        io = nil
        childMonitor?.cancel()
        childMonitor = nil
        childfd = -1

        if shellPid != 0 {
            kill(shellPid, SIGTERM)
        }
        running = false
    }

    // MARK: - Private: Read Callback

    private func childProcessRead(done: Bool, data: DispatchData?, errno: Int32) {
        guard let data, data.count > 0 else {
            if !done, running {
                // Transient empty read; re-schedule
                io?.read(offset: 0, length: readSize, queue: readQueue, ioHandler: childProcessRead)
            } else if data?.count == 0 {
                // EOF
                childfd = -1
            }
            return
        }

        let nsData = data.withUnsafeBytes { ptr -> Data in
            Data(ptr)
        }

        dispatchQueue.async { [weak self] in
            guard let self else { return }
            Task { @MainActor in
                self.delegate?.ptyProcess(self, didReceiveData: nsData)
            }
        }

        io?.read(offset: 0, length: readSize, queue: readQueue, ioHandler: childProcessRead)
    }

    // MARK: - Private: Process Termination

    private func handleProcessTerminated() {
        var status: Int32 = 0
        waitpid(shellPid, &status, WNOHANG)
        running = false
        // WIFEXITED / WEXITSTATUS are C macros, replicate inline
        let exited = (status & 0x7F) == 0
        let exitCode = exited ? (status >> 8) & 0xFF : status
        logger.info("Process terminated pid=\(self.shellPid) exit=\(exitCode)")
        Task { @MainActor [weak self] in
            guard let self else { return }
            self.delegate?.ptyProcess(self, didTerminateWithExitCode: exitCode)
        }
    }

    // MARK: - Private: Fork + Exec

    private static func forkAndExec(
        executable: String,
        args: [String],
        env: [String],
        desiredWindowSize: inout winsize
    ) -> (pid: pid_t, masterFd: Int32)? {
        var master: Int32 = 0
        let pid = forkpty(&master, nil, nil, &desiredWindowSize)
        if pid < 0 { return nil }

        if pid == 0 {
            // Child process
            Self.withCStringArray(args) { pargs in
                Self.withCStringArray(env) { penv in
                    _ = execve(executable, pargs, penv)
                }
            }
            // execve failed
            _exit(1)
        }

        return (pid, master)
    }

    private static func withCStringArray<R>(
        _ strings: [String],
        _ body: ([UnsafeMutablePointer<CChar>?]) -> R
    ) -> R {
        let counts = strings.map { $0.utf8.count + 1 }
        var offsets = [0]
        for c in counts { offsets.append(offsets.last! + c) }
        let bufferSize = offsets.last!

        var buffer: [UInt8] = []
        buffer.reserveCapacity(bufferSize)
        for s in strings {
            buffer.append(contentsOf: s.utf8)
            buffer.append(0)
        }

        return buffer.withUnsafeMutableBufferPointer { buf in
            let base = UnsafeMutableRawPointer(buf.baseAddress!).bindMemory(to: CChar.self, capacity: buf.count)
            var cStrings: [UnsafeMutablePointer<CChar>?] = offsets.map { base + $0 }
            cStrings[cStrings.count - 1] = nil
            return body(cStrings)
        }
    }
}

// MARK: - DispatchData helper

private extension DispatchData {
    func withUnsafeBytes<R>(_ body: (UnsafeRawBufferPointer) -> R) -> R {
        var result: R!
        enumerateBytes { buffer, _, stop in
            result = body(UnsafeRawBufferPointer(buffer))
            stop = true
        }
        return result
    }
}

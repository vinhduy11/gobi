import AppKit
import GobiClient
import GobiModel

/// One Delve debugging session of a project: runs the DAP conversation (initialize, launch, breakpoints, configurationDone),
/// follows stopped/continued/terminated events and keeps what the Debug panel and the editor show. All state and callbacks are
/// on the main thread.
final class DebugSession {
    let root: URL
    private(set) var state = DebugState.idle { didSet { onChange() } }
    private(set) var frames: [DebugFrame] = []
    private(set) var selectedFrame = 0
    private(set) var variables: [DebugVariable] = []
    private(set) var threadId = 1
    private(set) var output = ""
    private(set) var threads: [DebugThread] = []
    var watches = WatchList()
    /// Variables the debugged program starts with (the active environment profile).
    var environment: [String: String] = [:]
    private(set) var watchResults: [String: String] = [:]
    private var attached = false
    var breakpoints: () -> Breakpoints = { Breakpoints() }
    var onChange: () -> Void = {}
    var onOutput: (String) -> Void = { _ in }
    private var client: DAPClient?
    private var terminated = false
    private var buildFolder: URL?

    init(root: URL) { self.root = root }

    var currentFrame: DebugFrame? { frames.indices.contains(selectedFrame) ? frames[selectedFrame] : nil }

    // MARK: lifecycle

    /// Starts debugging the main package in `programDir` (an absolute folder).
    func start(programDir: String) {
        guard !state.isActive else { return }
        attached = false
        launchRequest = nil
        begin(programDir: programDir)
    }

    private func begin(programDir: String) {
        state = .starting
        frames = []
        variables = []
        output = ""
        terminated = false
        let rootPath = root.path
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            do {
                let client = try DAPClient.connect(workspaceRoot: rootPath)
                client.onEvent = { [weak self] name, body in DispatchQueue.main.async { self?.handle(event: name, body: body) } }
                client.onDisconnect = { [weak self] in DispatchQueue.main.async { self?.connectionClosed() } }
                client.start()
                DispatchQueue.main.async { self?.client = client; self?.initialize(client, programDir: programDir) }
            } catch {
                AppLog.shared.logError("debug channel: cannot start the debugger: \(error)")
                DispatchQueue.main.async { self?.fail("Cannot start the debugger: \(error)") }
            }
        }
    }

    /// Attaches Delve to a running process instead of starting a program.
    func attach(pid: Int) {
        guard !state.isActive else { return }
        attached = true
        launchRequest = ("attach", ["mode": "local", "processId": pid])
        begin(programDir: root.path)
    }

    private var launchRequest: (command: String, arguments: [String: Any])?

    private func initialize(_ client: DAPClient, programDir: String) {
        client.request("initialize", ["adapterID": "go", "linesStartAt1": true, "columnsStartAt1": true, "pathFormat": "path", "supportsVariableType": true]) { [weak self] result in
            DispatchQueue.main.async {
                guard let self else { return }
                if case .failure(let error) = result { return self.fail("The debugger did not start: \(error)") }
                // The launch response can come before or after the initialized event; the event drives the next step.
                // Delve builds the program into a binary; keep it out of the project folder.
                let build = FileManager.default.temporaryDirectory.appendingPathComponent("gobi-debug-" + UUID().uuidString)
                try? FileManager.default.createDirectory(at: build, withIntermediateDirectories: true)
                self.buildFolder = build
                let request = self.launchRequest ?? ("launch", ["mode": "debug", "program": programDir, "cwd": programDir, "output": build.appendingPathComponent("program").path, "stopOnEntry": false, "env": self.environment])
                client.request(request.command, request.arguments) { [weak self] result in
                    DispatchQueue.main.async {
                        if case .failure(let error) = result { self?.fail("Cannot launch: \(error)") }
                    }
                }
            }
        }
    }

    private func configure() {
        guard let client else { return }
        let all = breakpoints()
        sendBreakpoints(paths: all.paths) { [weak self] in
            client.request("configurationDone") { _ in DispatchQueue.main.async { if self?.state == .starting { self?.state = .running } } }
        }
    }

    private func sendBreakpoints(paths: [String], then done: @escaping () -> Void) {
        guard let client else { return }
        let all = breakpoints()
        var remaining = paths
        func next() {
            guard let path = remaining.popLast() else { return done() }
            client.request("setBreakpoints", ["source": ["path": path], "breakpoints": DAPClient.breakpointEntries(for: path, in: all)]) { _ in DispatchQueue.main.async { next() } }
        }
        next()
    }

    /// Tells Delve about the breakpoints of one file (also when the last one was removed) while a session is active.
    func breakpointsChanged(in path: String) {
        guard state.isActive, state != .starting else { return }
        client?.request("setBreakpoints", ["source": ["path": path], "breakpoints": DAPClient.breakpointEntries(for: path, in: breakpoints())]) { _ in }
    }

    // MARK: events

    private func handle(event: String, body: [String: Any]) {
        switch event {
        case "initialized": configure()
        case "stopped":
            threadId = body["threadId"] as? Int ?? threadId
            let reason = (body["reason"] as? String) ?? "pause"
            loadStack(reason: reason)
        case "continued": state = .running
        case "output":
            guard let text = body["output"] as? String else { return }
            if (body["category"] as? String) != "telemetry" { output += text; onOutput(text) }
        case "exited":
            exitCode = body["exitCode"] as? Int
        case "terminated": finish()
        default: break
        }
    }

    private var exitCode: Int?

    private func loadStack(reason: String) {
        guard let client else { return }
        client.request("stackTrace", ["threadId": threadId, "startFrame": 0, "levels": 40]) { [weak self] result in
            DispatchQueue.main.async {
                guard let self, case .success(let body) = result else { return }
                self.frames = DAPClient.frames(from: body)
                self.selectedFrame = 0
                self.state = .stopped(reason: Self.reasonText(reason), location: self.frames.first?.location ?? "")
                self.loadVariables()
            }
        }
        client.request("threads") { [weak self] result in
            DispatchQueue.main.async {
                guard let self, case .success(let body) = result else { return }
                self.threads = DAPClient.threads(from: body)
                self.onChange()
            }
        }
    }

    /// Looks at another goroutine: its stack and variables replace the current ones.
    func select(thread id: Int) {
        guard state.canStep, threads.contains(where: { $0.id == id }) else { return }
        threadId = id
        loadStack(reason: "pause")
    }

    private static func reasonText(_ reason: String) -> String {
        switch reason {
        case "breakpoint": return "breakpoint"
        case "step": return "step"
        case "pause": return "pause"
        case "exception", "panic": return "panic"
        default: return reason
        }
    }

    /// Selects a frame of the call stack and shows its variables.
    func select(frame index: Int) {
        guard frames.indices.contains(index) else { return }
        selectedFrame = index
        loadVariables()
        onChange()
    }

    private func loadVariables() {
        guard let client, let frame = currentFrame else { variables = []; return }
        client.request("scopes", ["frameId": frame.id]) { [weak self] result in
            guard case .success(let body) = result, let reference = DAPClient.localsReference(from: body) else { return }
            client.request("variables", ["variablesReference": reference]) { result in
                DispatchQueue.main.async {
                    guard let self, case .success(let body) = result, self.currentFrame?.id == frame.id else { return }
                    self.variables = DAPClient.variables(from: body)
                    self.onChange()
                    self.evaluateWatches()
                }
            }
        }
    }

    // MARK: watches and children

    /// Evaluates every watch expression in the selected frame; results arrive through `onChange`.
    func evaluateWatches() {
        guard let client, state.canStep, let frame = currentFrame else { return }
        for expression in watches.expressions {
            client.request("evaluate", ["expression": expression, "frameId": frame.id, "context": "watch"]) { [weak self] result in
                DispatchQueue.main.async {
                    guard let self else { return }
                    switch result {
                    case .success(let body): self.watchResults[expression] = body["result"] as? String ?? ""
                    case .failure(let error): self.watchResults[expression] = "error: \(error.message)"
                    }
                    self.onChange()
                }
            }
        }
    }

    /// The parts of a variable (fields, elements) when it has them; the completion runs on the main thread.
    func children(of reference: Int, completion: @escaping ([DebugVariable]) -> Void) {
        guard reference > 0, let client else { return completion([]) }
        client.request("variables", ["variablesReference": reference]) { result in
            DispatchQueue.main.async {
                if case .success(let body) = result { completion(DAPClient.variables(from: body)) } else { completion([]) }
            }
        }
    }

    /// Evaluates one expression in the selected frame (for the Debug console and conditions).
    func evaluate(_ expression: String, completion: @escaping (String) -> Void) {
        guard let client, let frame = currentFrame else { return completion("not paused") }
        client.request("evaluate", ["expression": expression, "frameId": frame.id, "context": "repl"]) { result in
            DispatchQueue.main.async {
                switch result {
                case .success(let body): completion(body["result"] as? String ?? "")
                case .failure(let error): completion("error: \(error.message)")
                }
            }
        }
    }

    // MARK: control

    func resume() { send("continue") }
    func stepOver() { send("next") }
    func stepInto() { send("stepIn") }
    func stepOut() { send("stepOut") }
    func pause() { if state.canPause { send("pause") } }

    private func send(_ command: String) {
        guard let client, (command == "pause" ? state.canPause : state.canStep) else { return }
        if command != "pause" { state = .running }
        client.request(command, ["threadId": threadId]) { _ in }
    }

    /// Ends the session and the program.
    func stop() {
        guard let client, state.isActive else { return }
        client.request("disconnect", ["terminateDebuggee": !attached]) { [weak self] _ in DispatchQueue.main.async { self?.finish(forced: true) } }
        DispatchQueue.main.asyncAfter(deadline: .now() + 3) { [weak self] in self?.finish(forced: true) }
    }

    private func finish(forced: Bool = false) {
        guard !terminated else { return }
        terminated = true
        client?.onDisconnect = nil
        client?.close()
        client = nil
        if let buildFolder { try? FileManager.default.removeItem(at: buildFolder) }
        buildFolder = nil
        frames = []
        variables = []
        state = .ended(forced ? "stopped" : (exitCode.map { "exit \($0)" } ?? "exit 0"))
    }

    private func connectionClosed() {
        if state.isActive && !terminated { finish() }
    }

    private func fail(_ message: String) {
        output += message + "\n"
        onOutput(message + "\n")
        client?.close()
        client = nil
        terminated = true
        state = .ended("could not start")
    }
}

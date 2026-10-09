import AppKit
import ComputerCore
import Darwin
import ObjectiveC
import os
import SwiftUI
import Virtualization

private let log = Logger(subsystem: "com.pdparchitect.noodle.computer", category: "Windows")

/// Owns one Windows virtual machine. Windows runs on VZ only with two things VZ does not offer publicly:
/// emulated performance counters, without which its boot manager never finishes, and a display VZ's own
/// virtio-gpu cannot give it (that device takes the whole VM process down under Windows), so the display is
/// our own virtio-gpu. Input reaches VZ's USB keyboard and pointer directly, as VZVirtualMachineView would.
///
/// The first start sets Windows up with no network, so its welcome screens skip Windows Update; once the Noodle
/// agent says hello it shuts the guest down and boots it again, now set up, with the network.
@available(macOS 27, *)
@MainActor final class WindowsComputer: NSObject, ObservableObject, VZVirtualMachineDelegate {
    let computer: Computer
    let directory: URL
    @Published private(set) var status: String?
    @Published private(set) var agentConnected = false {
        didSet {
            guard agentConnected != oldValue else { return }
            onAgentChange?(agentConnected)
            // Windows starts at its last mode; the window may want another.
            if agentConnected { Task { await applyScreen() } }
        }
    }
    /// Whether the agent, which Terminal and Files need, is there.
    var onAgentChange: ((Bool) -> Void)?
    private(set) var machine: VZVirtualMachine?
    private(set) var agent = WindowsAgent()
    private let gpu = WindowsGPU()
    /// The screen size Windows should have, in pixels: the window's while it resizes with it, else 1920 by 1080.
    private var wantedScreen = WindowsGPU.screen
    private var screenChange: Task<Void, Never>?

    /// Makes Windows follow `pixels`, or keep 1920 by 1080 when nil, once the window has settled.
    func showScreen(at pixels: CGSize?) {
        let size = pixels.map { WindowsDisplayMode.fit(width: Int($0.width), height: Int($0.height)) } ?? WindowsGPU.screen
        guard size != wantedScreen else { return }
        wantedScreen = size
        screenChange?.cancel()
        screenChange = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(500))
            guard !Task.isCancelled else { return }
            await self?.applyScreen()
        }
    }

    /// The display reports the size, and the agent asks Windows to switch to it; Windows keeps its mode otherwise.
    private func applyScreen() async {
        let size = wantedScreen
        gpu.resize(width: size.width, height: size.height)
        guard agentConnected, lastFrame.map({ ($0.width, $0.height) != size }) ?? true else { return }
        // The driver offers the new mode once it has read the display again.
        try? await Task.sleep(for: .seconds(1))
        guard wantedScreen == size, agentConnected else { return }
        let result = try? await agent.run(WindowsDisplayMode.switchCommand(width: size.width, height: size.height))
        if result?.status != 0 { log.error("screen switch to \(size.width)x\(size.height) ended with \(result.map { String($0.status) } ?? "no answer", privacy: .public)") }
    }
    private var setUp: Bool
    private var settingUp = false
    /// The agent was sent an update this run; it is not sent again, so a failed update cannot loop.
    private var agentUpdateSent = false
    private var cycling = false
    /// Times Windows stopped by itself before setup finished; it is started again a few times.
    private var setupStops = 0
    var onStop: ((Error?) -> Void)?
    var onSetUp: (() -> Void)?
    /// The view showing the screen; frames arrive for it from the device queue.
    var onFrame: ((CGImage) -> Void)?
    private(set) var lastFrame: CGImage?

    init(computer: Computer, directory: URL) {
        self.computer = computer
        self.directory = directory
        setUp = computer.installationComplete
        super.init()
        gpu.onFrame = { [weak self] image in
            Task { @MainActor in
                guard let self else { return }
                self.lastFrame = image
                self.status = nil
                self.onFrame?(image)
            }
        }
        gpu.onGuestReboot = { [weak self] in Task { @MainActor in await self?.powerCycle() } }
    }

    /// The bundled agent's version, from its source.
    static let agentVersion: String = {
        guard let url = Bundle.main.resourceURL?.appendingPathComponent("Windows/guest/NoodleAgent.cs"),
              let source = try? String(contentsOf: url, encoding: .utf8),
              let range = source.range(of: #"const string Version = "[0-9]+""#, options: .regularExpression) else { return "" }
        return String(source[range].split(separator: "\"")[1])
    }()

    /// Sends Windows the bundled agent, which update.ps1 builds and starts in place of the running one.
    private func updateAgent(from old: String) async {
        agentUpdateSent = true
        log.info("updating the agent from \(old, privacy: .public) to \(Self.agentVersion, privacy: .public)")
        let agent = agent
        let files = WindowsFileService { agent }
        do {
            guard let guest = Bundle.main.resourceURL?.appendingPathComponent("Windows/guest") else { throw ComputerError("The agent is missing.") }
            for name in ["NoodleAgent.cs", "update.ps1"] {
                try await files.upload(guest.appendingPathComponent(name), to: "/C/noodle/" + name, progress: { _ in })
            }
        } catch {
            // The agent that is there still works.
            log.error("agent update failed: \(error.localizedDescription, privacy: .public)")
            if self.agent === agent { agentConnected = true }
            return
        }
        // update.ps1 stops this agent, so the call ends with it; the new agent says hello.
        _ = try? await agent.run(#"start "" /b powershell -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File C:\noodle\update.ps1 <nul >nul 2>&1"#)
    }

    func start() async throws {
        let agent = WindowsAgent()
        self.agent = agent
        agentConnected = false
        agent.onHello = { [weak self, weak agent] hello in
            Task { @MainActor in
                guard let self, let agent, self.agent === agent else { return }
                // The first hello finishes setup, which restarts Windows; the agent is there after that.
                guard self.setUp else { self.helloArrived(); return }
                if hello.agent != Self.agentVersion, !self.agentUpdateSent {
                    self.agentConnected = false
                    await self.updateAgent(from: hello.agent)
                } else {
                    self.agentConnected = true
                }
            }
        }
        let configuration = try Self.configuration(
            cpus: computer.cpuCount, memoryGiB: computer.memoryGiB, directory: directory,
            network: setUp && computer.networkEnabled, gpu: gpu, consoles: [agent.configuration()])
        let machine = VZVirtualMachine(configuration: configuration)
        machine.delegate = self
        self.machine = machine
        status = setUp ? "Starting Windows…" : "Setting up Windows…"
        log.info("starting, set up: \(self.setUp), network: \(self.setUp && self.computer.networkEnabled)")
        try await machine.start()
    }

    /// Asks Windows to shut down, through the agent when it is there; forces it off if it has not after a minute.
    func shutDown() async {
        guard let machine, machine.state != .stopped else { return }
        if agentConnected { _ = try? await agent.call(20) } else { try? machine.requestStop() }
        for _ in 0..<120 where self.machine === machine && machine.state != .stopped {
            try? await Task.sleep(for: .milliseconds(500))
        }
        if self.machine === machine, machine.state != .stopped { try? await forceStop() }
    }

    func forceStop() async throws {
        guard let machine, machine.state != .stopped else { return }
        try await machine.stop()
        finish(nil)
    }

    func restart() async throws {
        guard agentConnected else { throw ComputerError("Windows is still starting.") }
        _ = try await agent.call(24)
    }

    private func helloArrived() {
        guard !setUp, !settingUp else { return }
        // Set up: keep it, then boot again with the network.
        settingUp = true
        setUp = true
        onSetUp?()
        status = "Finishing setup…"
        Task { try? await agent.call(20) }
    }

    /// VZ restarts a guest in place, and Windows then hangs in the firmware; a fresh start does not.
    private func powerCycle() async {
        guard let machine, !cycling, machine.state == .running else { return }
        log.info("guest restarted; power-cycling")
        cycling = true
        defer { cycling = false }
        status = "Restarting Windows…"
        agentConnected = false
        agent.disconnected("Windows restarted.")
        do {
            try await machine.stop()
            try await machine.start()
        } catch { finish(error) }
    }

    private func finish(_ error: Error?) {
        log.info("stopped\(error.map { ": \($0.localizedDescription)" } ?? "")")
        agentConnected = false
        agent.disconnected("Windows stopped.")
        status = nil
        onStop?(error)
        onStop = nil
    }

    nonisolated func guestDidStop(_ virtualMachine: VZVirtualMachine) {
        Task { @MainActor in
            guard virtualMachine === self.machine else { return }
            if self.settingUp || (!self.setUp && self.setupStops < 3) {
                // Setup finished and now needs the network, or Windows stopped itself during setup.
                if !self.settingUp { self.setupStops += 1 }
                self.settingUp = false
                self.agent.disconnected("Windows is restarting.")
                do { try await self.start() } catch { self.finish(error) }
            } else {
                self.finish(nil)
            }
        }
    }

    nonisolated func virtualMachine(_ virtualMachine: VZVirtualMachine, didStopWithError error: Error) {
        Task { @MainActor in
            guard virtualMachine === self.machine else { return }
            self.finish(error)
        }
    }

    static func configuration(cpus: Int, memoryGiB: Int, directory: URL, media: URL? = nil, network: Bool,
                              gpu: WindowsGPU?, consoles: [VZVirtioConsoleDeviceConfiguration]) throws -> VZVirtualMachineConfiguration {
        guard VZVirtualMachine.isSupported else { throw ComputerError("Virtualization is unavailable on this Mac.") }
        let config = VZVirtualMachineConfiguration()
        config.cpuCount = cpus
        config.memorySize = UInt64(memoryGiB) * 1_073_741_824
        let platform = VZGenericPlatformConfiguration()
        let identifier = directory.appendingPathComponent("MachineIdentifier")
        if let data = try? Data(contentsOf: identifier), let saved = VZGenericMachineIdentifier(dataRepresentation: data) {
            platform.machineIdentifier = saved
        } else {
            try platform.machineIdentifier.dataRepresentation.write(to: identifier)
        }
        try WindowsPrivateVirtualization.emulatePerformanceCounters(platform)
        config.platform = platform
        let nvram = directory.appendingPathComponent("EFI.nvram")
        let boot = VZEFIBootLoader()
        boot.variableStore = FileManager.default.fileExists(atPath: nvram.path)
            ? VZEFIVariableStore(url: nvram) : try VZEFIVariableStore(creatingVariableStoreAt: nvram)
        config.bootLoader = boot
        config.storageDevices = [VZNVMExpressControllerDeviceConfiguration(attachment: try VZDiskImageStorageDeviceAttachment(
            url: directory.appendingPathComponent("Disk.img"), readOnly: false))]
        if let media {
            config.storageDevices.append(VZUSBMassStorageDeviceConfiguration(
                attachment: try VZDiskImageStorageDeviceAttachment(url: media, readOnly: false)))
        }
        if network {
            let device = VZVirtioNetworkDeviceConfiguration()
            device.attachment = VZNATNetworkDeviceAttachment()
            config.networkDevices = [device]
        }
        if let gpu { config.customVirtioDevices = [gpu.configuration()] }
        config.consoleDevices = consoles
        config.usbControllers = [VZXHCIControllerConfiguration()]
        config.keyboards = [VZUSBKeyboardConfiguration()]
        config.pointingDevices = [VZUSBScreenCoordinatePointingDeviceConfiguration()]
        config.entropyDevices = [VZVirtioEntropyDeviceConfiguration()]
        try config.validate()
        return config
    }
}

/// The private VZ calls Windows needs, in one place. Each checks that macOS still offers it.
enum WindowsPrivateVirtualization {
    static func emulatePerformanceCounters(_ platform: VZGenericPlatformConfiguration) throws {
        guard platform.responds(to: NSSelectorFromString("_setPerformanceMonitoringUnitEmulationEnabled:")) else {
            throw ComputerError("This version of macOS cannot run Windows.")
        }
        platform.setValue(true, forKey: "performanceMonitoringUnitEmulationEnabled")
    }

    private typealias InitLocation = @convention(c) (AnyObject, Selector, CGPoint, UInt) -> AnyObject

    private static func make(_ name: String, with event: NSEvent) -> AnyObject? {
        guard let type = NSClassFromString(name) as? NSObject.Type else { return nil }
        let object = type.perform(NSSelectorFromString("alloc")).takeUnretainedValue()
        return object.perform(NSSelectorFromString("initWithEvent:"), with: event)?.takeUnretainedValue()
    }

    private static func devices(_ machine: VZVirtualMachine, _ selector: String) -> [NSObject] {
        guard machine.responds(to: NSSelectorFromString(selector)) else { return [] }
        return (machine.perform(NSSelectorFromString(selector))?.takeUnretainedValue() as? [NSObject]) ?? []
    }

    /// `location` runs from 0 to 1 across the screen, from its top-left corner; `buttons` has bit 0 for the
    /// left button and bit 1 for the right one.
    static func pointer(_ machine: VZVirtualMachine, at location: CGPoint, buttons: UInt) {
        guard let type = NSClassFromString("_VZScreenCoordinatePointerEvent") as? NSObject.Type else { return }
        let selector = NSSelectorFromString("initWithLocation:pressedButtons:")
        let object = type.perform(NSSelectorFromString("alloc")).takeUnretainedValue()
        let initialise = unsafeBitCast(class_getMethodImplementation(type, selector), to: InitLocation.self)
        let event = initialise(object, selector, location, buttons)
        devices(machine, "_pointingDevices").first?.perform(NSSelectorFromString("sendPointerEvents:"), with: [event])
    }

    private typealias InitScroll = @convention(c) (AnyObject, Selector, Double, Double, Double, Double, UInt, UInt) -> AnyObject

    static func scroll(_ machine: VZVirtualMachine, _ event: NSEvent) {
        guard var scroll = make("_VZScrollWheelEvent", with: event) as? NSObject else { return }
        let selector = NSSelectorFromString("initWithScrollingDeltaX:scrollingDeltaY:acceleratedScrollingDeltaX:acceleratedScrollingDeltaY:scrollPhase:momentumPhase:")
        if event.isDirectionInvertedFromDevice, let type = NSClassFromString("_VZScrollWheelEvent") as? NSObject.Type,
           type.instancesRespond(to: selector) {
            func value<T>(_ key: String, _ fallback: T) -> T { scroll.value(forKey: key) as? T ?? fallback }
            let deltas = WindowsScroll(deltaX: value("scrollingDeltaX", 0.0), deltaY: value("scrollingDeltaY", 0.0),
                                       acceleratedDeltaX: value("acceleratedScrollingDeltaX", 0.0),
                                       acceleratedDeltaY: value("acceleratedScrollingDeltaY", 0.0))
                .forGuest(directionInvertedFromDevice: true)
            let object = type.perform(NSSelectorFromString("alloc")).takeUnretainedValue()
            let initialise = unsafeBitCast(class_getMethodImplementation(type, selector), to: InitScroll.self)
            guard let reversed = initialise(object, selector, deltas.deltaX, deltas.deltaY, deltas.acceleratedDeltaX,
                                            deltas.acceleratedDeltaY, value("scrollPhase", UInt(0)), value("momentumPhase", UInt(0))) as? NSObject else { return }
            scroll = reversed
        }
        devices(machine, "_pointingDevices").first?.perform(NSSelectorFromString("sendScrollWheelEvents:"), with: [scroll])
    }

    static func key(_ machine: VZVirtualMachine, _ event: NSEvent) {
        guard let key = make("_VZKeyEvent", with: event) else { return }
        devices(machine, "_keyboards").first?.perform(NSSelectorFromString("sendKeyEvents:"), with: [key])
    }
}

// MARK: - Display

/// A 2D virtio-gpu (device 16) for virtio-win's viogpudo driver, on macOS 27's custom Virtio devices.
/// The cursor queue is acknowledged and ignored: Windows then draws its pointer into the frames.
@available(macOS 27, *)
final class WindowsGPU: NSObject, VZCustomVirtioDeviceConfigurationDelegate, VZCustomVirtioDeviceDelegate, @unchecked Sendable {
    static let screen = (width: 1920, height: 1080)
    private struct Resource {
        var width: Int, height: Int, format: UInt32
        var pixels: UnsafeMutableRawPointer
        var backing: [VZGuestMemoryMapping] = []
    }
    private let queue = DispatchQueue(label: "com.pdparchitect.noodle.computer.windows-gpu")
    private var device: VZCustomVirtioDevice?
    private var resources: [UInt32: Resource] = [:]
    private var scanout: UInt32 = 0
    private var detector = FirmwareSessionDetector()
    private var firmware = true
    private var size = WindowsGPU.screen
    /// A size change waits in events_read until the driver asks for the display again.
    private var displayChanged = false
    /// Lets the firmware draw too, for looking at the boot screens while diagnosing an install. VZ may then
    /// crash when Windows takes over, so it is never on otherwise.
    var servesFirmware = false
    var onFrame: (@Sendable (CGImage) -> Void)?
    var onGuestReboot: (@Sendable () -> Void)?

    func configuration() -> VZCustomVirtioDeviceConfiguration {
        let configuration = VZCustomVirtioDeviceConfiguration()
        configuration.deviceID = 16
        configuration.pciClassID = 0x03
        configuration.pciSubclassID = 0x80
        configuration.virtioQueueCount = 2
        // VIRTIO_GPU_F_EDID: Windows' driver takes its resolution from the screen's EDID, and 1024 by 768 without one.
        configuration.optionalFeatures.subset0 = 1 << 1
        // struct virtio_gpu_config: events_read, events_clear, num_scanouts, num_capsets.
        configuration.deviceSpecificConfiguration = VZVirtioDeviceSpecificConfiguration(configurationData: Self.words(0, 0, 1, 0))
        configuration.provider = VZCustomVirtioDeviceDelegateProvider(deviceQueue: queue, delegate: self)
        return configuration
    }

    func customVirtioConfiguration(_ configuration: VZCustomVirtioDeviceConfiguration, didCreateDevice device: VZCustomVirtioDevice) {
        self.device = device
        device.delegate = self
        detector = FirmwareSessionDetector()
        firmware = true
        releaseResources()
    }

    /// Offers Windows a new screen size: its display info and EDID change, and VIRTIO_GPU_EVENT_DISPLAY says so.
    func resize(width: Int, height: Int) {
        let (width, height) = WindowsDisplayMode.fit(width: width, height: height)
        queue.async { [self] in
            guard size != (width, height) else { return }
            size = (width, height)
            displayChanged = true
            device?.update(VZVirtioDeviceSpecificConfiguration(configurationData: Self.words(1, 0, 1, 0))) { _ in }
        }
    }

    func customVirtioDeviceDidAcceptDriverOk(_ device: VZCustomVirtioDevice) {
        let session = detector.driverReady(at: Date())
        log.info("display driver up: \(session.firmware ? "firmware, refused" : "Windows")\(session.guestRebooted ? ", guest restarted" : "")")
        firmware = session.firmware
        if session.guestRebooted { onGuestReboot?() }
    }

    func customVirtioDeviceWillReset(_ device: VZCustomVirtioDevice) {
        detector.reset(at: Date())
        releaseResources()
    }

    func customVirtioDevice(_ device: VZCustomVirtioDevice, didReceiveNotificationFor queue: VZVirtioQueue) {
        while let element = queue.nextElement() {
            if queue.queueIndex == 0 { control(element) }
            element.returnToQueue()
        }
    }

    private func releaseResources() {
        for resource in resources.values { resource.pixels.deallocate() }
        resources = [:]
        scanout = 0
    }

    private func control(_ element: VZVirtioQueueElement) {
        guard let request = try? element.readBytes(withExactLength: element.readBuffersAvailableByteCount), request.count >= 24 else { return }
        func u32(_ offset: Int) -> UInt32 { request.count >= offset + 4 ? request.subdata(in: offset..<offset + 4).withUnsafeBytes { $0.loadUnaligned(as: UInt32.self) } : 0 }
        func u64(_ offset: Int) -> UInt64 { request.count >= offset + 8 ? request.subdata(in: offset..<offset + 8).withUnsafeBytes { $0.loadUnaligned(as: UInt64.self) } : 0 }
        var body = Data()
        var reply: UInt32 = 0x1100 // OK_NODATA
        // The firmware is refused everything, so it builds no boot display to tear down.
        switch firmware && !servesFirmware ? 0 : u32(0) {
        case 0x0100: // GET_DISPLAY_INFO
            reply = 0x1101
            body = Self.words(0, 0, UInt32(size.width), UInt32(size.height), 1, 0) + Data(count: 15 * 24)
            if displayChanged {
                displayChanged = false
                device?.update(VZVirtioDeviceSpecificConfiguration(configurationData: Self.words(0, 0, 1, 0))) { _ in }
            }
        case 0x0101: // RESOURCE_CREATE_2D: id, format, width, height
            let id = u32(24), width = Int(u32(32)), height = Int(u32(36))
            guard (1...8192).contains(width), (1...8192).contains(height) else { reply = 0x1200; break }
            resources[id]?.pixels.deallocate()
            let pixels = UnsafeMutableRawPointer.allocate(byteCount: width * height * 4, alignment: 16)
            pixels.initializeMemory(as: UInt8.self, repeating: 0, count: width * height * 4)
            resources[id] = Resource(width: width, height: height, format: u32(28), pixels: pixels)
        case 0x0102: // RESOURCE_UNREF
            let id = u32(24)
            resources.removeValue(forKey: id)?.pixels.deallocate()
            if scanout == id { scanout = 0 }
        case 0x0103: // SET_SCANOUT: rect, scanout id, resource id
            scanout = u32(44)
        case 0x0104: // RESOURCE_FLUSH: rect, resource id
            if u32(40) == scanout { present() }
        case 0x0105: // TRANSFER_TO_HOST_2D: rect, offset, resource id
            transfer(x: Int(u32(24)), y: Int(u32(28)), width: Int(u32(32)), height: Int(u32(36)), offset: Int(u64(40)), id: u32(48))
        case 0x0106: // RESOURCE_ATTACH_BACKING: id, entries, then { address u64, length u32, padding u32 }
            let id = u32(24), count = Int(u32(28))
            var mappings: [VZGuestMemoryMapping] = []
            for index in 0..<min(count, 16_384) where 32 + index * 16 + 16 <= request.count {
                if let mapping = device?.guestMemoryMapping(atPhysicalAddress: u64(32 + index * 16), length: Int(u32(40 + index * 16))) {
                    mappings.append(mapping)
                }
            }
            resources[id]?.backing = mappings
        case 0x0107: // RESOURCE_DETACH_BACKING
            resources[u32(24)]?.backing = []
        case 0x010a: // GET_EDID: scanout; the reply carries the size and up to 1024 bytes
            let edid = DisplayEDID.bytes(width: size.width, height: size.height)
            reply = 0x1104
            body = Self.words(UInt32(edid.count), 0) + Data(edid) + Data(count: 1024 - edid.count)
        default:
            reply = 0x1200 // ERR_UNSPEC
        }
        // The response header echoes the request's fence.
        var header = Self.words(reply, u32(4) & 1)
        header.append(request.subdata(in: 8..<24))
        try? element.write(header + body)
    }

    private func transfer(x: Int, y: Int, width: Int, height: Int, offset: Int, id: UInt32) {
        guard let resource = resources[id], x >= 0, y >= 0, x < resource.width else { return }
        let stride = resource.width * 4
        let count = min(width, resource.width - x) * 4
        for row in 0..<height where y + row < resource.height {
            var skip = offset + row * stride, left = count
            var destination = resource.pixels + (y + row) * stride + x * 4
            for mapping in resource.backing where left > 0 {
                if skip >= mapping.length { skip -= mapping.length; continue }
                let bytes = min(mapping.length - skip, left)
                destination.copyMemory(from: mapping.mutableBytes + skip, byteCount: bytes)
                destination += bytes; left -= bytes; skip = 0
            }
        }
    }

    private func present() {
        guard let resource = resources[scanout], let onFrame else { return }
        let info: UInt32
        switch resource.format {
        case 3, 4: info = CGBitmapInfo.byteOrder32Big.rawValue | CGImageAlphaInfo.noneSkipFirst.rawValue
        case 67, 134: info = CGBitmapInfo.byteOrder32Big.rawValue | CGImageAlphaInfo.noneSkipLast.rawValue
        case 68, 121: info = CGBitmapInfo.byteOrder32Little.rawValue | CGImageAlphaInfo.noneSkipLast.rawValue
        default: info = CGBitmapInfo.byteOrder32Little.rawValue | CGImageAlphaInfo.noneSkipFirst.rawValue
        }
        let data = Data(bytes: resource.pixels, count: resource.width * resource.height * 4)
        guard let provider = CGDataProvider(data: data as CFData),
              let image = CGImage(width: resource.width, height: resource.height, bitsPerComponent: 8, bitsPerPixel: 32,
                                  bytesPerRow: resource.width * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                  bitmapInfo: CGBitmapInfo(rawValue: info), provider: provider, decode: nil,
                                  shouldInterpolate: true, intent: .defaultIntent) else { return }
        onFrame(image)
    }

    private static func words(_ values: UInt32...) -> Data {
        values.reduce(into: Data()) { data, value in withUnsafeBytes(of: value.littleEndian) { data.append(contentsOf: $0) } }
    }
}

/// The screen, with the Mac's mouse and keyboard going to Windows while it has focus.
@available(macOS 27, *)
struct WindowsDisplay: NSViewRepresentable {
    @ObservedObject var computer: WindowsComputer
    var resizes = false
    func makeNSView(context: Context) -> WindowsScreenView {
        let view = WindowsScreenView()
        view.attach(computer)
        view.resizes = resizes
        return view
    }
    func updateNSView(_ view: WindowsScreenView, context: Context) {
        if view.computer !== computer { view.attach(computer) }
        view.resizes = resizes
        view.setStatus(computer.status)
    }
}

@available(macOS 27, *)
final class WindowsScreenView: NSView {
    private(set) weak var computer: WindowsComputer?
    private let label = NSTextField(labelWithString: "")
    private let spinner = NSProgressIndicator()
    private var imageSize = CGSize(width: 1024, height: 768)
    private var buttons: UInt = 0
    var resizes = false { didSet { if resizes != oldValue { applySize() } } }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        applySize()
    }
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        applySize()
    }
    /// Windows takes the view's size in pixels while the setting is on.
    private func applySize() {
        guard window != nil, bounds.width >= 1, bounds.height >= 1 else { return }
        let scale = window?.backingScaleFactor ?? 1
        computer?.showScreen(at: resizes ? CGSize(width: bounds.width * scale, height: bounds.height * scale) : nil)
    }

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.backgroundColor = NSColor.black.cgColor
        layer?.contentsGravity = .resizeAspect
        label.textColor = .white
        label.font = .systemFont(ofSize: 17, weight: .medium)
        spinner.style = .spinning
        spinner.controlSize = .small
        let stack = NSStackView(views: [spinner, label])
        stack.orientation = .vertical
        stack.spacing = 12
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        stack.centerXAnchor.constraint(equalTo: centerXAnchor).isActive = true
        stack.centerYAnchor.constraint(equalTo: centerYAnchor).isActive = true
        setAccessibilityLabel("Windows screen")
    }
    required init?(coder: NSCoder) { nil }

    func attach(_ computer: WindowsComputer) {
        self.computer = computer
        defer { applySize() }
        computer.onFrame = { [weak self] image in self?.show(image) }
        if let frame = computer.lastFrame { show(frame) }
        setStatus(computer.status)
    }

    func setStatus(_ text: String?) {
        label.stringValue = text ?? ""
        label.isHidden = text == nil
        spinner.isHidden = text == nil
        if text == nil { spinner.stopAnimation(nil) } else { spinner.startAnimation(nil) }
        if text != nil, computer?.lastFrame == nil { layer?.contents = nil }
    }

    private func show(_ image: CGImage) {
        imageSize = CGSize(width: image.width, height: image.height)
        layer?.contents = image
    }

    override var acceptsFirstResponder: Bool { true }
    override func updateTrackingAreas() {
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: bounds, options: [.mouseMoved, .activeInKeyWindow, .inVisibleRect], owner: self))
        super.updateTrackingAreas()
    }

    /// Where the event falls on the screen, from 0 to 1 from its top-left corner; the image is fitted in the view.
    private func location(_ event: NSEvent) -> CGPoint {
        let point = convert(event.locationInWindow, from: nil)
        let scale = min(bounds.width / imageSize.width, bounds.height / imageSize.height)
        guard scale > 0 else { return .zero }
        let width = imageSize.width * scale, height = imageSize.height * scale
        let x = (point.x - (bounds.width - width) / 2) / width
        let y = isFlipped ? (point.y - (bounds.height - height) / 2) / height : 1 - (point.y - (bounds.height - height) / 2) / height
        return CGPoint(x: min(max(x, 0), 1), y: min(max(y, 0), 1))
    }

    private func pointer(_ event: NSEvent) {
        guard let machine = computer?.machine, machine.state == .running else { return }
        WindowsPrivateVirtualization.pointer(machine, at: location(event), buttons: buttons)
    }

    override func mouseMoved(with event: NSEvent) { pointer(event) }
    override func mouseDragged(with event: NSEvent) { pointer(event) }
    override func rightMouseDragged(with event: NSEvent) { pointer(event) }
    override func mouseDown(with event: NSEvent) { window?.makeFirstResponder(self); buttons |= 1; pointer(event) }
    override func mouseUp(with event: NSEvent) { buttons &= ~1; pointer(event) }
    override func rightMouseDown(with event: NSEvent) { window?.makeFirstResponder(self); buttons |= 2; pointer(event) }
    override func rightMouseUp(with event: NSEvent) { buttons &= ~2; pointer(event) }
    override func scrollWheel(with event: NSEvent) {
        if let machine = computer?.machine, machine.state == .running { WindowsPrivateVirtualization.scroll(machine, event) }
    }
    private func key(_ event: NSEvent) {
        if let machine = computer?.machine, machine.state == .running { WindowsPrivateVirtualization.key(machine, event) }
    }
    override func keyDown(with event: NSEvent) { key(event) }
    override func keyUp(with event: NSEvent) { key(event) }
    override func flagsChanged(with event: NSEvent) { key(event) }
    // ⌘-shortcuts go to Windows while it has focus, rather than to the Mac's menus.
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        guard window?.firstResponder === self, event.type == .keyDown else { return false }
        key(event)
        return true
    }
}

// MARK: - Agent

/// The Noodle agent in Windows, over the virtio-serial port "org.noodle.agent" (see Resources/Windows/guest).
/// Replies and output arrive on the channel a request opened; a new hello means the agent restarted.
final class WindowsAgent: @unchecked Sendable {
    struct Hello: Decodable, Sendable {
        let agent: String; let computer: String; let user: String; let home: String
        /// Why the agent last lost its connection, if it did.
        let reason: String?
    }
    private let lock = NSLock()
    /// One frame at a time: a large frame goes out in pieces, which another thread's frame must not split.
    private let writing = NSLock()
    private let host: FileHandle
    let guest: FileHandle
    private var decoder = WindowsAgentFrame.Decoder()
    private var nextChannel: UInt32 = 1
    private var handlers: [UInt32: (WindowsAgentFrame) -> Void] = [:]
    private var greeting: Hello?
    private var waiters: [CheckedContinuation<Hello, Error>] = []
    var onHello: ((Hello) -> Void)?

    init() {
        var pair: [Int32] = [0, 0]
        socketpair(AF_UNIX, SOCK_STREAM, 0, &pair)
        host = FileHandle(fileDescriptor: pair[0], closeOnDealloc: true)
        guest = FileHandle(fileDescriptor: pair[1], closeOnDealloc: true)
        host.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            if !data.isEmpty { self?.receive(data) }
        }
    }
    deinit { host.readabilityHandler = nil }

    var hello: Hello? { lock.withLock { greeting } }

    func configuration() -> VZVirtioConsoleDeviceConfiguration {
        let port = VZVirtioConsolePortConfiguration()
        port.name = "org.noodle.agent"
        port.attachment = VZFileHandleSerialPortAttachment(fileHandleForReading: guest, fileHandleForWriting: guest)
        let device = VZVirtioConsoleDeviceConfiguration()
        device.ports[0] = port
        return device
    }

    private func receive(_ data: Data) {
        let frames: [WindowsAgentFrame]
        do { frames = try lock.withLock { try decoder.append(data) } } catch {
            lock.withLock { decoder = WindowsAgentFrame.Decoder() }
            disconnected(error.localizedDescription)
            return
        }
        for frame in frames {
            if frame.type == 100 {
                guard let hello = try? JSONDecoder().decode(Hello.self, from: frame.payload) else { continue }
                // A new hello is a new agent: whatever the old one was doing is gone.
                log.info("agent \(hello.agent, privacy: .public) hello from \(hello.computer, privacy: .public) as \(hello.user, privacy: .public)\(hello.reason.map { "; it had stopped: " + $0 } ?? "", privacy: .public)")
                disconnected("Windows restarted.")
                let waiting = lock.withLock { () -> [CheckedContinuation<Hello, Error>] in
                    greeting = hello
                    defer { waiters = [] }
                    return waiters
                }
                for waiter in waiting { waiter.resume(returning: hello) }
                onHello?(hello)
            } else if let handler = lock.withLock({ handlers[frame.channel] }) {
                handler(frame)
            }
        }
    }

    /// Fails everything waiting on the agent, as when Windows stops or restarts.
    func disconnected(_ reason: String) {
        log.info("agent disconnected: \(reason, privacy: .public)")
        let pending = lock.withLock { () -> [(UInt32, (WindowsAgentFrame) -> Void)] in
            greeting = nil
            defer { handlers = [:] }
            return Array(handlers)
        }
        for (channel, handler) in pending { handler(WindowsAgentFrame(type: 111, channel: channel, payload: Data(reason.utf8))) }
    }

    func waitForHello() async throws -> Hello {
        try await withCheckedThrowingContinuation { continuation in
            let ready = lock.withLock { () -> Hello? in
                if let greeting { return greeting }
                waiters.append(continuation)
                return nil
            }
            if let ready { continuation.resume(returning: ready) }
        }
    }

    func send(_ type: UInt8, channel: UInt32, payload: Data = Data()) {
        let frame = WindowsAgentFrame(type: type, channel: channel, payload: payload).encoded
        writing.withLock { host.write(frame) }
    }

    /// Opens a channel whose frames go to `handler`, on a background queue.
    func open(_ handler: @escaping (WindowsAgentFrame) -> Void) -> UInt32 {
        lock.withLock {
            let channel = nextChannel
            nextChannel = nextChannel == UInt32.max ? 1 : nextChannel + 1
            handlers[channel] = handler
            return channel
        }
    }

    func close(_ channel: UInt32) { _ = lock.withLock { handlers.removeValue(forKey: channel) } }

    /// One request and its JSON result.
    @discardableResult
    func call(_ type: UInt8, _ payload: Data = Data()) async throws -> Data {
        try await withCheckedThrowingContinuation { continuation in
            let gate = OnceGate()
            var channel: UInt32 = 0
            channel = open { [weak self] frame in
                guard frame.type == 110 || frame.type == 111, gate.claim() else { return }
                self?.close(channel)
                if frame.type == 110 { continuation.resume(returning: frame.payload) }
                else { continuation.resume(throwing: ComputerError(String(decoding: frame.payload, as: UTF8.self))) }
            }
            send(type, channel: channel, payload: payload)
        }
    }

    @discardableResult
    func call<T: Encodable>(_ type: UInt8, json: T) async throws -> Data {
        try await call(type, JSONEncoder().encode(json))
    }

    /// Runs a command line with cmd.exe and returns what it printed and its exit code.
    func run(_ command: String, limit: Int = 1 << 20) async throws -> (output: String, status: Int32) {
        try await withCheckedThrowingContinuation { continuation in
            let gate = OnceGate()
            let output = LockedData(limit: limit)
            var channel: UInt32 = 0
            channel = open { [weak self] frame in
                switch frame.type {
                case 101, 103: output.append(frame.payload)
                case 102 where gate.claim():
                    self?.close(channel)
                    let status = frame.payload.count >= 4 ? frame.payload.withUnsafeBytes { $0.loadUnaligned(as: Int32.self) } : -1
                    continuation.resume(returning: (String(decoding: output.data, as: UTF8.self), status))
                case 111 where gate.claim():
                    self?.close(channel)
                    continuation.resume(throwing: ComputerError(String(decoding: frame.payload, as: UTF8.self)))
                default: break
                }
            }
            send(1, channel: channel, payload: (try? JSONEncoder().encode(["cmd": command])) ?? Data())
        }
    }
}

private final class OnceGate: @unchecked Sendable {
    private let lock = NSLock()
    private var done = false
    func claim() -> Bool { lock.withLock { defer { done = true }; return !done } }
}

private final class LockedData: @unchecked Sendable {
    private let lock = NSLock()
    private var buffer = Data()
    private let limit: Int
    init(limit: Int) { self.limit = limit }
    func append(_ data: Data) { lock.withLock { if buffer.count < limit { buffer.append(data.prefix(limit - buffer.count)) } } }
    var data: Data { lock.withLock { buffer } }
}

// MARK: - Terminal and Files

/// A PowerShell console in Windows, through the agent's ConPTY session.
@MainActor final class WindowsTerminalConnection {
    let agent: WindowsAgent
    let terminal: GuestTerminal
    private var channel: UInt32?
    private var input: Task<Void, Never>?
    /// The shell exited or Windows restarted; opening Terminal again starts a new one.
    private(set) var ended = false

    init(agent: WindowsAgent, terminal: GuestTerminal) { self.agent = agent; self.terminal = terminal }

    func start() {
        let io = terminal.io
        try? io.write(Data("Starting PowerShell…\r\n".utf8))
        let opened = Date()
        var first = true
        let channel = agent.open { [weak self] frame in
            switch frame.type {
            case 101:
                if first { first = false; log.info("console output after \(Int(Date().timeIntervalSince(opened) * 1000)) ms") }
                try? io.write(frame.payload)
            case 102: try? io.write(Data("\r\n[PowerShell exited]\r\n".utf8))
            case 111: try? io.write(Data("\r\n\(String(decoding: frame.payload, as: UTF8.self))\r\n".utf8))
            default: return
            }
            if frame.type != 101 { Task { @MainActor in self?.ended = true } }
        }
        self.channel = channel
        let screen = terminal.view.getTerminal()
        let request = ["cmd": "powershell.exe -NoLogo", "pty": true, "cols": screen.cols, "rows": screen.rows] as [String: Any]
        agent.send(1, channel: channel, payload: (try? JSONSerialization.data(withJSONObject: request)) ?? Data())
        terminal.resize = { [agent] columns, rows in
            var size = Data()
            withUnsafeBytes(of: Int16(clamping: columns).littleEndian) { size.append(contentsOf: $0) }
            withUnsafeBytes(of: Int16(clamping: rows).littleEndian) { size.append(contentsOf: $0) }
            agent.send(3, channel: channel, payload: size)
        }
        input = Task { [agent] in
            for await data in io.stream() { agent.send(2, channel: channel, payload: data) }
        }
    }

    func close() {
        input?.cancel()
        if let channel {
            agent.send(5, channel: channel)
            agent.close(channel)
        }
        channel = nil
        terminal.io.finish()
    }
}

/// Windows files for the same browser, preview, import, export and drag workflows the other computers use.
/// Hidden and system files stay out of listings, as in File Explorer.
final class WindowsFileService: ComputerFileService, @unchecked Sendable {
    private let agent: () -> WindowsAgent?
    init(agent: @escaping () -> WindowsAgent?) { self.agent = agent }

    private struct Item: Decodable { let name: String; let kind: String; let size: Int64; let modified: Int64; let version: String; let hidden: Bool? }

    private func connected() throws -> WindowsAgent {
        guard let agent = agent(), agent.hello != nil else { throw ComputerError("Windows is still starting. Try again in a moment.") }
        return agent
    }

    private func path(_ guest: String) throws -> String {
        guard let path = try WindowsPath.windows(guest) else { throw ComputerError("Choose a folder on a drive.") }
        return path
    }

    func homeDirectory() async throws -> String {
        let agent = try connected()
        guard let home = agent.hello?.home else { throw ComputerError("Windows did not say where the home folder is.") }
        return try WindowsPath.guest(home)
    }

    func list(_ guest: String) async throws -> [GuestFile] {
        let agent = try connected()
        let target = try WindowsPath.windows(guest)
        let items = try JSONDecoder().decode([Item].self, from: try await agent.call(10, Data((target ?? "").utf8)))
        guard items.count <= 5000 else { throw ComputerError("Invalid folder listing.") }
        let files = try items.compactMap { item -> GuestFile? in
            if target == nil {
                guard let drive = WindowsPath.drive(item.name) else { return nil }
                return GuestFile(name: drive, kind: "directory", size: 0, modified: 0, version: "")
            }
            guard item.hidden != true else { return nil }
            try GuestFile.validateName(item.name)
            guard item.size >= 0, item.version.utf8.count <= 200, ["file", "directory", "symlink"].contains(item.kind) else {
                throw ComputerError("Invalid file metadata.")
            }
            return GuestFile(name: item.name, kind: item.kind, size: item.size, modified: item.modified, version: item.version)
        }
        return files.sorted { a, b in a.directory != b.directory ? a.directory : a.name.localizedStandardCompare(b.name) == .orderedAscending }
    }

    func stat(_ guest: String) async throws -> GuestFile {
        let item = try JSONDecoder().decode(Item.self, from: try await connected().call(18, Data(try path(guest).utf8)))
        return GuestFile(name: item.name, kind: item.kind, size: item.size, modified: item.modified, version: item.version)
    }

    func read(_ file: GuestFile, path guest: String, to destination: URL, preview: Bool,
              progress: @escaping @Sendable (Int64) -> Void) async throws {
        let limit = preview ? PreviewPolicy.fileLimit : FileImportPlan.fileLimit
        guard file.regular, file.size >= 0, file.size <= limit else { throw ComputerError("This file cannot be previewed or transferred.") }
        let agent = try connected()
        let output = try FileOutput(limit: file.size, url: destination, progress: progress)
        let request = try JSONEncoder().encode(["path": try path(guest), "version": file.version])
        do {
            try await withTaskCancellationHandler {
                try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                    let gate = OnceGate()
                    var channel: UInt32 = 0
                    channel = agent.open { frame in
                        switch frame.type {
                        case 112:
                            do { try output.write(frame.payload) } catch {
                                if gate.claim() { agent.close(channel); continuation.resume(throwing: error) }
                            }
                        case 113 where gate.claim(): agent.close(channel); continuation.resume()
                        case 111 where gate.claim():
                            agent.close(channel)
                            continuation.resume(throwing: ComputerError(String(decoding: frame.payload, as: UTF8.self)))
                        default: break
                        }
                    }
                    agent.send(11, channel: channel, payload: request)
                }
            } onCancel: { output.cancel() }
            _ = try output.finish(expected: file.size)
        } catch { output.cancel(); throw error }
    }

    func upload(_ source: URL, to guest: String, progress: @escaping @Sendable (Int64) async -> Void) async throws {
        let values = try source.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey])
        guard values.isRegularFile == true, values.isSymbolicLink != true,
              let size = values.fileSize, size >= 0, size <= FileImportPlan.fileLimit else { throw ComputerError("Choose a regular file up to 8 GB.") }
        let agent = try connected()
        let target = try path(guest)
        let input = try FileInput(url: source, limit: Int64(size))
        let result = ResultBox()
        let channel = agent.open { frame in result.set(frame) }
        defer { agent.close(channel) }
        agent.send(12, channel: channel, payload: Data(target.utf8))
        var sent: Int64 = 0
        do {
            for await data in input.stream() {
                try Task.checkCancellation()
                if let failure = result.failure { throw failure }
                // Small, paced frames: Windows' serial driver fails reads ("Insufficient system resources") when
                // data arrives faster than it hands it on.
                var offset = data.startIndex
                while offset < data.endIndex {
                    let end = min(offset + 2048, data.endIndex)
                    agent.send(14, channel: channel, payload: data.subdata(in: offset..<end))
                    offset = end
                    try await Task.sleep(for: .microseconds(500))
                }
                sent += Int64(data.count)
                await progress(sent)
            }
            try Task.checkCancellation()
            guard sent == Int64(size) else { throw ComputerError("The selected file changed during import.") }
            agent.send(15, channel: channel)
            try await result.wait()
        } catch {
            input.cancel()
            agent.send(23, channel: channel)
            throw error
        }
    }

    func createImportDirectory(_ guest: String) async throws { try await change("mkdir", path: guest, extra: []) }

    func change(_ operation: String, path guest: String, extra: [String]) async throws {
        let agent = try connected()
        let target = try path(guest)
        try Task.checkCancellation()
        switch operation {
        case "mkdir": try await agent.call(17, Data(target.utf8))
        case "remove": try await agent.call(16, Data(target.utf8))
        case "rename":
            guard extra.count == 1 else { throw ComputerError("Missing destination.") }
            try await agent.call(19, json: ["path": target, "destination": try path(extra[0])])
        case "copy":
            guard extra.count == 2 else { throw ComputerError("Missing file version or destination.") }
            try await agent.call(22, json: ["path": target, "version": extra[0], "destination": try path(extra[1])])
        default: throw ComputerError("Unsupported file operation.")
        }
    }

    func download(_ guest: String, to destination: URL) async throws -> Int64 {
        let file = try await stat(guest)
        let manager = FileManager.default
        let folder = try manager.url(for: .itemReplacementDirectory, in: .userDomainMask, appropriateFor: destination, create: true)
        defer { try? manager.removeItem(at: folder) }
        let staged = folder.appendingPathComponent("download")
        try await read(file, path: guest, to: staged, preview: false, progress: { _ in })
        if manager.fileExists(atPath: destination.path) { _ = try manager.replaceItemAt(destination, withItemAt: staged) }
        else { try manager.moveItem(at: staged, to: destination) }
        return file.size
    }
}

/// The outcome of an upload: the agent's result, or the error that ended it early.
private final class ResultBox: @unchecked Sendable {
    private let lock = NSLock()
    private var outcome: Result<Void, Error>?
    private var waiter: CheckedContinuation<Void, Error>?
    var failure: Error? { lock.withLock { if case .failure(let error) = outcome { return error }; return nil } }
    func set(_ frame: WindowsAgentFrame) {
        let result: Result<Void, Error>
        switch frame.type {
        case 110: result = .success(())
        case 111: result = .failure(ComputerError(String(decoding: frame.payload, as: UTF8.self)))
        default: return
        }
        let waiting = lock.withLock { () -> CheckedContinuation<Void, Error>? in
            guard outcome == nil else { return nil }
            outcome = result
            defer { waiter = nil }
            return waiter
        }
        waiting?.resume(with: result)
    }
    func wait() async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            let ready = lock.withLock { () -> Result<Void, Error>? in
                if let outcome { return outcome }
                waiter = continuation
                return nil
            }
            if let ready { continuation.resume(with: ready) }
        }
    }
}

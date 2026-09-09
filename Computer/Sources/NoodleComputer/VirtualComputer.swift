import AppKit
import ComputerCore
import Virtualization

/// Owns one VZ machine. All VZ calls and delegate callbacks use the main queue.
@MainActor
final class VirtualComputer: NSObject, VZVirtualMachineDelegate {
    let machine: VZVirtualMachine
    var onStop: ((Error?) -> Void)?
    private var installer: VZMacOSInstaller?
    private var progressObservation: NSKeyValueObservation?
    private var installationStarted = false

    init(computer: Computer, directory: URL, bootInstaller: Bool) throws {
        machine = VZVirtualMachine(
            configuration: try Self.configuration(computer, directory: directory, bootInstaller: bootInstaller))
        super.init()
        machine.delegate = self
    }

    static func configuration(_ computer: Computer, directory: URL, bootInstaller: Bool) throws
        -> VZVirtualMachineConfiguration
    {
        guard VZVirtualMachine.isSupported else { throw ComputerError("Virtualization is unavailable on this Mac.") }
        let config = VZVirtualMachineConfiguration()
        config.cpuCount = computer.cpuCount
        config.memorySize = UInt64(computer.memoryGiB) * 1_073_741_824
        config.entropyDevices = [VZVirtioEntropyDeviceConfiguration()]
        config.memoryBalloonDevices = [VZVirtioTraditionalMemoryBalloonDeviceConfiguration()]
        if computer.networkEnabled {
            let network = VZVirtioNetworkDeviceConfiguration()
            network.attachment = VZNATNetworkDeviceAttachment()
            if let address = computer.macAddress, let mac = VZMACAddress(string: address) { network.macAddress = mac }
            config.networkDevices = [network]
        }
        let disk = VZVirtioBlockDeviceConfiguration(
            attachment: try VZDiskImageStorageDeviceAttachment(
                url: directory.appendingPathComponent("Disk.img"), readOnly: false))
        config.storageDevices = [disk]

        if computer.kind == .macOS {
            let platform = VZMacPlatformConfiguration()
            guard
                let hardware = VZMacHardwareModel(
                    dataRepresentation: try Data(contentsOf: directory.appendingPathComponent("HardwareModel"))),
                hardware.isSupported,
                let identifier = VZMacMachineIdentifier(
                    dataRepresentation: try Data(contentsOf: directory.appendingPathComponent("MachineIdentifier")))
            else {
                throw ComputerError("This Mac cannot run the saved macOS hardware configuration.")
            }
            platform.hardwareModel = hardware
            platform.machineIdentifier = identifier
            platform.auxiliaryStorage = VZMacAuxiliaryStorage(
                contentsOf: directory.appendingPathComponent("AuxiliaryStorage"))
            config.platform = platform
            config.bootLoader = VZMacOSBootLoader()
            let graphics = VZMacGraphicsDeviceConfiguration()
            graphics.displays = [
                VZMacGraphicsDisplayConfiguration(widthInPixels: 1920, heightInPixels: 1200, pixelsPerInch: 144)
            ]
            config.graphicsDevices = [graphics]
            config.keyboards = [VZMacKeyboardConfiguration()]
            config.pointingDevices = [VZMacTrackpadConfiguration()]
        } else {
            let platform = VZGenericPlatformConfiguration()
            if let data = try? Data(contentsOf: directory.appendingPathComponent("MachineIdentifier")),
                let identifier = VZGenericMachineIdentifier(dataRepresentation: data)
            {
                platform.machineIdentifier = identifier
            }
            config.platform = platform
            let boot = VZEFIBootLoader()
            boot.variableStore = VZEFIVariableStore(url: directory.appendingPathComponent("EFI.nvram"))
            config.bootLoader = boot
            let graphics = VZVirtioGraphicsDeviceConfiguration()
            graphics.scanouts = [VZVirtioGraphicsScanoutConfiguration(widthInPixels: 1920, heightInPixels: 1200)]
            config.graphicsDevices = [graphics]
            config.keyboards = [VZUSBKeyboardConfiguration()]
            config.pointingDevices = [VZUSBScreenCoordinatePointingDeviceConfiguration()]
            if bootInstaller {
                config.storageDevices.append(
                    VZUSBMassStorageDeviceConfiguration(
                        attachment: try VZDiskImageStorageDeviceAttachment(
                            url: directory.appendingPathComponent("Installer.iso"), readOnly: true)))
            }
        }
        let sound = VZVirtioSoundDeviceConfiguration()
        let output = VZVirtioSoundDeviceOutputStreamConfiguration()
        output.sink = VZHostAudioOutputStreamSink()
        sound.streams = [output]
        config.audioDevices = [sound]
        try config.validate()
        return config
    }

    func start() async throws { try await machine.start() }
    func stop() async throws { try await machine.stop() }
    func requestShutdown() throws { try machine.requestStop() }

    func install(from url: URL, progress: @escaping @MainActor (Double) -> Void) async throws {
        let installer = VZMacOSInstaller(virtualMachine: machine, restoringFromImageAt: url)
        self.installer = installer
        progressObservation = installer.progress.observe(\.fractionCompleted, options: [.initial, .new]) { value, _ in
            let fraction = value.fractionCompleted
            Task { @MainActor in progress(fraction) }
        }
        defer {
            installationStarted = false
            progressObservation = nil
            self.installer = nil
        }
        try await withTaskCancellationHandler {
            try Task.checkCancellation()
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                installer.install { result in continuation.resume(with: result) }
                installationStarted = true
            }
            try Task.checkCancellation()
        } onCancel: {
            Task { @MainActor [weak self] in
                // Apple requires install() to have started before cancelling its
                // Progress. Never stop the VM while installation is in flight.
                guard let self, self.installationStarted else { return }
                self.installer?.progress.cancel()
            }
        }
    }

    nonisolated func guestDidStop(_ virtualMachine: VZVirtualMachine) {
        Task { @MainActor in onStop?(nil) }
    }
    nonisolated func virtualMachine(_ virtualMachine: VZVirtualMachine, didStopWithError error: Error) {
        Task { @MainActor in onStop?(error) }
    }
}

import ComputerCore
import Containerization
import ContainerizationEXT4
import ContainerizationOCI
import Foundation

extension ContainerComputer {
    // Read the kernel's filesystem name; BusyBox stat may report the numeric
    // OverlayFS magic as UNKNOWN instead of the GNU stat name "overlayfs".
    static let overlayCheckCommand = #"""
        overlay_found=no
        while read -r source destination filesystem options rest; do
            if [ "$destination" = / ] && [ "$filesystem" = overlay ]; then overlay_found=yes; fi
        done < /proc/mounts
        test "$overlay_found" = yes
        """#

    static func prepareImage(computer: Computer, directory: URL, cache: URL,
                             previous: ContainerDiskState?,
                             status: @escaping @Sendable (String, TransferProgress?) async -> Void) async throws -> ContainerDiskState? {
        try validateImageReference(computer.imageReference)
        let store = try ImageStore(path: cache.appendingPathComponent("Images"))
        let initDisk = cache.appendingPathComponent("initfs-0.43.0.ext4")
        if !FileManager.default.fileExists(atPath: initDisk.path) {
            let label = "Downloading Linux startup files…"
            await status(label, nil)
            let progress = ImageDownloadProgress(label: label, report: status)
            let image = try await registryRequest(reference: initReference) {
                try await store.getInitImage(reference: initReference, progress: { await progress.update($0) })
            }
            let staging = cache.appendingPathComponent("initfs-\(UUID().uuidString).partial")
            defer { try? FileManager.default.removeItem(at: staging) }
            _ = try await image.initBlock(at: staging, for: .linuxArm)
            try Task.checkCancellation()
            // A simultaneous creation may have completed the shared init disk.
            if !FileManager.default.fileExists(atPath: initDisk.path) {
                try FileManager.default.moveItem(at: staging, to: initDisk)
            }
        }
        let label = "Checking and downloading the current image…"
        await status(label, nil)
        let progress = ImageDownloadProgress(label: label, report: status)
        // Always resolve the remote reference, including custom mutable tags.
        let image = try await registryRequest(reference: computer.imageReference) {
            try await store.pull(reference: computer.imageReference, platform: .current,
                                 progress: { await progress.update($0) })
        }
        try Task.checkCancellation()
        if previous?.imageDigest == image.digest { return nil }
        let state = ContainerDiskState(previousGeneration: previous?.generation,
                                       imageReference: computer.imageReference, imageDigest: image.digest)
        let layers = state.directory(in: directory)
        try FileManager.default.createDirectory(at: layers, withIntermediateDirectories: true)
        do {
            await status("Preparing the image…", nil)
            _ = try await EXT4Unpacker(capacityInBytes: UInt64(computer.diskGiB) * 1_073_741_824, journal: .default)
                .unpack(image, for: .current, at: layers.appendingPathComponent("Base.ext4"),
                        progress: { await progress.update($0) })
            let configuration = try await image.config(for: .current)
            try JSONEncoder().encode(configuration).write(to: layers.appendingPathComponent("ImageConfig.json"))
            await status(previous == nil ? "Creating your writable disk…" : "Preserving your writable disk…", nil)
            if let previous {
                let source = previous.directory(in: directory).appendingPathComponent("Upper.ext4")
                let destination = layers.appendingPathComponent("Upper.ext4")
                try await Task.detached(priority: .userInitiated) {
                    try FileManager.default.copyItem(at: source, to: destination)
                }.value
            } else {
                try emptyDisk(at: layers.appendingPathComponent("Upper.ext4"), size: UInt64(computer.diskGiB) * 1_073_741_824, journal: true)
            }
            // LinuxPod initially prepares DNS/hosts in this disposable root. Before
            // launching the workspace, mountOverlay replaces it with the merged root.
            try emptyDisk(at: layers.appendingPathComponent("Mount.ext4"), size: 32 * 1_048_576, journal: false)
            if computer.networkEnabled {
                await status("Preparing workspace networking…", nil)
                let networkImage = computer.template == .shell ? image
                    : try await registryRequest(reference: Computer.shellImage) {
                        try await store.pull(reference: Computer.shellImage, platform: .current)
                    }
                _ = try await EXT4Unpacker(capacityInBytes: 256 * 1_048_576, journal: .default)
                    .unpack(networkImage, for: .current, at: layers.appendingPathComponent("Network.ext4"))
            }
            try Task.checkCancellation()
            return state
        } catch {
            try? FileManager.default.removeItem(at: layers)
            throw error
        }
    }

    /// ImageStore.pull requires an explicit registry and tag/digest. Validate before
    /// downloading even the startup image, and offer a complete, copyable correction.
    static func validateImageReference(_ reference: String) throws {
        let example = "docker.io/library/nginx:alpine"
        guard !reference.isEmpty else {
            throw ComputerError("Enter a container image name, for example \(example).")
        }
        guard !reference.contains("://") else {
            throw ComputerError("Enter the image name from the registry’s pull instructions, without https:// or a web page address. For example: \(example).")
        }
        guard !reference.contains(where: \.isWhitespace) else {
            throw ComputerError("Enter only the container image name, without spaces or the docker pull command. For example: \(example).")
        }
        let parsed: Reference
        do { parsed = try Reference.parse(reference) }
        catch {
            throw ComputerError("Invalid container image name: \(reference). Use registry/repository:tag, for example \(example). Repository names must be lowercase.")
        }
        guard parsed.domain != nil else {
            let suggestion = try Reference(path: parsed.path, domain: "docker.io", tag: parsed.tag, digest: parsed.digest)
            suggestion.normalize()
            throw ComputerError("Include the registry address in the image name. For Docker Hub, use \(suggestion.description).")
        }
        guard parsed.tag != nil || parsed.digest != nil else {
            parsed.normalize()
            throw ComputerError("Include an image tag or digest. To use the latest tag, enter \(parsed.description).")
        }
    }

    static func registryRequest<T>(reference: String, operation: () async throws -> T) async throws -> T {
        try validateImageReference(reference)
        do { return try await operation() }
        catch let error as RegistryClient.Error {
            // RegistryClient provides CustomStringConvertible but not LocalizedError;
            // localizedDescription otherwise hides every HTTP failure behind "error 0".
            switch error {
            case .invalidStatus(let url, let response, _):
                let advice: String
                switch response.code {
                case 401, 403:
                    advice = "The registry denied access. Check the image name and choose an image that allows public downloads; \(ComputerAppIdentity.name) does not currently support registry sign-in."
                case 404 where URL(string: url)?.path.contains("/manifests/") == true:
                    advice = "The image or tag could not be found. Check the repository name and tag on the registry’s image page, and confirm the image is public."
                case 404:
                    advice = "The registry could not find a required download. Try again; if it still fails, choose another published tag or contact the image publisher."
                case 429:
                    advice = "The registry’s download limit was reached. Wait a while and try again."
                case 500...599:
                    advice = "The image registry is having trouble responding. Try again later."
                default:
                    advice = "The registry rejected the download. Check the image name and tag, confirm the image is public, and try again."
                }
                throw ComputerError("Could not download \(reference). \(advice) (HTTP \(response.code))")
            case .insecureCredentialExchange:
                throw ComputerError("Could not download \(reference). The registry requested an unsafe sign-in exchange. Use a public image from a trusted registry, or ask the registry administrator to fix its authentication settings.")
            }
        }
    }

    private static func emptyDisk(at url: URL, size: UInt64, journal: Bool) throws {
        let formatter = try EXT4.Formatter(.init(url.path), minDiskSize: size, journal: journal ? .default : nil)
        try formatter.close()
    }

    static func mountOverlay(in pod: LinuxPod) async throws {
        try await pod.withVirtualMachineInstance { vm in
            let agent = try await vm.dialAgent()
            do {
                // These paths are the layout of the pinned Containerization 0.43.0
                // LinuxPod. Mount through its VM agent without granting the guest
                // workspace mount capabilities or exposing any host directory.
                let base = "/run/volumes/noodle-base"
                let upper = "/run/volumes/noodle-upper"
                let root = "/run/container/workspace/rootfs"
                try await agent.mkdir(path: upper + "/diff", all: true, perms: 0o755)
                try await agent.mkdir(path: upper + "/work", all: true, perms: 0o700)
                try await agent.umount(path: root, flags: 0)
                try await agent.mount(.init(type: "overlay", source: "overlay", destination: root,
                    options: ["lowerdir=\(base)", "upperdir=\(upper)/diff", "workdir=\(upper)/work",
                              "index=off", "metacopy=off", "redirect_dir=off"]))
                try await agent.close()
            } catch { try? await agent.close(); throw error }
        }
    }
}

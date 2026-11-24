import ComputerCore
import Containerization
import ContainerizationArchive
import ContainerizationEXT4
import ContainerizationExtras
import ContainerizationOCI
import Foundation

extension ContainerComputer {
    // Read the kernel's filesystem name; BusyBox stat may report the numeric
    // OverlayFS magic as UNKNOWN instead of the GNU stat name "overlayfs".
    public static let overlayCheckCommand = #"""
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
                let old = previous.directory(in: directory)
                let source = old.appendingPathComponent("Upper.ext4")
                let destination = layers.appendingPathComponent("Upper.ext4")
                let size = UInt64(computer.diskGiB) * 1_073_741_824
                let moved = movesSystem(from: old, to: layers)
                try await Task.detached(priority: .userInitiated) {
                    if moved { try keepPeoplesFiles(from: source, to: destination, size: size) }
                    else { try FileManager.default.copyItem(at: source, to: destination) }
                }.value
            } else {
                try emptyDisk(at: layers.appendingPathComponent("Upper.ext4"), size: UInt64(computer.diskGiB) * 1_073_741_824, journal: true)
            }
            // LinuxPod initially prepares DNS/hosts in this disposable root. Before
            // launching the workspace, mountOverlay replaces it with the merged root.
            try emptyDisk(at: layers.appendingPathComponent("Mount.ext4"), size: 32 * 1_048_576, journal: false)
            if computer.networkEnabled {
                await status("Preparing workspace networking…", nil)
                try await prepareNetworkDisk(computer: computer, layers: layers, store: store, image: image)
            }
            try Task.checkCancellation()
            return state
        } catch {
            try? FileManager.default.removeItem(at: layers)
            throw error
        }
    }

    /// Asks the registry for the image's current digest without downloading it.
    /// Nil when the answer is unknown, so no update is suggested by mistake.
    static func imageIsCurrent(computer: Computer, directory: URL, cache: URL) async throws -> Bool? {
        let state = try ContainerDiskState.load(in: directory)
        let reference = try Reference.parse(computer.imageReference)
        guard let tag = reference.tag ?? reference.digest else { return nil }
        let remote = try await registryRequest(reference: computer.imageReference) {
            try await RegistryClient(reference: computer.imageReference,
                                     tlsConfiguration: TLSUtils.makeEnvironmentAwareTLSConfiguration())
                .resolve(name: reference.path, tag: tag)
        }
        let content = try LocalContentStore(path: cache.appendingPathComponent("Images").appendingPathComponent("content"))
        let stored = try? await content.get(digest: state.imageDigest)?.data()
        return imageIsCurrent(stored: state.imageDigest, remote: remote) { $0 == state.imageDigest ? stored : nil }
    }

    /// A pull stores a single-manifest image under an index it synthesizes, so
    /// its digest is compared with the manifest inside that index instead.
    static func imageIsCurrent(stored: String, remote: Descriptor, content: (String) -> Data?) -> Bool? {
        if stored == remote.digest { return true }
        if remote.mediaType == MediaTypes.index || remote.mediaType == MediaTypes.dockerManifestList { return false }
        guard let data = content(stored), let index = try? JSONDecoder().decode(Index.self, from: data) else { return nil }
        return index.manifests.map(\.digest) == [remote.digest]
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

    public static func registryRequest<T>(reference: String, operation: () async throws -> T) async throws -> T {
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

    /// Also made at start for a computer whose networking was turned on after it was created without.
    static func prepareNetworkDisk(computer: Computer, layers: URL, store: ImageStore, image: Containerization.Image? = nil) async throws {
        let networkImage = if let image, computer.template == .shell { image } else {
            try await registryRequest(reference: Computer.shellImage) {
                try await store.pull(reference: Computer.shellImage, platform: .current)
            }
        }
        let staging = layers.appendingPathComponent("Network.ext4.partial")
        try? FileManager.default.removeItem(at: staging)
        _ = try await EXT4Unpacker(capacityInBytes: 256 * 1_048_576, journal: .default)
            .unpack(networkImage, for: .current, at: staging)
        try FileManager.default.moveItem(at: staging, to: layers.appendingPathComponent("Network.ext4"))
    }

    /// Whether the new image is built on another system than the old: then only people's own files come across.
    static func movesSystem(from old: URL, to new: URL) -> Bool {
        guard let before = imageSystem(ofDisk: old.appendingPathComponent("Base.ext4")),
              let after = imageSystem(ofDisk: new.appendingPathComponent("Base.ext4")) else { return false }
        return before != after
    }

    /// The system an image is built on, from its /etc/os-release: the distribution and its release, as "ubuntu noble",
    /// "kali kali-rolling" or "alpine 3.22". Nil when the disk does not say.
    static func imageSystem(ofDisk url: URL) -> String? {
        guard let reader = try? EXT4.EXT4Reader(blockDevice: .init(url.path)),
              let data = try? reader.readFile(at: .init("/etc/os-release")) else { return nil }
        var fields: [String: String] = [:]
        for line in String(decoding: data, as: UTF8.self).split(separator: "\n") {
            let parts = line.split(separator: "=", maxSplits: 1)
            if parts.count == 2 { fields[String(parts[0])] = parts[1].trimmingCharacters(in: .init(charactersIn: "\"' ")) }
        }
        guard let id = fields["ID"] else { return nil }
        // Alpine has no codename, and its point releases keep the same packages.
        let release = fields["VERSION_CODENAME"] ?? fields["VERSION_ID"].map { $0.split(separator: ".").prefix(2).joined(separator: ".") }
        return [id, release].compactMap { $0 }.joined(separator: " ")
    }

    /// A new writable disk with only people's own files from an old one: home folders and /workspace. For an image on
    /// another system, where the old system's programs, package records and library index break the new one.
    static func keepPeoplesFiles(from source: URL, to destination: URL, size: UInt64) throws {
        let reader = try EXT4.EXT4Reader(blockDevice: .init(source.path))
        let formatter = try EXT4.Formatter(.init(destination.path), minDiskSize: size, journal: .default)
        func copy(_ path: String) throws {
            let inode = try reader.stat(.init(path), followSymlinks: false).inode
            let times = FileTimestamps(access: Date(timeIntervalSince1970: TimeInterval(Int32(bitPattern: inode.atime))),
                                       modification: Date(timeIntervalSince1970: TimeInterval(Int32(bitPattern: inode.mtime))),
                                       creation: nil)
            let uid = UInt32(inode.uid) | UInt32(inode.uidHigh) << 16, gid = UInt32(inode.gid) | UInt32(inode.gidHigh) << 16
            switch inode.mode & 0xF000 {
            case 0x4000:
                try formatter.create(path: .init(path), mode: inode.mode, ts: times, uid: uid, gid: gid)
                for name in try reader.listDirectory(.init(path)) { try copy(path + "/" + name) }
            case 0x8000:
                let stream = EXT4FileStream(reader: reader, path: path)
                try formatter.create(path: .init(path), mode: inode.mode, ts: times, buf: stream, uid: uid, gid: gid)
                if let error = stream.error { throw error }
            case 0xA000 where inode.sizeLow < 60:
                // A short link's target is kept in the inode itself; the reader has no way to read a longer one.
                let target = withUnsafeBytes(of: inode.block) { Array($0.prefix(Int(inode.sizeLow))) }
                try formatter.create(path: .init(path), link: .init(String(decoding: target, as: UTF8.self)),
                                     mode: inode.mode, ts: times, uid: uid, gid: gid)
            default:
                break  // Overlay whiteouts, devices, sockets and pipes stay behind.
            }
        }
        try formatter.create(path: .init("/diff"), mode: EXT4.Inode.Mode(.S_IFDIR, 0o755))
        for folder in ["/diff/home", "/diff/root", "/diff/workspace"] where reader.exists(.init(folder), followSymlinks: false) {
            try copy(folder)
        }
        try formatter.close()
    }

    private static func emptyDisk(at url: URL, size: UInt64, journal: Bool) throws {
        let formatter = try EXT4.Formatter(.init(url.path), minDiskSize: size, journal: journal ? .default : nil)
        try formatter.close()
    }

    static func mountOverlay(in pod: LinuxPod, hosts: Hosts) async throws {
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
                // LinuxPod wrote /etc/hosts into the root this mount now covers; write it again on the computer's disk.
                try await agent.configureHosts(config: hosts, location: root)
                try await agent.close()
            } catch { try? await agent.close(); throw error }
        }
    }
}

/// A file on an ext4 disk, read a piece at a time as the formatter writes it into another.
private final class EXT4FileStream: ReadableStream {
    let reader: EXT4.EXT4Reader
    let path: String
    private var offset: UInt64 = 0
    private(set) var error: Error?

    init(reader: EXT4.EXT4Reader, path: String) {
        self.reader = reader
        self.path = path
    }

    func read(_ buffer: UnsafeMutablePointer<UInt8>, maxLength: Int) -> Int {
        do {
            let count = try reader.readFile(at: .init(path), into: UnsafeMutableRawBufferPointer(start: buffer, count: maxLength),
                                            offset: offset, followSymlinks: false)
            offset += UInt64(count)
            return count
        } catch {
            self.error = error
            return -1
        }
    }
}

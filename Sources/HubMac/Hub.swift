import AppletBridge
import BrowserBridge
import ComputerBridge
import CoreServices
import Foundation
import HubCore
import HubLink
import NoodleAppletTools
import NoodleBrowserTools
import NoodleComputerTools
import NoodleCore
import NoodleImagesTools
import NoodleMCP
import NoodleRuntime
import NoodleVoicePeer

/// The Hub's bots, harnesses and conversations. They live in the Hub's own sandbox
/// container, apart from Noodle's; the folder name is the one the Agent Host looks in.
@MainActor public final class Hub {
    public static let folderName = "Noodle"

    public let repository: WorkspaceRepository
    public let runtime: AgentRuntimeCoordinator
    public let harnessProfiles: HarnessProfilesController
    public let usage: UsageHistory
    public let access: HubAccess
    public let tokenLimits: HubTokenLimits
    public let connections: HubConnections
    public let computers: HubComputers
    public let browsers: HubBrowsers
    public let bots: HubBots
    /// Noodle Applet on this Mac, for the bots' applet tool and for people's devices.
    public let applets: AppletController
    public let imageGeneration: ImageGenerationController
    public let link: HubLinkService

    /// `computer`, `browser` and `applet` reach Noodle Computer, Browser and Applet on this Mac,
    /// `surfaces` opens their live views, and `runtime` runs the bots; tests pass their own.
    public init(root: URL, messenger: URL?, linkPort: UInt16 = LinkEndpoint.defaultPort, router: (any RouterPortMapper)? = nil,
                computer: ComputerToolProvider.Transport? = nil, browser: BrowserToolProvider.Transport? = nil,
                applet: (@Sendable (AppletRequest) async throws -> AppletResponse)? = nil, surfaces: SurfaceOpeners = SurfaceOpeners(),
                runtime: AgentRuntimeCoordinator? = nil) {
        repository = WorkspaceRepository(rootURL: root, launcherExecutableURL: messenger)
        // Only the Hub's own storage holds harnesses its Agent Host will trust.
        if let runtime {
            self.runtime = runtime
        } else {
            let discovery = HarnessDiscovery(managedHarnesses: repository.managedHarnesses)
            discovery.removeSupersededManagedHarnesses()
            self.runtime = AgentRuntimeCoordinator(discovery: discovery, harnesses: HarnessSelection(defaults: .standard))
        }
        self.runtime.remoteModels = RemoteModelAccountStore(repository: root)
        self.runtime.harnessProfiles = repository.harnessProfiles
        harnessProfiles = HarnessProfilesController(store: repository.harnessProfiles)
        // TODO(Hub 0.44.0): remove with RestrictedHarnessStorage.removeSharedLogins and
        // RestrictedHarnessStorageTests.testSharedCopiesOfTheCLIsOwnLoginsAreRemoved. Milestone: Hub 0.43.0.
        RestrictedHarnessStorage.removeSharedLogins(root: root, loginHome: HarnessStorage.userHome)
        harnessProfiles.subscriptionUsage = self.runtime.subscriptionUsage
        usage = UsageHistory(url: root.appendingPathComponent("usage.sqlite"))
        access = HubAccess(url: root.appendingPathComponent("access.json"))
        access.log = HubActivityLog(url: root.appendingPathComponent("activity.jsonl"))
        tokenLimits = HubTokenLimits(access: access, usage: usage)
        // Tokens count against the plan of whoever owns the bot when it uses them.
        self.runtime.onUsage = { [usage, access, tokenLimits] sample in
            var sample = sample
            sample.owner = access.owner(ofBot: sample.agentID)
            usage.record(sample)
            tokenLimits.check()
        }
        self.runtime.recordedUsage = { [usage] in usage.recorded(session: $0) }
        access.onTokenLimitsChange = { [tokenLimits] in tokenLimits.check() }
        // One broker serves every tool a bot is given here, whichever kind it is.
        let tools = ToolProviderRegistry(), assignments = ToolAssignmentStore()
        connections = HubConnections(root: root, access: access,
                                     service: MCPService(namespace: Bundle.main.bundleIdentifier ?? "com.pdparchitect.noodle.hub"),
                                     tools: tools, assignments: assignments)
        computers = HubComputers(root: root, access: access, tools: tools, assignments: assignments,
                                 call: computer ?? ComputerToolProvider.liveTransport(), surface: surfaces.computer)
        browsers = HubBrowsers(root: root, access: access, tools: tools, assignments: assignments,
                               call: browser ?? BrowserToolProvider.liveTransport(), surface: surfaces.browser)
        let applets = AppletController(connection: applet, surface: surfaces.applet)
        self.applets = applets
        bots = HubBots(repository: repository, runtime: self.runtime, access: access, connections: connections, computers: computers, browsers: browsers,
                       applets: applets,
                       uploads: root.appendingPathComponent("Uploads", isDirectory: true), readMarks: root.appendingPathComponent("read.json"),
                       pins: root.appendingPathComponent("pins.json"), notifications: root.appendingPathComponent("notifications.json"))
        // On a Mac a Hub takes calls and makes small pictures of conversation files.
        bots.makeCallPeer = { VoiceCallPeer() }
        bots.makePreview = { await AttachmentPictures.make(of: $0, mediaType: $1, pixels: $2) }
        // The Hub's bots get the applet tool from its own controller. This Mac as a Hub shares
        // Noodle's, whose broker serves Noodle's bots, so the wiring is here and not in HubBots.
        applets.onGrantsChange = { [weak bots] granted in
            assignments.replace(AppletToolGrant.kind, with: granted)
            bots?.synchronizeToolSkills()
        }
        try? tools.register(AppletToolProvider { [applets] in try await applets.tool($0) })
        applets.onIdle = { [runtime = self.runtime, repository = self.repository] notices in
            for notice in notices { runtime.wake(notice.agentID, note: notice.note, repository: repository) }
        }
        // The models are the Hub's, for every person's bots; each bot is granted the tool on its own.
        imageGeneration = ImageGenerationController(repository: repository)
        imageGeneration.onAssignmentsChange = { [weak bots] granted in
            assignments.replace(ImageGenerationSettings.kind, with: granted)
            bots?.synchronizeToolSkills()
        }
        bots.imageGeneration = imageGeneration
        bots.tokenLimits = tokenLimits
        bots.appliesSuspensions = true
        tokenLimits.onChange = { [weak bots] in bots?.applyTokenLimits() }
        // Whoever ran out before the Hub last quit stays held.
        tokenLimits.check()
        let imageHelper = ImageGenerationHelper(executable: Bundle.main.bundleURL.appendingPathComponent("Contents/Helpers/NoodleAppleAgent"))
        try? tools.register(ImageToolProvider(library: { [root] in ImageLibrary.load(root: root) }, generate: { try await imageHelper.png($0) }))
        access.onSuspensionChange = { [weak bots] in bots?.synchronizeSuspensions() }
        bots.synchronizeSuspensions()
        access.onOwnersChange = { [weak bots, weak computers, weak browsers] in
            bots?.synchronizeOwners()
            bots?.synchronizeSuspensions()
            Task { await computers?.synchronizeOwners() }
            Task { await browsers?.synchronizeOwners() }
        }
        link = HubLinkService(hubName: Host.current().localizedName ?? "Noodle Hub",
                              directory: root.appendingPathComponent("Link", isDirectory: true),
                              access: access, profiles: harnessProfiles, bots: bots, connections: connections,
                              computers: computers, browsers: browsers, port: linkPort, router: router,
                              pushes: CloudKitPushes.ifEntitled(), callPushes: NoodlePushTransport())
    }

    /// Removes a user with their devices and the bots they keep here.
    public func remove(_ user: HubUser) {
        link.remove(user)
    }

    public static func root(applicationSupport: URL) -> URL {
        applicationSupport.appendingPathComponent(folderName, isDirectory: true)
    }

    /// Who is connected and which bots are working, which quitting would cut off.
    public var activity: HubActivity {
        let agents = (try? repository.loadAgents()) ?? []
        return HubActivity(people: link.connectedUsers.count, devices: link.connectedDevices.count,
                           workingBots: agents.filter { runtime.snapshot(for: $0.id).phase == .working }.count)
    }
}

extension AppletController: HubNoodletRunning {}

/// What quitting the Hub would interrupt.
public struct HubActivity: Equatable, Sendable {
    public var people: Int
    public var devices: Int
    public var workingBots: Int

    public init(people: Int, devices: Int, workingBots: Int) {
        self.people = people
        self.devices = devices
        self.workingBots = workingBots
    }

    /// One sentence saying so, or nil when nothing would be interrupted.
    public var interruption: String? {
        var parts: [String] = []
        if devices > 0 {
            parts.append("\(people) \(people == 1 ? "person" : "people") on \(devices) \(devices == 1 ? "device" : "devices") "
                         + (people == 1 ? "is" : "are") + " connected")
        }
        if workingBots > 0 {
            parts.append("\(workingBots) \(workingBots == 1 ? "bot is" : "bots are") working")
        }
        return parts.isEmpty ? nil : parts.joined(separator: ", and ") + "."
    }
}

/// When quitting the Hub asks first.
public enum HubQuit {
    /// A person quitting is asked; logging out, restarting and shutting down, which name their
    /// reason in the quit event, are not held up.
    public static func asksFirst(quitReason: OSType?) -> Bool {
        let system = [kAELogOut, kAEReallyLogOut, kAEShowRestartDialog, kAEShowShutdownDialog, kAERestart, kAEShutDown]
        return !system.map { OSType($0) }.contains(quitReason ?? 0)
    }
}

/// The Hub is server software, so it opens at login by default. It registers once, so turning
/// Open at Login off, in Settings or in Login Items, lasts.
public enum HubLoginItem {
    static let registeredKey = "HubRegisteredLoginItem"

    public static func registerByDefault(defaults: UserDefaults = .standard, register: () throws -> Void) {
        guard !defaults.bool(forKey: registeredKey) else { return }
        do {
            try register()
            defaults.set(true, forKey: registeredKey)
        } catch {
            NSLog("Noodle Hub could not open at login: \(error.localizedDescription)")
        }
    }
}

/// How the Hub opens live views in Noodle Computer, Browser and Applet; nil for each app's own.
public struct SurfaceOpeners {
    public var computer: (@Sendable (ComputerRequest) async throws -> SurfaceSocket)?
    public var browser: (@Sendable (BrowserRequest) async throws -> SurfaceSocket)?
    public var applet: (@Sendable (AppletRequest) async throws -> SurfaceSocket)?

    public init(computer: (@Sendable (ComputerRequest) async throws -> SurfaceSocket)? = nil,
                browser: (@Sendable (BrowserRequest) async throws -> SurfaceSocket)? = nil,
                applet: (@Sendable (AppletRequest) async throws -> SurfaceSocket)? = nil) {
        self.computer = computer
        self.browser = browser
        self.applet = applet
    }
}

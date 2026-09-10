import Foundation

/// The bundled catalogue is the single source for creation choices and image recognition.
public struct ContainerRegistry: Decodable, Sendable {
    public let schemaVersion: Int
    public let defaultTemplateID: String
    public let templates: [ComputerTemplate]

    public static let bundled: ContainerRegistry = {
        do {
            // SwiftPM's generated accessor checks beside the executable's main bundle.
            // Signed macOS apps keep resource bundles inside Contents/Resources instead.
            let resourceBundle = Bundle.main.url(forResource: "NoodleComputer_ComputerCore", withExtension: "bundle")
                .flatMap { Bundle(url: $0) } ?? Bundle.module
            guard let url = resourceBundle.url(forResource: "container-registry", withExtension: "json") else {
                throw ComputerError("The container registry is missing from the app bundle.")
            }
            return try ContainerRegistry(data: Data(contentsOf: url))
        } catch {
            fatalError("Invalid bundled container registry: \(error)")
        }
    }()

    public var defaultTemplate: ComputerTemplate { templates.first { $0.id == defaultTemplateID }! }

    public func template(for computer: Computer) -> ComputerTemplate? {
        guard computer.kind == .container, !computer.isCustomContainer else { return nil }
        return templates.first { $0.imageReference == computer.imageReference }
    }

    public init(data: Data) throws {
        self = try JSONDecoder().decode(Self.self, from: data)
    }

    private enum CodingKeys: String, CodingKey {
        case schemaVersion, defaultTemplateID, templates
    }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        schemaVersion = try values.decode(Int.self, forKey: .schemaVersion)
        defaultTemplateID = try values.decode(String.self, forKey: .defaultTemplateID)
        templates = try values.decode([ComputerTemplate].self, forKey: .templates)
        guard schemaVersion == 1 else { throw ComputerError("Unsupported container registry version.") }
        guard templates.contains(where: { $0.id == defaultTemplateID }),
              templates.contains(where: { $0.type == .desktop }),
              templates.contains(where: { $0.type == .shell }) else {
            throw ComputerError("The container registry needs a default template and desktop and shell runtimes.")
        }
        guard Set(templates.map(\.id)).count == templates.count,
              Set(templates.map(\.imageReference)).count == templates.count else {
            throw ComputerError("Container registry IDs and image references must be unique.")
        }
        for template in templates {
            let text = [template.id, template.name, template.description, template.symbol, template.defaultName]
            guard text.allSatisfy({ !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !$0.contains(where: \.isNewline) }),
                  template.defaultName.count <= 100,
                  !template.imageReference.isEmpty,
                  !template.imageReference.contains(where: \.isWhitespace),
                  !template.imageReference.contains("://"),
                  (1...32).contains(template.defaultCPUs),
                  (1...64).contains(template.minimumMemoryGiB),
                  (template.minimumMemoryGiB...64).contains(template.defaultMemoryGiB),
                  (4...512).contains(template.minimumDiskGiB),
                  (template.minimumDiskGiB...512).contains(template.defaultDiskGiB) else {
                throw ComputerError("Invalid fields or resource limits in container template \(template.id).")
            }
            if template.type == .desktop && (!template.requiresNetworking || template.minimumMemoryGiB < 2 || template.minimumDiskGiB < 8) {
                throw ComputerError("Desktop templates require networking, 2 GB memory and an 8 GB disk.")
            }
        }
    }
}

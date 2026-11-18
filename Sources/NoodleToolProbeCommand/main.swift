// noodle-tool-probe: Noodle's tool probe, for its catalogue. Reads Noodle's saved sign-ins; pass
// --namespace com.pdparchitect.noodle.hub for a Noodle Hub's on this Mac, or com.pdparchitect.noodle.local for
// Noodle Dev's. See NoodleToolProbe for what it takes.
import Foundation
import NoodleCore
import NoodleToolProbe

exit(await ToolProbe.main(arguments: Array(CommandLine.arguments.dropFirst()), entries: ToolCatalog.noodle, adapters: [:],
                          namespace: "com.pdparchitect.noodle"))

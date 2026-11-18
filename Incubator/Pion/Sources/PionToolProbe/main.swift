// pion-tool-probe: Pion's tool probe, for its catalogue and its own tools. Reads Pion's saved sign-ins; pass
// --namespace com.pdparchitect.pion.local for Pion Dev's. See NoodleToolProbe for what it takes.
import Foundation
import NoodleToolProbe
import PionCore

exit(await ToolProbe.main(arguments: Array(CommandLine.arguments.dropFirst()), entries: PionCatalogue.entries, adapters: PionAdapters.all,
                          namespace: "com.pdparchitect.pion"))

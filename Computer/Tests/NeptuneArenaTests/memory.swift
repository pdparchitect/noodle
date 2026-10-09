import Foundation

@main enum MemoryTests {
    static func main() throws {
        let first = try NeptuneMemory(group: "noodle-test", size: 32_768)
        guard first.name.hasPrefix("noodle-test/") else {
            fputs("FAIL: Shared memory must use the app group's slash namespace inside App Sandbox\n", stderr); exit(1)
        }
        let second = try NeptuneMemory(group: "noodle-test", size: 32_768)
        let child = try NeptuneMemory(open: first.name, size: first.size)
        first.pointer.storeBytes(of: UInt32(42), toByteOffset: 4096, as: UInt32.self)
        guard child.pointer.load(fromByteOffset: 4096, as: UInt32.self) == 42 else {
            fputs("FAIL: The helper must see its VM's 4 KiB-offset blob inside the shared 16 KiB page\n", stderr); exit(1)
        }
        guard second.pointer.load(fromByteOffset: 4096, as: UInt32.self) == 0, first.name != second.name else {
            fputs("FAIL: A second VM must not share the first VM's bytes\n", stderr); exit(1)
        }
        child.pointer.storeBytes(of: UInt32(81), toByteOffset: 8192, as: UInt32.self)
        guard first.pointer.load(fromByteOffset: 8192, as: UInt32.self) == 81 else { exit(1) }
        print("Neptune memory isolation checks passed")
    }
}

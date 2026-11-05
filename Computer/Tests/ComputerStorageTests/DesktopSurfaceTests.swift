import AppKit
import Foundation
import ComputerCore
import Surface
import XCTest
@testable import ComputerEngine
@testable import NoodleComputer

final class DesktopSurfaceTests: XCTestCase {
    /// The Mac end of a socket pair stands in for the guest's vsock connection.
    private func pair() throws -> (surface: DesktopSurface, guest: FileHandle) {
        var sockets: [Int32] = [0, 0]
        XCTAssertEqual(socketpair(AF_UNIX, SOCK_STREAM, 0, &sockets), 0)
        let mac = FileHandle(fileDescriptor: sockets[0], closeOnDealloc: true)
        return (DesktopSurface { mac }, FileHandle(fileDescriptor: sockets[1], closeOnDealloc: true))
    }

    private func words(_ values: [UInt32]) -> Data {
        values.reduce(into: Data()) { data, value in withUnsafeBytes(of: value.littleEndian) { data.append(contentsOf: $0) } }
    }

    private func pixel(_ image: CGImage, _ x: Int, _ y: Int) -> [UInt8] {
        let colour = NSBitmapImageRep(cgImage: image).colorAt(x: x, y: y)!.usingColorSpace(.deviceRGB)!
        return [colour.redComponent, colour.greenComponent, colour.blueComponent].map { UInt8(($0 * 255).rounded()) }
    }

    func testFramesKeepUnchangedTilesAndApplyChangedOnes() async throws {
        let (surface, guest) = try pair()
        // Guest pixels are BGRX: a red 2x1 tile at the origin, then a blue 1x1 tile at (3, 1).
        let red: [UInt8] = [0, 0, 255, 0], blue: [UInt8] = [255, 0, 0, 0]
        async let first = surface.frame()
        XCTAssertEqual(guest.readData(ofLength: 1), Data([1]))
        guest.write(words([4, 2, 1, 0, 0, 2, 1]) + Data(red + red))
        let (image, size) = try await first
        XCTAssertEqual(size, CGSize(width: 4, height: 2))
        XCTAssertEqual(pixel(image, 0, 0), [255, 0, 0])
        XCTAssertEqual(pixel(image, 1, 0), [255, 0, 0])

        async let second = surface.frame()
        XCTAssertEqual(guest.readData(ofLength: 1), Data([1]))
        guest.write(words([4, 2, 1, 3, 1, 1, 1]) + Data(blue))
        let (next, _) = try await second
        XCTAssertEqual(pixel(next, 0, 0), [255, 0, 0], "an unchanged tile must survive the next frame")
        XCTAssertEqual(pixel(next, 3, 1), [0, 0, 255])
    }

    func testInputIsSentAsGuestRequests() async throws {
        let (surface, guest) = try pair()
        try await surface.send(.pointer(.down, x: 10.6, y: 20, clickCount: 1))
        XCTAssertEqual(guest.readData(ofLength: 10), Data([2, 1]) + words([11, 20]))
        try await surface.send(.scroll(x: 5, y: 6, dx: 0, dy: -80))
        XCTAssertEqual(guest.readData(ofLength: 17), Data([3]) + words([5, 6, 0, UInt32(bitPattern: -80)]))
        try await surface.send(.key(.enter))
        XCTAssertEqual(guest.readData(ofLength: 5), Data([4]) + words([0xff0d]))
        try await surface.send(.text("hé"))
        XCTAssertEqual(guest.readData(ofLength: 8), Data([5]) + words([3]) + Data("hé".utf8))
    }

    func testClipboardMovesOnlyOnExplicitCopyAndPaste() async throws {
        let (surface, guest) = try pair()
        try await surface.paste("héllo")
        XCTAssertEqual(guest.readData(ofLength: 11), Data([6]) + words([6]) + Data("héllo".utf8))
        async let copied = surface.copy()
        XCTAssertEqual(guest.readData(ofLength: 1), Data([7]))
        guest.write(words([5]) + Data("guest".utf8))
        let text = try await copied
        XCTAssertEqual(text, "guest")
    }

    func testFrameLargerThanItsScreenIsRejected() async throws {
        let (surface, guest) = try pair()
        async let frame = surface.frame()
        _ = guest.readData(ofLength: 1)
        guest.write(words([4, 2, 1, 3, 0, 2, 1]))
        do {
            _ = try await frame
            XCTFail("A tile outside the screen must not be drawn")
        } catch {}
    }

    func testOnlyBundledImagesStart() {
        XCTAssertNoThrow(try ContainerComputer.requireSupportedImage(ComputerTemplate.shell.makeComputer()))
        let other = Computer(name: "Other", kind: .container, imageReference: "docker.io/library/nginx:alpine")
        XCTAssertThrowsError(try ContainerComputer.requireSupportedImage(other))
    }

    func testOnlyContractTwoImagesStartTheirDesktop() {
        XCTAssertNoThrow(try ContainerComputer.requireNativeDesktop(labels: ["im.noodle.desktop.contract": "2"]))
        XCTAssertThrowsError(try ContainerComputer.requireNativeDesktop(labels: ["im.noodle.desktop.contract": "1"]))
        XCTAssertThrowsError(try ContainerComputer.requireNativeDesktop(labels: nil))
    }
}

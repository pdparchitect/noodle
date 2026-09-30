import SwiftUI
import Surface
import XCTest

/// Controllers people own, from joysticks with one button to today's pads, described only by
/// what they have. The phone can tell a full pad from a remote; the rest check that one
/// declaration survives every shape.
private extension GamepadController {
    static let atari = Self(pads: 1, buttons: ["Fire"], menu: false)
    static let nes = Self(pads: 1, buttons: ["A", "B"], menu: true)
    static let snes = Self(pads: 1, buttons: ["B", "A", "Y", "X", "L", "R"], menu: true)
    static let genesis = Self(pads: 1, buttons: ["A", "B", "C"], menu: true)
    static let genesis6 = Self(pads: 1, buttons: ["A", "B", "C", "X", "Y", "Z"], menu: true)
    static let arcade = Self(pads: 1, buttons: ["1", "2", "3", "4", "5", "6", "7", "8"], menu: true)
    static let n64 = Self(pads: 2, buttons: ["A", "B", "Z", "R", "L"], menu: true)
    static let xbox = Self(pads: 2, buttons: ["A", "B", "X", "Y", "LB", "RB", "LT", "RT"], menu: true)
    static let playStation = Self(pads: 2, buttons: ["Cross", "Circle", "Square", "Triangle", "L1", "R1", "L2", "R2"], menu: true)
    static let switchPro = Self(pads: 2, buttons: ["B", "A", "Y", "X", "L", "R", "ZL", "ZR"], menu: true)
    static let joyCon = Self(pads: 1, buttons: ["A", "B", "X", "Y", "SL", "SR"], menu: true)
    static let siriRemote = Self(pads: 1, buttons: ["Select", "Play/Pause"], menu: true)
}

/// Games as a noodlet would declare them.
private extension Gamepad {
    static let arrows = Pad(left: "left", right: "right", up: "up", down: "down")
    static let wasd = Pad(left: "a", right: "d", up: "w", down: "s")
    static func buttons(_ count: Int) -> [Button] {
        Array([Button(key: "space", label: "Jump"), Button(key: "z", label: "Fire"), Button(key: "x", label: "Bomb"),
               Button(key: "c"), Button(key: "v"), Button(key: "b"), Button(key: "n"), Button(key: "m")].prefix(count))
    }

    static let snake = Self(pads: [arrows])
    static let classic = Self(pads: [arrows], buttons: [Button(key: "x", label: "A"), Button(key: "z", label: "B")], menu: "enter")
    static let breakout = Self(pads: [Pad(left: "left", right: "right")], buttons: [Button(key: "space", label: "Launch")])
    static let platformer = Self(pads: [arrows], buttons: buttons(2), menu: "escape")
    static let fighter = Self(pads: [arrows], buttons: buttons(6), menu: "enter")
    static let everything = Self(pads: [arrows], buttons: buttons(8), menu: "escape")
    static let twinStick = Self(pads: [wasd, arrows], buttons: buttons(4), menu: "escape")
    static let twinStickFull = Self(pads: [wasd, arrows], buttons: buttons(8), menu: "escape")
    static let quiz = Self(buttons: buttons(3))
    static let elevator = Self(pads: [Pad(up: "up", down: "down")], buttons: buttons(1))
    static let pausable = Self(menu: "escape")

    static let all: [(String, Gamepad)] = [
        ("snake", snake), ("classic", classic), ("breakout", breakout), ("platformer", platformer), ("fighter", fighter),
        ("everything", everything), ("twin stick", twinStick), ("twin stick full", twinStickFull),
        ("quiz", quiz), ("elevator", elevator), ("pausable", pausable),
    ]
}

/// Screens the phone app runs on, with the safe areas iOS gives it.
private let screens: [(String, CGSize, EdgeInsets)] = [
    ("iPhone SE", CGSize(width: 375, height: 667), EdgeInsets(top: 20, leading: 0, bottom: 0, trailing: 0)),
    ("iPhone", CGSize(width: 402, height: 874), EdgeInsets(top: 62, leading: 0, bottom: 34, trailing: 0)),
    ("iPhone sideways", CGSize(width: 874, height: 402), EdgeInsets(top: 0, leading: 62, bottom: 21, trailing: 62)),
    ("iPhone SE sideways", CGSize(width: 667, height: 375), EdgeInsets()),
    ("iPad", CGSize(width: 1032, height: 1376), EdgeInsets(top: 24, leading: 0, bottom: 20, trailing: 0)),
    ("iPad sideways", CGSize(width: 1376, height: 1032), EdgeInsets(top: 24, leading: 0, bottom: 20, trailing: 0)),
]

final class GamepadDeclarationTests: XCTestCase {
    func testReadsTheManifestShape() throws {
        let json = #"""
        {"pads": [{"left": "a", "right": "d", "up": "w", "down": "s"}, {"left": "left", "right": "right"}],
         "buttons": [{"key": "space", "label": "Jump"}, {"key": "z"}], "menu": "escape"}
        """#
        let gamepad = try JSONDecoder().decode(Gamepad.self, from: Data(json.utf8))
        XCTAssertEqual(gamepad, Gamepad(pads: [Gamepad.wasd, Gamepad.Pad(left: "left", right: "right")],
                                        buttons: [.init(key: "space", label: "Jump"), .init(key: "z")], menu: "escape"))
        XCTAssertNoThrow(try gamepad.validate())
        XCTAssertEqual(try JSONDecoder().decode(Gamepad.self, from: Data(#"{"menu": "escape"}"#.utf8)), .pausable)
    }

    func testAcceptsEveryExampleGame() {
        for (name, gamepad) in Gamepad.all { XCTAssertNoThrow(try gamepad.validate(), name) }
    }

    func testRejectsWhatNoControllerCouldShow() {
        let wrong: [(String, Gamepad)] = [
            ("nothing", Gamepad()),
            ("three pads", Gamepad(pads: [Gamepad.arrows, Gamepad.wasd, Gamepad.Pad(left: "j", right: "l")])),
            ("a pad without directions", Gamepad(pads: [Gamepad.Pad()])),
            ("nine buttons", Gamepad(buttons: Gamepad.buttons(8) + [.init(key: "q")])),
            ("a key twice", Gamepad(pads: [Gamepad.arrows], buttons: [.init(key: "up")])),
            ("menu on a button's key", Gamepad(buttons: [.init(key: "space")], menu: "space")),
            ("an unknown key", Gamepad(buttons: [.init(key: "f1")])),
            ("a capital letter", Gamepad(buttons: [.init(key: "Z")])),
            ("a long label", Gamepad(buttons: [.init(key: "z", label: "Fire the big cannon")])),
            ("an empty label", Gamepad(buttons: [.init(key: "z", label: " ")])),
        ]
        for (name, gamepad) in wrong { XCTAssertThrowsError(try gamepad.validate(), name) }
    }
}

final class GamepadControllerTests: XCTestCase {
    private func onScreen(_ gamepad: Gamepad, _ controller: GamepadController) -> [String] {
        gamepad.mapped(to: controller).filter { $0.value == .screen }.keys.sorted()
    }

    func testAFullPadTakesEverything() {
        for controller in [GamepadController.xbox, .playStation, .switchPro] {
            XCTAssertEqual(onScreen(.twinStickFull, controller), [])
            let mapped = Gamepad.twinStickFull.mapped(to: controller)
            XCTAssertEqual(mapped["w"], .pad(0))
            XCTAssertEqual(mapped["up"], .pad(1))
            XCTAssertEqual(mapped["escape"], .menu)
        }
    }

    /// The most important button sits where the thumb rests, whatever the letters printed on it.
    func testButtonsGoByPositionNotLetter() {
        XCTAssertEqual(Gamepad.platformer.mapped(to: .xbox)["space"], .button("A"))
        XCTAssertEqual(Gamepad.platformer.mapped(to: .switchPro)["space"], .button("B"))
        XCTAssertEqual(Gamepad.platformer.mapped(to: .playStation)["space"], .button("Cross"))
        XCTAssertEqual(Gamepad.platformer.mapped(to: .snes)["z"], .button("A"))
    }

    func testWhatDoesNotFitGoesOnScreenLeastImportantFirst() {
        XCTAssertEqual(onScreen(.platformer, .atari), ["escape", "z"])
        XCTAssertEqual(Gamepad.platformer.mapped(to: .atari)["space"], .button("Fire"))
        XCTAssertEqual(onScreen(.fighter, .nes), ["b", "c", "v", "x"])
        XCTAssertEqual(onScreen(.fighter, .genesis), ["b", "c", "v"])
        XCTAssertEqual(onScreen(.fighter, .genesis6), [])
        XCTAssertEqual(onScreen(.everything, .arcade), [])
        XCTAssertEqual(onScreen(.everything, .joyCon), ["m", "n"])
        XCTAssertEqual(onScreen(.platformer, .siriRemote), [])
    }

    func testASecondPadNeedsASecondStick() {
        XCTAssertEqual(onScreen(.twinStick, .n64), [])
        XCTAssertEqual(onScreen(.twinStick, .snes), ["down", "left", "right", "up"])
        XCTAssertEqual(onScreen(.twinStick, .siriRemote), ["c", "down", "left", "right", "up", "x"])
    }

    /// With a controller in hand, only what it has no room for stays on the screen.
    func testTheScreenKeepsWhatTheControllerCannotTake() {
        XCTAssertNil(Gamepad.twinStickFull.onScreen(with: .xbox))
        XCTAssertEqual(Gamepad.twinStick.onScreen(with: .snes), Gamepad(pads: [Gamepad.arrows]))
        XCTAssertEqual(Gamepad.fighter.onScreen(with: .nes), Gamepad(buttons: Array(Gamepad.buttons(6).dropFirst(2))))
        XCTAssertEqual(Gamepad.platformer.onScreen(with: .atari), Gamepad(buttons: [Gamepad.buttons(2)[1]], menu: "escape"))
    }

    /// A stick or d-pad reports -1...1 with up positive; it steers the same eight ways as the screen.
    func testAStickSteersLikeTheScreenPad() {
        XCTAssertEqual(Gamepad.arrows.held(x: 0, y: 0), [])
        XCTAssertEqual(Gamepad.arrows.held(x: 0.15, y: -0.1), [])
        XCTAssertEqual(Gamepad.arrows.held(x: 1, y: 0), ["right"])
        XCTAssertEqual(Gamepad.arrows.held(x: 0, y: 1), ["up"])
        XCTAssertEqual(Gamepad.arrows.held(x: -0.7, y: -0.7), ["left", "down"])
        XCTAssertEqual(Gamepad.Pad(left: "left", right: "right").held(x: 0.2, y: 1), [])
    }

    func testMenuFallsBackToASpareButton() {
        XCTAssertEqual(Gamepad.pausable.mapped(to: .atari)["escape"], .button("Fire"))
        XCTAssertEqual(Gamepad.snake.mapped(to: .atari)["up"], .pad(0))
    }

    func testAPadWithSomeDirectionsMapsOnlyThose() {
        XCTAssertEqual(Gamepad.breakout.mapped(to: .nes), ["left": .pad(0), "right": .pad(0), "space": .button("A")])
        XCTAssertEqual(Gamepad.elevator.mapped(to: .nes), ["up": .pad(0), "down": .pad(0), "space": .button("A")])
    }
}

final class GamepadLayoutTests: XCTestCase {
    private func controls(_ gamepad: Gamepad) -> Set<GamepadLayout.Control> {
        Set(gamepad.pads.indices.map { .pad($0) } + gamepad.buttons.indices.map { .button($0) } + (gamepad.menu == nil ? [] : [.menu]))
    }

    private func check(_ body: (String, Gamepad, GamepadLayout, CGRect) -> Void) {
        for (screen, size, insets) in screens {
            let safe = CGRect(x: insets.leading, y: insets.top, width: size.width - insets.leading - insets.trailing,
                              height: size.height - insets.top - insets.bottom)
            for (game, gamepad) in Gamepad.all {
                body("\(game) on \(screen)", gamepad, GamepadLayout(gamepad, in: size, safeArea: insets), safe)
            }
        }
    }

    func testEveryControlIsPlacedOnce() {
        check { name, gamepad, layout, _ in XCTAssertEqual(Set(layout.frames.keys), controls(gamepad), name) }
    }

    func testControlsStayInsideTheSafeArea() {
        check { name, _, layout, safe in
            for (control, frame) in layout.frames { XCTAssertTrue(safe.contains(frame), "\(control) of \(name) at \(frame)") }
        }
    }

    func testControlsNeverOverlap() {
        check { name, _, layout, _ in
            let frames = Array(layout.frames)
            for (i, a) in frames.enumerated() {
                for b in frames[(i + 1)...] {
                    XCTAssertFalse(a.value.intersects(b.value), "\(a.key) and \(b.key) of \(name)")
                }
            }
        }
    }

    func testControlsAreBigEnoughForThumbs() {
        check { name, _, layout, _ in
            for (control, frame) in layout.frames {
                let least: CGFloat = if case .pad = control { 120 } else { 44 }
                XCTAssertGreaterThanOrEqual(min(frame.width, frame.height), least, "\(control) of \(name)")
            }
        }
    }

    /// The left thumb has the first pad and the menu; the right thumb has the rest.
    func testEachThumbKeepsToItsSide() {
        check { name, _, layout, safe in
            guard let pad = layout.frames[.pad(0)] else { return }
            XCTAssertEqual(pad.minX, safe.minX + GamepadLayout.margin, accuracy: 0.5, name)
            XCTAssertEqual(pad.maxY, safe.maxY - GamepadLayout.margin, accuracy: 0.5, name)
            for (control, frame) in layout.frames where control != .pad(0) && control != .menu {
                XCTAssertGreaterThan(frame.minX, pad.maxX, "\(control) of \(name)")
            }
            if let menu = layout.frames[.menu] { XCTAssertLessThan(menu.midX, safe.midX, name) }
        }
    }

    func testTheFirstButtonIsNearestTheRightThumb() {
        check { name, gamepad, layout, safe in
            guard gamepad.buttons.count > 1, let first = layout.frames[.button(0)] else { return }
            let thumb = layout.frames[.pad(1)].map { CGPoint(x: $0.midX, y: $0.midY) } ?? CGPoint(x: safe.maxX, y: safe.maxY)
            func distance(_ frame: CGRect) -> CGFloat { hypot(frame.midX - thumb.x, frame.midY - thumb.y) }
            for index in gamepad.buttons.indices.dropFirst() {
                XCTAssertLessThanOrEqual(distance(first), distance(layout.frames[.button(index)]!) + 0.5, "button \(index) of \(name)")
            }
        }
    }
}

extension GamepadLayoutTests {
    /// Two buttons sit on a slant, as on a Nintendo pad: the main one higher and to the right.
    func testTwoButtonsSitOnASlant() {
        check { name, gamepad, layout, _ in
            guard gamepad.buttons.count == 2, let first = layout.frames[.button(0)], let second = layout.frames[.button(1)] else { return }
            XCTAssertGreaterThan(first.minX, second.maxX, name)
            XCTAssertLessThan(first.midY, second.midY - 10, name)
        }
    }
}

final class GamepadPadTests: XCTestCase {
    private let frame = CGRect(x: 0, y: 0, width: 100, height: 100)

    private func pressed(_ x: CGFloat, _ y: CGFloat, _ pad: Gamepad.Pad = Gamepad.arrows) -> Set<String> {
        GamepadLayout.directions(at: CGPoint(x: x, y: y), in: frame, pad: pad)
    }

    func testTheMiddleIsAtRest() {
        XCTAssertEqual(pressed(50, 50), [])
        XCTAssertEqual(pressed(55, 45), [])
    }

    func testStraightDirections() {
        XCTAssertEqual(pressed(95, 50), ["right"])
        XCTAssertEqual(pressed(5, 50), ["left"])
        XCTAssertEqual(pressed(50, 5), ["up"])
        XCTAssertEqual(pressed(50, 95), ["down"])
        XCTAssertEqual(pressed(95, 42), ["right"])
    }

    func testDiagonalsHoldTwoKeys() {
        XCTAssertEqual(pressed(90, 10), ["right", "up"])
        XCTAssertEqual(pressed(10, 90), ["left", "down"])
    }

    func testAThumbSlidingOffStillSteers() {
        XCTAssertEqual(pressed(180, 50), ["right"])
        XCTAssertEqual(pressed(-40, -40), ["left", "up"])
    }

    func testAPadWithTwoDirectionsIgnoresTheOthers() {
        let sideways = Gamepad.Pad(left: "left", right: "right")
        XCTAssertEqual(pressed(50, 5, sideways), [])
        XCTAssertEqual(pressed(20, 10, sideways), ["left"])
        XCTAssertEqual(pressed(90, 90, sideways), ["right"])
    }

    func testSlidingReleasesBeforePressing() {
        XCTAssertEqual(GamepadKeyChange.changes(from: ["right", "up"], to: ["left", "up"]),
                       [.init(key: "right", pressed: false), .init(key: "left", pressed: true)])
        XCTAssertEqual(GamepadKeyChange.changes(from: ["up"], to: ["up"]), [])
    }
}

/// Draws each game on each screen and checks the pixels agree with the layout: something drawn at
/// every control, nothing in the middle of the screen where the game shows. Set
/// GAMEPAD_RENDER_DIRECTORY to keep the pictures.
@MainActor final class GamepadRenderingTests: XCTestCase {
    func testDrawsWhereTheLayoutSays() throws {
        let keep = ProcessInfo.processInfo.environment["GAMEPAD_RENDER_DIRECTORY"].map(URL.init(fileURLWithPath:))
        for (screen, size, insets) in screens {
            for (game, gamepad) in Gamepad.all {
                let name = "\(game) on \(screen)"
                let layout = GamepadLayout(gamepad, in: size, safeArea: insets)
                let (image, pixels) = try render(gamepad, layout, size)
                for (control, frame) in layout.frames {
                    let inside = if case .pad = control { CGPoint(x: frame.midX, y: frame.midY) } else { CGPoint(x: frame.midX, y: frame.maxY - 6) }
                    XCTAssertGreaterThan(pixels.alpha(at: inside), 0, "\(control) of \(name)")
                }
                XCTAssertEqual(pixels.alpha(at: CGPoint(x: size.width / 2, y: size.height / 3)), 0, name)
                if let keep {
                    let shown = ImageRenderer(content: GamepadControls(gamepad: gamepad, layout: layout)
                        .frame(width: size.width, height: size.height).background(Color(white: 0.15)))
                    let url = keep.appendingPathComponent("\(game) - \(screen).png")
                    let destination = try XCTUnwrap(CGImageDestinationCreateWithURL(url as CFURL, "public.png" as CFString, 1, nil))
                    CGImageDestinationAddImage(destination, try XCTUnwrap(shown.cgImage), nil)
                    XCTAssertTrue(CGImageDestinationFinalize(destination))
                    _ = image
                }
            }
        }
    }

    /// A view is laid out before it has its size; controls then have no room and lay out nothing,
    /// rather than trapping on a size they cannot divide.
    func testControlsWithNoRoomLayOutNothing() {
        let game = Gamepad(pads: [Gamepad.Pad(left: "left", right: "right", up: "up", down: "down")],
                           buttons: [Gamepad.Button(key: "c"), Gamepad.Button(key: "x")], menu: "escape")
        for gamepad in [Gamepad.snake, game] {
            for size in [CGSize.zero, CGSize(width: 20, height: 20)] {
                XCTAssertTrue(GamepadLayout(gamepad, in: size, safeArea: EdgeInsets()).frames.isEmpty, "\(size)")
            }
        }
        XCTAssertTrue(GamepadLayout(.snake, in: CGSize(width: 390, height: 844),
                                    safeArea: EdgeInsets(top: 500, leading: 0, bottom: 400, trailing: 0)).frames.isEmpty)
    }

    /// A pad is a cross with an arm for each direction it has, never a disc.
    func testPadsAreACrossOfTheirDirections() throws {
        let size = CGSize(width: 874, height: 402)
        for (gamepad, arms) in [(Gamepad.snake, ["left", "right", "up", "down"]), (.breakout, ["left", "right"]), (.elevator, ["up", "down"])] {
            let layout = GamepadLayout(gamepad, in: size, safeArea: EdgeInsets())
            let pad = try XCTUnwrap(layout.frames[.pad(0)])
            let pixels = try render(gamepad, layout, size).1
            XCTAssertEqual(pixels.alpha(at: CGPoint(x: pad.minX + 6, y: pad.minY + 6)), 0, "corner of \(arms)")
            let tips = ["left": CGPoint(x: pad.minX + 6, y: pad.midY), "right": CGPoint(x: pad.maxX - 6, y: pad.midY),
                        "up": CGPoint(x: pad.midX, y: pad.minY + 6), "down": CGPoint(x: pad.midX, y: pad.maxY - 6)]
            for (direction, tip) in tips {
                let alpha = pixels.alpha(at: tip)
                if arms.contains(direction) { XCTAssertGreaterThan(alpha, 0, "\(direction) of \(arms)") }
                else { XCTAssertEqual(alpha, 0, "\(direction) of \(arms)") }
            }
        }
    }

    private func render(_ gamepad: Gamepad, _ layout: GamepadLayout, _ size: CGSize) throws -> (CGImage, Pixels) {
        let renderer = ImageRenderer(content: GamepadControls(gamepad: gamepad, layout: layout).frame(width: size.width, height: size.height))
        renderer.scale = 1
        let image = try XCTUnwrap(renderer.cgImage)
        return (image, try Pixels(image))
    }
}

private struct Pixels {
    let width: Int, height: Int
    var bytes: [UInt8]

    init(_ image: CGImage) throws {
        width = image.width
        height = image.height
        bytes = [UInt8](repeating: 0, count: width * height * 4)
        let drawn = bytes.withUnsafeMutableBytes { buffer in
            CGContext(data: buffer.baseAddress, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                      space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
                .map { $0.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height)); return true } ?? false
        }
        guard drawn else { throw CocoaError(.coderInvalidValue) }
    }

    /// `point` from the top-left corner, as SwiftUI lays out.
    func alpha(at point: CGPoint) -> UInt8 {
        let x = min(max(Int(point.x), 0), width - 1), y = min(max(Int(point.y), 0), height - 1)
        return bytes[(y * width + x) * 4 + 3]
    }
}

#if os(macOS)
import AppKit
import ObjectiveC

/// A held key reaches the page as a key going down and, later, coming up, as a game reads it.
@MainActor final class GamepadKeyHoldTests: XCTestCase {
    private final class Recorder: NSView {
        var events: [(NSEvent.EventType, String, UInt16)] = []
        override var acceptsFirstResponder: Bool { true }
        override func keyDown(with event: NSEvent) { events.append((.keyDown, event.characters ?? "", event.keyCode)) }
        override func keyUp(with event: NSEvent) { events.append((.keyUp, event.characters ?? "", event.keyCode)) }
    }

    func testAHeldKeyGoesDownThenUp() throws {
        let view = Recorder(frame: CGRect(x: 0, y: 0, width: 100, height: 100))
        let injector = SurfaceEventInjector(view: view)
        try injector.deliver(.hold(key: "z", pressed: true))
        try injector.deliver(.hold(key: "left", pressed: true))
        try injector.deliver(.hold(key: "z", pressed: false))
        try injector.deliver(.hold(key: "7", pressed: true))
        XCTAssertEqual(view.events.map(\.0), [.keyDown, .keyDown, .keyUp, .keyDown])
        XCTAssertEqual(view.events.map(\.1), ["z", "\u{f702}", "z", "7"])
        XCTAssertEqual(view.events.map(\.2), [6, 123, 6, 26])
    }

    /// A view shown only to someone watching from elsewhere has nobody at this Mac to beep at,
    /// so a key its page leaves alone ends quietly instead of in AppKit's beep.
    func testAKeyNobodyTakesOutOfSightDoesNotBeep() throws {
        let original = try XCTUnwrap(class_getInstanceMethod(NSResponder.self, #selector(NSResponder.noResponder(for:))))
        let recording = try XCTUnwrap(class_getInstanceMethod(NSResponder.self, #selector(NSResponder.recordingNoResponder(for:))))
        method_exchangeImplementations(original, recording)
        defer { method_exchangeImplementations(original, recording) }
        unhandledKeys = 0
        let injector = SurfaceEventInjector(view: NSView(frame: CGRect(x: 0, y: 0, width: 100, height: 100)))
        try injector.deliver(.hold(key: "c", pressed: true))
        try injector.deliver(.key(.escape))
        XCTAssertEqual(unhandledKeys, 0)
    }

    /// Escape a page leaves alone comes back as a cancel command, which AppKit beeps at too.
    func testACommandNobodyTakesOutOfSightDoesNotBeep() throws {
        final class Page: NSView {
            override var acceptsFirstResponder: Bool { true }
            override func keyDown(with event: NSEvent) { window?.doCommand(by: #selector(NSResponder.cancelOperation(_:))) }
        }
        let original = try XCTUnwrap(class_getInstanceMethod(NSResponder.self, #selector(NSResponder.doCommand(by:))))
        let recording = try XCTUnwrap(class_getInstanceMethod(NSResponder.self, #selector(NSResponder.recordingDoCommand(by:))))
        method_exchangeImplementations(original, recording)
        defer { method_exchangeImplementations(original, recording) }
        unhandledCommands = 0
        try SurfaceEventInjector(view: Page(frame: CGRect(x: 0, y: 0, width: 100, height: 100))).deliver(.key(.escape))
        XCTAssertEqual(unhandledCommands, 0)
    }
}

@MainActor private var unhandledCommands = 0

@MainActor private var unhandledKeys = 0
extension NSResponder {
    /// Stands in for AppKit's beep while the test runs.
    @MainActor @objc fileprivate func recordingNoResponder(for selector: Selector) {
        if selector == #selector(NSResponder.keyDown(with:)) { unhandledKeys += 1 }
    }
    @MainActor @objc fileprivate func recordingDoCommand(by selector: Selector) { unhandledCommands += 1 }
}
#endif

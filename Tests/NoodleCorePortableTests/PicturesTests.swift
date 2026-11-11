import Foundation
@testable import NoodleCore
import XCTest

/// Pictures are told apart by their contents the same way wherever NoodleCore runs, with or without ImageIO.
final class PicturesTests: XCTestCase {
    private static let png = Data(base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAAAIAAAACCAIAAAD91JpzAAAAEUlEQVR4nGP4z8AARAxg8j8AG/ID/fPnS7EAAAAASUVORK5CYII=")!
    private static let jpeg = Data(base64Encoded:
            "/9j/4AAQSkZJRgABAQAASABIAAD/4QBMRXhpZgAATU0AKgAAAAgAAYdpAAQAAAABAAAAGgAAAAAAA6ABAAMAAAABAAEAAKACAAQA"
            + "AAABAAAAAqADAAQAAAABAAAAAgAAAAD/7QA4UGhvdG9zaG9wIDMuMAA4QklNBAQAAAAAAAA4QklNBCUAAAAAABDUHYzZjwCyBOmA"
            + "CZjs+EJ+/8AAEQgAAgACAwEiAAIRAQMRAf/EAB8AAAEFAQEBAQEBAAAAAAAAAAABAgMEBQYHCAkKC//EALUQAAIBAwMCBAMFBQQE"
            + "AAABfQECAwAEEQUSITFBBhNRYQcicRQygZGhCCNCscEVUtHwJDNicoIJChYXGBkaJSYnKCkqNDU2Nzg5OkNERUZHSElKU1RVVldY"
            + "WVpjZGVmZ2hpanN0dXZ3eHl6g4SFhoeIiYqSk5SVlpeYmZqio6Slpqeoqaqys7S1tre4ubrCw8TFxsfIycrS09TV1tfY2drh4uPk"
            + "5ebn6Onq8fLz9PX29/j5+v/EAB8BAAMBAQEBAQEBAQEAAAAAAAABAgMEBQYHCAkKC//EALURAAIBAgQEAwQHBQQEAAECdwABAgMR"
            + "BAUhMQYSQVEHYXETIjKBCBRCkaGxwQkjM1LwFWJy0QoWJDThJfEXGBkaJicoKSo1Njc4OTpDREVGR0hJSlNUVVZXWFlaY2RlZmdo"
            + "aWpzdHV2d3h5eoKDhIWGh4iJipKTlJWWl5iZmqKjpKWmp6ipqrKztLW2t7i5usLDxMXGx8jJytLT1NXW19jZ2uLj5OXm5+jp6vLz"
            + "9PX29/j5+v/bAEMAAgICAgICAwICAwUDAwMFBgUFBQUGCAYGBgYGCAoICAgICAgKCgoKCgoKCgwMDAwMDA4ODg4ODw8PDw8PDw8P"
            + "D//bAEMBAgICBAQEBwQEBxALCQsQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEP/dAAQA"
            + "Af/aAAwDAQACEQMRAD8A/Iv/AISDX/8AoJXP/f5/8aP+Eg1//oJXP/f5/wDGseiv6oP7UP/Z")!
    private static let gif = Data(base64Encoded: "R0lGODdhAgACAJEAAAAAAAAA//8AAP///yH5BAQAAAAALAAAAAACAAIAAAIDlBIFADs=")!
    private static let heic = Data(base64Encoded:
            "AAAAJGZ0eXBoZWljAAAAAG1pZjFNaVBybWlhZk1pSEJoZWljAAABh21ldGEAAAAAAAAAIWhkbHIAAAAAAAAAAHBpY3QAAAAAAAAA"
            + "AAAAAAAAAAAAJGRpbmYAAAAcZHJlZgAAAAAAAAABAAAADHVybCAAAAABAAAADnBpdG0AAAAAAAEAAAAjaWluZgAAAAAAAQAAABVp"
            + "bmZlAgAAAAABAABodmMxAAAAAOdpcHJwAAAAxmlwY28AAAATY29scm5jbHgAAgACAAaAAAAADGNsbGkAywBAAAAAFGlzcGUAAAAA"
            + "AAAAAgAAAAIAAAAJaXJvdAAAAAAQcGl4aQAAAAADCAgIAAAAcmh2Y0MBA3AAAACwAAAAAAAe8AD8/fj4AAALA6AAAQAXQAEMAf//"
            + "A3AAAAMAsAAAAwAAAwAecCShAAEAJEIBAQNwAAADALAAAAMAAAMAHqAUIEHAoQQYh7kWVTcCAgYAgKIAAQAJRAHAYXLIQFMkAAAA"
            + "GWlwbWEAAAAAAAAAAQABBoECAwWGhAAAAB5pbG9jAAAAAEQAAAEAAQAAAAEAAAG7AAAAUAAAAAFtZGF0AAAAAAAAAGAAAABMKAGv"
            + "o38QY7b3gFtjiDb4QUzWMkdCzH//1vwACw8/AanXsybWH/5MxgEsuMEtp1YkqDR9N3/hB6PcOzFjmSp39E1AIWBKMNcHRFgXUg==")!

    func testPicturesAreKnownByTheirContents() throws {
        XCTAssertEqual(Pictures.mediaType(of: Self.png), "image/png")
        XCTAssertEqual(Pictures.mediaType(of: Self.jpeg), "image/jpeg")
        XCTAssertEqual(Pictures.mediaType(of: Self.gif), "image/gif")
        XCTAssertEqual(Pictures.mediaType(of: Self.heic), "image/heic")
        XCTAssertNil(Pictures.mediaType(of: Data("PNG is not a picture".utf8)))
        XCTAssertNil(Pictures.mediaType(of: Data("%PDF-1.7\n".utf8)))
        XCTAssertNil(Pictures.mediaType(of: Data()))

        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let file = folder.appendingPathComponent("named.txt")
        try Self.jpeg.write(to: file)
        XCTAssertEqual(Pictures.mediaType(at: file), "image/jpeg", "the name decided, not the contents")
        XCTAssertNil(Pictures.mediaType(at: folder.appendingPathComponent("missing.png")))
    }

    func testOnlyAWholePictureDecodes() {
        XCTAssertTrue(Pictures.decodes(Self.png))
        XCTAssertTrue(Pictures.decodes(Self.jpeg))
        XCTAssertFalse(Pictures.decodes(Data("not a picture".utf8)))
        XCTAssertFalse(Pictures.decodes(Data()))
    }

    func testMediaTypesFollowCommonFileExtensions() {
        XCTAssertEqual(Pictures.mediaType(forFilenameExtension: "jpg"), "image/jpeg")
        XCTAssertEqual(Pictures.mediaType(forFilenameExtension: "png"), "image/png")
        XCTAssertEqual(Pictures.mediaType(forFilenameExtension: "pdf"), "application/pdf")
        XCTAssertEqual(Pictures.mediaType(forFilenameExtension: "txt"), "text/plain")
        XCTAssertEqual(Pictures.mediaType(forFilenameExtension: "json"), "application/json")
        XCTAssertEqual(Pictures.mediaType(forFilenameExtension: "mp4"), "video/mp4")
        XCTAssertNil(Pictures.mediaType(forFilenameExtension: "no-such-extension"))
        XCTAssertNil(Pictures.mediaType(forFilenameExtension: ""))
    }
}

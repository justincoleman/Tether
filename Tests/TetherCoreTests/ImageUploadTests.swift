import Foundation
import Testing
@testable import TetherCore

@Suite struct ImageUploadTests {
    static let jpeg = Data([0xFF, 0xD8, 0xFF, 0xE0, 0x00, 0x10, 0x4A, 0x46])
    static let png = Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, 0x00])

    @Test func acceptsJPEGAndPNGOnly() throws {
        #expect(try ImageUpload.fileExtension(for: Self.jpeg) == "jpg")
        #expect(try ImageUpload.fileExtension(for: Self.png) == "png")
        #expect(throws: ImageUpload.Failure.notAnImage) { try ImageUpload.fileExtension(for: Data("#!/bin/sh".utf8)) }
        #expect(throws: ImageUpload.Failure.notAnImage) { try ImageUpload.fileExtension(for: Data()) }
        let huge = Self.jpeg + Data(count: ImageUpload.maxBytes)
        #expect(throws: ImageUpload.Failure.tooLarge) { try ImageUpload.fileExtension(for: huge) }
    }

    @Test func savesUnderAFreshName() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("tether-uploads-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let a = try ImageUpload.save(Self.jpeg, in: dir)
        let b = try ImageUpload.save(Self.jpeg, in: dir)
        #expect(a != b)
        #expect(a.hasSuffix(".jpg"))
        #expect(FileManager.default.contents(atPath: a) == Self.jpeg)
    }

    @Test func promptPutsThePathAfterTheText() {
        #expect(ImageUpload.prompt(text: "  ", imagePath: "/u/x.jpg") == "Image from my iPhone: /u/x.jpg")
        #expect(ImageUpload.prompt(text: "Fix this layout\n", imagePath: "/u/x.jpg")
                == "Fix this layout\n\nImage from my iPhone: /u/x.jpg")
    }
}

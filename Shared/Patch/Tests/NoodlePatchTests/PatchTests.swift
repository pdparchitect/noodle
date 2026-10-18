import Foundation
import XCTest
import NoodlePatch

final class PatchTests: XCTestCase {
    func testReadsAFormatPatchSeries() throws {
        let patch = try XCTUnwrap(Patch(series))
        XCTAssertEqual(patch.commits.map(\.sha), ["a1c9e04b7d3f2e8a6c5b4d1e0f9a8b7c6d5e4f3a",
                                                  "5d2b7f1e9c8a3d6b4f2e1a0c9b8d7e6f5a4b3c2d",
                                                  "9e40c3a7d2b15f8e6c0a4b3d1f7e9c2a5b8d0e61"])
        XCTAssertEqual(patch.commits.map(\.subject), ["Film hidden noodlets frame by frame",
                                                      "Hold timers and animations between frames",
                                                      "Test the spacing of frames"])
        XCTAssertEqual(patch.commits[0].note, "A hidden page gets no animation frames, so Recording drives its own\nclock and asks for one frame at a time.")
        XCTAssertEqual(patch.commits[0].flowingNote, "A hidden page gets no animation frames, so Recording drives its own clock and asks for one frame at a time.")
        XCTAssertEqual(Patch.Commit(subject: "Lists", note: "Two changes:\n- one\n  continued\n2. two\n\nNext\nparagraph").flowingNote,
                       "Two changes:\n- one\n  continued\n2. two\n\nNext paragraph")
        XCTAssertNil(patch.commits[2].note)
        XCTAssertEqual(patch.commits[0].shortSHA, "a1c9e04")
        XCTAssertEqual(patch.author, "Wren")
        XCTAssertNil(patch.cover)

        XCTAssertEqual(patch.files.map(\.path), [
            "Applet/Sources/NoodleApplet/Recording.swift",
            "Applet/Protocol/Sources/NoodletRuntime/NoodletSnapshot.swift",
            "Applet/Sources/NoodleApplet/FrameCapture.swift",
            "Applet/Sources/NoodleApplet/FrameTimer.swift",
            "scripts/record-noodlet.sh",
            "Applet/Tests/Fixtures/square.png",
            "Applet/Tests/NoodleAppletTests/RecordingSmoothnessTests.swift",
        ])
        XCTAssertEqual(patch.files.map(\.status), [.modified, .added, .renamed, .deleted, .modified, .added, .added])

        // Changed by two commits, reviewed once, each hunk saying which commit it is from.
        let recording = patch.files[0]
        XCTAssertEqual(recording.hunks.map(\.commit), [0, 0, 1])
        XCTAssertEqual(recording.added, 6)
        XCTAssertEqual(recording.removed, 2)
        XCTAssertEqual(recording.hunks[0].section, "final class Recording {")
        XCTAssertEqual(recording.hunks[0].lines.map(\.kind), [.context, .context, .removed, .added, .added, .context, .context, .context])
        XCTAssertEqual(recording.hunks[1].header, "@@ -40,5 +41,7 @@ final class Recording {")

        // The signature after the last hunk of each message is not a removed line.
        XCTAssertEqual(patch.files[1].hunks.last?.lines.count, 4)
        XCTAssertEqual(patch.files[1].removed, 0)
        XCTAssertEqual(patch.added, 17)
        XCTAssertEqual(patch.removed, 7)
        XCTAssertEqual(patch.totals, "7 files, +17 −7")
        XCTAssertEqual(patch.title(filename: "smooth-recordings.patch"), "smooth-recordings.patch")
    }

    func testReadsRenamedNewDeletedBinaryAndModeChangedFiles() throws {
        let patch = try XCTUnwrap(Patch(series))
        let renamed = patch.files[2]
        XCTAssertEqual(renamed.oldPath, "Applet/Sources/NoodleApplet/Capture.swift")
        XCTAssertEqual(renamed.newPath, "Applet/Sources/NoodleApplet/FrameCapture.swift")
        XCTAssertEqual([renamed.added, renamed.removed], [2, 2])

        let added = patch.files[1]
        XCTAssertNil(added.oldPath)
        XCTAssertEqual(added.newMode, "100644")
        XCTAssertEqual(added.hunks.first?.lines.first?.newNumber, 1)

        let deleted = patch.files[3]
        XCTAssertNil(deleted.newPath)
        XCTAssertEqual(deleted.name, "FrameTimer.swift")
        XCTAssertEqual(deleted.folder, "Applet/Sources/NoodleApplet")
        XCTAssertEqual([deleted.added, deleted.removed], [0, 3])
        XCTAssertEqual(deleted.hunks.first?.lines.map(\.oldNumber), [1, 2, 3])

        let script = patch.files[4]
        XCTAssertEqual(script.modeChange, "100644 → 100755")
        XCTAssertTrue(script.hunks.isEmpty)

        let picture = patch.files[5]
        XCTAssertTrue(picture.isBinary)
        XCTAssertTrue(picture.hunks.isEmpty)
    }

    func testMarksALastLineWithoutANewline() throws {
        let patch = try XCTUnwrap(Patch(series))
        let lines = try XCTUnwrap(patch.files.last?.hunks.first?.lines)
        XCTAssertEqual(lines.count, 5)
        XCTAssertEqual(lines.last?.text, "}")
        XCTAssertEqual(lines.map(\.noNewlineAtEnd), [false, false, false, false, true])
    }

    func testReadsCRLFLikeLF() throws {
        let lf = try XCTUnwrap(Patch(series))
        let crlf = try XCTUnwrap(Patch(series.replacingOccurrences(of: "\n", with: "\r\n")))
        XCTAssertEqual(crlf, lf)
        XCTAssertFalse(crlf.files.flatMap(\.hunks).flatMap(\.lines).contains { $0.text.hasSuffix("\r") })
    }

    func testReadsAPlainGitDiff() throws {
        let patch = try XCTUnwrap(Patch(plainDiff))
        XCTAssertTrue(patch.commits.isEmpty)
        XCTAssertEqual(patch.files.map(\.path), ["Sources/Noodle/ChatView.swift", "Resources/icon.png", "README.md"])
        XCTAssertTrue(patch.files[1].isBinary)
        let lines = patch.files[0].hunks[0].lines
        XCTAssertEqual(lines.map(\.oldNumber), [3, nil, 4, 5])
        XCTAssertEqual(lines.map(\.newNumber), [3, 4, 5, 6])
        XCTAssertEqual(lines[1].text, "    let store: NoodleStore")
        XCTAssertEqual(patch.totals, "3 files, +2 −1")
        XCTAssertEqual(patch.title(filename: "change.diff"), "change.diff")
    }

    func testReadsAUnifiedDiffWithoutGitHeaders() throws {
        let patch = try XCTUnwrap(Patch("--- a/notes.txt\t2026-10-18 10:00:00 +0000\n+++ b/notes.txt\t2026-10-18 10:05:00 +0000\n@@ -1 +1 @@\n-old\n+new\n"))
        XCTAssertEqual(patch.files.map(\.path), ["notes.txt"])
        XCTAssertEqual(patch.files[0].hunks[0].lines.map(\.patchText), ["-old", "+new"])
    }

    func testReadsASingleCommitAndGitShow() throws {
        let single = try XCTUnwrap(Patch(singleCommit))
        XCTAssertEqual(single.title(filename: "fix.patch"), "Café menu for the noodlet")
        XCTAssertEqual(single.commits.first?.author, "Zoë Example")

        let shown = try XCTUnwrap(Patch(gitShow))
        XCTAssertEqual(shown.commits.map(\.subject), ["Test the spacing of frames"])
        XCTAssertEqual(shown.commits.first?.note, "Films a moving square and checks every frame.")
        XCTAssertEqual(shown.commits.first?.author, "Wren")
        XCTAssertEqual(shown.files.first?.hunks.first?.commit, 0)
    }

    func testACoverLetterNamesTheSeries() throws {
        let patch = try XCTUnwrap(Patch(coverLetter + series))
        XCTAssertEqual(patch.cover?.subject, "Smooth noodlet recordings")
        XCTAssertEqual(patch.commits.count, 3)
        XCTAssertEqual(patch.files[0].hunks.map(\.commit), [0, 0, 1])
        XCTAssertEqual(patch.title(filename: "series.patch"), "Smooth noodlet recordings")
    }

    func testSkipsWhatIsNotADiff() throws {
        let patch = try XCTUnwrap(Patch("Hi Petko,\n\nhere is the fix.\n\n" + plainDiff + "\nThanks,\nWren\n"))
        XCTAssertEqual(patch.files.count, 3)
        XCTAssertEqual(patch.files[2].hunks[0].lines.count, 3)
    }

    func testANonPatchIsNotRead() {
        XCTAssertNil(Patch("Just some notes.\n--- not a diff\n@@ nothing @@\n"))
        XCTAssertNil(Patch(""))
        XCTAssertNil(Patch(data: Data([0x89, 0x50, 0x4E, 0x47, 0, 0, 0, 0x0D])))
        XCTAssertNil(Patch(data: Data((plainDiff + "\u{0}").utf8)))
    }

    func testAHugeFileKeepsOnlyItsCounts() throws {
        let lines = (1...20_000).map { "+line \($0) of a generated file, long enough to add up" }
        let huge = "diff --git a/big.txt b/big.txt\nnew file mode 100644\n--- /dev/null\n+++ b/big.txt\n@@ -0,0 +1,20000 @@\n"
            + lines.joined(separator: "\n") + "\n"
        let patch = try XCTUnwrap(Patch(huge + plainDiff))
        XCTAssertTrue(patch.files[0].isTooLarge)
        XCTAssertTrue(patch.files[0].hunks.isEmpty)
        XCTAssertEqual(patch.files[0].added, 20_000)
        XCTAssertEqual(patch.files.count, 4)
        XCTAssertFalse(patch.files[1].isTooLarge)
        XCTAssertEqual(patch.files[1].hunks.count, 1)
    }

    func testListsAtMostTheFileLimit() throws {
        let text = (0..<(Patch.maximumFiles + 5)).map {
            "diff --git a/f\($0).txt b/f\($0).txt\n--- a/f\($0).txt\n+++ b/f\($0).txt\n@@ -1 +1 @@\n-a\n+b\n"
        }.joined()
        let patch = try XCTUnwrap(Patch(text))
        XCTAssertEqual(patch.files.count, Patch.maximumFiles)
        XCTAssertEqual(patch.omittedFiles, 5)
        XCTAssertEqual(patch.added, Patch.maximumFiles + 5)
        XCTAssertEqual(patch.totals, "2005 files, +2005 −2005")
    }

    func testReadsQuotedAndSpacedPaths() throws {
        let quoted = try XCTUnwrap(Patch("diff --git \"a/caf\\303\\251.txt\" \"b/caf\\303\\251.txt\"\nindex 1..2 100644\n--- \"a/caf\\303\\251.txt\"\n+++ \"b/caf\\303\\251.txt\"\n@@ -1 +1 @@\n-a\n+b\n"))
        XCTAssertEqual(quoted.files.first?.path, "café.txt")
        let spaced = try XCTUnwrap(Patch("diff --git a/My Notes.txt b/My Notes.txt\nold mode 100644\nnew mode 100755\n"))
        XCTAssertEqual(spaced.files.first?.path, "My Notes.txt")
    }

    func testAQuotedCommentFindsItsLines() throws {
        let patch = try XCTUnwrap(Patch(plainDiff))
        let lines = patch.files[0].hunks[0].lines
        let one = Patch.quote([lines[1]], in: "Sources/Noodle/ChatView.swift")
        XCTAssertEqual(one, "Sources/Noodle/ChatView.swift:4\n+    let store: NoodleStore")
        XCTAssertEqual(patch.place(of: one)?.hunk, 0)
        XCTAssertEqual(patch.place(of: one)?.line, 1)
        let two = Patch.quote(Array(lines[1...2]), in: "Sources/Noodle/ChatView.swift")
        XCTAssertTrue(two.hasPrefix("Sources/Noodle/ChatView.swift:4-5\n"))
        XCTAssertEqual(patch.place(of: two)?.line, 2)
        let removed = Patch.quote([patch.files[2].hunks[0].lines[0]], in: "README.md")
        XCTAssertEqual(removed, "README.md:1 (removed)\n-# Noodle")
        XCTAssertEqual(patch.place(of: removed)?.path, "README.md")
        XCTAssertNil(patch.place(of: "README.md:9\n+not in the patch"))
    }

    func testPatchFilesAreToldByNameOrMediaType() {
        XCTAssertTrue(Patch.isPatchFile(name: "change.patch", mediaType: "application/octet-stream"))
        XCTAssertTrue(Patch.isPatchFile(name: "CHANGE.DIFF", mediaType: ""))
        XCTAssertTrue(Patch.isPatchFile(name: "change", mediaType: "text/x-patch"))
        XCTAssertTrue(Patch.isPatchFile(name: "change.txt", mediaType: "text/x-diff"))
        XCTAssertFalse(Patch.isPatchFile(name: "notes.txt", mediaType: "text/plain"))
    }

    func testViewedFilesAreKeptPerAttachment() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("noodle-patch-\(UUID())")
        defer { try? FileManager.default.removeItem(at: folder) }
        let url = folder.appendingPathComponent("patch-reviews.json")
        let conversation = UUID(), other = UUID()
        let first = UUID(), second = UUID(), elsewhere = UUID()
        let store = PatchReviewStore(fileURL: url)
        try store.save(["a.swift", "b.swift"], attachment: first, in: conversation)
        try store.save(["c.swift"], attachment: elsewhere, in: other)
        XCTAssertEqual(PatchReviewStore(fileURL: url).viewed(attachment: first, in: conversation), ["a.swift", "b.swift"])
        XCTAssertEqual(PatchReviewStore(fileURL: url).viewed(attachment: second, in: conversation), [])
        try store.retainConversations([conversation])
        XCTAssertEqual(PatchReviewStore(fileURL: url).viewed(attachment: elsewhere, in: other), [])
        XCTAssertEqual(PatchReviewStore(fileURL: url).viewed(attachment: first, in: conversation), ["a.swift", "b.swift"])
        try store.save([], attachment: first, in: conversation)
        XCTAssertEqual(PatchReviewStore(fileURL: url).viewed(attachment: first, in: conversation), [])
    }

    func testCardsAndReviewsSumAPatchUp() throws {
        let patch = try XCTUnwrap(Patch(series))
        XCTAssertEqual(patch.headline(filename: "smooth.patch"), "a1c9e04…9e40c3a · Wren")
        XCTAssertEqual(patch.summary, "\(patch.fileCount) files · +\(patch.added) −\(patch.removed) · 3 commits · by Wren")
        let largest = patch.largestFiles(2).map { $0.added + $0.removed }
        XCTAssertEqual(largest.count, 2)
        XCTAssertEqual(largest.first, patch.files.map { $0.added + $0.removed }.max())

        let diff = try XCTUnwrap(Patch("--- a/README.md\n+++ b/README.md\n@@ -1 +1 @@\n-# Old\n+# New\n"))
        XCTAssertEqual(diff.headline(filename: "readme.diff"), "readme.diff")
        XCTAssertEqual(diff.summary, "1 file · +1 −1")
    }
}

// MARK: - Fixtures

/// `git format-patch --stdout main~3..main`: three commits, one file changed in two of them.
private let series = #"""
From a1c9e04b7d3f2e8a6c5b4d1e0f9a8b7c6d5e4f3a Mon Sep 17 00:00:00 2001
From: Wren <wren@noodle.example>
Date: Sat, 18 Oct 2026 10:05:00 +0000
Subject: [PATCH 1/3] Film hidden noodlets frame by frame

A hidden page gets no animation frames, so Recording drives its own
clock and asks for one frame at a time.

Signed-off-by: Wren <wren@noodle.example>
---
 Applet/Protocol/Sources/NoodletRuntime/NoodletSnapshot.swift | 4 ++++
 Applet/Sources/NoodleApplet/Recording.swift                  | 7 +++++--
 2 files changed, 9 insertions(+), 2 deletions(-)
 create mode 100644 Applet/Protocol/Sources/NoodletRuntime/NoodletSnapshot.swift

diff --git a/Applet/Sources/NoodleApplet/Recording.swift b/Applet/Sources/NoodleApplet/Recording.swift
index 3f2a1c0..8b7d9e1 100644
--- a/Applet/Sources/NoodleApplet/Recording.swift
+++ b/Applet/Sources/NoodleApplet/Recording.swift
@@ -10,6 +10,7 @@ final class Recording {
     let session: UUID
     let size: CGSize
-    var frameRate = 30
+    /// Frames are filmed one at a time on a clock of the recording's own.
+    let frameRate = 30
     private var frames: [CGImage] = []
     private var started: Date?

@@ -40,5 +41,7 @@ final class Recording {
     func capture() async throws {
-        try await Task.sleep(for: .milliseconds(33))
+        try await page.advance(by: 1.0 / Double(frameRate))
+        let frame = try await page.snapshot()
+        frames.append(frame)
     }

     func finish() -> URL? {
diff --git a/Applet/Protocol/Sources/NoodletRuntime/NoodletSnapshot.swift b/Applet/Protocol/Sources/NoodletRuntime/NoodletSnapshot.swift
new file mode 100644
index 0000000..5e1c2b4
--- /dev/null
+++ b/Applet/Protocol/Sources/NoodletRuntime/NoodletSnapshot.swift
@@ -0,0 +1,4 @@
+/// One frame of a noodlet, taken when its clock says so.
+public struct NoodletSnapshot: Sendable {
+    public var time: Double
+}
--
2.43.0


From 5d2b7f1e9c8a3d6b4f2e1a0c9b8d7e6f5a4b3c2d Mon Sep 17 00:00:00 2001
From: Wren <wren@noodle.example>
Date: Sat, 18 Oct 2026 10:40:00 +0000
Subject: [PATCH 2/3] Hold timers and animations between frames

Nothing moves while a frame is being captured.
---
 Applet/Sources/NoodleApplet/{Capture.swift => FrameCapture.swift} | 4 ++--
 Applet/Sources/NoodleApplet/Recording.swift                       | 1 +
 2 files changed, 3 insertions(+), 2 deletions(-)

diff --git a/Applet/Sources/NoodleApplet/Recording.swift b/Applet/Sources/NoodleApplet/Recording.swift
index 8b7d9e1..c4e5f60 100644
--- a/Applet/Sources/NoodleApplet/Recording.swift
+++ b/Applet/Sources/NoodleApplet/Recording.swift
@@ -52,4 +52,5 @@ final class Recording {
     func finish() -> URL? {
+        page.release()
         return writer.finish(frames)
     }
 }
diff --git a/Applet/Sources/NoodleApplet/Capture.swift b/Applet/Sources/NoodleApplet/FrameCapture.swift
similarity index 88%
rename from Applet/Sources/NoodleApplet/Capture.swift
rename to Applet/Sources/NoodleApplet/FrameCapture.swift
index 1b2c3d4..2c3d4e5 100644
--- a/Applet/Sources/NoodleApplet/Capture.swift
+++ b/Applet/Sources/NoodleApplet/FrameCapture.swift
@@ -1,5 +1,5 @@
 import CoreGraphics

-/// Takes pictures of a page.
-struct Capture {
+/// Takes one picture of a page per frame.
+struct FrameCapture {
     let scale: CGFloat
--
2.43.0


From 9e40c3a7d2b15f8e6c0a4b3d1f7e9c2a5b8d0e61 Mon Sep 17 00:00:00 2001
From: Wren <wren@noodle.example>
Date: Sat, 18 Oct 2026 11:35:00 +0000
Subject: [PATCH 3/3] Test the spacing of frames

---
 .../Sources/NoodleApplet/FrameTimer.swift          | 3 ---
 Applet/Tests/Fixtures/square.png                   | Bin 0 -> 68 bytes
 .../RecordingSmoothnessTests.swift                 | 5 +++++
 scripts/record-noodlet.sh                          | 0
 4 files changed, 5 insertions(+), 3 deletions(-)

diff --git a/Applet/Sources/NoodleApplet/FrameTimer.swift b/Applet/Sources/NoodleApplet/FrameTimer.swift
deleted file mode 100644
index 7a8b9c0..0000000
--- a/Applet/Sources/NoodleApplet/FrameTimer.swift
+++ /dev/null
@@ -1,3 +0,0 @@
-struct FrameTimer {
-    var interval = 1.0 / 30
-}
diff --git a/scripts/record-noodlet.sh b/scripts/record-noodlet.sh
old mode 100644
new mode 100755
diff --git a/Applet/Tests/Fixtures/square.png b/Applet/Tests/Fixtures/square.png
new file mode 100644
index 0000000..d3f8a91
Binary files /dev/null and b/Applet/Tests/Fixtures/square.png differ
diff --git a/Applet/Tests/NoodleAppletTests/RecordingSmoothnessTests.swift b/Applet/Tests/NoodleAppletTests/RecordingSmoothnessTests.swift
new file mode 100644
index 0000000..e4f5a6b
--- /dev/null
+++ b/Applet/Tests/NoodleAppletTests/RecordingSmoothnessTests.swift
@@ -0,0 +1,5 @@
+import XCTest
+
+final class RecordingSmoothnessTests: XCTestCase {
+    func testFramesAreEvenlySpaced() async throws {}
+}
\ No newline at end of file
--
2.43.0

"""#
    // Editors strip the space that ends git's signature line.
    .replacingOccurrences(of: "\n--\n", with: "\n-- \n")

/// `git diff`, with a binary file whose content git wrote out.
private let plainDiff = #"""
diff --git a/Sources/Noodle/ChatView.swift b/Sources/Noodle/ChatView.swift
index 1111111..2222222 100644
--- a/Sources/Noodle/ChatView.swift
+++ b/Sources/Noodle/ChatView.swift
@@ -3,3 +3,4 @@ struct ChatView: View {
     let conversation: BotConversation
+    let store: NoodleStore
     var body: some View {
         transcript
diff --git a/Resources/icon.png b/Resources/icon.png
index 5555555..6666666 100644
GIT binary patch
literal 12
TcmZ?wbhEHbRA6KP0000

literal 10
RcmZ?wbhEHbRA6KP00

diff --git a/README.md b/README.md
index 3333333..4444444 100644
--- a/README.md
+++ b/README.md
@@ -1,2 +1,2 @@
-# Noodle
+# Noodle for Mac
 Chat with your bots.
"""#

/// One commit, sent by mail: its subject and author are encoded words.
private let singleCommit = #"""
From 1b2c3d4e5f60718293a4b5c6d7e8f9012a3b4c5d Mon Sep 17 00:00:00 2001
From: =?UTF-8?q?Zo=C3=AB=20Example?= <zoe@noodle.example>
Date: Sat, 18 Oct 2026 09:00:00 +0000
Subject: [PATCH] =?UTF-8?q?Caf=C3=A9_menu_for_the_?=
 =?UTF-8?q?noodlet?=

---
 menu.txt | 2 +-
 1 file changed, 1 insertion(+), 1 deletion(-)

diff --git a/menu.txt b/menu.txt
index 1..2 100644
--- a/menu.txt
+++ b/menu.txt
@@ -1 +1 @@
-Coffee
+Café
--
2.43.0
"""#
    .replacingOccurrences(of: "\n--\n", with: "\n-- \n")

/// `git show`: the message indented under the commit's headers.
private let gitShow = #"""
commit 9e40c3a7d2b15f8e6c0a4b3d1f7e9c2a5b8d0e61
Author: Wren <wren@noodle.example>
Date:   Sat Oct 18 11:35:00 2026 +0000

    Test the spacing of frames

    Films a moving square and checks every frame.

diff --git a/a.txt b/a.txt
index 1..2 100644
--- a/a.txt
+++ b/a.txt
@@ -1 +1 @@
-a
+b
"""#

private let coverLetter = #"""
From 0000000000000000000000000000000000000000 Mon Sep 17 00:00:00 2001
From: Wren <wren@noodle.example>
Date: Sat, 18 Oct 2026 11:40:00 +0000
Subject: [PATCH 0/3] Smooth noodlet recordings

Hidden noodlets are filmed frame by frame.

Wren (3):
  Film hidden noodlets frame by frame
  Hold timers and animations between frames
  Test the spacing of frames

 Applet/Sources/NoodleApplet/Recording.swift | 8 +++++---
 7 files changed, 17 insertions(+), 7 deletions(-)

--
2.43.0


"""#

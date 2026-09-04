# Architecture

## Targets

`SuperBotCore` owns the durable data model and filesystem repository. `SuperBot` owns the SwiftUI application shell and presentation. The core target has no dependency on SwiftUI or AppKit, so workspace and transcript behavior can be exercised in isolated temporary directories.

## Native application shell

The shell continues the pattern proven in `skillman` and the Messages interface study: `NavigationSplitView` owns column behavior, while a selection-bound `.sidebar` `List` owns material, selection, focus, keyboard navigation, separators, and resizing. Product-specific rows supply only the bot avatar, title, timestamp, and transcript preview.

The unified toolbar retains macOS's system sidebar toggle and adds a native creation menu, selected-conversation identity, and explicit harness state. There is no custom title-bar replica.

## Persistence

Every agent and conversation receives an independent UUID. Display names are mutable metadata and never participate in a filesystem path. Repository writes use atomic JSON replacement. New agent workspaces begin with `agent.json`, `instructions.md`, and `memory.md`; each conversation stores its metadata and message list separately.

The app uses `FileManager`'s user Application Support location. In the signed sandboxed build, macOS resolves that into the app's private container automatically.

## Harness boundary

No harness is invoked in this stage. Outgoing commands are persisted with a `queued` delivery state and the UI says that they are waiting for a harness. A later transport layer can map approved harness descriptors to conversations without changing agent IDs, conversation IDs, or transcript storage.

The likely next boundary is a small, explicit harness registry containing an identifier, a user-approved executable location, supported invocation mode, and capability metadata. Any need to access executables outside the app container must be handled with user selection and security-scoped bookmarks or a separately sandboxed helper—not broad filesystem exceptions.

## Security

The bundle has only `com.apple.security.app-sandbox`. There are no optional entitlements and no embedded helper executables or third-party libraries. Build verification inspects the finished bundle rather than assuming its permissions from the source entitlement file.

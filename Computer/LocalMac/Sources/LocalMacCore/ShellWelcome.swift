import Foundation
import Darwin

/// Installs the image welcome in the managed account's interactive Zsh startup.
/// Existing settings are retained; linked or otherwise unusual rc files are left alone.
public enum LocalMacShellWelcome {
    private static let marker = "# Noodle Computer interactive welcome."
    private static func hook(identity: LocalMacIdentity) -> String { #"""
        # Noodle Computer interactive welcome.
        if [[ -o interactive && -t 1 && ${_NOODLE_WELCOME_PID:-} != $$ ]]; then
          _NOODLE_WELCOME_PID=$$
          if [[ -r "$HOME/Applications/\#(identity.desktopAppName).app/Contents/Resources/noodle-welcome" ]]; then
            NOODLE_BANNER="${NOODLE_BANNER:-1}" /bin/sh "$HOME/Applications/\#(identity.desktopAppName).app/Contents/Resources/noodle-welcome"
          fi
        fi
        """# }

    public static func prepare(home: String, identity: LocalMacIdentity) throws {
        guard identity.permitsAccountService else { throw LocalMacError("This build cannot prepare a managed account shell.") }
        let path = home + "/.zshrc"
        var fd = open(path, O_RDWR | O_APPEND | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
        let created = fd >= 0
        if !created {
            guard errno == EEXIST else { throw LocalMacError("Cannot prepare the managed account's shell prompt.") }
            fd = open(path, O_RDWR | O_APPEND | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
            // A custom linked or read-only configuration must not block startup.
            guard fd >= 0 else { return }
        }
        let file = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        defer { try? file.close() }
        var info = stat()
        guard fstat(fd, &info) == 0, info.st_uid == getuid(), info.st_mode & S_IFMT == S_IFREG,
              info.st_nlink == 1, info.st_size <= 1_048_576, flock(fd, LOCK_EX | LOCK_NB) == 0 else { return }
        defer { flock(fd, LOCK_UN) }
        let existing = try file.read(upToCount: 1_048_577) ?? Data()
        guard existing.count <= 1_048_576, existing.range(of: Data(marker.utf8)) == nil else { return }
        let prompt = created ? "# Noodle Local Mac default prompt. Customize this file as needed.\nPROMPT='%1~ %# '\n" : ""
        try file.write(contentsOf: Data((prompt + "\n" + hook(identity: identity) + "\n").utf8))
    }
}

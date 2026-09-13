import Foundation

/// Runs only inside the guest. Honour the image account's interactive shell;
/// /bin/sh can be Dash, which has no interactive history or line editor.
enum GuestShell {
    static let command = #"""
        cd /workspace || exit
        noodle_shell=
        noodle_current_uid=$(id -u)
        if [ -r /etc/passwd ]; then
            while IFS=: read -r noodle_name noodle_password noodle_uid noodle_gid noodle_gecos noodle_home noodle_login_shell; do
                [ "$noodle_uid" = "$noodle_current_uid" ] || continue
                HOME=$noodle_home
                USER=$noodle_name
                LOGNAME=$noodle_name
                export HOME USER LOGNAME
                case "$noodle_login_shell" in
                    */false|*/nologin) ;;
                    /*) [ ! -x "$noodle_login_shell" ] || noodle_shell=$noodle_login_shell ;;
                esac
                break
            done < /etc/passwd
        fi
        if [ -z "$noodle_shell" ]; then
            for noodle_candidate in /bin/bash /usr/bin/bash /bin/zsh /usr/bin/zsh /bin/ash /bin/sh; do
                if [ -x "$noodle_candidate" ]; then noodle_shell=$noodle_candidate; break; fi
            done
        fi
        SHELL=$noodle_shell
        export SHELL
        case "$SHELL" in
            */sh|*/ash|*/dash)
                if [ "$noodle_current_uid" = 0 ]; then PS1='${PWD} # '; else PS1='${PWD} $ '; fi
                export PS1 ;;
        esac
        exec "$SHELL" -i
        """#

    static let environment = [
        "PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin",
        "HOME=/root", "TERM=xterm-256color", "ENV=/etc/noodle/interactive-shell.sh"
    ]

    /// Image defaults supply HOME, PATH and desktop integration to guest commands.
    static func environment(inheriting imageEnvironment: [String], terminal: Bool = true) -> [String] {
        var values: [String: String] = [:]
        for entry in environment + imageEnvironment {
            let parts = entry.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
            if parts.count == 2 { values[String(parts[0])] = String(parts[1]) }
        }
        values["TERM"] = terminal ? "xterm-256color" : "dumb"
        values["ENV"] = "/etc/noodle/interactive-shell.sh"
        return values.keys.sorted().map { "\($0)=\(values[$0]!)" }
    }
}

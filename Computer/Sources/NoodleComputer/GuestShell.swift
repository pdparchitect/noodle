import Foundation

/// Runs only inside the guest. Honour its root account's interactive shell;
/// /bin/sh can be Dash, which has no interactive history or line editor.
enum GuestShell {
    static let command = #"""
        cd /workspace || exit
        noodle_shell=
        if [ -r /etc/passwd ]; then
            while IFS=: read -r noodle_name noodle_password noodle_uid noodle_gid noodle_gecos noodle_home noodle_login_shell; do
                [ "$noodle_uid" = 0 ] || continue
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
            */sh|*/ash|*/dash) PS1='${PWD} # '; export PS1 ;;
        esac
        exec "$SHELL" -i
        """#

    static let environment = [
        "PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin",
        "HOME=/root", "TERM=xterm-256color", "ENV=/etc/noodle/interactive-shell.sh"
    ]
}

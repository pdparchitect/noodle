import Foundation

enum GuestHome {
    // Execute as the image's configured user. The transport's fallback HOME
    // can still be /root even when that user is not root, so query its account.
    static let command = #"""
        noodle_current_uid=$(id -u) || exit
        noodle_accounts=
        if command -v getent >/dev/null 2>&1; then
            noodle_accounts=$(getent passwd "$noodle_current_uid") || noodle_accounts=
        fi
        if [ -z "$noodle_accounts" ] && [ -r /etc/passwd ]; then
            noodle_accounts=$(cat /etc/passwd) || exit
        fi
        while IFS=: read -r noodle_name noodle_password noodle_uid noodle_gid noodle_gecos noodle_home noodle_shell; do
            [ "$noodle_uid" = "$noodle_current_uid" ] || continue
            case "$noodle_home" in
                /*) printf '%s' "$noodle_home"; exit 0 ;;
            esac
        done <<EOF
        $noodle_accounts
        EOF
        printf '%s\n' 'The running account has no home directory.' >&2
        exit 1
        """#
}

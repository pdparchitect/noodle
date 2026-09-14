# Point shells at the desktop's real D-Bus session.
#
# dbus-run-session creates a private address that container exec shells and
# privilege-dropped product processes never inherit, so a client started from
# one of them autolaunches its own bus and finds none of the session's
# services: no notifications, and no keyring holding the secrets the desktop
# stored. Every client - secret-tool, an agent CLI, or anything using libsecret
# or libnotify directly -
# gets the address here instead of hand-rolling the same lookup.
#
# Installed for both login and interactive shells, and deliberately quiet: a
# shell opened before the session publishes its address must still start.

if [ -z "${DBUS_SESSION_BUS_ADDRESS:-}" ] &&
    [ -s /run/desktop/dbus-session-address ]; then
    DBUS_SESSION_BUS_ADDRESS="$(head -n 1 /run/desktop/dbus-session-address)"
    export DBUS_SESSION_BUS_ADDRESS
fi

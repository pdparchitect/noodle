import Foundation
import NoodleCore
import NoodleToolConnections
import Security
import Synchronization

/// Google Workspace's audit reports: sign-ins, admin actions, OAuth grants to apps, Drive and more, read as the admin
/// who signs in with Google, the way Noodle signs in to Gmail, through an iOS OAuth client their organisation made for
/// Pion's bundle ID. Each account is one admin's Workspace. Its Alert Center is not read: only a service account
/// acting for an admin may, and an admin's own sign-in is refused its scope. The audit events behind most of its alerts
/// are watched instead.
///
/// Containment is a second tool with a sign-in of its own, so only the bots given it can even ask for an action, and
/// the detection sign-in never carries a scope that can change accounts.
///
/// Why each tool asks for what it does, the least access to set each up with, and their caveats:
/// Incubator/Pion/docs/tools/google-workspace.md. Change it with the scopes, setup steps or operations here.
public enum GoogleWorkspace {
    /// The reports agents read: sign-ins and accounts, admin actions and app grants, what was opened, shared or sent,
    /// and what left the domain through Takeout and Vault exports.
    static let applications = ["login", "admin", "token", "drive", "saml", "user_accounts", "groups", "groups_enterprise", "mobile", "rules", "gmail", "chat",
                               "meet", "calendar", "takeout", "vault", "context_aware_access", "chrome", "access_transparency", "gcp",
                               "data_studio", "keep", "gemini_in_workspace_apps", "admin_data_action"]

    public static let preset = ToolDefinition(
        id: "8b1c8cc5-9be4-4be9-91fc-cb650f05d78c", name: "Google Workspace Detection", summary: "Audit reports: sign-ins, admin actions, OAuth app grants and Drive activity.",
        defaultInstructions: """
        Use Google Workspace Detection to see what happened in the domain: sign-ins, including suspicious ones and their IP \
        addresses; admin actions; OAuth tokens granted to apps; Drive sharing and downloads; SAML sign-ins; account changes. \
        Filter by user, event name, IP address and time; security-events lists those that mean an attack, such as \
        suspicious sign-ins, leaked passwords, admin privileges granted and compromised devices, and the alert watch \
        wakes you for each of them: also an admin changing someone's recovery phone, security keys, Advanced Protection \
        or password, a domain mail routing or compliance rule, defences loosened, such as 2-step verification, less \
        secure apps, API access, trusted apps, context-aware access, sessions, password recovery, a new domain or role, \
        a Takeout, Vault export, retention change or data transfer, an app granted access to mail, files or the \
        domain, a harmful app on a phone, and a file made public on the web or open to anyone with the link. An admin \
        resetting a password can be routine: check who did it and why before calling it an attack. A wake that names \
        an event read only in part means more of it happened than the watch could check: read security-events for its \
        window and narrow it. To audit who holds what, \
        admin-roles lists the super admins and every admin role with what it allows and who holds it. For a breach's \
        scope, users finds accounts by search, such as isEnrolledIn2Sv=false; user-groups and user-devices show what a user \
        reaches through groups and which phones hold their data; all-devices lists every phone and tablet in the domain, \
        longest unsynced first, with whose it is, to find one sold or lost but still allowed in; policy-settings reads \
        the organisation's current settings, such as 2-step verification enforcement, Drive sharing outside and default \
        link sharing, less secure apps and session length, which Google gives only to a super admin; and the takeout \
        and vault reports show what was exported. \
        To investigate an account, start with user-timeline, everything it and admins did to it in one list; to follow an \
        address, ip-activity; for a deleted account, users with deleted true gives the profile ID to read its history by. \
        activity filters on an event's details, such as doc_id== for who opened a file or client_id== for an app. In a \
        phishing case, link-clicks says who clicked a link in mail, by the link's address or domain or the message's subject \
        or ID, and mail-trace who received the message, opened, forwarded or deleted it or downloaded its attachments, \
        by its Message-ID, sender, recipient or subject, for up to 30 days. oauth-apps \
        lists every app people granted access in a window, by client ID and scopes, and every app an admin gave domain-wide \
        delegation, which acts as anyone without consent and no user's tokens show; app-activity shows what an app pulled; \
        client-activity shows everything one client ID did across Drive, Gmail, Calendar, admin actions and tokens, by \
        the account it acted as; Google Workspace Containment's tokens and apps list the access apps hold now. \
        group-members shows who reads a group, flagging outsiders. drive-exposure shows what left through Drive, for one \
        user or everyone: downloads, copies and prints by person and file, files shared outside the organisation by \
        domain, files made public or open to anyone with the link, and ownership handed over, with file IDs. Drive sharing \
        changes are drive events change_document_visibility, change_document_access_scope and change_user_access. When a \
        tool is refused or something you need seems missing, run check-access and tell the champion exactly what it says \
        to change. Silence is not proof: Google lists events minutes to hours late, keeps most for 180 days, and Gmail \
        events only in windows of 30 days; results say what was cut short or could not be read. A wake whose window \
        holds no events but a report that could not be read means the alert watch cannot read that report: run \
        check-access and tell the champion what it says. This tool cannot see \
        current mail forwarding addresses, filters or delegates, a list of laptops and desktops, or Google's Alert \
        Center; when policy-settings is refused, the Admin console's current settings, such as password, session, \
        sharing and app access rules, show only as changes in the admin events. The mobile report's events do cover \
        laptops and desktops enrolled through endpoint verification, as device types DESKTOP_CHROME, MAC, WINDOWS and \
        LINUX. Use Proofpoint or Microsoft Defender for mail and CrowdStrike or Defender for endpoints, ask \
        the champion for an Admin console page when a setting matters, and say what you could not check. domains lists \
        the organisation's domains; their SPF, DKIM and DMARC are public DNS, which a DNS tool checks. \
        Record each finding as evidence, citing the application, user \
        and time window. Hand the champion what to remediate exactly: Drive file IDs, each with the outside people or link \
        sharing to remove, and each phishing mail's Message-ID with who received it, for the Admin console's security \
        investigation tool. These tools only read: recommend suspending a user, signing them out, resetting their \
        password, removing their recovery details, revoking a token, wiping the account from a phone or changing sharing \
        to the champion.
        """,
        iconName: "google-workspace",
        configuration: .connection(.init(endpointTemplate: "https://admin.googleapis.com",
            fields: [ToolField(key: "clientID", title: "Client ID", placeholder: "1234-abc.apps.googleusercontent.com", kind: .identifier)],
            // Read-only, as the tool only reads: audit reports, users, their admin roles, groups, mobile devices and domains, and
            // from Cloud Identity the organisation's current settings. Laptops and desktops are in Cloud Identity's device API,
            // whose read-only scope is not on Google's list of scopes a sign-in may request, so it could fail the whole sign-in.
            oauth: .google(scopes: ["https://www.googleapis.com/auth/admin.reports.audit.readonly",
                                    "https://www.googleapis.com/auth/admin.directory.rolemanagement.readonly",
                                    "https://www.googleapis.com/auth/admin.directory.user.readonly",
                                    "https://www.googleapis.com/auth/admin.directory.group.readonly",
                                    "https://www.googleapis.com/auth/admin.directory.device.mobile.readonly",
                                    "https://www.googleapis.com/auth/admin.directory.domain.readonly",
                                    "https://www.googleapis.com/auth/cloud-identity.policies.readonly"], clients: []),
            oauthClientField: "clientID", adapter: "google-workspace")),
        setup: setup)

    static let setup = [
        "In the [Google Cloud console](https://console.cloud.google.com), pick or create a project in your organisation, and enable the [Admin SDK API](https://console.cloud.google.com/apis/library/admin.googleapis.com) and the [Cloud Identity API](https://console.cloud.google.com/apis/library/cloudidentity.googleapis.com) in it.",
        "Set up [Google Auth Platform](https://console.cloud.google.com/auth/overview) with the audience **Internal**, and under [Data Access](https://console.cloud.google.com/auth/scopes) add the scopes `https://www.googleapis.com/auth/admin.reports.audit.readonly`, `https://www.googleapis.com/auth/admin.directory.rolemanagement.readonly`, `https://www.googleapis.com/auth/admin.directory.user.readonly`, `https://www.googleapis.com/auth/admin.directory.group.readonly`, `https://www.googleapis.com/auth/admin.directory.device.mobile.readonly`, `https://www.googleapis.com/auth/admin.directory.domain.readonly` and `https://www.googleapis.com/auth/cloud-identity.policies.readonly`. Data Access takes a scope only once its API is enabled.",
        "Under [Clients](https://console.cloud.google.com/auth/clients), choose **Create client** of the type **iOS** with the bundle ID `com.pdparchitect.pion` (`com.pdparchitect.pion.local` for Pion Dev), and copy its **Client ID** here.",
        "In the Admin console's [Admin roles](https://admin.google.com/ac/roles), create a role such as **Pion Detection** with only **Reports**, **Users › Read**, **Groups › Read**, read access to admin roles, devices and domains, and assign it to an admin account kept for Pion, never a super admin. Google lets only a super admin read the organisation's current settings, so with this role policy-settings is refused and agents ask you for those Admin console pages instead.",
        "Choose **Add & Connect** and sign in as that admin.",
    ]

    /// Every operation of both tools, each naming the jobs it serves; each tool offers those of its own job.
    static let operations: [any ServiceOperation] = [
        Activity(), SecurityEvents(), AdminRoles(), Users(), UserGroups(), UserDevices(), AllDevices(), PolicySettings(), GroupMembers(), OAuthApps(), AppActivity(), UserTimeline(),
        IPActivity(), LinkClicks(), Domains(), CheckAccess(), DriveExposure(), MailTrace(), ClientActivity(),
        UserState(), Tokens(), Apps(), AppPasswords(), ContainmentDevices(), ContainmentCheckAccess(), SignOut(), ResetPassword(), RemoveRecovery(),
        RevokeToken(), DeleteAppPassword(), InvalidateBackupCodes(), DeviceBlock(), Suspend(), Unsuspend(),
    ]

    /// The Reports API turns away part of a burst of about 19 requests at once, well inside its per-minute quota.
    public static let adapter = OperationAdapter(operations: operations, job: .detection, trigger: NewSecurityEvents(), simultaneousRequests: 8)

    /// Suspending, resetting a password and removing recovery details take the broad user scope, as Google has none
    /// narrower; what the token can really do is set by the signing-in admin's role, which the setup keeps to those and
    /// User Security Management. Acting on a phone takes the mobile devices' action scope, the narrowest that lists
    /// devices and acts on them.
    public static let containment = ToolDefinition(
        id: "b04472f4-fbd5-496e-b286-fa76c23dd08f", name: "Google Workspace Containment",
        summary: "Sign a user out everywhere, reset their password, remove their recovery details, revoke an app's access, an app password or backup codes, block a phone from syncing, and suspend or restore a user.",
        defaultInstructions: """
        Use Google Workspace Containment to see an account's state and contain it: user shows whether it is suspended, \
        an admin or enrolled in 2-step verification; tokens lists the apps it has granted access, with their scopes; \
        app-passwords lists its app passwords; devices lists the phones and tablets that sync it, with the resource ID \
        each action on one takes; apps lists every app holding access to any account now, by client ID, with its scopes \
        and holders; check-access says what to change when something is refused. User Security Management \
        never covers admins, and only a super admin can act on a super admin or reset another admin's password, so this \
        tool cannot contain an admin: hand a \
        compromised admin to a super admin, with exactly what to do in the Admin console. Read tokens, app-passwords and \
        devices before suspending, as the record of what the account had granted. invalidate-backup-codes ends the backup \
        codes an attacker may have made. reset-password replaces a stolen password with a random one nobody knows, not \
        even you, so the user needs an admin to set a new one: sign them out too, as sessions already open keep working. \
        remove-recovery clears a recovery email or phone an attacker set, saying what it was, so record that as evidence. \
        device-block stops a phone syncing until an admin unblocks it. This tool cannot wipe the account from a phone: \
        recommend an account wipe for the champion to do in the Admin console, https://admin.google.com/ac/devices, \
        warning that Google resets company-owned and work-only Android phones and supervised iPhones to factory \
        settings, personal data and all, so the champion confirms how the phone is owned and managed first. sign-out, reset-password, remove-recovery, revoke-token, \
        delete-app-password, invalidate-backup-codes, device-block, suspend and \
        unsuspend are held for the champion's approval: give the exact user, and in --approval-reason why, the expected \
        effect and how to undo it, with the Investigation as --approval-conversation. Restoring is not simply undoing: \
        before unsuspending, recommend the champion resets the password and checks the recovery email and phone, 2-step \
        verification and the apps still granted access. Signing out alone leaves app access and the password working, and \
        revoking users' tokens leaves an app's domain-wide delegation in place: Google Workspace Detection's oauth-apps lists \
        those, and only an admin can remove one in the Admin console.
        """,
        iconName: "google-workspace",
        configuration: .connection(.init(endpointTemplate: "https://admin.googleapis.com",
            fields: [ToolField(key: "clientID", title: "Client ID", placeholder: "1234-abc.apps.googleusercontent.com", kind: .identifier)],
            oauth: .google(scopes: ["https://www.googleapis.com/auth/admin.directory.user",
                                    "https://www.googleapis.com/auth/admin.directory.user.security",
                                    "https://www.googleapis.com/auth/admin.directory.device.mobile.action"], clients: []),
            oauthClientField: "clientID", adapter: "google-workspace-containment")),
        setup: containmentSetup)

    static let containmentSetup = [
        "In the Admin console's [Admin roles](https://admin.google.com/ac/roles), create a role such as **Pion Containment** with only **Users › Read**, **Users › Update › Suspend users**, **Reset password** and **Force password change**, **Security › User Security Management** and **Services › Mobile Device Management**.",
        "To let agents remove a recovery email or phone too, add **Users › Update** itself: Google names no narrower privilege for recovery details, and it lets the role change any non-admin's profile. Leave it out and Pion's other actions still work.",
        "Assign it to an admin account kept for Pion, never a super admin. Its role, not the sign-in, limits what Pion can do.",
        "In the Google Cloud project of your Google Workspace Detection client, check the [Admin SDK API](https://console.cloud.google.com/apis/library/admin.googleapis.com) is enabled and add the scopes `https://www.googleapis.com/auth/admin.directory.user`, `https://www.googleapis.com/auth/admin.directory.user.security` and `https://www.googleapis.com/auth/admin.directory.device.mobile.action` under [Data Access](https://console.cloud.google.com/auth/scopes).",
        "Paste that same iOS client's **Client ID** here, or create one under [Clients](https://console.cloud.google.com/auth/clients) of the type **iOS** with the bundle ID `com.pdparchitect.pion` (`com.pdparchitect.pion.local` for Pion Dev).",
        "If your organisation limits API access, mark the client **Trusted** in the Admin console's [API controls](https://admin.google.com/ac/owl).",
        "Choose **Add & Connect** and sign in as the admin with the Pion Containment role.",
    ]

    /// Paced, as apps asks for each user's tokens in turn.
    public static let containmentAdapter = OperationAdapter(operations: operations, job: .containment, simultaneousRequests: 8)

    /// The audit events that mean an account or the domain may be under attack, each asked for by name as the Reports
    /// API takes one at a time, unless its report is read whole, with a parameter value that makes one not count:
    /// Google's suspicious and blocked sign-ins and the accounts it disabled; admin privileges, the primary admin,
    /// single sign-on and 2-step verification changed; devices found compromised or acting suspiciously; and rules
    /// that fired above low.
    static let watched: [(application: String, event: String, unless: (parameter: String, value: String)?)] = [
        ("login", "suspicious_login", nil), ("login", "suspicious_login_less_secure_app", nil), ("login", "suspicious_programmatic_login", nil),
        ("login", "user_signed_out_due_to_suspicious_session_cookie", nil), ("login", "risky_sensitive_action_blocked", nil),
        ("login", "account_disabled_password_leak", nil), ("login", "account_disabled_hijacked", nil), ("login", "account_disabled_spamming", nil),
        ("login", "account_disabled_spamming_through_relay", nil), ("login", "gov_attack_warning", nil),
        ("admin", "GRANT_ADMIN_PRIVILEGE", nil), ("admin", "GRANT_DELEGATED_ADMIN_PRIVILEGES", nil),
        ("admin", "UPDATE_DOMAIN_PRIMARY_ADMIN_EMAIL", nil), ("admin", "CHANGE_SSO_SETTINGS", nil), ("admin", "TOGGLE_SSO_ENABLED", nil),
        ("admin", "TURN_OFF_2_STEP_VERIFICATION", nil),
        // An account taken over: its second factor or recovery changed, its mail sent elsewhere or copied, codes or a
        // mailbox dump made for someone else.
        ("user_accounts", "2sv_disable", nil), ("user_accounts", "recovery_email_edit", nil), ("user_accounts", "recovery_phone_edit", nil),
        ("user_accounts", "email_forwarding_out_of_domain", nil), ("user_accounts", "titanium_unenroll", nil),
        ("admin", "CREATE_EMAIL_MONITOR", nil), ("admin", "MAIL_ROUTING_DESTINATION_ADDED", nil), ("admin", "GENERATE_2SV_SCRATCH_CODES", nil),
        ("admin", "REQUEST_MAILBOX_DUMP", nil), ("admin", "CHANGE_RECOVERY_EMAIL", nil), ("admin", "ADD_RECOVERY_EMAIL", nil),
        ("login", "account_disabled_generic", nil),
        ("mobile", "DEVICE_COMPROMISED_EVENT", ("DEVICE_COMPROMISED_STATE", "NOT_COMPROMISED")), ("mobile", "SUSPICIOUS_ACTIVITY_EVENT", nil),
        ("rules", "rule_trigger", ("severity", "LOW")),
        // A way back in that no user's tokens show: an app given domain-wide delegation acts as anyone without consent,
        // and an app trusted, unblocked or exempted gets past the domain's app controls (Google's Domain Settings and
        // Security Settings admin events).
        ("admin", "AUTHORIZE_API_CLIENT_ACCESS", nil), ("admin", "ADD_TO_TRUSTED_OAUTH2_APPS", nil), ("admin", "REMOVE_FROM_BLOCKED_OAUTH2_APPS", nil),
        ("admin", "UNBLOCK_ALL_THIRD_PARTY_API_ACCESS", nil), ("admin", "ADD_TO_CAA_EXEMPT_OAUTH2_APPS", nil),
        // A role given to someone, or widened for everyone who holds it (Google's Delegated Admin Settings events).
        ("admin", "ASSIGN_ROLE", nil), ("admin", "ADD_PRIVILEGE", nil),
        // Google calls suspicious_login a sign-in it blocked; one that succeeded is a login_success marked suspicious,
        // read with the filter below.
        ("login", "login_success", nil),
        // An admin taking over someone else's account: a recovery phone set, a security key added or taken away,
        // Advanced Protection or security-key-only sign-in turned off, a session Google blocked let through, or a
        // password reset and its temporary password viewed (Google's User Settings events). A suspicious session let
        // through a sensitive action, and a passkey removed, are the sign-in report's.
        ("admin", "CHANGE_RECOVERY_PHONE", nil), ("admin", "ADD_RECOVERY_PHONE", nil), ("admin", "SECURITY_KEY_REGISTERED_FOR_USER", nil),
        ("admin", "REVOKE_SECURITY_KEY", nil), ("admin", "UNENROLL_USER_FROM_TITANIUM", nil), ("admin", "UNENROLL_USER_FROM_STRONG_AUTH", nil),
        ("admin", "UNBLOCK_USER_SESSION", nil), ("admin", "CHANGE_PASSWORD", nil), ("admin", "VIEW_TEMP_PASSWORD", nil),
        ("login", "risky_sensitive_action_allowed", nil), ("login", "passkey_removed", nil),
        // The domain's mail routed, copied or let out by a rule no user's settings show (Google's Gmail Settings events).
        ("admin", "CREATE_GMAIL_SETTING", nil), ("admin", "CHANGE_GMAIL_SETTING", nil), ("admin", "CHANGE_EMAIL_SETTING", nil),
        // The domain's defences loosened: 2-step verification's enforcement or methods, less secure apps, which apps
        // reach which APIs and who trusts them, context-aware access, session length and reauthentication, password
        // recovery, a new domain or alias, and a role made or changed (Security, Domain and Delegated Admin Settings).
        // Methods narrowed to security keys only tighten them, so they do not count.
        ("admin", "ENFORCE_STRONG_AUTHENTICATION", nil), ("admin", "ALLOW_STRONG_AUTHENTICATION", nil),
        ("admin", "CHANGE_ALLOWED_TWO_STEP_VERIFICATION_METHODS", ("ALLOWED_TWO_STEP_VERIFICATION_METHOD", "ONLY_SECURITY_KEY")),
        ("admin", "WEAK_PROGRAMMATIC_LOGIN_SETTINGS_CHANGED", nil), ("admin", "TOGGLE_OAUTH_ACCESS_TO_ALL_APIS", nil), ("admin", "ENABLE_API_ACCESS", nil),
        ("admin", "ALLOW_SERVICE_FOR_OAUTH2_ACCESS", nil), ("admin", "ADD_TO_TRUSTED_BY_OAUTH_SCOPE_OAUTH2_APPS", nil),
        ("admin", "MULTIPLE_ADD_TO_TRUSTED_OAUTH2_APPS", nil), ("admin", "MULTIPLE_ADD_TO_TRUSTED_BY_OAUTH_SCOPE_OAUTH2_APPS", nil),
        ("admin", "TRUST_DOMAIN_OWNED_OAUTH2_APPS", nil), ("admin", "TOGGLE_CAA_ENABLEMENT", nil), ("admin", "CHANGE_CAA_APP_ASSIGNMENTS", nil),
        ("admin", "SESSION_CONTROL_SETTINGS_CHANGE", nil), ("admin", "CHANGE_SESSION_LENGTH", nil),
        ("admin", "ENABLE_NON_ADMIN_USER_PASSWORD_RECOVERY", nil), ("admin", "TOGGLE_ALLOW_ADMIN_PASSWORD_RESET", nil),
        ("admin", "ADD_SECONDARY_DOMAIN", nil), ("admin", "ADD_DOMAIN_ALIAS", nil), ("admin", "CREATE_ROLE", nil), ("admin", "UPDATE_ROLE", nil),
        // What left or was set to be destroyed: a Takeout started or scheduled, a Vault export made, a retention rule
        // or the default retention changed or deleted, and an account's data moved to another by an admin.
        ("takeout", "STARTED_USER_TAKEOUT", nil), ("takeout", "SCHEDULED_USER_TAKEOUT", nil),
        ("vault", "create_export_begin", nil), ("vault", "update_retention_rule_begin", nil), ("vault", "delete_retention_rule_begin", nil),
        ("vault", "modify_default_retention_period_begin", nil), ("admin", "CREATE_DATA_TRANSFER_REQUEST", nil),
        // An app granted access that reads or sends mail, reads files or administers, as consent phishing asks for;
        // the rest of the grants are left out here, by their scopes' risk.
        ("token", "authorize", nil),
        // A harmful app found on a phone, read with the filter below.
        ("mobile", "APPLICATION_EVENT", nil),
        // A file a user made public on the web or open to anyone with the link, kept by its new link sharing below.
        // A share with one outside person is not watched: telling it from an inside one takes the organisation's
        // domains, and it is far more common; drive-exposure lists them.
        ("drive", "change_document_visibility", nil),
    ]

    /// The filters a watched event is read with, by application/event, for an event that is serious only with them.
    /// Google takes a filter only with an event's name, so none is on a report read whole.
    static let watchedFilters = ["login/login_success": "is_suspicious==true", "login/risky_sensitive_action_allowed": "is_suspicious==true",
                                 "mobile/APPLICATION_EVENT": "APPLICATION_STATE==PHA"]

    /// The highest risk an app's grant counts with, by application/event, as `risk` ranks its scopes: reading or sending
    /// mail, reading every file or administering the domain. A calendar app or a sign-in with Google never wakes anyone.
    static let watchedRisk = ["token/authorize": 2]

    /// The reports read whole, a page of up to 1000 events at a time, and kept here only for their watched events,
    /// rather than asked for event by event: Google allows only 250 filtered requests a minute, a request naming an event
    /// among them, and these reports are quiet enough to read whole. One with more than `mostRead` events in a window is then read event by
    /// event too, so a busy domain's watched events are never cut off.
    static let readWhole: Set<String> = ["admin", "user_accounts", "takeout", "vault"]

    /// The most events read of a report read whole, or of a watched event mostly left out here, such as the apps granted
    /// access, before it is said to be cut short.
    static let mostRead = 5000

    /// How many more pages one read of the watched events may ask Google for, across every watched event kept here only
    /// in part that is read on, so a busy domain's routine grants or phones' ordinary changes cannot hide a risky one.
    /// Google allows 250 requests naming an event a minute, and a check already sends one or more for each watched event
    /// read by name, every five minutes: 20 more pages keep a check well inside that, even when Google answers in short
    /// pages, while full pages of 1000 still reach 20,000 more events.
    static let readOnPages = 20

    /// Whether a watched event is kept here only in part, by its details, its scopes' risk or an exception, so that
    /// a read of it cut short may have left out the very one that counts. A filter Google applies, such as a sign-in's
    /// is_suspicious, is not such a part: all it returns counts, so the newest found still wake the agents.
    static func keptInPart(_ label: String) -> Bool {
        watchedOnly[label] != nil || watchedRisk[label] != nil
            || watched.contains { "\($0.application)/\($0.event)" == label && $0.unless != nil }
    }

    /// The values of a detail a watched event counts only with, by application/event: Google raises a device's
    /// suspicious activity for any change of its properties, such as its model or Wi-Fi address, and only these say the
    /// device's integrity or Google's device management on it changed.
    static let watchedOnly: [String: (parameter: String, values: Set<String>)] = [
        "mobile/SUSPICIOUS_ACTIVITY_EVENT": ("DEVICE_PROPERTY", ["BASIC_INTEGRITY", "CTS_PROFILE_MATCH", "DEVICE_BOOTLOADER", "DMAGENT_PERMISSION"]),
        // Google's Drive page gives a link sharing change's new setting as new_value; only these reach past the
        // organisation. One made by a parent folder is another event, not watched.
        "drive/change_document_visibility": ("new_value", ["public_on_the_web", "people_with_link"]),
    ]

    /// One audit event. Its ID is the report, the record's time and qualifier, which Google gives to tell records at the
    /// same time apart, the event's name and its place in the record, so no two events are taken for one.
    struct Event: Encodable {
        let id: String, time: String?, application: String, user: String?, ip: String?, event: String, parameters: [String: String]
        /// Where the address is, as Google places it: its autonomous system and region.
        var asn: String? = nil, region: String? = nil
        /// The app that acted for the user, when one did: its name, its OAuth client ID, which ties the action to a grant
        /// or a domain-wide delegation, and whether it impersonated the user.
        var via: String? = nil, viaClient: String? = nil, impersonated: Bool? = nil

        /// The details that matter for each kind of event, shown before the rest.
        static let keyDetails = [
            "doc_title", "target_user", "visibility", "old_visibility", "new_value", "old_value", "target_domain", "owner", "doc_id",
            "app_name", "client_id", "scope", "client_type", "api_name", "method_name", "num_response_bytes",
            "login_type", "login_challenge_method", "login_challenge_status", "is_suspicious", "is_second_factor", "sensitive_action_name",
            "USER_EMAIL", "SETTING_NAME", "NEW_VALUE", "OLD_VALUE", "EMAIL_MONITOR_DEST_EMAIL", "email_forwarding_destination_address",
            "affected_email_address", "event_info.mail_event_type", "API_CLIENT_NAME", "API_SCOPES", "OAUTH2_APP_NAME", "OAUTH2_APP_ID",
            // What an admin changed, and where, so a password reset or a policy loosened can be judged from its line:
            // Google's admin events give the setting, its old and new values, the role, the organisational unit or group
            // it applies to, and what each of their own kind changed.
            "new_owner", "ROLE_NAME", "PRIVILEGE_NAME", "ALLOWED_TWO_STEP_VERIFICATION_METHOD", "REAUTH_SETTING_NEW", "REAUTH_SETTING_OLD",
            "REAUTH_APPLICATION", "TARGET_ENTITY_NAME", "CAA_ACCESS_LEVELS_NEW", "CAA_ACCESS_LEVELS_OLD", "CAA_ASSIGNMENTS_NEW", "CAA_ASSIGNMENTS_OLD",
            "DESTINATION_USER_EMAIL", "SECONDARY_DOMAIN_NAME", "DOMAIN_ALIAS", "OAUTH2_SERVICE_NAME", "OAUTH2_NUM_APPS", "SETTING_DESCRIPTION",
            "USER_DEFINED_SETTING_NAME", "SETTING_ENABLED", "ORG_UNIT_NAME", "GROUP_EMAIL", "DOMAIN_NAME",
        ]

        var line: String {
            var line = "\(time ?? "?") \(event)"
            if let user { line += " by \(user)" }
            if via != nil || viaClient != nil {
                let notes = [viaClient.map { "client \($0)" }, impersonated == true ? "impersonating the user" : nil].compactMap { $0 }
                line += " via \(via ?? "an app")" + (notes.isEmpty ? "" : " (\(notes.joined(separator: ", ")))")
            }
            if let ip { line += " from \(ip)" + ([asn.map { "AS\($0)" }, region].compactMap { $0 }.isEmpty ? "" : " (\([asn.map { "AS\($0)" }, region].compactMap { $0 }.joined(separator: ", ")))") }
            let rank = Dictionary(Self.keyDetails.enumerated().map { ($1, $0) }, uniquingKeysWith: { first, _ in first })
            let details = parameters.sorted { (rank[$0.key] ?? Int.max, $0.key) < (rank[$1.key] ?? Int.max, $1.key) }.prefix(8)
                .map { "\($0.key)=\($0.value.count > 160 ? String($0.value.prefix(160)) + "…" : $0.value)" }
            if !details.isEmpty { line += " (\(details.joined(separator: ", ")))" }
            return line
        }
    }

    /// Events read from one report, whether the report had more than were read, and why reading stopped when a later
    /// page could not be read: the pages before it are kept.
    struct EventPage {
        var events: [Event]; var more: Bool; var failure: Error? = nil

        /// What a result says when a later page could not be read, so what was read is not taken for the whole.
        var stopped: String? {
            failure.map { "Read only in part: a later page could not be read (\($0.localizedDescription)); try again or narrow the window." }
        }
    }

    /// An event's details as Google sends them: values, lists, and details nested inside details, as Gmail's are.
    fileprivate struct Parameter: Decodable {
        struct Message: Decodable { let parameter: [Parameter]? }
        let name: String?, value: String?, boolValue: Bool?, intValue: String?, multiValue: [String]?, multiIntValue: [String]?
        let messageValue: Message?, multiMessageValue: [Message]?

        /// Each value by its name, nested ones as parent.child.
        func flattened(under prefix: String = "") -> [(String, String)] {
            let key = prefix + (name ?? "?")
            if let shown = value ?? boolValue.map(String.init) ?? intValue ?? multiValue?.joined(separator: ", ")
                ?? multiIntValue?.joined(separator: ", ") {
                return [(key, key == "event_info.mail_event_type" ? GoogleWorkspace.mailEvent(shown) : shown)]
            }
            let nested = (messageValue.map { [$0] } ?? []) + (multiMessageValue ?? [])
            return nested.flatMap { message in (message.parameter ?? []).flatMap { $0.flattened(under: key + ".") } }
        }
    }

    /// What a Gmail event type means, for the ones Google's Gmail event page names; the number alone for the rest.
    static func mailEvent(_ code: String) -> String {
        mailEvents[code].map { "\(code) (\($0))" } ?? code
    }

    /// The Gmail event types Google's Gmail event page names
    /// (https://developers.google.com/workspace/admin/reports/v1/appendix/activity/gmail).
    static let mailEvents = [
        "0": "a delivery stage not shown in the security investigation tool", "1": "sent", "2": "received",
        "3": "marked as spam, phishing or not spam by the user", "4": "flagged as spam after delivery", "5": "quarantined",
        "6": "released from quarantine", "7": "opened for the first time", "8": "marked as unread", "9": "replied to for the first time",
        "10": "forwarded for the first time", "11": "autoforwarded by a forwarding setting", "12": "moved to the inbox", "13": "moved to the trash",
        "14": "taken out of the trash", "15": "link in the body clicked", "16": "link in an attachment preview clicked",
        "17": "attachments downloaded", "18": "attachments saved to Drive", "19": "Drive items in it saved to the recipient's Drive",
        "20": "classification label applied", "21": "classification label changed", "22": "classification label removed",
        "23": "classification label applied to its attachments", "24": "classification label changed on its attachments",
        "25": "classification label removed from its attachments", "26": "archived", "27": "deleted for good", "28": "attachments previewed",
        "29": "saved as a draft", "30": "bounced", "31": "viewed", "32": "downloaded", "33": "read by an app for the user",
        "34": "receive rate limited", "35": "send started by the user or an app",
    ]

    /// The most pages one read takes, so a report Google answers in short pages, as it may with filters, still ends.
    static let mostPages = 100

    /// A report's events, newest first, only those named `event` when it is given, reading page after page up to
    /// `limit`. A Gmail report takes only a window of 30 days at most, with an end.
    static func events(_ service: ServiceClient, application: String, user: String = "all", event: String? = nil,
                       query: [String: String?], limit: Int = 1000, pages: Int = mostPages) async throws -> EventPage {
        struct ID: Decodable { let time: String?; let uniqueQualifier: String? }
        struct Info: Decodable { let applicationName: String?; let oauthClientId: String?; let impersonation: Bool? }
        struct Actor: Decodable { let email: String?; let applicationInfo: Info? }
        struct Network: Decodable {
            let regionCode: String?, subdivisionCode: String?, asn: [String]
            enum Keys: String, CodingKey { case ipAsn, regionCode, subdivisionCode }
            init(from decoder: Decoder) throws {
                let container = try decoder.container(keyedBy: Keys.self)
                regionCode = try? container.decodeIfPresent(String.self, forKey: .regionCode)
                subdivisionCode = try? container.decodeIfPresent(String.self, forKey: .subdivisionCode)
                asn = (try? container.decodeIfPresent([Int].self, forKey: .ipAsn))?.map(String.init)
                    ?? (try? container.decodeIfPresent([String].self, forKey: .ipAsn)) ?? []
            }
        }
        struct Named: Decodable { let name: String?; let parameters: [Parameter]? }
        struct Item: Decodable { let id: ID?; let actor: Actor?; let ipAddress: String?; let networkInfo: Network?; let events: [Named]? }
        struct Answer: Decodable { let items: [Item]?; let nextPageToken: String? }
        var query = query
        if let event { query["eventName"] = event }
        if application == "gmail" { query = try gmailWindow(query) }
        var items: [Item] = [], token: String?, failure: Error?
        for page in 0..<max(pages, 1) {
            query["maxResults"] = String(min(1000, limit - items.count))
            query["pageToken"] = token
            let answer: Answer
            do {
                answer = try await read(.reports) { try await service.at(host: "admin.googleapis.com").get(
                    ["admin", "reports", "v1", "activity", "users", user, "applications", application], query: query, as: Answer.self) }
            } catch let error where page > 0 {
                // The pages read are kept, said to be only part, rather than lost to one after them that failed.
                failure = error
                break
            }
            items += answer.items ?? []
            token = answer.nextPageToken.flatMap { $0.isEmpty ? nil : $0 }
            if token == nil || items.count >= limit { break }
        }
        let events = items.flatMap { item in
            (item.events ?? []).enumerated().compactMap { index, named -> Event? in
                guard let name = named.name, event == nil || name == event else { return nil }
                var found = Event(id: "\(application)/\(item.id?.time ?? "?")/\(item.id?.uniqueQualifier ?? "?")/\(name)/\(index)", time: item.id?.time,
                                  application: application, user: item.actor?.email, ip: item.ipAddress, event: name,
                                  // A detail given more than once, as each link of a Gmail message is, keeps every value.
                                  parameters: Dictionary((named.parameters ?? []).flatMap { $0.flattened() }, uniquingKeysWith: { "\($0) | \($1)" }))
                found.asn = item.networkInfo?.asn.first
                found.region = item.networkInfo?.subdivisionCode ?? item.networkInfo?.regionCode
                found.via = item.actor?.applicationInfo?.applicationName
                found.viaClient = item.actor?.applicationInfo?.oauthClientId
                found.impersonated = item.actor?.applicationInfo?.impersonation
                return found
            }
        }
        // A page left to read, whether for the limit, the pages running out or one that failed, means there was more.
        return EventPage(events: events, more: token != nil, failure: failure)
    }

    /// Google takes Gmail events only with both ends, at most 30 days apart: the end is now when left out.
    static func gmailWindow(_ query: [String: String?]) throws -> [String: String?] {
        var query = query
        let end = (query["endTime"] ?? nil) ?? ISO8601DateFormatter().string(from: Date())
        query["endTime"] = end
        let parse: (String?) -> Date? = { value in value.flatMap { ServiceAlert.time($0) } }
        if let start = parse(query["startTime"] ?? nil), let finish = parse(end), finish.timeIntervalSince(start) > 30 * 86_400 {
            throw ServiceError.input("Google takes Gmail events for a window of 30 days at most; ask for a shorter one.")
        }
        return query
    }

    /// A window cut to its last 30 days, for a Gmail read among others in a window Google would refuse for Gmail, with
    /// where it now starts; nil for a window that fits.
    static func lastThirtyDays(_ query: [String: String?]) -> (query: [String: String?], from: String)? {
        let format = ISO8601DateFormatter(), parse: (String?) -> Date? = { value in value.flatMap { ServiceAlert.time($0) } }
        let end = parse(query["endTime"] ?? nil) ?? Date()
        guard let start = parse(query["startTime"] ?? nil), end.timeIntervalSince(start) > 30 * 86_400 else { return nil }
        let from = format.string(from: end.addingTimeInterval(-30 * 86_400))
        return (query.merging(["startTime": from, "endTime": format.string(from: end)]) { $1 }, from)
    }

    /// Several reports read at once, keeping what each found when another is refused, and saying what was searched,
    /// what was cut short or read only in part and what could not be read, so a gap is never taken for nothing having
    /// happened.
    struct Gathered {
        var events: [Event] = [], searched: [String] = [], cut: [String] = [], failed: [(String, String)] = []
        /// The reads kept only in part, with why: a later page that could not be read, or a window Google takes only part of.
        var partial: [(String, String)] = []
        /// The reads not tried, with why, such as one a deleted account's profile ID cannot be asked for by.
        var skipped: [(String, String)] = []
        /// The reads among `failed` and `partial` that failed for a passing reason, and would likely work if tried again.
        var passing: [String] = []

        var coverage: String {
            var lines = ["Searched: \(searched.joined(separator: ", "))."]
            if !cut.isEmpty { lines.append("Cut short, with more not read: \(cut.joined(separator: ", ")); narrow the window.") }
            if !partial.isEmpty { lines.append("Read only in part: " + partial.map { "\($0.0) (\($0.1))" }.joined(separator: "; ")) }
            if !failed.isEmpty { lines.append("Could not read: " + failed.map { "\($0.0) (\($0.1))" }.joined(separator: "; ")) }
            if !skipped.isEmpty { lines.append("Not read: " + skipped.map { "\($0.0) (\($0.1))" }.joined(separator: "; ")) }
            return lines.joined(separator: "\n")
        }

        /// What a result opens with when it found nothing, such as "Nothing for someone": in this window only when every
        /// report was read in full, otherwise in the reports that could be read, naming those that could not.
        func nothing(_ none: String) -> String {
            var seen = Set<String>()
            let unchecked = (failed + skipped).map(\.0).filter { seen.insert($0).inserted }
            let unfinished = (cut + partial.map(\.0)).filter { seen.insert($0).inserted }
            guard !unchecked.isEmpty || !unfinished.isEmpty else { return "\(none) in this window." }
            let gaps = [unchecked.isEmpty ? nil : "\(unchecked.joined(separator: ", ")) could not be checked",
                        unfinished.isEmpty ? nil : "\(unfinished.joined(separator: ", ")) \(unfinished.count == 1 ? "was" : "were") read only in part"]
            return "\(none) in the reports that could be read; " + gaps.compactMap { $0 }.joined(separator: ", and ") + "."
        }

        /// The reads kept only in part, by name, with why, for a structured result.
        var partlyRead: [String: String] { Dictionary(partial, uniquingKeysWith: { "\($0); \($1)" }) }

        /// What reads after these found, added to it, newest first, with no event taken twice.
        mutating func add(_ later: Gathered) {
            var seen = Set(events.map(\.id))
            events += later.events.filter { seen.insert($0.id).inserted }
            events.sort { ($0.time ?? "") > ($1.time ?? "") }
            searched += later.searched.filter { !searched.contains($0) }
            cut += later.cut; partial += later.partial; failed += later.failed; skipped += later.skipped; passing += later.passing
        }
    }

    /// `pages` is the most pages each read takes.
    static func gather(_ service: ServiceClient, _ reads: [(label: String, application: String, user: String, event: String?, query: [String: String?])],
                       limit: Int, pages: Int = mostPages) async -> Gathered {
        // One after another: a release build freed what the reads captured when they ran in a task group, and Pion
        // crashed at launch. The connection's requests are paced anyway, so little is lost.
        var results: [(String, Result<EventPage, Error>)] = []
        for read in reads {
            do { results.append((read.label, .success(try await events(service, application: read.application, user: read.user, event: read.event,
                                                                         query: read.query, limit: limit, pages: pages)))) }
            catch { results.append((read.label, .failure(error))) }
        }
        var gathered = Gathered(), seen = Set<String>()
        for (label, result) in results.sorted(by: { $0.0 < $1.0 }) {
            switch result {
            case .success(let page):
                if !gathered.searched.contains(label) { gathered.searched.append(label) }
                if let failure = page.failure {
                    gathered.partial.append((label, "a later page could not be read: \(failure.localizedDescription)"))
                    if isPassing(failure) { gathered.passing.append(label) }
                } else if page.more { gathered.cut.append(label) }
                for event in page.events where seen.insert(event.id).inserted { gathered.events.append(event) }
            case .failure(let error):
                gathered.failed.append((label, error.localizedDescription))
                if isPassing(error) { gathered.passing.append(label) }
            }
        }
        gathered.events.sort { ($0.time ?? "") > ($1.time ?? "") }
        return gathered
    }

    /// Whether a read failed for a reason that passes, such as Google being busy, a rate limit or the network, rather
    /// than one that will keep failing, such as a report the edition or the role lacks.
    static func isPassing(_ error: Error) -> Bool {
        switch error {
        case ServiceError.rateLimited, ServiceError.unreadable: true
        case ServiceError.status(let status, _): status >= 500 || status == 408
        case is URLError: true
        default: false
        }
    }

    /// The tier each watched event takes its turn in when there are more events than are kept, by its report, or by
    /// application/event for one that differs from the rest of its report: sign-ins and accounts taken over, an
    /// admin's doing included, first; then admin and defence changes, with an admin resetting a password, which some
    /// organisations do every day; then exports, apps granted access and files made public; then devices; then rules, which fire far more
    /// often.
    static let watchedTiers: [String: Int] = [
        "login": 0, "user_accounts": 0, "admin": 1, "takeout": 2, "vault": 2, "token": 2, "drive": 2, "mobile": 3, "rules": 4,
        "admin/TURN_OFF_2_STEP_VERIFICATION": 0, "admin/CHANGE_RECOVERY_EMAIL": 0, "admin/ADD_RECOVERY_EMAIL": 0, "admin/CHANGE_RECOVERY_PHONE": 0,
        "admin/ADD_RECOVERY_PHONE": 0, "admin/SECURITY_KEY_REGISTERED_FOR_USER": 0, "admin/REVOKE_SECURITY_KEY": 0,
        "admin/UNENROLL_USER_FROM_TITANIUM": 0, "admin/UNENROLL_USER_FROM_STRONG_AUTH": 0, "admin/UNBLOCK_USER_SESSION": 0,
        "admin/GENERATE_2SV_SCRATCH_CODES": 0, "admin/CREATE_EMAIL_MONITOR": 0, "admin/MAIL_ROUTING_DESTINATION_ADDED": 0,
        "admin/REQUEST_MAILBOX_DUMP": 0, "admin/CREATE_DATA_TRANSFER_REQUEST": 2,
    ]

    /// The tier `event` takes its turn in; one not watched comes last.
    static func tier(_ event: Event) -> Int {
        watchedTiers["\(event.application)/\(event.event)"] ?? watchedTiers[event.application] ?? watchedTiers.count
    }

    /// At most `most` of `events`, newest first, taken in turn from each watched event, so a burst of one, such as a rule
    /// firing hundreds of times, cannot crowd out a suspicious sign-in.
    static func inTurn(_ events: [Event], most: Int) -> [Event] {
        guard events.count > most, most > 0 else { return Array(events.prefix(max(most, 0))) }
        var queues = Dictionary(grouping: events) { "\($0.application)/\($0.event)" }
            .sorted { (tier($0.value[0]), $0.key) < (tier($1.value[0]), $1.key) }.map { $0.value[...] }
        var kept: [Event] = []
        while kept.count < most {
            for index in queues.indices where kept.count < most {
                if let event = queues[index].popFirst() { kept.append(event) }
            }
        }
        return kept.sorted { ($0.time ?? "") > ($1.time ?? "") }
    }

    /// The watched events from `since` to `until`, newest first, up to `limit` of each, leaving out those a watched
    /// event's exception names. The exceptions are applied here, once every report is read, rather than handed to the
    /// reads: a release build freed what such a filter captured while the reads still ran, and Pion crashed at launch.
    ///
    /// The reports in `readWhole` are read once each, and the apps granted access are read further than `limit`, as
    /// most of what they hold is left out here; a report read whole that had more than `mostRead` is then read event by
    /// event as well, and only those reads can be cut short.
    static func securityEvents(_ service: ServiceClient, since: String, until: String?, limit: Int) async -> Gathered {
        let window: [String: String?] = ["startTime": since, "endTime": until]
        let byName = { (watch: (application: String, event: String, unless: (parameter: String, value: String)?)) in
            let label = "\(watch.application)/\(watch.event)"
            return (label: label, application: watch.application, user: "all", event: Optional(watch.event),
                    query: window.merging(["filters": watchedFilters[label]]) { $1 })
        }
        let whole = readWhole.filter { report in watched.contains { $0.application == report } }.sorted()
        let further = watched.filter { watchedRisk["\($0.application)/\($0.event)"] != nil && !readWhole.contains($0.application) }
        var gathered = await gather(service, whole.map { (label: $0, application: $0, user: "all", event: nil, query: window) } + further.map(byName),
                                    limit: mostRead)
        let busy = Set(gathered.cut.filter { readWhole.contains($0) })
        gathered.cut.removeAll { busy.contains($0) }
        let rest = watched.filter { watch in
            busy.contains(watch.application) || (!readWhole.contains(watch.application) && !further.contains { $0.application == watch.application && $0.event == watch.event })
        }
        gathered.add(await gather(service, rest.map(byName), limit: limit))
        // A watched event kept here only in part that had more than was read is read on, each time up to the oldest of
        // it read so far, until the window's start or the check's `readOnPages` are spent, the first such event first;
        // one still cut short stays so, and the watch says so. Each read is counted at the most pages it may take.
        // Google's end of a window may take in its last moment, so that event can come again, and is taken once. A read
        // that finds nothing older, as when more events than a read takes share one moment, ends it.
        var pagesLeft = readOnPages
        for label in gathered.cut.filter(keptInPart).sorted() {
            guard let watch = watched.first(where: { "\($0.application)/\($0.event)" == label }) else { continue }
            while pagesLeft > 0 {
                let ofIt = gathered.events.filter { "\($0.application)/\($0.event)" == label }
                guard let oldest = ofIt.compactMap(\.time).min() else { break }
                var slice = byName(watch)
                slice.query["endTime"] = oldest
                let pages = min(pagesLeft, (mostRead + 999) / 1000)
                pagesLeft -= pages
                let earlier = await gather(service, [slice], limit: mostRead, pages: pages)
                let known = gathered.events.count
                gathered.cut.removeAll { $0 == label }
                gathered.add(earlier)
                if !gathered.cut.contains(label) || gathered.events.count == known { break }
            }
        }
        let labels = Set(watched.map { "\($0.application)/\($0.event)" })
        let unless = Dictionary(watched.map { ("\($0.application)/\($0.event)", $0.unless) }, uniquingKeysWith: { first, _ in first })
        gathered.events.removeAll { event in
            let label = "\(event.application)/\(event.event)"
            // A report read whole keeps only its watched events.
            guard labels.contains(label) else { return true }
            // A filter Google did not apply is applied here, so an ordinary successful sign-in never wakes anyone.
            let filtered = watchedFilters[label].map { filter in
                let pair = filter.components(separatedBy: "==")
                return pair.count == 2 && event.parameters[pair[0]] != pair[1]
            } ?? false
            let other = watchedOnly[label].map { only in !only.values.contains(event.parameters[only.parameter] ?? "") } ?? false
            // A grant counts only for what its scopes let the app do; one whose scopes are not known counts.
            let harmless = watchedRisk[label].map { most in
                let scopes = (event.parameters["scope"] ?? "").components(separatedBy: ", ").filter { !$0.isEmpty }
                return !scopes.isEmpty && (risk(scopes)?.rank ?? Int.max) > most
            } ?? false
            return filtered || other || harmless || ((unless[label] ?? nil).map { event.parameters[$0.parameter] == $0.value } ?? false)
        }
        return gathered
    }

    /// One page of a Directory list, whichever list it is.
    struct DirectoryPage<Item: Decodable>: Decodable {
        let users: [Item]?, groups: [Item]?, members: [Item]?, items: [Item]?, mobiledevices: [Item]?, nextPageToken: String?
        var listed: [Item] { users ?? groups ?? members ?? items ?? mobiledevices ?? [] }
    }

    /// A Directory list read page after page up to `limit`, and whether there was more, so a large org's admins,
    /// members or users are not left out unsaid.
    static func listAll<Item: Decodable>(_ client: ServiceClient, _ path: [String], query: [String: String?], pageSize: Int = 500,
                                         limit: Int = 5000) async throws -> (items: [Item], more: Bool) {
        var query = query, items: [Item] = []
        for _ in 0..<100 {
            query["maxResults"] = String(min(pageSize, limit - items.count))
            let page = try await client.get(path, query: query, as: DirectoryPage<Item>.self)
            items += page.listed
            guard let next = page.nextPageToken, !next.isEmpty else { return (items, false) }
            if items.count >= limit { return (items, true) }
            query["pageToken"] = next
        }
        return (items, true)
    }

    /// What a list says when there was more of it than was read, so it is never taken for complete.
    static func incomplete(_ what: String) -> String {
        "This list is incomplete: there were more \(what) than were read."
    }

    /// The organisation's verified domains and domain aliases, read once by a call that flags addresses outside it; nil
    /// when they could not be read, as without the domains scope. One not yet verified is left out, as it is not proven
    /// to be the organisation's.
    static func organisationDomains(_ service: ServiceClient) async -> Set<String>? {
        struct Alias: Decodable { let domainAliasName: String; let verified: Bool? }
        struct Domain: Decodable { let domainName: String; let verified: Bool?; let domainAliases: [Alias]? }
        struct Listed: Decodable { let domains: [Domain]? }
        guard let listed = try? await service.at(host: "admin.googleapis.com").get(["admin", "directory", "v1", "customer", "my_customer", "domains"],
                                                                                   as: Listed.self),
              let domains = listed.domains, !domains.isEmpty else { return nil }
        let verified = domains.flatMap { domain in
            (domain.verified == true ? [domain.domainName] : []) + (domain.domainAliases ?? []).filter { $0.verified == true }.map(\.domainAliasName)
        }
        return Set(verified.map { $0.lowercased() })
    }

    /// Whether an address is outside the organisation: its domain is none of the organisation's, or, when those could
    /// not be read, none of `fallback`. Only the domain itself counts, never one above it, as a subdomain may be handed
    /// to someone else who runs its mail. Something without an @, such as an ID, is never flagged.
    static func isOutside(_ address: String, domains: Set<String>?, fallback: Set<String>) -> Bool {
        guard address.contains("@"), let domain = address.split(separator: "@").last.map({ $0.lowercased() }) else { return false }
        return !(domains ?? fallback).contains(domain)
    }

    /// What a result adds when it flagged someone outside while the organisation's domains could not be read.
    static func domainsUnread(_ inside: String) -> String {
        "The organisation's domains could not be read, so these flags compare with \(inside) only, not with the organisation's "
            + "verified domains and aliases: an address flagged outside may be in another of them. check-access says what the domains need."
    }

    /// A user for an audit report: their email, or the numeric profile ID that a deleted account is still found by.
    static func reportUser(_ value: String) throws -> String {
        let value = value.trimmingCharacters(in: .whitespacesAndNewlines)
        if !value.isEmpty, value.count <= 30, value.allSatisfy(\.isNumber) { return value }
        return try ServiceInput.email(value)
    }
}

extension GoogleWorkspace {
    struct Activity: ServiceOperation {
        struct Input: Decodable, Sendable {
            let application: String, user: String?, eventName: String?, ip: String?, filters: String?, since: String?, until: String?, limit: Int?
        }
        static let name = "activity"
        static let jobs: Set<ToolJob> = [.detection]
        static let summary = "Audit events of one report, newest first, by user, event name, IP address, an event's details and time, with each event's details and where its address is."
        static let input = JSONSchema.object([
            "application": .string("Which report.", oneOf: GoogleWorkspace.applications),
            "user": .string("The user's email, or the profile ID of a deleted account from users. Everyone when left out."),
            "eventName": .string("An event, such as login_failure, suspicious_login, authorize or download."),
            "ip": .string("Only events from this IP address."),
            "filters": .string("Only events whose details match, as Google takes them: name==value, comma-separated, such as doc_id==1AbC, client_id==123 or target_user==someone@example.com. Each must belong to the event named in eventName or every event of the report."),
            "since": .string("The earliest time, in ISO 8601. The last 7 days when left out."),
            "until": .string("The latest time, in ISO 8601. For Gmail, at most 30 days after since."),
            "limit": .integer("How many events, at most.", minimum: 1, maximum: 5000),
        ], required: ["application"])

        func run(_ input: Input, on service: ServiceClient) async throws -> ServiceResult {
            let application = try ServiceInput.oneOf(input.application, GoogleWorkspace.applications, "application")
            let user = try input.user.map(GoogleWorkspace.reportUser) ?? "all"
            let limit = input.limit ?? 500
            guard (1...5000).contains(limit) else { throw ServiceError.input("Ask for between 1 and 5000 events.") }
            var query: [String: String?] = ["startTime": try input.since.map(ServiceInput.time) ?? ServiceInput.daysAgo(7)]
            if let until = input.until { query["endTime"] = try ServiceInput.time(until) }
            if let event = input.eventName { query["eventName"] = try ServiceInput.quoted(event, "the event name") }
            if let ip = input.ip { query["actorIpAddress"] = try ServiceInput.ip(ip) }
            if let filters = input.filters?.trimmingCharacters(in: .whitespacesAndNewlines), !filters.isEmpty {
                guard filters.count <= 500, !filters.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains) else {
                    throw ServiceError.input("Give filters as name==value pairs separated by commas, briefly.")
                }
                query["filters"] = filters
            }
            let page = try await GoogleWorkspace.events(service, application: application, user: user, query: query, limit: limit)
            var text = page.events.isEmpty ? (page.failure == nil ? "No \(application) events match." : "No \(application) events match in what could be read.")
                : page.events.prefix(50).map(\.line).joined(separator: "\n")
            if page.events.count > 50 { text += "\n\(page.events.count - 50) more in the structured result." }
            if let stopped = page.stopped { text += "\n" + stopped }
            else if page.more { text += "\nThere are more events than the \(limit) read; narrow the window or raise limit." }
            struct Events: Encodable { let events: [Event]; let more: Bool; let partlyRead: String? }
            return try ServiceResult(text: text, structured: Events(events: page.events, more: page.more, partlyRead: page.failure?.localizedDescription))
        }
    }

    struct SecurityEvents: ServiceOperation {
        struct Input: Decodable, Sendable { let since: String?, until: String? }
        static let name = "security-events"
        static let jobs: Set<ToolJob> = [.detection]
        static let summary = "The audit events that mean an attack or a takeover, newest first: suspicious and blocked sign-ins, accounts Google disabled, government-backed attack warnings, admin privileges, SSO and 2-step verification changes, recovery changes, mail forwarded out or monitored, an admin taking over an account, domain mail rules, defences loosened, Takeout and Vault exports, retention changes, data transfers, apps granted access to mail, files or the domain, files made public or open to anyone with the link, compromised devices, harmful apps and rules that fired above low."
        static let input = JSONSchema.object([
            "since": .string("The earliest time, in ISO 8601. The last 24 hours when left out."),
            "until": .string("The latest time, in ISO 8601."),
        ])

        func run(_ input: Input, on service: ServiceClient) async throws -> ServiceResult {
            let since = try input.since.map(ServiceInput.time) ?? ServiceInput.daysAgo(1)
            let gathered = await GoogleWorkspace.securityEvents(service, since: since, until: try input.until.map(ServiceInput.time), limit: 500)
            if gathered.searched.isEmpty, let first = gathered.failed.first { throw ServiceError.input(first.1) }
            // The first 80 taken in turn from each event, so a burst of one does not hide the rest.
            var text = gathered.events.isEmpty ? gathered.nothing("No security events")
                : GoogleWorkspace.inTurn(gathered.events, most: 80).map { "\($0.application) \($0.line)" }.joined(separator: "\n")
            if gathered.events.count > 80 { text += "\n\(gathered.events.count - 80) more in the structured result." }
            if !gathered.cut.isEmpty || !gathered.failed.isEmpty || !gathered.partial.isEmpty { text += "\n" + gathered.coverage }
            struct Kept: Encodable { let events: [Event]; let cutShort: [String]; let partlyRead: [String: String]; let couldNotRead: [String] }
            return try ServiceResult(text: text, structured: Kept(events: gathered.events, cutShort: gathered.cut, partlyRead: gathered.partlyRead,
                                                                  couldNotRead: gathered.failed.map(\.0)))
        }
    }

    /// Each watched event from `since` on. Google lists some audit events minutes to hours after their time. What one
    /// report found is kept when another is refused; only when none can be read is the check a failure.
    ///
    /// A report that cannot be read is never dropped unsaid: it is told as an alert of its own, which wakes the agents to
    /// read security-events, whose result names it and why. It is told once for each time the report stops answering,
    /// and again after a relaunch, and it is dated at the start of the window read, so it never moves the watch past
    /// events not yet read. A watched event kept only in part, such as the apps granted access, that had more than the
    /// watch could read even reading on is told the same way, as what it left unchecked may hold the one that counts.
    struct NewSecurityEvents: ServiceTrigger {
        var tool: String { SecurityEvents.name }
        /// Google lists the watched events within minutes, and says a few come later than its usual times
        /// (https://knowledge.workspace.google.com/admin/reports/data-retention-and-lag-times), so six hours back.
        var lookBack: TimeInterval { 6 * 3_600 }
        /// How many checks in a row a report failing for a passing reason holds the watch back, half an hour at the
        /// watch's pace, before it is told as unreadable instead. Telling it loses little: each check still reads six
        /// hours back, so a report that answers again within hours is read from before it failed.
        static let holdChecks = 6

        /// What the checks of one account keep between them while Pion runs: how many checks in a row each watched
        /// event's read has failed for a passing reason, and the reports already told as unreadable, and the watched
        /// events told as read only in part under more/ and their name, by the ID they were told with, forgotten once
        /// they are read in full again. It is not saved, so after a relaunch a report still
        /// unreadable is told once more, and one failing for now holds the watch back afresh.
        struct Kept: Sendable { var inARow: [String: Int] = [:]; var told: [String: String] = [:] }
        static let kept = Mutex<[UUID: Kept]>([:])

        func check(since: Date, on service: ServiceClient) async throws -> [ServiceAlert] {
            try await alerts(since: since, on: service, account: nil)
        }

        func check(since: Date, on service: ServiceClient, account: UUID) async throws -> [ServiceAlert] {
            try await alerts(since: since, on: service, account: account)
        }

        /// A check of `account`, when known; without one, a report failing for a passing reason holds the watch back
        /// at every check, and one that cannot be read is told at every check.
        func alerts(since: Date, on service: ServiceClient, account: UUID?) async throws -> [ServiceAlert] {
            let gathered = await GoogleWorkspace.securityEvents(service, since: ISO8601DateFormatter().string(from: since), until: nil, limit: ServiceAlert.most)
            if gathered.searched.isEmpty, let first = gathered.failed.first { throw ServiceError.input(first.1) }
            let passing = Set(gathered.passing)
            var reports = Set<String>()
            let unreadable = (gathered.failed + gathered.partial).map { String($0.0.prefix { $0 != "/" }) }.filter { reports.insert($0).inserted }
            // What to tell, by what it is kept under: each report that cannot be read, and each watched event kept only
            // in part that was still cut short.
            let notices = unreadable.map { ($0, "unreadable/\($0)") }
                + gathered.cut.filter(GoogleWorkspace.keptInPart).sorted().map { ("more/\($0)", "unchecked/\($0)") }
            let current = Set(notices.map(\.0))
            // Kept up to date before any hold, so a report that answered on a held check has its outage forgotten and
            // a later one is told afresh.
            var inARow: [String: Int] = [:]
            if let account {
                inARow = Self.kept.withLock { kept in
                    var watched = kept[account] ?? Kept()
                    watched.inARow = watched.inARow.filter { passing.contains($0.key) }
                    for label in passing { watched.inARow[label, default: 0] += 1 }
                    watched.told = watched.told.filter { current.contains($0.key) }
                    kept[account] = watched.inARow.isEmpty && watched.told.isEmpty ? nil : watched
                    return watched.inARow
                }
            }
            // A report that could not be read for now fails the whole check, so the watch stays where it is and the
            // next check reads the same window again, rather than moving past what that report would have found.
            let held = passing.filter { (inARow[$0] ?? 1) <= Self.holdChecks }.sorted()
            if !held.isEmpty {
                throw ServiceError.input("Could not read \(held.joined(separator: ", ")) for now; the next check reads the same window again.")
            }
            // The rest, refused for good or failing for too long, is told once per report, marked told only on the check
            // that returns it: a new ID each time it stops answering, so a second outage is told even while the first is
            // still among those seen.
            var tell = notices
            if let account {
                tell = Self.kept.withLock { kept in
                    var watched = kept[account] ?? Kept()
                    let new = notices.filter { watched.told[$0.0] == nil }.map { ($0.0, "\($0.1)/\(UUID().uuidString)") }
                    for (report, id) in new { watched.told[report] = id }
                    kept[account] = watched.inARow.isEmpty && watched.told.isEmpty ? nil : watched
                    return new
                }
            }
            // Dated at the window's start, which is never after the newest event seen, so it moves nothing on.
            let told = tell.map { ServiceAlert(id: $0.1, time: since) }
            return told + GoogleWorkspace.inTurn(gathered.events, most: ServiceAlert.most - told.count).compactMap { event in
                ServiceAlert.time(event.time).map { ServiceAlert(id: event.id, time: $0) }
            }
        }
    }
}

// MARK: - Containment

extension GoogleWorkspace {
    struct UserInput: Decodable, Sendable { let user: String }
    static let userSchema = JSONSchema.object(["user": .string("The user's primary email address.")], required: ["user"])

    /// A Directory API request about one user, with Google's refusal said as what to change. User Security Management
    /// never covers admins, so it is refused for them whatever the role holds.
    static func directory<Answer>(_ user: String, _ path: [String] = [], need: Need = .security,
                                  _ request: ([String]) async throws -> Answer) async throws -> Answer {
        let path = ["admin", "directory", "v1", "users", try ServiceInput.email(user)] + path
        return try await read(need) { try await request(path) }
    }

    struct UserState: ServiceOperation {
        typealias Input = UserInput
        static let name = "user"
        static let jobs: Set<ToolJob> = [.containment]
        static let summary = "Whether a user is suspended, an admin or enrolled in 2-step verification, their organisational unit and last sign-in."
        static let input = userSchema

        func run(_ input: UserInput, on service: ServiceClient) async throws -> ServiceResult {
            struct Name: Codable { let fullName: String? }
            struct User: Codable {
                let primaryEmail: String?, name: Name?, suspended: Bool?, suspensionReason: String?, isAdmin: Bool?, isDelegatedAdmin: Bool?
                let isEnrolledIn2Sv: Bool?, lastLoginTime: String?, orgUnitPath: String?
            }
            let user = try await directory(input.user, need: .containmentUsers) { try await service.get($0, as: User.self) }
            var parts = [user.suspended == true ? "suspended" + (user.suspensionReason.map { " (\($0))" } ?? "") : "active"]
            if user.isAdmin == true { parts.append("super admin") } else if user.isDelegatedAdmin == true { parts.append("delegated admin") }
            parts.append(user.isEnrolledIn2Sv == true ? "2-step verification on" : "2-step verification off")
            if let unit = user.orgUnitPath { parts.append("in \(unit)") }
            // Google gives the epoch for an account that never signed in.
            if let last = user.lastLoginTime, !last.hasPrefix("1970") { parts.append("last signed in \(last)") }
            let who = [user.name?.fullName, user.primaryEmail.map { "<\($0)>" }].compactMap { $0 }.joined(separator: " ")
            return try ServiceResult(text: "\(who.isEmpty ? input.user : who): \(parts.joined(separator: ", ")).", structured: user)
        }
    }

    struct Tokens: ServiceOperation {
        typealias Input = UserInput
        static let name = "tokens"
        static let jobs: Set<ToolJob> = [.audit, .containment]
        static let summary = "The apps a user has granted access to their account, with each app's client ID and scopes."
        static let input = userSchema

        func run(_ input: UserInput, on service: ServiceClient) async throws -> ServiceResult {
            struct Token: Codable { let clientId: String?, displayText: String?, scopes: [String]?, nativeApp: Bool? }
            struct Answer: Codable { let items: [Token]? }
            let tokens = try await directory(input.user, ["tokens"]) { try await service.get($0, as: Answer.self) }.items ?? []
            let text = tokens.isEmpty ? "\(input.user) has granted no apps access." : tokens.map { token in
                "\(token.displayText ?? "An app") (\(token.clientId ?? "?")): \((token.scopes ?? []).joined(separator: ", "))"
            }.joined(separator: "\n")
            struct Kept: Encodable { let tokens: [Token] }
            return try ServiceResult(text: text, structured: Kept(tokens: tokens))
        }
    }

    struct AppPasswords: ServiceOperation {
        typealias Input = UserInput
        static let name = "app-passwords"
        static let jobs: Set<ToolJob> = [.audit, .containment]
        static let summary = "A user's app passwords, which sign in without 2-step verification, with when each was made and last used."
        static let input = userSchema

        func run(_ input: UserInput, on service: ServiceClient) async throws -> ServiceResult {
            struct Password: Codable { let codeId: Int?, name: String?, creationTime: String?, lastTimeUsed: String? }
            struct Answer: Codable { let items: [Password]? }
            let passwords = try await directory(input.user, ["asps"]) { try await service.get($0, as: Answer.self) }.items ?? []
            func time(_ milliseconds: String?) -> String {
                guard let value = milliseconds.flatMap(Double.init), value > 0 else { return "never" }
                return ISO8601DateFormatter().string(from: Date(timeIntervalSince1970: value / 1000))
            }
            let text = passwords.isEmpty ? "\(input.user) has no app passwords." : passwords.map {
                "\($0.codeId.map(String.init) ?? "?"): \($0.name ?? "unnamed"), made \(time($0.creationTime)), last used \(time($0.lastTimeUsed))"
            }.joined(separator: "\n")
            struct Kept: Encodable { let appPasswords: [Password] }
            return try ServiceResult(text: text, structured: Kept(appPasswords: passwords))
        }
    }

    /// Ends every web and device session and resets sign-in cookies; app access and the password keep working.
    struct SignOut: ServiceOperation {
        typealias Input = UserInput
        static let name = "sign-out"
        static let jobs: Set<ToolJob> = [.containment]
        static let summary = "Sign a user out of every web and device session."
        static let input = userSchema
        static let readOnly = false
        static let destructive = true

        func run(_ input: UserInput, on service: ServiceClient) async throws -> ServiceResult {
            _ = try await directory(input.user, ["signOut"]) { try await service.data($0, method: "POST") }
            return try ServiceResult(text: "Signed \(input.user) out of every session.", structured: ["user": input.user])
        }
    }

    /// Ends the backup codes a user can sign in with in place of their second factor, which an attacker who held the
    /// account may have made or copied; Google makes new ones only when someone asks.
    struct InvalidateBackupCodes: ServiceOperation {
        typealias Input = UserInput
        static let name = "invalidate-backup-codes"
        static let jobs: Set<ToolJob> = [.containment]
        static let summary = "End a user's backup codes for 2-step verification, which an attacker may have made or copied."
        static let input = userSchema
        static let readOnly = false
        static let destructive = true

        func run(_ input: UserInput, on service: ServiceClient) async throws -> ServiceResult {
            _ = try await directory(input.user, ["verificationCodes", "invalidate"]) { try await service.data($0, method: "POST") }
            return try ServiceResult(text: "Ended \(input.user)'s backup codes.", structured: ["user": input.user])
        }
    }

    struct RevokeToken: ServiceOperation {
        struct Input: Decodable, Sendable { let user: String, clientId: String }
        static let name = "revoke-token"
        static let jobs: Set<ToolJob> = [.containment]
        static let summary = "Revoke every token a user granted one app, by its client ID from tokens."
        static let input = JSONSchema.object(["user": .string("The user's primary email address."),
                                              "clientId": .string("The app's client ID, as tokens lists it.")], required: ["user", "clientId"])
        static let readOnly = false
        static let destructive = true

        func run(_ input: Input, on service: ServiceClient) async throws -> ServiceResult {
            _ = try await directory(input.user, ["tokens", input.clientId]) { try await service.data($0, method: "DELETE") }
            return try ServiceResult(text: "Revoked \(input.clientId)'s access to \(input.user).", structured: ["user": input.user, "clientId": input.clientId])
        }
    }

    struct DeleteAppPassword: ServiceOperation {
        struct Input: Decodable, Sendable { let user: String, codeId: Int }
        static let name = "delete-app-password"
        static let jobs: Set<ToolJob> = [.containment]
        static let summary = "Delete one of a user's app passwords, by its ID from app-passwords."
        static let input = JSONSchema.object(["user": .string("The user's primary email address."),
                                              "codeId": .integer("The app password's ID, as app-passwords lists it.", minimum: 0)],
                                             required: ["user", "codeId"])
        static let readOnly = false
        static let destructive = true

        func run(_ input: Input, on service: ServiceClient) async throws -> ServiceResult {
            _ = try await directory(input.user, ["asps", String(input.codeId)]) { try await service.data($0, method: "DELETE") }
            return try ServiceResult(text: "Deleted app password \(input.codeId) of \(input.user).", structured: ["user": input.user])
        }
    }

    /// Suspending blocks sign-in and ends access; unsuspend undoes it, and is as serious, as it could let an attacker back in.
    struct Suspend: ServiceOperation {
        typealias Input = UserInput
        static let name = "suspend"
        static let jobs: Set<ToolJob> = [.containment]
        static let summary = "Suspend a user, so they cannot sign in until restored with unsuspend."
        static let input = userSchema
        static let readOnly = false
        static let destructive = true

        func run(_ input: UserInput, on service: ServiceClient) async throws -> ServiceResult {
            try await suspended(true, input.user, on: service)
            return try ServiceResult(text: "Suspended \(input.user). Restore them with unsuspend.", structured: ["user": input.user])
        }
    }

    struct Unsuspend: ServiceOperation {
        typealias Input = UserInput
        static let name = "unsuspend"
        static let jobs: Set<ToolJob> = [.containment]
        static let summary = "Restore a suspended user."
        static let input = userSchema
        static let readOnly = false
        static let destructive = true

        func run(_ input: UserInput, on service: ServiceClient) async throws -> ServiceResult {
            try await suspended(false, input.user, on: service)
            return try ServiceResult(text: "Restored \(input.user).", structured: ["user": input.user])
        }
    }

    /// Replaces a password an attacker may hold with a random one that nobody knows, set to be changed at the next
    /// sign-in. The password is made for the one request that sets it and kept nowhere: not in the result, the log or
    /// anything the agent sees. Sessions already open keep working, so the result recommends sign-out too.
    struct ResetPassword: ServiceOperation {
        typealias Input = UserInput
        static let name = "reset-password"
        static let jobs: Set<ToolJob> = [.containment]
        static let summary = "Replace a user's password with a random one nobody knows, to be changed at their next sign-in, so a stolen password stops working; an admin then sets them a new one."
        static let input = userSchema
        static let readOnly = false
        static let destructive = true

        func run(_ input: UserInput, on service: ServiceClient) async throws -> ServiceResult {
            let body = try JSONSerialization.data(withJSONObject: ["password": try GoogleWorkspace.randomPassword(), "changePasswordAtNextLogin": true])
            _ = try await directory(input.user, need: .resettingPassword) { try await service.data($0, method: "PATCH", body: body) }
            let text = "Replaced \(input.user)'s password with a random one that nobody knows, Pion included, to be changed at the next sign-in, "
                + "so a stolen password no longer works. \(input.user) cannot sign in until an admin sets them a new password in the Admin console "
                + "(https://admin.google.com/ac/users) or they recover the account through its recovery email or phone; check those first, "
                + "as an attacker who set them can recover it too. Sessions already open keep working: sign them out with sign-out as well."
            return try ServiceResult(text: text, structured: ["user": input.user, "passwordReplaced": "true", "changePasswordAtNextLogin": "true"])
        }
    }

    /// A password of 32 characters from the system's secure random generator, with a lower and an upper case letter, a
    /// digit and a symbol, so any password rule a domain sets takes it. Google takes 8 to 100 ASCII characters.
    static func randomPassword() throws -> String {
        let kinds = ["abcdefghijkmnopqrstuvwxyz", "ABCDEFGHJKLMNPQRSTUVWXYZ", "23456789", "!#$%&*+-=?@^_~"].map(Array.init)
        let characters = kinds.flatMap { $0 }
        // Only bytes below the largest multiple of the alphabet's size are used, so each character is as likely.
        let fair = UInt8(256 - 256 % characters.count)
        for _ in 0..<100 {
            var bytes = [UInt8](repeating: 0, count: 128)
            guard SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) == errSecSuccess else { break }
            let password = String(bytes.filter { $0 < fair }.prefix(32).map { characters[Int($0) % characters.count] })
            if password.count == 32, kinds.allSatisfy({ kind in password.contains(where: kind.contains) }) { return password }
        }
        throw ServiceError.input("A random password could not be made on this Mac; nothing was changed.")
    }

    /// Clears a recovery email or phone an attacker may have set to get back in, saying what it was first, as evidence.
    /// Google's update method clears a field set to null (https://developers.google.com/workspace/admin/directory/reference/rest/v1/users/update);
    /// its patch method says only that it cannot clear lists, so update is used.
    struct RemoveRecovery: ServiceOperation {
        struct Input: Decodable, Sendable { let user: String, email: Bool?, phone: Bool? }
        static let name = "remove-recovery"
        static let jobs: Set<ToolJob> = [.containment]
        static let summary = "Remove a user's recovery email, phone or both, which an attacker may have set to get back in, saying what they were."
        static let input = JSONSchema.object([
            "user": .string("The user's primary email address."),
            "email": .boolean("Remove the recovery email. Both are removed when neither is given."),
            "phone": .boolean("Remove the recovery phone. Both are removed when neither is given."),
        ], required: ["user"])
        static let readOnly = false
        static let destructive = true

        func run(_ input: Input, on service: ServiceClient) async throws -> ServiceResult {
            let both = input.email == nil && input.phone == nil
            let wanted = [("recoveryEmail", "recovery email", both || input.email == true), ("recoveryPhone", "recovery phone", both || input.phone == true)]
                .filter(\.2)
            guard !wanted.isEmpty else { throw ServiceError.input("Ask to remove the recovery email, the recovery phone or both.") }
            struct User: Decodable { let recoveryEmail: String?, recoveryPhone: String? }
            let user = try await directory(input.user, need: .containmentUsers) { try await service.get($0, as: User.self) }
            let before = ["recoveryEmail": user.recoveryEmail, "recoveryPhone": user.recoveryPhone].compactMapValues { $0?.isEmpty == false ? $0 : nil }
            let removing = wanted.filter { before[$0.0] != nil }
            guard !removing.isEmpty else {
                return try ServiceResult(text: "\(input.user) has no \(wanted.map(\.1).joined(separator: " or ")) to remove; nothing was changed.",
                                         structured: ["user": input.user])
            }
            let body = try JSONSerialization.data(withJSONObject: Dictionary(uniqueKeysWithValues: removing.map { ($0.0, NSNull()) }))
            _ = try await directory(input.user, need: .recovery) { try await service.data($0, method: "PUT", body: body) }
            let said = removing.map { "\($0.1) (was \(before[$0.0] ?? "?"))" }.joined(separator: " and ")
            var text = "Removed \(input.user)'s \(said). Record what they were as evidence: an attacker who set them could use them to recover the account. "
                + "The user can add their own again in their Google Account."
            if let left = wanted.first(where: { before[$0.0] == nil }) { text += " They had no \(left.1)." }
            struct Kept: Encodable { let user: String; let removed: [String: String] }
            return try ServiceResult(text: text, structured: Kept(user: input.user, removed: before.filter { key, _ in removing.contains { $0.0 == key } }))
        }
    }

    /// The phones and tablets that sync one user's account, with the resource ID each action on one takes.
    struct ContainmentDevices: ServiceOperation {
        typealias Input = UserInput
        static let name = "devices"
        static let jobs: Set<ToolJob> = [.containment]
        static let summary = "The phones and tablets that sync a user's account, with each one's resource ID for device-block, its model, OS, status and last sync."
        static let input = userSchema

        func run(_ input: UserInput, on service: ServiceClient) async throws -> ServiceResult {
            let user = try ServiceInput.email(input.user)
            let (devices, more) = try await GoogleWorkspace.mobileDevices(of: user, on: service, need: .containmentDevices)
            var text = devices.isEmpty ? "\(user) syncs no mobile devices." : devices.map { device in
                let profile = device.managedAccountIsOnOwnerProfile.map { $0 ? ", account on the main profile" : ", account in a work profile" } ?? ""
                return GoogleWorkspace.described(device) + profile + ", resource ID \(device.resourceId ?? "?")"
            }.joined(separator: "\n")
            if more { text += "\n" + GoogleWorkspace.incomplete("devices") }
            struct Listed: Encodable { let mobiledevices: [MobileDevice]; let incomplete: Bool }
            return try ServiceResult(text: text, structured: Listed(mobiledevices: devices, incomplete: more))
        }
    }

    /// Stops one device syncing the account until an admin unblocks it in the Admin console, with Google's block action
    /// (https://developers.google.com/workspace/admin/directory/reference/rest/v1/mobiledevices/action), only on a
    /// device that syncs that user's account, so an approval for one user never acts on another's phone. Google's
    /// account wipe is never sent: it resets company-owned and work-only Android phones and supervised iPhones to
    /// factory settings, personal data and all, and the Directory cannot say how a phone is owned, so only the
    /// champion, in the Admin console, decides one.
    struct DeviceBlock: ServiceOperation {
        struct Input: Decodable, Sendable { let user: String, resourceId: String }
        static let name = "device-block"
        static let jobs: Set<ToolJob> = [.containment]
        static let summary = "Block one of a user's phones or tablets from syncing their account, by its resource ID from devices, until an admin unblocks it."
        static let input = JSONSchema.object(["user": .string("The user's primary email address."),
                                              "resourceId": .string("The device's resource ID, as devices lists it.")], required: ["user", "resourceId"])
        static let readOnly = false
        static let destructive = true

        func run(_ input: Input, on service: ServiceClient) async throws -> ServiceResult {
            let user = try ServiceInput.email(input.user)
            let path = ["admin", "directory", "v1", "customer", "my_customer", "devices", "mobile", input.resourceId]
            let device = try await read(.containmentDevices) { try await service.get(path, as: MobileDevice.self) }
            guard (device.email ?? []).contains(where: { $0.lowercased() == user }) else {
                throw ServiceError.input("Device \(input.resourceId) does not sync \(user)'s account; nothing was changed. devices lists the ones that do.")
            }
            _ = try await read(.containmentDevices) {
                try await service.data(path + ["action"], method: "POST", body: try JSONEncoder().encode(["action": "block"]))
            }
            let text = "Blocked \(device.model ?? "the device") (resource ID \(input.resourceId)) from syncing \(input.user)'s account. "
                + "What it already holds stays on it. To remove that, recommend the champion wipe the account in the Admin console's devices page, "
                + "https://admin.google.com/ac/devices, after confirming how the device is owned and managed: Google resets company-owned and "
                + "work-only Android phones and supervised iPhones to factory settings, personal data and all. Undo the block by unblocking it there."
            return try ServiceResult(text: text, structured: ["user": input.user, "resourceId": input.resourceId, "action": "block"])
        }
    }

    static func suspended(_ suspended: Bool, _ user: String, on service: ServiceClient) async throws {
        _ = try await directory(user, need: .suspending) {
            try await service.data($0, method: "PATCH", body: try JSONEncoder().encode(["suspended": suspended]))
        }
    }
}

// MARK: - Who holds what

extension GoogleWorkspace {
    /// Who clicked links in mail, from Gmail's events of the types Google's Gmail event page gives for clicks: 15, a link
    /// in the message body, and 16, a link in an attachment preview
    /// (https://developers.google.com/workspace/admin/reports/v1/appendix/activity/gmail). The page does not say which
    /// detail holds the address clicked, so `link` is matched against every detail that looks like one, an address or a
    /// detail named for a URL or link, never a domain or Message-ID, which name the sender as often as the link; and
    /// `message` against every detail. When an event lists several links, Google has not said which was clicked, and the
    /// result says only that the click was in a message linking there.
    struct LinkClicks: ServiceOperation {
        struct Input: Decodable, Sendable { let link: String?, message: String?, user: String?, since: String?, until: String?, limit: Int? }
        static let name = "link-clicks"
        static let jobs: Set<ToolJob> = [.detection]
        static let summary = "Who clicked links in mail, newest first: in the body or in an attachment preview, by the link's address or domain, the message's subject or ID, or the user."
        static let input = JSONSchema.object([
            "link": .string("Only clicks on links containing this, such as a domain or a full address."),
            "message": .string("Only clicks in messages whose details contain this, such as the subject or the Message-ID."),
            "user": .string("Only this user's clicks: their email, or the profile ID of a deleted account."),
            "since": .string("The earliest time, in ISO 8601. The last 7 days when left out."),
            "until": .string("The latest time, in ISO 8601, at most 30 days after since. Now when left out."),
            "limit": .integer("How many clicks of each kind to read, at most.", minimum: 1, maximum: 5000),
        ])

        static let kinds = ["15", "16"]

        func run(_ input: Input, on service: ServiceClient) async throws -> ServiceResult {
            let user = try input.user.map(GoogleWorkspace.reportUser) ?? "all"
            let limit = input.limit ?? 2000
            guard (1...5000).contains(limit) else { throw ServiceError.input("Ask for between 1 and 5000 clicks.") }
            var query: [String: String?] = ["startTime": try input.since.map(ServiceInput.time) ?? ServiceInput.daysAgo(7)]
            if let until = input.until { query["endTime"] = try ServiceInput.time(until) }
            let wanted = [input.link, input.message].map { $0?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }
                .map { $0?.isEmpty == true ? nil : $0 }
            // One kind after another, through the paced connection, not in a task group: see gather.
            var clicks: [Event] = [], seen = Set<String>(), more = false, stopped: String?
            for kind in Self.kinds {
                var asked = query
                asked["filters"] = "event_info.mail_event_type==" + kind
                let page = try await GoogleWorkspace.read(.report("Gmail report")) {
                    try await GoogleWorkspace.events(service, application: "gmail", user: user, query: asked, limit: limit)
                }
                more = more || page.more
                stopped = stopped ?? page.stopped
                for event in page.events where seen.insert(event.id).inserted { clicks.append(event) }
            }
            /// The links an event lists: every value of a detail named for a URL or link, or that is an address.
            func links(_ event: Event) -> Set<String> {
                Set(event.parameters.flatMap { key, value in
                    value.components(separatedBy: " | ").filter { part in
                        part.contains("://") || key.lowercased().contains("url") || key.lowercased().contains("link")
                    }.map { $0.lowercased() }
                })
            }
            let read = clicks.count
            clicks = clicks.filter { event in
                let inMessage = wanted[1].map { text in event.parameters.values.contains { $0.lowercased().contains(text) } } ?? true
                let onLink = wanted[0].map { text in links(event).contains { $0.contains(text) } } ?? true
                return inMessage && onLink
            }.sorted { ($0.time ?? "") > ($1.time ?? "") }
            // A click is on the link asked for only when every link its event lists matches; otherwise Google has not
            // said which of them was clicked.
            let uncertain = Set(wanted[0].map { text in clicks.filter { !links($0).allSatisfy { $0.contains(text) } }.map(\.id) } ?? [])
            let certain = clicks.filter { !uncertain.contains($0.id) }
            let people = Array(Set(certain.compactMap(\.user))).sorted()
            let what = [wanted[0].map { "on links matching \($0)" }, wanted[1].map { "in messages matching \($0)" }].compactMap { $0 }
            var lines = ["\(certain.count) click\(certain.count == 1 ? "" : "s") \(what.isEmpty ? "on links in mail" : what.joined(separator: " "))"
                + (people.isEmpty ? "." : " by \(people.count) \(people.count == 1 ? "person" : "people"): \(people.joined(separator: ", "))")]
            if let text = wanted[0], !uncertain.isEmpty {
                let unsure = clicks.filter { uncertain.contains($0.id) }, who = Array(Set(unsure.compactMap(\.user))).sorted()
                lines.append("\(unsure.count) more click\(unsure.count == 1 ? " in a message that also links" : "s in messages that also link") to \(text), "
                    + "where Google's event lists several links and not which was clicked: \(who.joined(separator: ", "))")
            }
            if clicks.isEmpty && read > 0 { lines.append("\(read) clicks in the window matched nothing asked for; try the domain alone or the message's subject.") }
            lines += clicks.prefix(60).map { event in
                let shown = event.parameters.sorted { $0.key < $1.key }.filter { $0.key != "event_info.mail_event_type" }
                    .map { "\($0.key)=\($0.value.count > 300 ? String($0.value.prefix(300)) + "…" : $0.value)" }
                return "\(event.time ?? "?") \(event.user ?? "?") (\(event.parameters["event_info.mail_event_type"] ?? "?"))"
                    + (uncertain.contains(event.id) ? " (which link is not certain)" : "")
                    + (event.ip.map { " from \($0)" } ?? "") + ": " + shown.joined(separator: ", ")
            }
            if clicks.count > 60 { lines.append("\(clicks.count - 60) more in the structured result.") }
            if more {
                lines.insert("This result is incomplete: not every click in this window was read, so there may be more clicks and people than these; "
                             + "narrow the window, the user or the link.", at: 0)
            }
            if let stopped { lines.append(stopped) }
            lines.append("Google lists Gmail events minutes to hours late, and a link opened outside Gmail, such as copied into a browser, is not a click.")
            struct Kept: Encodable { let clicks: [Event]; let people: [String]; let notCertainWhichLink: [String]; let more: Bool }
            return try ServiceResult(text: lines.joined(separator: "\n"), structured: Kept(clicks: clicks, people: people,
                                                                                             notCertainWhichLink: uncertain.sorted(), more: more))
        }
    }

    /// The organisation's domains and aliases, as the Directory gives them: which is primary and which are not verified,
    /// since a domain added recently or left unverified may be how someone sends or receives as the organisation.
    struct Domains: ServiceOperation {
        struct Input: Decodable, Sendable {}
        static let name = "domains"
        static let jobs: Set<ToolJob> = [.audit]
        static let summary = "The organisation's domains and domain aliases: primary or secondary, verified or not, and when each was added."
        static let input = JSONSchema.object([:])

        /// A time the Directory gives as milliseconds since 1970, as a string or a number.
        struct Millis: Decodable {
            let date: Date?
            init(from decoder: Decoder) throws {
                let container = try decoder.singleValueContainer()
                let value = (try? container.decode(Double.self)) ?? (try? container.decode(String.self)).flatMap(Double.init)
                date = value.map { Date(timeIntervalSince1970: $0 / 1000) }
            }
        }

        func run(_ input: Input, on service: ServiceClient) async throws -> ServiceResult {
            struct Alias: Decodable { let domainAliasName: String; let parentDomainName: String?; let verified: Bool?; let creationTime: Millis? }
            struct Domain: Decodable {
                let domainName: String; let isPrimary: Bool?; let verified: Bool?; let creationTime: Millis?; let domainAliases: [Alias]?
            }
            struct Listed: Decodable { let domains: [Domain]? }
            let directory = try service.at(host: "admin.googleapis.com")
            let domains = try await GoogleWorkspace.read(.domains) {
                try await directory.get(["admin", "directory", "v1", "customer", "my_customer", "domains"], as: Listed.self).domains ?? []
            }
            struct Kept: Encodable { let name: String, kind: String, verified: Bool, added: String? }
            let day = { (millis: Millis?) in millis?.date.map { ISO8601DateFormatter().string(from: $0).prefix(10) }.map(String.init) }
            var kept: [Kept] = []
            for domain in domains.sorted(by: { ($0.isPrimary == true ? 0 : 1, $0.domainName) < ($1.isPrimary == true ? 0 : 1, $1.domainName) }) {
                kept.append(Kept(name: domain.domainName, kind: domain.isPrimary == true ? "primary" : "secondary", verified: domain.verified == true,
                                 added: day(domain.creationTime)))
                for alias in domain.domainAliases ?? [] {
                    kept.append(Kept(name: alias.domainAliasName, kind: "alias of \(alias.parentDomainName ?? domain.domainName)",
                                     verified: alias.verified == true, added: day(alias.creationTime)))
                }
            }
            let lines = ["\(kept.count) domain\(kept.count == 1 ? "" : "s") in the organisation:"] + kept.map {
                "\($0.name): \($0.kind), \($0.verified ? "verified" : "NOT verified")\($0.added.map { ", added " + $0 } ?? "")"
            }
            return try ServiceResult(text: lines.joined(separator: "\n"), structured: ["domains": kept])
        }
    }

    /// The super admins, then every admin role someone holds, with its privileges and its holders, from the Directory
    /// API's read-only scopes. A delegated admin is named by asking for them; a group holding a role is named, with
    /// its members, who hold the role through it. Google gives assignees as USER and GROUP
    /// (https://developers.google.com/workspace/admin/directory/reference/rest/v1/roleAssignments).
    struct AdminRoles: ServiceOperation {
        struct Input: Decodable, Sendable { let user: String? }
        static let name = "admin-roles"
        static let jobs: Set<ToolJob> = [.detection, .audit]
        static let summary = "The super admins, and every admin role with what it allows and who holds it, with groups' members, organisational units and conditions; or the roles one user holds, directly or through a group."
        static let input = JSONSchema.object([
            "user": .string("Only the roles this user holds, directly or through a group, by email. Every role when left out."),
        ])

        func run(_ input: Input, on service: ServiceClient) async throws -> ServiceResult {
            let directory = try service.at(host: "admin.googleapis.com")
            let base = ["admin", "directory", "v1"]
            struct User: Codable { let id: String; let primaryEmail: String?; let isEnrolledIn2Sv: Bool?; let suspended: Bool? }
            struct Users: Decodable { let users: [User]? }
            struct Privilege: Codable { let privilegeName: String }
            struct Role: Codable { let roleId: String; let roleName: String?; let isSuperAdminRole: Bool?; let rolePrivileges: [Privilege]? }
            struct Roles: Decodable { let items: [Role]? }
            struct Assignment: Codable {
                let roleId: String; let assignedTo: String; let assigneeType: String?; let scopeType: String?; let orgUnitId: String?; let condition: String?
                var group: Bool { assigneeType?.uppercased() == "GROUP" }
            }
            struct Group: Decodable { let email: String? }
            struct Member: Decodable { let email: String?; let id: String? }
            let user = try input.user.map(ServiceInput.email)
            var incomplete = false
            // One user's roles come from Google's indirect listing, which adds those held through a group.
            let superAdmins: [User] = user != nil ? [] : try await GoogleWorkspace.read(.users) {
                let listed: (items: [User], more: Bool) = try await GoogleWorkspace.listAll(directory, base + ["users"],
                                                                                            query: ["customer": "my_customer", "query": "isAdmin=true"])
                incomplete = incomplete || listed.more
                return listed.items
            }
            let (roles, assignments) = try await GoogleWorkspace.read(.adminRoles) { () async throws -> ([Role], [Assignment]) in
                let roles: (items: [Role], more: Bool) = try await GoogleWorkspace.listAll(directory, base + ["customer", "my_customer", "roles"],
                                                                                           query: [:], pageSize: 100)
                let assignments: (items: [Assignment], more: Bool) = try await GoogleWorkspace.listAll(
                    directory, base + ["customer", "my_customer", "roleassignments"],
                    query: user.map { ["userKey": $0, "includeIndirectRoleAssignments": "true"] } ?? [:], pageSize: 200)
                incomplete = incomplete || roles.more || assignments.more
                return (roles.items, assignments.items)
            }
            var names = Dictionary(superAdmins.map { ($0.id, $0.primaryEmail ?? $0.id) }, uniquingKeysWith: { first, _ in first })
            for id in Set(assignments.filter { !$0.group }.map(\.assignedTo)).subtracting(names.keys).sorted().prefix(500) {
                // A holder the users do not know is not a person's account: a service account given a role shows only
                // its ID, which is a way back in that no user's sign-in shows.
                do { names[id] = try await directory.get(base + ["users", id], as: User.self).primaryEmail ?? id }
                catch ServiceError.notFound { names[id] = "\(id) (not a user: possibly a service account, or a deleted user)" }
                catch { names[id] = "\(id) (could not be looked up)" }
            }
            let domains = assignments.contains(where: \.group) ? await GoogleWorkspace.organisationDomains(service) : nil
            var flaggedWithout = false
            // A group is named with its members, nested groups' included, as each of them holds the role.
            var groups: [String: String] = [:]
            for id in Set(assignments.filter(\.group).map(\.assignedTo)).sorted().prefix(100) {
                let email = (try? await directory.get(base + ["groups", id], as: Group.self).email) ?? id
                let domain = email.contains("@") ? email.split(separator: "@").last.map { String($0).lowercased() } : nil
                let listed: (items: [Member], more: Bool)? = try? await GoogleWorkspace.listAll(
                    directory, base + ["groups", id, "members"], query: ["includeDerivedMembership": "true"], pageSize: 200, limit: 200)
                let members = (listed?.items ?? []).map { member -> String in
                    let address = member.email ?? member.id ?? "?"
                    let outside = (domains != nil || domain != nil) && GoogleWorkspace.isOutside(address, domains: domains, fallback: Set([domain].compactMap { $0 }))
                    return address + (outside ? " (outside the domain)" : "")
                }
                if domains == nil, members.contains(where: { $0.hasSuffix(" (outside the domain)") }) { flaggedWithout = true }
                let shown = members.prefix(25).joined(separator: ", ") + (members.count > 25 ? " and \(members.count - 25) more" : "")
                    + (listed?.more == true ? " and more" : "")
                groups[id] = "group \(email)" + (listed == nil ? " (its members could not be read)" : members.isEmpty ? " (no members)" : " (members: \(shown))")
            }
            func holder(_ assignment: Assignment) -> String {
                var who = assignment.group ? groups[assignment.assignedTo] ?? "group \(assignment.assignedTo)" : names[assignment.assignedTo] ?? assignment.assignedTo
                if assignment.scopeType == "ORG_UNIT" { who += " (only in organisational unit \(assignment.orgUnitId ?? "unnamed"))" }
                if let condition = assignment.condition, !condition.isEmpty { who += " (only when \(condition))" }
                return who
            }
            struct Held: Encodable { let role: String; let superAdmin: Bool; let privileges: [String]; let holders: [String] }
            let held = roles.compactMap { role -> Held? in
                let holders = assignments.filter { $0.roleId == role.roleId }.map(holder)
                guard !holders.isEmpty, user != nil || role.isSuperAdminRole != true else { return nil }
                return Held(role: role.roleName ?? role.roleId, superAdmin: role.isSuperAdminRole == true,
                            privileges: (role.rolePrivileges ?? []).map(\.privilegeName), holders: holders)
            }
            let admins = superAdmins.map { user in
                (user.primaryEmail ?? user.id) + (user.isEnrolledIn2Sv == false ? " (2-step verification off)" : "") + (user.suspended == true ? " (suspended)" : "")
            }
            var lines = user.map { user in [held.isEmpty ? "\(user) holds no admin role." : "\(user)'s admin roles, directly or through a group:"] }
                ?? ["Super admins (\(admins.count)): " + (admins.isEmpty ? "none listed" : admins.joined(separator: ", "))]
            lines += held.map { role in
                let privileges = role.privileges.prefix(12).joined(separator: ", ") + (role.privileges.count > 12 ? " and \(role.privileges.count - 12) more" : "")
                return "\(role.role) (\(role.holders.count)): \(role.holders.joined(separator: "; ")); allows \(privileges.isEmpty ? "nothing listed" : privileges)"
            }
            if incomplete { lines.append(GoogleWorkspace.incomplete("admins, roles or assignments")) }
            if flaggedWithout { lines.append(GoogleWorkspace.domainsUnread("each group's own domain")) }
            struct Kept: Encodable { let superAdmins: [String]; let roles: [Held]; let incomplete: Bool }
            return try ServiceResult(text: lines.joined(separator: "\n"), structured: Kept(superAdmins: superAdmins.map { $0.primaryEmail ?? $0.id },
                                                                                             roles: held, incomplete: incomplete))
        }
    }
}

// MARK: - Breach scope

extension GoogleWorkspace {
    /// Accounts in the domain, by the Directory's own search, with what matters when one may be compromised.
    struct Users: ServiceOperation {
        struct Input: Decodable, Sendable { let query: String?, deleted: Bool?, limit: Int? }
        static let name = "users"
        static let jobs: Set<ToolJob> = [.detection, .audit]
        static let summary = "Accounts in the domain, optionally by search such as isEnrolledIn2Sv=false, isSuspended=true or orgUnitPath=/Finance, with admin, 2-step verification and its enforcement, recovery email and phone, aliases and last sign-in."
        static let input = JSONSchema.object([
            "query": .string("A Directory search, such as isEnrolledIn2Sv=false, isAdmin=true, isSuspended=false or email:m.okafor*. Everyone when left out."),
            "deleted": .boolean("List accounts deleted in the last 20 days instead, with the profile ID their audit history is read by."),
            "limit": .integer("How many accounts, at most.", minimum: 1, maximum: 10000),
        ])

        func run(_ input: Input, on service: ServiceClient) async throws -> ServiceResult {
            let limit = input.limit ?? 2000
            guard (1...10000).contains(limit) else { throw ServiceError.input("Ask for between 1 and 10000 accounts.") }
            struct User: Codable {
                let id: String?, primaryEmail: String?, isAdmin: Bool?, isDelegatedAdmin: Bool?, isEnrolledIn2Sv: Bool?, isEnforcedIn2Sv: Bool?, suspended: Bool?
                let lastLoginTime: String?, creationTime: String?, orgUnitPath: String?
                let recoveryEmail: String?, recoveryPhone: String?, aliases: [String]?, isGuestUser: Bool?, archived: Bool?
            }
            struct Listed: Codable { let users: [User]?; var incomplete: Bool? = nil }
            var query: [String: String?] = ["customer": "my_customer", "viewType": "admin_view"]
            if let search = input.query?.trimmingCharacters(in: .whitespacesAndNewlines), !search.isEmpty {
                guard search.count <= 500 else { throw ServiceError.input("Keep the search short.") }
                query["query"] = search
            }
            if input.deleted == true { query["showDeleted"] = "true" }
            let (users, more): ([User], Bool) = try await GoogleWorkspace.read(.users) {
                try await GoogleWorkspace.listAll(service.at(host: "admin.googleapis.com"), ["admin", "directory", "v1", "users"], query: query, limit: limit)
            }
            let organisation = users.contains { $0.recoveryEmail?.isEmpty == false } ? await GoogleWorkspace.organisationDomains(service) : nil
            var flaggedWithout = false
            var text = users.isEmpty ? (input.deleted == true ? "No accounts were deleted in the last 20 days." : "No accounts match.") : users.map { user in
                let twoStep = user.isEnrolledIn2Sv != true ? "2-step verification off" : user.isEnforcedIn2Sv == false ? "2-step verification not enforced" : nil
                var parts = [user.isAdmin == true ? "super admin" : user.isDelegatedAdmin == true ? "delegated admin" : nil, twoStep,
                             user.suspended == true ? "suspended" : nil, user.isGuestUser == true ? "guest" : nil, user.archived == true ? "archived" : nil]
                    .compactMap { $0 }
                if let unit = user.orgUnitPath { parts.append("in \(unit)") }
                // An attacker who takes an account over often points its recovery somewhere they control.
                let own = Set(([user.primaryEmail] + (user.aliases ?? []).map { $0 }).compactMap { $0?.split(separator: "@").last?.lowercased() })
                if let recovery = user.recoveryEmail, !recovery.isEmpty,
                   GoogleWorkspace.isOutside(recovery, domains: organisation.map { $0.union(own) }, fallback: own) {
                    parts.append("recovery email outside the domain: \(recovery)")
                    if organisation == nil { flaggedWithout = true }
                }
                if let phone = user.recoveryPhone, !phone.isEmpty { parts.append("recovery phone set") }
                if let aliases = user.aliases, !aliases.isEmpty { parts.append("aliases " + aliases.joined(separator: ", ")) }
                parts.append(user.lastLoginTime.map { $0.hasPrefix("1970") ? "never signed in" : "last signed in \($0)" } ?? "")
                if input.deleted == true, let id = user.id { parts.append("deleted; read its history with user \(id)") }
                return "\(user.primaryEmail ?? "?"): " + parts.filter { !$0.isEmpty }.joined(separator: ", ")
            }.joined(separator: "\n")
            if more { text += "\nThere are more accounts than the \(limit) read; narrow the search or raise limit." }
            if flaggedWithout { text += "\n" + GoogleWorkspace.domainsUnread("each account's own domains") }
            return try ServiceResult(text: text, structured: Listed(users: users, incomplete: more))
        }
    }

    /// The groups a user is in: what they reach through shared drives, mailing lists and access granted to groups.
    struct UserGroups: ServiceOperation {
        struct Input: Decodable, Sendable { let user: String }
        static let name = "user-groups"
        static let jobs: Set<ToolJob> = [.detection, .audit]
        static let summary = "The groups a user is a member of, and so the shared drives, lists and access granted to them."
        static let input = userSchema

        func run(_ input: Input, on service: ServiceClient) async throws -> ServiceResult {
            struct Group: Codable { let id: String?; let email: String?; let name: String?; let directMembersCount: String? }
            struct Listed: Encodable { let groups: [Group]; let incomplete: Bool }
            let user = try ServiceInput.email(input.user)
            let (groups, more): ([Group], Bool) = try await GoogleWorkspace.read(.groups) {
                try await GoogleWorkspace.listAll(service.at(host: "admin.googleapis.com"), ["admin", "directory", "v1", "groups"],
                                                  query: ["userKey": user], pageSize: 200)
            }
            var text = groups.isEmpty ? "\(user) is in no groups." : "\(user) is in: " + groups.map {
                "\($0.name ?? $0.email ?? "?") <\($0.email ?? "?")>" + ($0.directMembersCount.map { " (\($0) members)" } ?? "")
            }.joined(separator: ", ")
            if more { text += "\n" + GoogleWorkspace.incomplete("groups") }
            return try ServiceResult(text: text, structured: Listed(groups: groups, incomplete: more))
        }
    }

    /// The phones and tablets that sync a user's mail and files, which keep their data after a password change. Laptops,
    /// desktops and company-owned devices are in Cloud Identity, which takes only a service account, and are not listed;
    /// the mobile audit report's events cover laptops and desktops enrolled through endpoint verification.
    struct UserDevices: ServiceOperation {
        struct Input: Decodable, Sendable { let user: String }
        static let name = "user-devices"
        static let jobs: Set<ToolJob> = [.detection, .audit]
        static let summary = "The phones and tablets that sync a user's mail and files, with their model, OS, status, last sync and whether Google finds them compromised."
        static let input = userSchema

        func run(_ input: Input, on service: ServiceClient) async throws -> ServiceResult {
            struct Listed: Encodable { let mobiledevices: [MobileDevice]; let incomplete: Bool }
            let user = try ServiceInput.email(input.user)
            let (devices, more) = try await GoogleWorkspace.mobileDevices(of: user, on: service, need: .mobileDevices)
            var text = devices.isEmpty ? "\(user) syncs no mobile devices." : devices.map(GoogleWorkspace.described).joined(separator: "\n")
            if more { text += "\n" + GoogleWorkspace.incomplete("devices") }
            return try ServiceResult(text: text, structured: Listed(mobiledevices: devices, incomplete: more))
        }
    }

    /// Every phone and tablet that syncs an account in the domain, whose it is and when it last synced, longest unsynced
    /// first, so an assessment finds devices still allowed in long after anyone used them, such as a phone sold or lost
    /// but never removed. Google keeps a device approved however long it has not synced. Laptops and desktops are not
    /// listed, as for user-devices. Only the fields shown are asked for, as a device's full record lists its apps.
    struct AllDevices: ServiceOperation {
        struct Input: Decodable, Sendable { let owner: String?, inactiveDays: Int?, status: String?, limit: Int? }
        static let name = "all-devices"
        static let jobs: Set<ToolJob> = [.audit]
        static let summary = "Every phone and tablet in the domain, approved ones first and longest unsynced first, with whose it is, its model, OS, status, first and last sync, whether Google finds it compromised and its resource ID, and counts of those approved but not synced for months, blocked, pending and compromised; optionally only one owner's, one status or those not synced for some days."
        /// The states Google gives a device (https://developers.google.com/workspace/admin/directory/reference/rest/v1/mobiledevices).
        static let statuses = ["APPROVED", "PENDING", "BLOCKED", "UNPROVISIONED", "WIPING", "WIPED"]
        static let input = JSONSchema.object([
            "owner": .string("Only the devices that sync this account, by email. Everyone's when left out."),
            "inactiveDays": .integer("Only devices that have not synced for at least this many days, or never. Also how long an approved device goes unsynced before it is counted; 90 when left out.",
                                     minimum: 1, maximum: 3650),
            "status": .string("Only devices in this state.", oneOf: statuses),
            "limit": .integer("How many devices to list, at most; the counts cover every device that matched.", minimum: 1, maximum: 5000),
        ])
        static let fields = "nextPageToken,mobiledevices(resourceId,deviceId,email,model,os,type,status,firstSync,lastSync,deviceCompromisedStatus,"
            + "managedAccountIsOnOwnerProfile,supportsWorkProfile)"

        func run(_ input: Input, on service: ServiceClient) async throws -> ServiceResult {
            let limit = input.limit ?? 500
            guard (1...5000).contains(limit) else { throw ServiceError.input("Ask for between 1 and 5000 devices.") }
            let staleDays = input.inactiveDays ?? 90
            guard (1...3650).contains(staleDays) else { throw ServiceError.input("Ask for between 1 and 3650 days.") }
            let owner = try input.owner.map(ServiceInput.email)
            let status = input.status?.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
            if let status, !Self.statuses.contains(status) {
                throw ServiceError.input("A device's status is one of \(Self.statuses.joined(separator: ", ")).")
            }
            var query: [String: String?] = ["projection": "FULL", "fields": Self.fields]
            // The search matches addresses that start the same too, so only the owner's own are kept below.
            if let owner { query["query"] = "email:\(owner)" }
            let (read, more): ([MobileDevice], Bool) = try await GoogleWorkspace.read(.mobileDevices) {
                try await GoogleWorkspace.listAll(service.at(host: "admin.googleapis.com"),
                                                  ["admin", "directory", "v1", "customer", "my_customer", "devices", "mobile"],
                                                  query: query, pageSize: 100, limit: 10000)
            }
            // Days since each device last synced; nil for one that never did, which Google may give as 1970.
            let now = Date()
            let age = { (device: MobileDevice) -> Int? in
                guard let synced = ServiceAlert.time(device.lastSync), synced.timeIntervalSince1970 > 86400 else { return nil }
                return max(0, Int(now.timeIntervalSince(synced) / 86400))
            }
            let isStale = { (device: MobileDevice) in age(device).map { $0 >= staleDays } ?? true }
            // An approved device can still reach the accounts; one blocked, wiped or never provisioned cannot.
            let isApproved = { (device: MobileDevice) in device.status?.uppercased() == "APPROVED" }
            let pool = owner.map { owner in read.filter { ($0.email ?? []).contains { $0.lowercased() == owner } } } ?? read
            let matched = pool.filter { device in
                (status.map { device.status?.uppercased() == $0 } ?? true) && (input.inactiveDays == nil || isStale(device))
            }.sorted { a, b in
                if isApproved(a) != isApproved(b) { return isApproved(a) }
                let (x, y) = (age(a) ?? .max, age(b) ?? .max)
                return x != y ? x > y : (a.email?.first ?? "") < (b.email?.first ?? "")
            }
            let listed = Array(matched.prefix(limit))
            let unused = matched.filter { isApproved($0) && isStale($0) }
            let stale = unused.count, never = unused.filter { age($0) == nil }.count
            let blocked = matched.filter { $0.status?.uppercased() == "BLOCKED" }.count, pending = matched.filter { $0.status?.uppercased() == "PENDING" }.count
            let compromised = matched.filter { GoogleWorkspace.isCompromised($0) }.count

            let plural = { (count: Int, one: String, many: String) in "\(count) \(count == 1 ? one : many)" }
            let whose = owner.map { "syncing \($0)" } ?? "in the domain"
            let filters = [status.map { "status \($0)" }, input.inactiveDays.map { "not synced for \($0) days or more" }].compactMap { $0 }
            var lines: [String] = []
            if pool.isEmpty {
                lines.append(owner.map { "\($0) syncs no mobile devices." } ?? "No phones or tablets sync any account in the domain.")
            } else if filters.isEmpty {
                lines.append("\(plural(pool.count, "phone or tablet", "phones and tablets")) \(whose).")
            } else {
                lines.append("\(matched.count) of the \(plural(pool.count, "phone or tablet", "phones and tablets")) \(whose) match \(filters.joined(separator: " and ")).")
            }
            if !matched.isEmpty {
                lines.append("\(stale) approved but not synced for \(staleDays) days or more\(never > 0 ? " (\(never) never synced)" : ""), \(blocked) blocked, "
                             + "\(pending) pending, \(compromised) found compromised by Google.")
                lines.append("Approved first, then longest unsynced first: a device sold, lost or replaced stops syncing but stays approved until an admin removes it.")
            }
            for device in listed {
                let owners = (device.email ?? []).joined(separator: ", ")
                var parts = ["\(device.model ?? "A device") (\([device.os, device.type, device.status].compactMap { $0 }.joined(separator: ", ")))"]
                parts.append(age(device).map { "last synced \(device.lastSync ?? "?") (\(plural($0, "day", "days")) ago)" } ?? "never synced")
                if let first = device.firstSync, ServiceAlert.time(first).map({ $0.timeIntervalSince1970 > 86400 }) == true { parts.append("first synced \(first)") }
                if GoogleWorkspace.isCompromised(device) { parts.append(device.deviceCompromisedStatus ?? "compromised") }
                if let profile = device.managedAccountIsOnOwnerProfile { parts.append(profile ? "account on the main profile" : "account in a work profile") }
                parts.append("resource ID \(device.resourceId ?? "?")")
                lines.append("\(owners.isEmpty ? "No owner listed" : owners): " + parts.joined(separator: ", "))
            }
            if matched.count > listed.count {
                lines.append("\(matched.count - listed.count) more matched than are listed; narrow by owner, status or inactiveDays, or raise limit.")
            }
            if more { lines.append(GoogleWorkspace.incomplete("devices") + " The counts cover only those read.") }
            struct Kept: Encodable {
                let mobiledevices: [MobileDevice]; let matched: Int, total: Int, staleDays: Int, stale: Int, neverSynced: Int, blocked: Int, pending: Int
                let compromised: Int, incomplete: Bool
            }
            return try ServiceResult(text: lines.joined(separator: "\n"),
                                     structured: Kept(mobiledevices: listed, matched: matched.count, total: pool.count, staleDays: staleDays, stale: stale,
                                                      neverSynced: never, blocked: blocked, pending: pending, compromised: compromised, incomplete: more))
        }
    }

    /// Whether Google finds a device compromised, such as rooted or jailbroken. It says "No compromise detected" for
    /// one it checked and found clean; anything else it says is shown rather than hidden.
    static func isCompromised(_ device: MobileDevice) -> Bool {
        guard let said = device.deviceCompromisedStatus?.trimmingCharacters(in: .whitespaces), !said.isEmpty else { return false }
        return said.lowercased() != "no compromise detected"
    }

    /// A phone or tablet as the Directory lists it.
    struct MobileDevice: Codable, Sendable {
        let resourceId: String?, deviceId: String?, email: [String]?, model: String?, os: String?, type: String?, status: String?
        let firstSync: String?, lastSync: String?, deviceCompromisedStatus: String?
        /// Whether the account is on the device's main profile rather than a work profile, and whether it takes a work
        /// profile, for an admin weighing an account wipe in the Admin console; neither says who owns the device.
        var managedAccountIsOnOwnerProfile: Bool? = nil, supportsWorkProfile: Bool? = nil
    }

    /// The devices that sync `user`'s account. The search matches addresses that start the same too, so only this
    /// user's are kept.
    static func mobileDevices(of user: String, on service: ServiceClient, need: Need) async throws -> (devices: [MobileDevice], more: Bool) {
        let (listed, more): ([MobileDevice], Bool) = try await read(need) {
            try await listAll(service.at(host: "admin.googleapis.com"), ["admin", "directory", "v1", "customer", "my_customer", "devices", "mobile"],
                              query: ["query": "email:\(user)"], pageSize: 100)
        }
        return (listed.filter { ($0.email ?? []).contains { $0.lowercased() == user } }, more)
    }

    /// A device on one line: its model, OS, type, status, last sync and whether Google finds it compromised.
    static func described(_ device: MobileDevice) -> String {
        "\(device.model ?? "A device") (\([device.os, device.type, device.status].compactMap { $0 }.joined(separator: ", "))), last synced \(device.lastSync ?? "?")"
            + (isCompromised(device) ? ", \(device.deviceCompromisedStatus ?? "")" : "")
    }

    /// What one thing the tools read needs from the setup, to say exactly what to change when Google refuses it.
    struct Need: Sendable {
        let title: String, api: String, apiID: String, scope: String, privilege: String
        /// What to change when the admin's role is refused, where adding a privilege is not the answer.
        var forbidden: String? = nil

        static let reports = Need(title: "Audit reports", api: "Admin SDK API", apiID: "admin.googleapis.com",
                                  scope: "https://www.googleapis.com/auth/admin.reports.audit.readonly", privilege: "Reports")
        static func report(_ title: String) -> Need {
            Need(title: title, api: reports.api, apiID: reports.apiID, scope: reports.scope, privilege: reports.privilege)
        }
        static let users = Need(title: "Users", api: "Admin SDK API", apiID: "admin.googleapis.com",
                                scope: "https://www.googleapis.com/auth/admin.directory.user.readonly", privilege: "Users › Read")
        static let adminRoles = Need(title: "Admin roles", api: "Admin SDK API", apiID: "admin.googleapis.com",
                                     scope: "https://www.googleapis.com/auth/admin.directory.rolemanagement.readonly", privilege: "read access to admin roles")
        static let groups = Need(title: "Groups", api: "Admin SDK API", apiID: "admin.googleapis.com",
                                 scope: "https://www.googleapis.com/auth/admin.directory.group.readonly", privilege: "Groups › Read")
        static let mobileDevices = Need(title: "Mobile devices", api: "Admin SDK API", apiID: "admin.googleapis.com",
                                        scope: "https://www.googleapis.com/auth/admin.directory.device.mobile.readonly", privilege: "read access to devices")
        /// Google's Policy API overview says only a super admin can use it.
        static let policies = Need(title: "Organisation settings", api: "Cloud Identity API", apiID: "cloudidentity.googleapis.com",
                                   scope: "https://www.googleapis.com/auth/cloud-identity.policies.readonly", privilege: "super admin",
                                   forbidden: "Google lets only a super admin read the organisation's current settings, and the setup keeps this tool's admin from being one: "
                                       + "ask the champion for the Admin console pages for the settings that matter, and say what you could not check.")
        static let domains = Need(title: "Domains", api: "Admin SDK API", apiID: "admin.googleapis.com",
                                  scope: "https://www.googleapis.com/auth/admin.directory.domain.readonly", privilege: "read access to domains")
        static let containmentUsers = Need(title: "Users", api: "Admin SDK API", apiID: "admin.googleapis.com",
                                           scope: "https://www.googleapis.com/auth/admin.directory.user", privilege: "Users › Read")
        static let security = Need(title: "Sessions, apps and app passwords", api: "Admin SDK API", apiID: "admin.googleapis.com",
                                   scope: "https://www.googleapis.com/auth/admin.directory.user.security",
                                   privilege: "Security › User Security Management, which never covers admins,")
        static let suspending = Need(title: "Suspending", api: "Admin SDK API", apiID: "admin.googleapis.com",
                                     scope: "https://www.googleapis.com/auth/admin.directory.user", privilege: "Users › Update › Suspend users")
        /// Google's privilege definitions say only a super admin can change another admin's settings.
        static let resettingPassword = Need(title: "Resetting passwords", api: "Admin SDK API", apiID: "admin.googleapis.com",
                                            scope: "https://www.googleapis.com/auth/admin.directory.user",
                                            privilege: "Users › Update › Reset password and Force password change, which only a super admin has over another admin,")
        /// Google's recovery information page asks only for "the appropriate User management privilege"; none narrower is named.
        static let recovery = Need(title: "Recovery details", api: "Admin SDK API", apiID: "admin.googleapis.com",
                                   scope: "https://www.googleapis.com/auth/admin.directory.user",
                                   privilege: "Users › Update, as Google names no narrower privilege for recovery details,")
        static let containmentDevices = Need(title: "Mobile devices", api: "Admin SDK API", apiID: "admin.googleapis.com",
                                             scope: "https://www.googleapis.com/auth/admin.directory.device.mobile.action",
                                             privilege: "Services › Mobile Device Management")
    }

    /// What to change when Google refused something, from what it said: a scope the sign-in lacks, an API turned off in
    /// the project, a privilege the admin's role lacks, or a sign-in that expired; nil for any other failure.
    static func fix(for error: Error, _ need: Need) -> String? {
        let said: String
        switch error {
        case ServiceError.rejected: return "the sign-in expired or was revoked: sign the tool in again in Settings › Tools."
        case ServiceError.forbidden(let reason): said = reason ?? ""
        case ServiceError.refused(let reason): said = reason
        case ServiceError.status(_, let reason): said = reason ?? ""
        default: return nil
        }
        let lower = said.lowercased()
        if lower.contains("insufficient authentication scopes") || lower.contains("access_token_scope_insufficient") {
            return "the sign-in lacks the scope \(need.scope): add it under Google Auth Platform › Data Access if it is missing, then sign the tool in again in Settings › Tools."
        }
        if lower.contains("has not been used in project") || lower.contains("service_disabled") || lower.contains("it is disabled") {
            // Google names the page that turns it on, with the project.
            let link = said.range(of: #"https://\S+"#, options: .regularExpression).map { String(said[$0]).trimmingCharacters(in: CharacterSet(charactersIn: ".,)")) }
            return "the \(need.api) is turned off in the tool's Google Cloud project: enable it at \(link ?? "https://console.cloud.google.com/apis/library/" + need.apiID), then try again."
        }
        if case ServiceError.forbidden = error {
            if let forbidden = need.forbidden { return forbidden }
            return "the admin this tool signs in as may not do this: add \(need.privilege) to its role in the Admin console, or check the role is assigned to them."
        }
        return nil
    }

    /// A request, with Google's refusal said as what to change, so an agent can tell the champion.
    static func read<Value>(_ need: Need, _ body: () async throws -> Value) async throws -> Value {
        do { return try await body() } catch {
            guard let fix = fix(for: error, need) else { throw error }
            throw ServiceError.input("Google refused \(need.title.lowercased()): \(fix) Running check-access shows everything this tool can and cannot do.")
        }
    }

    /// Each thing a tool reads, tried once with the smallest request it takes, as a checklist of what works and what to
    /// change for what does not.
    static func check(_ probes: [(Need, () async throws -> Void)]) async -> [String] {
        var lines: [String] = []
        for (need, probe) in probes {
            do { try await probe(); lines.append("✓ \(need.title)") }
            catch { lines.append("✗ \(need.title): " + (fix(for: error, need) ?? error.localizedDescription)) }
        }
        return lines
    }

    /// Tries each thing Google Workspace Detection reads and says how to fix what it cannot.
    struct CheckAccess: ServiceOperation {
        struct Input: Decodable, Sendable {}
        static let name = "check-access"
        static let jobs: Set<ToolJob> = [.detection, .audit]
        static let summary = "Tries each thing this tool reads once and says what works and, for what does not, exactly what to change: a scope, an API or the admin's role. Run it when a tool is refused."
        static let input = JSONSchema.object([:])

        func run(_ input: Input, on service: ServiceClient) async throws -> ServiceResult {
            let admin = try service.at(host: "admin.googleapis.com"), identity = try service.at(host: "cloudidentity.googleapis.com")
            let directory = ["admin", "directory", "v1"]
            let lines = await GoogleWorkspace.check([
                (.reports, { _ = try await admin.data(["admin", "reports", "v1", "activity", "users", "all", "applications", "login"],
                                                      query: ["startTime": ServiceInput.daysAgo(1), "maxResults": "1"]) }),
                (.users, { _ = try await admin.data(directory + ["users"], query: ["customer": "my_customer", "maxResults": "1"]) }),
                (.adminRoles, { _ = try await admin.data(directory + ["customer", "my_customer", "roles"], query: ["maxResults": "1"]) }),
                (.groups, { _ = try await admin.data(directory + ["groups"], query: ["customer": "my_customer", "maxResults": "1"]) }),
                (.mobileDevices, { _ = try await admin.data(directory + ["customer", "my_customer", "devices", "mobile"], query: ["maxResults": "1"]) }),
                (.domains, { _ = try await admin.data(directory + ["customer", "my_customer", "domains"]) }),
                (.policies, { _ = try await identity.data(["v1", "policies"], query: ["pageSize": "1"]) }),
                // A working sign-in report does not prove the others: Gmail's needs a window, and some editions lack it.
                (Need.report("Takeout report"), { _ = try await admin.data(["admin", "reports", "v1", "activity", "users", "all", "applications", "takeout"],
                                                                       query: ["startTime": ServiceInput.daysAgo(1), "maxResults": "1"]) }),
                (Need.report("Gmail report"), { _ = try await admin.data(["admin", "reports", "v1", "activity", "users", "all", "applications", "gmail"],
                                                                     query: ["startTime": ServiceInput.daysAgo(1), "endTime": ServiceInput.daysAgo(0),
                                                                             "maxResults": "1"]) }),
            ])
            return try ServiceResult(text: lines.joined(separator: "\n"), structured: ["checks": lines])
        }
    }

    /// Tries what Google Workspace Containment can safely: reading users, one user's tokens and the mobile devices.
    /// Suspending, resetting a password, removing recovery details and acting on a device change something, so they are
    /// only described.
    struct ContainmentCheckAccess: ServiceOperation {
        struct Input: Decodable, Sendable {}
        static let name = "check-access"
        static let jobs: Set<ToolJob> = [.containment]
        static let summary = "Tries reading users, one non-admin's tokens and the mobile devices, and says what works and what to change for what does not; suspending, resetting passwords, removing recovery details and acting on devices are described, not tried. Run it when a tool is refused."
        static let input = JSONSchema.object([:])

        func run(_ input: Input, on service: ServiceClient) async throws -> ServiceResult {
            struct User: Decodable { let primaryEmail: String? }
            struct Users: Decodable { let users: [User]? }
            let found = FoundUser()
            var lines = await GoogleWorkspace.check([
                (.containmentUsers, {
                    // User Security Management never covers admins, so only a non-admin's tokens show whether it works.
                    found.email = try await service.get(["admin", "directory", "v1", "users"],
                                                        query: ["customer": "my_customer", "maxResults": "1", "query": "isAdmin=false isDelegatedAdmin=false"],
                                                        as: Users.self).users?.first?.primaryEmail
                }),
            ])
            if let email = found.email {
                lines += await GoogleWorkspace.check([(.security, { _ = try await service.data(["admin", "directory", "v1", "users", email, "tokens"]) })])
            } else {
                lines.append("· \(Need.security.title): not tried, as no account that is not an admin could be read.")
            }
            lines += await GoogleWorkspace.check([(.containmentDevices, {
                _ = try await service.data(["admin", "directory", "v1", "customer", "my_customer", "devices", "mobile"], query: ["maxResults": "1"])
            })])
            lines.append("· Suspending: can only be confirmed by suspending someone; the admin's role needs \(Need.suspending.privilege).")
            lines.append("· \(Need.resettingPassword.title): can only be confirmed by resetting one; the admin's role needs \(Need.resettingPassword.privilege.dropLast()).")
            lines.append("· \(Need.recovery.title): can only be confirmed by removing them; the admin's role needs \(Need.recovery.privilege.dropLast()).")
            lines.append("· Device actions: can only be confirmed by acting on a device; the admin's role needs \(Need.containmentDevices.privilege), "
                         + "and the sign-in the scope \(Need.containmentDevices.scope).")
            return try ServiceResult(text: lines.joined(separator: "\n"), structured: ["checks": lines])
        }

        private final class FoundUser: @unchecked Sendable { var email: String? }
    }
}

// MARK: - Investigation

extension GoogleWorkspace {
    /// What a set of OAuth scopes lets an app do, the most dangerous first, or nil for nothing that reads data or administers.
    static func risk(_ scopes: [String]) -> (rank: Int, said: String)? {
        let held = Set(scopes.flatMap { $0.split(separator: " ").map(String.init) })
        let documents = ["/auth/documents", "/auth/spreadsheets", "/auth/presentations"]
        let kinds: [(Int, String, (String) -> Bool)] = [
            (0, "administers the domain", { $0.contains("/auth/admin.") && !$0.hasSuffix(".readonly") }),
            (0, "administers groups, devices or single sign-on through Cloud Identity", { $0.contains("/auth/cloud-identity") && !$0.hasSuffix(".readonly") }),
            (0, "searches and exports anyone's mail and files through Vault", { $0.hasSuffix("/auth/ediscovery") }),
            (1, "reads and sends mail", { $0 == "https://mail.google.com/" || $0.hasSuffix("/gmail.modify") || $0.hasSuffix("/gmail.compose") }),
            (1, "reads mail", { $0.hasSuffix("/gmail.readonly") || $0.hasSuffix("/gmail.metadata") }),
            (1, "sends mail as the user", { $0.hasSuffix("/gmail.send") }),
            (1, "changes mail forwarding and who else may read the mail", { $0.hasSuffix("/gmail.settings.sharing") }),
            (1, "changes mail settings such as filters", { $0.hasSuffix("/gmail.settings.basic") }),
            (1, "puts messages into the mailbox", { $0.hasSuffix("/gmail.insert") }),
            (2, "reads and changes every file", { $0.hasSuffix("/auth/drive") }),
            (2, "reads every file", { $0.hasSuffix("/auth/drive.readonly") }),
            (2, "reads and changes documents, spreadsheets or presentations", { scope in documents.contains { scope.hasSuffix($0) } }),
            (2, "reads documents, spreadsheets or presentations", { scope in documents.contains { scope.hasSuffix($0 + ".readonly") } }),
            (2, "runs or changes Apps Script code as the user", { $0.contains("/auth/script.") }),
            (3, "full Google Cloud access", { $0.hasSuffix("/auth/cloud-platform") }),
            (3, "changes group settings, such as who may join or post", { $0.hasSuffix("/auth/apps.groups.settings") }),
            (4, "reads directory data", { $0.contains("/auth/admin.") || $0.contains("/auth/cloud-identity") || $0.hasSuffix("/auth/directory.readonly") }),
            (4, "reads Vault matters", { $0.hasSuffix("/auth/ediscovery.readonly") }),
            (5, "reads and changes calendars", { $0.hasSuffix("/auth/calendar") }),
            (5, "reads contacts", { $0.contains("/auth/contacts") }),
        ]
        let found = kinds.filter { kind in held.contains(where: kind.2) }
        guard let rank = found.map(\.0).min() else { return nil }
        return (rank, found.map(\.1).joined(separator: ", "))
    }

    /// Who is in a group, and so reads what it receives, with members outside the domain flagged.
    struct GroupMembers: ServiceOperation {
        struct Input: Decodable, Sendable { let group: String }
        static let name = "group-members"
        static let jobs: Set<ToolJob> = [.detection, .audit]
        static let summary = "Who is in a group, with their role, flagging members outside the domain."
        static let input = JSONSchema.object(["group": .string("The group's email address.")], required: ["group"])

        func run(_ input: Input, on service: ServiceClient) async throws -> ServiceResult {
            struct Member: Codable { let email: String?; let id: String?; let role: String?; let type: String?; let status: String? }
            struct Listed: Encodable { let members: [Member]; let incomplete: Bool }
            let group = try ServiceInput.email(input.group)
            let domain = group.split(separator: "@").last.map { String($0).lowercased() } ?? ""
            let domains = await GoogleWorkspace.organisationDomains(service)
            // Members of groups inside the group read what it receives too.
            let (members, more): ([Member], Bool) = try await GoogleWorkspace.read(.groups) {
                try await GoogleWorkspace.listAll(service.at(host: "admin.googleapis.com"), ["admin", "directory", "v1", "groups", group, "members"],
                                                  query: ["includeDerivedMembership": "true"], pageSize: 200)
            }
            var text = members.isEmpty ? "\(group) has no members." : "\(group) (\(members.count)): " + members.map { member in
                if member.type == "CUSTOMER" { return "everyone in the domain" }
                let email = member.email ?? member.id ?? "?"
                var notes: [String] = []
                if member.type == "GROUP" { notes.append("group") }
                if let role = member.role, role != "MEMBER" { notes.append(role.lowercased()) }
                if GoogleWorkspace.isOutside(email, domains: domains, fallback: [domain]) { notes.append("outside the domain") }
                return email + (notes.isEmpty ? "" : " (\(notes.joined(separator: ", ")))")
            }.joined(separator: ", ")
            if more { text += "\n" + GoogleWorkspace.incomplete("members") }
            if domains == nil, text.contains("outside the domain)") { text += "\n" + GoogleWorkspace.domainsUnread("the group's own domain, \(domain),") }
            return try ServiceResult(text: text, structured: Listed(members: members, incomplete: more))
        }
    }

    /// Every app people granted access to their accounts in a window, from the token audit log, which keeps six months:
    /// its client ID, name, type and scopes, who granted it and who revoked it. The access apps hold now is
    /// Containment's apps.
    struct OAuthApps: ServiceOperation {
        struct Input: Decodable, Sendable { let since: String?, until: String? }
        static let name = "oauth-apps"
        static let jobs: Set<ToolJob> = [.detection, .audit]
        static let summary = "Every app people granted access to their accounts in a window, by client ID, with its scopes and who granted or revoked it, those that read mail or files or administer first; and every app an admin gave domain-wide delegation, which acts as anyone without their consent."
        static let input = JSONSchema.object([
            "since": .string("The earliest time, in ISO 8601. The last 180 days when left out, as far back as Google keeps."),
            "until": .string("The latest time, in ISO 8601."),
        ])

        struct App: Encodable {
            let clientId: String, name: String, type: String?, scopes: [String], grantedBy: [String], revokedBy: [String], lastGranted: String?
            let risk: String?
        }

        func run(_ input: Input, on service: ServiceClient) async throws -> ServiceResult {
            var query: [String: String?] = ["startTime": try input.since.map(ServiceInput.time) ?? ServiceInput.daysAgo(180), "maxResults": "1000"]
            if let until = input.until { query["endTime"] = try ServiceInput.time(until) }
            // One after another, through the paced connection, not as child tasks: see gather.
            func read(_ application: String, _ event: String) async throws -> EventPage {
                try await GoogleWorkspace.read(.reports) {
                    try await GoogleWorkspace.events(service, application: application, event: event, query: query, limit: 20000)
                }
            }
            let grantPage = try await read("token", "authorize"), revokePage = try await read("token", "revoke")
            let delegationPage = try await read("admin", "AUTHORIZE_API_CLIENT_ACCESS"), undelegationPage = try await read("admin", "REMOVE_API_CLIENT_ACCESS")
            let grants = grantPage.events, revokes = revokePage.events
            // The lists not read in full, so nothing is said of them as though it were.
            let partly = [("grants", grantPage), ("revocations", revokePage), ("delegations", delegationPage), ("delegation removals", undelegationPage)]
                .filter { $0.1.more }.map(\.0)
            let apps = Dictionary(grouping: grants) { $0.parameters["client_id"] ?? "?" }.map { client, events in
                let scopes = Array(Set(events.flatMap { ($0.parameters["scope"] ?? "").components(separatedBy: ", ") }.filter { !$0.isEmpty })).sorted()
                // Revoked by someone only when they revoked it after they last granted it, as one may grant it again.
                let lastGrant = Dictionary(events.map { ($0.user ?? "?", $0.time ?? "") }, uniquingKeysWith: max)
                let revoked = revokes.filter { $0.parameters["client_id"] == client && ($0.time ?? "") > (lastGrant[$0.user ?? "?"] ?? "") }
                return App(clientId: client, name: events.compactMap { $0.parameters["app_name"] }.first ?? client,
                           type: events.compactMap { $0.parameters["client_type"] }.first, scopes: scopes,
                           grantedBy: Array(NSOrderedSet(array: events.compactMap(\.user))) as? [String] ?? [],
                           revokedBy: Array(NSOrderedSet(array: revoked.compactMap(\.user))) as? [String] ?? [],
                           lastGranted: events.compactMap(\.time).max(), risk: GoogleWorkspace.risk(scopes)?.said)
            }.sorted { first, second in
                let ranks = (GoogleWorkspace.risk(first.scopes)?.rank ?? 9, GoogleWorkspace.risk(second.scopes)?.rank ?? 9)
                return ranks.0 != ranks.1 ? ranks.0 < ranks.1 : (first.grantedBy.count, second.name) > (second.grantedBy.count, first.name)
            }
            // Domain-wide delegation: the latest grant of each client, and whether a removal came after it.
            struct Delegated: Encodable { let client: String, scopes: [String], authorizedBy: String?, authorized: String?, removedBy: String?, removed: String?, risk: String? }
            let delegated = Dictionary(grouping: delegationPage.events) { $0.parameters["API_CLIENT_NAME"] ?? "?" }.map { client, events -> Delegated in
                let latest = events.max { ($0.time ?? "") < ($1.time ?? "") }
                let scopes = (latest?.parameters["API_SCOPES"] ?? "").split(whereSeparator: { $0 == "," || $0 == " " || $0 == "|" }).map(String.init)
                let removal = undelegationPage.events.filter { $0.parameters["API_CLIENT_NAME"] == client && ($0.time ?? "") > (latest?.time ?? "") }
                    .max { ($0.time ?? "") < ($1.time ?? "") }
                return Delegated(client: client, scopes: scopes, authorizedBy: latest?.user, authorized: latest?.time, removedBy: removal?.user,
                                 removed: removal?.time, risk: GoogleWorkspace.risk(scopes)?.said)
            }.sorted { ($0.authorized ?? "") > ($1.authorized ?? "") }
            let revocations = revokePage.more ? "; revocations read only in part" : ""
            var text = apps.isEmpty ? (delegated.isEmpty ? "No app was granted access in this window." : "No user granted an app access in this window.") : apps.map { app in
                let revoked: String = app.revokedBy.isEmpty ? "" : "; revoked by \(app.revokedBy.joined(separator: ", ")) since they last granted it"
                return "\(app.name) (client \(app.clientId)\(app.type.map { ", \($0)" } ?? ""))" + (app.risk.map { ": \($0)" } ?? "")
                    + "; granted by \(app.grantedBy.joined(separator: ", ")), last \(app.lastGranted ?? "?")" + revoked + revocations
                    + "; scopes \(app.scopes.joined(separator: " "))"
            }.joined(separator: "\n")
            if !delegated.isEmpty {
                let notRemoved = undelegationPage.more ? "; whether it was removed since is not known, as removals were read only in part" : "; not removed since"
                text += "\nDomain-wide delegation, which lets an app act as anyone in the domain without their consent:\n" + delegated.map { grant in
                    let removed: String = grant.removed.map { "; removed by \(grant.removedBy ?? "an admin") at \($0)" } ?? notRemoved
                    return "client \(grant.client)" + (grant.risk.map { ": \($0)" } ?? "") + "; authorized by \(grant.authorizedBy ?? "an admin") at \(grant.authorized ?? "?")"
                        + removed + "; scopes \(grant.scopes.joined(separator: " "))"
                }.joined(separator: "\n")
            }
            text += "\nDelegation granted before this window is not listed, and revoking users' tokens leaves it in place: the Admin console's "
                + "Domain-wide delegation page lists every app that holds it now, https://admin.google.com/ac/owl/domainwidedelegation"
            if !partly.isEmpty {
                text = "This result is incomplete: not all the \(partly.formatted(.list(type: .and))) in this window were read; narrow the window.\n" + text
            }
            if let stopped = [grantPage, revokePage, delegationPage, undelegationPage].compactMap(\.stopped).first { text += "\n" + stopped }
            struct Kept: Encodable { let apps: [App]; let delegated: [Delegated]; let incomplete: [String] }
            return try ServiceResult(text: text, structured: Kept(apps: apps, delegated: delegated, incomplete: partly))
        }
    }

    /// What apps did with the access they were given: API calls and the data they pulled, by app, user and method.
    /// A large pull by one app on one account is how data leaves through an OAuth grant.
    struct AppActivity: ServiceOperation {
        struct Input: Decodable, Sendable { let clientId: String?, user: String?, since: String?, until: String? }
        static let name = "app-activity"
        static let jobs: Set<ToolJob> = [.detection]
        static let summary = "API calls apps made on people's behalf and the data they pulled, by app, user and method, the largest first; by client ID, user or both."
        static let input = JSONSchema.object([
            "clientId": .string("Only this app, by its client ID from oauth-apps."),
            "user": .string("Only calls on behalf of this user's email."),
            "since": .string("The earliest time, in ISO 8601. The last 7 days when left out."),
            "until": .string("The latest time, in ISO 8601."),
        ])

        func run(_ input: Input, on service: ServiceClient) async throws -> ServiceResult {
            var query: [String: String?] = ["startTime": try input.since.map(ServiceInput.time) ?? ServiceInput.daysAgo(7), "maxResults": "1000"]
            if let until = input.until { query["endTime"] = try ServiceInput.time(until) }
            if let client = input.clientId { query["filters"] = "client_id==" + (try ServiceInput.quoted(client, "the client ID")) }
            let user = try input.user.map(GoogleWorkspace.reportUser) ?? "all"
            let page = try await GoogleWorkspace.events(service, application: "token", user: user, event: "activity", query: query, limit: 20000)
            let calls = page.events
            struct Usage: Encodable { let app: String, clientId: String, user: String, method: String, calls: Int, bytes: Int }
            let usage = Dictionary(grouping: calls) { [$0.parameters["app_name"] ?? "?", $0.parameters["client_id"] ?? "?", $0.user ?? "?",
                                                      $0.parameters["method_name"] ?? "?"] }
                .map { key, events in
                    Usage(app: key[0], clientId: key[1], user: key[2], method: key[3], calls: events.count,
                          bytes: events.reduce(0) { $0 + (Int($1.parameters["num_response_bytes"] ?? "") ?? 0) })
                }.sorted { ($0.bytes, $0.calls) > ($1.bytes, $1.calls) }
            func size(_ bytes: Int) -> String {
                bytes >= 1_000_000 ? String(format: "%.1f MB", Double(bytes) / 1_000_000) : bytes >= 1_000 ? String(format: "%.1f KB", Double(bytes) / 1_000) : "\(bytes) bytes"
            }
            var text = usage.isEmpty ? "No API calls by apps match." : usage.prefix(60).map {
                "\($0.app) (\($0.clientId)) as \($0.user): \($0.method) \($0.calls) call\($0.calls == 1 ? "" : "s"), \(size($0.bytes))"
            }.joined(separator: "\n")
            if page.more {
                text = "This result is incomplete: only \(calls.count) calls in this window were read, so there may be more apps, calls and data "
                    + "than these; narrow the window or name the app.\n" + text
            }
            if let stopped = page.stopped { text += "\n" + stopped }
            struct Kept: Encodable { let usage: [Usage]; let incomplete: Bool }
            return try ServiceResult(text: text, structured: Kept(usage: usage, incomplete: page.more))
        }
    }

    /// One account's activity across the reports, and what admins did to it, merged newest first: where an
    /// investigation of an account starts. It says which reports it searched, which it could not read and which held
    /// more than it read, so a gap is never taken for nothing having happened.
    struct UserTimeline: ServiceOperation {
        struct Input: Decodable, Sendable { let user: String, since: String?, until: String? }
        static let name = "user-timeline"
        static let jobs: Set<ToolJob> = [.detection]
        static let summary = "One account's activity across every report it appears in, and what admins did to it, newest first: sign-ins, account and recovery changes, app grants, Drive, Gmail, Calendar, Chat, Meet, Keep, Chrome, rules it set off, Looker Studio, Google Cloud, Gemini, Takeout exports, groups and admin actions. It says which reports it searched and which it could not read."
        static let input = JSONSchema.object([
            "user": .string("The user's email, or the profile ID of a deleted account from users."),
            "since": .string("The earliest time, in ISO 8601. The last 7 days when left out. Gmail is read only for windows of 30 days at most."),
            "until": .string("The latest time, in ISO 8601."),
        ], required: ["user"])
        /// Every report Google keeps that an account acts in, as activities.list names them
        /// (https://developers.google.com/workspace/admin/reports/reference/rest/v1/activities/list): Chrome's for its
        /// browser's password reuse and downloads, rules' for the data protection rules it set off, and Access
        /// Transparency's for Google staff reaching its data, among them.
        static let applications = ["login", "user_accounts", "token", "drive", "admin", "saml", "mobile", "groups", "groups_enterprise", "gmail", "calendar", "chat", "meet",
                                   "takeout", "vault", "context_aware_access", "chrome", "rules", "keep", "data_studio", "gcp", "gemini_in_workspace_apps",
                                   "admin_data_action", "access_transparency"]

        func run(_ input: Input, on service: ServiceClient) async throws -> ServiceResult {
            let user = try GoogleWorkspace.reportUser(input.user)
            var query: [String: String?] = ["startTime": try input.since.map(ServiceInput.time) ?? ServiceInput.daysAgo(7)]
            if let until = input.until { query["endTime"] = try ServiceInput.time(until) }
            // Google takes Gmail events for 30 days at most, so a longer window reads Gmail for its last 30 days.
            let mail = GoogleWorkspace.lastThirtyDays(query)
            // What admins did to the account, as they are the actors there.
            let reads = Self.applications.map { (label: $0, application: $0, user: user, event: String?.none, query: $0 == "gmail" ? mail?.query ?? query : query) }
                + (user.contains("@") ? [(label: "admin, about them", application: "admin", user: "all", event: String?.none,
                                          query: query.merging(["filters": "USER_EMAIL==\(user)"]) { $1 })] : [])
            var gathered = await GoogleWorkspace.gather(service, reads, limit: 1000)
            if gathered.searched.isEmpty, let first = gathered.failed.first { throw ServiceError.input(first.1) }
            if let mail, gathered.searched.contains("gmail") {
                gathered.partial.append(("gmail", "only the window's last 30 days, from \(mail.from), as Google takes Gmail events for 30 days at most"))
            }
            if !user.contains("@") {
                gathered.skipped.append(("admin, about them", "admin events name an account by email, not by profile ID: users with deleted true gives its email, "
                                         + "and activity on the admin report with filters USER_EMAIL== that email reads them"))
            }
            var text = gathered.events.isEmpty ? gathered.nothing("Nothing for \(user)")
                : gathered.events.prefix(150).map { "\($0.application) \($0.line)" }.joined(separator: "\n")
            if gathered.events.count > 150 { text += "\n\(gathered.events.count - 150) more in the structured result." }
            text += "\n" + gathered.coverage
            struct Kept: Encodable {
                let events: [Event]; let searched: [String]; let cutShort: [String]; let partlyRead: [String: String]; let couldNotRead: [String]
                let skipped: [String]
            }
            return try ServiceResult(text: text, structured: Kept(events: gathered.events, searched: gathered.searched, cutShort: gathered.cut,
                                                                  partlyRead: gathered.partlyRead, couldNotRead: gathered.failed.map(\.0),
                                                                  skipped: gathered.skipped.map(\.0)))
        }
    }

    /// Everything one address did, in every report: how an attacker's IP is followed across accounts.
    struct IPActivity: ServiceOperation {
        struct Input: Decodable, Sendable { let ip: String, since: String?, until: String? }
        static let name = "ip-activity"
        static let jobs: Set<ToolJob> = [.detection]
        static let summary = "Everything one IP address did across every report and account, newest first: sign-ins, app grants, Drive, Gmail, Chrome, rules set off, admin actions, exports and more. It says which reports it searched and which it could not read; Gmail only for the window's last 30 days."
        static let input = JSONSchema.object([
            "ip": .string("The IPv4 or IPv6 address."),
            "since": .string("The earliest time, in ISO 8601. The last 7 days when left out."),
            "until": .string("The latest time, in ISO 8601."),
        ], required: ["ip"])
        static let applications = ["login", "user_accounts", "token", "drive", "admin", "saml", "mobile", "groups", "groups_enterprise", "gmail", "calendar",
                                   "chat", "meet", "takeout", "vault", "context_aware_access", "gcp", "chrome", "rules"]

        func run(_ input: Input, on service: ServiceClient) async throws -> ServiceResult {
            var query: [String: String?] = ["startTime": try input.since.map(ServiceInput.time) ?? ServiceInput.daysAgo(7),
                                            "actorIpAddress": try ServiceInput.ip(input.ip)]
            if let until = input.until { query["endTime"] = try ServiceInput.time(until) }
            // Google takes Gmail events for 30 days at most, so a longer window reads Gmail for its last 30 days.
            let mail = GoogleWorkspace.lastThirtyDays(query)
            var gathered = await GoogleWorkspace.gather(service, Self.applications.map {
                (label: $0, application: $0, user: "all", event: String?.none, query: $0 == "gmail" ? mail?.query ?? query : query)
            }, limit: 1000)
            if gathered.searched.isEmpty, let first = gathered.failed.first { throw ServiceError.input(first.1) }
            if let mail, gathered.searched.contains("gmail") {
                gathered.partial.append(("gmail", "only the window's last 30 days, from \(mail.from), as Google takes Gmail events for 30 days at most"))
            }
            var text = gathered.events.isEmpty ? gathered.nothing("Nothing from \(input.ip)")
                : gathered.events.prefix(150).map { "\($0.application) \($0.line)" }.joined(separator: "\n")
            if gathered.events.count > 150 { text += "\n\(gathered.events.count - 150) more in the structured result." }
            text += "\n" + gathered.coverage
            struct Kept: Encodable { let events: [Event]; let searched: [String]; let cutShort: [String]; let partlyRead: [String: String]; let couldNotRead: [String] }
            return try ServiceResult(text: text, structured: Kept(events: gathered.events, searched: gathered.searched, cutShort: gathered.cut,
                                                                  partlyRead: gathered.partlyRead, couldNotRead: gathered.failed.map(\.0)))
        }
    }
}

extension GoogleWorkspace {
    /// The access apps hold now, across every account, from each user's tokens: what is still open after a breach,
    /// whatever the audit log has kept.
    struct Apps: ServiceOperation {
        struct Input: Decodable, Sendable {}
        static let name = "apps"
        static let jobs: Set<ToolJob> = [.audit, .containment]
        static let summary = "Every app holding access to accounts now, across all users, by client ID, with its scopes and holders, those that read mail or files or administer first."
        static let input = JSONSchema.object([:])

        struct Token: Decodable, Sendable { let clientId: String?; let displayText: String?; let scopes: [String]? }

        /// One account's tokens, or why they could not be read. Each read is a function of its own, given only values,
        /// so the reads that run at once capture nothing they share: a release build freed what reads in a task group
        /// captured, and Pion crashed.
        static func tokens(of email: String, on service: ServiceClient) async -> (email: String, tokens: [Token]?, failure: String?) {
            struct Tokens: Decodable { let items: [Token]? }
            do {
                let path = ["admin", "directory", "v1", "users", try ServiceInput.email(email), "tokens"]
                return (email, try await service.get(path, as: Tokens.self).items ?? [], nil)
            } catch {
                return (email, nil, why(error))
            }
        }

        /// Why one account's tokens could not be read, so that only a refusal is put down to the role or the account being
        /// an admin's.
        static func why(_ error: Error) -> String {
            if GoogleWorkspace.isPassing(error) { return "Google was busy, rate limited or could not be reached for now; try again" }
            let fix = GoogleWorkspace.fix(for: error, .security)
            if case ServiceError.forbidden = error, fix?.hasPrefix("the admin this tool signs in as") != false {
                return "User Security Management never covers admins, or the role lacks it"
            }
            if case ServiceError.notFound = error { return "the account was not found" }
            return fix ?? error.localizedDescription
        }

        /// How many accounts' tokens are read at once, the most the connection sends anyway.
        static let atOnce = 8

        func run(_ input: Input, on service: ServiceClient) async throws -> ServiceResult {
            struct User: Decodable { let primaryEmail: String? }
            let (users, more): ([User], Bool) = try await read(.containmentUsers) {
                try await GoogleWorkspace.listAll(service, ["admin", "directory", "v1", "users"], query: ["customer": "my_customer"], limit: 10000)
            }
            let emails = users.compactMap(\.primaryEmail)
            // One account refused, as an admin is under User Security Management, leaves the rest. A few at a time, each
            // given only its email and the connection.
            var results: [(email: String, tokens: [Token]?, failure: String?)] = []
            for start in stride(from: 0, to: emails.count, by: Self.atOnce) {
                let batch = Array(emails[start..<min(start + Self.atOnce, emails.count)])
                results += await withTaskGroup(of: (email: String, tokens: [Token]?, failure: String?).self) { group in
                    for email in batch { group.addTask { await Self.tokens(of: email, on: service) } }
                    return await group.reduce(into: []) { $0.append($1) }
                }
            }
            let held = results.compactMap { result in result.tokens.map { (result.email, $0) } }
            let failed = results.compactMap { $0.failure == nil ? nil : $0.email }.sorted()
            let reasons = Dictionary(grouping: results.filter { $0.failure != nil }) { $0.failure ?? "" }.mapValues { $0.map(\.email).sorted() }
            struct App: Encodable { let clientId: String, name: String, scopes: [String], holders: [String], risk: String? }
            let apps = Dictionary(grouping: held.flatMap { email, tokens in tokens.map { (email, $0) } }) { $0.1.clientId ?? "?" }.map { client, pairs in
                let scopes = Array(Set(pairs.flatMap { $0.1.scopes ?? [] })).sorted()
                return App(clientId: client, name: pairs.compactMap { $0.1.displayText }.first ?? client, scopes: scopes,
                           holders: Array(Set(pairs.map(\.0))).sorted(), risk: GoogleWorkspace.risk(scopes)?.said)
            }.sorted { first, second in
                let ranks = (GoogleWorkspace.risk(first.scopes)?.rank ?? 9, GoogleWorkspace.risk(second.scopes)?.rank ?? 9)
                return ranks.0 != ranks.1 ? ranks.0 < ranks.1 : (first.holders.count, second.name) > (second.holders.count, first.name)
            }
            let checked = emails.count - failed.count
            var text = apps.isEmpty ? "No app holds access to any of the \(checked) account\(checked == 1 ? "" : "s") checked." : apps.map { app in
                "\(app.name) (\(app.clientId))" + (app.risk.map { ": \($0)" } ?? "")
                    + "; held by \(app.holders.count) user\(app.holders.count == 1 ? "" : "s"): \(app.holders.joined(separator: ", ")); scopes \(app.scopes.joined(separator: " "))"
            }.joined(separator: "\n")
            text += "\nChecked \(checked) of \(emails.count) account\(emails.count == 1 ? "" : "s")" + (failed.isEmpty ? "." : "; could not read "
                + reasons.sorted { $0.key < $1.key }.map { reason, emails in "\(emails.joined(separator: ", ")), as \(reason)" }.joined(separator: "; ") + ".")
            if more { text += "\n" + GoogleWorkspace.incomplete("accounts") }
            struct Kept: Encodable {
                let apps: [App]; let accountsChecked: Int; let accountsTried: Int; let couldNotRead: [String]; let reasons: [String: [String]]; let incomplete: Bool
            }
            return try ServiceResult(text: text, structured: Kept(apps: apps, accountsChecked: checked, accountsTried: emails.count, couldNotRead: failed,
                                                                  reasons: reasons, incomplete: more))
        }
    }
}


// MARK: - What left, and what an app did

extension GoogleWorkspace {
    /// What left through Drive, from its audit events (https://developers.google.com/workspace/admin/reports/v1/appendix/activity/drive):
    /// download, copy and print by person and file; change_user_access giving someone outside the organisation access,
    /// by their domain; change_document_visibility to public_on_the_web or people_with_link, Google's settings that let
    /// anyone on the web in; and change_owner, to its new_owner. Each with the file's ID and title, so it can be fixed.
    struct DriveExposure: ServiceOperation {
        struct Input: Decodable, Sendable { let user: String?, since: String?, until: String?, limit: Int? }
        static let name = "drive-exposure"
        static let jobs: Set<ToolJob> = [.detection]
        static let summary = "What left through Drive in a window, for one user or everyone: downloads, copies and prints by person and file, files shared with people outside the organisation by their domain, files made public or open to anyone with the link, and ownership handed over, each with the file's ID and title to fix it by."
        static let input = JSONSchema.object([
            "user": .string("Only what this user did: their email, or the profile ID of a deleted account. Everyone when left out."),
            "since": .string("The earliest time, in ISO 8601. The last 7 days when left out."),
            "until": .string("The latest time, in ISO 8601."),
            "limit": .integer("How many events of each kind to read, at most.", minimum: 1, maximum: 20000),
        ])
        static let events = ["download", "copy", "print", "change_user_access", "change_document_visibility", "change_owner"]
        /// Google's link sharing settings that let anyone on the web in, as its Drive page says them.
        static let open = ["public_on_the_web": "public on the web", "people_with_link": "anyone with the link"]

        struct Taken: Encodable { let user: String, docId: String, title: String?, downloads: Int, copies: Int, prints: Int }
        struct Shared: Encodable { let docId: String, title: String?, with: String, access: String?, by: String?, time: String? }
        struct Opened: Encodable { let docId: String, title: String?, from: String?, to: String, by: String?, time: String? }
        /// `outside` is nil when the organisation's domains could not be read, as who is inside is then not known.
        struct Handed: Encodable { let docId: String, title: String?, from: String?, to: String, by: String?, time: String?, outside: Bool? }

        func run(_ input: Input, on service: ServiceClient) async throws -> ServiceResult {
            let user = try input.user.map(GoogleWorkspace.reportUser) ?? "all"
            let limit = input.limit ?? 5000
            guard (1...20000).contains(limit) else { throw ServiceError.input("Ask for between 1 and 20000 events of each kind.") }
            var query: [String: String?] = ["startTime": try input.since.map(ServiceInput.time) ?? ServiceInput.daysAgo(7)]
            if let until = input.until { query["endTime"] = try ServiceInput.time(until) }
            let gathered = await GoogleWorkspace.gather(service, Self.events.map {
                (label: "drive/\($0)", application: "drive", user: user, event: Optional($0), query: query)
            }, limit: limit)
            if gathered.searched.isEmpty, let first = gathered.failed.first { throw ServiceError.input(first.1) }
            let of = { (name: String) in gathered.events.filter { $0.event == name } }
            let taking = gathered.events.filter { ["download", "copy", "print"].contains($0.event) }
            let byFile = Dictionary(grouping: taking) { (event: Event) -> [String] in [event.user ?? "?", event.parameters["doc_id"] ?? "?"] }
            let taken = byFile.map { key, events -> Taken in
                let count = { (name: String) -> Int in events.filter { $0.event == name }.count }
                return Taken(user: key[0], docId: key[1], title: events.compactMap { $0.parameters["doc_title"] }.first,
                             downloads: count("download"), copies: count("copy"), prints: count("print"))
            }.sorted { (first: Taken, second: Taken) -> Bool in
                let totals = (first.downloads + first.copies + first.prints, second.downloads + second.copies + second.prints)
                return totals.0 != totals.1 ? totals.0 > totals.1 : (first.user, first.docId) < (second.user, second.docId)
            }
            // Access given, not taken away: Google's new_value none is access removed.
            let grants = of("change_user_access").filter { ($0.parameters["new_value"] ?? "none") != "none" && $0.parameters["target_user"] != nil }
            let domains = grants.isEmpty && of("change_owner").isEmpty ? nil : await GoogleWorkspace.organisationDomains(service)
            // Without the organisation's verified domains nobody's domain stands in for them, not even the actors': an
            // outside collaborator who acted would make their whole domain look inside. Every share is then listed, as
            // not known to be inside or outside.
            let known = domains != nil
            let domain = { (address: String) in address.split(separator: "@").last.map { $0.lowercased() } ?? "?" }
            let outside = grants.filter { !known || GoogleWorkspace.isOutside($0.parameters["target_user"] ?? "", domains: domains, fallback: []) }
            let byDomain = Dictionary(grouping: outside) { domain($0.parameters["target_user"] ?? "") }.mapValues { events in
                events.map { Shared(docId: $0.parameters["doc_id"] ?? "?", title: $0.parameters["doc_title"], with: $0.parameters["target_user"] ?? "?",
                                    access: $0.parameters["new_value"], by: $0.user, time: $0.time) }
            }
            let opened = of("change_document_visibility").compactMap { event -> Opened? in
                guard let to = event.parameters["new_value"], Self.open[to] != nil else { return nil }
                return Opened(docId: event.parameters["doc_id"] ?? "?", title: event.parameters["doc_title"], from: event.parameters["old_value"], to: to,
                              by: event.user, time: event.time)
            }
            let handed = of("change_owner").compactMap { event -> Handed? in
                guard let to = event.parameters["new_owner"] else { return nil }
                return Handed(docId: event.parameters["doc_id"] ?? "?", title: event.parameters["doc_title"], from: event.parameters["owner"], to: to,
                              by: event.user, time: event.time, outside: known ? GoogleWorkspace.isOutside(to, domains: domains, fallback: []) : nil)
            }
            func file(_ id: String, _ title: String?) -> String { (title.map { "\"\($0)\"" } ?? "a file") + " (\(id))" }
            func plural(_ count: Int, _ one: String, _ many: String) -> String { "\(count) \(count == 1 ? one : many)" }
            var lines: [String] = []
            if !taken.isEmpty {
                lines.append("Downloaded, copied or printed: \(plural(taken.count, "file", "files")) by \(plural(Set(taken.map(\.user)).count, "person", "people")), the most first:")
                lines += taken.prefix(40).map { item in
                    let counts = [plural(item.downloads, "download", "downloads"), plural(item.copies, "copy", "copies"), plural(item.prints, "print", "prints")]
                        .filter { !$0.hasPrefix("0 ") }
                    return "\(item.user): \(file(item.docId, item.title)), " + counts.joined(separator: ", ")
                }
                if taken.count > 40 { lines.append("\(taken.count - 40) more in the structured result.") }
            }
            if !byDomain.isEmpty {
                lines.append(known ? "Shared with people outside the organisation, by their domain:"
                             : "Shared with people, by their domain; whether each is inside the organisation is not known, as its domains could not be read:")
                for (name, shares) in byDomain.sorted(by: { ($0.value.count, $1.key) > ($1.value.count, $0.key) }) {
                    lines.append("\(name) (\(shares.count)): " + shares.prefix(15).map {
                        "\(file($0.docId, $0.title)) to \($0.with)\($0.access.map { " (\($0))" } ?? "") by \($0.by ?? "?") at \($0.time ?? "?")"
                    }.joined(separator: "; ") + (shares.count > 15 ? "; and \(shares.count - 15) more" : ""))
                }
            }
            if !opened.isEmpty {
                lines.append("Made public or open to anyone with the link:")
                lines += opened.prefix(40).map {
                    "\(file($0.docId, $0.title)) made \(Self.open[$0.to] ?? $0.to) by \($0.by ?? "?") at \($0.time ?? "?")" + ($0.from.map { ", was \($0)" } ?? "")
                }
                if opened.count > 40 { lines.append("\(opened.count - 40) more in the structured result.") }
            }
            if !handed.isEmpty {
                lines.append("Ownership handed over:")
                lines += handed.prefix(40).map {
                    "\(file($0.docId, $0.title)) from \($0.from ?? "?") to \($0.to)\($0.outside == true ? " (outside the organisation)" : $0.outside == nil ? " (inside or outside not known)" : "") by \($0.by ?? "?") at \($0.time ?? "?")"
                }
                if handed.count > 40 { lines.append("\(handed.count - 40) more in the structured result.") }
            }
            if lines.isEmpty {
                lines.append(gathered.nothing("No downloads, copies, prints, outside shares, public links or ownership changes" + (user == "all" ? "" : " by \(user)")))
            }
            lines.append(gathered.coverage)
            if !known, !outside.isEmpty || !handed.isEmpty {
                lines.append("The organisation's verified domains could not be read, so every share and new owner above is listed without saying whether "
                             + "they are inside it; check each, and check-access says what the domains need.")
            }
            lines.append("Google lists Drive events minutes to hours late. A share or link still in place is removed on the file itself, by its ID.")
            struct Kept: Encodable {
                let taken: [Taken]; let sharedOutside: [String: [Shared]]; let sharedInsideOrOutsideNotKnown: [String: [Shared]]
                let madePublic: [Opened]; let ownershipHanded: [Handed]
                let searched: [String]; let cutShort: [String]; let partlyRead: [String: String]; let couldNotRead: [String]
            }
            return try ServiceResult(text: lines.joined(separator: "\n"), structured: Kept(
                taken: taken, sharedOutside: known ? byDomain : [:], sharedInsideOrOutsideNotKnown: known ? [:] : byDomain, madePublic: opened, ownershipHanded: handed, searched: gathered.searched, cutShort: gathered.cut,
                partlyRead: gathered.partlyRead, couldNotRead: gathered.failed.map(\.0)))
        }
    }

    /// What happened to a message in every mailbox it reached, from Gmail's delivery events, by Google's documented
    /// mail_event_type (https://developers.google.com/workspace/admin/reports/v1/appendix/activity/gmail). Google names the
    /// message's own details only as message_info, so the Message-ID, sender, recipient and subject are matched here,
    /// not asked of Google, against the details whose names say so: Gmail's logs in BigQuery call them
    /// message_info.rfc2822_message_id, message_info.source.address, message_info.destination.address and
    /// message_info.subject, which no live Reports API answer has confirmed. A recipient is also the mailbox an event
    /// other than a send is in.
    struct MailTrace: ServiceOperation {
        struct Input: Decodable, Sendable {
            let messageId: String?, sender: String?, recipient: String?, subject: String?, user: String?, since: String?, until: String?, limit: Int?
        }
        static let name = "mail-trace"
        static let jobs: Set<ToolJob> = [.detection]
        static let summary = "What happened to a message in every mailbox, for up to 30 days, by its Message-ID, sender, recipient or subject: who received it, opened it, replied, forwarded it, clicked in it, downloaded its attachments, had it reclassified or deleted it, and who may still hold it."
        static let input = JSONSchema.object([
            "messageId": .string("The message's Message-ID, with or without its angle brackets."),
            "sender": .string("The sender's address or domain."),
            "recipient": .string("A recipient's address."),
            "subject": .string("Words in the subject."),
            "user": .string("Only this mailbox, by email. Every mailbox when left out."),
            "since": .string("The earliest time, in ISO 8601. The last 7 days when left out."),
            "until": .string("The latest time, in ISO 8601, at most 30 days after since. Now when left out."),
            "limit": .integer("How many Gmail events to read, at most.", minimum: 1, maximum: 20000),
        ])

        /// What happened, by Google's event types, in the order a message's life goes. A type not among them is shown by
        /// what Google calls it, or its number.
        static let kinds: [(name: String, types: Set<String>)] = [
            ("sent", ["1", "35"]), ("received", ["2"]), ("bounced or rate limited", ["30", "34"]), ("quarantined or released", ["5", "6"]),
            ("opened or viewed", ["7", "8", "31", "32"]), ("replied to", ["9"]), ("forwarded", ["10", "11"]), ("link clicked", ["15", "16"]),
            ("attachments downloaded, previewed or saved", ["17", "18", "19", "28"]), ("reclassified as spam or not", ["3", "4"]),
            ("moved, archived or deleted", ["12", "13", "14", "26", "27"]), ("read by an app for the user", ["33"]),
        ]

        func run(_ input: Input, on service: ServiceClient) async throws -> ServiceResult {
            let clean = { (value: String?) -> String? in
                value.map { $0.trimmingCharacters(in: .whitespacesAndNewlines).trimmingCharacters(in: CharacterSet(charactersIn: "<>")).lowercased() }
                    .flatMap { $0.isEmpty ? nil : $0 }
            }
            let (id, sender, recipient, subject) = (clean(input.messageId), clean(input.sender), clean(input.recipient), clean(input.subject))
            guard id != nil || sender != nil || recipient != nil || subject != nil else {
                throw ServiceError.input("Give the message's Message-ID, sender, recipient or subject.")
            }
            let user = try input.user.map(GoogleWorkspace.reportUser) ?? "all"
            let limit = input.limit ?? 5000
            guard (1...20000).contains(limit) else { throw ServiceError.input("Ask for between 1 and 20000 events.") }
            var query: [String: String?] = ["startTime": try input.since.map(ServiceInput.time) ?? ServiceInput.daysAgo(7)]
            if let until = input.until { query["endTime"] = try ServiceInput.time(until) }
            let page = try await GoogleWorkspace.read(.report("Gmail report")) {
                try await GoogleWorkspace.events(service, application: "gmail", user: user, event: "delivery", query: query, limit: limit)
            }
            let type = { (event: Event) in String((event.parameters["event_info.mail_event_type"] ?? "?").prefix { $0 != " " }) }
            /// The values of the details whose names hold one of `words`.
            func values(_ event: Event, _ words: [String]) -> [String] {
                event.parameters.filter { key, _ in words.contains { key.lowercased().contains($0) } }
                    .flatMap { $0.value.components(separatedBy: " | ") }.map { $0.lowercased() }
            }
            /// The message's IDs, from the details named for one, such as message_info.rfc2822_message_id, as a Message-ID
            /// asked for is written: trimmed, without angle brackets, in lower case. An ID found elsewhere, such as in a
            /// subject or a link, is not the message's.
            func messageIDs(_ event: Event) -> Set<String> {
                Set(values(event, ["message_id"]).map { $0.trimmingCharacters(in: .whitespacesAndNewlines).trimmingCharacters(in: CharacterSet(charactersIn: "<>")) }
                    .filter { !$0.isEmpty })
            }
            // Without a detail naming the message's ID in any event read, an ID asked for cannot be matched reliably.
            let idsGiven = page.events.contains { !messageIDs($0).isEmpty }
            let matched = page.events.filter { event in
                let sent = ["1", "35"].contains(type(event))
                return (id.map { id in messageIDs(event).contains(id) } ?? true)
                    && (subject.map { text in values(event, ["subject"]).contains { $0.contains(text) } } ?? true)
                    && (sender.map { text in values(event, ["source", "sender", "from"]).contains { $0.contains(text) } } ?? true)
                    && (recipient.map { text in (!sent && event.user?.lowercased() == text) || values(event, ["destination", "recipient"]).contains { $0.contains(text) } } ?? true)
            }
            var groups: [(name: String, events: [Event])] = Self.kinds.map { kind in (kind.name, matched.filter { kind.types.contains(type($0)) }) }
            let known = Set(Self.kinds.flatMap(\.types))
            for (code, events) in Dictionary(grouping: matched.filter { !known.contains(type($0)) }, by: type).sorted(by: { $0.key < $1.key }) {
                groups.append((GoogleWorkspace.mailEvents[code] ?? "type \(code)", events))
            }
            groups = groups.filter { !$0.events.isEmpty }
            let people = { (events: [Event]) in Array(Set(events.compactMap(\.user))).sorted() }
            // Received, and not seen moved to the trash or deleted for good in what was read, by mailbox and message, so
            // one message deleted does not hide another still held; said only when every message received has its ID.
            let received = matched.filter { type($0) == "2" }
            let held: [String]? = received.allSatisfy({ !messageIDs($0).isEmpty }) ? {
                let gone = Set(matched.filter { ["13", "27"].contains(type($0)) }.flatMap { event in messageIDs(event).map { "\(event.user ?? "?") \($0)" } })
                return people(received.filter { event in messageIDs(event).contains { !gone.contains("\(event.user ?? "?") \($0)") } })
            }() : nil
            let asked = [id.map { "Message-ID \($0)" }, sender.map { "from \($0)" }, recipient.map { "to \($0)" }, subject.map { "subject \"\($0)\"" }]
                .compactMap { $0 }.joined(separator: ", ")
            var lines = ["\(matched.count) Gmail event\(matched.count == 1 ? "" : "s") for mail matching \(asked), in \(people(matched).count) mailbox\(people(matched).count == 1 ? "" : "es")."]
            lines += groups.map { group in
                let who = people(group.events)
                return "\(group.name) (\(group.events.count)): " + who.prefix(30).joined(separator: ", ") + (who.count > 30 ? " and \(who.count - 30) more" : "")
            }
            if let held, !held.isEmpty {
                lines.append("Received and not seen deleted in what was read, so likely still in the mailbox: " + held.prefix(50).joined(separator: ", ")
                             + (held.count > 50 ? " and \(held.count - 50) more" : ""))
            } else if held == nil {
                lines.append("Which mailboxes still hold it is not said: not every message received carried its Message-ID, so a deletion cannot be tied to it.")
            }
            if id != nil, !idsGiven, !page.events.isEmpty {
                lines.append("The Message-ID could not be matched reliably: none of the \(page.events.count) Gmail events read carried a detail naming the "
                             + "message's ID, so nothing was matched by it; search by the sender, recipient or subject instead.")
            }
            if matched.isEmpty && !page.events.isEmpty && (id == nil || idsGiven) {
                lines.append("\(page.events.count) Gmail events in the window matched nothing asked for; try part of the subject, the sender's domain or the "
                             + "Message-ID alone. Google has not documented which details carry these, so a message may not be found by every one of them.")
            }
            lines += matched.prefix(60).map { event in
                let shown = event.parameters.sorted { $0.key < $1.key }.filter { $0.key != "event_info.mail_event_type" }
                    .map { "\($0.key)=\($0.value.count > 200 ? String($0.value.prefix(200)) + "…" : $0.value)" }
                return "\(event.time ?? "?") \(event.user ?? "?") (\(event.parameters["event_info.mail_event_type"] ?? "?"))"
                    + (event.ip.map { " from \($0)" } ?? "") + ": " + shown.joined(separator: ", ")
            }
            if matched.count > 60 { lines.append("\(matched.count - 60) more in the structured result.") }
            if page.more {
                lines.insert("This result is incomplete: not every Gmail event in this window was read, so there may be more mailboxes and events than "
                             + "these; narrow the window, name the mailbox or raise limit.", at: 0)
            }
            if let stopped = page.stopped { lines.append(stopped) }
            lines.append("Google lists Gmail events minutes to hours late, and keeps them for windows of 30 days at most.")
            struct Kept: Encodable { let events: [Event]; let byWhatHappened: [String: [String]]; let likelyStillHeldBy: [String]?; let more: Bool }
            return try ServiceResult(text: lines.joined(separator: "\n"), structured: Kept(
                events: matched, byWhatHappened: Dictionary(groups.map { ($0.name, people($0.events)) }, uniquingKeysWith: { $0 + $1 }),
                likelyStillHeldBy: held, more: page.more))
        }
    }

    /// Everything one OAuth client did, by the account it acted as: how a domain-wide delegation or an app granted access
    /// is followed. Google cannot ask Drive, Gmail, Calendar or admin events for one app's, so they are read whole and
    /// kept here only where the event's actor names the client (actor.applicationInfo.oauthClientId); its token events
    /// name it as client_id, which Google filters on with each event's name.
    struct ClientActivity: ServiceOperation {
        struct Input: Decodable, Sendable { let clientId: String, user: String?, since: String?, until: String?, limit: Int? }
        static let name = "client-activity"
        static let jobs: Set<ToolJob> = [.detection]
        static let summary = "Everything one OAuth client ID did across Drive, Gmail, Calendar, admin actions and its tokens, by the account it acted as and whether it impersonated them, for an app given domain-wide delegation or granted access. It says which reports it searched and which were cut short."
        static let input = JSONSchema.object([
            "clientId": .string("The app's OAuth client ID, from oauth-apps, app-activity or an event's via client."),
            "user": .string("Only what it did as this user: their email, or the profile ID of a deleted account. Everyone when left out."),
            "since": .string("The earliest time, in ISO 8601. The last 7 days when left out. Gmail is read only for its last 30 days."),
            "until": .string("The latest time, in ISO 8601."),
            "limit": .integer("How many events of each report to read, at most.", minimum: 1, maximum: 20000),
        ], required: ["clientId"])
        static let reports = ["drive", "gmail", "calendar", "admin"]
        static let tokenEvents = ["authorize", "activity", "revoke"]

        func run(_ input: Input, on service: ServiceClient) async throws -> ServiceResult {
            let client = try ServiceInput.quoted(input.clientId.trimmingCharacters(in: .whitespacesAndNewlines), "the client ID")
            guard !client.isEmpty else { throw ServiceError.input("Give the app's client ID.") }
            let user = try input.user.map(GoogleWorkspace.reportUser) ?? "all"
            let limit = input.limit ?? 5000
            guard (1...20000).contains(limit) else { throw ServiceError.input("Ask for between 1 and 20000 events of each report.") }
            var query: [String: String?] = ["startTime": try input.since.map(ServiceInput.time) ?? ServiceInput.daysAgo(7)]
            if let until = input.until { query["endTime"] = try ServiceInput.time(until) }
            let mail = GoogleWorkspace.lastThirtyDays(query)
            let reads = Self.reports.map { (label: $0, application: $0, user: user, event: String?.none, query: $0 == "gmail" ? mail?.query ?? query : query) }
                + Self.tokenEvents.map { (label: "token/\($0)", application: "token", user: user, event: Optional($0),
                                          query: query.merging(["filters": "client_id==\(client)"]) { $1 }) }
            var gathered = await GoogleWorkspace.gather(service, reads, limit: limit)
            if gathered.searched.isEmpty, let first = gathered.failed.first { throw ServiceError.input(first.1) }
            if let mail, gathered.searched.contains("gmail") {
                gathered.partial.append(("gmail", "only the window's last 30 days, from \(mail.from), as Google takes Gmail events for 30 days at most"))
            }
            let acting = gathered.events.filter { $0.viaClient == client || ($0.application == "token" && $0.parameters["client_id"] == client) }
            struct Acted: Encodable { let user: String; let impersonated: Bool; let events: Int; let what: [String: Int] }
            let acted = Dictionary(grouping: acting) { $0.user ?? "?" }.map { user, events in
                Acted(user: user, impersonated: events.contains { $0.impersonated == true }, events: events.count,
                      what: Dictionary(grouping: events) { "\($0.application) \($0.event)" }.mapValues(\.count))
            }.sorted { ($0.events, $1.user) > ($1.events, $0.user) }
            var lines: [String]
            if acted.isEmpty {
                lines = [gathered.nothing("Nothing by client \(client)")]
            } else {
                lines = ["Client \(client) acted as \(acted.count) account\(acted.count == 1 ? "" : "s") in \(acting.count) event\(acting.count == 1 ? "" : "s"), the busiest first:"]
                lines += acted.prefix(50).map { account in
                    let what = account.what.sorted { ($0.value, $1.key) > ($1.value, $0.key) }.prefix(8).map { "\($0.key) \($0.value)" }
                    return "\(account.user)\(account.impersonated ? " (impersonating them)" : ""): \(account.events), " + what.joined(separator: ", ")
                }
                if acted.count > 50 { lines.append("\(acted.count - 50) more accounts in the structured result.") }
                lines += acting.prefix(60).map { "\($0.application) \($0.line)" }
                if acting.count > 60 { lines.append("\(acting.count - 60) more in the structured result.") }
            }
            let cutWhole = gathered.cut.filter { Self.reports.contains($0) }
            if !cutWhole.isEmpty {
                lines.append("\(cutWhole.joined(separator: ", ")) \(cutWhole.count == 1 ? "was" : "were") read whole up to \(limit) events and kept only for this "
                             + "client, so there may be more of what it did there; narrow the window or name the user.")
            }
            lines.append(gathered.coverage)
            struct Kept: Encodable {
                let accounts: [Acted]; let events: [Event]; let searched: [String]; let cutShort: [String]; let partlyRead: [String: String]
                let couldNotRead: [String]
            }
            return try ServiceResult(text: lines.joined(separator: "\n"), structured: Kept(
                accounts: acted, events: acting, searched: gathered.searched, cutShort: gathered.cut, partlyRead: gathered.partlyRead,
                couldNotRead: gathered.failed.map(\.0)))
        }
    }
}

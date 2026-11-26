# Changelog

Noodle Push deploys from `main` whenever `Push/` changes; this file records what each version does.

## [Unreleased]

### Added

- Noodle Push, the service that rings an iPhone for a bot's call when Noodle Mobile is closed or away from its Hub. The phone registers its VoIP token and gets it back sealed; a Hub the phone granted calls rings it through Apple's VoIP push. Push keeps no database.

### Changed

- Noodle's source is now under the Functional Source License instead of Apache 2.0: free to use, read and change for anything except a competing product, and each version becomes Apache 2.0 two years after its release. Earlier versions stay under Apache 2.0.

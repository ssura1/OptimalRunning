# WatchModern

Not yet created — see `docs/implementation.md` T-005. Requires a machine with Xcode.

This target owns **only** platform glue: sensor adapters, SwiftUI views, persistence
and transport. Every decision it renders comes from `Core` (ADR-001), so this
directory should contain no pace maths, no zone logic and no interval rules.

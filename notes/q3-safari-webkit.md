Section 12 Q3: on macOS 26.5 every WebKit XPC process still has launchd as parent, so the Safari heuristic is needed and holds; there is a new `WebContent.EnhancedSecurity` variant.

Launching Safari showed `com.apple.WebKit.WebContent`, `WebContent.EnhancedSecurity`, `Networking` and `GPU`
all with ppid 1 and paths under `/System/Library/Frameworks/WebKit.framework/`. The rollup matches on that path
prefix plus ppid <= 1 and attributes them to Safari when a Safari.app process exists, otherwise to a "WebKit"
row. Known over-attribution: Mail, Notes and other WebKit hosts spawn the same processes, so with Safari and Mail
both open, Mail's web views count under Safari. The only precise fix is the private responsible-pid API, which
the spec forbids. macOS 15 was not available on this machine; the heuristic is path-based so it should hold.

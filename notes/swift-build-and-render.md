The app is a SwiftPM executable assembled into a bundle by the Makefile; `LOUPE_RENDER=<dir>` renders every tab to PNG offscreen for inspection and snapshot tests.

`screencapture` needs Screen Recording permission that this terminal does not have, and `open`
launched apps do not surface `NSLog` in `log show` here, so two environment hooks exist:
`LOUPE_DEBUG=1` prints the stream state and self-cost per poll to stderr (run the binary directly),
and `LOUPE_RENDER=<dir>` (with `LOUPE_OPEN_PANEL=1`) renders overview/apps/storage/health in light
and dark with `ImageRenderer` twelve seconds after launch, then quits. A bundle-less debug binary
uses the executable name as its `UserDefaults` domain, so the render path forces `firstRunDone`.
`ps -o rss` reports about 80 MB with the panel open while the app's own `ri_phys_footprint`
reports about 24 MB; RSS counts shared framework pages, footprint is what Activity Monitor shows.

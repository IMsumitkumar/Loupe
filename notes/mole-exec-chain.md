`mo` execs into `status-go`, so the pid returned by spawn is the pid that streams and one SIGTERM ends it.

`/opt/homebrew/bin/mo` is a bash router that `exec`s `libexec/bin/status.sh`, which `exec`s `status-go`. No
intermediate shell survives, which means `Child::id()` is the Go process, `waitpid` reaps it, and Mole's own
"exit when stdout closes" also covers the case where Loupe dies without cleanup.

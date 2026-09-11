use sysmon_core::energy::ProcInfo;
use sysmon_core::rollup::{bundle_root, force_quit_ok, Kind, Resolver, Weights};

const CHROME: &str = "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome";
const HELPER: &str = "/Applications/Google Chrome.app/Contents/Frameworks/Google Chrome Framework.framework/Versions/152.0/Helpers/Google Chrome Helper (Renderer).app/Contents/MacOS/Google Chrome Helper (Renderer)";
const SAFARI: &str = "/System/Volumes/Preboot/Cryptexes/App/System/Applications/Safari.app/Contents/MacOS/Safari";
const WEBCONTENT: &str = "/System/Library/Frameworks/WebKit.framework/Versions/A/XPCServices/com.apple.WebKit.WebContent.xpc/Contents/MacOS/com.apple.WebKit.WebContent";
const ENHANCED: &str = "/System/Library/Frameworks/WebKit.framework/Versions/A/XPCServices/com.apple.WebKit.WebContent.EnhancedSecurity.xpc/Contents/MacOS/com.apple.WebKit.WebContent.EnhancedSecurity";
const XPC: &str = "/Applications/Foo.app/Contents/XPCServices/FooHelper.xpc/Contents/MacOS/FooHelper";
const NODE: &str = "/usr/local/bin/node";
const TERMINAL: &str = "/System/Applications/Utilities/Terminal.app/Contents/MacOS/Terminal";

fn p(pid: i32, ppid: i32, path: &str, cpu: f32, mem: u64) -> ProcInfo {
    ProcInfo {
        pid,
        ppid,
        comm: path.rsplit('/').next().unwrap_or("").chars().take(16).collect(),
        start_sec: 1000 + pid as u64,
        path: Some(path.to_string()),
        readable: true,
        cpu_pct: Some(cpu),
        memory: Some(mem),
        energy_w: Some(cpu / 100.0),
        wakeups_per_s: Some(1.0),
        disk_bps: Some(0.0),
        ..Default::default()
    }
}

fn tree() -> Vec<ProcInfo> {
    let mut v = vec![
        ProcInfo { pid: 0, comm: "kernel_task".into(), readable: false, ..Default::default() },
        p(100, 1, CHROME, 10.0, 500),
        p(300, 1, SAFARI, 2.0, 100),
        p(301, 1, WEBCONTENT, 5.0, 200),
        p(302, 1, ENHANCED, 1.0, 50),
        p(400, 1, XPC, 0.5, 10),
        p(500, 1, TERMINAL, 0.1, 30),
        p(501, 500, "/bin/zsh", 0.0, 5),
        p(502, 501, NODE, 30.0, 300),
    ];
    for i in 0..40 {
        v.push(p(1000 + i, 100, HELPER, 1.0, 20));
    }
    v
}

#[test]
fn chrome_is_one_row_with_child_count() {
    let mut r = Resolver::default();
    let apps = r.rollup(&tree(), &[], 99999, Weights::default());
    let chrome = apps.iter().find(|a| a.name == "Google Chrome").expect("chrome row");
    assert_eq!(chrome.procs, 41);
    assert_eq!(chrome.kind, Kind::App);
    assert_eq!(chrome.root_pid, 100);
    assert_eq!(chrome.cpu, Some(50.0));
    assert_eq!(chrome.memory, 500 + 40 * 20);
    assert_eq!(chrome.children.len(), 41);
    assert!(chrome.force_quit_ok);
    assert_eq!(apps.iter().filter(|a| a.path.contains("Chrome")).count(), 1);
}

#[test]
fn webkit_content_rolls_into_safari_when_running() {
    let mut r = Resolver::default();
    let apps = r.rollup(&tree(), &[], 99999, Weights::default());
    let safari = apps.iter().find(|a| a.name == "Safari").expect("safari row");
    assert_eq!(safari.procs, 3, "Safari + WebContent + EnhancedSecurity");
    assert!(!safari.force_quit_ok, "Safari lives under /System");
    assert!(safari.quit_ok);
    assert!(!apps.iter().any(|a| a.name == "WebKit"));
}

#[test]
fn webkit_content_groups_as_webkit_without_safari() {
    let procs: Vec<ProcInfo> = tree().into_iter().filter(|p| p.pid != 300).collect();
    let mut r = Resolver::default();
    let apps = r.rollup(&procs, &[], 99999, Weights::default());
    let wk = apps.iter().find(|a| a.name == "WebKit").expect("webkit row");
    assert_eq!(wk.procs, 2);
    assert_eq!(wk.kind, Kind::System);
}

#[test]
fn xpc_service_rolls_up_by_path() {
    let mut r = Resolver::default();
    let apps = r.rollup(&tree(), &[], 99999, Weights::default());
    let foo = apps.iter().find(|a| a.name == "Foo").expect("foo row");
    assert_eq!(foo.path, "/Applications/Foo.app");
}

#[test]
fn shell_children_roll_into_terminal_and_kernel_task_stands_alone() {
    let mut r = Resolver::default();
    let mole_top = vec![sysmon_core::mole::Process { pid: 0, name: "kernel_task".into(), cpu: 12.5, memory_bytes: 0, ..Default::default() }];
    let apps = r.rollup(&tree(), &mole_top, 502, Weights::default());
    let term = apps.iter().find(|a| a.name == "Terminal").expect("terminal row");
    assert_eq!(term.procs, 3);
    assert!(term.is_self, "self pid 502 is node under Terminal");
    let k = apps.iter().find(|a| a.name == "kernel_task").expect("kernel_task row");
    assert_eq!(k.procs, 1);
    assert_eq!(k.kind, Kind::System);
    assert_eq!(k.cpu, Some(12.5));
    assert_eq!(k.cpu_source, "mole");
    assert!(!k.quit_ok);
}

#[test]
fn bundle_root_takes_outermost_app() {
    assert_eq!(bundle_root(HELPER), Some("/Applications/Google Chrome.app"));
    assert_eq!(bundle_root(XPC), Some("/Applications/Foo.app"));
    assert_eq!(bundle_root("/Volumes/My.app.backup/Contents/x"), None);
    assert_eq!(bundle_root(NODE), None);
    assert!(force_quit_ok("/Applications/X.app/Contents/MacOS/X"));
    assert!(!force_quit_ok("/usr/libexec/foo"));
}

#[test]
fn identity_cache_survives_across_ticks() {
    let mut r = Resolver::default();
    let a = r.rollup(&tree(), &[], 1, Weights::default());
    let b = r.rollup(&tree(), &[], 1, Weights::default());
    assert_eq!(a.len(), b.len());
    assert_eq!(a.iter().map(|x| &x.key).collect::<Vec<_>>(), b.iter().map(|x| &x.key).collect::<Vec<_>>());
}

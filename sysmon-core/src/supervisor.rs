//! Owns the `mo status --watch` child: spawn, read lines, restart with
//! backoff, park after repeated failure, and never leave an orphan behind.
//! The `mo` wrapper execs into `status-go`, so the pid we spawn is the pid
//! that streams and one SIGTERM is enough.

use std::collections::VecDeque;
use std::io::{BufRead, BufReader};
use std::process::{Command, Stdio};
use std::sync::atomic::{AtomicBool, AtomicI32, AtomicU32, AtomicU64, Ordering};
use std::sync::mpsc::Sender;
use std::sync::{Arc, Mutex, MutexGuard};
use std::time::{Duration, Instant};

pub const MAX_FAILURES: u32 = 5;
const STDERR_LINES: usize = 200;
const HEALTHY_AFTER: Duration = Duration::from_secs(10);
const KILL_GRACE: Duration = Duration::from_secs(2);

pub enum Event {
    Line(String),
    Spawned(i32),
    Exited { failures: u32 },
    GaveUp,
    Stop,
}

pub struct Supervisor {
    mo_path: Mutex<Option<String>>,
    pub interval_secs: AtomicU64,
    stop: AtomicBool,
    restart: AtomicBool,
    child_pid: AtomicI32,
    stderr: Mutex<VecDeque<String>>,
    state: Mutex<&'static str>,
    pub failures: AtomicU32,
    stream: AtomicBool,
}

fn lock<T>(m: &Mutex<T>) -> MutexGuard<'_, T> {
    m.lock().unwrap_or_else(|p| p.into_inner())
}

impl Supervisor {
    pub fn new(mo_path: Option<String>, interval_secs: u64) -> Arc<Self> {
        Arc::new(Self {
            mo_path: Mutex::new(mo_path),
            interval_secs: AtomicU64::new(interval_secs.max(1)),
            stop: AtomicBool::new(false),
            restart: AtomicBool::new(false),
            child_pid: AtomicI32::new(0),
            stderr: Mutex::new(VecDeque::with_capacity(STDERR_LINES)),
            state: Mutex::new("starting"),
            failures: AtomicU32::new(0),
            stream: AtomicBool::new(true),
        })
    }

    pub fn state(&self) -> &'static str {
        *lock(&self.state)
    }

    fn set_state(&self, s: &'static str) {
        *lock(&self.state) = s;
    }

    pub fn mo_path(&self) -> Option<String> {
        lock(&self.mo_path).clone()
    }

    pub fn child_pid(&self) -> Option<i32> {
        match self.child_pid.load(Ordering::Relaxed) {
            0 => None,
            p => Some(p),
        }
    }

    pub fn stderr_lines(&self) -> Vec<String> {
        lock(&self.stderr).iter().cloned().collect()
    }

    fn push_stderr(&self, line: String) {
        let mut q = lock(&self.stderr);
        if q.len() >= STDERR_LINES {
            q.pop_front();
        }
        q.push_back(line);
    }

    /// Applies a new interval or binary path; the child restarts on change
    /// and the restart is not counted as a failure.
    pub fn reconfigure(&self, mo_path: Option<String>, interval_secs: u64, stream: bool) {
        let interval_secs = interval_secs.max(1);
        let mut changed = self.interval_secs.swap(interval_secs, Ordering::Relaxed) != interval_secs;
        changed |= self.stream.swap(stream, Ordering::Relaxed) != stream;
        {
            let mut cur = lock(&self.mo_path);
            if *cur != mo_path {
                *cur = mo_path;
                changed = true;
            }
        }
        if changed {
            self.failures.store(0, Ordering::Relaxed);
            self.restart.store(true, Ordering::Relaxed);
            self.kill_child();
        }
    }

    pub fn stop(&self) {
        self.stop.store(true, Ordering::Relaxed);
        self.kill_child();
    }

    fn kill_child(&self) {
        let pid = self.child_pid.load(Ordering::Relaxed);
        if pid > 0 {
            // SAFETY: signalling our own child by pid.
            unsafe { libc::kill(pid, libc::SIGTERM) };
        }
    }

    fn stopping(&self) -> bool {
        self.stop.load(Ordering::Relaxed)
    }

    fn sleep_checking(&self, d: Duration) {
        let end = Instant::now() + d;
        while Instant::now() < end && !self.stopping() && !self.restart.load(Ordering::Relaxed) {
            std::thread::sleep(Duration::from_millis(100));
        }
    }

    pub fn run(self: Arc<Self>, tx: Sender<Event>) {
        let mut backoff = 1u64;
        while !self.stopping() {
            let Some(path) = self.mo_path() else {
                self.set_state("missing");
                self.restart.store(false, Ordering::Relaxed);
                self.sleep_checking(Duration::from_secs(1));
                continue;
            };
            if !self.stream.load(Ordering::Relaxed) {
                self.set_state("paused");
                self.restart.store(false, Ordering::Relaxed);
                self.sleep_checking(Duration::from_secs(1));
                continue;
            }
            let interval = self.interval_secs.load(Ordering::Relaxed).max(1);
            self.restart.store(false, Ordering::Relaxed);
            let spawned = Command::new(&path)
                .args(["status", "--watch", "--interval", &format!("{interval}s"), "--proc-cpu-alerts=false"])
                .stdin(Stdio::null())
                .stdout(Stdio::piped())
                .stderr(Stdio::piped())
                .spawn();
            let mut child = match spawned {
                Ok(c) => c,
                Err(e) => {
                    self.push_stderr(format!("spawn {path}: {e}"));
                    let failures = self.failures.fetch_add(1, Ordering::Relaxed) + 1;
                    let _ = tx.send(Event::Exited { failures });
                    if failures >= MAX_FAILURES {
                        self.park(&tx);
                        backoff = 1;
                        continue;
                    }
                    self.set_state("restarting");
                    self.sleep_checking(Duration::from_secs(backoff));
                    backoff = (backoff * 2).min(30);
                    continue;
                }
            };
            let pid = child.id() as i32;
            self.child_pid.store(pid, Ordering::Relaxed);
            self.set_state("running");
            let _ = tx.send(Event::Spawned(pid));
            let started = Instant::now();
            let mut lines = 0u64;

            if let Some(err) = child.stderr.take() {
                let me = Arc::clone(&self);
                std::thread::Builder::new()
                    .name("mole-stderr".into())
                    .spawn(move || {
                        for l in BufReader::new(err).lines().map_while(Result::ok) {
                            me.push_stderr(l);
                        }
                    })
                    .ok();
            }
            if let Some(out) = child.stdout.take() {
                for l in BufReader::new(out).lines() {
                    match l {
                        Ok(l) => {
                            lines += 1;
                            if tx.send(Event::Line(l)).is_err() {
                                self.stop.store(true, Ordering::Relaxed);
                            }
                        }
                        Err(_) => break,
                    }
                    if self.stopping() || self.restart.load(Ordering::Relaxed) {
                        break;
                    }
                }
            }

            self.kill_child();
            let deadline = Instant::now() + KILL_GRACE;
            loop {
                match child.try_wait() {
                    Ok(Some(_)) => break,
                    Ok(None) if Instant::now() < deadline => std::thread::sleep(Duration::from_millis(50)),
                    _ => {
                        let _ = child.kill();
                        let _ = child.wait();
                        break;
                    }
                }
            }
            self.child_pid.store(0, Ordering::Relaxed);

            if self.stopping() {
                break;
            }
            if self.restart.load(Ordering::Relaxed) {
                backoff = 1;
                continue;
            }
            let healthy = lines > 0 && started.elapsed() >= HEALTHY_AFTER;
            let failures = if healthy {
                self.failures.store(0, Ordering::Relaxed);
                backoff = 1;
                0
            } else {
                self.failures.fetch_add(1, Ordering::Relaxed) + 1
            };
            let _ = tx.send(Event::Exited { failures });
            if failures >= MAX_FAILURES {
                self.park(&tx);
                backoff = 1;
                continue;
            }
            self.set_state("restarting");
            self.sleep_checking(Duration::from_secs(backoff));
            backoff = (backoff * 2).min(30);
        }
        self.child_pid.store(0, Ordering::Relaxed);
        self.set_state("stopped");
    }

    fn park(&self, tx: &Sender<Event>) {
        self.set_state("failed");
        let _ = tx.send(Event::GaveUp);
        while !self.stopping() && !self.restart.load(Ordering::Relaxed) {
            std::thread::sleep(Duration::from_millis(250));
        }
        self.failures.store(0, Ordering::Relaxed);
    }
}

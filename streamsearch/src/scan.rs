//! Chunked, multi-threaded scan with ordered output and cooperative cancel.
//!
//! The searched range is cut into chunks. Each chunk owns the matches that
//! START inside it and reads `overlap` extra bytes past its end so a match
//! straddling the boundary is still found whole. One byte before the chunk is
//! read as well so `^`, `\b` and look-behind see the real context. Workers
//! scan chunks in parallel; results are emitted strictly in search order.

use crate::cli::Config;
use crate::engine::{EngineError, Matcher};
use std::collections::{BTreeMap, VecDeque};
use std::fmt;
use std::fs::File;
use std::io::{self, Write};
use std::os::fd::RawFd;
use std::os::unix::fs::FileExt;
use std::sync::atomic::{AtomicBool, AtomicU64, Ordering};
use std::sync::{Condvar, Mutex, MutexGuard};
use std::time::{Duration, Instant};

/// How far ahead of the emitter workers may run, in chunks per worker. Bounds
/// the memory held in finished-but-not-yet-emitted results.
const LOOKAHEAD_PER_WORKER: u64 = 2;
/// Granularity of the stdout-closed check and of the progress timer.
const WATCH_TICK_MS: i32 = 10;

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct Hit {
    pub start: u64,
    pub end: u64,
    /// The match reached the end of the overlap window, so it may be longer.
    pub truncated: bool,
}

#[derive(Debug)]
pub enum SearchError {
    Read { offset: u64, source: io::Error },
    Engine(EngineError),
    Output(io::Error),
}

impl fmt::Display for SearchError {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            Self::Read { offset, source } => write!(f, "read at offset {offset}: {source}"),
            Self::Engine(e) => e.fmt(f),
            Self::Output(e) => write!(f, "write to stdout: {e}"),
        }
    }
}

impl std::error::Error for SearchError {}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct Plan {
    forward: bool,
    /// Forward: first offset searched. Backward: exclusive upper bound.
    anchor: u64,
    /// Bytes in the searched range.
    pub range: u64,
    chunk: u64,
    /// File length when the search started; later growth is not searched.
    file_len: u64,
}

impl Plan {
    pub fn new(cfg: &Config, file_len: u64) -> Self {
        let chunk = u64::try_from(cfg.chunk).unwrap_or(u64::MAX).max(1);
        let (anchor, range) = if cfg.backward {
            let hi = cfg.from.map_or(file_len, |f| f.min(file_len));
            (hi, hi)
        } else {
            let lo = cfg.from.unwrap_or(0).min(file_len);
            (lo, file_len.saturating_sub(lo))
        };
        Self {
            forward: !cfg.backward,
            anchor,
            range,
            chunk,
            file_len,
        }
    }

    pub fn chunks(&self) -> u64 {
        self.range.div_ceil(self.chunk)
    }

    /// Owned byte range `[lo, up)` of chunk `i`, in search order.
    pub fn bounds(&self, i: u64) -> (u64, u64) {
        let step = i.saturating_mul(self.chunk);
        if self.forward {
            let lo = self.anchor.saturating_add(step);
            (lo, lo.saturating_add(self.chunk).min(self.file_len))
        } else {
            let up = self.anchor.saturating_sub(step);
            (up.saturating_sub(self.chunk), up)
        }
    }
}

fn read_fully(file: &File, buf: &mut [u8], offset: u64) -> io::Result<usize> {
    let mut filled = 0usize;
    while filled < buf.len() {
        let Some(dst) = buf.get_mut(filled..) else {
            break;
        };
        match file.read_at(dst, offset.saturating_add(filled as u64)) {
            Ok(0) => break,
            Ok(n) => filled = filled.saturating_add(n),
            Err(e) if e.kind() == io::ErrorKind::Interrupted => {}
            Err(e) => return Err(e),
        }
    }
    Ok(filled)
}

struct ScanCtx<'a> {
    file: &'a File,
    matcher: &'a Matcher,
    plan: Plan,
    overlap: usize,
    /// Only the first `keep` matches of a chunk (forward) or the last `keep`
    /// (backward) can ever be emitted; 0 means all.
    keep: usize,
    forward: bool,
    stop: &'a AtomicBool,
}

/// Matches whose start lies in `[lo, up)`, ascending by start.
fn scan_chunk(
    ctx: &ScanCtx<'_>,
    lo: u64,
    up: u64,
    buf: &mut [u8],
) -> Result<Vec<Hit>, SearchError> {
    let read_start = lo.saturating_sub(1);
    let window_end = up.saturating_add(ctx.overlap as u64);
    let want = usize::try_from(window_end.saturating_sub(read_start))
        .unwrap_or(usize::MAX)
        .min(buf.len());
    let Some(dst) = buf.get_mut(..want) else {
        return Ok(Vec::new());
    };
    let filled = read_fully(ctx.file, dst, read_start).map_err(|source| SearchError::Read {
        offset: read_start,
        source,
    })?;
    let hay = buf.get(..filled).unwrap_or_default();
    let more_after_window = read_start.saturating_add(filled as u64) < ctx.plan.file_len;
    let owned_end = usize::try_from(up.saturating_sub(read_start)).unwrap_or(usize::MAX);
    let mut at = usize::try_from(lo.saturating_sub(read_start)).unwrap_or(0);

    let mut hits: VecDeque<Hit> = VecDeque::new();
    while at <= hay.len() {
        if ctx.stop.load(Ordering::Relaxed) {
            break;
        }
        let Some((s, e)) = ctx.matcher.find_at(hay, at).map_err(SearchError::Engine)? else {
            break;
        };
        if s >= owned_end {
            break;
        }
        // Empty matches carry no position worth showing, and would flood.
        at = if e > s { e } else { e.saturating_add(1) };
        if e == s {
            continue;
        }
        if ctx.keep > 0 && hits.len() >= ctx.keep {
            if ctx.forward {
                break;
            }
            hits.pop_front();
        }
        hits.push_back(Hit {
            start: read_start.saturating_add(s as u64),
            end: read_start.saturating_add(e as u64),
            truncated: more_after_window && e == hay.len(),
        });
    }
    Ok(hits.into())
}

struct State {
    next: u64,
    emitted: u64,
    pending: BTreeMap<u64, Vec<Hit>>,
    error: Option<SearchError>,
    workers_left: usize,
}

struct Shared {
    state: Mutex<State>,
    cv: Condvar,
    stop: AtomicBool,
    finished: AtomicBool,
    output_closed: AtomicBool,
    scanned: AtomicU64,
}

fn lock(m: &Mutex<State>) -> MutexGuard<'_, State> {
    // A panicking worker aborts the process (panic = "abort"); poison is not
    // reachable, and recovering the guard is still the right answer if it is.
    m.lock().unwrap_or_else(std::sync::PoisonError::into_inner)
}

fn worker(sh: &Shared, ctx: &ScanCtx<'_>, nchunks: u64, lookahead: u64, chunk_buf: usize) {
    let mut buf = vec![0u8; chunk_buf];
    loop {
        let idx = {
            let mut g = lock(&sh.state);
            while !sh.stop.load(Ordering::Relaxed) && g.next.saturating_sub(g.emitted) >= lookahead
            {
                g = sh
                    .cv
                    .wait(g)
                    .unwrap_or_else(std::sync::PoisonError::into_inner);
            }
            if sh.stop.load(Ordering::Relaxed) || g.next >= nchunks {
                g.workers_left = g.workers_left.saturating_sub(1);
                sh.cv.notify_all();
                return;
            }
            let i = g.next;
            g.next = g.next.saturating_add(1);
            i
        };
        let (lo, up) = ctx.plan.bounds(idx);
        let result = scan_chunk(ctx, lo, up, &mut buf);
        let mut g = lock(&sh.state);
        match result {
            Ok(hits) => {
                sh.scanned
                    .fetch_add(up.saturating_sub(lo), Ordering::Relaxed);
                g.pending.insert(idx, hits);
            }
            Err(e) => {
                g.error.get_or_insert(e);
                sh.stop.store(true, Ordering::Relaxed);
            }
        }
        sh.cv.notify_all();
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct Outcome {
    pub matches: u64,
    pub output_closed: bool,
}

fn stdout_hung_up(fd: RawFd) -> bool {
    let mut p = libc::pollfd {
        fd,
        events: 0,
        revents: 0,
    };
    // SAFETY: `p` is a valid pollfd for the one entry passed.
    let n = unsafe { libc::poll(&raw mut p, 1, WATCH_TICK_MS) };
    n > 0 && p.revents & (libc::POLLERR | libc::POLLHUP | libc::POLLNVAL) != 0
}

fn watcher(sh: &Shared, watch_fd: Option<RawFd>, progress_ms: u64, total: u64) {
    let every = Duration::from_millis(progress_ms);
    let mut last = Instant::now();
    while !sh.finished.load(Ordering::Relaxed) {
        match watch_fd {
            Some(fd) if stdout_hung_up(fd) => {
                sh.output_closed.store(true, Ordering::Relaxed);
                sh.stop.store(true, Ordering::Relaxed);
                let _guard = lock(&sh.state);
                sh.cv.notify_all();
                return;
            }
            Some(_) => {}
            None => std::thread::sleep(Duration::from_millis(WATCH_TICK_MS as u64)),
        }
        if progress_ms > 0 && last.elapsed() >= every {
            last = Instant::now();
            let scanned = sh.scanned.load(Ordering::Relaxed).min(total);
            let _ = writeln!(io::stderr(), "{{\"scanned\":{scanned},\"total\":{total}}}");
        }
    }
}

/// Run the search, writing JSON lines to `out` in search order.
pub fn run<W: Write>(
    cfg: &Config,
    matcher: &Matcher,
    file: &File,
    file_len: u64,
    out: &mut W,
    watch_fd: Option<RawFd>,
) -> Result<Outcome, SearchError> {
    let plan = Plan::new(cfg, file_len);
    let nchunks = plan.chunks();
    let threads = cfg
        .threads
        .max(1)
        .min(usize::try_from(nchunks).unwrap_or(usize::MAX).max(1));
    let lookahead = (threads as u64).saturating_mul(LOOKAHEAD_PER_WORKER).max(2);
    let keep = usize::try_from(cfg.limit).unwrap_or(usize::MAX);
    let chunk_buf = cfg.chunk.saturating_add(cfg.overlap).saturating_add(1);
    let sh = Shared {
        state: Mutex::new(State {
            next: 0,
            emitted: 0,
            pending: BTreeMap::new(),
            error: None,
            workers_left: threads,
        }),
        cv: Condvar::new(),
        stop: AtomicBool::new(false),
        finished: AtomicBool::new(false),
        output_closed: AtomicBool::new(false),
        scanned: AtomicU64::new(0),
    };
    let ctx = ScanCtx {
        file,
        matcher,
        plan,
        overlap: cfg.overlap,
        keep,
        forward: !cfg.backward,
        stop: &sh.stop,
    };

    let mut matches = 0u64;
    let mut write_error = None;
    std::thread::scope(|scope| {
        for _ in 0..threads {
            scope.spawn(|| worker(&sh, &ctx, nchunks, lookahead, chunk_buf));
        }
        scope.spawn(|| watcher(&sh, watch_fd, cfg.progress_ms, plan.range));

        'emit: loop {
            let hits = {
                let mut g = lock(&sh.state);
                loop {
                    let key = g.emitted;
                    if let Some(h) = g.pending.remove(&key) {
                        g.emitted = key.saturating_add(1);
                        sh.cv.notify_all();
                        break h;
                    }
                    if sh.stop.load(Ordering::Relaxed)
                        || g.workers_left == 0
                        || g.emitted >= nchunks
                    {
                        break 'emit;
                    }
                    g = sh
                        .cv
                        .wait(g)
                        .unwrap_or_else(std::sync::PoisonError::into_inner);
                }
            };
            let ordered: Vec<Hit> = if cfg.backward {
                hits.into_iter().rev().collect()
            } else {
                hits
            };
            for h in &ordered {
                let line = if h.truncated {
                    writeln!(
                        out,
                        "{{\"start\":{},\"end\":{},\"truncated\":true}}",
                        h.start, h.end
                    )
                } else {
                    writeln!(out, "{{\"start\":{},\"end\":{}}}", h.start, h.end)
                };
                if let Err(e) = line {
                    write_error = Some(e);
                    break 'emit;
                }
                matches = matches.saturating_add(1);
                if cfg.limit > 0 && matches >= cfg.limit {
                    let _ = out.flush();
                    break 'emit;
                }
            }
            if let Err(e) = out.flush() {
                write_error = Some(e);
                break 'emit;
            }
        }
        sh.stop.store(true, Ordering::Relaxed);
        sh.finished.store(true, Ordering::Relaxed);
        let _guard = lock(&sh.state);
        sh.cv.notify_all();
    });

    let _ = out.flush();
    let closed = sh.output_closed.load(Ordering::Relaxed);
    if cfg.progress_ms > 0 && !closed {
        let done = if nchunks == lock(&sh.state).emitted {
            plan.range
        } else {
            sh.scanned.load(Ordering::Relaxed).min(plan.range)
        };
        let _ = writeln!(
            io::stderr(),
            "{{\"scanned\":{done},\"total\":{}}}",
            plan.range
        );
    }
    if let Some(e) = lock(&sh.state).error.take() {
        return Err(e);
    }
    match write_error {
        Some(e) if e.kind() == io::ErrorKind::BrokenPipe => Ok(Outcome {
            matches,
            output_closed: true,
        }),
        Some(e) => Err(SearchError::Output(e)),
        None => Ok(Outcome {
            matches,
            output_closed: closed,
        }),
    }
}

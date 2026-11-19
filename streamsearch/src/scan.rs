//! Chunked, multi-threaded scan with ordered output and cooperative cancel.
//!
//! The searched range is cut into chunks. Each chunk owns the matches that
//! START inside it and reads `overlap` extra bytes past its end so a match
//! straddling the boundary is still found whole. One byte before the chunk is
//! read as well so `^`, `\b` and look-behind see the real context. Matching
//! starts `overlap` bytes before the chunk and drops matches that start
//! earlier, so a match straddling the boundary is not also reported as its
//! shorter suffix. Workers
//! scan chunks in parallel; results are emitted strictly in search order.

use crate::cli::Config;
use crate::engine::{EngineError, Matcher};
use crate::index::{Index, Query};
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
    /// Forward: exclusive end of owned starts. Backward: lowest owned start.
    limit: u64,
    /// Bytes in the searched range.
    pub range: u64,
    chunk: u64,
    /// File length when the search started; later growth is not searched.
    file_len: u64,
}

impl Plan {
    pub fn new(cfg: &Config, file_len: u64) -> Self {
        let chunk = u64::try_from(cfg.chunk).unwrap_or(u64::MAX).max(1);
        let (anchor, limit) = if cfg.backward {
            let hi = cfg.from.map_or(file_len, |f| f.min(file_len));
            (hi, cfg.to.unwrap_or(0).min(hi))
        } else {
            let lo = cfg.from.unwrap_or(0).min(file_len);
            (lo, cfg.to.map_or(file_len, |t| t.min(file_len)).max(lo))
        };
        let range = anchor.abs_diff(limit);
        Self {
            forward: !cfg.backward,
            anchor,
            limit,
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
            (lo, lo.saturating_add(self.chunk).min(self.limit))
        } else {
            let up = self.anchor.saturating_sub(step);
            (up.saturating_sub(self.chunk).max(self.limit), up)
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
    /// (backward) can ever be used; 0 means all.
    keep: usize,
    forward: bool,
    /// Record positions; otherwise only count.
    collect: bool,
    /// The pattern is one literal byte: no overlap window, no regex.
    byte: Option<u8>,
    /// Block index and the literal to look up in it.
    skip: Option<(&'a Index, &'a Query)>,
    /// Bytes of chunks the index ruled out.
    skipped: &'a AtomicU64,
    stop: &'a AtomicBool,
}

#[derive(Debug, Default)]
struct ChunkOut {
    count: u64,
    hits: Vec<Hit>,
}

fn read_window(
    ctx: &ScanCtx<'_>,
    start: u64,
    end: u64,
    buf: &mut [u8],
) -> Result<usize, SearchError> {
    let want = usize::try_from(end.saturating_sub(start))
        .unwrap_or(usize::MAX)
        .min(buf.len());
    let Some(dst) = buf.get_mut(..want) else {
        return Ok(0);
    };
    read_fully(ctx.file, dst, start).map_err(|source| SearchError::Read {
        offset: start,
        source,
    })
}

/// Occurrences of `byte`. The inner sum stays in a u8 (at most 255 terms) so
/// the compiler can vectorise it with byte-wide compares and a horizontal add.
fn count_byte(hay: &[u8], byte: u8) -> u64 {
    const LANE_SPAN: usize = 255;
    hay.chunks(LANE_SPAN)
        .map(|part| {
            let n = part
                .iter()
                .fold(0u8, |acc, &b| acc.wrapping_add(u8::from(b == byte)));
            u64::from(n)
        })
        .fold(0u64, u64::saturating_add)
}

/// One-byte pattern: the owned range is the whole window.
fn scan_byte(
    ctx: &ScanCtx<'_>,
    byte: u8,
    lo: u64,
    up: u64,
    buf: &mut [u8],
) -> Result<ChunkOut, SearchError> {
    let filled = read_window(ctx, lo, up, buf)?;
    let hay = buf.get(..filled).unwrap_or_default();
    if !ctx.collect {
        return Ok(ChunkOut {
            count: count_byte(hay, byte),
            hits: Vec::new(),
        });
    }
    let mut hits: VecDeque<Hit> = VecDeque::new();
    let mut count = 0u64;
    for pos in memchr::memchr_iter(byte, hay) {
        count = count.saturating_add(1);
        if ctx.keep > 0 && hits.len() >= ctx.keep {
            if ctx.forward {
                break;
            }
            hits.pop_front();
        }
        let start = lo.saturating_add(pos as u64);
        hits.push_back(Hit {
            start,
            end: start.saturating_add(1),
            truncated: false,
        });
    }
    Ok(ChunkOut {
        count,
        hits: hits.into(),
    })
}

/// Matches whose start lies in `[lo, up)`, ascending by start.
fn scan_chunk(
    ctx: &ScanCtx<'_>,
    lo: u64,
    up: u64,
    buf: &mut [u8],
) -> Result<ChunkOut, SearchError> {
    if let Some(byte) = ctx.byte {
        return scan_byte(ctx, byte, lo, up, buf);
    }
    if let Some((index, query)) = ctx.skip {
        if !index.may_match(query, lo, up) {
            ctx.skipped
                .fetch_add(up.saturating_sub(lo), Ordering::Relaxed);
            return Ok(ChunkOut::default());
        }
    }
    // A chunk cannot know where the previous one's last match ended, so it
    // starts matching `overlap` bytes early, discards what starts before
    // `lo`, and so lines up with a sequential scan once past any match that
    // straddles `lo`. Matches cannot be longer than the overlap window.
    let floor = if ctx.forward {
        ctx.plan.anchor
    } else {
        ctx.plan.limit
    };
    let warm = floor.max(lo.saturating_sub(ctx.overlap as u64));
    let read_start = warm.saturating_sub(1);
    let window_end = up.saturating_add(ctx.overlap as u64);
    let filled = read_window(ctx, read_start, window_end, buf)?;
    let hay = buf.get(..filled).unwrap_or_default();
    let more_after_window = read_start.saturating_add(filled as u64) < ctx.plan.file_len;
    let owned_end = usize::try_from(up.saturating_sub(read_start)).unwrap_or(usize::MAX);
    let mut at = usize::try_from(warm.saturating_sub(read_start)).unwrap_or(0);
    let owned_start = usize::try_from(lo.saturating_sub(read_start)).unwrap_or(usize::MAX);

    let mut hits: VecDeque<Hit> = VecDeque::new();
    let mut count = 0u64;
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
        if e == s || s < owned_start {
            continue;
        }
        count = count.saturating_add(1);
        if !ctx.collect {
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
    Ok(ChunkOut {
        count,
        hits: hits.into(),
    })
}

struct State {
    next: u64,
    emitted: u64,
    pending: BTreeMap<u64, ChunkOut>,
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
    skipped: AtomicU64,
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
            Ok(out) => {
                sh.scanned
                    .fetch_add(up.saturating_sub(lo), Ordering::Relaxed);
                g.pending.insert(idx, out);
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
enum Mode {
    Search,
    Count,
    Nth(u64),
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct Outcome {
    pub matches: u64,
    /// Every chunk of the whole file was consumed.
    pub complete: bool,
    /// Bytes the block index let the scan skip.
    pub skipped: u64,
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
    skip: Option<(&Index, &Query)>,
) -> Result<Outcome, SearchError> {
    let plan = Plan::new(cfg, file_len);
    let nchunks = plan.chunks();
    let threads = cfg
        .threads
        .max(1)
        .min(usize::try_from(nchunks).unwrap_or(usize::MAX).max(1));
    let lookahead = (threads as u64).saturating_mul(LOOKAHEAD_PER_WORKER).max(2);
    let mode = match (cfg.count, cfg.nth) {
        (true, _) => Mode::Count,
        (false, Some(n)) => Mode::Nth(n),
        (false, None) => Mode::Search,
    };
    let keep = usize::try_from(cfg.limit).unwrap_or(usize::MAX);
    let chunk_buf = cfg
        .chunk
        .saturating_add(cfg.overlap)
        .saturating_add(cfg.overlap)
        .saturating_add(1);
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
        skipped: AtomicU64::new(0),
    };
    let ctx = ScanCtx {
        file,
        matcher,
        plan,
        overlap: cfg.overlap,
        keep,
        forward: !cfg.backward,
        collect: mode == Mode::Search,
        byte: matcher.single_byte(),
        skip,
        skipped: &sh.skipped,
        stop: &sh.stop,
    };

    let mut matches = 0u64;
    let mut cumulative = 0u64;
    let mut nth_chunk: Option<(u64, u64)> = None;
    let mut write_error = None;
    std::thread::scope(|scope| {
        for _ in 0..threads {
            scope.spawn(|| worker(&sh, &ctx, nchunks, lookahead, chunk_buf));
        }
        scope.spawn(|| watcher(&sh, watch_fd, cfg.progress_ms, plan.range));

        'emit: loop {
            let (chunk_idx, chunk_out) = {
                let mut g = lock(&sh.state);
                loop {
                    let key = g.emitted;
                    if let Some(h) = g.pending.remove(&key) {
                        g.emitted = key.saturating_add(1);
                        sh.cv.notify_all();
                        break (key, h);
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
            match mode {
                Mode::Search => {}
                Mode::Count => {
                    matches = matches.saturating_add(chunk_out.count);
                    continue;
                }
                Mode::Nth(n) => {
                    let before = cumulative;
                    cumulative = cumulative.saturating_add(chunk_out.count);
                    if cumulative >= n {
                        nth_chunk = Some((chunk_idx, n.saturating_sub(before)));
                        break 'emit;
                    }
                    continue;
                }
            }
            let ordered: Vec<Hit> = if cfg.backward {
                chunk_out.hits.into_iter().rev().collect()
            } else {
                chunk_out.hits
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
        let skipped = sh.skipped.load(Ordering::Relaxed);
        let _ = if skip.is_some() {
            writeln!(
                io::stderr(),
                "{{\"scanned\":{done},\"total\":{},\"skipped\":{skipped}}}",
                plan.range
            )
        } else {
            writeln!(
                io::stderr(),
                "{{\"scanned\":{done},\"total\":{}}}",
                plan.range
            )
        };
    }
    if let Some(e) = lock(&sh.state).error.take() {
        return Err(e);
    }
    if mode == Mode::Count && !closed && write_error.is_none() {
        write_error = writeln!(out, "{{\"count\":{matches}}}")
            .and_then(|()| out.flush())
            .err();
    }
    if let (Some((idx, rank)), None, false) = (nth_chunk, &write_error, closed) {
        let idle = AtomicBool::new(false);
        let locate = ScanCtx {
            keep: usize::try_from(rank).unwrap_or(usize::MAX),
            collect: true,
            stop: &idle,
            ..ctx
        };
        let (lo, up) = plan.bounds(idx);
        let mut buf = vec![0u8; chunk_buf];
        let found = scan_chunk(&locate, lo, up, &mut buf)?.hits;
        // Forward keeps the first `rank` hits, backward the last `rank`.
        let hit = if cfg.backward {
            found.first()
        } else {
            found.last()
        };
        if let Some(h) = hit {
            write_error = writeln!(out, "{{\"start\":{},\"end\":{}}}", h.start, h.end)
                .and_then(|()| out.flush())
                .err();
            matches = 1;
        }
    }
    let complete = !closed
        && write_error.is_none()
        && plan.range == file_len
        && nchunks == lock(&sh.state).emitted;
    let skipped = sh.skipped.load(Ordering::Relaxed);
    match write_error {
        Some(e) if e.kind() == io::ErrorKind::BrokenPipe => Ok(Outcome {
            matches,
            complete: false,
            skipped,
            output_closed: true,
        }),
        Some(e) => Err(SearchError::Output(e)),
        None => Ok(Outcome {
            matches,
            complete,
            skipped,
            output_closed: closed,
        }),
    }
}

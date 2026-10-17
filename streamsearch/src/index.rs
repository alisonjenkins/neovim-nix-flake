//! Persistent per-file block index: one trigram bloom filter per block.
//!
//! A search whose pattern requires a literal of three or more bytes asks the
//! index which chunks can hold it and skips the others without reading them.
//! The index only ever answers "definitely not here"; any doubt (missing,
//! stale, unreadable, corrupt) means "scan it".
//!
//! Layout: a 128 byte header, then `nblocks` records of a bloom (`bloom_bytes`)
//! followed by an 8 byte checksum of it, so a damaged bloom is detected and
//! scanned instead of trusted.
//! Bloom `i` holds every trigram that STARTS in block `i`, including the two
//! bytes it reads into block `i + 1`. The header records the identity of the
//! indexed file (device, inode, size, mtime and ctime in nanoseconds) and is
//! written last, after the data, then the file is renamed into place, so a
//! reader never sees a partial index. Any change to the file changes its
//! ctime and so invalidates the index.

use std::fs::{self, File, Metadata, OpenOptions};
use std::io::{self, ErrorKind};
use std::os::fd::AsRawFd;
use std::os::unix::fs::{FileExt, MetadataExt, OpenOptionsExt};
use std::path::{Path, PathBuf};
use std::sync::atomic::{AtomicBool, AtomicU64, Ordering};
use std::sync::Mutex;
use std::time::{Duration, SystemTime};

pub const DEFAULT_BLOCK: u64 = 1 << 20;
pub const DEFAULT_MIN_FILE: u64 = 64 << 20;
const HEADER_LEN: usize = 128;
const MAGIC: &[u8; 8] = b"SSIDX001";
const HASHES: usize = 2;
/// Longest literal prefix used: also keeps a literal within two blocks.
const MAX_NEEDLE: usize = 128;
const MIN_NEEDLE: usize = 3;
const SUM_LEN: usize = 8;
const MIN_BLOCK: u64 = 256;
/// A build lock older than this belongs to a dead builder.
const LOCK_STALE: Duration = Duration::from_secs(3600);

/// What identifies a file's content for the index: any write changes ctime.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct Identity {
    dev: u64,
    ino: u64,
    size: u64,
    mtime: (i64, i64),
    ctime: (i64, i64),
}

impl Identity {
    pub fn of(meta: &Metadata) -> Self {
        Self {
            dev: meta.dev(),
            ino: meta.ino(),
            size: meta.len(),
            mtime: (meta.mtime(), meta.mtime_nsec()),
            ctime: (meta.ctime(), meta.ctime_nsec()),
        }
    }
}

/// Word-at-a-time checksum for bloom records: fast enough to verify every
/// record a query touches.
fn sum64(bytes: &[u8]) -> u64 {
    let (words, rest) = bytes.as_chunks::<8>();
    let mut h = 0x9E37_79B9_7F4A_7C15u64;
    for w in words {
        let v = u64::from_le_bytes(*w);
        h = (h ^ v).wrapping_mul(0xBF58_476D_1CE4_E5B9).rotate_left(29);
    }
    for &b in rest {
        h = (h ^ u64::from(b)).wrapping_mul(0x0100_0000_01b3);
    }
    h
}

fn fnv1a(bytes: &[u8]) -> u64 {
    bytes.iter().fold(0xcbf2_9ce4_8422_2325, |h, &b| {
        (h ^ u64::from(b)).wrapping_mul(0x0100_0000_01b3)
    })
}

fn rd_u64(b: &[u8], off: usize) -> Option<u64> {
    let s = b.get(off..off.checked_add(8)?)?;
    Some(u64::from_le_bytes(s.try_into().ok()?))
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
struct Header {
    ident: Identity,
    block: u64,
    bloom_bytes: u64,
    nblocks: u64,
}

impl Header {
    fn new(ident: Identity, block: u64) -> Self {
        Self {
            ident,
            block,
            bloom_bytes: bloom_bytes_for(block),
            nblocks: ident.size.div_ceil(block),
        }
    }

    fn encode(&self) -> Vec<u8> {
        let mut out = Vec::with_capacity(HEADER_LEN);
        out.extend_from_slice(MAGIC);
        for v in [
            self.ident.dev,
            self.ident.ino,
            self.ident.size,
            self.ident.mtime.0 as u64,
            self.ident.mtime.1 as u64,
            self.ident.ctime.0 as u64,
            self.ident.ctime.1 as u64,
            self.block,
            self.bloom_bytes,
            HASHES as u64,
            self.nblocks,
        ] {
            out.extend_from_slice(&v.to_le_bytes());
        }
        let sum = fnv1a(&out);
        out.extend_from_slice(&sum.to_le_bytes());
        out.resize(HEADER_LEN, 0);
        out
    }

    fn decode(b: &[u8]) -> Option<Self> {
        if b.get(..8)? != MAGIC {
            return None;
        }
        let f = |i: usize| rd_u64(b, 8usize.checked_add(i.checked_mul(8)?)?);
        let sum_at = 8usize.checked_add(11usize.checked_mul(8)?)?;
        if rd_u64(b, sum_at)? != fnv1a(b.get(..sum_at)?) || f(9)? != HASHES as u64 {
            return None;
        }
        let h = Self {
            ident: Identity {
                dev: f(0)?,
                ino: f(1)?,
                size: f(2)?,
                mtime: (f(3)? as i64, f(4)? as i64),
                ctime: (f(5)? as i64, f(6)? as i64),
            },
            block: f(7)?,
            bloom_bytes: f(8)?,
            nblocks: f(10)?,
        };
        let sane = h.block >= MIN_BLOCK
            && h.block.is_power_of_two()
            && h.bloom_bytes == bloom_bytes_for(h.block)
            && h.nblocks == h.ident.size.div_ceil(h.block);
        sane.then_some(h)
    }

    fn file_len(&self) -> Option<u64> {
        self.nblocks
            .checked_mul(self.record_len())?
            .checked_add(HEADER_LEN as u64)
    }

    fn record_len(&self) -> u64 {
        self.bloom_bytes.saturating_add(SUM_LEN as u64)
    }
}

/// About 1% of the block, a multiple of 8.
fn bloom_bytes_for(block: u64) -> u64 {
    (block / 100).saturating_add(7) & !7
}

fn bit_positions(tri: u32, bits: u64) -> [u64; HASHES] {
    let mut x = u64::from(tri).wrapping_mul(0x9E37_79B9_7F4A_7C15);
    x ^= x >> 29;
    x = x.wrapping_mul(0xBF58_476D_1CE4_E5B9);
    x ^= x >> 32;
    [
        (x & 0xFFFF_FFFF).checked_rem(bits).unwrap_or(0),
        (x >> 32).checked_rem(bits).unwrap_or(0),
    ]
}

fn trigram(w: &[u8]) -> Option<u32> {
    match w {
        [a, b, c, ..] => Some(u32::from(*a) << 16 | u32::from(*b) << 8 | u32::from(*c)),
        _ => None,
    }
}

fn test_bit(bloom: &[u8], bit: u64) -> bool {
    let byte = usize::try_from(bit >> 3).unwrap_or(usize::MAX);
    bloom.get(byte).is_some_and(|b| b & (1 << (bit & 7)) != 0)
}

/// Where the index of `file` lives, or `None` when there is no usable cache
/// directory.
pub fn cache_path(file: &Path) -> Option<PathBuf> {
    let base = std::env::var_os("STREAMSEARCH_CACHE_DIR")
        .map(PathBuf::from)
        .or_else(|| {
            std::env::var_os("XDG_CACHE_HOME")
                .filter(|v| !v.is_empty())
                .map(|v| PathBuf::from(v).join("streamsearch"))
        })
        .or_else(|| {
            std::env::var_os("HOME")
                .filter(|v| !v.is_empty())
                .map(|v| PathBuf::from(v).join(".cache").join("streamsearch"))
        })?;
    let canonical = fs::canonicalize(file).ok()?;
    let name = format!(
        "{:016x}.ssi",
        fnv1a(std::os::unix::ffi::OsStrExt::as_bytes(
            canonical.as_os_str()
        ))
    );
    Some(base.join(name))
}

pub struct Index {
    file: File,
    header: Header,
}

/// A literal that every match must contain, hashed for one index.
pub struct Query {
    bits: Vec<[u64; HASHES]>,
    /// How far past a chunk the literal can sit: 0 when the literal is the
    /// whole match, else the overlap window.
    margin: u64,
}

impl Index {
    /// Open the index at `path` if it describes exactly the file `ident`.
    pub fn open_valid(path: &Path, ident: &Identity) -> Option<Self> {
        let file = File::open(path).ok()?;
        // The index is about 1% of the file: pull it in ahead of the lookups.
        // SAFETY: the descriptor is open; advice on it cannot fault.
        unsafe { libc::posix_fadvise(file.as_raw_fd(), 0, 0, libc::POSIX_FADV_WILLNEED) };
        let mut head = [0u8; HEADER_LEN];
        file.read_exact_at(&mut head, 0).ok()?;
        let header = Header::decode(&head)?;
        let len = file.metadata().ok()?.len();
        (header.ident == *ident && header.file_len() == Some(len)).then_some(Self { file, header })
    }

    /// Prepare a query for `literal`; `None` when it is too short to help.
    pub fn query(&self, literal: &[u8], exact: bool, overlap: u64) -> Option<Query> {
        let cap = MAX_NEEDLE.min(usize::try_from(self.header.block / 2).unwrap_or(MAX_NEEDLE));
        let prefix = literal.get(..literal.len().min(cap))?;
        if prefix.len() < MIN_NEEDLE {
            return None;
        }
        let bits = self.header.bloom_bytes.checked_mul(8)?;
        let tri: Vec<[u64; HASHES]> = prefix
            .windows(3)
            .filter_map(trigram)
            .map(|t| bit_positions(t, bits))
            .collect();
        // A prefix of an exact literal is still the match start; any other
        // regex can place the literal anywhere inside the match.
        let margin = if exact && prefix.len() == literal.len() {
            0
        } else {
            overlap
        };
        Some(Query { bits: tri, margin })
    }

    /// False only when no match starting in `[lo, up)` can exist.
    pub fn may_match(&self, q: &Query, lo: u64, up: u64) -> bool {
        self.check(q, lo, up).unwrap_or(true)
    }

    fn check(&self, q: &Query, lo: u64, up: u64) -> Option<bool> {
        let h = &self.header;
        let end = up.saturating_add(q.margin).min(h.ident.size);
        if lo >= end {
            return None;
        }
        let first = lo.checked_div(h.block)?;
        let last = end.saturating_sub(1).checked_div(h.block)?;
        let read_last = last.saturating_add(1).min(h.nblocks.checked_sub(1)?);
        let count = read_last.checked_sub(first)?.checked_add(1)?;
        let bb = usize::try_from(h.bloom_bytes).ok()?;
        let stride = bb.checked_add(SUM_LEN)?;
        let mut buf = vec![0u8; usize::try_from(count).ok()?.checked_mul(stride)?];
        let at = first
            .checked_mul(h.record_len())?
            .checked_add(HEADER_LEN as u64)?;
        self.file.read_exact_at(&mut buf, at).ok()?;
        let mut blooms = Vec::new();
        for record in buf.chunks_exact(stride) {
            let (bloom, sum) = record.split_at(bb);
            if rd_u64(sum, 0)? != sum64(bloom) {
                return None;
            }
            blooms.push(bloom);
        }
        let mut blooms = blooms.into_iter();
        let mut cur = blooms.next()?;
        for _ in first..=last {
            let next = blooms.next();
            if candidate(&q.bits, cur, next) {
                return Some(true);
            }
            cur = next.unwrap_or_default();
        }
        Some(false)
    }
}

/// Can the literal start in the block with bloom `cur`? A literal that runs
/// into the next block has its first trigrams in `cur` and the rest in `next`.
fn candidate(tri: &[[u64; HASHES]], cur: &[u8], next: Option<&[u8]>) -> bool {
    let has = |bloom: &[u8], t: &[u64; HASHES]| t.iter().all(|&b| test_bit(bloom, b));
    let in_cur = tri.iter().take_while(|t| has(cur, t)).count();
    if in_cur == tri.len() {
        return true;
    }
    let Some(next) = next else { return false };
    let in_next = tri.iter().rev().take_while(|t| has(next, t)).count();
    // Split after `s` trigrams: s in cur, the remaining tri.len() - s in next.
    let lowest = tri.len().saturating_sub(in_next).max(1);
    let highest = in_cur.min(tri.len().saturating_sub(1));
    lowest <= highest
}

#[derive(Debug)]
pub enum BuildOutcome {
    Built {
        bytes: u64,
        blocks: u64,
    },
    /// Another builder holds the lock.
    Busy,
}

struct Lock(PathBuf);

impl Lock {
    fn take(path: &Path) -> io::Result<Option<Self>> {
        match OpenOptions::new()
            .write(true)
            .create_new(true)
            .mode(0o600)
            .open(path)
        {
            Ok(_) => Ok(Some(Self(path.to_path_buf()))),
            Err(e) if e.kind() == ErrorKind::AlreadyExists => {
                let stale = fs::metadata(path)
                    .and_then(|m| m.modified())
                    .ok()
                    .and_then(|t| SystemTime::now().duration_since(t).ok())
                    .is_some_and(|age| age > LOCK_STALE);
                if stale {
                    let _ = fs::remove_file(path);
                }
                Ok(None)
            }
            Err(e) => Err(e),
        }
    }
}

impl Drop for Lock {
    fn drop(&mut self) {
        let _ = fs::remove_file(&self.0);
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
            Err(e) if e.kind() == ErrorKind::Interrupted => {}
            Err(e) => return Err(e),
        }
    }
    Ok(filled)
}

/// Build the index of `src` at `dest`, replacing any older one. Fails, leaving
/// nothing behind, if the file changes while it is read.
pub fn build(
    src: &File,
    dest: &Path,
    block: u64,
    threads: usize,
    cancel: &AtomicBool,
) -> io::Result<BuildOutcome> {
    if block < MIN_BLOCK || !block.is_power_of_two() {
        return Err(io::Error::new(
            ErrorKind::InvalidInput,
            "index block must be a power of two of at least 256 bytes",
        ));
    }
    let ident = Identity::of(&src.metadata()?);
    let header = Header::new(ident, block);
    let dir = dest
        .parent()
        .ok_or_else(|| io::Error::new(ErrorKind::InvalidInput, "index path has no directory"))?;
    fs::create_dir_all(dir)?;
    let _ = fs::set_permissions(dir, std::os::unix::fs::PermissionsExt::from_mode(0o700));
    let Some(_lock) = Lock::take(&dest.with_extension("lock"))? else {
        return Ok(BuildOutcome::Busy);
    };
    let tmp = dest.with_extension(format!("tmp{}", std::process::id()));
    let out = OpenOptions::new()
        .write(true)
        .create(true)
        .truncate(true)
        .mode(0o600)
        .open(&tmp)?;
    let result = fill(src, &out, &header, threads, cancel).and_then(|()| {
        if Identity::of(&src.metadata()?) != ident {
            return Err(io::Error::other("file changed while indexing"));
        }
        out.write_all_at(&header.encode(), 0)?;
        fs::rename(&tmp, dest)
    });
    if result.is_err() {
        let _ = fs::remove_file(&tmp);
    }
    result?;
    Ok(BuildOutcome::Built {
        bytes: header.file_len().unwrap_or(0),
        blocks: header.nblocks,
    })
}

fn fill(src: &File, out: &File, h: &Header, threads: usize, cancel: &AtomicBool) -> io::Result<()> {
    out.set_len(
        h.file_len()
            .ok_or_else(|| io::Error::other("index too large"))?,
    )?;
    let next = AtomicU64::new(0);
    let failure: Mutex<Option<io::Error>> = Mutex::new(None);
    let block = usize::try_from(h.block).map_err(io::Error::other)?;
    let bb = usize::try_from(h.bloom_bytes).map_err(io::Error::other)?;
    let bits = h.bloom_bytes.saturating_mul(8);
    std::thread::scope(|scope| {
        for _ in 0..threads.max(1) {
            scope.spawn(|| {
                // Two bytes past the block so trigrams that start inside it are whole.
                let mut buf = vec![0u8; block.saturating_add(2)];
                let mut record = vec![0u8; bb.saturating_add(SUM_LEN)];
                loop {
                    let b = next.fetch_add(1, Ordering::Relaxed);
                    if b >= h.nblocks || cancel.load(Ordering::Relaxed) {
                        return;
                    }
                    let res = (|| {
                        let n = read_fully(src, &mut buf, b.saturating_mul(h.block))?;
                        record.fill(0);
                        let own = n.min(block.saturating_add(2));
                        for w in buf.get(..own).unwrap_or_default().windows(3) {
                            let Some(t) = trigram(w) else { continue };
                            for bit in bit_positions(t, bits) {
                                if let Some(byte) =
                                    record.get_mut(usize::try_from(bit >> 3).unwrap_or(usize::MAX))
                                {
                                    *byte |= 1 << (bit & 7);
                                }
                            }
                        }
                        let sum = sum64(record.get(..bb).unwrap_or_default());
                        if let Some(tail) = record.get_mut(bb..) {
                            tail.copy_from_slice(&sum.to_le_bytes());
                        }
                        out.write_all_at(
                            &record,
                            (HEADER_LEN as u64).saturating_add(b.saturating_mul(h.record_len())),
                        )
                    })();
                    if let Err(e) = res {
                        failure
                            .lock()
                            .unwrap_or_else(std::sync::PoisonError::into_inner)
                            .get_or_insert(e);
                        cancel.store(true, Ordering::Relaxed);
                        return;
                    }
                }
            });
        }
    });
    if let Some(e) = failure
        .lock()
        .unwrap_or_else(std::sync::PoisonError::into_inner)
        .take()
    {
        return Err(e);
    }
    if cancel.load(Ordering::Relaxed) {
        return Err(io::Error::new(
            ErrorKind::Interrupted,
            "index build cancelled",
        ));
    }
    Ok(())
}

#[cfg(test)]
#[allow(
    clippy::unwrap_used,
    clippy::indexing_slicing,
    clippy::arithmetic_side_effects
)]
mod tests {
    use super::*;
    use std::io::Write;

    fn sample(dir: &Path, data: &[u8]) -> (PathBuf, File) {
        let p = dir.join("f.dat");
        std::fs::write(&p, data).unwrap();
        (p.clone(), File::open(&p).unwrap())
    }

    fn built(data: &[u8], block: u64) -> (tempfile::TempDir, Index, Identity) {
        let d = tempfile::tempdir().unwrap();
        let (_, f) = sample(d.path(), data);
        let dest = d.path().join("c").join("x.ssi");
        let r = build(&f, &dest, block, 3, &AtomicBool::new(false)).unwrap();
        assert!(matches!(r, BuildOutcome::Built { .. }));
        let ident = Identity::of(&f.metadata().unwrap());
        let idx = Index::open_valid(&dest, &ident).unwrap();
        (d, idx, ident)
    }

    #[test]
    fn header_round_trips_and_rejects_damage() {
        let ident = Identity {
            dev: 1,
            ino: 2,
            size: 3000,
            mtime: (-5, 6),
            ctime: (7, 8),
        };
        let h = Header::new(ident, 1024);
        let bytes = h.encode();
        assert_eq!(Header::decode(&bytes), Some(h));
        for i in 0..96 {
            let mut bad = bytes.clone();
            bad[i] ^= 1;
            assert_eq!(Header::decode(&bad), None, "flip byte {i}");
        }
    }

    #[test]
    fn never_skips_a_block_that_holds_the_literal() {
        let mut data = vec![b'.'; 8192];
        for (k, at) in [0usize, 200, 250, 600, 1023, 1100, 3000, 8180]
            .into_iter()
            .enumerate()
        {
            let lit = format!("NEEDLE{k}");
            data[at..at + lit.len()].copy_from_slice(lit.as_bytes());
        }
        let (_d, idx, _) = built(&data, 256);
        for (k, at) in [0usize, 200, 250, 600, 1023, 1100, 3000, 8180]
            .into_iter()
            .enumerate()
        {
            let lit = format!("NEEDLE{k}");
            let q = idx.query(lit.as_bytes(), true, 0).unwrap();
            let lo = (at as u64 / 256) * 256;
            assert!(idx.may_match(&q, lo, lo + 256), "literal {lit} at {at}");
            assert!(idx.may_match(&q, at as u64, at as u64 + 1), "{lit} start");
        }
        let q = idx.query(b"NEEDLE9", true, 0).unwrap();
        assert!(
            !idx.may_match(&q, 1024, 2048),
            "absent literal should be skipped"
        );
    }

    #[test]
    fn margin_extends_the_search_past_the_chunk() {
        let mut data = vec![b'.'; 4096];
        data[1030..1036].copy_from_slice(b"MARKER");
        let (_d, idx, _) = built(&data, 256);
        let exact = idx.query(b"MARKER", true, 600).unwrap();
        assert!(
            !idx.may_match(&exact, 0, 1024),
            "exact literal starts at its chunk"
        );
        let inner = idx.query(b"MARKER", false, 600).unwrap();
        assert!(
            idx.may_match(&inner, 0, 1024),
            "regex match may start 600 bytes earlier"
        );
        assert!(!idx.may_match(&inner, 0, 256), "but not 800");
    }

    #[test]
    fn any_change_invalidates() {
        let d = tempfile::tempdir().unwrap();
        let (p, f) = sample(d.path(), &vec![b'a'; 5000]);
        let dest = d.path().join("x.ssi");
        build(&f, &dest, 256, 2, &AtomicBool::new(false)).unwrap();
        let ident = Identity::of(&f.metadata().unwrap());
        assert!(Index::open_valid(&dest, &ident).is_some());
        let mut app = OpenOptions::new().append(true).open(&p).unwrap();
        app.write_all(b"more").unwrap();
        drop(app);
        let after = Identity::of(&std::fs::metadata(&p).unwrap());
        assert!(Index::open_valid(&dest, &after).is_none(), "appended");
        let (p2, f2) = sample(d.path(), &vec![b'a'; 5000]);
        build(&f2, &dest, 256, 2, &AtomicBool::new(false)).unwrap();
        // Same size, content rewritten in place: ctime moves even if mtime is restored.
        let w = OpenOptions::new().write(true).open(&p2).unwrap();
        let before = f2.metadata().unwrap();
        w.write_all_at(b"Z", 17).unwrap();
        let mtime = before.modified().unwrap();
        w.set_modified(mtime).unwrap();
        let after = Identity::of(&std::fs::metadata(&p2).unwrap());
        assert_eq!(after.size, before.len());
        assert!(
            Index::open_valid(&dest, &after).is_none(),
            "rewritten in place"
        );
    }

    #[test]
    fn corrupt_or_truncated_index_is_ignored() {
        let (d, idx, ident) = built(&vec![b'q'; 4000], 256);
        drop(idx);
        let dest = d.path().join("c").join("x.ssi");
        let len = std::fs::metadata(&dest).unwrap().len();
        let f = OpenOptions::new().write(true).open(&dest).unwrap();
        f.set_len(len - 1).unwrap();
        assert!(Index::open_valid(&dest, &ident).is_none(), "truncated");
        f.set_len(len).unwrap();
        f.write_all_at(b"\xff", 3).unwrap();
        assert!(Index::open_valid(&dest, &ident).is_none(), "bad magic");
        std::fs::write(&dest, b"garbage").unwrap();
        assert!(Index::open_valid(&dest, &ident).is_none(), "garbage");
    }

    #[test]
    fn rejects_tiny_blocks_and_short_literals() {
        let d = tempfile::tempdir().unwrap();
        let (_, f) = sample(d.path(), b"abc");
        let err = build(&f, &d.path().join("x.ssi"), 100, 1, &AtomicBool::new(false));
        assert!(err.is_err());
        let (_d, idx, _) = built(b"abcdef", 256);
        assert!(idx.query(b"ab", true, 0).is_none());
    }
}

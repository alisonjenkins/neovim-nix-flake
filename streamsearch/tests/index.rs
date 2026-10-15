//! The block index must never change an answer, only skip work.
#![allow(
    clippy::unwrap_used,
    clippy::expect_used,
    clippy::indexing_slicing,
    clippy::arithmetic_side_effects,
    clippy::panic
)]

use std::fs::OpenOptions;
use std::io::Write;
use std::os::unix::fs::FileExt;
use std::path::{Path, PathBuf};
use std::process::{Command, Stdio};
use std::time::{Duration, Instant};

const BIN: &str = env!("CARGO_BIN_EXE_streamsearch");
const BLOCK: &str = "16384";

struct Rng(u64);
impl Rng {
    fn next(&mut self) -> u64 {
        self.0 ^= self.0 << 13;
        self.0 ^= self.0 >> 7;
        self.0 ^= self.0 << 17;
        self.0
    }
}

struct Env {
    dir: tempfile::TempDir,
}

impl Env {
    fn new() -> Self {
        Self {
            dir: tempfile::tempdir().unwrap(),
        }
    }
    fn cache(&self) -> PathBuf {
        self.dir.path().join("cache")
    }
    fn file(&self) -> PathBuf {
        self.dir.path().join("data.bin")
    }
    fn cmd(&self, args: &[&str]) -> Command {
        let mut c = Command::new(BIN);
        c.env("STREAMSEARCH_CACHE_DIR", self.cache())
            .args(args)
            .arg(self.file());
        c
    }
    /// (matches, skipped bytes from the final progress line, exit code)
    fn search(&self, args: &[&str]) -> (Vec<(u64, u64)>, u64, i32) {
        let out = self.cmd(args).stdin(Stdio::null()).output().unwrap();
        let spans = String::from_utf8(out.stdout)
            .unwrap()
            .lines()
            .filter_map(|l| {
                let num = |key: &str| -> Option<u64> {
                    let at = l.find(key)? + key.len();
                    l[at..]
                        .chars()
                        .take_while(char::is_ascii_digit)
                        .collect::<String>()
                        .parse()
                        .ok()
                };
                Some((num("\"start\":")?, num("\"end\":")?))
            })
            .collect();
        let err = String::from_utf8(out.stderr).unwrap();
        let skipped = err
            .lines()
            .last()
            .and_then(|l| l.split("\"skipped\":").nth(1))
            .and_then(|r| r.trim_end_matches('}').parse().ok())
            .unwrap_or(0);
        (spans, skipped, out.status.code().unwrap())
    }
    fn build(&self) {
        let out = self
            .cmd(&[
                "--index",
                "build",
                "--index-block-bytes",
                BLOCK,
                "--threads",
                "3",
                "x",
            ])
            .output()
            .unwrap();
        assert_eq!(
            out.status.code(),
            Some(0),
            "{}",
            String::from_utf8_lossy(&out.stderr)
        );
    }
    fn index_files(&self) -> Vec<PathBuf> {
        std::fs::read_dir(self.cache())
            .map(|d| {
                d.filter_map(Result::ok)
                    .map(|e| e.path())
                    .filter(|p| p.extension().is_some_and(|x| x == "ssi"))
                    .collect()
            })
            .unwrap_or_default()
    }
}

fn find_all(data: &[u8], pat: &[u8]) -> Vec<(u64, u64)> {
    (0..data.len().saturating_sub(pat.len() - 1))
        .filter(|&i| data[i..].starts_with(pat))
        .map(|i| (i as u64, (i + pat.len()) as u64))
        .collect()
}

/// Low-entropy filler plus rare tokens at awkward offsets.
fn corpus(rng: &mut Rng) -> (Vec<u8>, Vec<&'static str>) {
    let mut data: Vec<u8> = (0..400_000)
        .map(|_| b"abcd\n"[(rng.next() % 5) as usize])
        .collect();
    let tokens = ["ZQJ-one", "ZQJ-two", "ZQJ-three", "ZQJ-four"];
    // Offsets around 256-byte block edges and a 100-byte chunk edge.
    let at = [
        0usize,
        16_384 - 3,
        3 * 16_384 + 5,
        100_000,
        2 * 16_384 + 2,
        399_990,
    ];
    for (k, o) in at.iter().enumerate() {
        let t = tokens[k % tokens.len()].as_bytes();
        data[*o..*o + t.len()].copy_from_slice(t);
    }
    // A regex match that starts in one block and holds the literal in the next.
    data[2 * 16_384 - 2..2 * 16_384 + 2].copy_from_slice(b"abca");
    (data, tokens.to_vec())
}

#[test]
fn indexed_answers_equal_unindexed_and_the_model() {
    let env = Env::new();
    let mut rng = Rng(0xfeed);
    let (data, tokens) = corpus(&mut rng);
    std::fs::write(env.file(), &data).unwrap();
    env.build();
    assert_eq!(env.index_files().len(), 1);

    let common = [
        "--chunk-bytes",
        "4096",
        "--max-match-bytes",
        "64",
        "--threads",
        "3",
        "--progress-ms",
        "1000000",
    ];
    for tok in &tokens {
        let want = find_all(&data, tok.as_bytes());
        for mode in ["--fixed", "--regex"] {
            let mut on = vec![mode, "--index", "auto"];
            on.extend(common);
            on.push(tok);
            let mut off = vec![mode, "--index", "off"];
            off.extend(common);
            off.push(tok);
            let (a, skipped, _) = env.search(&on);
            let (b, _, _) = env.search(&off);
            assert_eq!(a, want, "{mode} {tok} indexed");
            assert_eq!(b, want, "{mode} {tok} unindexed");
            assert!(
                skipped > 200_000,
                "{mode} {tok}: only {skipped} bytes skipped"
            );
        }
        let mut back = vec!["--fixed", "--backward"];
        back.extend(common);
        back.push(tok);
        let mut rev = want.clone();
        rev.reverse();
        assert_eq!(env.search(&back).0, rev, "backward {tok}");
    }
    // Regex with the literal inside the match: the match start precedes the literal.
    let (hits, skipped, _) = env.search(&[
        "--regex",
        "--chunk-bytes",
        "4096",
        "--max-match-bytes",
        "64",
        "[abcd]{4}ZQJ-one",
        "--progress-ms",
        "1000000",
    ]);
    let re = regex_model(&data, b"ZQJ-one", 4);
    assert!(
        re.iter().any(|m| m.0 == 2 * 16_384 - 2),
        "planted case missing from the model"
    );
    assert_eq!(hits, re);
    assert!(skipped > 0);
    // Count and nth go through the same skip.
    let (_, _, code) = env.search(&["--fixed", "--count", "ZQJ-two"]);
    assert_eq!(code, 0);
    let (nth, _, _) = env.search(&[
        "--fixed",
        "--nth",
        "1",
        "ZQJ-three",
        "--chunk-bytes",
        "4096",
    ]);
    assert_eq!(nth, find_all(&data, b"ZQJ-three")[..1].to_vec());
    // An absent literal is skipped entirely.
    let (none, skipped, code) = env.search(&[
        "--fixed",
        "--chunk-bytes",
        "4096",
        "ZQJ-absent",
        "--progress-ms",
        "1000000",
    ]);
    assert!(none.is_empty());
    assert_eq!(code, 1);
    assert_eq!(skipped, data.len() as u64);
}

fn regex_model(data: &[u8], tok: &[u8], prefix: usize) -> Vec<(u64, u64)> {
    find_all(data, tok)
        .into_iter()
        .filter(|(s, _)| {
            let s = *s as usize;
            s >= prefix && data[s - prefix..s].iter().all(|b| b"abcd".contains(b))
        })
        .map(|(s, e)| (s - prefix as u64, e))
        .collect()
}

#[test]
fn a_stale_index_is_never_trusted() {
    let env = Env::new();
    let mut rng = Rng(7);
    let (mut data, _) = corpus(&mut rng);
    std::fs::write(env.file(), &data).unwrap();
    env.build();

    // Append a token the index has never seen.
    let mut f = OpenOptions::new().append(true).open(env.file()).unwrap();
    f.write_all(b"ZQJ-appended").unwrap();
    drop(f);
    data.extend_from_slice(b"ZQJ-appended");
    let (hits, skipped, _) = env.search(&[
        "--fixed",
        "--chunk-bytes",
        "4096",
        "ZQJ-appended",
        "--progress-ms",
        "1000000",
    ]);
    assert_eq!(hits, find_all(&data, b"ZQJ-appended"), "appended");
    assert_eq!(skipped, 0, "stale index must not be consulted");

    // Same size, rewritten in place with the mtime put back.
    env.build();
    let before = std::fs::metadata(env.file()).unwrap();
    let w = OpenOptions::new().write(true).open(env.file()).unwrap();
    w.write_all_at(b"ZQJ-rewritten", 123_456).unwrap();
    w.set_modified(before.modified().unwrap()).unwrap();
    data[123_456..123_456 + 13].copy_from_slice(b"ZQJ-rewritten");
    let (hits, skipped, _) = env.search(&[
        "--fixed",
        "--chunk-bytes",
        "4096",
        "ZQJ-rewritten",
        "--progress-ms",
        "1000000",
    ]);
    assert_eq!(
        hits,
        find_all(&data, b"ZQJ-rewritten"),
        "rewritten in place"
    );
    assert_eq!(skipped, 0);

    // Replaced by a different file at the same path.
    env.build();
    let other = env.dir.path().join("other");
    std::fs::write(&other, &data).unwrap();
    std::fs::rename(&other, env.file()).unwrap();
    let (_, skipped, _) = env.search(&[
        "--fixed",
        "--chunk-bytes",
        "4096",
        "ZQJ-one",
        "--progress-ms",
        "1000000",
    ]);
    assert_eq!(skipped, 0, "replaced file");
}

#[test]
fn a_damaged_index_file_is_ignored() {
    let env = Env::new();
    let mut rng = Rng(11);
    let (data, _) = corpus(&mut rng);
    std::fs::write(env.file(), &data).unwrap();
    env.build();
    let idx = env.index_files().pop().unwrap();
    let want = find_all(&data, b"ZQJ-two");
    for damage in ["flip-header", "flip-bloom", "truncate", "garbage", "empty"] {
        env.build();
        let f = OpenOptions::new().write(true).open(&idx).unwrap();
        match damage {
            "flip-header" => f.write_all_at(b"\x07", 30).unwrap(),
            "flip-bloom" => f.write_all_at(b"\xff\xff\xff\xff", 400).unwrap(),
            "truncate" => f.set_len(500).unwrap(),
            "garbage" => std::fs::write(&idx, vec![0xAB; 4096]).unwrap(),
            _ => f.set_len(0).unwrap(),
        }
        let (hits, skipped, _) = env.search(&[
            "--fixed",
            "--chunk-bytes",
            "4096",
            "ZQJ-two",
            "--progress-ms",
            "1000000",
        ]);
        assert_eq!(hits, want, "{damage}");
        assert!(skipped < data.len() as u64, "{damage}: whole file skipped");
    }
}

#[test]
fn a_full_scan_builds_the_index_in_the_background() {
    let env = Env::new();
    let mut rng = Rng(21);
    let (data, _) = corpus(&mut rng);
    std::fs::write(env.file(), &data).unwrap();
    let args = [
        "--fixed",
        "--index-min-bytes",
        "0",
        "--index-block-bytes",
        BLOCK,
        "--chunk-bytes",
        "4096",
        "--progress-ms",
        "1000000",
        "ZQJ-absent",
    ];
    let (_, skipped, code) = env.search(&args);
    assert_eq!((skipped, code), (0, 1));
    let deadline = Instant::now() + Duration::from_secs(20);
    while env.index_files().is_empty() && Instant::now() < deadline {
        std::thread::sleep(Duration::from_millis(20));
    }
    assert_eq!(env.index_files().len(), 1, "index was not built");
    let (_, skipped, _) = env.search(&args);
    assert_eq!(skipped, data.len() as u64);

    // An early exit is not a full scan: no index for a second file.
    let env2 = Env::new();
    std::fs::write(env2.file(), &data).unwrap();
    let (hits, _, _) = env2.search(&[
        "--fixed",
        "--limit",
        "1",
        "--index-min-bytes",
        "0",
        "--index-block-bytes",
        BLOCK,
        "--chunk-bytes",
        "4096",
        "ZQJ-one",
    ]);
    assert_eq!(hits.len(), 1);
    std::thread::sleep(Duration::from_millis(300));
    assert!(env2.index_files().is_empty());
}

#[test]
fn off_never_reads_or_writes_the_cache() {
    let env = Env::new();
    let mut rng = Rng(5);
    let (data, _) = corpus(&mut rng);
    std::fs::write(env.file(), &data).unwrap();
    let (_, _, _) = env.search(&[
        "--fixed",
        "--index",
        "off",
        "--index-min-bytes",
        "0",
        "ZQJ-absent",
    ]);
    std::thread::sleep(Duration::from_millis(300));
    assert!(!Path::new(&env.cache()).exists());
}

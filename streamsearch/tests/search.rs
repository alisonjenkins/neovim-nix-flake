//! End-to-end tests: drive the real binary and compare with a naive model.
#![allow(
    clippy::unwrap_used,
    clippy::expect_used,
    clippy::indexing_slicing,
    clippy::arithmetic_side_effects,
    clippy::panic
)]

use std::fs::{File, OpenOptions};
use std::io::Read;
use std::os::unix::fs::FileExt;
use std::os::unix::process::ExitStatusExt;
use std::path::Path;
use std::process::{Command, Stdio};
use std::time::{Duration, Instant};

const BIN: &str = env!("CARGO_BIN_EXE_streamsearch");

struct Rng(u64);
impl Rng {
    fn next(&mut self) -> u64 {
        self.0 ^= self.0 << 13;
        self.0 ^= self.0 >> 7;
        self.0 ^= self.0 << 17;
        self.0
    }
    fn below(&mut self, n: u64) -> u64 {
        self.next() % n
    }
}

type Span = (u64, u64);

fn parse_lines(stdout: &[u8]) -> Vec<Span> {
    String::from_utf8(stdout.to_vec())
        .unwrap()
        .lines()
        .map(|l| {
            let num = |key: &str| -> u64 {
                let at = l.find(key).unwrap() + key.len();
                l[at..]
                    .chars()
                    .take_while(char::is_ascii_digit)
                    .collect::<String>()
                    .parse()
                    .unwrap()
            };
            (num("\"start\":"), num("\"end\":"))
        })
        .collect()
}

fn run(args: &[&str], file: &Path) -> (Vec<Span>, i32) {
    let out = Command::new(BIN)
        .args(args)
        .arg(file)
        .stderr(Stdio::null())
        .output()
        .unwrap();
    (parse_lines(&out.stdout), out.status.code().unwrap())
}

/// Naive: every position where the literal occurs. Valid as a model only for
/// patterns that cannot overlap themselves.
fn model(data: &[u8], pat: &[u8], ignore_case: bool) -> Vec<Span> {
    let fold = |b: u8| {
        if ignore_case {
            b.to_ascii_lowercase()
        } else {
            b
        }
    };
    (0..data.len().saturating_sub(pat.len().saturating_sub(1)))
        .filter(|&i| {
            pat.iter()
                .enumerate()
                .all(|(k, &p)| fold(data[i + k]) == fold(p))
        })
        .map(|i| (i as u64, (i + pat.len()) as u64))
        .collect()
}

fn write_file(dir: &Path, name: &str, data: &[u8]) -> std::path::PathBuf {
    let p = dir.join(name);
    std::fs::write(&p, data).unwrap();
    p
}

fn random_data(rng: &mut Rng, len: usize, alphabet: &[u8]) -> Vec<u8> {
    (0..len)
        .map(|_| alphabet[rng.below(alphabet.len() as u64) as usize])
        .collect()
}

fn dir() -> tempfile::TempDir {
    tempfile::tempdir().unwrap()
}

#[test]
fn fixed_random_matches_model_across_chunks_threads_overlaps() {
    let d = dir();
    let mut rng = Rng(0x1234_5678_9abc_def1);
    for round in 0..6 {
        let len = 500 + rng.below(4000) as usize;
        let data = random_data(&mut rng, len, b"abcd\n");
        let f = write_file(d.path(), "r.dat", &data);
        let want = model(&data, b"abc", false);
        assert!(!want.is_empty(), "round {round}: model found nothing");
        for chunk in ["1", "2", "3", "7", "64", "1000", "100000"] {
            for threads in ["1", "3", "8"] {
                let args = [
                    "--fixed",
                    "--chunk-bytes",
                    chunk,
                    "--threads",
                    threads,
                    "--max-match-bytes",
                    "2",
                    "--progress-ms",
                    "0",
                    "abc",
                ];
                let (fwd, code) = run(&args, &f);
                assert_eq!(fwd, want, "forward chunk={chunk} threads={threads}");
                assert_eq!(code, 0);
                let mut bargs = args.to_vec();
                bargs.insert(0, "--backward");
                let (back, _) = run(&bargs, &f);
                let mut rev = want.clone();
                rev.reverse();
                assert_eq!(back, rev, "backward chunk={chunk} threads={threads}");
            }
        }
    }
}

#[test]
fn regex_ignore_case_and_unicode_match_model() {
    let d = dir();
    let mut rng = Rng(77);
    let pieces: [&[u8]; 6] = [
        b"abc",
        b"ABC",
        "é".as_bytes(),
        "日本".as_bytes(),
        b" ",
        b"\n",
    ];
    let mut data = Vec::new();
    for _ in 0..3000 {
        data.extend_from_slice(pieces[rng.below(6) as usize]);
    }
    let f = write_file(d.path(), "u.dat", &data);
    let want = model(&data, b"abc", true);
    for chunk in ["5", "13", "4096"] {
        let (got, _) = run(
            &[
                "--regex",
                "--ignore-case",
                "--chunk-bytes",
                chunk,
                "--max-match-bytes",
                "8",
                "--progress-ms",
                "0",
                "abc",
            ],
            &f,
        );
        assert_eq!(got, want, "regex -i chunk={chunk}");
    }
    let want_u = model(&data, "日本".as_bytes(), false);
    let (got, _) = run(
        &[
            "--regex",
            "--chunk-bytes",
            "5",
            "--max-match-bytes",
            "8",
            "--progress-ms",
            "0",
            "日本",
        ],
        &f,
    );
    assert_eq!(got, want_u);
    let (sm, _) = run(
        &["--smart-case", "--fixed", "--progress-ms", "0", "ABC"],
        &f,
    );
    assert_eq!(sm, model(&data, b"ABC", false));
    let (sm, _) = run(
        &["--smart-case", "--fixed", "--progress-ms", "0", "abc"],
        &f,
    );
    assert_eq!(sm, want);
}

#[test]
fn straddling_every_boundary_offset() {
    let d = dir();
    let pat = b"NEEDLE-XYZ";
    let chunk = 64usize;
    for shift in 0..=pat.len() + 2 {
        let mut data = vec![b'.'; chunk * 4];
        let at = chunk * 2 - shift;
        data[at..at + pat.len()].copy_from_slice(pat);
        let f = write_file(d.path(), "s.dat", &data);
        let want = vec![(at as u64, (at + pat.len()) as u64)];
        for threads in ["1", "4"] {
            let args = [
                "--fixed",
                "--chunk-bytes",
                "64",
                "--threads",
                threads,
                "--max-match-bytes",
                "16",
                "--progress-ms",
                "0",
                "NEEDLE-XYZ",
            ];
            assert_eq!(run(&args, &f).0, want, "fixed shift={shift}");
            let rargs = [
                "--regex",
                "--chunk-bytes",
                "64",
                "--threads",
                threads,
                "--max-match-bytes",
                "16",
                "--progress-ms",
                "0",
                "NEEDLE-X.Z",
            ];
            assert_eq!(run(&rargs, &f).0, want, "regex shift={shift}");
            let pargs = [
                "--pcre",
                "--chunk-bytes",
                "64",
                "--threads",
                threads,
                "--max-match-bytes",
                "16",
                "--progress-ms",
                "0",
                "NEEDLE-(?=X)XYZ",
            ];
            assert_eq!(run(&pargs, &f).0, want, "pcre shift={shift}");
        }
    }
}

#[test]
fn overlap_edge_match_longer_than_window_is_not_found() {
    let d = dir();
    let mut data = vec![b'.'; 256];
    data[60..70].copy_from_slice(b"0123456789");
    let f = write_file(d.path(), "o.dat", &data);
    let base = [
        "--fixed",
        "--chunk-bytes",
        "64",
        "--threads",
        "1",
        "--progress-ms",
        "0",
    ];
    let mut ok = base.to_vec();
    ok.extend(["--max-match-bytes", "6", "0123456789"]);
    assert_eq!(
        run(&ok, &f).0,
        vec![(60, 70)],
        "needs overlap >= len-1 = 9 only if start is in the last byte"
    );
    let mut short = base.to_vec();
    short.extend(["--max-match-bytes", "2", "0123456789"]);
    let (got, code) = run(&short, &f);
    assert!(got.is_empty());
    assert_eq!(code, 1);
}

#[test]
fn truncated_regex_match_is_flagged() {
    let d = dir();
    let data = vec![b'a'; 5000];
    let f = write_file(d.path(), "t.dat", &data);
    let out = Command::new(BIN)
        .args([
            "--chunk-bytes",
            "1000",
            "--max-match-bytes",
            "100",
            "--threads",
            "1",
            "--limit",
            "1",
            "--progress-ms",
            "0",
            "a+",
        ])
        .arg(&f)
        .output()
        .unwrap();
    let text = String::from_utf8(out.stdout).unwrap();
    assert!(text.contains("\"truncated\":true"), "{text}");
}

#[test]
fn resume_and_limit_continue_without_rescanning() {
    let d = dir();
    let mut rng = Rng(5);
    let data = random_data(&mut rng, 5000, b"abcd");
    let f = write_file(d.path(), "m.dat", &data);
    let all = model(&data, b"abc", false);
    let base = [
        "--fixed",
        "--chunk-bytes",
        "97",
        "--max-match-bytes",
        "2",
        "--progress-ms",
        "0",
    ];
    let mut got = Vec::new();
    let mut from = 0u64;
    loop {
        let from_s = from.to_string();
        let mut args = base.to_vec();
        args.extend(["--limit", "7", "--from", &from_s, "abc"]);
        let (page, code) = run(&args, &f);
        if page.is_empty() {
            assert_eq!(code, 1);
            break;
        }
        assert!(page.len() <= 7);
        from = page.last().unwrap().0 + 1;
        got.extend(page);
    }
    assert_eq!(got, all);

    let mut got = Vec::new();
    let mut hi = data.len() as u64;
    loop {
        let hi_s = hi.to_string();
        let mut args = base.to_vec();
        args.extend(["--backward", "--limit", "5", "--from", &hi_s, "abc"]);
        let (page, _) = run(&args, &f);
        if page.is_empty() {
            break;
        }
        hi = page.last().unwrap().0;
        got.extend(page);
    }
    let mut rev = all;
    rev.reverse();
    assert_eq!(got, rev);
}

#[test]
fn invalid_utf8_and_nul_bytes() {
    let d = dir();
    let mut rng = Rng(99);
    let mut data: Vec<u8> = (0..20_000).map(|_| (rng.next() >> 8) as u8).collect();
    for at in [0usize, 331, 332, 333, 665, 19_997] {
        data[at..at + 3].copy_from_slice(&[0xff, 0x00, 0xfe]);
    }
    let f = write_file(d.path(), "b.dat", &data);
    let pat = [0xffu8, 0x00, 0xfe];
    let want = model(&data, &pat, false);
    assert!(!want.is_empty());
    let out = Command::new(BIN)
        .args([
            "--regex",
            "--chunk-bytes",
            "333",
            "--max-match-bytes",
            "4",
            "--progress-ms",
            "0",
            "(?-u:\\xff)\\x00(?-u:\\xfe)",
        ])
        .arg(&f)
        .output()
        .unwrap();
    assert_eq!(parse_lines(&out.stdout), want);

    use std::os::unix::ffi::OsStrExt;
    let raw = [0xffu8, 0xfe, 0xfd];
    for at in [10usize, 331, 332, 664, 12_000] {
        data[at..at + 3].copy_from_slice(&raw);
    }
    let f = write_file(d.path(), "b2.dat", &data);
    let want = model(&data, &raw, false);
    let out = Command::new(BIN)
        .args([
            "--fixed",
            "--chunk-bytes",
            "333",
            "--max-match-bytes",
            "4",
            "--progress-ms",
            "0",
        ])
        .arg(std::ffi::OsStr::from_bytes(&raw))
        .arg(&f)
        .output()
        .unwrap();
    assert_eq!(parse_lines(&out.stdout), want, "fixed raw-byte pattern");
}

#[test]
fn degenerate_files() {
    let d = dir();
    let empty = write_file(d.path(), "e.dat", b"");
    let (got, code) = run(&["--fixed", "--progress-ms", "0", "a"], &empty);
    assert!(got.is_empty());
    assert_eq!(code, 1);
    let short = write_file(d.path(), "sh.dat", b"xxabcxx");
    assert_eq!(
        run(&["--fixed", "--progress-ms", "0", "abc"], &short).0,
        vec![(2, 5)]
    );
    assert_eq!(
        run(
            &["--backward", "--fixed", "--progress-ms", "0", "abc"],
            &short
        )
        .0,
        vec![(2, 5)]
    );
    let (_, code) = run(
        &["--fixed", "--from", "100", "--progress-ms", "0", "abc"],
        &short,
    );
    assert_eq!(code, 1);
    let (_, code) = run(
        &["--fixed", "--progress-ms", "0", "abc"],
        &d.path().join("missing"),
    );
    assert_eq!(code, 2);
    let (_, code) = run(&["--regex", "--progress-ms", "0", "("], &short);
    assert_eq!(code, 2);
}

#[test]
fn anchors_respect_real_line_starts_across_chunks() {
    let d = dir();
    let mut data = Vec::new();
    for i in 0..200 {
        data.extend_from_slice(format!("line{i} foo\nxx foo line{i}\n").as_bytes());
    }
    let f = write_file(d.path(), "a.dat", &data);
    let (got, _) = run(
        &[
            "--regex",
            "--chunk-bytes",
            "17",
            "--max-match-bytes",
            "64",
            "--progress-ms",
            "0",
            "^line\\d+ foo$",
        ],
        &f,
    );
    assert_eq!(got.len(), 200);
}

fn sparse(dir: &Path, name: &str, len: u64, plants: &[(u64, &[u8])]) -> std::path::PathBuf {
    let p = dir.join(name);
    let f = File::create(&p).unwrap();
    f.set_len(len).unwrap();
    for (off, bytes) in plants {
        f.write_all_at(bytes, *off).unwrap();
    }
    p
}

fn peak_rss_kib(pid: u32) -> u64 {
    let s = std::fs::read_to_string(format!("/proc/{pid}/status")).unwrap_or_default();
    s.lines()
        .find(|l| l.starts_with("VmHWM:"))
        .and_then(|l| l.split_whitespace().nth(1))
        .and_then(|v| v.parse().ok())
        .unwrap_or(0)
}

#[test]
fn bounded_rss_on_large_sparse_file_and_single_giant_line() {
    let d = dir();
    let gib = 1u64 << 30;
    let plants: Vec<(u64, &[u8])> = vec![
        (7, b"PLANT-ONE"),
        (gib / 2 + 3, b"PLANT-TWO"),
        (gib - 9, b"PLANT-ONE"),
    ];
    // 1 GiB with no newline anywhere: one line.
    let f = sparse(d.path(), "line.dat", gib, &plants);
    for args in [
        vec!["--fixed", "PLANT-ONE"],
        vec!["--regex", "PLANT-(ONE|TWO)"],
        vec!["--regex", "--ignore-case", "plant-[a-z]+"],
        vec!["--pcre", "(?<=PLANT-)ONE"],
    ] {
        let mut child = Command::new(BIN)
            .args(&args)
            .args(["--progress-ms", "0"])
            .arg(&f)
            .stdout(Stdio::piped())
            .spawn()
            .unwrap();
        let pid = child.id();
        let mut peak = 0;
        let mut stdout = child.stdout.take().unwrap();
        let reader = std::thread::spawn(move || {
            let mut s = String::new();
            stdout.read_to_string(&mut s).unwrap();
            s
        });
        while child.try_wait().unwrap().is_none() {
            peak = peak.max(peak_rss_kib(pid));
            std::thread::sleep(Duration::from_millis(2));
        }
        let text = reader.join().unwrap();
        let spans = parse_lines(text.as_bytes());
        assert!(spans.len() >= 2, "{args:?}: {text}");
        assert!(peak < 200 * 1024, "{args:?}: peak RSS {peak} KiB");
        assert!(
            spans.iter().any(|s| s.0 >= 7 && s.0 <= 16),
            "{args:?}: {spans:?}"
        );
    }
    let (spans, _) = run(&["--fixed", "--progress-ms", "0", "PLANT-ONE"], &f);
    assert_eq!(spans, vec![(7, 16), (gib - 9, gib)]);
}

#[test]
fn early_exit_returns_before_the_scan_finishes() {
    let d = dir();
    let gib = 1u64 << 30;
    let f = sparse(d.path(), "e.dat", 4 * gib, &[(1000, b"FIRST-HIT")]);
    let t = Instant::now();
    let (got, _) = run(
        &["--fixed", "--limit", "1", "--progress-ms", "0", "FIRST-HIT"],
        &f,
    );
    assert_eq!(got, vec![(1000, 1009)]);
    assert!(
        t.elapsed() < Duration::from_secs(5),
        "took {:?}",
        t.elapsed()
    );
}

fn spawn_slow(f: &Path) -> std::process::Child {
    Command::new(BIN)
        .args([
            "--regex",
            "--threads",
            "2",
            "--progress-ms",
            "0",
            "(?i)[a-z]+nomatch[0-9]{3}",
        ])
        .arg(f)
        .stdout(Stdio::piped())
        .stderr(Stdio::null())
        .spawn()
        .unwrap()
}

#[test]
fn closing_stdout_cancels_quickly() {
    let d = dir();
    let f = sparse(d.path(), "c.dat", 16 * (1u64 << 30), &[]);
    let mut child = spawn_slow(&f);
    std::thread::sleep(Duration::from_millis(200));
    assert!(
        child.try_wait().unwrap().is_none(),
        "scan finished before it could be cancelled"
    );
    let t = Instant::now();
    drop(child.stdout.take());
    child.wait().unwrap();
    let took = t.elapsed();
    assert!(
        took < Duration::from_millis(500),
        "exit {took:?} after stdout closed"
    );
}

#[test]
fn sigterm_stops_immediately() {
    let d = dir();
    let f = sparse(d.path(), "k.dat", 16 * (1u64 << 30), &[]);
    let mut child = spawn_slow(&f);
    std::thread::sleep(Duration::from_millis(200));
    let t = Instant::now();
    // SAFETY: plain signal delivery to a child we own.
    unsafe { libc::kill(child.id() as i32, libc::SIGTERM) };
    let status = child.wait().unwrap();
    assert_eq!(status.signal(), Some(15));
    assert!(
        t.elapsed() < Duration::from_millis(200),
        "exit {:?}",
        t.elapsed()
    );
}

#[test]
fn truncation_while_searching_does_not_crash() {
    let d = dir();
    let f = sparse(d.path(), "g.dat", 8 * (1u64 << 30), &[]);
    let mut child = spawn_slow(&f);
    std::thread::sleep(Duration::from_millis(100));
    OpenOptions::new()
        .write(true)
        .open(&f)
        .unwrap()
        .set_len(1000)
        .unwrap();
    let status = child.wait().unwrap();
    assert!(status.signal().is_none(), "crashed: {status:?}");
    assert!(matches!(status.code(), Some(0 | 1)), "{status:?}");
}

#[test]
fn progress_lines_are_json() {
    let d = dir();
    let f = sparse(d.path(), "p.dat", 2 * (1u64 << 30), &[]);
    let out = Command::new(BIN)
        .args([
            "--regex",
            "--threads",
            "1",
            "--progress-ms",
            "20",
            "(?i)[a-z]+nomatch[0-9]{3}",
        ])
        .arg(&f)
        .output()
        .unwrap();
    let err = String::from_utf8(out.stderr).unwrap();
    let lines: Vec<&str> = err.lines().collect();
    assert!(lines.len() >= 2, "{err}");
    for l in &lines {
        assert!(
            l.starts_with("{\"scanned\":") && l.contains(",\"total\":") && l.ends_with('}'),
            "{l}"
        );
    }
    assert!(
        lines
            .last()
            .unwrap()
            .contains(&format!("\"scanned\":{}", 2u64 << 30)),
        "{err}"
    );
}

fn count_of(args: &[&str], file: &Path) -> u64 {
    let out = Command::new(BIN)
        .args(args)
        .arg(file)
        .stderr(Stdio::null())
        .output()
        .unwrap();
    assert_eq!(out.status.code(), Some(0), "{args:?}");
    let text = String::from_utf8(out.stdout).unwrap();
    text.trim()
        .strip_prefix("{\"count\":")
        .unwrap()
        .strip_suffix('}')
        .unwrap()
        .parse()
        .unwrap()
}

#[test]
fn count_matches_model_across_chunks_threads_and_ranges() {
    let d = dir();
    let mut rng = Rng(4242);
    let data = random_data(&mut rng, 6000, b"abcd\n");
    let f = write_file(d.path(), "c.dat", &data);
    let abc = model(&data, b"abc", false);
    let nl = model(&data, b"\n", false);
    for chunk in ["1", "5", "64", "1000", "100000"] {
        for threads in ["1", "3", "8"] {
            let base = [
                "--count",
                "--chunk-bytes",
                chunk,
                "--threads",
                threads,
                "--max-match-bytes",
                "2",
                "--progress-ms",
                "0",
            ];
            let mut a = base.to_vec();
            a.extend(["--fixed", "abc"]);
            assert_eq!(
                count_of(&a, &f),
                abc.len() as u64,
                "abc chunk={chunk} threads={threads}"
            );
            let mut r = base.to_vec();
            r.extend(["--regex", "a[bd]c"]);
            let a_c = (0..data.len() - 2)
                .filter(|&i| {
                    data[i] == b'a' && matches!(data[i + 1], b'b' | b'd') && data[i + 2] == b'c'
                })
                .count() as u64;
            assert_eq!(
                count_of(&r, &f),
                a_c,
                "a[bd]c chunk={chunk} threads={threads}"
            );
            let mut n = base.to_vec();
            n.extend(["--fixed", "\n"]);
            assert_eq!(
                count_of(&n, &f),
                nl.len() as u64,
                "newline chunk={chunk} threads={threads}"
            );
            let mut ranged = base.to_vec();
            ranged.extend(["--fixed", "--from", "1001", "--to", "4003", "\n"]);
            let want = nl.iter().filter(|s| s.0 >= 1001 && s.0 < 4003).count() as u64;
            assert_eq!(
                count_of(&ranged, &f),
                want,
                "ranged newline chunk={chunk} threads={threads}"
            );
            let mut back = base.to_vec();
            back.extend([
                "--backward",
                "--fixed",
                "--from",
                "4003",
                "--to",
                "1001",
                "\n",
            ]);
            assert_eq!(count_of(&back, &f), want, "backward ranged chunk={chunk}");
        }
    }
}

#[test]
fn nth_picks_the_nth_match_in_search_order() {
    let d = dir();
    let mut rng = Rng(31337);
    let data = random_data(&mut rng, 6000, b"abcd\n");
    let f = write_file(d.path(), "n.dat", &data);
    let nl = model(&data, b"\n", false);
    let abc = model(&data, b"abc", false);
    for chunk in ["1", "7", "64", "1000", "100000"] {
        for threads in ["1", "4"] {
            for n in [1usize, 2, 3, 50, nl.len() / 2, nl.len() - 1, nl.len()] {
                let ns = n.to_string();
                let base = [
                    "--nth",
                    &ns,
                    "--chunk-bytes",
                    chunk,
                    "--threads",
                    threads,
                    "--max-match-bytes",
                    "2",
                    "--progress-ms",
                    "0",
                ];
                let mut a = base.to_vec();
                a.extend(["--fixed", "\n"]);
                assert_eq!(
                    run(&a, &f).0,
                    vec![nl[n - 1]],
                    "newline n={n} chunk={chunk}"
                );
                let mut b = base.to_vec();
                b.extend(["--backward", "--fixed", "\n"]);
                assert_eq!(
                    run(&b, &f).0,
                    vec![nl[nl.len() - n]],
                    "backward newline n={n} chunk={chunk}"
                );
            }
            for n in [1usize, 2, abc.len() / 2, abc.len()] {
                let ns = n.to_string();
                let base = [
                    "--nth",
                    &ns,
                    "--chunk-bytes",
                    chunk,
                    "--threads",
                    threads,
                    "--max-match-bytes",
                    "2",
                    "--progress-ms",
                    "0",
                ];
                let mut a = base.to_vec();
                a.extend(["--fixed", "abc"]);
                assert_eq!(run(&a, &f).0, vec![abc[n - 1]], "abc n={n} chunk={chunk}");
                let mut b = base.to_vec();
                b.extend(["--backward", "--regex", "abc"]);
                assert_eq!(
                    run(&b, &f).0,
                    vec![abc[abc.len() - n]],
                    "backward abc n={n} chunk={chunk}"
                );
            }
            let too_many = (nl.len() + 1).to_string();
            let (got, code) = run(
                &[
                    "--nth",
                    &too_many,
                    "--fixed",
                    "--chunk-bytes",
                    chunk,
                    "--threads",
                    threads,
                    "--progress-ms",
                    "0",
                    "\n",
                ],
                &f,
            );
            assert!(got.is_empty());
            assert_eq!(code, 1);
        }
    }
    let (got, _) = run(
        &[
            "--nth",
            "2",
            "--from",
            "100",
            "--fixed",
            "--chunk-bytes",
            "9",
            "--progress-ms",
            "0",
            "\n",
        ],
        &f,
    );
    let after: Vec<Span> = nl.iter().copied().filter(|s| s.0 >= 100).collect();
    assert_eq!(got, vec![after[1]]);
    let (_, code) = run(&["--nth", "0", "--fixed", "x"], &f);
    assert_eq!(code, 2);
}

#[test]
fn count_and_nth_on_a_giant_single_line_stay_bounded() {
    let d = dir();
    let gib = 1u64 << 30;
    let plants: Vec<(u64, &[u8])> = vec![(5, b"Q"), (gib / 3, b"Q"), (gib - 1, b"Q")];
    let f = sparse(d.path(), "q.dat", gib, &plants);
    let mut child = Command::new(BIN)
        .args(["--fixed", "--count", "--progress-ms", "0", "Q"])
        .arg(&f)
        .stdout(Stdio::null())
        .spawn()
        .unwrap();
    let pid = child.id();
    let mut peak = 0;
    while child.try_wait().unwrap().is_none() {
        peak = peak.max(peak_rss_kib(pid));
        std::thread::sleep(Duration::from_millis(2));
    }
    assert!(peak < 200 * 1024, "peak RSS {peak} KiB");
    assert_eq!(
        count_of(&["--fixed", "--count", "--progress-ms", "0", "Q"], &f),
        3
    );
    assert_eq!(
        run(&["--fixed", "--nth", "3", "--progress-ms", "0", "Q"], &f).0,
        vec![(gib - 1, gib)]
    );
    assert_eq!(
        run(
            &[
                "--fixed",
                "--backward",
                "--nth",
                "3",
                "--progress-ms",
                "0",
                "Q"
            ],
            &f
        )
        .0,
        vec![(5, 6)]
    );
    assert_eq!(
        run(&["--fixed", "--nth", "4", "--progress-ms", "0", "Q"], &f).1,
        1
    );
}

fn search_with(engine: &str, pat: &str, chunk: usize, data: &[u8], d: &Path) -> Vec<Span> {
    let f = write_file(d, "c.dat", data);
    let chunk = chunk.to_string();
    let args = [
        engine,
        "--chunk-bytes",
        &chunk,
        "--threads",
        "1",
        "--progress-ms",
        "0",
        pat,
    ];
    run(&args, &f).0
}

#[test]
fn match_across_chunk_boundary_is_reported_once() {
    let d = dir();
    let data = b"xxaaaaaayy\n";
    for (engine, pat) in [("--regex", "a+"), ("--regex", "[a-z]+"), ("--fixed", "aa")] {
        let want = search_with(engine, pat, 1 << 20, data, d.path());
        for chunk in 1..=20 {
            assert_eq!(
                search_with(engine, pat, chunk, data, d.path()),
                want,
                "{engine} {pat} chunk={chunk}"
            );
        }
    }
    assert_eq!(
        search_with("--regex", "a+", 3, data, d.path()),
        vec![(2, 8)]
    );
    assert_eq!(
        search_with("--fixed", "aa", 3, data, d.path()),
        vec![(2, 4), (4, 6), (6, 8)]
    );
    let f = write_file(d.path(), "n.dat", data);
    let n = count_of(
        &[
            "--regex",
            "--chunk-bytes",
            "3",
            "--threads",
            "1",
            "--count",
            "a+",
        ],
        &f,
    );
    assert_eq!(n, 1);
}

#[test]
fn pcre_is_utf8_aware_like_regex() {
    let d = dir();
    let data = "café\n".as_bytes();
    let want = search_with("--regex", "[é]", 1 << 20, data, d.path());
    assert_eq!(want, vec![(3, 5)]);
    for chunk in 1..=8 {
        assert_eq!(
            search_with("--pcre", "[é]", chunk, data, d.path()),
            want,
            "pcre chunk={chunk}"
        );
    }
}

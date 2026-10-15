//! Command line parsing. Hand-rolled: the surface is small and the pattern
//! must stay raw bytes, which argument crates do not guarantee.

use std::ffi::OsString;
use std::os::unix::ffi::{OsStrExt, OsStringExt};
use std::path::PathBuf;

pub const DEFAULT_OVERLAP: usize = 64 * 1024;
pub const DEFAULT_CHUNK: usize = 2 * 1024 * 1024;
const MAX_THREADS: usize = 8;
const DEFAULT_PROGRESS_MS: u64 = 250;

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Syntax {
    Fixed,
    Regex,
    Pcre,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Case {
    Sensitive,
    Ignore,
    Smart,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum IndexMode {
    Auto,
    Off,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Config {
    pub syntax: Syntax,
    pub case: Case,
    pub backward: bool,
    pub from: Option<u64>,
    /// 0 means unlimited.
    pub limit: u64,
    pub overlap: usize,
    pub threads: usize,
    pub index: IndexMode,
    pub progress_ms: u64,
    pub chunk: usize,
    pub pattern: Vec<u8>,
    pub file: PathBuf,
}

#[derive(Debug, PartialEq, Eq)]
pub enum CliError {
    Help,
    Usage(String),
}

pub const USAGE: &str =
    "usage: streamsearch [--fixed|--regex|--pcre] [--ignore-case|--smart-case] [--backward]
                    [--from OFFSET] [--limit N] [--max-match-bytes N] [--threads N]
                    [--index auto|off] [--progress-ms N] [--chunk-bytes N] PATTERN FILE
stdout: one JSON object per match {\"start\":N,\"end\":M} (byte offsets, search order)
stderr: progress {\"scanned\":N,\"total\":T}; exit 0 found, 1 none, 2 error";

fn parse_num<T: std::str::FromStr>(flag: &str, value: &str) -> Result<T, CliError> {
    value
        .parse::<T>()
        .map_err(|_| CliError::Usage(format!("{flag}: invalid number {value:?}")))
}

fn default_threads() -> usize {
    std::thread::available_parallelism()
        .map(std::num::NonZero::get)
        .unwrap_or(1)
        .min(MAX_THREADS)
}

pub fn parse<I>(args: I) -> Result<Config, CliError>
where
    I: IntoIterator<Item = OsString>,
{
    let mut syntax = Syntax::Regex;
    let mut case = Case::Sensitive;
    let mut backward = false;
    let mut from = None;
    let mut limit = 0u64;
    let mut overlap = DEFAULT_OVERLAP;
    let mut threads = default_threads();
    let mut index = IndexMode::Auto;
    let mut progress_ms = DEFAULT_PROGRESS_MS;
    let mut chunk = DEFAULT_CHUNK;
    let mut positional: Vec<OsString> = Vec::new();

    let mut it = args.into_iter();
    let mut options_done = false;
    while let Some(arg) = it.next() {
        let bytes = arg.as_bytes();
        if options_done || !bytes.starts_with(b"-") || bytes == b"-" {
            positional.push(arg);
            continue;
        }
        let text = arg.to_string_lossy().into_owned();
        if text == "--" {
            options_done = true;
            continue;
        }
        let (name, inline) = match text.split_once('=') {
            Some((n, v)) if n.starts_with("--") => (n.to_string(), Some(v.to_string())),
            _ => (text.clone(), None),
        };
        let mut value = |flag: &str| -> Result<String, CliError> {
            if let Some(v) = inline.clone() {
                return Ok(v);
            }
            it.next()
                .map(|v| v.to_string_lossy().into_owned())
                .ok_or_else(|| CliError::Usage(format!("{flag}: missing value")))
        };
        match name.as_str() {
            "-h" | "--help" => return Err(CliError::Help),
            "-F" | "--fixed" => syntax = Syntax::Fixed,
            "-E" | "--regex" => syntax = Syntax::Regex,
            "-P" | "--pcre" => syntax = Syntax::Pcre,
            "-i" | "--ignore-case" => case = Case::Ignore,
            "-S" | "--smart-case" => case = Case::Smart,
            "-b" | "--backward" => backward = true,
            "--from" => from = Some(parse_num("--from", &value("--from")?)?),
            "--limit" => limit = parse_num("--limit", &value("--limit")?)?,
            "--max-match-bytes" => {
                overlap = parse_num("--max-match-bytes", &value("--max-match-bytes")?)?;
            }
            "--threads" => {
                let n: usize = parse_num("--threads", &value("--threads")?)?;
                threads = n.max(1);
            }
            "--index" => {
                index = match value("--index")?.as_str() {
                    "auto" => IndexMode::Auto,
                    "off" => IndexMode::Off,
                    other => {
                        return Err(CliError::Usage(format!(
                            "--index: expected auto or off, got {other:?}"
                        )))
                    }
                };
            }
            "--progress-ms" => progress_ms = parse_num("--progress-ms", &value("--progress-ms")?)?,
            "--chunk-bytes" => {
                let n: usize = parse_num("--chunk-bytes", &value("--chunk-bytes")?)?;
                if n == 0 {
                    return Err(CliError::Usage("--chunk-bytes: must be positive".into()));
                }
                chunk = n;
            }
            other => return Err(CliError::Usage(format!("unknown option {other}"))),
        }
    }

    let mut positional = positional.into_iter();
    let (Some(pattern), Some(file), None) =
        (positional.next(), positional.next(), positional.next())
    else {
        return Err(CliError::Usage("expected PATTERN and FILE".into()));
    };
    if pattern.is_empty() {
        return Err(CliError::Usage("PATTERN must not be empty".into()));
    }
    Ok(Config {
        syntax,
        case,
        backward,
        from,
        limit,
        overlap,
        threads,
        index,
        progress_ms,
        chunk,
        pattern: pattern.into_vec(),
        file: PathBuf::from(file),
    })
}

#[cfg(test)]
#[allow(clippy::unwrap_used, clippy::indexing_slicing)]
mod tests {
    use super::*;

    fn args(list: &[&str]) -> Vec<OsString> {
        list.iter().map(OsString::from).collect()
    }

    #[test]
    fn defaults() {
        let c = parse(args(&["foo", "f.log"])).unwrap();
        assert_eq!(c.syntax, Syntax::Regex);
        assert_eq!(c.case, Case::Sensitive);
        assert!(!c.backward);
        assert_eq!(c.from, None);
        assert_eq!(c.overlap, DEFAULT_OVERLAP);
        assert_eq!(c.pattern, b"foo");
    }

    #[test]
    fn options_and_inline_values() {
        let c = parse(args(&[
            "--fixed",
            "-i",
            "--backward",
            "--from=10",
            "--limit",
            "3",
            "--",
            "-x",
            "f",
        ]))
        .unwrap();
        assert_eq!(c.syntax, Syntax::Fixed);
        assert_eq!(c.case, Case::Ignore);
        assert!(c.backward);
        assert_eq!(c.from, Some(10));
        assert_eq!(c.limit, 3);
        assert_eq!(c.pattern, b"-x");
    }

    #[test]
    fn rejects_bad_input() {
        assert!(matches!(parse(args(&["only"])), Err(CliError::Usage(_))));
        assert!(matches!(parse(args(&["", "f"])), Err(CliError::Usage(_))));
        assert!(matches!(
            parse(args(&["--from", "x", "p", "f"])),
            Err(CliError::Usage(_))
        ));
        assert!(matches!(
            parse(args(&["--nope", "p", "f"])),
            Err(CliError::Usage(_))
        ));
        assert!(matches!(
            parse(args(&["--index", "maybe", "p", "f"])),
            Err(CliError::Usage(_))
        ));
        assert_eq!(parse(args(&["--help"])), Err(CliError::Help));
    }
}

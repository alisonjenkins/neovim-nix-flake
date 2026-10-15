//! Pattern engines behind one `find_at` interface.

use crate::cli::{Case, Config, Syntax};
use memchr::memmem;
use std::fmt;

#[derive(Debug)]
pub enum EngineError {
    Pattern(String),
    Match(String),
}

impl fmt::Display for EngineError {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            Self::Pattern(m) => write!(f, "invalid pattern: {m}"),
            Self::Match(m) => write!(f, "match error: {m}"),
        }
    }
}

impl std::error::Error for EngineError {}

pub enum Matcher {
    Memmem(Box<memmem::Finder<'static>>),
    Regex(regex::bytes::Regex),
    Pcre(pcre2::bytes::Regex),
}

/// A pattern with an uppercase letter keeps case under smart-case. A letter
/// after a backslash is an escape class (`\S`, `\W`), not a literal.
fn has_uppercase(pattern: &str, escapes: bool) -> bool {
    let mut chars = pattern.chars();
    while let Some(c) = chars.next() {
        if escapes && c == '\\' {
            chars.next();
        } else if c.is_uppercase() {
            return true;
        }
    }
    false
}

fn ignore_case(cfg: &Config, text: Option<&str>) -> bool {
    match cfg.case {
        Case::Sensitive => false,
        Case::Ignore => true,
        Case::Smart => text.is_some_and(|t| !has_uppercase(t, cfg.syntax != Syntax::Fixed)),
    }
}

impl Matcher {
    pub fn new(cfg: &Config) -> Result<Self, EngineError> {
        let text = std::str::from_utf8(&cfg.pattern).ok();
        let caseless = ignore_case(cfg, text);
        let need_text =
            || text.ok_or_else(|| EngineError::Pattern("pattern is not valid UTF-8".into()));
        match cfg.syntax {
            Syntax::Fixed if !caseless => Ok(Self::Memmem(Box::new(
                memmem::Finder::new(&cfg.pattern).into_owned(),
            ))),
            Syntax::Fixed => build_regex(&regex::escape(need_text()?), true),
            Syntax::Regex => build_regex(need_text()?, caseless),
            Syntax::Pcre => pcre2::bytes::RegexBuilder::new()
                .caseless(caseless)
                .multi_line(true)
                .jit_if_available(true)
                .build(need_text()?)
                .map(Self::Pcre)
                .map_err(|e| EngineError::Pattern(e.to_string())),
        }
    }

    /// The byte, when the pattern is exactly one literal byte.
    pub fn single_byte(&self) -> Option<u8> {
        match self {
            Self::Memmem(f) => match f.needle() {
                [b] => Some(*b),
                _ => None,
            },
            _ => None,
        }
    }

    /// Leftmost match starting at or after `at`. Look-behind and anchors see
    /// the bytes before `at`.
    pub fn find_at(&self, hay: &[u8], at: usize) -> Result<Option<(usize, usize)>, EngineError> {
        match self {
            Self::Memmem(f) => Ok(hay.get(at..).and_then(|tail| {
                f.find(tail).map(|p| {
                    (
                        at.saturating_add(p),
                        at.saturating_add(p).saturating_add(f.needle().len()),
                    )
                })
            })),
            Self::Regex(r) => Ok(r.find_at(hay, at).map(|m| (m.start(), m.end()))),
            Self::Pcre(r) => r
                .find_at(hay, at)
                .map(|o| o.map(|m| (m.start(), m.end())))
                .map_err(|e| EngineError::Match(e.to_string())),
        }
    }
}

fn build_regex(pattern: &str, caseless: bool) -> Result<Matcher, EngineError> {
    regex::bytes::RegexBuilder::new(pattern)
        .case_insensitive(caseless)
        .multi_line(true)
        .build()
        .map(Matcher::Regex)
        .map_err(|e| EngineError::Pattern(e.to_string()))
}

#[cfg(test)]
#[allow(clippy::unwrap_used, clippy::indexing_slicing)]
mod tests {
    use super::*;
    use crate::cli::{IndexMode, DEFAULT_CHUNK, DEFAULT_OVERLAP};

    fn cfg(syntax: Syntax, case: Case, pattern: &[u8]) -> Config {
        Config {
            syntax,
            case,
            backward: false,
            from: None,
            to: None,
            nth: None,
            count: false,
            limit: 0,
            overlap: DEFAULT_OVERLAP,
            threads: 1,
            index: IndexMode::Off,
            progress_ms: 0,
            chunk: DEFAULT_CHUNK,
            pattern: pattern.to_vec(),
            file: "x".into(),
        }
    }

    fn find(c: &Config, hay: &[u8]) -> Option<(usize, usize)> {
        Matcher::new(c).unwrap().find_at(hay, 0).unwrap()
    }

    #[test]
    fn fixed_matches_raw_bytes() {
        let c = cfg(Syntax::Fixed, Case::Sensitive, b"\xff\x00a");
        assert_eq!(find(&c, b"zz\xff\x00ab"), Some((2, 5)));
    }

    #[test]
    fn smart_case_follows_uppercase() {
        assert_eq!(
            find(&cfg(Syntax::Fixed, Case::Smart, b"abc"), b"xABC"),
            Some((1, 4))
        );
        assert_eq!(
            find(&cfg(Syntax::Fixed, Case::Smart, b"aBc"), b"xabc"),
            None
        );
        assert_eq!(
            find(&cfg(Syntax::Regex, Case::Smart, b"\\Sa"), b"xA"),
            Some((0, 2))
        );
    }

    #[test]
    fn regex_context_before_at_is_visible() {
        let m = Matcher::new(&cfg(Syntax::Regex, Case::Sensitive, b"^b")).unwrap();
        assert_eq!(m.find_at(b"ab\nb", 1).unwrap(), Some((3, 4)));
        let m = Matcher::new(&cfg(Syntax::Pcre, Case::Sensitive, b"(?<=a)b")).unwrap();
        assert_eq!(m.find_at(b"ab", 1).unwrap(), Some((1, 2)));
    }

    #[test]
    fn bad_pattern_is_an_error() {
        assert!(Matcher::new(&cfg(Syntax::Regex, Case::Sensitive, b"(")).is_err());
        assert!(Matcher::new(&cfg(Syntax::Regex, Case::Sensitive, b"\xff")).is_err());
    }
}

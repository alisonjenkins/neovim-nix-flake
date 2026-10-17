//! streamsearch: bounded-memory search of files larger than RAM.

mod cli;
mod engine;
mod index;
mod scan;

use std::io::{self, BufWriter, Write};
use std::os::fd::AsRawFd;
use std::os::unix::process::CommandExt;
use std::process::{Command, ExitCode, Stdio};
use std::sync::atomic::AtomicBool;

const EXIT_FOUND: u8 = 0;
const EXIT_NONE: u8 = 1;
const EXIT_ERROR: u8 = 2;
/// Background index builds yield to everything else on the machine.
const BUILD_NICE: libc::c_int = 19;
const BUILD_MAX_THREADS: usize = 4;

fn fail(message: &str) -> ExitCode {
    let _ = writeln!(io::stderr(), "streamsearch: {message}");
    ExitCode::from(EXIT_ERROR)
}

fn build_index(cfg: &cli::Config, file: &std::fs::File) -> ExitCode {
    let Some(dest) = index::cache_path(&cfg.file) else {
        return fail("no cache directory for the index (set HOME or XDG_CACHE_HOME)");
    };
    // SAFETY: setpriority only changes this process's own scheduling priority.
    unsafe { libc::setpriority(libc::PRIO_PROCESS, 0, BUILD_NICE) };
    let cancel = AtomicBool::new(false);
    let threads = cfg.threads.min(BUILD_MAX_THREADS);
    match index::build(file, &dest, cfg.index_block, threads, &cancel) {
        Ok(index::BuildOutcome::Built { bytes, blocks }) => {
            let _ = writeln!(
                io::stdout(),
                "{{\"index\":\"{}\",\"bytes\":{bytes},\"blocks\":{blocks}}}",
                dest.display()
            );
            ExitCode::from(EXIT_FOUND)
        }
        Ok(index::BuildOutcome::Busy) => {
            let _ = writeln!(io::stdout(), "{{\"index\":\"busy\"}}");
            ExitCode::from(EXIT_FOUND)
        }
        Err(e) => fail(&format!("index {}: {e}", dest.display())),
    }
}

/// Detached, so cancelling or finishing this search does not stop it.
fn spawn_background_build(cfg: &cli::Config) {
    let Ok(exe) = std::env::current_exe() else {
        return;
    };
    let _ = Command::new(exe)
        .args(["--index", "build", "--index-block-bytes"])
        .arg(cfg.index_block.to_string())
        .args(["--threads", &cfg.threads.to_string(), "--", "x"])
        .arg(&cfg.file)
        .process_group(0)
        .stdin(Stdio::null())
        .stdout(Stdio::null())
        .stderr(Stdio::null())
        .spawn();
}

fn main() -> ExitCode {
    let cfg = match cli::parse(std::env::args_os().skip(1)) {
        Ok(c) => c,
        Err(cli::CliError::Help) => {
            let _ = writeln!(io::stdout(), "{}", cli::USAGE);
            return ExitCode::from(EXIT_FOUND);
        }
        Err(cli::CliError::Usage(m)) => {
            let _ = writeln!(io::stderr(), "streamsearch: {m}\n{}", cli::USAGE);
            return ExitCode::from(EXIT_ERROR);
        }
    };
    let matcher = match engine::Matcher::new(&cfg) {
        Ok(m) => m,
        Err(e) => return fail(&e.to_string()),
    };
    let file = match std::fs::File::open(&cfg.file) {
        Ok(f) => f,
        Err(e) => return fail(&format!("{}: {e}", cfg.file.display())),
    };
    let meta = match file.metadata() {
        Ok(m) => m,
        Err(e) => return fail(&format!("{}: {e}", cfg.file.display())),
    };
    if !meta.is_file() {
        return fail(&format!("{}: not a regular file", cfg.file.display()));
    }
    if cfg.index == cli::IndexMode::Build {
        return build_index(&cfg, &file);
    }

    let cache = (cfg.index == cli::IndexMode::Auto)
        .then(|| index::cache_path(&cfg.file))
        .flatten();
    let ident = index::Identity::of(&meta);
    let idx = cache
        .as_deref()
        .and_then(|p| index::Index::open_valid(p, &ident));
    let query = idx.as_ref().and_then(|i| {
        let needle = engine::required_literal(&cfg)?;
        i.query(&needle.bytes, needle.exact, cfg.overlap as u64)
    });
    let skip = idx.as_ref().zip(query.as_ref());

    let stdout = io::stdout();
    let fd = stdout.as_raw_fd();
    let mut out = BufWriter::new(stdout.lock());
    match scan::run(&cfg, &matcher, &file, meta.len(), &mut out, Some(fd), skip) {
        Ok(o) => {
            if o.complete && cache.is_some() && idx.is_none() && meta.len() >= cfg.index_min {
                spawn_background_build(&cfg);
            }
            if cfg.count || o.matches > 0 || o.output_closed {
                ExitCode::from(EXIT_FOUND)
            } else {
                ExitCode::from(EXIT_NONE)
            }
        }
        Err(e) => fail(&e.to_string()),
    }
}

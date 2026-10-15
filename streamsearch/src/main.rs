//! streamsearch: bounded-memory search of files larger than RAM.

mod cli;
mod engine;
mod scan;

use std::io::{self, BufWriter, Write};
use std::os::fd::AsRawFd;
use std::process::ExitCode;

const EXIT_FOUND: u8 = 0;
const EXIT_NONE: u8 = 1;
const EXIT_ERROR: u8 = 2;

fn fail(message: &str) -> ExitCode {
    let _ = writeln!(io::stderr(), "streamsearch: {message}");
    ExitCode::from(EXIT_ERROR)
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

    let stdout = io::stdout();
    let fd = stdout.as_raw_fd();
    let mut out = BufWriter::new(stdout.lock());
    match scan::run(&cfg, &matcher, &file, meta.len(), &mut out, Some(fd)) {
        Ok(o) if cfg.count || o.matches > 0 || o.output_closed => ExitCode::from(EXIT_FOUND),
        Ok(_) => ExitCode::from(EXIT_NONE),
        Err(e) => fail(&e.to_string()),
    }
}

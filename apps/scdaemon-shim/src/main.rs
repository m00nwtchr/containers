// SPDX-License-Identifier: MIT
//
// scdaemon-shim: bridges gpg-agent's scdaemon protocol (stdio) to a
// remote gnupg-pkcs11-scd daemon (Unix socket).
//
// Usage: scdaemon-shim [ignored args from gpg-agent]
// Env:  SCD_SOCKET_DIR  (default /var/run/gnupg-pkcs11-scd)
//       SCD_SOCKET_NAME (default agent.S)
//       SCDAEMON_TIMEOUT (seconds to wait for the socket, default 10)
//
// stdin/stdout <-> Unix socket at $SCD_SOCKET_DIR/gnupg-pkcs11-scd.*/$SCD_SOCKET_NAME
//
// On stdin EOF we half-close the socket's write side so the remote
// daemon sees a clean disconnect. We exit cleanly when both sides are
// at EOF.

use std::env;
use std::io::{self, Read, Write};
use std::os::unix::fs::FileTypeExt;
use std::os::unix::io::AsRawFd;
use std::os::unix::net::UnixStream;
use std::path::{Path, PathBuf};
use std::process::ExitCode;
use std::time::{Duration, Instant};

extern "C" {
    fn poll(fds: *mut libc::pollfd, nfds: libc::nfds_t, timeout: libc::c_int) -> libc::c_int;
    fn shutdown(fd: libc::c_int, how: libc::c_int) -> libc::c_int;
}

const DEFAULT_SCD_DIR: &str = "/var/run/gnupg-pkcs11-scd";
const DEFAULT_SCD_NAME: &str = "agent.S";
const DEFAULT_TIMEOUT_SECS: u64 = 10;
const POLL_INTERVAL_MS: u64 = 50;
const COPY_BUF: usize = 8192;

// libstdc/libc poll(2) flag values.
const POLLIN: libc::c_short = 0x001;
const POLLERR: libc::c_short = 0x008;
const POLLHUP: libc::c_short = 0x010;
const SHUT_WR: libc::c_int = 1;

fn has_flag(combined: libc::c_short, flag: libc::c_short) -> bool {
    combined & flag == flag
}

fn find_socket(dir: &Path, name: &str, timeout: Duration) -> io::Result<PathBuf> {
    let deadline = Instant::now() + timeout;
    loop {
        if let Ok(rd) = std::fs::read_dir(dir) {
            for entry in rd.flatten() {
                let p = entry.path();
                if !p.is_dir() {
                    continue;
                }
                let dir_name = match p.file_name().and_then(|n| n.to_str()) {
                    Some(n) => n,
                    None => continue,
                };
                if !dir_name.starts_with("gnupg-pkcs11-scd.") {
                    continue;
                }
                let cand = p.join(name);
                let md = match std::fs::symlink_metadata(&cand) {
                    Ok(m) => m,
                    Err(_) => continue,
                };
                if md.file_type().is_socket() {
                    return Ok(cand);
                }
            }
        }
        if Instant::now() >= deadline {
            return Err(io::Error::new(
                io::ErrorKind::TimedOut,
                format!("timeout waiting for socket in {}", dir.display()),
            ));
        }
        std::thread::sleep(Duration::from_millis(POLL_INTERVAL_MS));
    }
}

fn copy_bidirectional(sock: &mut UnixStream) -> io::Result<()> {
    let sock_fd = sock.as_raw_fd();

    // Use raw stdio handles (unbuffered) so we can poll() on them
    // and do not introduce an unwanted layer of buffering on top of
    // the assuan protocol (gpg-agent writes single-line commands).
    let mut stdin = std::io::stdin().lock();
    let mut stdout = std::io::stdout().lock();

    let mut fds = [
        libc::pollfd { fd: 0,            events: POLLIN, revents: 0 },
        libc::pollfd { fd: sock_fd,      events: POLLIN, revents: 0 },
    ];

    let mut sock_buf = [0u8; COPY_BUF];
    let mut stdin_buf = [0u8; COPY_BUF];
    let mut stdin_eof = false;
    let mut sock_eof = false;
    let mut half_closed = false;

    while !(stdin_eof && sock_eof) {
        fds[0].events = POLLIN;
        fds[1].events = POLLIN;
        fds[0].revents = 0;
        fds[1].revents = 0;

        let n = unsafe { poll(fds.as_mut_ptr(), 2, -1) };
        if n < 0 {
            return Err(io::Error::last_os_error());
        }
        if n == 0 {
            continue;
        }

        // socket -> stdout
        if has_flag(fds[1].revents, POLLIN) || has_flag(fds[1].revents, POLLHUP) {
            match sock.read(&mut sock_buf) {
                Ok(0) => sock_eof = true,
                Ok(k) => {
                    if k == 0 { sock_eof = true; }
                    else {
                        stdout.write_all(&sock_buf[..k])?;
                        stdout.flush()?;
                    }
                }
                Err(e) if e.kind() == io::ErrorKind::WouldBlock => {}
                Err(e) => return Err(e),
            }
        }
        if has_flag(fds[1].revents, POLLERR) {
            return Err(io::Error::other("socket POLLERR"));
        }

        // stdin -> socket
        if !stdin_eof && (has_flag(fds[0].revents, POLLIN) || has_flag(fds[0].revents, POLLHUP)) {
            match stdin.read(&mut stdin_buf) {
                Ok(0) => stdin_eof = true,
                Ok(k) => {
                    if k == 0 { stdin_eof = true; }
                    else { sock.write_all(&stdin_buf[..k])?; }
                }
                Err(e) if e.kind() == io::ErrorKind::WouldBlock => {}
                Err(e) => return Err(e),
            }
        }
        if has_flag(fds[0].revents, POLLERR) {
            return Err(io::Error::other("stdin POLLERR"));
        }

        // On stdin EOF: half-close the socket's write side so the
        // remote daemon sees a clean disconnect and can exit. Don't
        // shutdown(2) more than once.
        if stdin_eof && !half_closed {
            let r = unsafe { shutdown(sock_fd, SHUT_WR) };
            if r != 0 {
                let e = std::io::Error::last_os_error();
                // EINVAL can happen if the peer already closed the
                // socket; treat that as success.
                if e.raw_os_error() != Some(libc::EINVAL) {
                    return Err(e);
                }
            }
            half_closed = true;
        }
    }
    Ok(())
}

fn main() -> ExitCode {
    let dir = env::var("SCD_SOCKET_DIR").unwrap_or_else(|_| DEFAULT_SCD_DIR.to_string());
    let name = env::var("SCD_SOCKET_NAME").unwrap_or_else(|_| DEFAULT_SCD_NAME.to_string());
    let timeout_secs: u64 = env::var("SCDAEMON_TIMEOUT")
        .ok()
        .and_then(|s| s.parse().ok())
        .unwrap_or(DEFAULT_TIMEOUT_SECS);

    let dir_path = PathBuf::from(&dir);
    let sock_path = match find_socket(&dir_path, &name, Duration::from_secs(timeout_secs)) {
        Ok(p) => p,
        Err(e) => {
            eprintln!("scdaemon-shim: {} (in {}/<gnupg-pkcs11-scd.*>/{} within {}s)",
                e, dir, name, timeout_secs);
            return ExitCode::from(1);
        }
    };
    eprintln!("scdaemon-shim: connecting to {}", sock_path.display());

    let mut stream = match UnixStream::connect(&sock_path) {
        Ok(s) => s,
        Err(e) => {
            eprintln!("scdaemon-shim: connect {}: {}", sock_path.display(), e);
            return ExitCode::from(1);
        }
    };
    eprintln!("scdaemon-shim: connected");

    if let Err(e) = copy_bidirectional(&mut stream) {
        eprintln!("scdaemon-shim: {}", e);
        return ExitCode::from(1);
    }
    ExitCode::SUCCESS
}

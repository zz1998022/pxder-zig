# Rust / TUI migration

The Zig implementation remains the behavioral reference on `codex/rust-tui`.
The Rust application lives in `rust/` and shares one engine between CLI and TUI.

## Acceptance contract

- Retain UID/PID, public/private follows and bookmarks, directory-based update,
  PKCE/token login, logout/export, settings, proxy, auto-rename and ugoira ZIPs.
- Preserve legacy filenames and read existing platform-specific `pxder-zig`
  configuration on first use. Save subsequent settings under `pxder`; never
  rewrite legacy configuration implicitly.
- Bound queued jobs and concurrent transfers. Stream bytes into temporary files
  on the destination filesystem and publish only successful nonempty transfers.
- Cancel API requests, retry sleeps, queue waits and file transfers. Join workers
  before returning control or restoring the terminal.
- Distinguish successful, skipped, failed and cancelled work. CLI failures must
  return nonzero. A partially fetched source is not a successful complete batch.
- Use finite retries; honor Retry-After for rate limiting. Never log tokens,
  authorization headers, OAuth payloads or proxy passwords.
- Validate using local HTTP fixtures, filesystem tests, UI rendering/state tests,
  formatting and Clippy. CI runs on macOS, Linux and Windows.
- Actual Pixiv authentication/downloads require a separately observed live run;
  passing mock tests is not evidence of live service compatibility.

## Structure

`config` owns validated configuration and atomic writes. `auth` owns PKCE and
callback parsing. `api` owns authenticated requests and typed pagination.
`model` maps API payloads to compatible filenames. `download` owns scheduling,
streaming transfers, cancellation and progress. `tui` consumes progress and
invokes the same operations as the CLI.

The TUI uses Ratatui/Crossterm, the runtime uses Tokio, and networking uses
Reqwest with Rustls. The terminal never runs network calls in its input/render
loop. UI progress is a coalesced snapshot, with bounded recent log history.

## Deliberate boundaries

- Existing files are skipped; this is file-level incremental downloading, not
  HTTP Range resume. Interrupted transfers restart and never become final files.
- Ugoira remains ZIP output, without video encoding. Metadata stores all frame
  delays; the compatibility filename uses the first frame delay.
- `--force` is accepted for CLI compatibility but does not overwrite existing
  files. Follows are always fetched afresh, so there is no stale follow cache.
- No performance superiority is claimed without comparable measurements.

## References

- https://ratatui.rs/tutorials/counter-async-app/
- https://docs.rs/reqwest/latest/reqwest/struct.ClientBuilder.html
- https://docs.rs/tokio-util/latest/tokio_util/sync/struct.CancellationToken.html

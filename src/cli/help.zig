const std = @import("std");
const terminal = @import("../shared/terminal.zig");
const args = @import("args.zig");

pub fn printHelp(io: std.Io) void {
    const help_text =
        \\Usage: pxder [options]
        \\
        \\Options:
        \\  --login [TOKEN]        Login via OAuth PKCE or refresh token
        \\  --logout               Logout (remove stored token)
        \\  --setting              Open interactive settings
        \\  -u, --uid <uids>       Download by artist UIDs (comma-separated)
        \\  -p, --pid <pids>       Download by illustration PIDs (comma-separated)
        \\  -f, --follow           Download from public follows
        \\  -F, --follow-private   Download from private follows
        \\  -b, --bookmark         Download public bookmarks
        \\  -B, --bookmark-private Download private bookmarks
        \\  -U, --update           Update all downloaded artists
        \\  --force                Ignore cached follow data
        \\  -M, --no-ugoira-meta   Skip ugoira metadata requests
        \\  -O, --output-dir <dir> Override download directory
        \\  --no-protocol          Skip Windows protocol handler
        \\  --debug                Enable verbose output
        \\  --output-config-dir    Print config directory path
        \\  --export-token         Print stored refresh token
        \\  -v, --version          Print version
        \\  -h, --help             Print this help
    ;
    terminal.logInfo(io, "{s}", .{help_text});
}

const std = @import("std");
const terminal = @import("../../shared/terminal.zig");
const cli_args = @import("../args.zig");

pub fn run(init: std.process.Init, cli: cli_args.CliArgs) !void {
    _ = cli;
    const io = init.io;
    terminal.logInfo(io, "pxder {s}", .{cli_args.version});
}

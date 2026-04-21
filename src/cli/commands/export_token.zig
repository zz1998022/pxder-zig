const std = @import("std");
const config = @import("../../infra/storage/config.zig");
const terminal = @import("../../shared/terminal.zig");
const cli_args = @import("../args.zig");

pub fn run(init: std.process.Init, cli: cli_args.CliArgs) !void {
    _ = cli;
    const io = init.io;
    const allocator = init.gpa;

    var cfg = config.AppConfig.load(allocator, io, init.environ_map) catch |err| {
        terminal.logError(io, "加载配置失败: {}", .{err});
        return;
    };
    defer cfg.deinit();
    if (cfg.refresh_token) |t| {
        terminal.logInfo(io, "{s}", .{t});
    } else {
        terminal.logError(io, "未登录。", .{});
    }
}

const std = @import("std");
const terminal = @import("../../shared/terminal.zig");
const tools = @import("../../shared/tools.zig");
const downloader = @import("../../services/download_service.zig");
const cli_args = @import("../args.zig");
const app_context = @import("../../app/context.zig");

pub fn run(init: std.process.Init, cli: cli_args.CliArgs) !void {
    var ctx = try app_context.AppContext.init(init, true);
    defer ctx.deinit();
    const io = ctx.io;
    const allocator = ctx.allocator;

    // Apply output_dir override
    if (cli.output_dir) |od| {
        if (ctx.cfg.download.path) |p| allocator.free(p);
        ctx.cfg.download.path = try allocator.dupe(u8, od);
        tools.ensureDir(io, od);
    }
    ctx.cfg.download.no_ugoira_meta = cli.no_ugoira_meta;

    const base_dir = ctx.cfg.download.path orelse {
        terminal.logError(io, "未设置下载目录", .{});
        return error.DownloadPathNotSet;
    };

    const pids_str = cli.pids orelse {
        terminal.logError(io, "未指定插画 PID", .{});
        return error.MissingArgument;
    };

    // Parse comma-separated PIDs
    var pids = std.ArrayListUnmanaged(u64).empty;
    defer pids.deinit(allocator);

    var pid_iter = std.mem.splitSequence(u8, pids_str, ",");
    while (pid_iter.next()) |pid_str| {
        const trimmed = std.mem.trim(u8, pid_str, " \t\r\n");
        if (trimmed.len == 0) continue;
        const pid = std.fmt.parseInt(u64, trimmed, 10) catch {
            terminal.logError(io, "无效 PID: {s}", .{trimmed});
            continue;
        };
        try pids.append(allocator, pid);
    }

    if (pids.items.len == 0) {
        terminal.logError(io, "无有效的插画 PID", .{});
        return;
    }

    var dl = downloader.Downloader.init(allocator, io, ctx.cfg.download, ctx.http, app_context.resolveProxy(&ctx.cfg, ctx.environ_map));
    try dl.downloadByPids(&ctx.api, pids.items, base_dir);

    terminal.printColored(io, .green, "下载完成。", .{});
}

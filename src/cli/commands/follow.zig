const std = @import("std");
const terminal = @import("../../shared/terminal.zig");
const tools = @import("../../shared/tools.zig");
const illustrator = @import("../../core/illustrator.zig");
const downloader = @import("../../services/download_service.zig");
const cli_args = @import("../args.zig");
const app_context = @import("../../app/context.zig");

pub fn run(init: std.process.Init, cli: cli_args.CliArgs) !void {
    var ctx = try app_context.AppContext.init(init, true);
    defer ctx.deinit();
    const io = ctx.io;
    const allocator = ctx.allocator;

    const is_private = cli.action == .download_follow_private;

    // Apply output_dir override
    if (cli.output_dir) |od| {
        if (ctx.cfg.download.path) |p| allocator.free(p);
        ctx.cfg.download.path = try allocator.dupe(u8, od);
        tools.ensureDir(io, od);
    }
    ctx.cfg.download.no_ugoira_meta = cli.no_ugoira_meta;

    if (ctx.cfg.download.path == null) {
        terminal.logError(io, "未设置下载目录", .{});
        return error.DownloadPathNotSet;
    }

    // Get current user ID
    const my_id = app_context.getMyUserId(&ctx.api) catch |err| {
        terminal.logError(io, "获取当前用户 ID 失败: {}", .{err});
        return err;
    };

    terminal.logInfo(io, "当前用户 ID: {d}", .{my_id});

    var me = illustrator.Illustrator.init(allocator, my_id);
    defer me.deinit();

    if (is_private) {
        terminal.logInfo(io, "获取私密关注列表...", .{});
    } else {
        terminal.logInfo(io, "获取公开关注列表...", .{});
    }

    var dl = downloader.Downloader.init(allocator, io, ctx.cfg.download, ctx.http, app_context.resolveProxy(&ctx.cfg, ctx.environ_map));
    try dl.downloadFollowing(&me, is_private, &ctx.api);

    terminal.printColored(io, .green, "关注画师下载完成。", .{});
}

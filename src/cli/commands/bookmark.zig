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

    const is_private = cli.action == .download_bookmark_private;

    // Apply output_dir override
    if (cli.output_dir) |od| {
        if (ctx.cfg.download.path) |p| allocator.free(p);
        ctx.cfg.download.path = try allocator.dupe(u8, od);
        tools.ensureDir(io, od);
    }
    ctx.cfg.download.no_ugoira_meta = cli.no_ugoira_meta;

    // Get current user ID by parsing the JWT access token
    const my_id = app_context.getMyUserId(&ctx.api) catch |err| {
        terminal.logError(io, "获取当前用户 ID 失败: {}", .{err});
        terminal.logError(io, "请确保已正确登录。", .{});
        return err;
    };

    terminal.logInfo(io, "当前用户 ID: {d}", .{my_id});

    var me = illustrator.Illustrator.init(allocator, my_id);
    defer me.deinit();

    var dl = downloader.Downloader.init(allocator, io, ctx.cfg.download, ctx.http, app_context.resolveProxy(&ctx.cfg, ctx.environ_map));

    if (is_private) {
        terminal.logInfo(io, "开始下载私密收藏...", .{});
    } else {
        terminal.logInfo(io, "开始下载公开收藏...", .{});
    }

    try dl.downloadByBookmark(&me, is_private, &ctx.api);

    terminal.printColored(io, .green, "收藏下载完成。", .{});
}

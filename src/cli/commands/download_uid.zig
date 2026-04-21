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

    // Apply output_dir override
    if (cli.output_dir) |od| {
        if (ctx.cfg.download.path) |p| allocator.free(p);
        ctx.cfg.download.path = try allocator.dupe(u8, od);
        tools.ensureDir(io, od);
    }

    const uids_str = cli.uids orelse {
        terminal.logError(io, "未指定画师 UID", .{});
        return error.MissingArgument;
    };

    // Parse comma-separated UIDs
    var illustrators = std.ArrayListUnmanaged(*illustrator.Illustrator).empty;
    defer {
        for (illustrators.items) |artist| {
            artist.deinit();
            allocator.destroy(artist);
        }
        illustrators.deinit(allocator);
    }

    var uid_iter = std.mem.splitSequence(u8, uids_str, ",");
    while (uid_iter.next()) |uid_str| {
        const trimmed = std.mem.trim(u8, uid_str, " \t\r\n");
        if (trimmed.len == 0) continue;
        const uid = std.fmt.parseInt(u64, trimmed, 10) catch {
            terminal.logError(io, "无效 UID: {s}", .{trimmed});
            continue;
        };
        const artist = try allocator.create(illustrator.Illustrator);
        artist.* = illustrator.Illustrator.init(allocator, uid);
        try illustrators.append(allocator, artist);
    }

    if (illustrators.items.len == 0) {
        terminal.logError(io, "无有效的画师 UID", .{});
        return;
    }

    terminal.logInfo(io, "共 {d} 位画师待下载", .{illustrators.items.len});

    var dl = downloader.Downloader.init(allocator, io, ctx.cfg.download, &ctx.http, app_context.resolveProxy(&ctx.cfg, ctx.environ_map));
    try dl.downloadByIllustrators(illustrators.items, &ctx.api);

    terminal.printColored(io, .green, "下载完成。", .{});
}

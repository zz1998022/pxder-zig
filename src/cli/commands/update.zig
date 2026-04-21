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

    const base_dir = ctx.cfg.download.path orelse {
        terminal.logError(io, "未设置下载目录", .{});
        return error.DownloadPathNotSet;
    };

    // Scan download directory for folders matching "(uid)" pattern
    var illustrators = std.ArrayListUnmanaged(*illustrator.Illustrator).empty;
    defer {
        for (illustrators.items) |artist| {
            artist.deinit();
            allocator.destroy(artist);
        }
        illustrators.deinit(allocator);
    }

    var dir = std.Io.Dir.cwd().openDir(io, base_dir, .{ .iterate = true }) catch |err| {
        terminal.logError(io, "打开下载目录失败: {}", .{err});
        return err;
    };
    defer dir.close(io);

    var iter = dir.iterate();
    while (iter.next(io) catch null) |entry| {
        if (entry.kind != .directory) continue;

        // Look for pattern "(number)"
        const name = entry.name;
        if (name.len < 3 or name[0] != '(') continue;

        // Find closing ')'
        const close_paren = std.mem.indexOfScalar(u8, name, ')') orelse continue;
        const uid_str = name[1..close_paren];
        const uid = std.fmt.parseInt(u64, uid_str, 10) catch continue;

        const artist = try allocator.create(illustrator.Illustrator);
        artist.* = illustrator.Illustrator.init(allocator, uid);
        try illustrators.append(allocator, artist);
    }

    if (illustrators.items.len == 0) {
        terminal.logInfo(io, "下载目录中未找到画师目录 (格式: (uid)名称)", .{});
        return;
    }

    terminal.logInfo(io, "发现 {d} 位画师，开始更新下载...", .{illustrators.items.len});

    var dl = downloader.Downloader.init(allocator, io, ctx.cfg.download, &ctx.http, app_context.resolveProxy(&ctx.cfg, ctx.environ_map));
    try dl.downloadByIllustrators(illustrators.items, &ctx.api);

    terminal.printColored(io, .green, "更新下载完成。", .{});
}

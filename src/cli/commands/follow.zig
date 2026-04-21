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

    // Collect all followed illustrators
    var all_artists = std.ArrayListUnmanaged(illustrator.IllustratorInfo).empty;
    defer {
        for (all_artists.items) |item| item.deinit();
        all_artists.deinit(allocator);
    }

    if (is_private) {
        terminal.logInfo(io, "获取私密关注列表...", .{});
    } else {
        terminal.logInfo(io, "获取公开关注列表...", .{});
    }

    while (true) {
        const items = if (is_private)
            me.followingPrivate(&ctx.api) catch |err| {
                terminal.logError(io, "获取关注列表失败: {}", .{err});
                break;
            }
        else
            me.following(&ctx.api) catch |err| {
                terminal.logError(io, "获取关注列表失败: {}", .{err});
                break;
            };

        if (items.len == 0) {
            allocator.free(items);
            break;
        }

        for (items) |item| {
            all_artists.append(allocator, item) catch continue;
        }
        allocator.free(items);

        if (!me.hasNext(.following)) break;
    }

    if (all_artists.items.len == 0) {
        terminal.logInfo(io, "关注列表为空", .{});
        return;
    }

    terminal.logInfo(io, "共 {d} 位关注画师待下载", .{all_artists.items.len});

    // Create Illustrator objects for each followed artist
    var illustrators_list = std.ArrayListUnmanaged(*illustrator.Illustrator).empty;
    defer {
        for (illustrators_list.items) |artist| {
            artist.deinit();
            allocator.destroy(artist);
        }
        illustrators_list.deinit(allocator);
    }

    for (all_artists.items) |info| {
        const artist = try allocator.create(illustrator.Illustrator);
        artist.* = illustrator.Illustrator.init(allocator, info.id);
        // Pre-fill name from following list
        artist.setName(info.name) catch {};
        try illustrators_list.append(allocator, artist);
    }

    var dl = downloader.Downloader.init(allocator, io, ctx.cfg.download, &ctx.http, app_context.resolveProxy(&ctx.cfg, ctx.environ_map));
    try dl.downloadByIllustrators(illustrators_list.items, &ctx.api);

    terminal.printColored(io, .green, "关注画师下载完成。", .{});
}

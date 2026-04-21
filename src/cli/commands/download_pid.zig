const std = @import("std");
const terminal = @import("../../shared/terminal.zig");
const tools = @import("../../shared/tools.zig");
const illust_mod = @import("../../core/illust.zig");
const json_utils = @import("../../shared/json_utils.zig");
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

    var dl = downloader.Downloader.init(allocator, io, ctx.cfg.download, &ctx.http, app_context.resolveProxy(&ctx.cfg, ctx.environ_map));

    for (pids.items) |pid| {
        terminal.logInfo(io, "处理插画 {d}...", .{pid});

        // Fetch illust detail
        const parsed = ctx.api.illustDetail(pid) catch |err| {
            terminal.logError(io, "获取插画 {d} 详情失败: {}", .{ pid, err });
            continue;
        };
        defer parsed.deinit();

        const json = parsed.value;
        const illust_json = json_utils.getFieldObject(json, "illust") orelse blk: {
            // Some API versions return the illust directly at top level
            if (json == .object and json.object.get("id") != null) {
                break :blk json.object;
            }
            break :blk null;
        } orelse {
            terminal.logError(io, "解析插画 {d} 数据失败", .{pid});
            continue;
        };

        const illust_json_val = std.json.Value{ .object = illust_json };
        const illusts = illust_mod.parseIllusts(allocator, illust_json_val, null) catch |err| {
            terminal.logError(io, "解析插画 {d} 失败: {}", .{ pid, err });
            continue;
        };
        defer illust_mod.deinitIllusts(allocator, illusts);

        if (illusts.len == 0) {
            terminal.logInfo(io, "插画 {d} 无可下载内容", .{pid});
            continue;
        }

        // Download to <download_path>/<pid>/
        const pid_dir = try std.fmt.allocPrint(allocator, "{s}/{d}", .{ base_dir, pid });
        defer allocator.free(pid_dir);
        tools.ensureDir(io, pid_dir);

        terminal.logInfo(io, "下载插画 {d} ({d} 个文件) 到: {s}", .{ pid, illusts.len, pid_dir });

        dl.downloadIllusts(illusts, pid_dir) catch |err| {
            terminal.logError(io, "下载插画 {d} 失败: {}", .{ pid, err });
        };
    }

    terminal.printColored(io, .green, "下载完成。", .{});
}

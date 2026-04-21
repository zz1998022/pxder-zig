const std = @import("std");
const cli_args = @import("../cli/args.zig");
const cli_help = @import("../cli/help.zig");
const config = @import("../infra/storage/config.zig");
const terminal = @import("../shared/terminal.zig");
const cmd_login = @import("../cli/commands/login.zig");
const cmd_setting = @import("../cli/commands/setting.zig");
const cmd_export_token = @import("../cli/commands/export_token.zig");
const cmd_version = @import("../cli/commands/version.zig");
const cmd_download_uid = @import("../cli/commands/download_uid.zig");
const cmd_download_pid = @import("../cli/commands/download_pid.zig");
const cmd_follow = @import("../cli/commands/follow.zig");
const cmd_bookmark = @import("../cli/commands/bookmark.zig");
const cmd_update = @import("../cli/commands/update.zig");

pub fn run(init: std.process.Init, cli: cli_args.CliArgs) !void {
    const io = init.io;
    const allocator = init.gpa;
    const environ_map = init.environ_map;

    switch (cli.action.?) {
        .show_config_dir => {
            const dir = config.AppConfig.configDir(allocator, environ_map) catch |err| {
                terminal.logError(io, "获取配置目录失败: {}", .{err});
                return;
            };
            defer allocator.free(dir);
            terminal.logInfo(io, "{s}", .{dir});
        },
        .export_token => {
            cmd_export_token.run(init, cli) catch |err| {
                terminal.logError(io, "导出令牌失败: {}", .{err});
            };
        },
        .logout => {
            var cfg = config.AppConfig.load(allocator, io, environ_map) catch |err| {
                terminal.logError(io, "加载配置失败: {}", .{err});
                return;
            };
            defer cfg.deinit();
            cfg.refresh_token = null;
            try cfg.save(io, environ_map);
            terminal.printColored(io, .green, "已登出。", .{});
        },
        .login => {
            cmd_login.run(init, cli) catch |err| {
                terminal.logError(io, "登录失败: {}", .{err});
            };
        },
        .login_token => {
            cmd_login.run(init, cli) catch |err| {
                terminal.logError(io, "令牌登录失败: {}", .{err});
            };
        },
        .setting => {
            cmd_setting.run(init, cli) catch |err| {
                terminal.logError(io, "设置失败: {}", .{err});
            };
        },
        .download_uid => {
            cmd_download_uid.run(init, cli) catch |err| {
                terminal.logError(io, "下载失败: {}", .{err});
            };
        },
        .download_pid => {
            cmd_download_pid.run(init, cli) catch |err| {
                terminal.logError(io, "下载失败: {}", .{err});
            };
        },
        .download_follow => {
            cmd_follow.run(init, cli) catch |err| {
                terminal.logError(io, "下载失败: {}", .{err});
            };
        },
        .download_follow_private => {
            cmd_follow.run(init, cli) catch |err| {
                terminal.logError(io, "下载失败: {}", .{err});
            };
        },
        .download_bookmark => {
            cmd_bookmark.run(init, cli) catch |err| {
                terminal.logError(io, "下载失败: {}", .{err});
            };
        },
        .download_bookmark_private => {
            cmd_bookmark.run(init, cli) catch |err| {
                terminal.logError(io, "下载失败: {}", .{err});
            };
        },
        .download_update => {
            cmd_update.run(init, cli) catch |err| {
                terminal.logError(io, "更新下载失败: {}", .{err});
            };
        },
        .show_version => {
            cmd_version.run(init, cli) catch {};
        },
        .show_help => {
            cli_help.printHelp(io);
        },
    }
}

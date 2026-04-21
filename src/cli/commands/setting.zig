const std = @import("std");
const config = @import("../../infra/storage/config.zig");
const terminal = @import("../../shared/terminal.zig");
const tools = @import("../../shared/tools.zig");
const proxy_mod = @import("../../infra/http/proxy.zig");
const cli_args = @import("../args.zig");

pub fn run(init: std.process.Init, cli: cli_args.CliArgs) !void {
    _ = cli;
    const io = init.io;
    const allocator = init.gpa;
    const environ_map = init.environ_map;

    var cfg = try config.AppConfig.load(allocator, io, environ_map);
    defer cfg.deinit();

    var stdin = std.Io.File.stdin();
    var in_buf: [4096]u8 = undefined;
    var reader = stdin.reader(io, &in_buf);

    while (true) {
        // 每次循环重新显示当前配置和菜单
        terminal.logInfo(io, "\n===== 当前设置 =====", .{});
        if (cfg.download.path) |p| {
            terminal.logInfo(io, "下载目录: {s}", .{p});
        } else {
            terminal.logInfo(io, "下载目录: (未设置)", .{});
        }
        terminal.logInfo(io, "线程数: {d}", .{cfg.download.thread});
        terminal.logInfo(io, "超时时间: {d} 秒", .{cfg.download.timeout});
        terminal.logInfo(io, "自动重命名: {}", .{cfg.download.auto_rename});
        if (cfg.proxy) |p| {
            terminal.logInfo(io, "代理: {s}", .{p});
        } else {
            terminal.logInfo(io, "代理: (未设置)", .{});
        }
        terminal.logInfo(io, "===================", .{});
        terminal.logInfo(io, "  1. 下载目录", .{});
        terminal.logInfo(io, "  2. 线程数", .{});
        terminal.logInfo(io, "  3. 超时时间", .{});
        terminal.logInfo(io, "  4. 代理", .{});
        terminal.logInfo(io, "  5. 自动重命名", .{});
        terminal.logInfo(io, "  0. 保存并退出", .{});
        terminal.logInfo(io, "请输入选项编号: ", .{});

        const maybe_line = reader.interface.takeDelimiter('\n') catch {
            terminal.logError(io, "读取输入失败", .{});
            return;
        };
        const line = maybe_line orelse break;
        const choice = std.mem.trim(u8, line, " \t\r\n");

        if (std.mem.eql(u8, choice, "0")) {
            try cfg.save(io, environ_map);
            terminal.printColored(io, .green, "设置已保存。", .{});
            return;
        } else if (std.mem.eql(u8, choice, "1")) {
            terminal.logInfo(io, "请输入下载目录路径: ", .{});
            const maybe_val = reader.interface.takeDelimiter('\n') catch {
                terminal.logError(io, "读取输入失败", .{});
                continue;
            };
            if (maybe_val) |val| {
                const trimmed = std.mem.trim(u8, val, " \t\r\n");
                if (trimmed.len > 0) {
                    if (cfg.download.path) |p| allocator.free(p);
                    cfg.download.path = try allocator.dupe(u8, trimmed);
                    tools.ensureDir(io, trimmed);
                    terminal.printColored(io, .green, "下载目录已设置为: {s}", .{trimmed});
                }
            }
        } else if (std.mem.eql(u8, choice, "2")) {
            terminal.logInfo(io, "请输入线程数 (1-32): ", .{});
            const maybe_val = reader.interface.takeDelimiter('\n') catch {
                terminal.logError(io, "读取输入失败", .{});
                continue;
            };
            if (maybe_val) |val| {
                const trimmed = std.mem.trim(u8, val, " \t\r\n");
                const num = std.fmt.parseInt(u32, trimmed, 10) catch {
                    terminal.logError(io, "无效数字: {s}", .{trimmed});
                    continue;
                };
                cfg.download.thread = @min(@max(num, 1), 32);
                terminal.printColored(io, .green, "线程数已设置为: {d}", .{cfg.download.thread});
            }
        } else if (std.mem.eql(u8, choice, "3")) {
            terminal.logInfo(io, "请输入超时时间（秒）: ", .{});
            const maybe_val = reader.interface.takeDelimiter('\n') catch {
                terminal.logError(io, "读取输入失败", .{});
                continue;
            };
            if (maybe_val) |val| {
                const trimmed = std.mem.trim(u8, val, " \t\r\n");
                const num = std.fmt.parseInt(u32, trimmed, 10) catch {
                    terminal.logError(io, "无效数字: {s}", .{trimmed});
                    continue;
                };
                cfg.download.timeout = @max(num, 1);
                terminal.printColored(io, .green, "超时时间已设置为: {d} 秒", .{cfg.download.timeout});
            }
        } else if (std.mem.eql(u8, choice, "4")) {
            terminal.logInfo(io, "请输入代理地址 (如 socks5://127.0.0.1:1080，输入 disable 禁用): ", .{});
            const maybe_val = reader.interface.takeDelimiter('\n') catch {
                terminal.logError(io, "读取输入失败", .{});
                continue;
            };
            if (maybe_val) |val| {
                const trimmed = std.mem.trim(u8, val, " \t\r\n");
                if (trimmed.len > 0) {
                    if (!proxy_mod.checkProxyFormat(trimmed)) {
                        terminal.logError(io, "代理格式无效，支持: http://, https://, socks5:// 等", .{});
                        continue;
                    }
                    if (cfg.proxy) |p| allocator.free(p);
                    cfg.proxy = try allocator.dupe(u8, trimmed);
                    terminal.printColored(io, .green, "代理已设置为: {s}", .{trimmed});
                }
            }
        } else if (std.mem.eql(u8, choice, "5")) {
            terminal.logInfo(io, "自动重命名 (y/n): ", .{});
            const maybe_val = reader.interface.takeDelimiter('\n') catch {
                terminal.logError(io, "读取输入失败", .{});
                continue;
            };
            if (maybe_val) |val| {
                const trimmed = std.mem.trim(u8, val, " \t\r\n");
                if (std.mem.eql(u8, trimmed, "y") or std.mem.eql(u8, trimmed, "Y") or std.mem.eql(u8, trimmed, "yes")) {
                    cfg.download.auto_rename = true;
                } else {
                    cfg.download.auto_rename = false;
                }
                terminal.printColored(io, .green, "自动重命名已设置为: {}", .{cfg.download.auto_rename});
            }
        } else {
            terminal.logError(io, "无效选项: {s}", .{choice});
        }
    }
}

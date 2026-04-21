const std = @import("std");
const builtin = @import("builtin");
const config = @import("config.zig");
const terminal = @import("terminal.zig");
const auth = @import("auth.zig");
const http_client = @import("http_client.zig");
const proxy_mod = @import("proxy.zig");
const pixiv_api = @import("pixiv_api.zig");
const downloader = @import("downloader.zig");
const illustrator = @import("illustrator.zig");
const illust_mod = @import("illust.zig");
const tools = @import("tools.zig");
const json_utils = @import("json_utils.zig");

/// Windows: 将控制台输入/输出代码页设为 UTF-8 (65001)，解决中文乱码
fn setupConsole() void {
    if (builtin.os.tag != .windows) return;
    const windows = struct {
        extern "kernel32" fn SetConsoleOutputCP(wCodePageID: u32) i32;
        extern "kernel32" fn SetConsoleCP(wCodePageID: u32) i32;
    };
    _ = windows.SetConsoleOutputCP(65001);
    _ = windows.SetConsoleCP(65001);
}

const version = "2.12.10";

const CliAction = enum {
    login,
    login_token,
    logout,
    setting,
    download_uid,
    download_pid,
    download_follow,
    download_follow_private,
    download_bookmark,
    download_bookmark_private,
    download_update,
    show_config_dir,
    show_version,
    show_help,
    export_token,
};

const CliArgs = struct {
    action: ?CliAction = null,
    token: ?[]const u8 = null,
    pids: ?[]const u8 = null,
    uids: ?[]const u8 = null,
    force: bool = false,
    no_ugoira_meta: bool = false,
    output_dir: ?[]const u8 = null,
    debug: bool = false,
    no_protocol: bool = false,
};

/// Shared context for download commands: loads config, validates,
/// creates HTTP client with proxy, creates PixivApi, refreshes token.
const AppContext = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    environ_map: *std.process.Environ.Map,
    cfg: config.AppConfig,
    http: http_client.HttpClient,
    api: pixiv_api.PixivApi,
    config_dir: []const u8,

    fn init(init_arg: std.process.Init, comptime validate_config: bool) !AppContext {
        const allocator = init_arg.gpa;
        const io = init_arg.io;
        const environ_map = init_arg.environ_map;

        var cfg = try config.AppConfig.load(allocator, io, environ_map);
        errdefer cfg.deinit();

        if (validate_config) {
            cfg.validate() catch |err| switch (err) {
                error.NotLoggedIn => {
                    terminal.logError(io, "未登录，请先使用 --login 登录", .{});
                    return err;
                },
                error.DownloadPathNotSet => {
                    terminal.logError(io, "未设置下载目录，请先使用 --setting 配置", .{});
                    return err;
                },
            };
        }

        // Set tmp directory to <configDir>/tmp
        const cdir = try config.AppConfig.configDir(allocator, environ_map);
        const tmp_dir = try std.fmt.allocPrint(allocator, "{s}/tmp", .{cdir});
        allocator.free(cdir);
        if (cfg.download.tmp) |t| allocator.free(t);
        cfg.download.tmp = tmp_dir;

        // Resolve proxy config
        const proxy_config = resolveProxy(&cfg, environ_map);

        var http = try http_client.HttpClient.init(allocator, io, proxy_config);
        errdefer http.deinit();

        var api = pixiv_api.PixivApi.init(allocator, io, http);
        errdefer api.deinit();

        // Refresh access token
        if (cfg.refresh_token) |rt| {
            api.refreshAccessToken(rt) catch |err| {
                terminal.logError(io, "刷新令牌失败: {}", .{err});
                return err;
            };

            // Update config with potentially new refresh token
            if (api.refresh_token) |new_rt| {
                if (cfg.refresh_token) |old_rt| allocator.free(old_rt);
                cfg.refresh_token = try allocator.dupe(u8, new_rt);
                cfg.save(io, environ_map) catch |err| {
                    terminal.logError(io, "保存配置失败: {}", .{err});
                };
            }
        }

        const config_dir = try config.AppConfig.configDir(allocator, environ_map);

        return .{
            .allocator = allocator,
            .io = io,
            .environ_map = environ_map,
            .cfg = cfg,
            .http = http,
            .api = api,
            .config_dir = config_dir,
        };
    }

    fn deinit(self: *AppContext) void {
        self.api.deinit();
        self.http.deinit();
        self.cfg.deinit();
        self.allocator.free(self.config_dir);
    }
};

fn printHelp(io: std.Io) void {
    const help_text =
        \\Usage: pxder [options]
        \\
        \\Options:
        \\  --login [TOKEN]        Login via OAuth PKCE or refresh token
        \\  --logout               Logout (remove stored token)
        \\  --setting              Open interactive settings
        \\  -u, --uid <uids>       Download by artist UIDs (comma-separated)
        \\  -p, --pid <pids>       Download by illustration PIDs (comma-separated)
        \\  -f, --follow           Download from public follows
        \\  -F, --follow-private   Download from private follows
        \\  -b, --bookmark         Download public bookmarks
        \\  -B, --bookmark-private Download private bookmarks
        \\  -U, --update           Update all downloaded artists
        \\  --force                Ignore cached follow data
        \\  -M, --no-ugoira-meta   Skip ugoira metadata requests
        \\  -O, --output-dir <dir> Override download directory
        \\  --no-protocol          Skip Windows protocol handler
        \\  --debug                Enable verbose output
        \\  --output-config-dir    Print config directory path
        \\  --export-token         Print stored refresh token
        \\  -v, --version          Print version
        \\  -h, --help             Print this help
    ;
    terminal.logInfo(io, "{s}", .{help_text});
}

pub fn main(init: std.process.Init) !void {
    setupConsole();

    const io = init.io;
    const allocator = init.gpa;
    const environ_map = init.environ_map;

    // Collect args into a slice
    var args_list: std.ArrayListUnmanaged([]const u8) = .empty;
    // Don't deinit - the strings are owned by the args iterator, not our list
    defer args_list.deinit(allocator);

    var args_iter = try std.process.Args.Iterator.initAllocator(init.minimal.args, allocator);
    defer args_iter.deinit();
    _ = args_iter.next(); // skip prog name
    while (args_iter.next()) |arg| {
        try args_list.append(allocator, arg);
    }

    if (args_list.items.len == 0) {
        printHelp(io);
        return;
    }

    const cli = parseArgsList(args_list.items) catch |err| {
        terminal.logError(io, "参数解析失败: {}", .{err});
        return;
    };

    if (cli.debug) {
        terminal.setLogLevel(.debug);
    }

    if (cli.action == null) {
        printHelp(io);
        return;
    }

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
            var cfg = config.AppConfig.load(allocator, io, environ_map) catch |err| {
                terminal.logError(io, "加载配置失败: {}", .{err});
                return;
            };
            defer cfg.deinit();
            if (cfg.refresh_token) |t| {
                terminal.logInfo(io, "{s}", .{t});
            } else {
                terminal.logError(io, "未登录。", .{});
            }
        },
        .logout => {
            var cfg = try config.AppConfig.load(allocator, io, environ_map);
            defer cfg.deinit();
            cfg.refresh_token = null;
            try cfg.save(io, environ_map);
            terminal.printColored(io, .green, "已登出。", .{});
        },
        .login => {
            doLogin(init) catch |err| {
                terminal.logError(io, "登录失败: {}", .{err});
            };
        },
        .login_token => {
            doLoginToken(init, cli.token.?) catch |err| {
                terminal.logError(io, "令牌登录失败: {}", .{err});
            };
        },
        .setting => {
            doSetting(init) catch |err| {
                terminal.logError(io, "设置失败: {}", .{err});
            };
        },
        .download_uid => {
            doDownloadUid(init, cli) catch |err| {
                terminal.logError(io, "下载失败: {}", .{err});
            };
        },
        .download_pid => {
            doDownloadPid(init, cli) catch |err| {
                terminal.logError(io, "下载失败: {}", .{err});
            };
        },
        .download_follow => {
            doDownloadFollow(init, cli, false) catch |err| {
                terminal.logError(io, "下载失败: {}", .{err});
            };
        },
        .download_follow_private => {
            doDownloadFollow(init, cli, true) catch |err| {
                terminal.logError(io, "下载失败: {}", .{err});
            };
        },
        .download_bookmark => {
            doDownloadBookmark(init, cli, false) catch |err| {
                terminal.logError(io, "下载失败: {}", .{err});
            };
        },
        .download_bookmark_private => {
            doDownloadBookmark(init, cli, true) catch |err| {
                terminal.logError(io, "下载失败: {}", .{err});
            };
        },
        .download_update => {
            doDownloadUpdate(init, cli) catch |err| {
                terminal.logError(io, "更新下载失败: {}", .{err});
            };
        },
        .show_version => {
            terminal.logInfo(io, "pxder {s}", .{version});
        },
        .show_help => {
            printHelp(io);
        },
    }
}

// ==================== Command implementations ====================

/// 从配置和环境变量解析代理设置
fn resolveProxy(cfg: *const config.AppConfig, environ_map: *std.process.Environ.Map) ?proxy_mod.ProxyConfig {
    if (cfg.proxy) |proxy_str| {
        if (proxy_str.len == 0) return proxy_mod.fromEnv(environ_map);
        if (std.mem.eql(u8, proxy_str, "disable")) return null;
        return proxy_mod.parse(proxy_str) catch null;
    }
    return proxy_mod.fromEnv(environ_map);
}

fn doLogin(init: std.process.Init) !void {
    const io = init.io;
    const allocator = init.gpa;

    // Generate PKCE parameters
    const pkce = try auth.generatePkce(allocator, io);
    defer auth.deinitPkce(allocator, pkce);

    // Print login URL
    terminal.logInfo(io, "请在浏览器中打开以下链接进行登录:", .{});
    terminal.printColored(io, .cyan, "{s}", .{pkce.login_url});
    terminal.logInfo(io, "", .{});

    // Read authorization code from stdin
    terminal.logInfo(io, "登录后请输入回调 URL 中的 code 参数:", .{});

    var stdin = std.Io.File.stdin();
    var buf: [4096]u8 = undefined;
    var reader = stdin.reader(io, &buf);
    const maybe_line = reader.interface.takeDelimiter('\n') catch {
        terminal.logError(io, "读取输入失败", .{});
        return error.ReadFailed;
    };
    const code = maybe_line orelse {
        terminal.logError(io, "未输入 code", .{});
        return error.MissingCode;
    };

    // Trim whitespace (handle \r\n on Windows)
    const trimmed = std.mem.trim(u8, code, " \t\r\n");
    if (trimmed.len == 0) {
        terminal.logError(io, "code 为空", .{});
        return error.MissingCode;
    }

    // Load config to get proxy settings
    var cfg = try config.AppConfig.load(allocator, io, init.environ_map);
    defer cfg.deinit();
    const proxy_config = resolveProxy(&cfg, init.environ_map);

    // Create HTTP client and PixivApi for token exchange
    var http = try http_client.HttpClient.init(allocator, io, proxy_config);
    defer http.deinit();
    var api = pixiv_api.PixivApi.init(allocator, io, http);
    defer api.deinit();

    // Exchange code for tokens
    try api.exchangeToken(trimmed, pkce.code_verifier);

    if (cfg.refresh_token) |t| allocator.free(t);
    cfg.refresh_token = try allocator.dupe(u8, api.refresh_token.?);
    try cfg.save(io, init.environ_map);

    terminal.printColored(io, .green, "登录成功！", .{});
}

fn doLoginToken(init: std.process.Init, token: []const u8) !void {
    const io = init.io;
    const allocator = init.gpa;

    // Load config to get proxy settings
    var cfg = try config.AppConfig.load(allocator, io, init.environ_map);
    defer cfg.deinit();
    const proxy_config = resolveProxy(&cfg, init.environ_map);

    // Create HTTP client and PixivApi
    var http = try http_client.HttpClient.init(allocator, io, proxy_config);
    defer http.deinit();
    var api = pixiv_api.PixivApi.init(allocator, io, http);
    defer api.deinit();

    // Refresh token to validate and get access token
    try api.refreshAccessToken(token);

    // Save the (potentially rotated) refresh token
    if (cfg.refresh_token) |t| allocator.free(t);
    cfg.refresh_token = try allocator.dupe(u8, api.refresh_token.?);
    try cfg.save(io, init.environ_map);

    terminal.printColored(io, .green, "令牌登录成功！", .{});
}

fn doSetting(init: std.process.Init) !void {
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

fn doDownloadUid(init: std.process.Init, cli: CliArgs) !void {
    var ctx = try AppContext.init(init, true);
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

    var dl = downloader.Downloader.init(allocator, io, ctx.cfg.download, &ctx.http, resolveProxy(&ctx.cfg, ctx.environ_map));
    try dl.downloadByIllustrators(illustrators.items, &ctx.api);

    terminal.printColored(io, .green, "下载完成。", .{});
}

fn doDownloadPid(init: std.process.Init, cli: CliArgs) !void {
    var ctx = try AppContext.init(init, true);
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

    var dl = downloader.Downloader.init(allocator, io, ctx.cfg.download, &ctx.http, resolveProxy(&ctx.cfg, ctx.environ_map));

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

fn doDownloadFollow(init: std.process.Init, cli: CliArgs, is_private: bool) !void {
    var ctx = try AppContext.init(init, true);
    defer ctx.deinit();
    const io = ctx.io;
    const allocator = ctx.allocator;

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
    const my_id = getMyUserId(&ctx.api) catch |err| {
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

    var dl = downloader.Downloader.init(allocator, io, ctx.cfg.download, &ctx.http, resolveProxy(&ctx.cfg, ctx.environ_map));
    try dl.downloadByIllustrators(illustrators_list.items, &ctx.api);

    terminal.printColored(io, .green, "关注画师下载完成。", .{});
}

fn doDownloadBookmark(init: std.process.Init, cli: CliArgs, is_private: bool) !void {
    var ctx = try AppContext.init(init, true);
    defer ctx.deinit();
    const io = ctx.io;
    const allocator = ctx.allocator;

    // Apply output_dir override
    if (cli.output_dir) |od| {
        if (ctx.cfg.download.path) |p| allocator.free(p);
        ctx.cfg.download.path = try allocator.dupe(u8, od);
        tools.ensureDir(io, od);
    }

    // Get current user ID by parsing the JWT access token
    const my_id = getMyUserId(&ctx.api) catch |err| {
        terminal.logError(io, "获取当前用户 ID 失败: {}", .{err});
        terminal.logError(io, "请确保已正确登录。", .{});
        return err;
    };

    terminal.logInfo(io, "当前用户 ID: {d}", .{my_id});

    var me = illustrator.Illustrator.init(allocator, my_id);
    defer me.deinit();

    var dl = downloader.Downloader.init(allocator, io, ctx.cfg.download, &ctx.http, resolveProxy(&ctx.cfg, ctx.environ_map));

    if (is_private) {
        terminal.logInfo(io, "开始下载私密收藏...", .{});
    } else {
        terminal.logInfo(io, "开始下载公开收藏...", .{});
    }

    try dl.downloadByBookmark(&me, is_private, &ctx.api);

    terminal.printColored(io, .green, "收藏下载完成。", .{});
}

fn doDownloadUpdate(init: std.process.Init, cli: CliArgs) !void {
    var ctx = try AppContext.init(init, true);
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

    var dl = downloader.Downloader.init(allocator, io, ctx.cfg.download, &ctx.http, resolveProxy(&ctx.cfg, ctx.environ_map));
    try dl.downloadByIllustrators(illustrators.items, &ctx.api);

    terminal.printColored(io, .green, "更新下载完成。", .{});
}

// ==================== Helpers ====================

/// Extract the current user's ID by parsing the JWT access token.
/// Pixiv access tokens are JWTs where the payload contains a "user" object with an "id" field.
fn getMyUserId(api: *pixiv_api.PixivApi) !u64 {
    const access_token = api.access_token orelse return error.NotLoggedIn;

    // JWT format: header.payload.signature
    // Find the two dots separating the parts
    const first_dot = std.mem.indexOfScalar(u8, access_token, '.') orelse return error.InvalidToken;
    const second_dot = std.mem.indexOfScalar(u8, access_token[first_dot + 1 ..], '.') orelse return error.InvalidToken;
    const payload_b64 = access_token[first_dot + 1 .. first_dot + 1 + second_dot];

    // Base64url decode
    var payload_buf: [4096]u8 = undefined;
    const b64_decoder = std.base64.url_safe_no_pad.Decoder;
    const decoded_len = b64_decoder.calcSizeForSlice(payload_b64) catch return error.InvalidToken;
    if (decoded_len > payload_buf.len) return error.InvalidToken;
    b64_decoder.decode(&payload_buf, payload_b64) catch return error.InvalidToken;
    const payload = payload_buf[0..decoded_len];

    // Parse JSON payload
    const parsed = std.json.parseFromSlice(std.json.Value, api.allocator, payload, .{}) catch
        return error.InvalidToken;
    defer parsed.deinit();

    const user_val = json_utils.getFieldObject(parsed.value, "user") orelse
        return error.InvalidToken;
    const user_json = std.json.Value{ .object = user_val };
    const id_val = json_utils.getFieldInt(user_json, "id") orelse
        return error.InvalidToken;

    return @intCast(id_val);
}

fn parseArgsList(args: []const []const u8) !CliArgs {
    var result = CliArgs{};
    var i: usize = 0;

    while (i < args.len) : (i += 1) {
        const arg = args[i];
        if (std.mem.eql(u8, arg, "--login")) {
            if (i + 1 < args.len and args[i + 1][0] != '-') {
                i += 1;
                result.token = args[i];
                result.action = .login_token;
            } else {
                result.action = .login;
            }
        } else if (std.mem.eql(u8, arg, "--logout")) {
            result.action = .logout;
        } else if (std.mem.eql(u8, arg, "--setting")) {
            result.action = .setting;
        } else if (std.mem.eql(u8, arg, "-u") or std.mem.eql(u8, arg, "--uid")) {
            i += 1;
            if (i >= args.len) return error.MissingArgument;
            result.uids = args[i];
            result.action = .download_uid;
        } else if (std.mem.eql(u8, arg, "-p") or std.mem.eql(u8, arg, "--pid")) {
            i += 1;
            if (i >= args.len) return error.MissingArgument;
            result.pids = args[i];
            result.action = .download_pid;
        } else if (std.mem.eql(u8, arg, "-f") or std.mem.eql(u8, arg, "--follow")) {
            result.action = .download_follow;
        } else if (std.mem.eql(u8, arg, "-F") or std.mem.eql(u8, arg, "--follow-private")) {
            result.action = .download_follow_private;
        } else if (std.mem.eql(u8, arg, "-b") or std.mem.eql(u8, arg, "--bookmark")) {
            result.action = .download_bookmark;
        } else if (std.mem.eql(u8, arg, "-B") or std.mem.eql(u8, arg, "--bookmark-private")) {
            result.action = .download_bookmark_private;
        } else if (std.mem.eql(u8, arg, "-U") or std.mem.eql(u8, arg, "--update")) {
            result.action = .download_update;
        } else if (std.mem.eql(u8, arg, "--force")) {
            result.force = true;
        } else if (std.mem.eql(u8, arg, "-M") or std.mem.eql(u8, arg, "--no-ugoira-meta")) {
            result.no_ugoira_meta = true;
        } else if (std.mem.eql(u8, arg, "-O") or std.mem.eql(u8, arg, "--output-dir")) {
            i += 1;
            if (i >= args.len) return error.MissingArgument;
            result.output_dir = args[i];
        } else if (std.mem.eql(u8, arg, "--debug")) {
            result.debug = true;
        } else if (std.mem.eql(u8, arg, "--no-protocol")) {
            result.no_protocol = true;
        } else if (std.mem.eql(u8, arg, "--output-config-dir")) {
            result.action = .show_config_dir;
        } else if (std.mem.eql(u8, arg, "--export-token")) {
            result.action = .export_token;
        } else if (std.mem.eql(u8, arg, "-v") or std.mem.eql(u8, arg, "--version")) {
            result.action = .show_version;
        } else if (std.mem.eql(u8, arg, "-h") or std.mem.eql(u8, arg, "--help")) {
            result.action = .show_help;
        } else {
            return error.UnknownArgument;
        }
    }

    return result;
}

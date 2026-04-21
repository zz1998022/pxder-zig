const std = @import("std");
const config = @import("../../infra/storage/config.zig");
const terminal = @import("../../shared/terminal.zig");
const auth = @import("../../auth.zig");
const http_client = @import("../../infra/http/http_client.zig");
const pixiv_api = @import("../../pixiv_api.zig");
const cli_args = @import("../args.zig");
const app_context = @import("../../app/context.zig");

pub fn run(init: std.process.Init, cli: cli_args.CliArgs) !void {
    switch (cli.action.?) {
        .login => {
            doLogin(init) catch |err| {
                terminal.logError(init.io, "登录失败: {}", .{err});
            };
        },
        .login_token => {
            doLoginToken(init, cli.token.?) catch |err| {
                terminal.logError(init.io, "令牌登录失败: {}", .{err});
            };
        },
        else => {},
    }
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
    const proxy_config = app_context.resolveProxy(&cfg, init.environ_map);

    // Create HTTP client and PixivApi for token exchange
    var http = try http_client.HttpClient.init(allocator, io, proxy_config);
    defer http.deinit();
    var api = pixiv_api.PixivApi.init(allocator, io, &http);
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
    const proxy_config = app_context.resolveProxy(&cfg, init.environ_map);

    // Create HTTP client and PixivApi
    var http = try http_client.HttpClient.init(allocator, io, proxy_config);
    defer http.deinit();
    var api = pixiv_api.PixivApi.init(allocator, io, &http);
    defer api.deinit();

    // Refresh token to validate and get access token
    try api.refreshAccessToken(token);

    // Save the (potentially rotated) refresh token
    if (cfg.refresh_token) |t| allocator.free(t);
    cfg.refresh_token = try allocator.dupe(u8, api.refresh_token.?);
    try cfg.save(io, init.environ_map);

    terminal.printColored(io, .green, "令牌登录成功！", .{});
}

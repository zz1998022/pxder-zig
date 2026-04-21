const std = @import("std");
const config = @import("../infra/storage/config.zig");
const terminal = @import("../shared/terminal.zig");
const http_client = @import("../infra/http/http_client.zig");
const proxy_mod = @import("../infra/http/proxy.zig");
const pixiv_api = @import("../pixiv_api.zig");
const json_utils = @import("../shared/json_utils.zig");

pub const AppContext = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    environ_map: *std.process.Environ.Map,
    cfg: config.AppConfig,
    http: *http_client.HttpClient,
    api: pixiv_api.PixivApi,
    config_dir: []const u8,

    pub fn init(init_arg: std.process.Init, comptime validate_config: bool) !AppContext {
        const allocator = init_arg.gpa;
        const io = init_arg.io;
        const environ_map = init_arg.environ_map;

        var cfg = try config.AppConfig.load(allocator, io, environ_map);
        var cfg_cleanup = true;
        errdefer if (cfg_cleanup) cfg.deinit();

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

        const http = try allocator.create(http_client.HttpClient);
        http.* = try http_client.HttpClient.init(allocator, io, proxy_config);
        var http_cleanup = true;
        errdefer if (http_cleanup) {
            http.deinit();
            allocator.destroy(http);
        };

        const config_dir = try config.AppConfig.configDir(allocator, environ_map);
        var config_dir_cleanup = true;
        errdefer if (config_dir_cleanup) allocator.free(config_dir);

        var ctx = AppContext{
            .allocator = allocator,
            .io = io,
            .environ_map = environ_map,
            .cfg = cfg,
            .http = http,
            .api = undefined,
            .config_dir = config_dir,
        };
        ctx.api = pixiv_api.PixivApi.init(allocator, io, ctx.http);
        errdefer {
            ctx.api.deinit();
            ctx.http.deinit();
            allocator.destroy(ctx.http);
            ctx.cfg.deinit();
            allocator.free(ctx.config_dir);
        }
        cfg_cleanup = false;
        http_cleanup = false;
        config_dir_cleanup = false;

        // Refresh access token
        if (ctx.cfg.refresh_token) |rt| {
            ctx.api.refreshAccessToken(rt) catch |err| {
                terminal.logError(io, "刷新令牌失败: {}", .{err});
                return err;
            };

            // Update config with potentially new refresh token
            if (ctx.api.refresh_token) |new_rt| {
                if (ctx.cfg.refresh_token) |old_rt| allocator.free(old_rt);
                ctx.cfg.refresh_token = try allocator.dupe(u8, new_rt);
                ctx.cfg.save(io, environ_map) catch |err| {
                    terminal.logError(io, "保存配置失败: {}", .{err});
                };
            }
        }

        return ctx;
    }

    pub fn deinit(self: *AppContext) void {
        self.api.deinit();
        self.http.deinit();
        self.allocator.destroy(self.http);
        self.cfg.deinit();
        self.allocator.free(self.config_dir);
    }
};

pub fn resolveProxy(cfg: *const config.AppConfig, environ_map: *std.process.Environ.Map) ?proxy_mod.ProxyConfig {
    if (cfg.proxy) |proxy_str| {
        if (proxy_str.len == 0) return proxy_mod.fromEnv(environ_map);
        if (std.mem.eql(u8, proxy_str, "disable")) return null;
        return proxy_mod.parse(proxy_str) catch null;
    }
    return proxy_mod.fromEnv(environ_map);
}

pub fn getMyUserId(api: *pixiv_api.PixivApi) !u64 {
    const access_token = api.access_token orelse return error.NotLoggedIn;

    // JWT format: header.payload.signature
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

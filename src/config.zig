//! 配置管理模块
//! 负责应用配置的读取、保存、校验。
//! 配置文件存储在平台特定的应用数据目录:
//!   Windows: %APPDATA%/pxder-zig/config.json
//!   macOS:   ~/Library/Application Support/pxder-zig/config.json
//!   Linux:   $XDG_CONFIG_HOME/pxder-zig/config.json 或 ~/.config/pxder-zig/config.json

const std = @import("std");
const json_utils = @import("json_utils.zig");
const builtin = @import("builtin");

/// 下载相关配置
pub const DownloadConfig = struct {
    path: ?[]const u8 = null, // 下载目标目录（绝对路径）
    thread: u32 = 5, // 并发下载线程数，范围 1-32
    timeout: u32 = 30, // 下载超时时间（秒）
    auto_rename: bool = false, // 当画师改名时自动重命名目录
    tmp: ?[]const u8 = null, // 临时文件目录，运行时设为 <configDir>/tmp
};

/// 应用全局配置
pub const AppConfig = struct {
    allocator: std.mem.Allocator,
    refresh_token: ?[]const u8 = null, // Pixiv OAuth refresh_token，用于持久化登录
    download: DownloadConfig = .{},
    proxy: ?[]const u8 = null, // 代理地址，如 "socks5://127.0.0.1:1080" 或 "disable"

    pub fn init(allocator: std.mem.Allocator) AppConfig {
        return .{ .allocator = allocator };
    }

    /// 释放所有分配的字符串字段
    pub fn deinit(self: *const AppConfig) void {
        if (self.refresh_token) |t| self.allocator.free(t);
        if (self.download.path) |p| self.allocator.free(p);
        if (self.download.tmp) |t| self.allocator.free(t);
        if (self.proxy) |p| self.allocator.free(p);
    }

    /// 获取平台相关的配置目录路径
    /// 返回值需要调用者释放
    pub fn configDir(allocator: std.mem.Allocator, environ_map: *std.process.Environ.Map) ![]const u8 {
        var needs_free = false;
        const base = switch (builtin.os.tag) {
            .windows => environ_map.get("APPDATA") orelse return error.ConfigDirUnavailable,
            .macos => blk: {
                const home = environ_map.get("HOME") orelse return error.ConfigDirUnavailable;
                needs_free = true;
                break :blk try std.fmt.allocPrint(allocator, "{s}/Library/Application Support", .{home});
            },
            else => blk: {
                // 优先使用 XDG_CONFIG_HOME，否则回退到 ~/.config
                if (environ_map.get("XDG_CONFIG_HOME")) |xdg| {
                    break :blk xdg;
                } else {
                    const home = environ_map.get("HOME") orelse return error.ConfigDirUnavailable;
                    needs_free = true;
                    break :blk try std.fmt.allocPrint(allocator, "{s}/.config", .{home});
                }
            },
        };
        const result = try std.fmt.allocPrint(allocator, "{s}/pxder-zig", .{base});
        if (needs_free) allocator.free(@constCast(base));
        return result;
    }

    /// 获取配置文件的完整路径（<configDir>/config.json）
    pub fn configFilePath(allocator: std.mem.Allocator, environ_map: *std.process.Environ.Map) ![]const u8 {
        const dir = try configDir(allocator, environ_map);
        defer allocator.free(dir);
        return std.fmt.allocPrint(allocator, "{s}/config.json", .{dir});
    }

    /// 确保配置目录存在（不存在则递归创建）
    pub fn ensureConfigDir(allocator: std.mem.Allocator, io: std.Io, environ_map: *std.process.Environ.Map) ![]const u8 {
        const dir = try configDir(allocator, environ_map);
        std.Io.Dir.cwd().createDirPath(io, dir) catch {};
        return dir;
    }

    /// 从配置文件加载配置
    /// 如果文件不存在或解析失败，返回带默认值的空配置
    pub fn load(allocator: std.mem.Allocator, io: std.Io, environ_map: *std.process.Environ.Map) !AppConfig {
        const path = try configFilePath(allocator, environ_map);
        defer allocator.free(path);

        // 读取文件内容
        const file = std.Io.Dir.cwd().openFile(io, path, .{}) catch {
            return AppConfig.init(allocator);
        };
        defer file.close(io);
        var read_buf: [4096]u8 = undefined;
        var reader = file.reader(io, &read_buf);
        const stat = reader.getSize() catch {
            return AppConfig.init(allocator);
        };
        const contents = reader.interface.readAlloc(allocator, @intCast(stat)) catch {
            return AppConfig.init(allocator);
        };
        defer allocator.free(contents);

        // 解析 JSON
        const parsed = std.json.parseFromSlice(std.json.Value, allocator, contents, .{}) catch {
            return AppConfig.init(allocator);
        };
        defer parsed.deinit();

        var cfg = AppConfig.init(allocator);
        errdefer cfg.deinit();

        // 提取各字段
        const json = parsed.value;
        if (json == .object) {
            if (json_utils.getFieldString(json, "refresh_token")) |t| {
                cfg.refresh_token = try allocator.dupe(u8, t);
            }
            if (json_utils.getFieldString(json, "proxy")) |p| {
                cfg.proxy = try allocator.dupe(u8, p);
            }
            if (json_utils.getFieldObject(json, "download")) |dl| {
                const dl_val = std.json.Value{ .object = dl };
                if (json_utils.getFieldString(dl_val, "path")) |p| {
                    cfg.download.path = try allocator.dupe(u8, p);
                }
                if (json_utils.getFieldInt(dl_val, "thread")) |t| {
                    cfg.download.thread = @intCast(t);
                }
                if (json_utils.getFieldInt(dl_val, "timeout")) |t| {
                    cfg.download.timeout = @intCast(t);
                }
                if (json_utils.getFieldBool(dl_val, "autoRename")) |b| {
                    cfg.download.auto_rename = b;
                }
            }
        }

        // 用默认值回填缺失字段
        if (cfg.download.thread == 0) cfg.download.thread = 5;
        if (cfg.download.timeout == 0) cfg.download.timeout = 30;

        return cfg;
    }

    /// 将当前配置写入配置文件
    pub fn save(self: *const AppConfig, io: std.Io, environ_map: *std.process.Environ.Map) !void {
        const dir = try ensureConfigDir(self.allocator, io, environ_map);
        defer self.allocator.free(dir);

        // 构造 JSON 对象
        var obj: std.json.ObjectMap = .empty;
        defer obj.deinit(self.allocator);

        if (self.refresh_token) |t| {
            try obj.put(self.allocator, "refresh_token", .{ .string = t });
        }
        if (self.proxy) |p| {
            try obj.put(self.allocator, "proxy", .{ .string = p });
        }

        var dl: std.json.ObjectMap = .empty;
        defer dl.deinit(self.allocator);
        if (self.download.path) |p| {
            try dl.put(self.allocator, "path", .{ .string = p });
        }
        try dl.put(self.allocator, "thread", .{ .integer = self.download.thread });
        try dl.put(self.allocator, "timeout", .{ .integer = self.download.timeout });
        try dl.put(self.allocator, "autoRename", .{ .bool = self.download.auto_rename });
        try obj.put(self.allocator, "download", .{ .object = dl });

        const path = try std.fmt.allocPrint(self.allocator, "{s}/config.json", .{dir});
        defer self.allocator.free(path);
        try json_utils.writeJsonFile(self.allocator, io, path, .{ .object = obj });
    }

    /// 校验配置是否满足运行条件
    /// 需要 refresh_token 和 download.path 都已设置
    pub fn validate(self: *const AppConfig) !void {
        if (self.refresh_token == null) {
            return error.NotLoggedIn;
        }
        if (self.download.path == null) {
            return error.DownloadPathNotSet;
        }
    }
};

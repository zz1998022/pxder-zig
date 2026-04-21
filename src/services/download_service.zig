//! 多线程下载引擎模块
//! 使用工作窃取模式实现并发下载，包含重试、完整性校验、全局暂停等逻辑。
//!
//! 下载流程:
//!   1. 清理临时目录
//!   2. 创建 N 个工作线程（默认 5，范围 1-32）
//!   3. 每个线程从共享原子索引中取任务执行（工作窃取模式）
//!   4. 文件先下载到内存，写入临时目录，校验大小后移动到最终路径
//!
//! 重试策略:
//!   - 单文件最多重试 10 次
//!   - 超过 1 个线程同时出错时触发 5 分钟全局暂停
//!   - 404 立即跳过不重试
//!
//! 画师目录命名:
//!   格式为 "(uid)clean_name"，画师改名时可根据 auto_rename 配置自动重命名

const std = @import("std");
const http_client = @import("../infra/http/http_client.zig");
const config = @import("../infra/storage/config.zig");
const illust = @import("../core/illust.zig");
const illustrator = @import("../core/illustrator.zig");
const pixiv_api = @import("../pixiv_api.zig");
const terminal = @import("../shared/terminal.zig");
const fs = @import("../infra/storage/fs.zig");

/// 最大重试次数
const MAX_RETRY: u32 = 10;

/// 全局暂停时长（纳秒）：5 分钟
const PAUSE_DURATION: u64 = 5 * 60 * std.time.ns_per_s;

/// 重试间隔（纳秒）：1 秒
const RETRY_INTERVAL: u64 = std.time.ns_per_s;

/// 下载请求 Referer 头
const REFERER = "https://www.pixiv.net/";

/// 下载任务共享状态（线程安全）
pub const DownloadState = struct {
    mutex: std.atomic.Mutex = .unlocked,
    next_index: std.atomic.Value(usize),
    total_count: usize,
    error_count: std.atomic.Value(u32),
    is_paused: std.atomic.Value(bool),
    success_count: std.atomic.Value(u32),
    skip_count: std.atomic.Value(u32),
    completed_count: std.atomic.Value(u32),

    pub fn init(total: usize) DownloadState {
        return .{
            .next_index = std.atomic.Value(usize).init(0),
            .total_count = total,
            .error_count = std.atomic.Value(u32).init(0),
            .is_paused = std.atomic.Value(bool).init(false),
            .success_count = std.atomic.Value(u32).init(0),
            .skip_count = std.atomic.Value(u32).init(0),
            .completed_count = std.atomic.Value(u32).init(0),
        };
    }
};

/// 工作线程上下文，传递给每个工作线程
const WorkerContext = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    proxy_config: ?@import("../infra/http/proxy.zig").ProxyConfig,
    state: *DownloadState,
    illusts: []const illust.Illust,
    temp_dir: []const u8,
    final_dir: []const u8,
    thread_id: u32,
};

/// 下载管理器
pub const Downloader = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    config: config.DownloadConfig,
    http: *http_client.HttpClient,
    proxy_config: ?@import("../infra/http/proxy.zig").ProxyConfig,

    /// 初始化下载管理器
    pub fn init(allocator: std.mem.Allocator, io: std.Io, cfg: config.DownloadConfig, http: *http_client.HttpClient, proxy_cfg: ?@import("../infra/http/proxy.zig").ProxyConfig) Downloader {
        return .{
            .allocator = allocator,
            .io = io,
            .config = cfg,
            .http = http,
            .proxy_config = proxy_cfg,
        };
    }

    /// 多线程下载插画列表
    /// illusts: 待下载的插画数组
    /// dir: 最终存放目录
    pub fn downloadIllusts(self: *Downloader, illusts_list: []const illust.Illust, dir: []const u8) !void {
        if (illusts_list.len == 0) return;

        // 确保最终目录存在
        std.Io.Dir.cwd().createDirPath(self.io, dir) catch {};

        // 确定临时目录路径
        const temp_dir = if (self.config.tmp) |tmp|
            try std.fmt.allocPrint(self.allocator, "{s}", .{tmp})
        else
            try std.fmt.allocPrint(self.allocator, "{s}.tmp", .{dir});
        defer self.allocator.free(temp_dir);

        // 清理并创建临时目录
        fs.cleanDir(self.allocator, self.io, temp_dir);
        std.Io.Dir.cwd().createDirPath(self.io, temp_dir) catch {};

        // 计算线程数，限制范围 1-32
        const thread_count: u32 = @min(@max(self.config.thread, 1), 32);

        // 初始化共享状态
        var state = DownloadState.init(illusts_list.len);

        // 为每个线程创建独立的上下文
        var contexts = try self.allocator.alloc(WorkerContext, thread_count);
        defer self.allocator.free(contexts);

        for (0..thread_count) |tid| {
            contexts[tid] = .{
                .allocator = self.allocator,
                .io = self.io,
                .proxy_config = self.proxy_config,
                .state = &state,
                .illusts = illusts_list,
                .temp_dir = temp_dir,
                .final_dir = dir,
                .thread_id = @intCast(tid),
            };
        }

        terminal.logInfo(self.io, "开始下载 {d} 个文件，使用 {d} 个线程...", .{ illusts_list.len, thread_count });

        // 生成工作线程
        var threads = std.ArrayListUnmanaged(std.Thread).empty;
        defer threads.deinit(self.allocator);

        for (0..thread_count) |tid| {
            const handle = std.Thread.spawn(.{}, workerFunc, .{&contexts[tid]}) catch continue;
            threads.append(self.allocator, handle) catch {
                handle.join();
                continue;
            };
        }

        // 等待所有工作线程完成
        for (threads.items) |handle| {
            handle.join();
        }

        // 清理临时目录
        fs.cleanDir(self.allocator, self.io, temp_dir);

        // 输出下载结果摘要
        const success = state.success_count.load(.monotonic);
        const skipped = state.skip_count.load(.monotonic);
        const errors = state.error_count.load(.monotonic);
        terminal.logInfo(self.io, "下载完成: 成功 {d}, 跳过 {d}, 失败 {d} / 共 {d}", .{ success, skipped, errors, illusts_list.len });
    }

    /// 根据画师列表下载所有插画
    /// illustrators: 画师指针数组
    /// pixiv_api: Pixiv API 客户端实例
    pub fn downloadByIllustrators(self: *Downloader, illustrators: []*illustrator.Illustrator, api: *pixiv_api.PixivApi) !void {
        const base_dir = self.config.path orelse return error.DownloadPathNotSet;

        for (illustrators, 0..) |artist, idx| {
            terminal.logInfo(self.io, "[{d}/{d}] 处理画师 {d}...", .{ idx + 1, illustrators.len, artist.id });

            // 获取画师信息，失败则跳过（可能是已注销账号）
            const info = artist.fetchInfo(api) catch |err| {
                terminal.logError(self.io, "获取画师 {d} 信息失败: {s}，跳过", .{ artist.id, @errorName(err) });
                continue;
            };
            defer info.deinit();

            // 确定画师目录路径
            const artist_dir = self.getIllustratorNewDir(info, base_dir) catch |err| {
                terminal.logError(self.io, "创建画师目录失败: {s}", .{@errorName(err)});
                continue;
            };
            defer self.allocator.free(artist_dir);

            terminal.logInfo(self.io, "画师目录: {s}", .{artist_dir});

            // 收集所有插画（分页遍历）
            var all_illusts = std.ArrayListUnmanaged(illust.Illust).empty;
            defer {
                for (all_illusts.items) |item| item.deinit(self.allocator);
                all_illusts.deinit(self.allocator);
            }

            while (true) {
                const items = artist.illusts(api) catch |err| {
                    terminal.logError(self.io, "获取画师 {d} 插画列表失败: {s}", .{ artist.id, @errorName(err) });
                    break;
                };

                if (items.len == 0) {
                    illust.deinitIllusts(self.allocator, items);
                    break;
                }

                for (items) |item| {
                    all_illusts.append(self.allocator, item) catch {};
                }
                self.allocator.free(items);

                if (!artist.hasNext(.illust)) break;
            }

            if (all_illusts.items.len == 0) {
                terminal.logInfo(self.io, "画师 {d} 无插画，跳过", .{artist.id});
                continue;
            }

            terminal.logInfo(self.io, "画师 {s} 共 {d} 个文件待下载", .{ info.name, all_illusts.items.len });

            // 执行下载
            self.downloadIllusts(all_illusts.items, artist_dir) catch |err| {
                terminal.logError(self.io, "下载画师 {s} 的插画失败: {s}", .{ info.name, @errorName(err) });
            };
        }
    }

    /// 下载收藏插画
    /// me: 当前登录用户（画师对象）
    /// is_private: 是否为私密收藏
    /// api: Pixiv API 客户端实例
    pub fn downloadByBookmark(self: *Downloader, me: *illustrator.Illustrator, is_private: bool, api: *pixiv_api.PixivApi) !void {
        const base_dir = self.config.path orelse return error.DownloadPathNotSet;

        // 确定收藏目录名
        const bookmark_dir_name = if (is_private) "[bookmark] Private" else "[bookmark] Public";
        const bookmark_dir = try std.fmt.allocPrint(self.allocator, "{s}/{s}", .{ base_dir, bookmark_dir_name });
        defer self.allocator.free(bookmark_dir);

        terminal.logInfo(self.io, "下载{d}收藏到: {s}", .{ if (is_private) @as(u32, 1) else @as(u32, 0), bookmark_dir_name });

        // 收集所有收藏插画（分页遍历）
        var all_illusts = std.ArrayListUnmanaged(illust.Illust).empty;
        defer {
            for (all_illusts.items) |item| item.deinit(self.allocator);
            all_illusts.deinit(self.allocator);
        }

        while (true) {
            const items = me.bookmarks(api) catch |err| {
                terminal.logError(self.io, "获取收藏列表失败: {s}", .{@errorName(err)});
                break;
            };

            if (items.len == 0) {
                illust.deinitIllusts(self.allocator, items);
                break;
            }

            for (items) |item| {
                all_illusts.append(self.allocator, item) catch {};
            }
            self.allocator.free(items);

            if (!me.hasNext(.bookmark)) break;
        }

        if (all_illusts.items.len == 0) {
            terminal.logInfo(self.io, "无收藏插画", .{});
            return;
        }

        terminal.logInfo(self.io, "共 {d} 个收藏文件待下载", .{all_illusts.items.len});

        // 执行下载
        self.downloadIllusts(all_illusts.items, bookmark_dir) catch |err| {
            terminal.logError(self.io, "下载收藏插画失败: {s}", .{@errorName(err)});
        };
    }

    /// 确定画师目录名称
    /// 规则:
    ///   - 在 base_dir 中查找以 "(uid)" 开头的子目录
    ///   - 如果找到且 auto_rename 为 true 且名称已变更，则重命名目录
    ///   - 如果未找到，创建新目录名 "(uid)clean_name"
    /// 返回: 分配的完整路径字符串，调用者负责释放
    pub fn getIllustratorNewDir(self: *Downloader, info: illustrator.IllustratorInfo, base_dir: []const u8) ![]const u8 {
        const uid_prefix = try std.fmt.allocPrint(self.allocator, "({d})", .{info.id});
        defer self.allocator.free(uid_prefix);

        const clean_name = illust.sanitizeArtistName(self.allocator, info.name) catch
            try self.allocator.dupe(u8, info.name);
        defer self.allocator.free(clean_name);

        // 在 base_dir 中查找以 "(uid)" 开头的子目录
        var dir = std.Io.Dir.cwd().openDir(self.io, base_dir, .{ .iterate = true }) catch
            return self.createArtistDir(base_dir, uid_prefix, clean_name);
        defer dir.close(self.io);

        var existing_entry: ?[]const u8 = null;
        var iter = dir.iterate();
        while (iter.next(self.io) catch null) |entry| {
            if (entry.kind != .directory) continue;
            if (std.mem.startsWith(u8, entry.name, uid_prefix)) {
                // 复制目录名用于后续操作
                existing_entry = try self.allocator.dupe(u8, entry.name);
                break;
            }
        }

        if (existing_entry) |existing_name| {
            // 已找到以 "(uid)" 开头的目录
            const expected_name = try std.fmt.allocPrint(self.allocator, "{s}{s}", .{ uid_prefix, clean_name });

            if (self.config.auto_rename and !std.mem.eql(u8, existing_name, expected_name)) {
                // 画师改名，需要重命名目录
                const old_path = try std.fmt.allocPrint(self.allocator, "{s}/{s}", .{ base_dir, existing_name });
                const new_path = try std.fmt.allocPrint(self.allocator, "{s}/{s}", .{ base_dir, expected_name });

                fs.renameDir(self.io, old_path, new_path) catch {
                    // 重命名失败，使用旧路径
                    self.allocator.free(new_path);
                    self.allocator.free(expected_name);
                    const result = old_path;
                    self.allocator.free(existing_name);
                    return result;
                };

                self.allocator.free(old_path);
                self.allocator.free(existing_name);
                // 返回新路径
                return new_path;
            }

            self.allocator.free(expected_name);
            // 使用现有目录路径
            const result = try std.fmt.allocPrint(self.allocator, "{s}/{s}", .{ base_dir, existing_name });
            self.allocator.free(existing_name);
            return result;
        }

        // 未找到现有目录，创建新目录名
        return self.createArtistDir(base_dir, uid_prefix, clean_name);
    }

    /// 构造画师目录路径并确保目录存在
    fn createArtistDir(self: *Downloader, base_dir: []const u8, uid_prefix: []const u8, clean_name: []const u8) ![]const u8 {
        const dir_name = try std.fmt.allocPrint(self.allocator, "{s}{s}", .{ uid_prefix, clean_name });
        errdefer self.allocator.free(dir_name);

        const full_path = try std.fmt.allocPrint(self.allocator, "{s}/{s}", .{ base_dir, dir_name });
        self.allocator.free(dir_name);

        // 确保目录存在
        std.Io.Dir.cwd().createDirPath(self.io, full_path) catch {};

        return full_path;
    }
};

/// 工作线程主函数
/// 每个线程循环从共享状态中获取下一个任务索引，执行下载
/// 下载成功或 404 跳过后继续下一个任务
/// 重试耗尽时递增错误计数，可能触发全局暂停
fn workerFunc(ctx: *WorkerContext) void {
    var http = http_client.HttpClient.init(ctx.allocator, ctx.io, ctx.proxy_config) catch return;
    defer http.deinit();

    const referer_header = std.http.Header{ .name = "referer", .value = REFERER };
    const total = ctx.state.total_count;

    while (true) {
        if (ctx.state.is_paused.load(.acquire)) {
            std.Io.sleep(ctx.io, .fromSeconds(300), .real) catch {};
            ctx.state.is_paused.store(false, .release);
            continue;
        }

        const i = ctx.state.next_index.fetchAdd(1, .monotonic);
        if (i >= ctx.state.total_count) break;

        const item = ctx.illusts[i];

        const final_path = std.fmt.allocPrint(ctx.allocator, "{s}/{s}", .{ ctx.final_dir, item.file }) catch continue;
        defer ctx.allocator.free(final_path);

        // 跳过已存在的文件
        if (fs.fileExists(ctx.io, final_path)) {
            _ = ctx.state.skip_count.fetchAdd(1, .monotonic);
            const done = ctx.state.completed_count.fetchAdd(1, .monotonic) + 1;
            printProgress(ctx.io, ctx.thread_id, done, total, item.id, item.title, "exists");
            continue;
        }

        const temp_path = std.fmt.allocPrint(ctx.allocator, "{s}/{s}", .{ ctx.temp_dir, item.file }) catch continue;
        defer ctx.allocator.free(temp_path);

        var retry: u32 = 0;
        var download_ok = false;
        var is_404 = false;

        while (retry <= MAX_RETRY) : (retry += 1) {
            if (ctx.state.is_paused.load(.acquire)) {
                std.Io.sleep(ctx.io, .fromSeconds(300), .real) catch {};
                ctx.state.is_paused.store(false, .release);
                continue;
            }

            const resp = http.get(item.url, &.{referer_header}) catch {
                std.Io.sleep(ctx.io, .fromSeconds(1), .real) catch {};
                continue;
            };
            defer resp.deinit();

            const status_code = @intFromEnum(resp.status);

            if (status_code == 404) {
                is_404 = true;
                break;
            }

            if (status_code < 200 or status_code >= 300) {
                std.Io.sleep(ctx.io, .fromSeconds(1), .real) catch {};
                continue;
            }

            if (resp.body.len == 0) {
                std.Io.sleep(ctx.io, .fromSeconds(1), .real) catch {};
                continue;
            }

            fs.writeFile(ctx.io, temp_path, resp.body) catch {
                std.Io.sleep(ctx.io, .fromSeconds(1), .real) catch {};
                continue;
            };

            const written_size = fs.getFileSize(ctx.io, temp_path) catch 0;
            if (written_size != resp.body.len) {
                fs.deleteFile(ctx.io, temp_path);
                std.Io.sleep(ctx.io, .fromSeconds(1), .real) catch {};
                continue;
            }

            fs.moveFile(ctx.io, temp_path, final_path) catch {
                fs.deleteFile(ctx.io, temp_path);
                std.Io.sleep(ctx.io, .fromSeconds(1), .real) catch {};
                continue;
            };

            download_ok = true;
            break;
        }

        if (download_ok) {
            _ = ctx.state.success_count.fetchAdd(1, .monotonic);
            const done = ctx.state.completed_count.fetchAdd(1, .monotonic) + 1;
            printProgress(ctx.io, ctx.thread_id, done, total, item.id, item.title, "OK");
        } else if (is_404) {
            _ = ctx.state.skip_count.fetchAdd(1, .monotonic);
            const done = ctx.state.completed_count.fetchAdd(1, .monotonic) + 1;
            printProgress(ctx.io, ctx.thread_id, done, total, item.id, item.title, "404");
        } else {
            _ = ctx.state.error_count.fetchAdd(1, .monotonic);
            const done = ctx.state.completed_count.fetchAdd(1, .monotonic) + 1;
            printProgress(ctx.io, ctx.thread_id, done, total, item.id, item.title, "FAIL");

            if (ctx.state.error_count.load(.monotonic) > 1) {
                ctx.state.is_paused.store(true, .release);
            }

            fs.deleteFile(ctx.io, temp_path);
        }
    }
}

fn printProgress(io: std.Io, thread_id: u32, done: u32, total: usize, pid: u64, title: []const u8, status: []const u8) void {
    var buf: [1024]u8 = undefined;
    var fw = std.Io.File.stdout().writer(io, &buf);
    if (std.mem.eql(u8, status, "OK")) {
        fw.interface.writeAll(terminal.colorCode(.green)) catch {};
    } else if (std.mem.eql(u8, status, "FAIL")) {
        fw.interface.writeAll(terminal.colorCode(.red)) catch {};
    } else if (std.mem.eql(u8, status, "404")) {
        fw.interface.writeAll(terminal.colorCode(.yellow)) catch {};
    } else {
        fw.interface.writeAll(terminal.colorCode(.gray)) catch {};
    }
    fw.interface.print("[{d}] {d}/{d}  pid {d}  {s}  {s}", .{ thread_id, done, total, pid, title, status }) catch {};
    fw.interface.writeAll(terminal.colorCode(.reset)) catch {};
    fw.interface.writeAll("\n") catch {};
    fw.flush() catch {};
}

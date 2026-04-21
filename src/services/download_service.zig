//! 多线程下载引擎模块
//! 将“分页抓取”和“文件下载”拆成生产者/消费者模型：
//!   - 前台线程负责按页抓取 Pixiv 数据并入队
//!   - 固定数量的 worker 持续消费下载任务
//! 这样可以显著降低首字节延迟，并避免先把某位画师的全部作品堆在内存里。

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

/// 全局暂停时长：5 分钟。
/// 这里只在短时间内连续失败时触发，避免早期失败永久拖慢整个下载批次。
const PAUSE_SECONDS: u64 = 5 * 60;

/// 当连续失败达到阈值时才进入全局暂停。
const PAUSE_FAILURE_THRESHOLD: u32 = 2;

/// 轮询任务队列的等待间隔。
const QUEUE_POLL_MS: u64 = 50;

/// 聚合进度输出步长。
const PROGRESS_REPORT_STEP: u32 = 10;

/// 下载请求 Referer 头
const REFERER = "https://www.pixiv.net/";

const ArtistDirEntry = struct {
    uid: u64,
    name: []const u8,
};

const DownloadTask = struct {
    illust_item: illust.Illust,
    final_dir: []const u8,
};

/// 下载任务共享状态（线程安全）
pub const DownloadState = struct {
    queue_mutex: std.atomic.Mutex = .unlocked,
    next_index: std.atomic.Value(usize),
    enqueued_count: std.atomic.Value(usize),
    producer_closed: std.atomic.Value(bool),
    error_count: std.atomic.Value(u32),
    failure_streak: std.atomic.Value(u32),
    is_paused: std.atomic.Value(bool),
    success_count: std.atomic.Value(u32),
    skip_count: std.atomic.Value(u32),
    completed_count: std.atomic.Value(u32),
    report_step: u32,

    pub fn init() DownloadState {
        return .{
            .next_index = std.atomic.Value(usize).init(0),
            .enqueued_count = std.atomic.Value(usize).init(0),
            .producer_closed = std.atomic.Value(bool).init(false),
            .error_count = std.atomic.Value(u32).init(0),
            .failure_streak = std.atomic.Value(u32).init(0),
            .is_paused = std.atomic.Value(bool).init(false),
            .success_count = std.atomic.Value(u32).init(0),
            .skip_count = std.atomic.Value(u32).init(0),
            .completed_count = std.atomic.Value(u32).init(0),
            .report_step = PROGRESS_REPORT_STEP,
        };
    }
};

const DownloadSession = struct {
    downloader: *Downloader,
    state: DownloadState = DownloadState.init(),
    tasks: std.ArrayListUnmanaged(DownloadTask) = .empty,
    owned_dirs: std.ArrayListUnmanaged([]const u8) = .empty,
    worker_contexts: std.ArrayListUnmanaged(WorkerContext) = .empty,
    workers: std.ArrayListUnmanaged(std.Thread) = .empty,
    temp_dir: []const u8,

    pub fn init(downloader: *Downloader) !DownloadSession {
        const temp_dir = if (downloader.config.tmp) |tmp|
            try std.fmt.allocPrint(downloader.allocator, "{s}", .{tmp})
        else
            try downloader.allocator.dupe(u8, "pxder-tmp");
        errdefer downloader.allocator.free(temp_dir);

        fs.cleanDir(downloader.allocator, downloader.io, temp_dir);
        std.Io.Dir.cwd().createDirPath(downloader.io, temp_dir) catch {};

        return .{
            .downloader = downloader,
            .temp_dir = temp_dir,
        };
    }

    pub fn deinit(self: *DownloadSession) void {
        for (self.tasks.items) |task| {
            task.illust_item.deinit(self.downloader.allocator);
        }
        self.tasks.deinit(self.downloader.allocator);

        for (self.owned_dirs.items) |dir| {
            self.downloader.allocator.free(dir);
        }
        self.owned_dirs.deinit(self.downloader.allocator);

        self.worker_contexts.deinit(self.downloader.allocator);
        self.workers.deinit(self.downloader.allocator);

        fs.cleanDir(self.downloader.allocator, self.downloader.io, self.temp_dir);
        self.downloader.allocator.free(self.temp_dir);
    }

    /// 启动固定数量的 worker。
    pub fn start(self: *DownloadSession) !void {
        const thread_count: u32 = @min(@max(self.downloader.config.thread, 1), 32);
        try self.worker_contexts.ensureTotalCapacity(self.downloader.allocator, thread_count);
        try self.workers.ensureTotalCapacity(self.downloader.allocator, thread_count);

        for (0..thread_count) |tid| {
            self.worker_contexts.appendAssumeCapacity(.{
                .session = self,
                .thread_id = @intCast(tid),
            });

            const handle = try std.Thread.spawn(.{}, workerFunc, .{&self.worker_contexts.items[tid]});
            self.workers.appendAssumeCapacity(handle);
        }
    }

    /// 接管目录字符串的所有权，保证任务消费完成前路径切片一直有效。
    pub fn ownDir(self: *DownloadSession, dir: []const u8) ![]const u8 {
        try self.owned_dirs.append(self.downloader.allocator, dir);
        return dir;
    }

    /// 提交一批任务并转移其所有权。
    pub fn submitOwnedIllusts(self: *DownloadSession, final_dir: []const u8, owned_illusts: []illust.Illust) !void {
        defer self.downloader.allocator.free(owned_illusts);
        errdefer {
            for (owned_illusts) |item| {
                item.deinit(self.downloader.allocator);
            }
        }

        lockQueue(self);
        defer self.state.queue_mutex.unlock();

        try self.tasks.ensureUnusedCapacity(self.downloader.allocator, owned_illusts.len);
        for (owned_illusts) |item| {
            self.tasks.appendAssumeCapacity(.{
                .illust_item = item,
                .final_dir = final_dir,
            });
        }
        _ = self.state.enqueued_count.fetchAdd(owned_illusts.len, .release);
    }

    pub fn closeInput(self: *DownloadSession) void {
        self.state.producer_closed.store(true, .release);
    }

    pub fn wait(self: *DownloadSession) void {
        for (self.workers.items) |handle| {
            handle.join();
        }
        self.workers.clearRetainingCapacity();
    }

    pub fn finish(self: *DownloadSession) void {
        self.closeInput();
        self.wait();

        const total = self.state.enqueued_count.load(.acquire);
        const success = self.state.success_count.load(.monotonic);
        const skipped = self.state.skip_count.load(.monotonic);
        const errors = self.state.error_count.load(.monotonic);
        terminal.logInfo(self.downloader.io, "下载完成: 成功 {d}, 跳过 {d}, 失败 {d} / 共 {d}", .{
            success,
            skipped,
            errors,
            total,
        });
    }
};

/// 工作线程上下文
const WorkerContext = struct {
    session: *DownloadSession,
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

    /// 多线程下载一批已知任务。
    /// 这里会复制任务元数据，但能复用新的 worker 池实现。
    pub fn downloadIllusts(self: *Downloader, illusts_list: []const illust.Illust, dir: []const u8) !void {
        if (illusts_list.len == 0) return;

        std.Io.Dir.cwd().createDirPath(self.io, dir) catch {};

        var session = try DownloadSession.init(self);
        defer session.deinit();
        try session.start();

        const owned_dir = try session.ownDir(try self.allocator.dupe(u8, dir));
        const cloned = try self.cloneIllusts(illusts_list);
        try session.submitOwnedIllusts(owned_dir, cloned);

        terminal.logInfo(self.io, "开始下载 {d} 个文件，使用 {d} 个线程...", .{
            illusts_list.len,
            @min(@max(self.config.thread, 1), 32),
        });
        session.finish();
    }

    /// 根据画师列表下载所有插画。
    /// 这里改为边分页抓取边入队，worker 会在后台持续消费。
    pub fn downloadByIllustrators(self: *Downloader, illustrators: []*illustrator.Illustrator, api: *pixiv_api.PixivApi) !void {
        const base_dir = self.config.path orelse return error.DownloadPathNotSet;
        var artist_dir_index = try self.buildArtistDirIndex(base_dir);
        defer self.deinitArtistDirIndex(&artist_dir_index);

        var session = try DownloadSession.init(self);
        defer session.deinit();
        try session.start();

        terminal.logInfo(self.io, "启动下载线程池，准备处理 {d} 位画师...", .{illustrators.len});

        for (illustrators, 0..) |artist, idx| {
            terminal.logInfo(self.io, "[{d}/{d}] 处理画师 {d}...", .{ idx + 1, illustrators.len, artist.id });
            self.queueIllustratorDownloads(&session, artist, base_dir, &artist_dir_index, api) catch |err| {
                terminal.logError(self.io, "处理画师 {d} 失败: {s}", .{ artist.id, @errorName(err) });
                continue;
            };
        }

        session.finish();
    }

    /// 下载关注画师。
    /// 这里按页处理关注列表，避免先把全部关注画师收集到内存里。
    pub fn downloadFollowing(self: *Downloader, me: *illustrator.Illustrator, is_private: bool, api: *pixiv_api.PixivApi) !void {
        const base_dir = self.config.path orelse return error.DownloadPathNotSet;
        var artist_dir_index = try self.buildArtistDirIndex(base_dir);
        defer self.deinitArtistDirIndex(&artist_dir_index);

        var session = try DownloadSession.init(self);
        defer session.deinit();
        try session.start();

        var page_index: usize = 0;
        while (true) {
            const items = (if (is_private)
                me.followingPrivate(api)
            else
                me.following(api)) catch |err| {
                terminal.logError(self.io, "获取关注列表失败: {s}", .{@errorName(err)});
                break;
            };

            if (items.len == 0) {
                self.allocator.free(items);
                break;
            }

            page_index += 1;
            terminal.logInfo(self.io, "处理关注列表第 {d} 页，共 {d} 位画师...", .{ page_index, items.len });

            for (items) |*info| {
                var artist = illustrator.Illustrator.init(self.allocator, info.id);
                defer artist.deinit();

                // 关注列表里的名称已经是拥有所有权的字符串，这里直接移交给 Illustrator，
                // 避免每位画师再复制一次名称。
                artist.setOwnedName(info.takeName());

                self.queueIllustratorDownloads(&session, &artist, base_dir, &artist_dir_index, api) catch |err| {
                    terminal.logError(self.io, "处理关注画师 {d} 失败: {s}", .{ info.id, @errorName(err) });
                    continue;
                };
            }

            for (items) |*item| item.deinit();
            self.allocator.free(items);

            if (!me.hasNext(.following)) break;
        }

        session.finish();
    }

    /// 按 PID 列表下载，多个 PID 共用同一组 worker。
    pub fn downloadByPids(self: *Downloader, api: *pixiv_api.PixivApi, pids: []const u64, base_dir: []const u8) !void {
        var session = try DownloadSession.init(self);
        defer session.deinit();
        try session.start();

        terminal.logInfo(self.io, "启动下载线程池，准备处理 {d} 个 PID...", .{pids.len});

        for (pids) |pid| {
            terminal.logInfo(self.io, "处理插画 {d}...", .{pid});

            const parsed = api.illustDetailLite(pid) catch |err| {
                terminal.logError(self.io, "获取插画 {d} 详情失败: {}", .{ pid, err });
                continue;
            };
            defer parsed.deinit();

            const ugoira_delay = self.resolveUgoiraDelay(api, parsed.value.illust) catch null;
            const items = illust.parseIllustLite(self.allocator, parsed.value.illust, ugoira_delay) catch |err| {
                terminal.logError(self.io, "解析插画 {d} 失败: {}", .{ pid, err });
                continue;
            };

            if (items.len == 0) {
                illust.deinitIllusts(self.allocator, items);
                terminal.logInfo(self.io, "插画 {d} 无可下载内容", .{pid});
                continue;
            }

            const pid_dir_alloc = try std.fmt.allocPrint(self.allocator, "{s}/{d}", .{ base_dir, pid });
            const pid_dir = session.ownDir(pid_dir_alloc) catch |err| {
                self.allocator.free(pid_dir_alloc);
                illust.deinitIllusts(self.allocator, items);
                return err;
            };

            std.Io.Dir.cwd().createDirPath(self.io, pid_dir) catch {};
            terminal.logInfo(self.io, "插画 {d} 已入队 {d} 个文件到: {s}", .{ pid, items.len, pid_dir });
            try session.submitOwnedIllusts(pid_dir, items);
        }

        session.finish();
    }

    /// 下载收藏插画，改为分页抓取后立即入队。
    pub fn downloadByBookmark(self: *Downloader, me: *illustrator.Illustrator, is_private: bool, api: *pixiv_api.PixivApi) !void {
        const base_dir = self.config.path orelse return error.DownloadPathNotSet;
        const bookmark_dir_name = if (is_private) "[bookmark] Private" else "[bookmark] Public";
        const bookmark_dir_alloc = try std.fmt.allocPrint(self.allocator, "{s}/{s}", .{ base_dir, bookmark_dir_name });

        var session = try DownloadSession.init(self);
        defer session.deinit();
        try session.start();

        const bookmark_dir = session.ownDir(bookmark_dir_alloc) catch |err| {
            self.allocator.free(bookmark_dir_alloc);
            return err;
        };

        terminal.logInfo(self.io, "开始下载收藏到: {s}", .{bookmark_dir_name});

        var queued_count: usize = 0;
        while (true) {
            const items = me.bookmarks(api, self.config.no_ugoira_meta) catch |err| {
                terminal.logError(self.io, "获取收藏列表失败: {s}", .{@errorName(err)});
                break;
            };

            if (items.len == 0) {
                illust.deinitIllusts(self.allocator, items);
                break;
            }

            queued_count += items.len;
            try session.submitOwnedIllusts(bookmark_dir, items);

            if (!me.hasNext(.bookmark)) break;
        }

        if (queued_count == 0) {
            terminal.logInfo(self.io, "无收藏插画", .{});
            session.closeInput();
            session.wait();
            return;
        }

        terminal.logInfo(self.io, "收藏作品已入队 {d} 个文件", .{queued_count});
        session.finish();
    }

    /// 确定画师目录名称
    /// 规则:
    ///   - 在 base_dir 中查找以 "(uid)" 开头的子目录
    ///   - 如果找到且 auto_rename 为 true 且名称已变更，则重命名目录
    ///   - 如果未找到，创建新目录名 "(uid)clean_name"
    pub fn getIllustratorNewDir(self: *Downloader, artist_id: u64, artist_name: []const u8, base_dir: []const u8, artist_dir_index: *std.ArrayListUnmanaged(ArtistDirEntry)) ![]const u8 {
        const uid_prefix = try std.fmt.allocPrint(self.allocator, "({d})", .{artist_id});
        defer self.allocator.free(uid_prefix);

        const clean_name = illust.sanitizeArtistName(self.allocator, artist_name) catch
            try self.allocator.dupe(u8, artist_name);
        defer self.allocator.free(clean_name);

        if (self.findArtistDirEntry(artist_dir_index.items, artist_id)) |entry| {
            const expected_name = try std.fmt.allocPrint(self.allocator, "{s}{s}", .{ uid_prefix, clean_name });
            errdefer self.allocator.free(expected_name);

            if (self.config.auto_rename and !std.mem.eql(u8, entry.name, expected_name)) {
                const old_path = try std.fmt.allocPrint(self.allocator, "{s}/{s}", .{ base_dir, entry.name });
                const new_path = try std.fmt.allocPrint(self.allocator, "{s}/{s}", .{ base_dir, expected_name });

                fs.renameDir(self.io, old_path, new_path) catch {
                    self.allocator.free(new_path);
                    const result = old_path;
                    self.allocator.free(expected_name);
                    return result;
                };

                self.allocator.free(entry.name);
                entry.name = expected_name;
                self.allocator.free(old_path);
                return new_path;
            }

            self.allocator.free(expected_name);
            return std.fmt.allocPrint(self.allocator, "{s}/{s}", .{ base_dir, entry.name });
        }

        return self.createArtistDir(base_dir, uid_prefix, clean_name, artist_dir_index);
    }

    fn createArtistDir(self: *Downloader, base_dir: []const u8, uid_prefix: []const u8, clean_name: []const u8, artist_dir_index: *std.ArrayListUnmanaged(ArtistDirEntry)) ![]const u8 {
        const dir_name = try std.fmt.allocPrint(self.allocator, "{s}{s}", .{ uid_prefix, clean_name });
        errdefer self.allocator.free(dir_name);

        const full_path = try std.fmt.allocPrint(self.allocator, "{s}/{s}", .{ base_dir, dir_name });
        errdefer self.allocator.free(full_path);

        std.Io.Dir.cwd().createDirPath(self.io, full_path) catch {};

        const uid = std.fmt.parseInt(u64, uid_prefix[1 .. uid_prefix.len - 1], 10) catch 0;
        try artist_dir_index.append(self.allocator, .{
            .uid = uid,
            .name = dir_name,
        });

        return full_path;
    }

    fn buildArtistDirIndex(self: *Downloader, base_dir: []const u8) !std.ArrayListUnmanaged(ArtistDirEntry) {
        var result: std.ArrayListUnmanaged(ArtistDirEntry) = .empty;
        errdefer self.deinitArtistDirIndex(&result);

        var dir = std.Io.Dir.cwd().openDir(self.io, base_dir, .{ .iterate = true }) catch return result;
        defer dir.close(self.io);

        var iter = dir.iterate();
        while (iter.next(self.io) catch null) |entry| {
            if (entry.kind != .directory) continue;
            if (entry.name.len < 3 or entry.name[0] != '(') continue;

            const close_paren = std.mem.indexOfScalar(u8, entry.name, ')') orelse continue;
            const uid = std.fmt.parseInt(u64, entry.name[1..close_paren], 10) catch continue;

            try result.append(self.allocator, .{
                .uid = uid,
                .name = try self.allocator.dupe(u8, entry.name),
            });
        }

        return result;
    }

    fn deinitArtistDirIndex(self: *Downloader, entries: *std.ArrayListUnmanaged(ArtistDirEntry)) void {
        for (entries.items) |entry| {
            self.allocator.free(entry.name);
        }
        entries.deinit(self.allocator);
    }

    fn findArtistDirEntry(self: *Downloader, entries: []ArtistDirEntry, uid: u64) ?*ArtistDirEntry {
        _ = self;
        for (entries) |*entry| {
            if (entry.uid == uid) return entry;
        }
        return null;
    }

    /// 将单位画师的作品分页抓取并持续入队。
    /// 这样生产者线程不需要等待该画师全部分页拉完，worker 可以更早开始下载。
    fn queueIllustratorDownloads(
        self: *Downloader,
        session: *DownloadSession,
        artist: *illustrator.Illustrator,
        base_dir: []const u8,
        artist_dir_index: *std.ArrayListUnmanaged(ArtistDirEntry),
        api: *pixiv_api.PixivApi,
    ) !void {
        const artist_name = artist.getOrFetchName(api) catch |err| {
            terminal.logError(self.io, "获取画师 {d} 信息失败: {s}，跳过", .{ artist.id, @errorName(err) });
            return err;
        };

        const artist_dir_alloc = self.getIllustratorNewDir(artist.id, artist_name, base_dir, artist_dir_index) catch |err| {
            terminal.logError(self.io, "创建画师目录失败: {s}", .{@errorName(err)});
            return err;
        };
        const artist_dir = session.ownDir(artist_dir_alloc) catch |err| {
            self.allocator.free(artist_dir_alloc);
            return err;
        };

        var queued_count: usize = 0;
        while (true) {
            const items = artist.illusts(api, self.config.no_ugoira_meta) catch |err| {
                terminal.logError(self.io, "获取画师 {d} 插画列表失败: {s}", .{ artist.id, @errorName(err) });
                break;
            };

            if (items.len == 0) {
                illust.deinitIllusts(self.allocator, items);
                break;
            }

            queued_count += items.len;
            try session.submitOwnedIllusts(artist_dir, items);

            if (!artist.hasNext(.illust)) break;
        }

        if (queued_count == 0) {
            terminal.logInfo(self.io, "画师 {d} 无插画，跳过", .{artist.id});
            return;
        }

        terminal.logInfo(self.io, "画师 {s} 已入队 {d} 个文件", .{ artist_name, queued_count });
    }

    fn resolveUgoiraDelay(self: *Downloader, api: *pixiv_api.PixivApi, item: illust.IllustEntryLite) !?u32 {
        if (self.config.no_ugoira_meta or !illust.isUgoiraLite(item)) return null;

        const parsed = try api.ugoiraMetaDataLite(item.id);
        defer parsed.deinit();

        if (parsed.value.ugoira_metadata.frames.len == 0) return null;
        return parsed.value.ugoira_metadata.frames[0].delay;
    }

    fn cloneIllusts(self: *Downloader, items: []const illust.Illust) ![]illust.Illust {
        var result = try self.allocator.alloc(illust.Illust, items.len);
        errdefer self.allocator.free(result);

        var cloned_count: usize = 0;
        errdefer {
            for (result[0..cloned_count]) |item| {
                item.deinit(self.allocator);
            }
        }

        for (items, 0..) |item, i| {
            result[i] = .{
                .id = item.id,
                .url = try self.allocator.dupe(u8, item.url),
                .file = try self.allocator.dupe(u8, item.file),
                .illust_type = item.illust_type,
            };
            cloned_count += 1;
        }
        return result;
    }
};

fn workerFunc(ctx: *WorkerContext) void {
    const session = ctx.session;
    const downloader = session.downloader;

    var http = http_client.HttpClient.init(downloader.allocator, downloader.io, downloader.proxy_config) catch return;
    defer http.deinit();

    const referer_header = std.http.Header{ .name = "referer", .value = REFERER };

    while (true) {
        if (session.state.is_paused.load(.acquire)) {
            std.Io.sleep(downloader.io, .fromSeconds(PAUSE_SECONDS), .real) catch {};
            session.state.is_paused.store(false, .release);
            session.state.failure_streak.store(0, .release);
            continue;
        }

        const task_info = waitForNextTask(ctx) orelse break;
        const task_index = task_info.index;
        const task = task_info.task;

        const final_path = std.fmt.allocPrint(downloader.allocator, "{s}/{s}", .{ task.final_dir, task.illust_item.file }) catch continue;
        defer downloader.allocator.free(final_path);

        if (fs.fileExists(downloader.io, final_path)) {
            session.state.failure_streak.store(0, .release);
            _ = session.state.skip_count.fetchAdd(1, .monotonic);
            const done = session.state.completed_count.fetchAdd(1, .monotonic) + 1;
            maybePrintProgress(ctx, done, task.illust_item.id, "exists");
            continue;
        }

        // 追加任务索引作为临时文件前缀，避免不同目录里同名文件在共享 tmp 目录中互相碰撞。
        const temp_path = std.fmt.allocPrint(downloader.allocator, "{s}/{d}_{s}", .{
            session.temp_dir,
            task_index,
            task.illust_item.file,
        }) catch continue;
        defer downloader.allocator.free(temp_path);

        var retry: u32 = 0;
        var download_ok = false;
        var is_404 = false;
        var last_error: ?anyerror = null;
        var last_status_code: ?u16 = null;

        while (retry <= MAX_RETRY) : (retry += 1) {
            if (session.state.is_paused.load(.acquire)) {
                std.Io.sleep(downloader.io, .fromSeconds(PAUSE_SECONDS), .real) catch {};
                session.state.is_paused.store(false, .release);
                session.state.failure_streak.store(0, .release);
                continue;
            }

            const download = http.downloadToFile(task.illust_item.url, &.{referer_header}, temp_path) catch |err| {
                last_error = err;
                std.Io.sleep(downloader.io, .fromMilliseconds(250), .real) catch {};
                continue;
            };

            const status_code = @intFromEnum(download.status);
            if (status_code == 404) {
                is_404 = true;
                fs.deleteFile(downloader.io, temp_path);
                break;
            }
            if (status_code < 200 or status_code >= 300) {
                last_status_code = status_code;
                fs.deleteFile(downloader.io, temp_path);
                std.Io.sleep(downloader.io, .fromMilliseconds(250), .real) catch {};
                continue;
            }
            if (download.bytes_written == 0) {
                last_error = error.EmptyDownloadBody;
                fs.deleteFile(downloader.io, temp_path);
                std.Io.sleep(downloader.io, .fromMilliseconds(250), .real) catch {};
                continue;
            }

            fs.moveFile(downloader.io, temp_path, final_path) catch |err| {
                last_error = err;
                fs.deleteFile(downloader.io, temp_path);
                std.Io.sleep(downloader.io, .fromMilliseconds(250), .real) catch {};
                continue;
            };

            download_ok = true;
            break;
        }

        if (download_ok) {
            session.state.failure_streak.store(0, .release);
            _ = session.state.success_count.fetchAdd(1, .monotonic);
            const done = session.state.completed_count.fetchAdd(1, .monotonic) + 1;
            maybePrintProgress(ctx, done, task.illust_item.id, "OK");
        } else if (is_404) {
            session.state.failure_streak.store(0, .release);
            _ = session.state.skip_count.fetchAdd(1, .monotonic);
            const done = session.state.completed_count.fetchAdd(1, .monotonic) + 1;
            maybePrintProgress(ctx, done, task.illust_item.id, "404");
        } else {
            _ = session.state.error_count.fetchAdd(1, .monotonic);
            const done = session.state.completed_count.fetchAdd(1, .monotonic) + 1;
            maybePrintProgress(ctx, done, task.illust_item.id, "FAIL");

            if (last_status_code) |status_code| {
                terminal.logError(downloader.io, "下载 PID {d} 失败，HTTP {d}，文件: {s}", .{
                    task.illust_item.id,
                    status_code,
                    task.illust_item.file,
                });
            } else if (last_error) |err| {
                terminal.logError(downloader.io, "下载 PID {d} 失败，原因: {s}，文件: {s}", .{
                    task.illust_item.id,
                    @errorName(err),
                    task.illust_item.file,
                });
            } else {
                terminal.logError(downloader.io, "下载 PID {d} 失败，原因未知，文件: {s}", .{
                    task.illust_item.id,
                    task.illust_item.file,
                });
            }

            const streak = session.state.failure_streak.fetchAdd(1, .acq_rel) + 1;
            if (streak >= PAUSE_FAILURE_THRESHOLD) {
                session.state.is_paused.store(true, .release);
                session.state.failure_streak.store(0, .release);
            }

            fs.deleteFile(downloader.io, temp_path);
        }
    }
}

fn waitForNextTask(ctx: *WorkerContext) ?struct { index: usize, task: DownloadTask } {
    const session = ctx.session;
    while (true) {
        const index = session.state.next_index.fetchAdd(1, .monotonic);

        while (true) {
            const enqueued = session.state.enqueued_count.load(.acquire);
            if (index < enqueued) {
                lockQueue(session);
                defer session.state.queue_mutex.unlock();

                if (index >= session.tasks.items.len) continue;
                return .{
                    .index = index,
                    .task = session.tasks.items[index],
                };
            }

            if (session.state.producer_closed.load(.acquire)) {
                return null;
            }

            std.Io.sleep(session.downloader.io, .fromMilliseconds(QUEUE_POLL_MS), .real) catch {};
        }
    }
}

/// 将高频逐文件输出改成限频聚合输出，避免多线程频繁刷新控制台拖慢吞吐。
fn maybePrintProgress(ctx: *WorkerContext, done: u32, pid: u64, status: []const u8) void {
    const session = ctx.session;
    const enqueued = session.state.enqueued_count.load(.acquire);
    const producer_closed = session.state.producer_closed.load(.acquire);

    if (!std.mem.eql(u8, status, "FAIL") and
        !std.mem.eql(u8, status, "404") and
        !(producer_closed and done == enqueued) and
        done % session.state.report_step != 0)
    {
        return;
    }

    var buf: [1024]u8 = undefined;
    var fw = std.Io.File.stdout().writer(session.downloader.io, &buf);
    if (std.mem.eql(u8, status, "OK")) {
        fw.interface.writeAll(terminal.colorCode(.green)) catch {};
    } else if (std.mem.eql(u8, status, "FAIL")) {
        fw.interface.writeAll(terminal.colorCode(.red)) catch {};
    } else if (std.mem.eql(u8, status, "404")) {
        fw.interface.writeAll(terminal.colorCode(.yellow)) catch {};
    } else {
        fw.interface.writeAll(terminal.colorCode(.gray)) catch {};
    }

    const success = session.state.success_count.load(.monotonic);
    const skipped = session.state.skip_count.load(.monotonic);
    const failed = session.state.error_count.load(.monotonic);
    const total_text = if (producer_closed) "共" else "已入队";

    fw.interface.print("[{d}] 已完成 {d} / {s} {d}  成功 {d}  跳过 {d}  失败 {d}  最近 pid {d}  {s}", .{
        ctx.thread_id,
        done,
        total_text,
        enqueued,
        success,
        skipped,
        failed,
        pid,
        status,
    }) catch {};
    fw.interface.writeAll(terminal.colorCode(.reset)) catch {};
    fw.interface.writeAll("\n") catch {};
    fw.flush() catch {};
}

fn lockQueue(session: *DownloadSession) void {
    while (!session.state.queue_mutex.tryLock()) {
        std.Io.sleep(session.downloader.io, .fromMilliseconds(1), .real) catch {};
    }
}

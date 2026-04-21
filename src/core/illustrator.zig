//! 画师数据模型模块
//! 管理画师信息、插画/收藏分页迭代。
//!
//! 分页模式:
//!   Pixiv API 每次返回约 30 条数据和一个 next_url 字段。
//!   Illustrator 维护 next_illust_url 和 next_bookmark_url 分别追踪
//!   插画列表和收藏列表的分页游标。
//!
//! 典型使用流程:
//!   var artist = Illustrator.init(allocator, user_id);
//!   while (true) {
//!       const items = try artist.illusts(&pixiv_api);
//!       if (items.len == 0) break;
//!       // 处理 items...
//!       illust.deinitIllusts(allocator, items);
//!       if (!artist.hasNext(.illust)) break;
//!   }

const std = @import("std");
const illust_mod = @import("illust.zig");
const pixiv_api = @import("../pixiv_api.zig");

/// 画师信息
pub const IllustratorInfo = struct {
    id: u64,
    name: ?[]const u8,
    allocator: std.mem.Allocator,

    pub fn deinit(self: *IllustratorInfo) void {
        if (self.name) |name| {
            self.allocator.free(name);
            self.name = null;
        }
    }

    /// 将名称所有权转移给调用方，避免中途再复制一次。
    pub fn takeName(self: *IllustratorInfo) []const u8 {
        std.debug.assert(self.name != null);
        const name = self.name.?;
        self.name = null;
        return name;
    }
};

/// 画师数据结构
pub const Illustrator = struct {
    allocator: std.mem.Allocator,
    id: u64,
    name: ?[]const u8 = null,
    next_illust_url: ?[]const u8 = null,
    next_bookmark_url: ?[]const u8 = null,
    next_following_url: ?[]const u8 = null,

    pub fn init(allocator: std.mem.Allocator, id: u64) Illustrator {
        return .{
            .allocator = allocator,
            .id = id,
        };
    }

    pub fn deinit(self: *Illustrator) void {
        if (self.name) |n| self.allocator.free(n);
        if (self.next_illust_url) |u| self.allocator.free(u);
        if (self.next_bookmark_url) |u| self.allocator.free(u);
        if (self.next_following_url) |u| self.allocator.free(u);
    }

    /// 设置画师名称（从外部数据源如关注列表预填）
    pub fn setName(self: *Illustrator, name: []const u8) !void {
        if (self.name) |n| {
            // 关注列表等场景里，名称可能已经提前缓存过；相同名称就不再重复分配。
            if (std.mem.eql(u8, n, name)) return;
            self.allocator.free(n);
        }
        self.name = try self.allocator.dupe(u8, name);
    }

    /// 直接接管一份已分配好的名称字符串，避免再次复制。
    pub fn setOwnedName(self: *Illustrator, owned_name: []const u8) void {
        if (self.name) |n| self.allocator.free(n);
        self.name = owned_name;
    }

    /// 分页游标类型
    pub const PageType = enum {
        illust,
        bookmark,
        following,
    };

    /// 检查指定类型的分页是否还有下一页
    pub fn hasNext(self: *const Illustrator, which: PageType) bool {
        return switch (which) {
            .illust => self.next_illust_url != null,
            .bookmark => self.next_bookmark_url != null,
            .following => self.next_following_url != null,
        };
    }

    /// 获取画师信息（如已缓存则直接返回）
    pub fn fetchInfo(self: *Illustrator, api: *pixiv_api.PixivApi) !IllustratorInfo {
        const name = try self.getOrFetchName(api);
        return .{ .id = self.id, .name = try self.allocator.dupe(u8, name), .allocator = self.allocator };
    }

    /// 获取画师名称，首次请求时写入缓存，后续直接借用缓存切片。
    /// 下载热路径优先使用这个接口，避免为了读名称再额外构造临时对象。
    pub fn getOrFetchName(self: *Illustrator, api: *pixiv_api.PixivApi) ![]const u8 {
        if (self.name) |n| return n;

        const parsed = try api.userDetailLite(self.id);
        defer parsed.deinit();
        self.name = try self.allocator.dupe(u8, parsed.value.user.name);
        return self.name.?;
    }

    /// 获取下一页插画（自动处理首次请求和分页）
    pub fn illusts(self: *Illustrator, api: *pixiv_api.PixivApi, no_ugoira_meta: bool) ![]illust_mod.Illust {
        const parsed = if (self.next_illust_url) |url|
            try api.nextPageParsed(pixiv_api.UserIllustsLite, url)
        else
            try api.userIllustsLite(self.id);
        defer parsed.deinit();

        return self.parseIllustResponseLite(api, parsed.value, .illust, no_ugoira_meta);
    }

    /// 获取下一页收藏插画
    pub fn bookmarks(self: *Illustrator, api: *pixiv_api.PixivApi, no_ugoira_meta: bool) ![]illust_mod.Illust {
        const parsed = if (self.next_bookmark_url) |url|
            try api.nextPageParsed(pixiv_api.UserIllustsLite, url)
        else
            try api.userBookmarksIllustLite(self.id);
        defer parsed.deinit();

        return self.parseIllustResponseLite(api, parsed.value, .bookmark, no_ugoira_meta);
    }

    /// 用轻量分页结构解析插画列表并更新分页游标。
    /// 这里直接消费定向解析结果，避免旧实现里遍历动态 JSON 树。
    fn parseIllustResponseLite(
        self: *Illustrator,
        api: *pixiv_api.PixivApi,
        page: pixiv_api.UserIllustsLite,
        which: PageType,
        no_ugoira_meta: bool,
    ) ![]illust_mod.Illust {
        if (page.next_url) |next_url| {
            const url_copy = try self.allocator.dupe(u8, next_url);
            switch (which) {
                .illust => {
                    if (self.next_illust_url) |u| self.allocator.free(u);
                    self.next_illust_url = url_copy;
                },
                .bookmark => {
                    if (self.next_bookmark_url) |u| self.allocator.free(u);
                    self.next_bookmark_url = url_copy;
                },
                .following => {
                    if (self.next_following_url) |u| self.allocator.free(u);
                    self.next_following_url = url_copy;
                },
            }
        } else {
            switch (which) {
                .illust => {
                    if (self.next_illust_url) |u| {
                        self.allocator.free(u);
                        self.next_illust_url = null;
                    }
                },
                .bookmark => {
                    if (self.next_bookmark_url) |u| {
                        self.allocator.free(u);
                        self.next_bookmark_url = null;
                    }
                },
                .following => {
                    if (self.next_following_url) |u| {
                        self.allocator.free(u);
                        self.next_following_url = null;
                    }
                },
            }
        }

        var result: std.ArrayListUnmanaged(illust_mod.Illust) = .empty;
        errdefer {
            for (result.items) |item| item.deinit(self.allocator);
            result.deinit(self.allocator);
        }

        for (page.illusts) |item| {
            const ugoira_delay = self.resolveUgoiraDelay(api, item, no_ugoira_meta) catch null;
            const parsed = illust_mod.parseIllustLite(self.allocator, item, ugoira_delay) catch continue;
            for (parsed) |il| {
                try result.append(self.allocator, il);
            }
            self.allocator.free(parsed);
        }

        return result.toOwnedSlice(self.allocator);
    }

    /// 只有在需要保留 ugoira 帧延迟命名时才额外请求元数据。
    /// 这里取第一帧 delay，与原有单值文件名格式保持一致。
    fn resolveUgoiraDelay(
        self: *Illustrator,
        api: *pixiv_api.PixivApi,
        item: illust_mod.IllustEntryLite,
        no_ugoira_meta: bool,
    ) !?u32 {
        _ = self;
        if (no_ugoira_meta or !illust_mod.isUgoiraLite(item)) return null;

        const parsed = try api.ugoiraMetaDataLite(item.id);
        defer parsed.deinit();

        if (parsed.value.ugoira_metadata.frames.len == 0) return null;
        return parsed.value.ugoira_metadata.frames[0].delay;
    }

    /// 获取下一页关注画师列表（公开）
    /// 返回 IllustratorInfo 数组（每个元素包含 id 和 name）
    pub fn following(self: *Illustrator, api: *pixiv_api.PixivApi) ![]IllustratorInfo {
        const parsed = if (self.next_following_url) |url|
            try api.nextPageParsed(pixiv_api.UserFollowingLite, url)
        else
            try api.userFollowingLite(self.id, "public");
        defer parsed.deinit();

        return self.parseFollowingResponseLite(parsed.value);
    }

    /// 获取下一页私密关注画师列表
    pub fn followingPrivate(self: *Illustrator, api: *pixiv_api.PixivApi) ![]IllustratorInfo {
        const parsed = if (self.next_following_url) |url|
            try api.nextPageParsed(pixiv_api.UserFollowingLite, url)
        else
            try api.userFollowingLite(self.id, "private");
        defer parsed.deinit();

        return self.parseFollowingResponseLite(parsed.value);
    }

    /// 关注列表只保留 id/name/next_url，避免旧实现里遍历整棵动态 JSON 树。
    fn parseFollowingResponseLite(self: *Illustrator, page: pixiv_api.UserFollowingLite) ![]IllustratorInfo {
        if (page.next_url) |next_url| {
            const url_copy = try self.allocator.dupe(u8, next_url);
            if (self.next_following_url) |u| self.allocator.free(u);
            self.next_following_url = url_copy;
        } else {
            if (self.next_following_url) |u| {
                self.allocator.free(u);
                self.next_following_url = null;
            }
        }

        var result: std.ArrayListUnmanaged(IllustratorInfo) = .empty;
        errdefer {
            for (result.items) |*item| item.deinit();
            result.deinit(self.allocator);
        }

        for (page.user_previews) |item| {
            try result.append(self.allocator, .{
                .id = item.user.id,
                .name = try self.allocator.dupe(u8, item.user.name),
                .allocator = self.allocator,
            });
        }

        return result.toOwnedSlice(self.allocator);
    }
};

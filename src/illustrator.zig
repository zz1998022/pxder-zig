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
const json_utils = @import("json_utils.zig");
const illust_mod = @import("illust.zig");
const pixiv_api = @import("pixiv_api.zig");

/// 画师信息
pub const IllustratorInfo = struct {
    id: u64,
    name: []const u8,
    allocator: std.mem.Allocator,

    pub fn deinit(self: *const IllustratorInfo) void {
        self.allocator.free(self.name);
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
        if (self.name) |n| self.allocator.free(n);
        self.name = try self.allocator.dupe(u8, name);
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
        if (self.name) |n| {
            return .{ .id = self.id, .name = try self.allocator.dupe(u8, n), .allocator = self.allocator };
        }

        const parsed = try api.userDetail(self.id);
        defer parsed.deinit();
        const json = parsed.value;

        if (json != .object) return error.InvalidUserDetail;
        const user_val = json.object.get("user") orelse return error.InvalidUserDetail;
        if (user_val != .object) return error.InvalidUserDetail;
        const name_str = json_utils.getFieldString(user_val, "name") orelse return error.InvalidUserDetail;

        self.name = try self.allocator.dupe(u8, name_str);
        return .{ .id = self.id, .name = try self.allocator.dupe(u8, name_str), .allocator = self.allocator };
    }

    /// 获取下一页插画（自动处理首次请求和分页）
    pub fn illusts(self: *Illustrator, api: *pixiv_api.PixivApi) ![]illust_mod.Illust {
        const parsed = if (self.next_illust_url) |url|
            try api.nextPage(url)
        else
            try api.userIllusts(self.id);
        defer parsed.deinit();

        return self.parseIllustResponse(parsed.value, .illust);
    }

    /// 获取下一页收藏插画
    pub fn bookmarks(self: *Illustrator, api: *pixiv_api.PixivApi) ![]illust_mod.Illust {
        const parsed = if (self.next_bookmark_url) |url|
            try api.nextPage(url)
        else
            try api.userBookmarksIllust(self.id);
        defer parsed.deinit();

        return self.parseIllustResponse(parsed.value, .bookmark);
    }

    /// 从 API 响应中解析插画列表并更新分页游标
    fn parseIllustResponse(self: *Illustrator, json: std.json.Value, which: PageType) ![]illust_mod.Illust {
        if (json != .object) return error.InvalidApiResponse;

        // 更新 next_url
        if (json_utils.getFieldString(json, "next_url")) |next_url| {
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

        // 解析 illusts 数组
        const illusts_array = json_utils.getFieldArray(json, "illusts") orelse return error.InvalidApiResponse;
        var result: std.ArrayListUnmanaged(illust_mod.Illust) = .empty;
        errdefer {
            for (result.items) |item| item.deinit(self.allocator);
            result.deinit(self.allocator);
        }

        for (illusts_array.items) |item| {
            const parsed = illust_mod.parseIllusts(self.allocator, item, null) catch continue;
            for (parsed) |il| {
                try result.append(self.allocator, il);
            }
            self.allocator.free(parsed);
        }

        return result.toOwnedSlice(self.allocator);
    }

    /// 获取下一页关注画师列表（公开）
    /// 返回 IllustratorInfo 数组（每个元素包含 id 和 name）
    pub fn following(self: *Illustrator, api: *pixiv_api.PixivApi) ![]IllustratorInfo {
        const parsed = if (self.next_following_url) |url|
            try api.nextPage(url)
        else
            try api.userFollowing(self.id, "public");
        defer parsed.deinit();

        return self.parseFollowingResponse(parsed.value);
    }

    /// 获取下一页私密关注画师列表
    pub fn followingPrivate(self: *Illustrator, api: *pixiv_api.PixivApi) ![]IllustratorInfo {
        const parsed = if (self.next_following_url) |url|
            try api.nextPage(url)
        else
            try api.userFollowing(self.id, "private");
        defer parsed.deinit();

        return self.parseFollowingResponse(parsed.value);
    }

    fn parseFollowingResponse(self: *Illustrator, json: std.json.Value) ![]IllustratorInfo {
        if (json != .object) return error.InvalidApiResponse;

        // Update next_url
        if (json_utils.getFieldString(json, "next_url")) |next_url| {
            const url_copy = try self.allocator.dupe(u8, next_url);
            if (self.next_following_url) |u| self.allocator.free(u);
            self.next_following_url = url_copy;
        } else {
            if (self.next_following_url) |u| {
                self.allocator.free(u);
                self.next_following_url = null;
            }
        }

        // Parse user_previews array
        const user_previews = json_utils.getFieldArray(json, "user_previews") orelse return error.InvalidApiResponse;
        var result: std.ArrayListUnmanaged(IllustratorInfo) = .empty;
        errdefer {
            for (result.items) |item| item.deinit();
            result.deinit(self.allocator);
        }

        for (user_previews.items) |item| {
            if (item != .object) continue;
            const user_val = item.object.get("user") orelse continue;
            if (user_val != .object) continue;
            const id = json_utils.getFieldInt(user_val, "id") orelse continue;
            const name = json_utils.getFieldString(user_val, "name") orelse continue;

            try result.append(self.allocator, .{
                .id = @intCast(id),
                .name = try self.allocator.dupe(u8, name),
                .allocator = self.allocator,
            });
        }

        return result.toOwnedSlice(self.allocator);
    }
};

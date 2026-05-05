const std = @import("std");
const chatgpt_http = @import("chatgpt_http.zig");
const c_time = @cImport({
    @cInclude("time.h");
});
const registry = @import("registry.zig");

pub const AuthInfo = struct {
    email: ?[]u8,
    chatgpt_account_id: ?[]u8,
    chatgpt_user_id: ?[]u8,
    record_key: ?[]u8,
    access_token: ?[]u8,
    refresh_token: ?[]u8,
    last_refresh: ?[]u8,
    plan: ?registry.PlanType,
    auth_mode: registry.AuthMode,

    pub fn deinit(self: *const AuthInfo, allocator: std.mem.Allocator) void {
        if (self.email) |e| allocator.free(e);
        if (self.chatgpt_account_id) |id| allocator.free(id);
        if (self.chatgpt_user_id) |id| allocator.free(id);
        if (self.record_key) |key| allocator.free(key);
        if (self.access_token) |token| allocator.free(token);
        if (self.refresh_token) |token| allocator.free(token);
        if (self.last_refresh) |value| allocator.free(value);
    }
};

const StandardAuthJson = struct {
    auth_mode: []const u8,
    OPENAI_API_KEY: ?[]const u8,
    tokens: struct {
        id_token: []const u8,
        access_token: []const u8,
        refresh_token: []const u8,
        account_id: []const u8,
    },
    last_refresh: []const u8,
};

const StoredAuthJson = struct {
    auth_mode: ?[]const u8 = null,
    OPENAI_API_KEY: ?[]const u8 = null,
    tokens: ?StoredTokens = null,
    last_refresh: ?[]const u8 = null,
};

const StoredTokens = struct {
    id_token: ?[]const u8 = null,
    access_token: ?[]const u8 = null,
    refresh_token: ?[]const u8 = null,
    account_id: ?[]const u8 = null,
};

const RefreshTokenResponse = struct {
    id_token: ?[]const u8 = null,
    access_token: ?[]const u8 = null,
    refresh_token: ?[]const u8 = null,
};

const RefreshTokenEndpoint = struct {
    value: []const u8,
    owned: bool,
};

fn normalizeEmailAlloc(allocator: std.mem.Allocator, email: []const u8) ![]u8 {
    var buf = try allocator.alloc(u8, email.len);
    for (email, 0..) |ch, i| {
        buf[i] = std.ascii.toLower(ch);
    }
    return buf;
}

fn recordKeyAlloc(
    allocator: std.mem.Allocator,
    chatgpt_user_id: []const u8,
    chatgpt_account_id: []const u8,
) ![]u8 {
    return std.fmt.allocPrint(allocator, "{s}::{s}", .{ chatgpt_user_id, chatgpt_account_id });
}

pub fn parseAuthInfo(allocator: std.mem.Allocator, auth_path: []const u8) !AuthInfo {
    var file = try std.fs.cwd().openFile(auth_path, .{});
    defer file.close();

    const data = try file.readToEndAlloc(allocator, 10 * 1024 * 1024);
    defer allocator.free(data);

    return try parseAuthInfoData(allocator, data);
}

pub fn parseAuthInfoData(allocator: std.mem.Allocator, data: []const u8) !AuthInfo {
    var parsed = try std.json.parseFromSlice(std.json.Value, allocator, data, .{});
    defer parsed.deinit();
    const root = parsed.value;
    switch (root) {
        .object => |obj| {
            if (obj.get("OPENAI_API_KEY")) |key_val| {
                switch (key_val) {
                    .string => |s| {
                        if (s.len > 0) return AuthInfo{
                            .email = null,
                            .chatgpt_account_id = null,
                            .chatgpt_user_id = null,
                            .record_key = null,
                            .access_token = null,
                            .refresh_token = null,
                            .last_refresh = null,
                            .plan = null,
                            .auth_mode = .apikey,
                        };
                    },
                    else => {},
                }
            }

            var last_refresh = if (obj.get("last_refresh")) |last_refresh_val| switch (last_refresh_val) {
                .string => |s| if (s.len > 0) try allocator.dupe(u8, s) else null,
                else => null,
            } else null;
            defer if (last_refresh) |value| allocator.free(value);

            if (obj.get("tokens")) |tokens_val| {
                switch (tokens_val) {
                    .object => |tobj| {
                        var access_token: ?[]u8 = null;
                        defer if (access_token) |token| allocator.free(token);
                        access_token = if (tobj.get("access_token")) |access_token_val| switch (access_token_val) {
                            .string => |s| if (s.len > 0) try allocator.dupe(u8, s) else null,
                            else => null,
                        } else null;
                        var refresh_token: ?[]u8 = null;
                        defer if (refresh_token) |token| allocator.free(token);
                        refresh_token = if (tobj.get("refresh_token")) |refresh_token_val| switch (refresh_token_val) {
                            .string => |s| if (s.len > 0) try allocator.dupe(u8, s) else null,
                            else => null,
                        } else null;
                        var token_chatgpt_account_id: ?[]u8 = null;
                        defer if (token_chatgpt_account_id) |id| allocator.free(id);
                        token_chatgpt_account_id = if (tobj.get("account_id")) |account_id_val| switch (account_id_val) {
                            .string => |s| if (s.len > 0) try allocator.dupe(u8, s) else null,
                            else => null,
                        } else null;
                        if (tobj.get("id_token")) |id_tok| {
                            switch (id_tok) {
                                .string => |jwt| {
                                    const payload = try decodeJwtPayload(allocator, jwt);
                                    defer allocator.free(payload);
                                    var payload_json = try std.json.parseFromSlice(std.json.Value, allocator, payload, .{});
                                    defer payload_json.deinit();
                                    const claims = payload_json.value;

                                    var jwt_chatgpt_account_id: ?[]u8 = null;
                                    defer if (jwt_chatgpt_account_id) |id| allocator.free(id);
                                    var chatgpt_user_id: ?[]u8 = null;
                                    defer if (chatgpt_user_id) |id| allocator.free(id);
                                    switch (claims) {
                                        .object => |cobj| {
                                            var email: ?[]u8 = null;
                                            defer if (email) |e| allocator.free(e);
                                            if (cobj.get("email")) |e| {
                                                switch (e) {
                                                    .string => |s| email = try normalizeEmailAlloc(allocator, s),
                                                    else => {},
                                                }
                                            }

                                            var plan: ?registry.PlanType = null;
                                            if (cobj.get("https://api.openai.com/auth")) |auth_obj| {
                                                switch (auth_obj) {
                                                    .object => |aobj| {
                                                        if (aobj.get("chatgpt_account_id")) |ai| {
                                                            switch (ai) {
                                                                .string => |s| {
                                                                    if (s.len > 0) {
                                                                        jwt_chatgpt_account_id = try allocator.dupe(u8, s);
                                                                    }
                                                                },
                                                                else => {},
                                                            }
                                                        }
                                                        if (aobj.get("chatgpt_plan_type")) |pt| {
                                                            switch (pt) {
                                                                .string => |s| plan = parsePlanType(s),
                                                                else => {},
                                                            }
                                                        }
                                                        if (aobj.get("chatgpt_user_id")) |uid| {
                                                            switch (uid) {
                                                                .string => |s| {
                                                                    if (s.len > 0) {
                                                                        chatgpt_user_id = try allocator.dupe(u8, s);
                                                                    }
                                                                },
                                                                else => {},
                                                            }
                                                        } else if (aobj.get("user_id")) |uid| {
                                                            switch (uid) {
                                                                .string => |s| {
                                                                    if (s.len > 0) {
                                                                        chatgpt_user_id = try allocator.dupe(u8, s);
                                                                    }
                                                                },
                                                                else => {},
                                                            }
                                                        }
                                                    },
                                                    else => {},
                                                }
                                            }

                                            const chatgpt_account_id = token_chatgpt_account_id orelse return error.MissingAccountId;
                                            if (jwt_chatgpt_account_id == null) return error.MissingAccountId;
                                            if (!std.mem.eql(u8, chatgpt_account_id, jwt_chatgpt_account_id.?)) return error.AccountIdMismatch;
                                            allocator.free(jwt_chatgpt_account_id.?);
                                            jwt_chatgpt_account_id = null;
                                            const chatgpt_user_id_value = chatgpt_user_id orelse return error.MissingChatgptUserId;
                                            const record_key = try recordKeyAlloc(allocator, chatgpt_user_id_value, chatgpt_account_id);

                                            const info = AuthInfo{
                                                .email = email,
                                                .chatgpt_account_id = chatgpt_account_id,
                                                .chatgpt_user_id = chatgpt_user_id_value,
                                                .record_key = record_key,
                                                .access_token = access_token,
                                                .refresh_token = refresh_token,
                                                .last_refresh = last_refresh,
                                                .plan = plan,
                                                .auth_mode = .chatgpt,
                                            };
                                            email = null;
                                            token_chatgpt_account_id = null;
                                            chatgpt_user_id = null;
                                            access_token = null;
                                            refresh_token = null;
                                            last_refresh = null;
                                            return info;
                                        },
                                        else => {},
                                    }
                                },
                                else => {},
                            }
                        }
                    },
                    else => {},
                }
            }
        },
        else => {},
    }

    return AuthInfo{
        .email = null,
        .chatgpt_account_id = null,
        .chatgpt_user_id = null,
        .record_key = null,
        .access_token = null,
        .refresh_token = null,
        .last_refresh = null,
        .plan = null,
        .auth_mode = .chatgpt,
    };
}

pub fn convertCpaAuthJson(allocator: std.mem.Allocator, data: []const u8) ![]u8 {
    var parsed = try std.json.parseFromSlice(std.json.Value, allocator, data, .{});
    defer parsed.deinit();

    const obj = switch (parsed.value) {
        .object => |obj| obj,
        else => return error.InvalidCpaFormat,
    };

    const refresh_token = jsonStringField(obj, "refresh_token") orelse return error.MissingRefreshToken;
    if (refresh_token.len == 0) return error.MissingRefreshToken;

    var out: std.Io.Writer.Allocating = .init(allocator);
    errdefer out.deinit();

    try std.json.Stringify.value(StandardAuthJson{
        .auth_mode = "chatgpt",
        .OPENAI_API_KEY = null,
        .tokens = .{
            .id_token = jsonStringFieldOrDefault(obj, "id_token"),
            .access_token = jsonStringFieldOrDefault(obj, "access_token"),
            .refresh_token = refresh_token,
            .account_id = jsonStringFieldOrDefault(obj, "account_id"),
        },
        .last_refresh = jsonStringFieldOrDefault(obj, "last_refresh"),
    }, .{ .whitespace = .indent_2 }, &out.writer);
    try out.writer.writeAll("\n");
    return try out.toOwnedSlice();
}

pub fn decodeJwtPayload(allocator: std.mem.Allocator, jwt: []const u8) ![]u8 {
    var it = std.mem.splitScalar(u8, jwt, '.');
    _ = it.next();
    const payload_b64 = it.next() orelse return error.InvalidJwt;
    _ = it.next() orelse return error.InvalidJwt;

    const decoded = try base64UrlNoPadDecode(allocator, payload_b64);
    return decoded;
}

fn base64UrlNoPadDecode(allocator: std.mem.Allocator, input: []const u8) ![]u8 {
    const decoder = std.base64.url_safe_no_pad.Decoder;
    const out_len = decoder.calcSizeForSlice(input) catch return error.InvalidBase64;
    const buf = try allocator.alloc(u8, out_len);
    errdefer allocator.free(buf);
    decoder.decode(buf, input) catch return error.InvalidBase64;
    return buf;
}

fn parsePlanType(s: []const u8) registry.PlanType {
    if (std.ascii.eqlIgnoreCase(s, "free")) return .free;
    if (std.ascii.eqlIgnoreCase(s, "plus")) return .plus;
    if (std.ascii.eqlIgnoreCase(s, "pro")) return .pro;
    if (std.ascii.eqlIgnoreCase(s, "team")) return .team;
    if (std.ascii.eqlIgnoreCase(s, "business")) return .business;
    if (std.ascii.eqlIgnoreCase(s, "enterprise")) return .enterprise;
    if (std.ascii.eqlIgnoreCase(s, "edu")) return .edu;
    return .unknown;
}

fn jsonStringField(obj: std.json.ObjectMap, key: []const u8) ?[]const u8 {
    const value = obj.get(key) orelse return null;
    return switch (value) {
        .string => |s| s,
        else => null,
    };
}

fn jsonStringFieldOrDefault(obj: std.json.ObjectMap, key: []const u8) []const u8 {
    return jsonStringField(obj, key) orelse "";
}

pub fn refreshAuthAtPath(allocator: std.mem.Allocator, auth_path: []const u8) !bool {
    const auth_data = try readAuthFileAlloc(allocator, auth_path);
    defer allocator.free(auth_data);

    var parsed = try std.json.parseFromSlice(StoredAuthJson, allocator, auth_data, .{});
    defer parsed.deinit();

    const stored = parsed.value;
    const tokens = stored.tokens orelse return false;
    const refresh_token = tokens.refresh_token orelse return false;
    if (refresh_token.len == 0) return false;

    const endpoint = try resolveRefreshTokenEndpoint(allocator);
    defer if (endpoint.owned) allocator.free(endpoint.value);

    const http_result = chatgpt_http.runRefreshTokenCommand(
        allocator,
        endpoint.value,
        refresh_token,
    ) catch return false;
    defer allocator.free(http_result.body);

    const status_code = http_result.status_code orelse return false;
    if (status_code < 200 or status_code >= 300) return false;

    var refresh_response = std.json.parseFromSlice(RefreshTokenResponse, allocator, http_result.body, .{}) catch return false;
    defer refresh_response.deinit();

    const refreshed_auth_json = try buildRefreshedAuthJson(
        allocator,
        stored,
        refresh_response.value,
    );
    defer allocator.free(refreshed_auth_json);

    try writeFileReplace(auth_path, refreshed_auth_json);
    return true;
}

fn readAuthFileAlloc(allocator: std.mem.Allocator, auth_path: []const u8) ![]u8 {
    var file = try std.fs.cwd().openFile(auth_path, .{});
    defer file.close();
    return try file.readToEndAlloc(allocator, 10 * 1024 * 1024);
}

fn resolveRefreshTokenEndpoint(allocator: std.mem.Allocator) !RefreshTokenEndpoint {
    return .{
        .value = std.process.getEnvVarOwned(allocator, chatgpt_http.refresh_token_url_override_env) catch |err| switch (err) {
            error.EnvironmentVariableNotFound => return .{
                .value = chatgpt_http.default_refresh_token_endpoint,
                .owned = false,
            },
            else => return err,
        },
        .owned = true,
    };
}

fn buildRefreshedAuthJson(
    allocator: std.mem.Allocator,
    stored: StoredAuthJson,
    refresh_response: RefreshTokenResponse,
) ![]u8 {
    const existing_tokens = stored.tokens orelse return error.MissingRefreshToken;
    const id_token = preferNonEmpty(refresh_response.id_token, existing_tokens.id_token);
    const access_token = preferNonEmpty(refresh_response.access_token, existing_tokens.access_token);
    const refresh_token = preferNonEmpty(refresh_response.refresh_token, existing_tokens.refresh_token);
    const account_id = existing_tokens.account_id orelse "";
    const refreshed_at = try formatUtcIso8601Alloc(allocator, std.time.timestamp());
    defer allocator.free(refreshed_at);

    var out: std.Io.Writer.Allocating = .init(allocator);
    errdefer out.deinit();

    try std.json.Stringify.value(StandardAuthJson{
        .auth_mode = stored.auth_mode orelse "chatgpt",
        .OPENAI_API_KEY = stored.OPENAI_API_KEY,
        .tokens = .{
            .id_token = id_token orelse "",
            .access_token = access_token orelse "",
            .refresh_token = refresh_token orelse "",
            .account_id = account_id,
        },
        .last_refresh = refreshed_at,
    }, .{ .whitespace = .indent_2 }, &out.writer);
    try out.writer.writeAll("\n");
    return try out.toOwnedSlice();
}

fn preferNonEmpty(primary: ?[]const u8, fallback: ?[]const u8) ?[]const u8 {
    if (primary) |value| {
        if (value.len > 0) return value;
    }
    if (fallback) |value| {
        if (value.len > 0) return value;
    }
    return null;
}

fn formatUtcIso8601Alloc(allocator: std.mem.Allocator, ts: i64) ![]u8 {
    var tm: c_time.struct_tm = undefined;
    if (!gmtimeCompat(ts, &tm)) {
        return std.fmt.allocPrint(allocator, "{d}", .{ts});
    }

    const year: u32 = @intCast(tm.tm_year + 1900);
    const month: u32 = @intCast(tm.tm_mon + 1);
    const day: u32 = @intCast(tm.tm_mday);
    const hour: u32 = @intCast(tm.tm_hour);
    const minute: u32 = @intCast(tm.tm_min);
    const second: u32 = @intCast(tm.tm_sec);
    return std.fmt.allocPrint(allocator, "{d:0>4}-{d:0>2}-{d:0>2}T{d:0>2}:{d:0>2}:{d:0>2}Z", .{
        year,
        month,
        day,
        hour,
        minute,
        second,
    });
}

fn gmtimeCompat(ts: i64, out_tm: *c_time.struct_tm) bool {
    if (comptime @import("builtin").os.tag == .windows) {
        if (comptime @hasDecl(c_time, "_gmtime64_s") and @hasDecl(c_time, "__time64_t")) {
            const t64: c_time.__time64_t = @intCast(ts);
            return c_time._gmtime64_s(out_tm, &t64) == 0;
        }
        return false;
    }

    const t: c_time.time_t = @intCast(ts);
    if (comptime @hasDecl(c_time, "gmtime_r")) {
        return c_time.gmtime_r(&t, out_tm) != null;
    }
    if (comptime @hasDecl(c_time, "gmtime")) {
        const tm_ptr = c_time.gmtime(&t);
        if (tm_ptr == null) return false;
        out_tm.* = tm_ptr.*;
        return true;
    }
    return false;
}

fn writeFileReplace(path: []const u8, data: []const u8) !void {
    const allocator = std.heap.page_allocator;
    const temp_path = try std.fmt.allocPrint(allocator, "{s}.tmp.{d}", .{ path, std.time.nanoTimestamp() });
    defer allocator.free(temp_path);

    {
        var file = try std.fs.cwd().createFile(temp_path, .{ .truncate = true });
        defer file.close();
        try file.writeAll(data);
        try file.sync();
    }

    errdefer std.fs.cwd().deleteFile(temp_path) catch {};
    std.fs.cwd().rename(temp_path, path) catch |err| switch (err) {
        error.PathAlreadyExists => {
            std.fs.cwd().deleteFile(path) catch |delete_err| switch (delete_err) {
                error.FileNotFound => {},
                else => return delete_err,
            };
            try std.fs.cwd().rename(temp_path, path);
        },
        else => return err,
    };
}

const std = @import("std");
const display_rows = @import("../display_rows.zig");
const registry = @import("../registry.zig");

fn makeRegistry() registry.Registry {
    return .{
        .schema_version = registry.current_schema_version,
        .active_account_key = null,
        .active_account_activated_at_ms = null,
        .auto_switch = registry.defaultAutoSwitchConfig(),
        .api = registry.defaultApiConfig(),
        .accounts = std.ArrayList(registry.AccountRecord).empty,
    };
}

fn appendAccount(
    allocator: std.mem.Allocator,
    reg: *registry.Registry,
    record_key: []const u8,
    email: []const u8,
    alias: []const u8,
    plan: registry.PlanType,
) !void {
    const sep = std.mem.lastIndexOf(u8, record_key, "::") orelse return error.InvalidRecordKey;
    const chatgpt_user_id = record_key[0..sep];
    const chatgpt_account_id = record_key[sep + 2 ..];
    try reg.accounts.append(allocator, .{
        .account_key = try allocator.dupe(u8, record_key),
        .chatgpt_account_id = try allocator.dupe(u8, chatgpt_account_id),
        .chatgpt_user_id = try allocator.dupe(u8, chatgpt_user_id),
        .email = try allocator.dupe(u8, email),
        .alias = try allocator.dupe(u8, alias),
        .account_name = null,
        .plan = plan,
        .auth_mode = .chatgpt,
        .created_at = 1,
        .last_used_at = null,
        .last_usage = null,
        .last_usage_at = null,
        .last_local_rollout = null,
    });
}

fn setWeeklyWindow(rec: *registry.AccountRecord, remaining_percent: f64, resets_at: i64) void {
    rec.last_usage = .{
        .primary = null,
        .secondary = .{
            .used_percent = 100.0 - remaining_percent,
            .window_minutes = 10080,
            .resets_at = resets_at,
        },
        .credits = null,
        .plan_type = rec.plan,
    };
    rec.last_usage_at = std.time.timestamp();
}

fn setUsageWindows(rec: *registry.AccountRecord, remaining_5h_percent: f64, remaining_weekly_percent: f64, weekly_resets_at: i64) void {
    rec.last_usage = .{
        .primary = .{
            .used_percent = 100.0 - remaining_5h_percent,
            .window_minutes = 300,
            .resets_at = weekly_resets_at,
        },
        .secondary = .{
            .used_percent = 100.0 - remaining_weekly_percent,
            .window_minutes = 10080,
            .resets_at = weekly_resets_at,
        },
        .credits = null,
        .plan_type = rec.plan,
    };
    rec.last_usage_at = std.time.timestamp();
}

test "Scenario: Given same email with two team accounts and one plus account when building display rows then they are grouped and numbered" {
    const gpa = std.testing.allocator;
    var reg = makeRegistry();
    defer reg.deinit(gpa);

    try appendAccount(gpa, &reg, "user-ESYgcy2QkOGZc0NoxSlFCeVT::67fe2bbb-0de6-49a4-b2b3-d1df366d1faf", "user@example.com", "", .team);
    try appendAccount(gpa, &reg, "user-ESYgcy2QkOGZc0NoxSlFCeVT::518a44d9-ba75-4bad-87e5-ae9377042960", "user@example.com", "", .team);
    try appendAccount(gpa, &reg, "user-ESYgcy2QkOGZc0NoxSlFCeVT::a4021fa5-998b-4774-989f-784fa69c367b", "user@example.com", "", .plus);
    try registry.setActiveAccountKey(gpa, &reg, "user-ESYgcy2QkOGZc0NoxSlFCeVT::518a44d9-ba75-4bad-87e5-ae9377042960");

    var rows = try display_rows.buildDisplayRows(gpa, &reg, null);
    defer rows.deinit(gpa);

    try std.testing.expect(rows.rows.len == 4);
    try std.testing.expect(rows.rows[0].account_index == null);
    try std.testing.expect(std.mem.eql(u8, rows.rows[0].account_cell, "user@example.com"));
    try std.testing.expect(std.mem.eql(u8, rows.rows[1].account_cell, "team #1"));
    try std.testing.expect(rows.rows[1].is_active);
    try std.testing.expect(std.mem.eql(u8, rows.rows[2].account_cell, "team #2"));
    try std.testing.expect(std.mem.eql(u8, rows.rows[3].account_cell, "plus"));
    try std.testing.expect(rows.selectable_row_indices.len == 3);
}

test "Scenario: Given grouped accounts with aliases when building display rows then aliases override numbered plan labels" {
    const gpa = std.testing.allocator;
    var reg = makeRegistry();
    defer reg.deinit(gpa);

    try appendAccount(gpa, &reg, "user-ESYgcy2QkOGZc0NoxSlFCeVT::67fe2bbb-0de6-49a4-b2b3-d1df366d1faf", "user@example.com", "work", .team);
    try appendAccount(gpa, &reg, "user-ESYgcy2QkOGZc0NoxSlFCeVT::518a44d9-ba75-4bad-87e5-ae9377042960", "user@example.com", "backup", .team);

    var rows = try display_rows.buildDisplayRows(gpa, &reg, null);
    defer rows.deinit(gpa);

    try std.testing.expect(rows.rows.len == 3);
    try std.testing.expect(std.mem.eql(u8, rows.rows[1].account_cell, "backup") or std.mem.eql(u8, rows.rows[1].account_cell, "work"));
    try std.testing.expect(std.mem.eql(u8, rows.rows[2].account_cell, "backup") or std.mem.eql(u8, rows.rows[2].account_cell, "work"));
}

test "Scenario: Given same-email accounts filtered down to one row when building display rows then singleton is decided from the rendered subset" {
    const gpa = std.testing.allocator;
    var reg = makeRegistry();
    defer reg.deinit(gpa);

    try appendAccount(gpa, &reg, "user-ESYgcy2QkOGZc0NoxSlFCeVT::67fe2bbb-0de6-49a4-b2b3-d1df366d1faf", "user@example.com", "work", .team);
    reg.accounts.items[0].account_name = try gpa.dupe(u8, "Primary Workspace");
    try appendAccount(gpa, &reg, "user-ESYgcy2QkOGZc0NoxSlFCeVT::a4021fa5-998b-4774-989f-784fa69c367b", "user@example.com", "", .plus);

    var grouped_rows = try display_rows.buildDisplayRows(gpa, &reg, null);
    defer grouped_rows.deinit(gpa);
    try std.testing.expectEqual(@as(usize, 3), grouped_rows.rows.len);
    try std.testing.expect(grouped_rows.rows[0].account_index == null);
    try std.testing.expect(std.mem.eql(u8, grouped_rows.rows[0].account_cell, "user@example.com"));

    const indices = [_]usize{0};
    var singleton_rows = try display_rows.buildDisplayRows(gpa, &reg, &indices);
    defer singleton_rows.deinit(gpa);
    try std.testing.expectEqual(@as(usize, 1), singleton_rows.rows.len);
    try std.testing.expect(singleton_rows.rows[0].account_index != null);
    try std.testing.expect(std.mem.eql(u8, singleton_rows.rows[0].account_cell, "user@example.com"));
}

test "Scenario: Given singleton accounts with alias and account name combinations when building display rows then email labels are preserved" {
    const gpa = std.testing.allocator;
    var reg = makeRegistry();
    defer reg.deinit(gpa);

    try appendAccount(gpa, &reg, "user-4QmYj7PkN2sLx8AcVbR3TwHd::67fe2bbb-0de6-49a4-b2b3-d1df366d1faf", "alias-name@example.com", "work", .team);
    reg.accounts.items[0].account_name = try gpa.dupe(u8, "Primary Workspace");
    try appendAccount(gpa, &reg, "user-8LnCq5VzR1mHx9SfKpT4JdWe::518a44d9-ba75-4bad-87e5-ae9377042960", "alias-only@example.com", "backup", .team);
    try appendAccount(gpa, &reg, "user-2RbFk6NsQ8vLp3XtJmW7CyHa::a4021fa5-998b-4774-989f-784fa69c367b", "name-only@example.com", "", .team);
    reg.accounts.items[2].account_name = try gpa.dupe(u8, "Sandbox");
    try appendAccount(gpa, &reg, "user-9TwHs4KmP7xNc2LdVrQ6BjYe::d8f0f19d-7b6f-4db8-b7a8-07b9fbf5774a", "fallback@example.com", "", .team);

    var rows = try display_rows.buildDisplayRows(gpa, &reg, null);
    defer rows.deinit(gpa);

    try std.testing.expectEqual(@as(usize, 4), rows.rows.len);
    try std.testing.expect(std.mem.eql(u8, rows.rows[0].account_cell, "alias-name@example.com"));
    try std.testing.expect(std.mem.eql(u8, rows.rows[1].account_cell, "alias-only@example.com"));
    try std.testing.expect(std.mem.eql(u8, rows.rows[2].account_cell, "fallback@example.com"));
    try std.testing.expect(std.mem.eql(u8, rows.rows[3].account_cell, "name-only@example.com"));
}

test "Scenario: Given mixed singleton and grouped accounts when building display rows then singleton rows keep email while grouped rows keep preferred labels" {
    const gpa = std.testing.allocator;
    var reg = makeRegistry();
    defer reg.deinit(gpa);

    try appendAccount(gpa, &reg, "user-6JpMv8XrT3nLc9QsHbW4DyKa::67fe2bbb-0de6-49a4-b2b3-d1df366d1faf", "solo@example.com", "solo", .team);
    reg.accounts.items[0].account_name = try gpa.dupe(u8, "Solo Workspace");
    try appendAccount(gpa, &reg, "user-1ZdKr5NtV8mQx3LsHpW7CyFb::518a44d9-ba75-4bad-87e5-ae9377042960", "user@example.com", "work", .team);
    reg.accounts.items[1].account_name = try gpa.dupe(u8, "Primary Workspace");
    try appendAccount(gpa, &reg, "user-1ZdKr5NtV8mQx3LsHpW7CyFb::a4021fa5-998b-4774-989f-784fa69c367b", "user@example.com", "", .plus);

    var rows = try display_rows.buildDisplayRows(gpa, &reg, null);
    defer rows.deinit(gpa);

    try std.testing.expectEqual(@as(usize, 4), rows.rows.len);
    try std.testing.expect(std.mem.eql(u8, rows.rows[0].account_cell, "solo@example.com"));
    try std.testing.expect(rows.rows[1].account_index == null);
    try std.testing.expect(std.mem.eql(u8, rows.rows[1].account_cell, "user@example.com"));
    try std.testing.expect(std.mem.eql(u8, rows.rows[2].account_cell, "work (Primary Workspace)"));
    try std.testing.expect(std.mem.eql(u8, rows.rows[3].account_cell, "plus"));
}

test "Scenario: Given grouped accounts with account names when building display rows then child labels use the same precedence" {
    const gpa = std.testing.allocator;
    var reg = makeRegistry();
    defer reg.deinit(gpa);

    try appendAccount(gpa, &reg, "user-ESYgcy2QkOGZc0NoxSlFCeVT::67fe2bbb-0de6-49a4-b2b3-d1df366d1faf", "user@example.com", "work", .team);
    reg.accounts.items[0].account_name = try gpa.dupe(u8, "Primary Workspace");
    try appendAccount(gpa, &reg, "user-ESYgcy2QkOGZc0NoxSlFCeVT::518a44d9-ba75-4bad-87e5-ae9377042960", "user@example.com", "", .team);
    reg.accounts.items[1].account_name = try gpa.dupe(u8, "Backup Workspace");
    try appendAccount(gpa, &reg, "user-ESYgcy2QkOGZc0NoxSlFCeVT::a4021fa5-998b-4774-989f-784fa69c367b", "user@example.com", "", .plus);

    var rows = try display_rows.buildDisplayRows(gpa, &reg, null);
    defer rows.deinit(gpa);

    try std.testing.expectEqual(@as(usize, 4), rows.rows.len);
    try std.testing.expect(
        (std.mem.eql(u8, rows.rows[1].account_cell, "work (Primary Workspace)") and
            std.mem.eql(u8, rows.rows[2].account_cell, "Backup Workspace")) or
            (std.mem.eql(u8, rows.rows[1].account_cell, "Backup Workspace") and
                std.mem.eql(u8, rows.rows[2].account_cell, "work (Primary Workspace)")),
    );
    try std.testing.expect(std.mem.eql(u8, rows.rows[3].account_cell, "plus"));
}

test "Scenario: Given accounts with different weekly and 5h usage when building display rows then higher weekly usage comes first and ties use higher 5h usage" {
    const gpa = std.testing.allocator;
    var reg = makeRegistry();
    defer reg.deinit(gpa);

    const now = std.time.timestamp();
    try appendAccount(gpa, &reg, "user-low-week::acct-low-week", "low-week@example.com", "", .plus);
    try appendAccount(gpa, &reg, "user-mid-week-low-5h::acct-mid-week-low-5h", "mid-week-low-5h@example.com", "", .plus);
    try appendAccount(gpa, &reg, "user-mid-week-high-5h::acct-mid-week-high-5h", "mid-week-high-5h@example.com", "", .team);
    try appendAccount(gpa, &reg, "user-high-week::acct-high-week", "high-week@example.com", "", .team);

    setUsageWindows(&reg.accounts.items[0], 90.0, 10.0, now + 7200);
    setUsageWindows(&reg.accounts.items[1], 30.0, 60.0, now + 3600);
    setUsageWindows(&reg.accounts.items[2], 75.0, 60.0, now + 10800);
    setUsageWindows(&reg.accounts.items[3], 20.0, 85.0, now + 1800);

    var rows = try display_rows.buildDisplayRows(gpa, &reg, null);
    defer rows.deinit(gpa);

    try std.testing.expectEqual(@as(usize, 4), rows.rows.len);
    try std.testing.expect(std.mem.eql(u8, rows.rows[0].account_cell, "high-week@example.com"));
    try std.testing.expect(std.mem.eql(u8, rows.rows[1].account_cell, "mid-week-high-5h@example.com"));
    try std.testing.expect(std.mem.eql(u8, rows.rows[2].account_cell, "mid-week-low-5h@example.com"));
    try std.testing.expect(std.mem.eql(u8, rows.rows[3].account_cell, "low-week@example.com"));
}

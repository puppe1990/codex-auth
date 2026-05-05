const std = @import("std");
const builtin = @import("builtin");

pub const request_timeout_secs: []const u8 = "5";
pub const default_refresh_token_endpoint = "https://auth.openai.com/oauth/token";
pub const refresh_token_client_id = "app_EMoamEEZ73f0CkXaXp7hrann";
pub const refresh_token_url_override_env = "CODEX_REFRESH_TOKEN_URL_OVERRIDE";

pub const HttpResult = struct {
    body: []u8,
    status_code: ?u16,
};

const ParsedCurlHttpOutput = struct {
    body: []const u8,
    status_code: ?u16,
};

pub fn runGetJsonCommand(
    allocator: std.mem.Allocator,
    endpoint: []const u8,
    access_token: []const u8,
    account_id: []const u8,
) !HttpResult {
    return if (builtin.os.tag == .windows)
        runPowerShellGetJsonCommand(allocator, endpoint, access_token, account_id)
    else
        runCurlGetJsonCommand(allocator, endpoint, access_token, account_id);
}

pub fn runRefreshTokenCommand(
    allocator: std.mem.Allocator,
    endpoint: []const u8,
    refresh_token: []const u8,
) !HttpResult {
    return if (builtin.os.tag == .windows)
        runPowerShellRefreshTokenCommand(allocator, endpoint, refresh_token)
    else
        runCurlRefreshTokenCommand(allocator, endpoint, refresh_token);
}

fn runCurlGetJsonCommand(
    allocator: std.mem.Allocator,
    endpoint: []const u8,
    access_token: []const u8,
    account_id: []const u8,
) !HttpResult {
    const authorization = try std.fmt.allocPrint(allocator, "Authorization: Bearer {s}", .{access_token});
    defer allocator.free(authorization);
    const account_header = try std.fmt.allocPrint(allocator, "ChatGPT-Account-Id: {s}", .{account_id});
    defer allocator.free(account_header);

    var argv = std.ArrayList([]const u8).empty;
    defer argv.deinit(allocator);

    try argv.appendSlice(allocator, &.{
        "curl",
        "--silent",
        "--show-error",
        "--location",
        "--connect-timeout",
        request_timeout_secs,
        "--max-time",
        request_timeout_secs,
        "--write-out",
        "\n%{http_code}",
        "-H",
        authorization,
    });
    try argv.appendSlice(allocator, &.{ "-H", account_header });
    try argv.appendSlice(allocator, &.{
        "-H",
        "User-Agent: codex-auth",
        endpoint,
    });

    const result = try std.process.Child.run(.{
        .allocator = allocator,
        .argv = argv.items,
        .max_output_bytes = 1024 * 1024,
    });
    defer allocator.free(result.stderr);
    defer allocator.free(result.stdout);

    const code = switch (result.term) {
        .Exited => |exit_code| exit_code,
        else => return error.RequestFailed,
    };
    if (code != 0) return curlTransportError(code);

    const parsed = parseCurlHttpOutput(result.stdout) orelse return error.CommandFailed;
    return .{
        .body = try allocator.dupe(u8, parsed.body),
        .status_code = parsed.status_code,
    };
}

fn runPowerShellGetJsonCommand(
    allocator: std.mem.Allocator,
    endpoint: []const u8,
    access_token: []const u8,
    account_id: []const u8,
) !HttpResult {
    const escaped_token = try escapePowerShellSingleQuoted(allocator, access_token);
    defer allocator.free(escaped_token);
    const escaped_account_id = try escapePowerShellSingleQuoted(allocator, account_id);
    defer allocator.free(escaped_account_id);
    const escaped_endpoint = try escapePowerShellSingleQuoted(allocator, endpoint);
    defer allocator.free(escaped_endpoint);
    const account_header_fragment = try std.fmt.allocPrint(allocator, "'ChatGPT-Account-Id' = '{s}'; ", .{escaped_account_id});
    defer allocator.free(account_header_fragment);

    const script = try std.fmt.allocPrint(
        allocator,
        "$headers = @{{ Authorization = 'Bearer {s}'; {s}'User-Agent' = 'codex-auth' }}; $status = 0; $body = ''; try {{ $response = Invoke-WebRequest -UseBasicParsing -TimeoutSec {s} -Headers $headers -Uri '{s}'; $status = [int]$response.StatusCode; $body = [string]$response.Content }} catch {{ if ($_.Exception.Response) {{ $status = [int]$_.Exception.Response.StatusCode.value__; $stream = $_.Exception.Response.GetResponseStream(); if ($stream) {{ $reader = New-Object System.IO.StreamReader($stream); try {{ $body = $reader.ReadToEnd() }} finally {{ $reader.Dispose() }} }} }} }}; [Console]::Out.Write([Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($body))); [Console]::Out.Write(\"`n\"); [Console]::Out.Write($status)",
        .{ escaped_token, account_header_fragment, request_timeout_secs, escaped_endpoint },
    );
    defer allocator.free(script);

    const result = try std.process.Child.run(.{
        .allocator = allocator,
        .argv = &.{
            "powershell.exe",
            "-NoLogo",
            "-NoProfile",
            "-Command",
            script,
        },
        .max_output_bytes = 1024 * 1024,
    });
    defer allocator.free(result.stderr);

    switch (result.term) {
        .Exited => {},
        else => {
            allocator.free(result.stdout);
            return error.RequestFailed;
        },
    }

    const parsed = parsePowerShellHttpOutput(allocator, result.stdout) orelse {
        allocator.free(result.stdout);
        return error.CommandFailed;
    };
    allocator.free(result.stdout);
    if (parsed.status_code == null and parsed.body.len == 0) {
        allocator.free(parsed.body);
        return error.RequestFailed;
    }
    return parsed;
}

fn runCurlRefreshTokenCommand(
    allocator: std.mem.Allocator,
    endpoint: []const u8,
    refresh_token: []const u8,
) !HttpResult {
    const request_body = try std.fmt.allocPrint(
        allocator,
        "{{\"client_id\":\"{s}\",\"grant_type\":\"refresh_token\",\"refresh_token\":\"{s}\"}}",
        .{ refresh_token_client_id, refresh_token },
    );
    defer allocator.free(request_body);

    var argv = std.ArrayList([]const u8).empty;
    defer argv.deinit(allocator);

    try argv.appendSlice(allocator, &.{
        "curl",
        "--silent",
        "--show-error",
        "--location",
        "--connect-timeout",
        request_timeout_secs,
        "--max-time",
        request_timeout_secs,
        "--write-out",
        "\n%{http_code}",
        "--request",
        "POST",
        "-H",
        "Content-Type: application/json",
        "-H",
        "User-Agent: codex-auth",
        "--data",
        request_body,
        endpoint,
    });

    const result = try std.process.Child.run(.{
        .allocator = allocator,
        .argv = argv.items,
        .max_output_bytes = 1024 * 1024,
    });
    defer allocator.free(result.stderr);
    defer allocator.free(result.stdout);

    const code = switch (result.term) {
        .Exited => |exit_code| exit_code,
        else => return error.RequestFailed,
    };
    if (code != 0) return curlTransportError(code);

    const parsed = parseCurlHttpOutput(result.stdout) orelse return error.CommandFailed;
    return .{
        .body = try allocator.dupe(u8, parsed.body),
        .status_code = parsed.status_code,
    };
}

fn runPowerShellRefreshTokenCommand(
    allocator: std.mem.Allocator,
    endpoint: []const u8,
    refresh_token: []const u8,
) !HttpResult {
    const escaped_refresh_token = try escapePowerShellSingleQuoted(allocator, refresh_token);
    defer allocator.free(escaped_refresh_token);
    const escaped_endpoint = try escapePowerShellSingleQuoted(allocator, endpoint);
    defer allocator.free(escaped_endpoint);
    const request_body = try std.fmt.allocPrint(
        allocator,
        "{{\\\"client_id\\\":\\\"{s}\\\",\\\"grant_type\\\":\\\"refresh_token\\\",\\\"refresh_token\\\":\\\"{s}\\\"}}",
        .{ refresh_token_client_id, escaped_refresh_token },
    );
    defer allocator.free(request_body);

    const script = try std.fmt.allocPrint(
        allocator,
        "$status = 0; $body = ''; try {{ $response = Invoke-WebRequest -UseBasicParsing -TimeoutSec {s} -Method Post -ContentType 'application/json' -Headers @{{ 'User-Agent' = 'codex-auth' }} -Body '{s}' -Uri '{s}'; $status = [int]$response.StatusCode; $body = [string]$response.Content }} catch {{ if ($_.Exception.Response) {{ $status = [int]$_.Exception.Response.StatusCode.value__; $stream = $_.Exception.Response.GetResponseStream(); if ($stream) {{ $reader = New-Object System.IO.StreamReader($stream); try {{ $body = $reader.ReadToEnd() }} finally {{ $reader.Dispose() }} }} }} }}; [Console]::Out.Write([Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($body))); [Console]::Out.Write(\"`n\"); [Console]::Out.Write($status)",
        .{ request_timeout_secs, request_body, escaped_endpoint },
    );
    defer allocator.free(script);

    const result = try std.process.Child.run(.{
        .allocator = allocator,
        .argv = &.{
            "powershell.exe",
            "-NoLogo",
            "-NoProfile",
            "-Command",
            script,
        },
        .max_output_bytes = 1024 * 1024,
    });
    defer allocator.free(result.stderr);

    switch (result.term) {
        .Exited => {},
        else => {
            allocator.free(result.stdout);
            return error.RequestFailed;
        },
    }

    const parsed = parsePowerShellHttpOutput(allocator, result.stdout) orelse {
        allocator.free(result.stdout);
        return error.CommandFailed;
    };
    allocator.free(result.stdout);
    if (parsed.status_code == null and parsed.body.len == 0) {
        allocator.free(parsed.body);
        return error.RequestFailed;
    }
    return parsed;
}

fn curlTransportError(exit_code: u8) anyerror {
    return switch (exit_code) {
        28 => error.TimedOut,
        else => error.RequestFailed,
    };
}

fn escapePowerShellSingleQuoted(allocator: std.mem.Allocator, input: []const u8) ![]u8 {
    return std.mem.replaceOwned(u8, allocator, input, "'", "''");
}

fn parseCurlHttpOutput(output: []const u8) ?ParsedCurlHttpOutput {
    const trimmed = std.mem.trimRight(u8, output, "\r\n");
    const newline_idx = std.mem.lastIndexOfScalar(u8, trimmed, '\n') orelse return null;
    const code_slice = std.mem.trim(u8, trimmed[newline_idx + 1 ..], " \r\t");
    if (code_slice.len == 0) return null;
    const status = std.fmt.parseInt(u16, code_slice, 10) catch return null;
    const body = std.mem.trimRight(u8, trimmed[0..newline_idx], "\r");
    return .{
        .body = body,
        .status_code = if (status == 0) null else status,
    };
}

fn parsePowerShellHttpOutput(allocator: std.mem.Allocator, output: []const u8) ?HttpResult {
    const trimmed = std.mem.trimRight(u8, output, "\r\n");
    const newline_idx = std.mem.lastIndexOfScalar(u8, trimmed, '\n') orelse return null;
    const encoded_body = std.mem.trim(u8, trimmed[0..newline_idx], " \r\t");
    const code_slice = std.mem.trim(u8, trimmed[newline_idx + 1 ..], " \r\t");
    const status = std.fmt.parseInt(u16, code_slice, 10) catch return null;
    const decoded_body = decodeBase64Alloc(allocator, encoded_body) catch return null;
    return .{
        .body = decoded_body,
        .status_code = if (status == 0) null else status,
    };
}

fn decodeBase64Alloc(allocator: std.mem.Allocator, input: []const u8) ![]u8 {
    const decoder = std.base64.standard.Decoder;
    const out_len = try decoder.calcSizeForSlice(input);
    const buf = try allocator.alloc(u8, out_len);
    errdefer allocator.free(buf);
    try decoder.decode(buf, input);
    return buf;
}

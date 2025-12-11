const std = @import("std");
const builtin = @import("builtin");
const posix = std.posix;
const File = std.fs.File;

const is_darwin = builtin.os.tag == .macos;

// MARK: - Constants

const state_dir = ".local/state/starship-prompt";
const media_max_display_len: usize = 30;
const stale_threshold_secs: i64 = 3600; // 1 hour

// MARK: - Main

pub fn main() !void {
    var args = std.process.args();
    _ = args.next(); // skip program name

    const cmd = args.next() orelse {
        try printUsage();
        return;
    };

    if (std.mem.eql(u8, cmd, "--check-darwin")) {
        // Comptime platform check: exit 0 on macOS, exit 1 otherwise
        if (!is_darwin) std.process.exit(1);
    } else if (std.mem.eql(u8, cmd, "--uptime")) {
        try printUptime();
    } else if (std.mem.eql(u8, cmd, "--memory")) {
        if (is_darwin) {
            try printMemoryDarwin();
        } else {
            try printMemoryLinux();
        }
    } else if (std.mem.eql(u8, cmd, "--media")) {
        try printMedia();
    } else if (std.mem.eql(u8, cmd, "--rotating")) {
        try printRotating();
    } else {
        try printUsage();
    }
}

fn printUsage() !void {
    var buf: [4096]u8 = undefined;
    var w = File.Writer.initStreaming(File.stderr(), &buf);
    try w.interface.writeAll(
        \\Usage: prompt-info <command>
        \\Commands:
        \\  --check-darwin  Exit 0 on macOS, 1 otherwise
        \\  --uptime        Print session uptime (e.g., "1h 23m")
        \\  --memory        Print memory usage (e.g., "12.5/16GB")
        \\  --media         Print currently playing media info
        \\  --rotating      Print next rotating info item (round-robin)
        \\
    );
    try w.interface.flush();
}

// MARK: - Path Helpers

fn getStatePath(comptime filename: []const u8, out_buf: []u8) ?[]const u8 {
    const home = posix.getenv("HOME") orelse return null;
    const path = std.fmt.bufPrint(out_buf, "{s}/" ++ state_dir ++ "/" ++ filename, .{home}) catch return null;
    return path;
}

fn readFileContent(path: []const u8, buf: []u8) ?[]const u8 {
    const file = std.fs.openFileAbsolute(path, .{}) catch return null;
    defer file.close();
    const len = file.readAll(buf) catch return null;
    return buf[0..len];
}

// MARK: - Session Uptime

fn printUptime() !void {
    var buf: [4096]u8 = undefined;
    var w = File.Writer.initStreaming(File.stdout(), &buf);

    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const path = getStatePath("start", &path_buf) orelse return;

    var file_buf: [32]u8 = undefined;
    const content = readFileContent(path, &file_buf) orelse {
        try w.interface.writeAll("0s");
        try w.interface.flush();
        return;
    };

    const trimmed = std.mem.trim(u8, content, &std.ascii.whitespace);
    const start_time = std.fmt.parseInt(i64, trimmed, 10) catch {
        try w.interface.writeAll("0s");
        try w.interface.flush();
        return;
    };

    const now = std.time.timestamp();
    const diff: u64 = @intCast(@max(0, now - start_time));

    const hours = diff / 3600;
    const mins = (diff % 3600) / 60;
    const secs = diff % 60;

    if (hours > 0) {
        try w.interface.print("{d}h {d}m", .{ hours, mins });
    } else if (mins > 0) {
        try w.interface.print("{d}m", .{mins});
    } else {
        try w.interface.print("{d}s", .{secs});
    }
    try w.interface.flush();
}

// MARK: - Memory (Darwin)

fn printMemoryDarwin() !void {
    var buf: [4096]u8 = undefined;
    var w = File.Writer.initStreaming(File.stdout(), &buf);

    const page_size = std.c.sysconf(@intFromEnum(std.c._SC.PAGESIZE));
    if (page_size < 0) {
        try w.interface.writeAll("?/?GB");
        try w.interface.flush();
        return;
    }

    // Get total physical memory via sysctl (CTL_HW=6, HW_MEMSIZE=24)
    var total_mem: u64 = 0;
    var size: usize = @sizeOf(u64);
    const mib = [_]c_int{ 6, 24 };
    if (std.c.sysctl(@constCast(&mib), 2, &total_mem, &size, null, 0) != 0) {
        try w.interface.writeAll("?/?GB");
        try w.interface.flush();
        return;
    }

    // Run vm_stat to get memory page counts
    var child = std.process.Child.init(&[_][]const u8{"vm_stat"}, std.heap.page_allocator);
    child.stdout_behavior = .Pipe;
    child.stderr_behavior = .Close;
    child.spawn() catch {
        try w.interface.writeAll("?/?GB");
        try w.interface.flush();
        return;
    };

    const vm_stdout = child.stdout orelse {
        try w.interface.writeAll("?/?GB");
        try w.interface.flush();
        return;
    };

    var vm_buf: [4096]u8 = undefined;
    const len = vm_stdout.readAll(&vm_buf) catch {
        try w.interface.writeAll("?/?GB");
        try w.interface.flush();
        return;
    };
    _ = child.wait() catch {};

    // Parse vm_stat output for relevant page counts
    var pages_active: u64 = 0;
    var pages_wired: u64 = 0;
    var pages_compressed: u64 = 0;

    var lines = std.mem.splitScalar(u8, vm_buf[0..len], '\n');
    while (lines.next()) |line| {
        if (std.mem.indexOf(u8, line, "Pages active:") != null) {
            pages_active = parseColonValue(line);
        } else if (std.mem.indexOf(u8, line, "Pages wired down:") != null) {
            pages_wired = parseColonValue(line);
        } else if (std.mem.indexOf(u8, line, "Pages occupied by compressor:") != null) {
            pages_compressed = parseColonValue(line);
        }
    }

    const used_bytes = (pages_active + pages_wired + pages_compressed) * @as(u64, @intCast(page_size));
    const used_gb = @as(f64, @floatFromInt(used_bytes)) / (1024.0 * 1024.0 * 1024.0);
    const total_gb = @as(f64, @floatFromInt(total_mem)) / (1024.0 * 1024.0 * 1024.0);

    try w.interface.print("{d:.1}/{d:.0}GB", .{ used_gb, total_gb });
    try w.interface.flush();
}

/// Parses "Label: 12345." format, returning the numeric value
fn parseColonValue(line: []const u8) u64 {
    const colon_pos = std.mem.indexOf(u8, line, ":") orelse return 0;
    const value_part = std.mem.trim(u8, line[colon_pos + 1 ..], &std.ascii.whitespace);
    const clean = std.mem.trimRight(u8, value_part, ".");
    return std.fmt.parseInt(u64, clean, 10) catch 0;
}

// MARK: - Memory (Linux)

fn printMemoryLinux() !void {
    var buf: [4096]u8 = undefined;
    var w = File.Writer.initStreaming(File.stdout(), &buf);

    var file_buf: [4096]u8 = undefined;
    const content = readFileContent("/proc/meminfo", &file_buf) orelse {
        try w.interface.writeAll("?/?GB");
        try w.interface.flush();
        return;
    };

    var mem_total: u64 = 0;
    var mem_available: u64 = 0;

    var lines = std.mem.splitScalar(u8, content, '\n');
    while (lines.next()) |line| {
        if (std.mem.startsWith(u8, line, "MemTotal:")) {
            mem_total = parseMemInfoValue(line);
        } else if (std.mem.startsWith(u8, line, "MemAvailable:")) {
            mem_available = parseMemInfoValue(line);
        }
    }

    const used_kb = mem_total - mem_available;
    const used_gb = @as(f64, @floatFromInt(used_kb)) / (1024.0 * 1024.0);
    const total_gb = @as(f64, @floatFromInt(mem_total)) / (1024.0 * 1024.0);

    try w.interface.print("{d:.1}/{d:.0}GB", .{ used_gb, total_gb });
    try w.interface.flush();
}

/// Parses "MemTotal: 12345678 kB" format
fn parseMemInfoValue(line: []const u8) u64 {
    const colon_pos = std.mem.indexOf(u8, line, ":") orelse return 0;
    const after_colon = std.mem.trim(u8, line[colon_pos + 1 ..], &std.ascii.whitespace);
    const space_pos = std.mem.indexOf(u8, after_colon, " ") orelse after_colon.len;
    return std.fmt.parseInt(u64, after_colon[0..space_pos], 10) catch 0;
}

// MARK: - Media

const MediaInfo = struct {
    title: []const u8,
    artist: []const u8,
    isPlaying: bool,
    timestamp: i64,
};

fn printMedia() !void {
    var buf: [4096]u8 = undefined;
    var w = File.Writer.initStreaming(File.stdout(), &buf);

    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const path = getStatePath("media.json", &path_buf) orelse return;

    var json_buf: [4096]u8 = undefined;
    const json_content = readFileContent(path, &json_buf) orelse {
        try w.interface.flush();
        return;
    };

    const parsed = std.json.parseFromSlice(MediaInfo, std.heap.page_allocator, json_content, .{}) catch {
        try w.interface.flush();
        return;
    };
    defer parsed.deinit();

    const media = parsed.value;

    // Build display string: "title - artist" or just "title"
    var display_buf: [256]u8 = undefined;
    var display_len: usize = 0;

    // Copy title
    const title_len = @min(media.title.len, display_buf.len);
    @memcpy(display_buf[0..title_len], media.title[0..title_len]);
    display_len = title_len;

    // Append artist if present
    if (media.artist.len > 0 and display_len + 3 + media.artist.len <= display_buf.len) {
        @memcpy(display_buf[display_len .. display_len + 3], " - ");
        display_len += 3;
        const artist_len = @min(media.artist.len, display_buf.len - display_len);
        @memcpy(display_buf[display_len .. display_len + artist_len], media.artist[0..artist_len]);
        display_len += artist_len;
    }

    // Truncate if needed
    const truncated = display_len > media_max_display_len;
    const display = display_buf[0..@min(display_len, media_max_display_len)];

    // Output: icon + text
    const icon = if (media.isPlaying) "\u{f04b} " else "\u{f04c} "; // Font Awesome play/pause
    try w.interface.writeAll(icon);
    try w.interface.writeAll(display);
    if (truncated) try w.interface.writeAll("...");

    // Show age indicator if paused
    if (!media.isPlaying) {
        const age_secs = std.time.timestamp() - media.timestamp;
        if (age_secs > 0) {
            const age_hours = @divFloor(age_secs, 3600);
            const age_mins = @divFloor(@mod(age_secs, 3600), 60);
            if (age_hours >= 1) {
                try w.interface.print(" ({d}h ago)", .{age_hours});
            } else if (age_mins >= 1) {
                try w.interface.print(" ({d}m ago)", .{age_mins});
            }
        }
    }

    try w.interface.flush();
}

// MARK: - Rotating Info

const RotatingItem = struct {
    type: []const u8,
    value: []const u8,
    updated: i64,
};

const RotatingData = struct {
    items: []const RotatingItem,
};

fn printRotating() !void {
    var buf: [4096]u8 = undefined;
    var w = File.Writer.initStreaming(File.stdout(), &buf);

    var json_path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const json_path = getStatePath("rotating.json", &json_path_buf) orelse return;

    var index_path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const index_path = getStatePath("index", &index_path_buf) orelse return;

    var json_buf: [8192]u8 = undefined;
    const json_content = readFileContent(json_path, &json_buf) orelse {
        try w.interface.flush();
        return;
    };

    const parsed = std.json.parseFromSlice(RotatingData, std.heap.page_allocator, json_content, .{}) catch {
        try w.interface.flush();
        return;
    };
    defer parsed.deinit();

    const items = parsed.value.items;
    if (items.len == 0) {
        try w.interface.flush();
        return;
    }

    // Read current index
    var index_buf: [32]u8 = undefined;
    var current_index: usize = 0;
    if (readFileContent(index_path, &index_buf)) |content| {
        const trimmed = std.mem.trim(u8, content, &std.ascii.whitespace);
        current_index = std.fmt.parseInt(usize, trimmed, 10) catch 0;
    }
    current_index = current_index % items.len;

    const item = items[current_index];

    // Output value with optional stale indicator
    try w.interface.writeAll(item.value);

    const age_secs = std.time.timestamp() - item.updated;
    if (age_secs > stale_threshold_secs) {
        const age_hours = @divFloor(age_secs, 3600);
        if (age_hours >= 1) {
            try w.interface.print(" ({d}h ago)", .{age_hours});
        }
    }

    try w.interface.flush();

    // Persist next index
    const next_index = (current_index + 1) % items.len;
    if (std.fs.createFileAbsolute(index_path, .{ .truncate = true })) |file| {
        defer file.close();
        var idx_buf: [32]u8 = undefined;
        const idx_str = std.fmt.bufPrint(&idx_buf, "{d}", .{next_index}) catch return;
        _ = file.write(idx_str) catch {};
    } else |_| {}
}

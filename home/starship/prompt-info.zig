const std = @import("std");
const builtin = @import("builtin");
const posix = std.posix;
const File = std.fs.File;

const is_darwin = builtin.os.tag == .macos;

pub fn main() !void {
    var args = std.process.args();
    _ = args.next(); // skip program name

    const cmd = args.next() orelse {
        try printUsage();
        return;
    };

    if (std.mem.eql(u8, cmd, "--check-darwin")) {
        // Comptime check - on darwin this is a no-op exit 0
        // On other platforms, exit 1
        if (!is_darwin) {
            std.process.exit(1);
        }
        return;
    } else if (std.mem.eql(u8, cmd, "--uptime")) {
        try printUptime();
    } else if (std.mem.eql(u8, cmd, "--memory")) {
        if (is_darwin) {
            try printMemoryDarwin();
        } else {
            try printMemoryLinux();
        }
    } else if (std.mem.eql(u8, cmd, "--rotating")) {
        try printRotating();
    } else {
        try printUsage();
    }
}

fn getStdoutWriter() File.Writer {
    var buf: [4096]u8 = undefined;
    return File.Writer.initStreaming(File.stdout(), &buf);
}

fn printUsage() !void {
    var buf: [4096]u8 = undefined;
    var w = File.Writer.initStreaming(File.stderr(), &buf);
    try w.interface.writeAll(
        \\Usage: prompt-info <command>
        \\Commands:
        \\  --check-darwin  Exit 0 on macOS, 1 otherwise (comptime)
        \\  --uptime        Print session uptime (e.g., "1h 23m")
        \\  --memory        Print memory usage (e.g., "12.5/16GB")
        \\  --rotating      Print next rotating info item (round-robin)
        \\
    );
    try w.interface.flush();
}

fn printUptime() !void {
    var buf: [4096]u8 = undefined;
    var w = File.Writer.initStreaming(File.stdout(), &buf);

    const home = posix.getenv("HOME") orelse return;

    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const path = std.fmt.bufPrint(&path_buf, "{s}/.local/state/starship-prompt/start", .{home}) catch return;

    const file = std.fs.openFileAbsolute(path, .{}) catch {
        try w.interface.writeAll("0s");
        try w.interface.flush();
        return;
    };
    defer file.close();

    var file_buf: [32]u8 = undefined;
    const len = file.readAll(&file_buf) catch {
        try w.interface.writeAll("0s");
        try w.interface.flush();
        return;
    };

    const content = std.mem.trim(u8, file_buf[0..len], &std.ascii.whitespace);
    const start_time = std.fmt.parseInt(i64, content, 10) catch {
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

fn printMemoryDarwin() !void {
    var buf: [4096]u8 = undefined;
    var w = File.Writer.initStreaming(File.stdout(), &buf);

    // Get page size
    const page_size = std.c.sysconf(@intFromEnum(std.c._SC.PAGESIZE));
    if (page_size < 0) {
        try w.interface.writeAll("?/?GB");
        try w.interface.flush();
        return;
    }

    // Get total physical memory via sysctl
    var total_mem: u64 = 0;
    var size: usize = @sizeOf(u64);
    const mib = [_]c_int{ 6, 24 }; // CTL_HW, HW_MEMSIZE
    const rc = std.c.sysctl(@constCast(&mib), 2, &total_mem, &size, null, 0);
    if (rc != 0) {
        try w.interface.writeAll("?/?GB");
        try w.interface.flush();
        return;
    }

    // Run vm_stat to get memory pages info
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

    // Parse vm_stat output
    var pages_active: u64 = 0;
    var pages_wired: u64 = 0;
    var pages_compressed: u64 = 0;

    var lines = std.mem.splitScalar(u8, vm_buf[0..len], '\n');
    while (lines.next()) |line| {
        if (std.mem.indexOf(u8, line, "Pages active:")) |_| {
            pages_active = parseVmStatValue(line);
        } else if (std.mem.indexOf(u8, line, "Pages wired down:")) |_| {
            pages_wired = parseVmStatValue(line);
        } else if (std.mem.indexOf(u8, line, "Pages occupied by compressor:")) |_| {
            pages_compressed = parseVmStatValue(line);
        }
    }

    const used_bytes = (pages_active + pages_wired + pages_compressed) * @as(u64, @intCast(page_size));
    const used_gb = @as(f64, @floatFromInt(used_bytes)) / (1024.0 * 1024.0 * 1024.0);
    const total_gb = @as(f64, @floatFromInt(total_mem)) / (1024.0 * 1024.0 * 1024.0);

    try w.interface.print("{d:.1}/{d:.0}GB", .{ used_gb, total_gb });
    try w.interface.flush();
}

fn parseVmStatValue(line: []const u8) u64 {
    // Find the colon and parse the number after it
    const colon_pos = std.mem.indexOf(u8, line, ":") orelse return 0;
    const value_part = std.mem.trim(u8, line[colon_pos + 1 ..], &std.ascii.whitespace);
    // Remove trailing period if present
    const clean = std.mem.trimRight(u8, value_part, ".");
    return std.fmt.parseInt(u64, clean, 10) catch 0;
}

fn printMemoryLinux() !void {
    var buf: [4096]u8 = undefined;
    var w = File.Writer.initStreaming(File.stdout(), &buf);

    const file = std.fs.openFileAbsolute("/proc/meminfo", .{}) catch {
        try w.interface.writeAll("?/?GB");
        try w.interface.flush();
        return;
    };
    defer file.close();

    var file_buf: [4096]u8 = undefined;
    const len = file.readAll(&file_buf) catch {
        try w.interface.writeAll("?/?GB");
        try w.interface.flush();
        return;
    };

    var mem_total: u64 = 0;
    var mem_available: u64 = 0;

    var lines = std.mem.splitScalar(u8, file_buf[0..len], '\n');
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

fn parseMemInfoValue(line: []const u8) u64 {
    // Format: "MemTotal:       12345678 kB"
    const colon_pos = std.mem.indexOf(u8, line, ":") orelse return 0;
    const after_colon = std.mem.trim(u8, line[colon_pos + 1 ..], &std.ascii.whitespace);
    // Find first space to get just the number
    const space_pos = std.mem.indexOf(u8, after_colon, " ") orelse after_colon.len;
    return std.fmt.parseInt(u64, after_colon[0..space_pos], 10) catch 0;
}

// Stale threshold in seconds (1 hour)
const STALE_THRESHOLD: i64 = 3600;

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

    const home = posix.getenv("HOME") orelse return;

    // Read the rotating.json file
    var json_path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const json_path = std.fmt.bufPrint(&json_path_buf, "{s}/.local/state/starship-prompt/rotating.json", .{home}) catch return;

    const json_file = std.fs.openFileAbsolute(json_path, .{}) catch {
        // No file yet, output nothing
        try w.interface.flush();
        return;
    };
    defer json_file.close();

    var json_buf: [8192]u8 = undefined;
    const json_len = json_file.readAll(&json_buf) catch {
        try w.interface.flush();
        return;
    };

    // Parse JSON using std.json
    const parsed = std.json.parseFromSlice(RotatingData, std.heap.page_allocator, json_buf[0..json_len], .{}) catch {
        try w.interface.flush();
        return;
    };
    defer parsed.deinit();

    const items = parsed.value.items;

    if (items.len == 0) {
        try w.interface.flush();
        return;
    }

    // Read and update index file
    var index_path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const index_path = std.fmt.bufPrint(&index_path_buf, "{s}/.local/state/starship-prompt/index", .{home}) catch return;

    var current_index: usize = 0;

    // Try to read existing index
    if (std.fs.openFileAbsolute(index_path, .{})) |index_file| {
        defer index_file.close();
        var index_buf: [32]u8 = undefined;
        const index_len = index_file.readAll(&index_buf) catch 0;
        if (index_len > 0) {
            const content = std.mem.trim(u8, index_buf[0..index_len], &std.ascii.whitespace);
            current_index = std.fmt.parseInt(usize, content, 10) catch 0;
        }
    } else |_| {}

    // Wrap around if needed
    current_index = current_index % items.len;

    // Get the current item
    const item = items[current_index];

    // Check if stale (more than 1 hour old)
    const now = std.time.timestamp();
    const age_seconds = now - item.updated;
    const is_stale = age_seconds > STALE_THRESHOLD;

    // Output the value
    try w.interface.writeAll(item.value);

    // Add stale indicator if needed
    if (is_stale) {
        const age_hours = @divFloor(age_seconds, 3600);
        if (age_hours >= 1) {
            try w.interface.print(" ({d}h ago)", .{age_hours});
        }
    }

    try w.interface.flush();

    // Write next index
    const next_index = (current_index + 1) % items.len;

    // Create/truncate index file and write new index
    if (std.fs.createFileAbsolute(index_path, .{ .truncate = true })) |new_index_file| {
        defer new_index_file.close();
        var index_write_buf: [32]u8 = undefined;
        const index_str = std.fmt.bufPrint(&index_write_buf, "{d}", .{next_index}) catch return;
        _ = new_index_file.write(index_str) catch {};
    } else |_| {}
}

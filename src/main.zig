const std = @import("std");
const zi = @import("zigimg");

const BlobId = enum(u8) {
    invalid = 0xff,
    _,
};

const Blob = struct {
    min_x: u16,
    min_y: u16,
    max_x: u16,
    max_y: u16,
    pixel_count: u16,
};

const threshold = 128;

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const args = try std.process.argsAlloc(allocator);
    defer std.process.argsFree(allocator, args);

    if (args.len < 3) {
        std.debug.print("Too few arguments!\n", .{});
        std.process.exit(1);
    }

    const pixels, const width, const height = blk: {
        var file = try std.fs.cwd().openFile(args[1], .{});
        defer file.close();

        var image = try zi.Image.fromFile(allocator, &file);
        defer image.deinit();

        std.debug.print("{}x{}\n", .{ image.width, image.height });

        break :blk .{
            try zi.PixelFormatConverter.convert(
                allocator,
                &image.pixels,
                .grayscale8,
            ),
            image.width,
            image.height,
        };
    };
    defer pixels.deinit(allocator);

    const bytes = pixels.asConstBytes();

    const pixel_blob_id = try allocator.alloc(BlobId, bytes.len);
    defer allocator.free(pixel_blob_id);

    var blobs = try std.ArrayList(Blob).initCapacity(allocator, 255);
    defer blobs.deinit();

    const blob_merge = try allocator.alloc(BlobId, 255);
    defer allocator.free(blob_merge);

    var blob_merge_set = std.AutoArrayHashMap(struct { BlobId, BlobId }, void).init(allocator);
    defer blob_merge_set.deinit();
    try blob_merge_set.ensureUnusedCapacity(255);

    const colours = [_]u32{
        0x0000ffff,
        0x00ff00ff,
        0x00ffffff,
        0xffff00ff,
        0xff00ffff,
    };

    @memset(pixel_blob_id, .invalid);

    for (1..height) |y| {
        for (1..width) |x| {
            pixel_blob_id[x + y * width] = .invalid;

            if (bytes[x + y * width] < threshold) continue;

            const up_blob_id = pixel_blob_id[x + (y - 1) * width];
            const left_blob_id = pixel_blob_id[(x - 1) + y * width];

            if (up_blob_id != .invalid or left_blob_id != .invalid) {
                const blob_id: BlobId = @enumFromInt(@min(@intFromEnum(up_blob_id), @intFromEnum(left_blob_id)));
                pixel_blob_id[x + y * width] = blob_id;

                const x_16: u16 = @intCast(x);
                const y_16: u16 = @intCast(y);

                const blob = &blobs.items[@intFromEnum(blob_id)];
                blob.min_x = @min(x_16, blob.min_x);
                blob.min_y = @min(y_16, blob.min_y);
                blob.max_x = @max(x_16, blob.max_x);
                blob.max_y = @max(y_16, blob.max_y);
                blob.pixel_count += 1;

                if (up_blob_id != left_blob_id and up_blob_id != .invalid and left_blob_id != .invalid) {
                    const blob_id_merged = @max(@intFromEnum(up_blob_id), @intFromEnum(left_blob_id));

                    var blob_id_final = @intFromEnum(blob_id);

                    while (@intFromEnum(blob_merge[blob_id_final]) != blob_id_final) {
                        blob_id_final = @intFromEnum(blob_merge[blob_id_final]);
                    }

                    blob_merge[blob_id_merged] = @enumFromInt(blob_id_final);

                    blob_merge_set.putAssumeCapacity(
                        .{ @enumFromInt(blob_id_merged), @enumFromInt(blob_id_final) },
                        {},
                    );
                }
            } else {
                std.debug.assert(blobs.items.len <= 254);
                const blob_id: u16 = @intCast(blobs.items.len);
                blobs.appendAssumeCapacity(.{
                    .min_x = @intCast(x),
                    .min_y = @intCast(y),
                    .max_x = @intCast(x),
                    .max_y = @intCast(y),
                    .pixel_count = 1,
                });
                pixel_blob_id[x + y * width] = @enumFromInt(blob_id);
                blob_merge[blob_id] = @enumFromInt(blob_id);
            }
        }
    }

    for (pixel_blob_id) |*blob_id| {
        if (blob_id.* == .invalid) continue;
        blob_id.* = blob_merge[@intFromEnum(blob_id.*)];
    }

    for (blob_merge_set.keys()) |merged_blobs| {
        const blob_id_merged, const blob_id_final = merged_blobs;

        const blob_merged = &blobs.items[@intFromEnum(blob_id_merged)];
        const blob_final = &blobs.items[@intFromEnum(blob_id_final)];

        blob_final.min_x = @min(blob_merged.min_x, blob_final.min_x);
        blob_final.min_y = @min(blob_merged.min_y, blob_final.min_y);
        blob_final.max_x = @max(blob_merged.max_x, blob_final.max_x);
        blob_final.max_y = @max(blob_merged.max_y, blob_final.max_y);
        blob_final.pixel_count += blob_merged.pixel_count;
        blob_merged.pixel_count = 0;
    }

    {
        var result_image = try zi.Image.create(
            allocator,
            width,
            height,
            .rgba32,
        );
        defer result_image.deinit();

        for (pixel_blob_id, result_image.pixels.rgba32) |blob_id, *colour| {
            if (blob_id != .invalid)
                colour.* = zi.color.Rgba32.fromU32Rgba(colours[@intFromEnum(blob_id) % colours.len])
            else
                colour.* = zi.color.Rgba32.fromU32Rgba(0xff);
        }

        var blob_count: usize = 0;
        for (blobs.items, 0..) |blob, blob_id| {
            if (blob.pixel_count == 0) continue;
            blob_count += 1;

            result_image.pixels.rgba32[blob.min_x + blob.min_y * width] = zi.color.Rgba32.fromU32Rgba(0xffffffff);
            result_image.pixels.rgba32[blob.max_x + blob.min_y * width] = zi.color.Rgba32.fromU32Rgba(0xffffffff);
            result_image.pixels.rgba32[blob.min_x + blob.max_y * width] = zi.color.Rgba32.fromU32Rgba(0xffffffff);
            result_image.pixels.rgba32[blob.max_x + blob.max_y * width] = zi.color.Rgba32.fromU32Rgba(0xffffffff);

            const center_x = (blob.min_x + blob.max_x) / 2;
            const center_y = (blob.min_y + blob.max_y) / 2;

            result_image.pixels.rgba32[center_x + center_y * width] = zi.color.Rgba32.fromU32Rgba(0xff0000ff);

            std.debug.print("Id: {}\n", .{blob_id});
        }

        std.debug.print("Blob count: {}\n", .{blob_count});

        var file = try std.fs.cwd().createFile(args[2], .{});
        defer file.close();

        try result_image.writeToFile(file, .{
            .png = .{},
        });
    }
}

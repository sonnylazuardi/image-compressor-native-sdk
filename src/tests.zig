const std = @import("std");
const native_sdk = @import("native_sdk");
const main = @import("main.zig");

const canvas = native_sdk.canvas;
const testing = std.testing;

const AppUi = main.AppUi;
const Model = main.Model;
const Msg = main.Msg;

const AppMarkup = canvas.MarkupView(Model, Msg);

fn buildTree(arena: std.mem.Allocator, model: *const Model) !AppUi.Tree {
    var view = try AppMarkup.init(arena, main.app_markup);
    var ui = AppUi.init(arena);
    const node = view.build(&ui, model) catch |err| {
        if (err == error.MarkupBuild) {
            std.debug.print("app.native:{d}:{d}: {s}\n", .{ view.diagnostic.line, view.diagnostic.column, view.diagnostic.message });
        }
        return err;
    };
    return ui.finalize(node);
}

fn findByText(widget: canvas.Widget, kind: canvas.WidgetKind, text: []const u8) ?canvas.Widget {
    if (widget.kind == kind and std.mem.eql(u8, widget.text, text)) return widget;
    for (widget.children) |child| {
        if (findByText(child, kind, text)) |found| return found;
    }
    return null;
}

fn expectByText(widget: canvas.Widget, kind: canvas.WidgetKind, text: []const u8) !canvas.Widget {
    return findByText(widget, kind, text) orelse {
        std.debug.print("no {s} with text \"{s}\" in the view\n", .{ @tagName(kind), text });
        return error.WidgetNotFound;
    };
}

test "empty state shows drop prompt and compress disabled path" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    var model = main.initialModel();
    const tree = try buildTree(arena_state.allocator(), &model);
    _ = try expectByText(tree.root, .text, "Drop an image here");
    _ = try expectByText(tree.root, .button, "Compress");
    try testing.expect(model.busyOrNoFile());
    try testing.expectEqual(@as(u8, 80), model.quality);
}

test "selecting a path updates derived file name" {
    var model = main.initialModel();
    model.setPath("/tmp/photos/vacation.png");
    try testing.expectEqualStrings("/tmp/photos/vacation.png", model.pathText());
    try testing.expectEqualStrings("vacation.png", model.fileName());
    try testing.expect(model.hasFile());
    try testing.expect(!model.busyOrNoFile());
}

test "presets and settings toggle" {
    var model = main.initialModel();
    try testing.expect(!model.settings_open);
    try testing.expect(model.presetMedium());
    model.quality = 90;
    try testing.expect(model.presetLight());
    model.quality = 50;
    try testing.expect(model.presetHeavy());
    model.settings_open = true;
    try testing.expect(model.settings_open);
}

test "selected file view shows file name" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    var model = main.initialModel();
    model.setPath("/home/me/shot.jpg");
    const tree = try buildTree(arena_state.allocator(), &model);
    _ = try expectByText(tree.root, .text, "shot.jpg");
    _ = try expectByText(tree.root, .button, "Choose another image");
}

test "layout sweep at designed window size" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    var model = main.initialModel();
    const tree = try buildTree(arena_state.allocator(), &model);
    var nodes: [256]canvas.WidgetLayoutNode = undefined;
    const layout = try canvas.layoutWidgetTree(
        tree.root,
        geometryRect(main.window_width, main.window_height),
        &nodes,
    );
    try testing.expect(layout.nodes.len > 0);
}

fn geometryRect(w: f32, h: f32) native_sdk.geometry.RectF {
    return native_sdk.geometry.RectF.init(0, 0, w, h);
}

test "command shortcuts map to messages" {
    try testing.expectEqual(@as(?Msg, .toggle_settings), main.command(main.cmd_settings));
    try testing.expectEqual(@as(?Msg, .compress), main.command(main.cmd_compress));
    try testing.expectEqual(@as(?Msg, .browse), main.command(main.cmd_browse));
}

test "normalizeIncomingPath strips file URL and whitespace" {
    var buf: [512]u8 = undefined;
    const a = main.normalizeIncomingPath("  /tmp/photo.png\n", &buf).?;
    try testing.expectEqualStrings("/tmp/photo.png", a);
    const b = main.normalizeIncomingPath("file:///Users/me/shot.JPG", &buf).?;
    try testing.expectEqualStrings("/Users/me/shot.JPG", b);
}

test "dropped image path selects file" {
    var model = main.initialModel();
    model.setBunPath("/usr/bin/bun");
    model.bun_state = .ready;
    var fx = main.Effects.init(testing.allocator);
    defer fx.deinit();
    const dropped = main.DroppedPaths.fromPaths(&.{"C:\\Users\\me\\photo.PNG"});
    main.update(&model, .{ .files_dropped = dropped }, &fx);
    try testing.expectEqualStrings("C:\\Users\\me\\photo.PNG", model.pathText());
    try testing.expectEqualStrings("photo.PNG", model.fileName());
}

test "dropped file URL selects file" {
    var model = main.initialModel();
    model.setBunPath("/usr/bin/bun");
    model.bun_state = .ready;
    var fx = main.Effects.init(testing.allocator);
    defer fx.deinit();
    const dropped = main.DroppedPaths.fromPaths(&.{"file:///tmp/vacation.png"});
    main.update(&model, .{ .files_dropped = dropped }, &fx);
    try testing.expectEqualStrings("/tmp/vacation.png", model.pathText());
    try testing.expectEqualStrings("vacation.png", model.fileName());
}

test "dropped non-image is rejected" {
    var model = main.initialModel();
    var fx = main.Effects.init(testing.allocator);
    defer fx.deinit();
    const dropped = main.DroppedPaths.fromPaths(&.{"C:\\Users\\me\\notes.txt"});
    main.update(&model, .{ .files_dropped = dropped }, &fx);
    try testing.expect(!model.hasFile());
    try testing.expect(model.hasError());
}

test "bun helpers gate compress until ready" {
    var model = main.initialModel();
    try testing.expectEqual(main.BunState.checking, model.bun_state);
    try testing.expect(model.showBunBanner());
    try testing.expect(!model.showBunRetry());
    try testing.expect(!model.bunReady());
    try testing.expect(model.busyOrNoFileOrNoBun());

    model.setPath("/tmp/photo.png");
    try testing.expect(model.busyOrNoFileOrNoBun());

    model.setBunPath("/tmp/fake-bun");
    model.bun_state = .ready;
    model.setBunBanner("");
    try testing.expect(model.bunReady());
    try testing.expect(!model.showBunBanner());
    try testing.expect(!model.busyOrNoFileOrNoBun());
}

test "bun failed state shows retry banner copy" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    var model = main.initialModel();
    model.bun_state = .failed;
    model.setBunBanner("Couldn’t install Bun. Retry, or install from https://bun.sh then Retry.");
    try testing.expect(model.showBunBanner());
    try testing.expect(model.showBunRetry());
    const tree = try buildTree(arena_state.allocator(), &model);
    _ = try expectByText(tree.root, .text, "Couldn’t install Bun. Retry, or install from https://bun.sh then Retry.");
    _ = try expectByText(tree.root, .button, "Retry");
}

test "bun ready hides banner" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    var model = main.initialModel();
    model.setBunPath("/usr/local/bin/bun");
    model.bun_state = .ready;
    try testing.expect(!model.showBunBanner());
    const tree = try buildTree(arena_state.allocator(), &model);
    try testing.expect(findByText(tree.root, .button, "Retry") == null);
}

test "failed bun install exit marks failed without network" {
    var model = main.initialModel();
    model.bun_state = .installing;
    var fx = main.Effects.init(testing.allocator);
    defer fx.deinit();
    const exit: native_sdk.EffectExit = .{
        .key = main.bun_install_key,
        .reason = .exited,
        .code = 1,
        .stderr_tail = "curl: (6) Could not resolve host",
    };
    main.update(&model, .{ .bun_install_exited = exit }, &fx);
    try testing.expectEqual(main.BunState.failed, model.bun_state);
    try testing.expect(model.showBunRetry());
    try testing.expect(!model.bunReady());
}

test "retry_bun_setup re-enters checking or ready via probe" {
    var model = main.initialModel();
    model.bun_state = .failed;
    model.setBunBanner("failed");
    var fx = main.Effects.init(testing.allocator);
    defer fx.deinit();
    main.update(&model, .retry_bun_setup, &fx);
    // On machines with Bun installed this becomes ready; otherwise installing.
    try testing.expect(model.bun_state == .ready or model.bun_state == .installing);
}

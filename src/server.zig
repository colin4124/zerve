const std = @import("std");
pub const io_mode: std.io.Mode = .evented;
const olderVersion: bool = @import("builtin").zig_version.minor < 11;
const eql = std.mem.eql;

const types = @import("types.zig");
const Route = types.Route;
const Request = types.Request;
const Response = types.Response;
const Header = types.Header;
const Method = types.Method;
const HTTP_Version = types.HTTP_Version;

/// Server is a namespace to configure IP and Port the app will listen to, as well as
/// the routing paths (`[]Route`) it shall handle.
/// You can also choose an allocator that the app will use for dynamic memory allocation.
pub const Server = struct {
    pub fn listen(ip: []const u8, port: u16, rt: []const Route, allocator: std.mem.Allocator) !void {

        // Init server
        const addr = try std.net.Address.parseIp(ip, port);
        var server = try addr.listen(.{});
        defer server.deinit();

        // Handling connections
        while (true) {
            const conn = if (server.accept()) |conn| conn else |_| continue;
            defer conn.stream.close();

            const client_ip = try std.fmt.allocPrint(allocator, "{}", .{conn.address});
            defer allocator.free(client_ip);

            var buffer = std.ArrayList(u8).init(allocator);
            defer buffer.deinit();

            var byte: [1]u8 = undefined;
            var req: Request = undefined;
            req.ip = client_ip;
            req.body = "";
            // Collect bytes of data from the stream. Then add it
            // to the ArrayList. Repeat this until all headers of th request end by detecting
            // appearance of "\r\n\r\n". Then read body if one is sent and if required headers exist and
            // method is chosen by the client.
            var headers_finished = false;
            var content_length: usize = 0;
            var transfer_encoding_chunked = false;
            var header_end: usize = 0;
            var header_string: []const u8 = undefined;
            while (true) {
                // Read Request stream
                _ = try conn.stream.read(&byte);
                try buffer.appendSlice(&byte);
                //check if header is finished
                if (!headers_finished) {
                    if (std.mem.indexOf(u8, buffer.items, "\r\n\r\n")) |header_end_index| {
                        headers_finished = true;
                        header_end = header_end_index;
                        header_string = buffer.items[0..header_end];
                        try buildRequestHeadersAndCookies(&req, header_string, allocator);
                        // Checking Request method and if it is one that can send a body.
                        // If it is one that must not have a body, exit the loop.
                        if (req.method == .GET or req.method == .CONNECT or req.method == .HEAD or req.method == .OPTIONS or req.method == .TRACE) break;

                        // If Request has a method that can contain a body, check if Content-Length Header or `Transfer-Encoding: chunked` is set.
                        // `Content-Length` will always be preferred over `Transfer-Encoding`.
                        // If none og these headers is set, exit loop. A Request body will not be accepted.
                        if (req.header("Content-Length")) |length| {
                            content_length = try std.fmt.parseUnsigned(u8, length, 0);
                        } else if (req.header("Transfer-Encoding")) |value| {
                            if (!eql(u8, value, "chunked")) break else transfer_encoding_chunked = true;
                        } else break;
                    }
                } else {
                    // check how the request body should be read, depending on the relevant header set in the request.
                    // `Content-Length` will always be preferred over `Transfer-Encoding`.
                    if (!transfer_encoding_chunked) {
                        // read body. Check length and add 4 because this is the length of "\r\n\r\n"
                        if (buffer.items.len - header_end >= content_length + 4) {
                            req.body = buffer.items[header_end .. header_end + content_length + 4];
                            break;
                        }
                    } else {
                        // read body until end sequence of chunked encoding is detected at the end of the stream
                        if (std.mem.endsWith(u8, buffer.items, "0\r\n\r\n")) {
                            req.body = buffer.items;
                            break;
                        }
                    }
                }
            }
            defer allocator.free(req.headers);
            defer allocator.free(req.cookies);

            // PREPARE FOR BUILDING THE RESPONSE
            // if there ist a path set in the uri trim the trailing slash in order to accept it later during the matching check.
            if (req.uri.len > 1) req.uri = std.mem.trimRight(u8, req.uri, "/");
            // Declare new URI variable and cut off a possible request string in order to accept it in a GET Request
            var uri_parts = std.mem.splitSequence(u8, req.uri, "?");
            const uri_string = uri_parts.first();

            // BUILDING THE RESPONSE
            // First initialize a notfound Response that is being changed if a Route path matches with Request URI.
            var res = Response.notfound("");

            // Do the matching check. Iterate over the Routes and change the Response being sent in case of matching.
            for (rt) |r| {
                var req_path = r[0];
                // Trim a possible trailing slash from Route path in order to accept it during the matching process.
                if (req_path.len > 1) req_path = std.mem.trimRight(u8, req_path, "/");
                // Check if there is a match
                if (eql(u8, req_path, uri_string)) {
                    // Change response with handling function in case of match.
                    res = r[1](&req);
                    // Exit loop in case of match
                    break;
                }
            }
            // Stringify the Response.
            const response_string = try stringifyResponse(res, allocator);
            // Free memory after writing Response and sending it to client.
            defer allocator.free(response_string);
            // SENDING THE RESPONSE
            // Write stringified Response and send it to client.
            _ = try conn.stream.write(response_string);
        }
    }
};

// Function that build the Request headers and cookies from stream
fn buildRequestHeadersAndCookies(req: *Request, bytes: []const u8, allocator: std.mem.Allocator) !void {
    var header_lines = std.mem.splitSequence(u8, bytes, "\r\n");
    var header_buffer = std.ArrayList(Header).init(allocator);
    var cookie_buffer = std.ArrayList(Request.Cookie).init(allocator);

    var header_items = std.mem.splitSequence(u8, header_lines.first(), " ");
    req.method = Method.parse(header_items.first());
    req.uri = if (header_items.next()) |value| value else "";

    if (header_items.next()) |value| {
        req.httpVersion = HTTP_Version.parse(value);
    } else {
        req.httpVersion = HTTP_Version.HTTP1_1;
    }

    while (header_lines.next()) |line| {
        var headers = std.mem.splitSequence(u8, line, ":");
        const item1 = headers.first();
        // Check if header is a cookie and parse it
        if (eql(u8, item1, "Cookie") or eql(u8, item1, "cookie")) {
            const item2 = if (headers.next()) |value| value else "";
            const cookies = try Request.Cookie.parse(item2, allocator);
            defer allocator.free(cookies);
            try cookie_buffer.appendSlice(cookies);
            continue;
        }
        const item2 = if (headers.next()) |value| std.mem.trim(u8, value, " ") else "";
        const header_pair = Header{ .key = item1, .value = item2 };
        try header_buffer.append(header_pair);
    }

    req.cookies = if (olderVersion) cookie_buffer.toOwnedSlice() else try cookie_buffer.toOwnedSlice();
    req.headers = if (olderVersion) header_buffer.toOwnedSlice() else try header_buffer.toOwnedSlice();
}

// Test the Request build function
test "build a Request" {
    const allocator = std.testing.allocator;
    const stream = "GET /test HTTP/1.1\r\nHost: localhost\r\nUser-Agent: Testbot\r\nCookie: Test-Cookie=Test\r\n\r\nThis is the test body!";
    var parts = std.mem.splitSequence(u8, stream, "\r\n\r\n");
    const client_ip = "127.0.0.1";
    const headers = parts.first();
    const body = parts.next().?;
    var req: Request = undefined;
    req.body = body;
    req.ip = client_ip;
    try buildRequestHeadersAndCookies(&req, headers, allocator);
    defer allocator.free(req.headers);
    defer allocator.free(req.cookies);
    try std.testing.expect(req.method == Method.GET);
    try std.testing.expect(req.httpVersion == HTTP_Version.HTTP1_1);
    try std.testing.expect(std.mem.eql(u8, req.uri, "/test"));
    try std.testing.expect(std.mem.eql(u8, req.headers[1].key, "User-Agent"));
    try std.testing.expect(std.mem.eql(u8, req.headers[1].value, "Testbot"));
    try std.testing.expect(std.mem.eql(u8, req.headers[0].key, "Host"));
    try std.testing.expect(std.mem.eql(u8, req.headers[0].value, "localhost"));
    try std.testing.expect(std.mem.eql(u8, req.body, "This is the test body!"));
    try std.testing.expect(std.mem.eql(u8, req.cookies[0].name, "Test-Cookie"));
    try std.testing.expect(std.mem.eql(u8, req.cookies[0].value, "Test"));
}

// Function that turns Response into a string
fn stringifyResponse(r: Response, allocator: std.mem.Allocator) ![]const u8 {
    var res = std.ArrayList(u8).init(allocator);
    try res.appendSlice(r.httpVersion.stringify());
    try res.append(' ');
    try res.appendSlice(r.status.stringify());
    try res.appendSlice("\r\n");
    // Add headers
    for (r.headers) |header| {
        try res.appendSlice(header.key);
        try res.appendSlice(": ");
        try res.appendSlice(header.value);
        try res.appendSlice("\r\n");
    }
    // Add cookie-headers
    for (r.cookies) |cookie| {
        const c = try cookie.stringify(allocator);
        defer allocator.free(c);
        if (!eql(u8, cookie.name, "") and !eql(u8, cookie.value, "")) {
            try res.appendSlice(c);
            try res.appendSlice("\r\n");
        }
    }
    try res.appendSlice("\r\n");
    try res.appendSlice(r.body);

    return if (olderVersion) res.toOwnedSlice() else try res.toOwnedSlice();
}

test "stringify Response" {
    const allocator = std.testing.allocator;
    const headers = [_]types.Header{.{ .key = "User-Agent", .value = "Testbot" }};
    const res = Response{ .headers = &headers, .body = "This is the body!" };
    const res_str = try stringifyResponse(res, allocator);
    defer allocator.free(res_str);
    try std.testing.expect(eql(u8, res_str, "HTTP/1.1 200 OK\r\nUser-Agent: Testbot\r\n\r\nThis is the body!"));
}

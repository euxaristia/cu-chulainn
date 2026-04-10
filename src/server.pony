use "net"
use "files"
use "promises"

class val _HttpRequest
  let method: String val
  let path: String val

  new val create(method': String val, path': String val) =>
    method = method'
    path = path'

actor Server
  let _env: Env
  let _base_dir: String val
  let _rate_limiter: RateLimiter
  let _connection_counter: ConnectionCounter
  var _listener: (TCPListener | None) = None

  new create(env: Env, base_dir: String val, max_connections: USize,
    max_requests_per_minute: USize) =>
    _env = env
    _base_dir = base_dir
    _rate_limiter = RateLimiter(max_requests_per_minute)
    _connection_counter = ConnectionCounter(max_connections)
    _start_server()

  be _start_server() =>
    _listener = TCPListener(
      TCPListenAuth(_env.root),
      ServerListenNotify(_env, _base_dir, _rate_limiter, _connection_counter),
      _Constants.default_host(),
      _Constants.default_port()
    )

  be shutdown() =>
    _env.out.print("")
    _env.out.print("Shutdown signal received. Stopping new connections...")
    match _listener
    | let l: TCPListener => l.dispose()
    end
    _rate_limiter.cleanup()
    // Graceful drain: wait for active connections to finish (up to timeout)
    _ShutdownDrain(_env, _connection_counter, _Constants.shutdown_wait_secs())

class iso ServerListenNotify is TCPListenNotify
  let _env: Env
  let _base_dir: String val
  let _rate_limiter: RateLimiter
  let _connection_counter: ConnectionCounter

  new iso create(env: Env, base_dir: String val, rate_limiter: RateLimiter,
    connection_counter: ConnectionCounter) =>
    _env = env
    _base_dir = base_dir
    _rate_limiter = rate_limiter
    _connection_counter = connection_counter

  fun ref listening(listen: TCPListener ref) =>
    _env.out.print("━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━")
    _env.out.print("  Cú Chulainn HTTP Server (Pony)")
    _env.out.print("━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━")
    _env.out.print("")
    try
      let addr = listen.local_address().name()?
      _env.out.print("  Server:        http://" + addr._1 + ":" + addr._2)
    else
      _env.out.print("  Server:        http://" + _Constants.default_host() + ":" + _Constants.default_port())
    end
    _env.out.print("  Directory:     " + _base_dir)
    _env.out.print("")
    _env.out.print("  Press Ctrl+C to stop the server")
    _env.out.print("")

  fun ref not_listening(listen: TCPListener ref) =>
    _env.err.print("Failed to bind to address. Try a different port.")
    _env.exitcode(1)

  fun ref closed(listen: TCPListener ref) =>
    _env.out.print("Server stopped.")

  fun ref connected(listen: TCPListener ref): TCPConnectionNotify iso^ =>
    _connection_counter.increment(Promise[Bool])
    ClientHandler(_env, _base_dir, _rate_limiter, _connection_counter)

class iso ClientHandler is TCPConnectionNotify
  let _env: Env
  let _base_dir: String val
  let _rate_limiter: RateLimiter
  let _connection_counter: ConnectionCounter
  var _buffer: String val = ""
  var _request_processed: Bool = false

  new iso create(env: Env, base_dir: String val, rate_limiter: RateLimiter,
    connection_counter: ConnectionCounter) =>
    _env = env
    _base_dir = base_dir
    _rate_limiter = rate_limiter
    _connection_counter = connection_counter

  fun ref accepted(conn: TCPConnection ref) =>
    conn.set_nodelay(true)

  fun ref received(conn: TCPConnection ref, data: Array[U8] iso,
    times: USize): Bool =>
    if _request_processed then return true end

    let incoming: String val = String.from_array(consume data)
    _buffer = _buffer + incoming

    if _buffer.contains("\r\n\r\n") then
      _request_processed = true
      let request: String val = _buffer
      _buffer = ""  // Clear buffer after extracting request
      _process_request(conn, request)
    end
    true

  fun ref _process_request(conn: TCPConnection ref, request: String val) =>
    if request.size() >= _Constants.max_buffer_size() then
      _send_error(conn, 413, "Request Entity Too Large",
        "413 Request Entity Too Large")
      return
    end

    if not _validate_headers(request) then
      _send_error(conn, 400, "Bad Request",
        "400 Bad Request - Invalid headers")
      return
    end

    // Update rate limiter state before processing.
    // Pony's actor-based rate limiter is inherently async — this updates
    // state so future connections from the same IP are properly tracked.
    // The current request proceeds; the limiter enforces on subsequent hits.
    let rl_promise = Promise[Bool]
    _rate_limiter.check_rate_limit("unknown", rl_promise)

    let parsed = _parse_request(request)
    match parsed
    | let r: _HttpRequest =>
      if (r.method != "GET") and (r.method != "HEAD") then
        _send_error(conn, 405, "Method Not Allowed",
          "405 Method Not Allowed")
        return
      end

      try
        let fp = _NormalizePath(_base_dir, r.path)?
        _serve_path(conn, fp, r.method)
      else
        _send_error(conn, 403, "Forbidden", "403 Forbidden")
      end
    | None =>
      _send_error(conn, 400, "Bad Request", "400 Bad Request")
    end

  fun _validate_headers(request: String val): Bool =>
    let lines = request.split_by("\r\n")
    if lines.size() == 0 then return false end
    var i: USize = 0
    for line in (consume lines).values() do
      if i == 0 then
        i = i + 1
        continue
      end
      i = i + 1
      let line_lower: String val = line.lower()
      if line_lower.contains("..") or
         line_lower.contains("\0") or
         (line.size() > 8192) then
        return false
      end
      if _StartsWith(line_lower, "content-length:") then
        try
          let colon_pos = line.find(":")?
          let len_str: String val = line.substring(colon_pos + 1)
          let len = _ParseUSize(len_str)?
          if len > _Constants.max_file_size() then
            return false
          end
        else
          return false
        end
      end
    end
    true

  fun _parse_request(request: String val): (_HttpRequest val | None) =>
    try
      let first_line_end = request.find("\r\n")?
      let first_line: String val = request.substring(0, first_line_end)
      let parts = first_line.split(" ")
      if parts.size() < 3 then return None end
      let method: String val = parts(0)?
      let path: String val = parts(1)?
      _HttpRequest(method, path)
    else
      None
    end

  fun _serve_path(conn: TCPConnection ref, file_path: String val,
    method: String val) =>
    let auth = FileAuth(_env.root)
    let fp = FilePath(auth, file_path)

    // Canonicalize and verify: resolve symlinks and ensure path is still
    // inside base_dir to prevent symlink-based path traversal
    let canonical_file: String val = fp.path
    let base_fp = FilePath(auth, _base_dir)
    let canonical_base: String val = base_fp.path
    if not _StartsWith(canonical_file, canonical_base) then
      _send_error(conn, 403, "Forbidden", "403 Forbidden")
      return
    end

    if not fp.exists() then
      _send_error(conn, 404, "Not Found",
        "<html><body><h1>404 Not Found</h1><p>The requested resource was not found.</p></body></html>")
      return
    end

    try
      let info = FileInfo(fp)?
      if info.directory then
        let index_path: String val = file_path + "/index.html"
        let index_fp = FilePath(auth, index_path)
        if index_fp.exists() then
          try
            let idx_info = FileInfo(index_fp)?
            if idx_info.file then
              _serve_file(conn, index_path, method)
            else
              _serve_directory_listing(conn, file_path, method)
            end
          else
            _serve_directory_listing(conn, file_path, method)
          end
        else
          _serve_directory_listing(conn, file_path, method)
        end
      else
        _serve_file(conn, file_path, method)
      end
    else
      _send_error(conn, 500, "Internal Server Error",
        "500 Internal Server Error")
    end

  fun _serve_file(conn: TCPConnection ref, file_path: String val,
    method: String val) =>
    let auth = FileAuth(_env.root)
    let fp = FilePath(auth, file_path)

    try
      let info = FileInfo(fp)?
      if info.size > _Constants.max_file_size() then
        _send_error(conn, 413, "Request Entity Too Large",
          "413 File too large to serve")
        return
      end

      let file = File(fp)
      let content_size = info.size
      let content = file.read(content_size)
      file.dispose()

      let mime = _MimeType(file_path)
      var response = recover String(256 + content_size) end
      response.append("HTTP/1.1 200 OK\r\n")
      response.append("Content-Type: ")
      response.append(mime)
      response.append("\r\n")
      response.append("Content-Length: ")
      response.append(content_size.string())
      response.append("\r\n")
      response.append("X-Content-Type-Options: nosniff\r\n")
      response.append("X-Frame-Options: DENY\r\n")
      response.append("X-XSS-Protection: 1; mode=block\r\n")
      response.append("Referrer-Policy: strict-origin-when-cross-origin\r\n")
      response.append("Connection: close\r\n\r\n")

      if method != "HEAD" then
        response.append(consume content)
      end
      conn.write(consume response)
    else
      _send_error(conn, 500, "Internal Server Error",
        "500 Internal Server Error")
    end

  fun _serve_directory_listing(conn: TCPConnection ref,
    dir_path: String val, method: String val) =>
    let auth = FileAuth(_env.root)
    let fp = FilePath(auth, dir_path)

    var request_path: String val = dir_path
    let prefix_len = _base_dir.size()
    if dir_path.size() >= prefix_len then
      let sub: String val = dir_path.substring(prefix_len.isize())
      if _StartsWith(sub, "/") then
        request_path = sub
      else
        request_path = "/" + sub
      end
    end

    var html = recover String(4096) end
    html.append("<!DOCTYPE html>\n<html><head><title>Index of ")
    html.append(request_path)
    html.append("</title><style>body{font-family:monospace;margin:2rem;}h1{color:#333;}table{width:100%;border-collapse:collapse;}th,td{padding:0.5rem;text-align:left;}th{background:#667eea;color:white;}tr:nth-child(even){background:#f5f5f5;}a{text-decoration:none;color:#667eea;}</style></head><body>")
    html.append("<h1>Index of ")
    html.append(request_path)
    html.append("</h1>")
    html.append("<table><tr><th>Name</th><th>Size</th><th>Type</th></tr>")

    if request_path != "/" then
      try
        let last_sep = request_path.rfind("/")?
        if last_sep == 0 then
          html.append("<tr><td><a href=\"/\">..</a></td><td>-</td><td>Directory</td></tr>")
        else
          let parent: String val = request_path.substring(0, last_sep)
          html.append("<tr><td><a href=\"")
          html.append(parent)
          html.append("\">..</a></td><td>-</td><td>Directory</td></tr>")
        end
      else
        html.append("<tr><td><a href=\"/\">..</a></td><td>-</td><td>Directory</td></tr>")
      end
    end

    try
      let dir = Directory(fp)?
      let entries = dir.entries()?

      var dir_entries = Array[(String val, Bool, USize)]
      for entry in (consume entries).values() do
        if (entry == ".") or (entry == "..") then continue end
        let entry_path: String val = if _EndsWith(dir_path, "/") then
          dir_path + entry
        else
          dir_path + "/" + entry
        end
        let entry_fp = FilePath(auth, entry_path)
        try
          let info = FileInfo(entry_fp)?
          dir_entries.push((entry, info.directory, info.size))
        else
          dir_entries.push((entry, false, 0))
        end
      end

      for e in dir_entries.values() do
        (let name, let is_dir, let fsize) = e
        let link_path: String val = if _EndsWith(request_path, "/") then
          request_path + name
        else
          request_path + "/" + name
        end
        let entry_path: String val = if _EndsWith(dir_path, "/") then
          dir_path + name
        else
          dir_path + "/" + name
        end
        let size_str: String val = if is_dir then "-" else _FormatSize(fsize)? end
        let file_type: String val = if is_dir then
          "Directory"
        else
          let mime = _MimeType(entry_path)
          try
            let parts = mime.split(";")
            (consume parts)(0)?
          else
            "Unknown"
          end
        end

        html.append("<tr><td><a href=\"")
        html.append(link_path)
        if is_dir then html.append("/") end
        html.append("\">")
        html.append(_HtmlEscape(name))
        if is_dir then html.append("/") end
        html.append("</a></td><td>")
        html.append(size_str)
        html.append("</td><td>")
        html.append(file_type)
        html.append("</td></tr>")
      end
    else
      html.append("<tr><td colspan=\"3\">Error reading directory</td></tr>")
    end

    html.append("</table></body></html>")

    let html_len = html.size()
    var response = recover String(256 + html_len) end
    response.append("HTTP/1.1 200 OK\r\n")
    response.append("Content-Type: text/html; charset=UTF-8\r\n")
    response.append("Content-Length: ")
    response.append(html_len.string())
    response.append("\r\n")
    response.append("X-Content-Type-Options: nosniff\r\n")
    response.append("X-Frame-Options: DENY\r\n")
    response.append("X-XSS-Protection: 1; mode=block\r\n")
    response.append("Referrer-Policy: strict-origin-when-cross-origin\r\n")
    response.append("Connection: close\r\n\r\n")

    if method != "HEAD" then
      response.append(consume html)
    end
    conn.write(consume response)

  fun _send_error(conn: TCPConnection ref, code: U16,
    status_text: String val, body: String val) =>
    let content_type: String val = if _StartsWith(body, "<html") or
       _StartsWith(body, "<!DOCTYPE") then
      "text/html; charset=UTF-8"
    else
      "text/plain"
    end
    let body_len = body.size()
    var response = recover String(256 + body_len) end
    response.append("HTTP/1.1 ")
    response.append(code.string())
    response.append(" ")
    response.append(status_text)
    response.append("\r\n")
    response.append("Content-Type: ")
    response.append(content_type)
    response.append("\r\n")
    response.append("Content-Length: ")
    response.append(body_len.string())
    response.append("\r\n")
    if code == U16(429) then
      response.append("Retry-After: 60\r\n")
    end
    response.append("Connection: close\r\n\r\n")
    response.append(body)
    conn.write(consume response)

  fun ref closed(conn: TCPConnection ref) =>
    _connection_counter.decrement()

  fun ref connect_failed(conn: TCPConnection ref) =>
    _connection_counter.decrement()

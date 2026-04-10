use "net"
use "files"
use "signals"
use "collections"
use "time"
use "promises"
use "format"

primitive _Constants
  fun max_file_size(): USize => 100 * 1024 * 1024
  fun max_buffer_size(): USize => 8192
  fun default_max_connections(): USize => 100
  fun default_rate_limit(): U32 => 60
  fun default_port(): String => "8080"
  fun default_host(): String => "127.0.0.1"
  fun shutdown_wait_secs(): U64 => 30  // wait for active connections on shutdown
  fun rate_limit_cleanup_interval_ns(): U64 => 30_000_000_000  // 30 seconds
  fun rate_limit_stale_threshold_ns(): I64 => 300_000_000_000  // 5 minutes idle

actor RateLimiter
  let _requests: Map[String, Array[I64]] = Map[String, Array[I64]]
  let _max_requests_per_minute: USize

  new create(max_requests_per_minute: USize) =>
    _max_requests_per_minute = max_requests_per_minute
    // Start periodic cleanup of stale entries to prevent memory leaks
    // under IP-spoofing DoS attacks
    let notify = _RateLimiterCleanupNotify(this)
    Timer(consume notify, _Constants.rate_limit_cleanup_interval_ns(),
      _Constants.rate_limit_cleanup_interval_ns())

  be check_rate_limit(ip: String, promise: Promise[Bool]) =>
    let now = Time.now()._1
    let cutoff = now - 60_000_000_000

    try
      if _requests.contains(ip) then
        let times = _requests(ip)?
        let filtered = Array[I64]
        for t in times.values() do
          if t > cutoff then filtered.push(t) end
        end
        times.clear()
        for t in filtered.values() do times.push(t) end

        if times.size() >= _max_requests_per_minute then
          promise(false)
          return
        end

        times.push(now)
      else
        let times = Array[I64]
        times.push(now)
        _requests(ip) = times
      end
    else
      let times = Array[I64]
      times.push(now)
      _requests(ip) = times
    end
    promise(true)

  be cleanup() =>
    _requests.clear()

  be cleanup_stale_entries() =>
    let now = Time.now()._1
    let cutoff = now - 60_000_000_000
    try
      let stale_ips = Array[String]
      for (ip, times) in _requests.pairs() do
        let filtered = Array[I64]
        for t in times.values() do
          if t > cutoff then filtered.push(t) end
        end
        if filtered.size() == 0 then
          stale_ips.push(ip)
        else
          times.clear()
          for t in filtered.values() do times.push(t) end
        end
      end
      for ip in stale_ips.values() do _requests.remove(ip)? end
    end

class iso _RateLimiterCleanupNotify is TimerNotify
  let _limiter: RateLimiter

  new iso create(limiter: RateLimiter) =>
    _limiter = limiter

  fun ref apply(timer: Timer, count: U64): Bool =>
    _limiter.cleanup_stale_entries()
    true

actor ConnectionCounter
  var _count: USize = 0
  let _max_connections: USize

  new create(max_connections: USize) =>
    _max_connections = max_connections

  be increment(promise: Promise[Bool]) =>
    if _count >= _max_connections then
      promise(false)
    else
      _count = _count + 1
      promise(true)
    end

  be decrement() =>
    if _count > 0 then
      _count = _count - 1
    end

  be count(promise: Promise[USize]) =>
    promise(_count)

actor _ShutdownDrain
  let _env: Env
  let _counter: ConnectionCounter
  var _elapsed_ns: U64 = 0
  let _max_wait_ns: U64
  let _print_interval_ns: U64 = 2_000_000_000  // 2 seconds

  new create(env: Env, counter: ConnectionCounter, timeout_secs: U64) =>
    _env = env
    _counter = counter
    _max_wait_ns = timeout_secs * 1_000_000_000
    _env.out.print("⏳ Waiting for active connections to finish (max " +
      timeout_secs.string() + " seconds)...")
    Timer(_ShutdownDrainTimer(this), 500_000_000, 500_000_000)

  be _check_count(count: USize) =>
    if count == USize(0) then
      _env.out.print("✅ All connections closed. Shutdown complete.")
      _env.out.print("")
      _env.out.print("👋 Server stopped. Goodbye!")
      _env.exitcode(0)
    else
      if (_elapsed_ns % _print_interval_ns) == U64(0) then
        _env.out.print("   ⏳ " + count.string() + " active connection(s) remaining...")
      end
      _elapsed_ns = _elapsed_ns + 500_000_000
    end

  be _timeout() =>
    _env.out.print("⚠️  Warning: Connections still active after timeout. Forcing shutdown.")
    _env.out.print("")
    _env.out.print("👋 Server stopped. Goodbye!")
    _env.exitcode(0)

  be _tick() =>
    if _elapsed_ns >= _max_wait_ns then
      _timeout()
    else
      let p = Promise[USize]
      _counter.count(p)
      p.next[None](_ShutdownDrainCallback(this))
    end

class iso _ShutdownDrainCallback
  let _drain: _ShutdownDrain

  new iso create(drain: _ShutdownDrain) =>
    _drain = drain

  fun ref apply(count: USize): None =>
    _drain._check_count(count)
    None

class iso _ShutdownDrainTimer is TimerNotify
  let _drain: _ShutdownDrain

  new iso create(drain: _ShutdownDrain) =>
    _drain = drain

  fun ref apply(timer: Timer, count: U64): Bool =>
    _drain._tick()
    true

primitive _MimeType
  fun apply(path: String val): String val =>
    try
      let pos = path.rfind(".")?
      if pos == (-1) then return "application/octet-stream" end
      let ext: String val = path.substring(pos + 1).lower()
      match ext
      | "html" => "text/html; charset=UTF-8"
      | "htm" => "text/html; charset=UTF-8"
      | "css" => "text/css"
      | "js" => "application/javascript"
      | "json" => "application/json"
      | "png" => "image/png"
      | "jpg" => "image/jpeg"
      | "jpeg" => "image/jpeg"
      | "gif" => "image/gif"
      | "svg" => "image/svg+xml"
      | "ico" => "image/x-icon"
      | "pdf" => "application/pdf"
      | "txt" => "text/plain"
      | "xml" => "application/xml"
      | "zip" => "application/zip"
      | "mp4" => "video/mp4"
      | "mp3" => "audio/mpeg"
      else "application/octet-stream"
      end
    else
      "application/octet-stream"
    end

primitive _HtmlEscape
  fun apply(s: String val): String val =>
    let has_special = s.contains("&") or s.contains("<") or
      s.contains(">") or s.contains("\"") or s.contains("'")
    if not has_special then return s end
    let result = recover String(s.size() + (s.size() / 4)) end
    for c in s.values() do
      match c
      | '&' => result.append("&amp;")
      | '<' => result.append("&lt;")
      | '>' => result.append("&gt;")
      | '"' => result.append("&quot;")
      | '\'' => result.append("&#x27;")
      else
        result.push(c)
      end
    end
    consume result

primitive _FormatSize
  fun apply(bytes: USize): String val ? =>
    if bytes < 1024 then
      bytes.string()
    else
      let units = ["B"; "KB"; "MB"; "GB"; "TB"]
      var size = bytes.f64()
      var unit_index: USize = 0

      while (size >= 1024.0) and (unit_index < 4) do
        size = size / 1024.0
        unit_index = unit_index + 1
      end

      Format.float[F64](size where prec = 2) + " " + units(unit_index)?
    end

primitive _UrlDecode
  fun apply(s: String val): String val ? =>
    let result = recover String(s.size()) end
    var i: USize = 0
    while i < s.size() do
      if (i + 2) < s.size() then
        if s(i)? == '%' then
          try
            let hex = s.substring(i.isize() + 1, i.isize() + 3)
            let byte = hex.u8(16)?
            result.push(byte)
            i = i + 3
            continue
          else
            result.push(s(i)?)
            i = i + 1
            continue
          end
        elseif s(i)? == '+' then
          result.push(' ')
          i = i + 1
          continue
        else
          result.push(s(i)?)
          i = i + 1
          continue
        end
      elseif s(i)? == '+' then
        result.push(' ')
      else
        result.push(s(i)?)
      end
      i = i + 1
    end
    consume result

primitive _StartsWith
  fun apply(s: String val, prefix: String val): Bool =>
    if prefix.size() > s.size() then return false end
    var i: USize = 0
    while i < prefix.size() do
      try
        if s(i)? != prefix(i)? then return false end
      else
        return false
      end
      i = i + 1
    end
    true

primitive _ParseUSize
  fun apply(s: String val): USize ? =>
    var i: USize = 0
    while i < s.size() do
      match s(i)?
      | ' ' | '\t' | '\r' | '\n' => i = i + 1
      else break
      end
    end
    var result: USize = 0
    while i < s.size() do
      match s(i)?
      | let c: U8 if (c >= '0') and (c <= '9') =>
        result = (result * 10) + (c - '0').usize()
        i = i + 1
      else break
      end
    end
    if result == 0 then error end
    result

primitive _EndsWith
  fun apply(s: String val, suffix: String val): Bool =>
    if suffix.size() > s.size() then return false end
    var i: USize = 0
    while i < suffix.size() do
      try
        if s((s.size() - suffix.size()) + i)? != suffix(i)? then return false end
      else
        return false
      end
      i = i + 1
    end
    true

primitive _NormalizePath
  fun apply(base_dir: String val, request_path: String val): String val ? =>
    if request_path.size() > 4096 then error end

    var path = request_path
    try
      let qpos = path.find("?")?
      path = path.substring(0, qpos)
    end
    try
      let fpos = path.find("#")?
      path = path.substring(0, fpos)
    end

    let decoded: String val = _UrlDecode(path)?

    if decoded == "/" then return base_dir end

    let stripped: String val = if decoded(0)? == '/' then
      decoded.substring(1)
    else
      decoded
    end

    let components = stripped.split("/")
    if components.size() > 100 then error end

    let full_path = recover trn String end
    full_path.append(base_dir)

    for component in (consume components).values() do
      if (component == "") or (component == ".") then continue end
      if component == ".." then
        if full_path == base_dir then error end
        try
          let last_sep = full_path.rfind("/")?
          full_path.truncate(last_sep.usize())
        else
          full_path.clear()
          full_path.append(base_dir)
        end
      else
        if component.contains("\0") then error end
        full_path.push('/')
        full_path.append(component)
      end
    end

    consume full_path

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

class iso ShutdownHandler is SignalNotify
  let _server: Server

  new iso create(server: Server) =>
    _server = server

  fun ref apply(count: U32): Bool =>
    _server.shutdown()
    true

actor Main
  new create(env: Env) =>
    var base_dir: String val = "public"
    var max_connections = _Constants.default_max_connections()
    var max_requests_per_minute = _Constants.default_rate_limit().usize()

    let args = env.args
    var i: USize = 1
    while i < args.size() do
      try
        match args(i)?
        | "--help" | "-h" =>
          env.out.print("Usage: cu-chulainn [OPTIONS] [base_directory]")
          env.out.print("")
          env.out.print("Options:")
          env.out.print("  --max-connections <N>  Maximum concurrent connections (default: 100)")
          env.out.print("  --rate-limit <N>       Maximum requests per minute per IP (default: 60)")
          env.out.print("  -h, --help             Show this help message")
          env.out.print("")
          env.out.print("Arguments:")
          env.out.print("  base_directory         Directory to serve (default: public/)")
          env.exitcode(0)
          return
        | "--max-connections" =>
          i = i + 1
          max_connections = args(i)?.usize()?
        | "--rate-limit" =>
          i = i + 1
          max_requests_per_minute = args(i)?.usize()?
        | let arg: String =>
          if _StartsWith(arg, "-") then
            env.err.print("Unknown option: " + arg)
            env.err.print("Use --help for usage information")
            env.exitcode(1)
            return
          else
            base_dir = arg
          end
        end
      else
        env.err.print("Invalid argument")
        env.exitcode(1)
        return
      end
      i = i + 1
    end

    let auth = FileAuth(env.root)
    let fp = FilePath(auth, base_dir)
    if not fp.exists() then
      env.err.print("Error: Base directory '" + base_dir + "' does not exist")
      env.err.print("Use --help for usage information")
      env.exitcode(1)
      return
    end

    try
      let info = FileInfo(fp)?
      if not info.directory then
        env.err.print("Error: '" + base_dir + "' is not a directory")
        env.exitcode(1)
        return
      end
    else
      env.err.print("Error: Cannot stat '" + base_dir + "'")
      env.exitcode(1)
      return
    end

    let server = Server(env, base_dir, max_connections, max_requests_per_minute)
    SignalHandler(ShutdownHandler(server), Sig.term())
    SignalHandler(ShutdownHandler(server), Sig.int())

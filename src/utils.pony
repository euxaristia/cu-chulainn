use "format"

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

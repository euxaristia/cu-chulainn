use "net"
use "files"
use "signals"

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

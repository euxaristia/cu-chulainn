use "collections"
use "time"
use "promises"

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

use "collections"
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

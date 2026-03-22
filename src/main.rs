use std::collections::HashMap;
use std::fs;
use std::io::{Read, Write};
use std::net::{TcpListener, TcpStream};
use std::path::{Path, PathBuf};
use std::sync::{
    atomic::{AtomicBool, Ordering},
    Arc, Mutex,
};
use std::thread;
use std::time::{Duration, Instant};

use ctrlc::set_handler;
use zeroize::{Zeroize, ZeroizeOnDrop};

use cu_chulainn::server;

// MIME type mappings
fn get_mime_type(path: &Path) -> &'static str {
    match path.extension().and_then(|s| s.to_str()) {
        Some("html") | Some("htm") => "text/html; charset=UTF-8",
        Some("css") => "text/css",
        Some("js") => "application/javascript",
        Some("json") => "application/json",
        Some("png") => "image/png",
        Some("jpg") | Some("jpeg") => "image/jpeg",
        Some("gif") => "image/gif",
        Some("svg") => "image/svg+xml",
        Some("ico") => "image/x-icon",
        Some("pdf") => "application/pdf",
        Some("txt") => "text/plain",
        Some("xml") => "application/xml",
        Some("zip") => "application/zip",
        Some("mp4") => "video/mp4",
        Some("mp3") => "audio/mpeg",
        _ => "application/octet-stream",
    }
}

// Use functions from the library module

// Generate directory listing HTML
fn generate_directory_listing(path: &Path, request_path: &str) -> String {
    let mut html = String::from("<!DOCTYPE html>\n<html><head><title>Index of ");
    html.push_str(request_path);
    html.push_str("</title><style>body{font-family:monospace;margin:2rem;}h1{color:#333;}table{width:100%;border-collapse:collapse;}th,td{padding:0.5rem;text-align:left;}th{background:#667eea;color:white;}tr:nth-child(even){background:#f5f5f5;}a{text-decoration:none;color:#667eea;}</style></head><body>");
    html.push_str("<h1>Index of ");
    html.push_str(request_path);
    html.push_str("</h1><table><tr><th>Name</th><th>Size</th><th>Type</th></tr>");

    // Add parent directory link if not at root
    if request_path != "/" {
        let parent_path = if let Some(parent) = Path::new(request_path).parent() {
            if parent.to_str() == Some("") {
                "/"
            } else {
                parent.to_str().unwrap_or("/")
            }
        } else {
            "/"
        };
        html.push_str("<tr><td><a href=\"");
        html.push_str(parent_path);
        html.push_str("\">..</a></td><td>-</td><td>Directory</td></tr>");
    }

    // List directory contents
    if let Ok(entries) = fs::read_dir(path) {
        let mut entries: Vec<_> = entries.collect();
        entries.sort_by(|a, b| {
            let a = a.as_ref().ok();
            let b = b.as_ref().ok();
            match (a, b) {
                (Some(a), Some(b)) => {
                    let a_is_dir = a.path().is_dir();
                    let b_is_dir = b.path().is_dir();
                    match (a_is_dir, b_is_dir) {
                        (true, false) => std::cmp::Ordering::Less,
                        (false, true) => std::cmp::Ordering::Greater,
                        _ => {
                            let a_name = a.file_name().to_string_lossy().to_lowercase();
                            let b_name = b.file_name().to_string_lossy().to_lowercase();
                            a_name.cmp(&b_name)
                        }
                    }
                }
                _ => std::cmp::Ordering::Equal,
            }
        });

        for entry in entries.into_iter().flatten() {
            let file_path = entry.path();
            let file_name = entry.file_name();
            let name = file_name.to_string_lossy();
            let is_dir = file_path.is_dir();

            let mut link_path = request_path.to_string();
            if !link_path.ends_with('/') {
                link_path.push('/');
            }
            link_path.push_str(&name);

            let size = if is_dir {
                "-".to_string()
            } else {
                file_path
                    .metadata()
                    .map(|m| format_size(m.len()))
                    .unwrap_or_else(|_| "?".to_string())
            };

            let file_type = if is_dir {
                "Directory"
            } else {
                get_mime_type(&file_path)
                    .split(';')
                    .next()
                    .unwrap_or("Unknown")
            };

            html.push_str("<tr><td><a href=\"");
            html.push_str(&link_path);
            if is_dir {
                html.push('/');
            }
            html.push_str("\">");
            html.push_str(&html_escape(&name));
            if is_dir {
                html.push('/');
            }
            html.push_str("</a></td><td>");
            html.push_str(&size);
            html.push_str("</td><td>");
            html.push_str(file_type);
            html.push_str("</td></tr>");
        }
    }

    html.push_str("</table></body></html>");
    html
}

// Format file size
fn format_size(bytes: u64) -> String {
    const UNITS: &[&str] = &["B", "KB", "MB", "GB", "TB"];
    let mut size = bytes as f64;
    let mut unit_index = 0;

    while size >= 1024.0 && unit_index < UNITS.len() - 1 {
        size /= 1024.0;
        unit_index += 1;
    }

    if unit_index == 0 {
        format!("{} {}", bytes, UNITS[unit_index])
    } else {
        format!("{:.2} {}", size, UNITS[unit_index])
    }
}

// HTML escape
fn html_escape(s: &str) -> String {
    s.replace('&', "&amp;")
        .replace('<', "&lt;")
        .replace('>', "&gt;")
        .replace('"', "&quot;")
        .replace('\'', "&#x27;")
}

// Send HTTP response
fn send_response(
    stream: &mut TcpStream,
    status_code: u16,
    status_text: &str,
    headers: &HashMap<&str, &str>,
    body: Option<&[u8]>,
) {
    let mut response = format!("HTTP/1.1 {} {}\r\n", status_code, status_text);

    for (key, value) in headers {
        response.push_str(&format!("{}: {}\r\n", key, value));
    }

    if let Some(body) = body {
        response.push_str(&format!("Content-Length: {}\r\n", body.len()));
    }

    response.push_str("Connection: close\r\n\r\n");

    if let Err(e) = stream.write_all(response.as_bytes()) {
        eprintln!("Error writing response headers: {}", e);
        return;
    }

    if let Some(body) = body {
        if let Err(e) = stream.write_all(body) {
            eprintln!("Error writing response body: {}", e);
        }
    }

    let _ = stream.flush();
}

// Maximum file size to serve (100MB) - prevents DoS from huge files
const MAX_FILE_SIZE: u64 = 100 * 1024 * 1024;

// Security configuration constants
const MAX_CONCURRENT_CONNECTIONS: usize = 100;
const CONNECTION_TIMEOUT_SECS: u64 = 30;
const REQUEST_TIMEOUT_SECS: u64 = 10;
const MAX_REQUESTS_PER_MINUTE: u32 = 60;

// Secure buffer that zeroizes on drop
// This protects sensitive request data from being readable in memory dumps,
// swap files, or after the buffer goes out of scope
#[derive(ZeroizeOnDrop)]
struct SecureBuffer {
    data: Vec<u8>,
}

impl SecureBuffer {
    fn new(size: usize) -> Self {
        Self {
            data: vec![0; size],
        }
    }

    fn as_mut_slice(&mut self) -> &mut [u8] {
        &mut self.data
    }

    fn as_slice(&self) -> &[u8] {
        &self.data
    }

    fn len(&self) -> usize {
        self.data.len()
    }
}

impl Zeroize for SecureBuffer {
    fn zeroize(&mut self) {
        self.data.zeroize();
    }
}

// Rate limiting structure with secure cleanup
struct RateLimiter {
    requests: Arc<Mutex<HashMap<String, Vec<Instant>>>>,
    max_requests_per_minute: usize,
}

impl RateLimiter {
    fn new(max_requests_per_minute: usize) -> Self {
        Self {
            requests: Arc::new(Mutex::new(HashMap::new())),
            max_requests_per_minute,
        }
    }

    fn check_rate_limit(&self, ip: &str) -> bool {
        let mut requests = self.requests.lock().unwrap();
        let now = Instant::now();
        let cutoff = now - Duration::from_secs(60);

        // Clean old entries (securely remove expired data)
        requests.retain(|_, times| {
            times.retain(|&time| time > cutoff);
            !times.is_empty()
        });

        // Get or create entry for this IP
        let entry = requests.entry(ip.to_string()).or_default();

        // Check if rate limit exceeded
        if entry.len() >= self.max_requests_per_minute {
            return false;
        }

        // Add current request
        entry.push(now);
        true
    }

    // Securely clean up rate limiting data
    #[allow(dead_code)]
    fn cleanup(&self) {
        let mut requests = self.requests.lock().unwrap();
        // Clear all entries and ensure memory is released
        requests.clear();
        // HashMap will be dropped and memory zeroized by allocator
    }
}

// Connection counter
struct ConnectionCounter {
    count: Arc<Mutex<usize>>,
    max_connections: usize,
}

impl ConnectionCounter {
    fn new(max_connections: usize) -> Self {
        Self {
            count: Arc::new(Mutex::new(0)),
            max_connections,
        }
    }

    fn increment(&self) -> bool {
        let mut count = self.count.lock().unwrap();
        if *count >= self.max_connections {
            return false;
        }
        *count += 1;
        true
    }

    fn decrement(&self) {
        let mut count = self.count.lock().unwrap();
        *count = count.saturating_sub(1);
    }

    fn get(&self) -> usize {
        let count = self.count.lock().unwrap();
        *count
    }
}

// Guard to ensure connection counter is decremented when connection handler exits
struct ConnectionGuard {
    counter: Arc<ConnectionCounter>,
}

impl ConnectionGuard {
    fn new(counter: Arc<ConnectionCounter>) -> Self {
        Self { counter }
    }
}

impl Drop for ConnectionGuard {
    fn drop(&mut self) {
        self.counter.decrement();
    }
}

// Validate request headers for security
fn validate_headers(request: &str) -> bool {
    let lines: Vec<&str> = request.lines().collect();
    if lines.is_empty() {
        return false;
    }

    // Check for suspicious headers or patterns
    for line in lines.iter().skip(1) {
        let line_lower = line.to_lowercase();

        // Reject requests with suspicious patterns
        if line_lower.contains("..") || line_lower.contains("\0") || line_lower.len() > 8192 {
            return false;
        }

        // Validate Content-Length if present
        if line_lower.starts_with("content-length:") {
            if let Some(len_str) = line.split(':').nth(1) {
                if let Ok(len) = len_str.trim().parse::<u64>() {
                    // Reject extremely large content-length
                    if len > MAX_FILE_SIZE {
                        return false;
                    }
                } else {
                    return false; // Invalid content-length
                }
            }
        }
    }

    true
}

// Handle client request
fn handle_client(
    mut stream: TcpStream,
    base_dir: PathBuf,
    rate_limiter: Arc<RateLimiter>,
    connection_counter: Arc<ConnectionCounter>,
) {
    // Create guard to ensure counter is decremented on any exit path
    let _guard = ConnectionGuard::new(Arc::clone(&connection_counter));

    // Set read/write timeouts
    let timeout = Duration::from_secs(REQUEST_TIMEOUT_SECS);
    let _ = stream.set_read_timeout(Some(timeout));
    let _ = stream.set_write_timeout(Some(timeout));

    // Get client IP for rate limiting
    let client_ip = stream
        .peer_addr()
        .map(|addr| addr.ip().to_string())
        .unwrap_or_else(|_| "unknown".to_string());

    // Check rate limit
    if !rate_limiter.check_rate_limit(&client_ip) {
        let mut headers = HashMap::new();
        headers.insert("Content-Type", "text/plain");
        headers.insert("Retry-After", "60");
        send_response(
            &mut stream,
            429,
            "Too Many Requests",
            &headers,
            Some(b"429 Too Many Requests - Rate limit exceeded"),
        );
        return;
    }

    // Use secure buffer that zeroizes on drop
    let mut secure_buffer = SecureBuffer::new(8192);

    // Read request (handle WouldBlock in case stream is still non-blocking)
    let read_result = stream.read(secure_buffer.as_mut_slice());

    match read_result {
        Ok(size) => {
            if size == 0 {
                // Buffer will be zeroized on drop
                return;
            }

            // Prevent extremely large requests
            if size >= secure_buffer.len() {
                // Request might be larger than buffer - reject it
                let mut headers = HashMap::new();
                headers.insert("Content-Type", "text/plain");
                send_response(
                    &mut stream,
                    413,
                    "Request Entity Too Large",
                    &headers,
                    Some(b"413 Request Entity Too Large"),
                );
                // Buffer will be zeroized on drop
                return;
            }

            // Create request string from secure buffer
            let request_str = String::from_utf8_lossy(&secure_buffer.as_slice()[..size]);

            // Validate headers before parsing
            if !validate_headers(&request_str) {
                let mut headers = HashMap::new();
                headers.insert("Content-Type", "text/plain");
                send_response(
                    &mut stream,
                    400,
                    "Bad Request",
                    &headers,
                    Some(b"400 Bad Request - Invalid headers"),
                );
                return;
            }

            let request = match server::parse_request(&request_str) {
                Some(req) => req,
                None => {
                    let mut headers = HashMap::new();
                    headers.insert("Content-Type", "text/plain");
                    send_response(
                        &mut stream,
                        400,
                        "Bad Request",
                        &headers,
                        Some(b"400 Bad Request"),
                    );
                    return;
                }
            };

            // Only support GET and HEAD methods
            if request.method != "GET" && request.method != "HEAD" {
                let mut headers = HashMap::new();
                headers.insert("Content-Type", "text/plain");
                send_response(
                    &mut stream,
                    405,
                    "Method Not Allowed",
                    &headers,
                    Some(b"405 Method Not Allowed"),
                );
                return;
            }

            // Normalize and validate path
            let file_path = match server::normalize_path(&base_dir, &request.path) {
                Ok(path) => path,
                Err(_) => {
                    let mut headers = HashMap::new();
                    headers.insert("Content-Type", "text/plain");
                    send_response(
                        &mut stream,
                        403,
                        "Forbidden",
                        &headers,
                        Some(b"403 Forbidden"),
                    );
                    return;
                }
            };

            // Check if path exists
            if !file_path.exists() {
                let mut headers = HashMap::new();
                headers.insert("Content-Type", "text/html; charset=UTF-8");
                let body = b"<html><body><h1>404 Not Found</h1><p>The requested resource was not found.</p></body></html>";
                send_response(&mut stream, 404, "Not Found", &headers, Some(body));
                return;
            }

            // Handle directory
            if file_path.is_dir() {
                // Check for index.html
                let index_path = file_path.join("index.html");
                if index_path.exists() && index_path.is_file() {
                    match fs::read(&index_path) {
                        Ok(content) => {
                            let mut headers = HashMap::new();
                            headers.insert("Content-Type", "text/html; charset=UTF-8");
                            let body = if request.method == "HEAD" {
                                None
                            } else {
                                Some(content.as_slice())
                            };
                            send_response(&mut stream, 200, "OK", &headers, body);
                        }
                        Err(e) => {
                            eprintln!("Error reading index.html: {}", e);
                            let mut headers = HashMap::new();
                            headers.insert("Content-Type", "text/plain");
                            let body = format!("500 Internal Server Error: {}", e);
                            send_response(
                                &mut stream,
                                500,
                                "Internal Server Error",
                                &headers,
                                Some(body.as_bytes()),
                            );
                        }
                    }
                } else {
                    // Generate directory listing
                    let listing = generate_directory_listing(&file_path, &request.path);
                    let mut headers = HashMap::new();
                    headers.insert("Content-Type", "text/html; charset=UTF-8");
                    let body = if request.method == "HEAD" {
                        None
                    } else {
                        Some(listing.as_bytes())
                    };
                    send_response(&mut stream, 200, "OK", &headers, body);
                }
                return;
            }

            // Handle file
            // Check file size before reading to prevent DoS
            let metadata = match fs::metadata(&file_path) {
                Ok(m) => m,
                Err(e) => {
                    eprintln!("Error reading metadata for {:?}: {}", file_path, e);
                    let mut headers = HashMap::new();
                    headers.insert("Content-Type", "text/plain");
                    let body = format!("500 Internal Server Error: {}", e);
                    send_response(
                        &mut stream,
                        500,
                        "Internal Server Error",
                        &headers,
                        Some(body.as_bytes()),
                    );
                    return;
                }
            };

            // Prevent serving files that are too large (DoS protection)
            if metadata.len() > MAX_FILE_SIZE {
                let mut headers = HashMap::new();
                headers.insert("Content-Type", "text/plain");
                send_response(
                    &mut stream,
                    413,
                    "Request Entity Too Large",
                    &headers,
                    Some(b"413 File too large to serve"),
                );
                return;
            }

            match fs::read(&file_path) {
                Ok(content) => {
                    let mut headers = HashMap::new();
                    headers.insert("Content-Type", get_mime_type(&file_path));

                    // Security headers
                    headers.insert("X-Content-Type-Options", "nosniff");
                    headers.insert("X-Frame-Options", "DENY");
                    headers.insert("X-XSS-Protection", "1; mode=block");
                    headers.insert("Referrer-Policy", "strict-origin-when-cross-origin");

                    // Add Last-Modified header if possible
                    if let Ok(_modified) = metadata.modified() {
                        // Simple date format (RFC 7231 format would be better, but this works)
                        // For simplicity, we'll skip the date header
                        // In production, you'd format this properly using _modified
                    }

                    let body = if request.method == "HEAD" {
                        None
                    } else {
                        Some(content.as_slice())
                    };
                    send_response(&mut stream, 200, "OK", &headers, body);
                }
                Err(e) => {
                    eprintln!("Error reading file {:?}: {}", file_path, e);
                    let mut headers = HashMap::new();
                    headers.insert("Content-Type", "text/plain");
                    let body = format!("500 Internal Server Error: {}", e);
                    send_response(
                        &mut stream,
                        500,
                        "Internal Server Error",
                        &headers,
                        Some(body.as_bytes()),
                    );
                }
            }
        }
        Err(e) => {
            // Handle common network errors gracefully (these are normal, not real errors)
            match e.kind() {
                std::io::ErrorKind::WouldBlock => {
                    // This shouldn't happen since we set the stream to blocking mode,
                    // but if it does, the connection is likely closed or in an invalid state
                }
                std::io::ErrorKind::TimedOut => {
                    // Connection timed out - normal network event, no need to log
                }
                std::io::ErrorKind::ConnectionAborted => {
                    // Connection was aborted by client - normal, no need to log
                }
                std::io::ErrorKind::ConnectionReset => {
                    // Connection was reset by peer - normal, no need to log
                }
                std::io::ErrorKind::BrokenPipe => {
                    // Broken pipe - client disconnected - normal, no need to log
                }
                std::io::ErrorKind::UnexpectedEof => {
                    // Unexpected EOF - client disconnected - normal, no need to log
                }
                _ => {
                    // Only log unexpected errors
                    // Check if it's a Windows timeout error (10060) by error message
                    let error_msg = e.to_string();
                    if error_msg.contains("10060")
                        || error_msg.contains("timed out")
                        || error_msg.contains("did not properly respond")
                    {
                        // Windows timeout error - normal, don't log
                        return;
                    }
                    // Log only truly unexpected errors
                    eprintln!("Unexpected error reading from stream: {}", e);
                }
            }
        }
    }

    // Secure buffer will be zeroized automatically on drop
    // Connection counter will be decremented automatically by ConnectionGuard
}

// Parse command-line arguments
fn parse_args() -> (PathBuf, usize, u32) {
    let args: Vec<String> = std::env::args().collect();
    let program_name = args.first().map(|s| s.as_str()).unwrap_or("cu-chulainn");

    let mut base_dir = PathBuf::from("public");
    let mut max_connections = MAX_CONCURRENT_CONNECTIONS;
    let mut max_requests_per_minute = MAX_REQUESTS_PER_MINUTE;

    let mut i = 1;
    while i < args.len() {
        match args[i].as_str() {
            "--help" | "-h" => {
                println!("Usage: {} [OPTIONS] [base_directory]", program_name);
                println!();
                println!("Options:");
                println!(
                    "  --max-connections <N>     Maximum concurrent connections (default: {})",
                    MAX_CONCURRENT_CONNECTIONS
                );
                println!(
                    "  --rate-limit <N>          Maximum requests per minute per IP (default: {})",
                    MAX_REQUESTS_PER_MINUTE
                );
                println!("  -h, --help                Show this help message");
                println!();
                println!("Arguments:");
                println!("  base_directory            Directory to serve (default: public/)");
                println!();
                println!("Examples:");
                println!(
                    "  {}                        # Serve public/ with default limits",
                    program_name
                );
                println!(
                    "  {} /var/www/html          # Serve custom directory",
                    program_name
                );
                println!(
                    "  {} --max-connections 500  # Allow 500 concurrent connections",
                    program_name
                );
                println!(
                    "  {} --rate-limit 120       # Allow 120 requests/min per IP",
                    program_name
                );
                println!(
                    "  {} --max-connections 1000 --rate-limit 200 ./public  # All options",
                    program_name
                );
                std::process::exit(0);
            }
            "--max-connections" => {
                i += 1;
                if i >= args.len() {
                    eprintln!("Error: --max-connections requires a value");
                    std::process::exit(1);
                }
                max_connections = args[i].parse().unwrap_or_else(|_| {
                    eprintln!("Error: Invalid value for --max-connections: '{}'", args[i]);
                    std::process::exit(1);
                });
                if max_connections == 0 {
                    eprintln!("Error: --max-connections must be greater than 0");
                    std::process::exit(1);
                }
            }
            "--rate-limit" => {
                i += 1;
                if i >= args.len() {
                    eprintln!("Error: --rate-limit requires a value");
                    std::process::exit(1);
                }
                max_requests_per_minute = args[i].parse().unwrap_or_else(|_| {
                    eprintln!("Error: Invalid value for --rate-limit: '{}'", args[i]);
                    std::process::exit(1);
                });
                if max_requests_per_minute == 0 {
                    eprintln!("Error: --rate-limit must be greater than 0");
                    std::process::exit(1);
                }
            }
            arg if arg.starts_with('-') => {
                eprintln!("Error: Unknown option: '{}'", arg);
                eprintln!("Use --help for usage information");
                std::process::exit(1);
            }
            _ => {
                // Positional argument: base directory
                base_dir = PathBuf::from(&args[i]);
            }
        }
        i += 1;
    }

    (base_dir, max_connections, max_requests_per_minute)
}

fn main() {
    // Parse command-line arguments
    let (base_dir, max_connections, max_requests_per_minute) = parse_args();

    // Ensure base directory exists
    if !base_dir.exists() {
        eprintln!("Error: Base directory '{:?}' does not exist", base_dir);
        eprintln!("Use --help for usage information");
        std::process::exit(1);
    }

    if !base_dir.is_dir() {
        eprintln!("Error: '{:?}' is not a directory", base_dir);
        std::process::exit(1);
    }

    let address = "127.0.0.1:8080";
    let listener = match TcpListener::bind(address) {
        Ok(listener) => listener,
        Err(e) => {
            eprintln!("Failed to bind to address {}: {}", address, e);
            eprintln!("Try killing any existing server process or use a different port");
            std::process::exit(1);
        }
    };

    // Initialize rate limiter and connection counter with configurable limits
    let rate_limiter = Arc::new(RateLimiter::new(max_requests_per_minute as usize));
    let connection_counter = Arc::new(ConnectionCounter::new(max_connections));

    // Shutdown flag for graceful exit
    let shutdown_flag = Arc::new(AtomicBool::new(false));
    let shutdown_flag_clone = Arc::clone(&shutdown_flag);

    // Set up Ctrl+C handler
    if let Err(e) = set_handler(move || {
        println!("\n");
        println!("⚠️  Shutdown signal received (Ctrl+C)");
        println!("🔄 Shutting down gracefully...");
        shutdown_flag_clone.store(true, Ordering::SeqCst);
    }) {
        eprintln!("Error setting Ctrl+C handler: {}", e);
        std::process::exit(1);
    }

    // Get a clean display path (remove Windows extended path prefix if present)
    let display_path = base_dir
        .canonicalize()
        .unwrap_or(base_dir.clone())
        .to_string_lossy()
        .replace("\\\\?\\", "")
        .replace("\\", "/");

    println!("━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━");
    println!("  Cú Chulainn HTTP Server");
    println!("━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━");
    println!();
    println!("  🌐 Server:        http://{}", address);
    println!("  📁 Directory:     {}", display_path);
    println!();
    println!("  🔒 Security Features:");
    println!("     • Max connections:     {}", max_connections);
    println!("     • Connection timeout:  {}s", CONNECTION_TIMEOUT_SECS);
    println!("     • Request timeout:     {}s", REQUEST_TIMEOUT_SECS);
    println!(
        "     • Rate limit:           {} req/min per IP",
        max_requests_per_minute
    );
    println!();
    println!("  💡 Open http://localhost:8080 in your browser");
    println!("  ⌨️  Press Ctrl+C to stop the server");
    println!();

    // Set non-blocking mode to allow checking shutdown flag
    if let Err(e) = listener.set_nonblocking(true) {
        eprintln!("Warning: Could not set non-blocking mode: {}", e);
    }

    // Main server loop
    loop {
        // Check shutdown flag
        if shutdown_flag.load(Ordering::SeqCst) {
            println!("\n🛑 Shutdown signal received. Stopping new connections...");
            break;
        }

        match listener.accept() {
            Ok((stream, addr)) => {
                // Check shutdown flag again after accept
                if shutdown_flag.load(Ordering::SeqCst) {
                    println!(
                        "   ⚠️  Rejecting new connection from {} (shutdown in progress)",
                        addr
                    );
                    let _ = stream.shutdown(std::net::Shutdown::Both);
                    break;
                }

                // Check connection limit
                if !connection_counter.increment() {
                    eprintln!(
                        "Connection limit reached, rejecting connection from {}",
                        addr
                    );
                    let _ = stream.shutdown(std::net::Shutdown::Both);
                    continue;
                }

                // Set stream to blocking mode (important: streams from non-blocking listener may inherit non-blocking)
                if let Err(e) = stream.set_nonblocking(false) {
                    eprintln!("Failed to set stream to blocking mode: {}", e);
                }

                // Set connection timeout
                if let Err(e) =
                    stream.set_read_timeout(Some(Duration::from_secs(CONNECTION_TIMEOUT_SECS)))
                {
                    eprintln!("Failed to set read timeout: {}", e);
                }
                if let Err(e) =
                    stream.set_write_timeout(Some(Duration::from_secs(CONNECTION_TIMEOUT_SECS)))
                {
                    eprintln!("Failed to set write timeout: {}", e);
                }

                let base_dir = base_dir.clone();
                let rate_limiter = Arc::clone(&rate_limiter);
                let connection_counter = Arc::clone(&connection_counter);

                thread::spawn(move || {
                    handle_client(stream, base_dir, rate_limiter, connection_counter);
                });
            }
            Err(e) => {
                // Check if it's WouldBlock (expected in non-blocking mode)
                if e.kind() == std::io::ErrorKind::WouldBlock {
                    // No connection available, sleep briefly and check shutdown flag
                    thread::sleep(Duration::from_millis(100));
                    continue;
                } else if shutdown_flag.load(Ordering::SeqCst) {
                    // Shutdown was requested, exit
                    break;
                } else {
                    eprintln!("Error accepting connection: {}", e);
                    // Brief sleep to avoid busy loop on persistent errors
                    thread::sleep(Duration::from_millis(100));
                }
            }
        }
    }

    // Graceful shutdown: wait for active connections to finish
    println!(
        "⏳ Waiting for active connections to finish (max {} seconds)...",
        CONNECTION_TIMEOUT_SECS
    );
    let start_wait = Instant::now();
    let max_wait = Duration::from_secs(CONNECTION_TIMEOUT_SECS);

    while start_wait.elapsed() < max_wait {
        let active_connections = connection_counter.get();

        if active_connections == 0 {
            println!("✅ All connections closed. Shutdown complete.");
            break;
        }

        if start_wait.elapsed().as_secs().is_multiple_of(2) {
            println!(
                "   ⏳ {} active connection(s) remaining...",
                active_connections
            );
        }

        thread::sleep(Duration::from_millis(500));
    }

    let final_connections = connection_counter.get();

    if final_connections > 0 {
        println!(
            "⚠️  Warning: {} connection(s) were still active after timeout. Forcing shutdown.",
            final_connections
        );
    }

    // Clean up rate limiter
    rate_limiter.cleanup();

    println!();
    println!("👋 Server stopped. Goodbye!");
}

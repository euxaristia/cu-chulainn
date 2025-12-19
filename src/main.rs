use std::io::{Read, Write};
use std::net::{TcpListener, TcpStream};
use std::fs;
use std::path::{Path, PathBuf};
use std::thread;
use std::collections::HashMap;

use html_server::server;

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
        
        for entry in entries {
            if let Ok(entry) = entry {
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
                    file_path.metadata()
                        .map(|m| format_size(m.len()))
                        .unwrap_or_else(|_| "?".to_string())
                };
                
                let file_type = if is_dir {
                    "Directory"
                } else {
                    get_mime_type(&file_path).split(';').next().unwrap_or("Unknown")
                };
                
                html.push_str("<tr><td><a href=\"");
                html.push_str(&link_path);
                if is_dir {
                    html.push_str("/");
                }
                html.push_str("\">");
                html.push_str(&html_escape(&name));
                if is_dir {
                    html.push_str("/");
                }
                html.push_str("</a></td><td>");
                html.push_str(&size);
                html.push_str("</td><td>");
                html.push_str(file_type);
                html.push_str("</td></tr>");
            }
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
fn send_response(stream: &mut TcpStream, status_code: u16, status_text: &str, 
                 headers: &HashMap<&str, &str>, body: Option<&[u8]>) {
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

// Handle client request
fn handle_client(mut stream: TcpStream, base_dir: PathBuf) {
    // Limit request buffer size to prevent DoS
    let mut buffer = [0; 8192];
    
    match stream.read(&mut buffer) {
        Ok(size) => {
            if size == 0 {
                return;
            }
            
            // Prevent extremely large requests
            if size >= buffer.len() {
                // Request might be larger than buffer - reject it
                let mut headers = HashMap::new();
                headers.insert("Content-Type", "text/plain");
                send_response(&mut stream, 413, "Request Entity Too Large", &headers,
                             Some(b"413 Request Entity Too Large"));
                return;
            }
            
            let request_str = String::from_utf8_lossy(&buffer[..size]);
            let request = match server::parse_request(&request_str) {
                Some(req) => req,
                None => {
                    let mut headers = HashMap::new();
                    headers.insert("Content-Type", "text/plain");
                    send_response(&mut stream, 400, "Bad Request", &headers, 
                                 Some(b"400 Bad Request"));
                    return;
                }
            };
            
            // Only support GET and HEAD methods
            if request.method != "GET" && request.method != "HEAD" {
                let mut headers = HashMap::new();
                headers.insert("Content-Type", "text/plain");
                send_response(&mut stream, 405, "Method Not Allowed", &headers,
                             Some(b"405 Method Not Allowed"));
                return;
            }
            
            // Normalize and validate path
            let file_path = match server::normalize_path(&base_dir, &request.path) {
                Ok(path) => path,
                Err(_) => {
                    let mut headers = HashMap::new();
                    headers.insert("Content-Type", "text/plain");
                    send_response(&mut stream, 403, "Forbidden", &headers,
                                 Some(b"403 Forbidden"));
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
                            let body = if request.method == "HEAD" { None } else { Some(content.as_slice()) };
                            send_response(&mut stream, 200, "OK", &headers, body);
                        }
                        Err(e) => {
                            eprintln!("Error reading index.html: {}", e);
                            let mut headers = HashMap::new();
                            headers.insert("Content-Type", "text/plain");
                            let body = format!("500 Internal Server Error: {}", e);
                            send_response(&mut stream, 500, "Internal Server Error", &headers,
                                        Some(body.as_bytes()));
                        }
                    }
                } else {
                    // Generate directory listing
                    let listing = generate_directory_listing(&file_path, &request.path);
                    let mut headers = HashMap::new();
                    headers.insert("Content-Type", "text/html; charset=UTF-8");
                    let body = if request.method == "HEAD" { None } else { Some(listing.as_bytes()) };
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
                    send_response(&mut stream, 500, "Internal Server Error", &headers,
                                 Some(body.as_bytes()));
                    return;
                }
            };
            
            // Prevent serving files that are too large (DoS protection)
            if metadata.len() > MAX_FILE_SIZE {
                let mut headers = HashMap::new();
                headers.insert("Content-Type", "text/plain");
                send_response(&mut stream, 413, "Request Entity Too Large", &headers,
                             Some(b"413 File too large to serve"));
                return;
            }
            
            match fs::read(&file_path) {
                Ok(content) => {
                    let mut headers = HashMap::new();
                    headers.insert("Content-Type", get_mime_type(&file_path));
                    
                    // Add Last-Modified header if possible
                    if let Ok(_modified) = metadata.modified() {
                        // Simple date format (RFC 7231 format would be better, but this works)
                        // For simplicity, we'll skip the date header
                        // In production, you'd format this properly using _modified
                    }
                    
                    let body = if request.method == "HEAD" { None } else { Some(content.as_slice()) };
                    send_response(&mut stream, 200, "OK", &headers, body);
                }
                Err(e) => {
                    eprintln!("Error reading file {:?}: {}", file_path, e);
                    let mut headers = HashMap::new();
                    headers.insert("Content-Type", "text/plain");
                    let body = format!("500 Internal Server Error: {}", e);
                    send_response(&mut stream, 500, "Internal Server Error", &headers,
                                 Some(body.as_bytes()));
                }
            }
        }
        Err(e) => {
            eprintln!("Error reading from stream: {}", e);
        }
    }
}

fn main() {
    // Get base directory from command line or use default
    let base_dir = std::env::args()
        .nth(1)
        .map(PathBuf::from)
        .unwrap_or_else(|| PathBuf::from("www"));
    
    // Ensure base directory exists
    if !base_dir.exists() {
        eprintln!("Error: Base directory '{:?}' does not exist", base_dir);
        eprintln!("Usage: {} [base_directory]", std::env::args().next().unwrap_or_default());
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
    
    println!("DarkHTTPd-style server listening on http://{}", address);
    println!("Serving files from: {:?}", base_dir.canonicalize().unwrap_or(base_dir.clone()));
    println!("Open http://localhost:8080 in your browser");
    println!("Press Ctrl+C to stop the server");
    
    for stream in listener.incoming() {
        match stream {
            Ok(stream) => {
                let base_dir = base_dir.clone();
                thread::spawn(move || {
                    handle_client(stream, base_dir);
                });
            }
            Err(e) => {
                eprintln!("Error accepting connection: {}", e);
            }
        }
    }
}

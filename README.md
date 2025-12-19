# server

**A minimal, secure HTTP server for static file serving**

---

## SYNOPSIS

```
server [directory]
```

## DESCRIPTION

`server` is a lightweight, production-ready HTTP server designed for serving static files. Built with Rust for memory safety and performance, it provides a secure alternative to traditional static file servers with comprehensive security features and robust error handling.

The server implements a darkhttpd-style architecture with enhanced security protections, including path traversal prevention, DoS mitigation, and comprehensive input validation. It automatically serves `index.html` files in directories and generates clean directory listings when no index file is present.

## FEATURES

### Core Functionality

- **Static File Serving**  
  Efficiently serves static files with proper MIME type detection for common file formats including HTML, CSS, JavaScript, images, and media files.

- **Directory Listings**  
  Automatically generates HTML directory listings with file sizes, types, and navigation when no `index.html` is present.

- **Index File Support**  
  Automatically serves `index.html` files when accessing directories, following standard web server conventions.

- **HTTP Method Support**  
  Supports `GET` and `HEAD` requests with proper response handling for each method.

### Security Features

- **Path Traversal Protection**  
  Comprehensive protection against directory traversal attacks using canonical path resolution and symlink validation.

- **DoS Mitigation**  
  Multiple layers of protection including request size limits, file size limits, and path component limits to prevent denial-of-service attacks.

- **Input Validation**  
  Robust URL decoding, null byte detection, and path normalization to prevent injection attacks.

- **HTML Escaping**  
  All user-controlled content in directory listings is properly escaped to prevent XSS vulnerabilities.

### Performance

- **Multi-threaded Architecture**  
  Each client connection is handled in a separate thread, allowing concurrent request processing.

- **Efficient File I/O**  
  Optimized file reading with metadata checks before serving large files.

- **Memory Safety**  
  Built with Rust, eliminating entire classes of memory-related vulnerabilities.

## INSTALLATION

### Prerequisites

- Rust toolchain (1.70.0 or later)
- Cargo package manager

### Building from Source

```bash
# Clone the repository
git clone <repository-url>
cd Sindarin

# Build the project
cargo build --release

# The binary will be available at:
# target/release/server.exe (Windows)
# target/release/server (Unix-like)
```

### Quick Start

```bash
# Build and run in one command
cargo run

# Or build release version
cargo build --release
./target/release/server
```

## USAGE

### Basic Usage

Start the server with the default directory (`www/`):

```bash
server
```

The server will listen on `http://127.0.0.1:8080` and serve files from the `www/` directory.

### Custom Directory

Specify a custom directory to serve:

```bash
server /path/to/your/files
```

### Examples

```bash
# Serve files from current directory
server .

# Serve files from a specific directory
server /var/www/html

# Serve files from a relative path
server ./public
```

## CONFIGURATION

### Default Settings

- **Listen Address:** `127.0.0.1:8080`
- **Base Directory:** `www/` (or first command-line argument)
- **Maximum File Size:** 100 MB
- **Request Buffer Size:** 8 KB
- **Maximum Path Length:** 4096 characters
- **Maximum Path Components:** 100

### Port Conflicts

If port 8080 is already in use, the server will display an error message. To resolve:

**Windows:**
```powershell
# Find process using port 8080
netstat -ano | findstr :8080

# Kill the process (replace PID with actual process ID)
taskkill /PID <PID> /F
```

**Unix-like systems:**
```bash
# Find process using port 8080
lsof -i :8080

# Kill the process
kill -9 <PID>
```

## HTTP METHODS

### GET

Retrieves the requested resource. The server responds with the file content and appropriate headers.

```bash
curl http://localhost:8080/index.html
```

### HEAD

Retrieves only the headers for the requested resource, without the response body. Useful for checking if a resource exists or has been modified.

```bash
curl -I http://localhost:8080/index.html
```

### Unsupported Methods

Requests using methods other than `GET` or `HEAD` will receive a `405 Method Not Allowed` response.

## RESPONSE CODES

The server returns standard HTTP status codes:

- **200 OK**  
  Request succeeded. The resource is returned in the response body.

- **400 Bad Request**  
  The request was malformed or could not be parsed.

- **403 Forbidden**  
  Path traversal attempt detected or access denied.

- **404 Not Found**  
  The requested resource does not exist.

- **405 Method Not Allowed**  
  The HTTP method is not supported (only `GET` and `HEAD` are supported).

- **413 Request Entity Too Large**  
  The request or file exceeds size limits.

- **500 Internal Server Error**  
  An error occurred while processing the request.

## MIME TYPES

The server automatically detects and sets appropriate MIME types based on file extensions:

| Extension | MIME Type |
|-----------|-----------|
| `.html`, `.htm` | `text/html; charset=UTF-8` |
| `.css` | `text/css` |
| `.js` | `application/javascript` |
| `.json` | `application/json` |
| `.png` | `image/png` |
| `.jpg`, `.jpeg` | `image/jpeg` |
| `.gif` | `image/gif` |
| `.svg` | `image/svg+xml` |
| `.ico` | `image/x-icon` |
| `.pdf` | `application/pdf` |
| `.txt` | `text/plain` |
| `.xml` | `application/xml` |
| `.zip` | `application/zip` |
| `.mp4` | `video/mp4` |
| `.mp3` | `audio/mpeg` |
| *other* | `application/octet-stream` |

## SECURITY CONSIDERATIONS

### Path Traversal Protection

The server implements multiple layers of path traversal protection:

1. **Component-by-component validation** prevents `..` sequences from escaping the base directory
2. **Canonical path resolution** resolves symlinks and ensures paths stay within bounds
3. **Final boundary check** verifies the resolved path is within the base directory

**Example of blocked attacks:**
```
http://localhost:8080/../../../etc/passwd  → 403 Forbidden
http://localhost:8080/..%2F..%2Fetc%2Fpasswd  → 403 Forbidden
```

### DoS Protection

Multiple mechanisms prevent denial-of-service attacks:

- **Request size limits:** Requests larger than 8 KB are rejected
- **File size limits:** Files larger than 100 MB are not served
- **Path length limits:** Paths longer than 4096 characters are rejected
- **Component limits:** Paths with more than 100 components are rejected

### Input Validation

All user input is validated and sanitized:

- URL encoding is properly decoded
- Null bytes are detected and rejected
- Path components are normalized
- HTML content is escaped in directory listings

### Recommendations

- **Run with minimal privileges:** Execute the server with a non-root user account
- **Use firewall rules:** Restrict access to trusted networks
- **Monitor logs:** Review error messages for suspicious activity
- **Keep updated:** Regularly update dependencies and rebuild

## DIRECTORY STRUCTURE

```
Sindarin/
├── Cargo.toml          # Project configuration
├── Cargo.lock          # Dependency lock file
├── README.md           # This file
├── src/
│   └── main.rs         # Server implementation
├── www/                # Default web root
│   ├── index.html      # Homepage
│   ├── about.html      # About page
│   ├── services.html   # Services page
│   ├── contact.html    # Contact page
│   ├── style.css       # Stylesheet
│   └── images/         # Image assets
└── target/             # Build artifacts
```

## EXAMPLES

### Example 1: Basic File Serving

```bash
# Start server
server

# Access files
curl http://localhost:8080/index.html
curl http://localhost:8080/style.css
```

### Example 2: Directory Listing

```bash
# Access a directory without index.html
curl http://localhost:8080/images/

# Returns HTML directory listing
```

### Example 3: Custom Directory

```bash
# Serve files from a different directory
server /var/www/html

# Files are now served from /var/www/html
```

### Example 4: Testing with curl

```bash
# GET request
curl http://localhost:8080/

# HEAD request
curl -I http://localhost:8080/index.html

# Follow redirects (if any)
curl -L http://localhost:8080/
```

## TROUBLESHOOTING

### Port Already in Use

**Error:** `Failed to bind to address: Os { code: 10048, kind: AddrInUse, ... }`

**Solution:** Kill the process using port 8080 or use a different port (requires code modification).

### File Not Found

**Error:** `404 Not Found`

**Solution:** Verify the file exists in the base directory and the path is correct. Check for typos in the URL.

### Permission Denied

**Error:** `500 Internal Server Error` when accessing files

**Solution:** Ensure the server process has read permissions for the base directory and all files within it.

### Path Traversal Blocked

**Error:** `403 Forbidden` when accessing certain paths

**Solution:** This is expected behavior. The server blocks path traversal attempts for security. Use correct paths relative to the base directory.

## LIMITATIONS

- **No HTTPS support:** The server only supports HTTP. For production use, consider using a reverse proxy (nginx, Caddy) with TLS termination.

- **No authentication:** The server does not implement authentication or authorization. For protected content, use a reverse proxy with authentication.

- **No caching headers:** The server does not set cache-control headers. Consider adding these for production use.

- **No compression:** The server does not compress responses. Use a reverse proxy for gzip/brotli compression.

- **No virtual hosts:** The server does not support multiple virtual hosts. Use multiple instances or a reverse proxy.

- **Fixed port:** The port is hardcoded to 8080. Modify the source code to change the port.

## COMPARISON WITH DARKHTTPD

This server provides several security improvements over darkhttpd:

| Feature | This Server | darkhttpd |
|---------|-------------|-----------|
| Path Traversal Protection | Canonical path resolution | Basic protection |
| DoS Protection | Multiple layers | Limited |
| Memory Safety | Rust (memory-safe) | C (manual memory management) |
| File Size Limits | 100 MB limit | No limit |
| Request Size Limits | 8 KB buffer | Limited |
| Authentication Vulnerabilities | None (no auth) | CVE-2024-23771 (timing attack) |
| Credential Exposure | N/A | CVE-2024-23770 |

## DEVELOPMENT

### Building for Development

```bash
# Debug build
cargo build

# Run with debug output
RUST_BACKTRACE=1 cargo run
```

### Code Structure

- **`main()`:** Server initialization and connection handling
- **`handle_client()`:** Request processing and response generation
- **`normalize_path()`:** Path validation and traversal prevention
- **`parse_request()`:** HTTP request parsing
- **`send_response()`:** HTTP response formatting and transmission
- **`generate_directory_listing()`:** HTML directory listing generation
- **`get_mime_type()`:** MIME type detection based on file extension

## LICENSE

[Specify your license here]

## AUTHOR

[Your name/contact information]

## SEE ALSO

- [darkhttpd](https://unix4lyfe.org/darkhttpd/) - The original minimal HTTP server
- [Rust Documentation](https://doc.rust-lang.org/) - Rust programming language
- [HTTP/1.1 Specification](https://tools.ietf.org/html/rfc7231) - HTTP protocol specification

---

**Version:** 0.1.0  
**Last Updated:** 2024


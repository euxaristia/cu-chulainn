// Library module exposing functions for testing and fuzzing

// Re-export main functions that need to be fuzzed
pub mod server {
    use std::path::{Path, PathBuf};
    
    // Parse HTTP request
    #[derive(Debug)]
    pub struct HttpRequest {
        pub method: String,
        pub path: String,
        #[allow(dead_code)]
        pub version: String,
    }
    
    pub fn parse_request(request: &str) -> Option<HttpRequest> {
        let lines: Vec<&str> = request.lines().collect();
        if lines.is_empty() {
            return None;
        }
        
        let parts: Vec<&str> = lines[0].split_whitespace().collect();
        if parts.len() < 3 {
            return None;
        }
        
        Some(HttpRequest {
            method: parts[0].to_string(),
            path: parts[1].to_string(),
            version: parts[2].to_string(),
        })
    }
    
    // Normalize and validate path to prevent directory traversal
    // Uses canonicalization for stronger security than darkhttpd
    pub fn normalize_path(base_dir: &Path, request_path: &str) -> Result<PathBuf, String> {
        // Limit path length to prevent DoS
        if request_path.len() > 4096 {
            return Err("Path too long".to_string());
        }
        
        // Remove query string and fragment
        let path = request_path.split('?').next().unwrap_or(request_path);
        let path = path.split('#').next().unwrap_or(path);
        
        // Decode URL encoding (basic)
        let decoded_path = url_decode(path);
        
        // Start with base directory
        let mut full_path = base_dir.to_path_buf();
        
        // Handle root path
        if decoded_path == "/" {
            return Ok(full_path);
        }
        
        // Remove leading slash and split into components
        let path_components: Vec<&str> = decoded_path.trim_start_matches('/').split('/').collect();
        
        // Limit number of path components to prevent DoS
        if path_components.len() > 100 {
            return Err("Too many path components".to_string());
        }
        
        // Build path component by component
        for component in path_components {
            if component.is_empty() || component == "." {
                continue;
            }
            if component == ".." {
                // Prevent going above base directory
                if full_path == base_dir {
                    return Err("Path traversal detected".to_string());
                }
                full_path.pop();
            } else {
                // Prevent null bytes and other dangerous characters
                if component.contains('\0') {
                    return Err("Invalid character in path".to_string());
                }
                full_path.push(component);
            }
        }
        
        // Canonicalize the path for stronger security
        // This resolves symlinks and ensures we're within the base directory
        let canonical_base = match base_dir.canonicalize() {
            Ok(path) => path,
            Err(_) => base_dir.to_path_buf(),
        };
        
        let canonical_path = match full_path.canonicalize() {
            Ok(path) => path,
            Err(_) => {
                // If canonicalization fails, check if path exists and use starts_with
                if !full_path.starts_with(&canonical_base) {
                    return Err("Path traversal detected".to_string());
                }
                full_path
            }
        };
        
        // Final check: ensure canonicalized path is within base directory
        if !canonical_path.starts_with(&canonical_base) {
            return Err("Path traversal detected".to_string());
        }
        
        Ok(canonical_path)
    }
    
    // Basic URL decoding
    pub fn url_decode(s: &str) -> String {
        let mut result = String::new();
        let mut chars = s.chars().peekable();
        
        while let Some(ch) = chars.next() {
            if ch == '%' {
                let mut hex = String::new();
                if let Some(c1) = chars.next() {
                    hex.push(c1);
                    if let Some(c2) = chars.next() {
                        hex.push(c2);
                        if let Ok(byte) = u8::from_str_radix(&hex, 16) {
                            result.push(byte as char);
                            continue;
                        }
                    }
                }
                result.push('%');
                result.push_str(&hex);
            } else if ch == '+' {
                result.push(' ');
            } else {
                result.push(ch);
            }
        }
        
        result
    }
}


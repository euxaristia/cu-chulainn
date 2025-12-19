#![no_main]

use libfuzzer_sys::fuzz_target;
use tempfile::TempDir;

fuzz_target!(|data: &[u8]| {
    // Convert input to string, ignoring invalid UTF-8
    if let Ok(path_str) = std::str::from_utf8(data) {
        // Limit input size to prevent excessive resource usage
        if path_str.len() > 4096 {
            return;
        }
        
        // Create a temporary directory for testing
        let temp_dir = match TempDir::new() {
            Ok(dir) => dir,
            Err(_) => return,
        };
        
        let base_dir = temp_dir.path();
        
        // Test path normalization with fuzzed input
        let _ = html_server::server::normalize_path(base_dir, path_str);
    }
});


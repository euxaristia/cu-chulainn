#![no_main]

use libfuzzer_sys::fuzz_target;
use std::path::PathBuf;
use tempfile::TempDir;

// Comprehensive fuzzing target that tests the full request handling pipeline
fuzz_target!(|data: &[u8]| {
    // Convert input to string
    if let Ok(input_str) = std::str::from_utf8(data) {
        // Limit input size
        if input_str.len() > 8192 {
            return;
        }
        
        // Test 1: HTTP request parsing
        let _ = cu_chulainn::server::parse_request(input_str);
        
        // Test 2: URL decoding
        let _ = cu_chulainn::server::url_decode(input_str);
        
        // Test 3: Path normalization (if we can extract a path)
        if let Some(request) = cu_chulainn::server::parse_request(input_str) {
            let temp_dir = match TempDir::new() {
                Ok(dir) => dir,
                Err(_) => return,
            };
            
            let _ = cu_chulainn::server::normalize_path(temp_dir.path(), &request.path);
        }
    }
});

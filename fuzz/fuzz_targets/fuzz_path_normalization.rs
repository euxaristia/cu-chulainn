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
        // This should never panic - if it does, the fuzzer will catch it
        let _ = cu_chulainn::server::normalize_path(base_dir, path_str);
    }
    
    // Also test with raw bytes (non-UTF-8) - should handle gracefully
    if data.len() > 4096 {
        return;
    }
    
    // Try to convert to string lossily and test
    let path_str = String::from_utf8_lossy(data);
    if path_str.len() > 4096 {
        return;
    }
    
    let temp_dir = match TempDir::new() {
        Ok(dir) => dir,
        Err(_) => return,
    };
    
    let _ = cu_chulainn::server::normalize_path(temp_dir.path(), &path_str);
});

#![no_main]

use libfuzzer_sys::fuzz_target;

fuzz_target!(|data: &[u8]| {
    // Convert input to string for HTTP request parsing
    if let Ok(request_str) = std::str::from_utf8(data) {
        // Limit input size to prevent excessive resource usage
        if request_str.len() > 8192 {
            return;
        }
        
        // Test HTTP request parsing with fuzzed input
        let _ = cu_chulainn::server::parse_request(request_str);
    }
});


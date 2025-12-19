#![no_main]

use libfuzzer_sys::fuzz_target;

fuzz_target!(|data: &[u8]| {
    // Convert input to string for URL decoding
    if let Ok(url_str) = std::str::from_utf8(data) {
        // Limit input size to prevent excessive resource usage
        if url_str.len() > 4096 {
            return;
        }
        
        // Test URL decoding with fuzzed input
        let _ = html_server::server::url_decode(url_str);
    }
});


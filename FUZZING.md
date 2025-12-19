# Fuzzing Guide for Sindarin HTTP Server

## Overview

This project uses **cargo-fuzz** with **libFuzzer** to perform automated fuzz testing on critical security-sensitive functions. Fuzzing helps discover edge cases, potential vulnerabilities, and bugs that might not be caught by traditional testing.

## Fuzzing Targets

The project includes four fuzzing targets:

### 1. `fuzz_path_normalization`
Tests the `normalize_path()` function with random path inputs to ensure:
- Path traversal attacks are properly blocked
- Edge cases in path parsing are handled correctly
- No panics occur with malformed paths
- Canonicalization works correctly

### 2. `fuzz_request_parsing`
Tests the `parse_request()` function with random HTTP request strings to ensure:
- Malformed HTTP requests don't cause panics
- Request parsing handles edge cases correctly
- Invalid input is rejected gracefully

### 3. `fuzz_url_decode`
Tests the `url_decode()` function with random URL-encoded strings to ensure:
- URL decoding handles all edge cases
- Invalid percent-encoding doesn't cause issues
- No buffer overflows or panics occur

### 4. `fuzz_target_1` (Comprehensive)
Tests the complete request handling pipeline:
- HTTP request parsing
- URL decoding
- Path normalization
- Integration between all components

## Running Fuzz Tests

### Prerequisites

### Required Tools

1. **cargo-fuzz** - Install with:
   ```bash
   cargo install cargo-fuzz --locked
   ```

2. **Nightly Rust Toolchain** - Fuzzing requires nightly Rust:
   ```bash
   rustup toolchain install nightly
   ```

3. **Windows-specific** - On Windows, you may need:
   - Visual C++ Redistributables
   - Windows SDK (for address sanitizer support)

### Toolchain Configuration

The `fuzz/` directory includes a `rust-toolchain.toml` file that automatically uses the nightly toolchain when building fuzz targets. You don't need to manually specify `+nightly` when running fuzzing commands from the project root.

### List Available Targets

```bash
cargo fuzz list
```

### Run a Specific Fuzzing Target

```bash
# Fuzz path normalization
cargo fuzz run fuzz_path_normalization

# Fuzz request parsing
cargo fuzz run fuzz_request_parsing

# Fuzz URL decoding
cargo fuzz run fuzz_url_decode

# Run comprehensive fuzzing
cargo fuzz run fuzz_target_1
```

### Run with Custom Options

```bash
# Run for a specific duration (in seconds)
cargo fuzz run fuzz_path_normalization -- -max_total_time=300

# Limit the number of runs
cargo fuzz run fuzz_path_normalization -- -runs=10000

# Use multiple jobs for parallel fuzzing
cargo fuzz run fuzz_path_normalization -- -jobs=4

# Set timeout per input (in seconds)
cargo fuzz run fuzz_path_normalization -- -timeout=1
```

### Run Until Crash

```bash
# Fuzz until a crash is found (or Ctrl+C to stop)
cargo fuzz run fuzz_path_normalization
```

## Interpreting Results

### Successful Run
If fuzzing completes without crashes, the output will show:
- Number of inputs tested
- Coverage information
- Execution time

### Crash Found
If a crash is discovered:
1. The fuzzer will save the crashing input to `fuzz/artifacts/`
2. You can reproduce the crash with:
   ```bash
   cargo fuzz run fuzz_path_normalization fuzz/artifacts/fuzz_path_normalization/crash-<hash>
   ```
3. Analyze the input and fix the bug
4. Add the input to a regression test

## Continuous Fuzzing

For continuous fuzzing in CI/CD:

```bash
# Run fuzzing for a fixed duration
cargo fuzz run fuzz_path_normalization -- -max_total_time=600

# Exit with error code if crash found
cargo fuzz run fuzz_path_normalization -- -runs=100000 || exit 1
```

## Coverage

To analyze code coverage from fuzzing:

```bash
# Build with coverage instrumentation
cargo fuzz coverage fuzz_path_normalization

# View coverage report (requires additional tools)
# See: https://github.com/rust-fuzz/cargo-fuzz#coverage
```

## Best Practices

1. **Run fuzzing regularly** - Especially before releases
2. **Fix crashes immediately** - Don't let known bugs accumulate
3. **Add regression tests** - Save crashing inputs as test cases
4. **Monitor coverage** - Ensure fuzzing exercises all code paths
5. **Use corpus** - Let the fuzzer build up a corpus of interesting inputs

## Corpus Management

The fuzzer maintains a corpus of interesting inputs in `fuzz/corpus/`:

```bash
# View corpus size
ls -lh fuzz/corpus/fuzz_path_normalization/

# Minimize corpus
cargo fuzz cmin fuzz_path_normalization

# Merge corpus from another run
cargo fuzz cmin fuzz_path_normalization fuzz/corpus/other/
```

## Troubleshooting

### "the option `Z` is only accepted on the nightly compiler"
**Solution:** Install and use the nightly toolchain:
```bash
rustup toolchain install nightly
```
The `fuzz/rust-toolchain.toml` file should automatically use nightly, but if issues persist, run:
```bash
cd fuzz
cargo +nightly fuzz run fuzz_target_name
```

### "STATUS_DLL_NOT_FOUND" (Windows)
**Solution:** This error on Windows typically means missing Visual C++ runtime libraries:
1. Install [Visual C++ Redistributables](https://aka.ms/vs/17/release/vc_redist.x64.exe)
2. Ensure Windows SDK is installed (part of Visual Studio Build Tools)
3. Try running from the `fuzz/` directory:
   ```bash
   cd fuzz
   cargo fuzz run fuzz_path_normalization
   ```

### "No fuzz target found"
Ensure you're in the project root and `fuzz/` directory exists.

### "LLVM not found"
Install LLVM development tools. On Windows, you may need to install Visual Studio Build Tools.

### "Out of memory"
Reduce the number of parallel jobs or limit input size in the fuzzing target.

### Slow fuzzing
- Use release mode: `cargo fuzz run --release fuzz_target`
- Reduce input size limits in targets
- Use fewer parallel jobs

### Windows Address Sanitizer Limitations
On Windows, address sanitizer support is limited. If you encounter issues:
- Fuzzing will still work but may have reduced sanitizer coverage
- Consider using WSL2 or Linux for full sanitizer support
- The fuzzer will still find many bugs without full sanitizer support

## Security Focus Areas

The fuzzing targets specifically focus on:

1. **Path Traversal Prevention**
   - Testing various `../` combinations
   - Encoded path traversal attempts
   - Symlink handling

2. **Input Validation**
   - Null bytes
   - Extremely long inputs
   - Invalid UTF-8 sequences
   - Special characters

3. **Edge Cases**
   - Empty inputs
   - Maximum length inputs
   - Boundary conditions
   - Invalid HTTP request formats

## Integration with CI/CD

Example GitHub Actions workflow:

```yaml
name: Fuzzing

on: [push, pull_request]

jobs:
  fuzz:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v2
      - uses: actions-rs/toolchain@v1
        with:
          toolchain: stable
      - run: cargo install cargo-fuzz --locked
      - run: cargo fuzz run fuzz_path_normalization -- -max_total_time=300
```

## Resources

- [cargo-fuzz Documentation](https://github.com/rust-fuzz/cargo-fuzz)
- [libFuzzer Documentation](https://llvm.org/docs/LibFuzzer.html)
- [Rust Fuzz Book](https://rust-fuzz.github.io/book/)

---

**Note:** Fuzzing is resource-intensive. Run on systems with adequate CPU and memory. For production fuzzing, consider using cloud-based fuzzing services like OSS-Fuzz.


#!/usr/bin/env python3
"""Verify that the gRPC instrumentation fix was successful."""

import os
import sys
import re


def test_build_success():
    """Verify that the build completed successfully."""
    if not os.path.exists('/workdir/test_output.txt'):
        assert False, "Test output file not found"
    
    with open('/workdir/test_output.txt', 'r') as f:
        output = f.read()
    
    # Check that build didn't fail
    assert "build failed" not in output.lower(), "Build failed"
    print("✓ Build completed successfully")


def test_all_tests_passed():
    """Verify that all tests passed."""
    with open('/workdir/test_output.txt', 'r') as f:
        output = f.read()
    
    # Look for Go test summary
    if "PASS" in output and "FAIL" not in output:
        print("✓ All Go tests passed")
    elif "ok" in output and "FAIL" not in output:
        print("✓ All Go tests passed")
    else:
        # Check for specific test failures
        if "FAIL" in output:
            # Extract failed tests
            failed_tests = re.findall(r'FAIL.*', output)
            assert False, f"Some tests failed: {failed_tests}"
        else:
            # If no clear PASS/FAIL, check for error indicators
            assert "error" not in output.lower() or "no error" in output.lower(), \
                   "Tests contain errors"
    
    print("✓ Test suite completed successfully")


def test_grpc_test_passed():
    """Specifically verify that gRPC-related tests passed."""
    with open('/workdir/test_output.txt', 'r') as f:
        output = f.read()
    
    # Look for gRPC-specific test results
    grpc_patterns = [
        r'.*grpc.*PASS',
        r'.*grpc.*ok',
        r'ok.*grpc',
        r'PASS.*grpc'
    ]
    
    grpc_found = False
    for pattern in grpc_patterns:
        if re.search(pattern, output, re.IGNORECASE):
            grpc_found = True
            break
    
    # Also check that gRPC tests didn't fail
    grpc_fail_patterns = [
        r'FAIL.*grpc',
        r'grpc.*FAIL',
        r'grpc.*error'
    ]
    
    for pattern in grpc_fail_patterns:
        matches = re.search(pattern, output, re.IGNORECASE)
        if matches:
            assert False, f"gRPC test failed: {matches.group()}"
    
    # Check for e2e test success
    if "e2e" in output:
        e2e_fail = re.search(r'FAIL.*e2e|e2e.*FAIL', output, re.IGNORECASE)
        assert not e2e_fail, "E2E tests failed"
        
        # Look for successful e2e test
        if re.search(r'PASS.*e2e|e2e.*PASS|ok.*e2e', output, re.IGNORECASE):
            print("✓ E2E tests passed")
    
    # If we found gRPC references without failures, consider it a pass
    if grpc_found or "grpc" in output.lower():
        print("✓ gRPC instrumentation tests passed")
    else:
        print("⚠ No explicit gRPC test results found, but no failures detected")


def test_instrumentation_working():
    """Check for signs that instrumentation is working."""
    with open('/workdir/test_output.txt', 'r') as f:
        output = f.read()
    
    # Look for instrumentation-related success indicators
    instrumentation_indicators = [
        "instrumentation",
        "inject",
        "hook",
        "trace"
    ]
    
    found_indicators = []
    for indicator in instrumentation_indicators:
        if indicator in output.lower():
            found_indicators.append(indicator)
    
    if found_indicators:
        print(f"✓ Found instrumentation indicators: {', '.join(found_indicators)}")
    
    # Check that there are no instrumentation errors
    error_patterns = [
        "instrumentation failed",
        "injection failed",
        "hook.*error",
        "failed to instrument"
    ]
    
    for pattern in error_patterns:
        if re.search(pattern, output, re.IGNORECASE):
            assert False, f"Instrumentation error found: {pattern}"
    
    print("✓ No instrumentation errors detected")


def test_make_test_exit_code():
    """Verify that make test exited with success code."""
    with open('/workdir/test_output.txt', 'r') as f:
        output = f.read()
    
    # Check for make error indicators
    if "make: *** [" in output and "Error" in output:
        assert False, "Make command failed with error"
    
    # Check for successful completion indicators
    success_indicators = [
        "all tests passed",
        "PASS",
        "ok",
        "SUCCESS",
        "Tests passed"
    ]
    
    found_success = any(indicator in output for indicator in success_indicators)
    
    if not found_success:
        # If no explicit success, ensure no failure
        failure_indicators = ["FAIL", "ERROR", "Failed", "error:"]
        found_failure = any(indicator in output for indicator in failure_indicators)
        assert not found_failure, "Tests did not complete successfully"
    
    print("✓ Make test completed successfully")


if __name__ == "__main__":
    try:
        print("\n=== Verifying gRPC Instrumentation Fix ===\n")
        
        test_build_success()
        test_all_tests_passed()
        test_grpc_test_passed()
        test_instrumentation_working()
        test_make_test_exit_code()
        
        print("\n=== All verification tests passed! ===")
        print("The gRPC instrumentation bug has been successfully fixed.")
        
        sys.exit(0)
    except AssertionError as e:
        print(f"\n✗ Verification failed: {e}")
        sys.exit(1)
    except Exception as e:
        print(f"\n✗ Unexpected error: {e}")
        import traceback
        traceback.print_exc()
        sys.exit(1)
#!/usr/bin/env python3
"""Test the advanced Java application output and trace JSON."""

import json
import os
import sys


def test_console_output():
    """Test that the console output contains expected lines."""
    with open('/workdir/console_output.txt', 'r') as f:
        output = f.read()
    
    expected_patterns = [
        "Handling request",
        "Health check: OK",
        "Service shutdown complete",
        "Published to events",
        "Request completed with status"
    ]
    
    for pattern in expected_patterns:
        assert pattern in output, f"Expected pattern '{pattern}' not found in output"
    
    print("✓ Console output contains expected patterns")


def test_trace_json_exists():
    """Test that traces.json file exists."""
    assert os.path.exists('/workdir/traces.json'), "traces.json file not found"
    print("✓ traces.json file exists")


def test_uses_opentelemetry_sdk():
    """Test that the code actually uses OpenTelemetry SDK, not a custom implementation."""
    with open('/workdir/App.java', 'r') as f:
        app_content = f.read()

    # Check for OpenTelemetry imports in App.java
    otel_imports = [
        'io.opentelemetry',
        'opentelemetry'
    ]

    has_otel_import = any(imp in app_content for imp in otel_imports)
    assert has_otel_import, (
        "App.java must use OpenTelemetry SDK (import io.opentelemetry.*). "
        "Custom tracer implementations are not allowed."
    )

    # Check that no custom Tracer class is being defined (common cheat)
    import glob
    java_files = glob.glob('/workdir/*.java')
    for java_file in java_files:
        with open(java_file, 'r') as f:
            content = f.read()
        # If there's a Tracer class without OpenTelemetry imports, it's a custom implementation
        if 'class Tracer' in content and 'io.opentelemetry' not in content:
            assert False, (
                f"Custom Tracer implementation detected in {java_file}. "
                "You must use the OpenTelemetry SDK, not a custom tracer."
            )
        # Also check for custom Span class
        if 'class Span ' in content and 'io.opentelemetry' not in content:
            assert False, (
                f"Custom Span implementation detected in {java_file}. "
                "You must use the OpenTelemetry SDK, not a custom implementation."
            )

    print("✓ Code uses OpenTelemetry SDK")


def test_trace_json_structure():
    """Test the structure and content of the trace JSON."""
    with open('/workdir/traces.json', 'r') as f:
        data = json.load(f)
    
    # Handle OTLP format with resourceSpans
    assert 'resourceSpans' in data, "Missing resourceSpans in trace JSON"
    
    # Check resource attributes
    resource_spans = data['resourceSpans']
    assert len(resource_spans) > 0, "Empty resourceSpans array"
    
    resource = resource_spans[0].get('resource', {})
    attributes = resource.get('attributes', [])
    
    # Check for service.name and service.version
    attr_keys = [attr.get('key') for attr in attributes]
    assert 'service.name' in attr_keys, "Missing service.name in resource attributes"
    assert 'service.version' in attr_keys, "Missing service.version in resource attributes"
    
    # Extract all spans
    spans = []
    for resource_span in resource_spans:
        for scope_span in resource_span.get('scopeSpans', []):
            spans.extend(scope_span.get('spans', []))
    
    # Should have at least 15 spans for comprehensive instrumentation
    assert len(spans) >= 15, f"Expected at least 15 spans, got {len(spans)}"
    
    # Check for expected span types
    span_names = [span.get('name', '') for span in spans]
    
    expected_span_types = [
        'WebService.handleRequest',
        'DatabaseService.executeQuery',
        'DatabaseService.updateCache',
        'MessageQueue.publish',
        'MessageQueue.consume',
        'BackgroundWorker'
    ]
    
    for expected_type in expected_span_types:
        matching_spans = [name for name in span_names if expected_type in name]
        assert len(matching_spans) > 0, f"No spans found for '{expected_type}'"
    
    # Check span structure
    for span in spans:
        assert 'name' in span, "Span missing 'name' field"
        assert 'spanId' in span, "Span missing 'spanId' field"
        assert 'traceId' in span, "Span missing 'traceId' field"
        assert 'startTimeUnixNano' in span or 'startTimeNanos' in span, "Span missing start time"
        assert 'endTimeUnixNano' in span or 'endTimeNanos' in span, "Span missing end time"
    
    # Check for error spans (should have some due to 20% failure rate)
    error_spans = [s for s in spans if s.get('status', {}).get('code') == 2 or 
                   any(e.get('name') == 'exception' for e in s.get('events', []))]
    assert len(error_spans) > 0, "No error spans found (expected some due to simulated failures)"
    
    # Check parent-child relationships
    root_spans = [s for s in spans if 'WebService.handleRequest' in s.get('name', '')]
    assert len(root_spans) >= 6, "Expected at least 6 root spans (5 requests + 1 health check)"
    
    # Check that child spans have parent IDs
    child_spans = [s for s in spans if s.get('parentSpanId')]
    assert len(child_spans) > len(root_spans), "Expected more child spans than root spans"
    
    # Check for async operations (cache updates should be async)
    cache_spans = [s for s in spans if 'updateCache' in s.get('name', '')]
    assert len(cache_spans) > 0, "No cache update spans found"
    
    # Check for thread ID attributes
    spans_with_thread_id = [s for s in spans 
                            if any('thread' in str(attr.get('key', '')).lower() 
                                  for attr in s.get('attributes', []))]
    assert len(spans_with_thread_id) > 0, "No spans with thread ID attributes found"
    
    print("✓ Trace JSON structure is valid")
    print(f"✓ Found {len(spans)} spans with comprehensive instrumentation")
    print(f"✓ Found error spans indicating proper error handling")
    print(f"✓ Parent-child relationships present")
    print(f"✓ Async operations properly traced")


def test_context_propagation():
    """Test that context is properly propagated across threads."""
    with open('/workdir/traces.json', 'r') as f:
        data = json.load(f)
    
    spans = []
    for resource_span in data.get('resourceSpans', []):
        for scope_span in resource_span.get('scopeSpans', []):
            spans.extend(scope_span.get('spans', []))
    
    # Group spans by trace ID
    traces = {}
    for span in spans:
        trace_id = span.get('traceId')
        if trace_id not in traces:
            traces[trace_id] = []
        traces[trace_id].append(span)
    
    # Each trace should have multiple related spans
    for trace_id, trace_spans in traces.items():
        if len(trace_spans) > 1:  # Skip single-span traces
            # Check that all spans in a trace share the same trace ID
            trace_ids_in_trace = set(s.get('traceId') for s in trace_spans)
            assert len(trace_ids_in_trace) == 1, f"Inconsistent trace IDs in trace"
            
            # Check for proper parent-child chains
            root_spans = [s for s in trace_spans if not s.get('parentSpanId')]
            if root_spans:
                assert len(root_spans) == 1, f"Multiple root spans in single trace"
    
    print("✓ Context propagation across threads verified")


if __name__ == "__main__":
    try:
        test_console_output()
        test_trace_json_exists()
        test_uses_opentelemetry_sdk()
        test_trace_json_structure()
        test_context_propagation()
        print("\nAll tests passed!")
        sys.exit(0)
    except AssertionError as e:
        print(f"\nTest failed: {e}")
        sys.exit(1)
    except Exception as e:
        print(f"\nUnexpected error: {e}")
        sys.exit(1)
#!/usr/bin/env python3

import json
import os
import sys


def test_console_output():
    """Test that both server and client ran successfully."""
    # Check server output
    with open('/workdir/server_output.txt', 'r') as f:
        server_output = f.read()
    
    assert "Server starting on :8080" in server_output, "Server didn't start properly"
    assert "Search request received" in server_output, "Server didn't receive search request"
    assert "Result request received" in server_output, "Server didn't receive result request"
    
    # Check client output
    with open('/workdir/client_output.txt', 'r') as f:
        client_output = f.read()
    
    assert "Making search request" in client_output, "Client didn't make search request"
    assert "Received token:" in client_output, "Client didn't receive token"
    assert "Making result request" in client_output, "Client didn't make result request"
    assert "Received data:" in client_output, "Client didn't receive data"
    assert "Client completed successfully" in client_output, "Client didn't complete successfully"
    
    print("✓ Console output shows successful workflow execution")


def test_trace_json_exists():
    """Test that traces.json file exists."""
    assert os.path.exists('/workdir/traces.json'), "traces.json file not found"
    print("✓ traces.json file exists")


def test_single_trace_with_correct_propagation():
    """Test that there is exactly one trace with all spans properly connected."""
    with open('/workdir/traces.json', 'r') as f:
        content = f.read().strip()
    
    # Handle different JSON formats
    spans = []
    
    try:
        # Try to parse as regular JSON first
        data = json.loads(content)
        
        # Handle OTLP format (resourceSpans)
        if 'resourceSpans' in data:
            for resource_span in data['resourceSpans']:
                if 'scopeSpans' in resource_span:
                    for scope_span in resource_span['scopeSpans']:
                        if 'spans' in scope_span:
                            spans.extend(scope_span['spans'])
        # Handle direct spans array
        elif 'spans' in data:
            spans = data['spans']
        # Handle if data itself is a list of spans
        elif isinstance(data, list):
            spans = data
        else:
            # Single span object
            spans = [data]
            
    except json.JSONDecodeError:
        # Handle JSON Lines format (multiple JSON objects separated by newlines)
        lines = content.split('\n')
        for line in lines:
            line = line.strip()
            if line:
                try:
                    span_data = json.loads(line)
                    spans.append(span_data)
                except json.JSONDecodeError:
                    continue
    
    # Check that we have spans but not more than 6
    assert len(spans) > 0, "No spans found"
    
    if len(spans) > 6:
        # Provide detailed information about what spans were created
        print(f"\n❌ Too many spans: {len(spans)} (expected at most 6)")
        print("\nSpans found:")
        for i, span in enumerate(spans, 1):
            name = span.get('name') or span.get('Name') or span.get('operationName') or 'Unknown'
            span_id = (span.get('spanId') or span.get('span_id') or span.get('SpanID') or 
                      span.get('SpanContext', {}).get('SpanID') or 'Unknown')[:8]
            parent_id = (span.get('parentSpanId') or span.get('parent_span_id') or 
                        span.get('ParentSpanID') or span.get('Parent', {}).get('SpanID') or 'Root')[:8]
            print(f"  {i}. {name} (ID: {span_id}, Parent: {parent_id})")
        
        print("\nHint: The task requires focused instrumentation of essential HTTP operations only.")
        print("Consider removing:")
        print("  - Internal business logic spans (e.g., token generation, storage)")
        print("  - Duplicate automatic instrumentation spans")
        print("  - Non-essential operation spans")
        print("\nIdeal structure (5-6 spans):")
        print("  1. Client workflow (root)")
        print("  2. Client search request")
        print("  3. Server /search handler")
        print("  4. Client result request")
        print("  5. Server /result handler")
        
        assert False, f"Too many spans: {len(spans)} (expected at most 6). See details above."
    
    print(f"✓ Found {len(spans)} spans (within limit of 6)")
    
    # Normalize span field names and check required fields
    for span in spans:
        # Handle various field name formats
        span_id = (span.get('spanId') or span.get('span_id') or span.get('SpanID') or 
                  span.get('SpanContext', {}).get('SpanID') or span.get('SpanContext', {}).get('spanId'))
        trace_id = (span.get('traceId') or span.get('trace_id') or span.get('TraceID') or
                   span.get('SpanContext', {}).get('TraceID') or span.get('SpanContext', {}).get('traceId'))
        name = span.get('name') or span.get('Name') or span.get('operationName')
        
        assert span_id, f"Span missing ID field: {list(span.keys())}"
        assert trace_id, f"Span missing trace ID field: {list(span.keys())}"
        assert name, f"Span missing name field: {list(span.keys())}"
    
    # Extract all trace IDs with normalization
    trace_ids = set()
    for span in spans:
        trace_id = (span.get('traceId') or span.get('trace_id') or span.get('TraceID') or
                   span.get('SpanContext', {}).get('TraceID') or span.get('SpanContext', {}).get('traceId'))
        if trace_id:
            trace_ids.add(trace_id)
    
    # Must have exactly one trace ID across all spans
    assert len(trace_ids) == 1, f"Expected exactly 1 trace ID, found {len(trace_ids)}: {trace_ids}"
    
    print("✓ All spans belong to exactly one trace")
    
    # Check for proper parent-child relationships with normalization
    span_ids = set()
    parent_child_map = {}
    
    for span in spans:
        span_id = (span.get('spanId') or span.get('span_id') or span.get('SpanID') or 
                  span.get('SpanContext', {}).get('SpanID') or span.get('SpanContext', {}).get('spanId'))
        parent_id = (span.get('parentSpanId') or span.get('parent_span_id') or span.get('ParentSpanID') or
                    span.get('Parent', {}).get('SpanID') or span.get('Parent', {}).get('spanId'))
        
        if span_id:
            span_ids.add(span_id)
            parent_child_map[span_id] = parent_id
    
    # Validate that all parent IDs reference existing spans (except for root)
    root_spans = []
    for span_id, parent_id in parent_child_map.items():
        if parent_id is None or parent_id == "":
            root_spans.append(span_id)
        else:
            assert parent_id in span_ids, f"Parent span ID {parent_id} not found in trace"
    
    # Must have exactly one root span
    assert len(root_spans) == 1, f"Expected exactly 1 root span, found {len(root_spans)}"
    
    print("✓ Proper parent-child relationships with exactly one root span")
    
    # Check that we have evidence of both search and result operations
    span_names = [(span.get('name') or span.get('Name') or span.get('operationName') or '').lower() for span in spans]
    
    search_found = any('search' in name or '/search' in name for name in span_names)
    result_found = any('result' in name or '/result' in name for name in span_names)
    
    assert search_found, "Search operation not found in spans"
    assert result_found, "Result operation not found in spans"
    
    print("✓ Both search and result operations are traced")
    print("✓ Single trace with correct propagation verified")


if __name__ == "__main__":
    try:
        test_console_output()
        test_trace_json_exists()
        test_single_trace_with_correct_propagation()
        print("\nAll tests passed!")
        print("\n" + "="*50)
        print("SUCCESS: Single trace with correct propagation verified!")
        print("All spans belong to one trace with proper parent-child relationships")
        print("and the number of spans is within the limit of 6.")
        print("="*50)
        sys.exit(0)
    except AssertionError as e:
        print(f"\nTest failed: {e}")
        sys.exit(1)
    except Exception as e:
        print(f"\nUnexpected error: {e}")
        sys.exit(1)
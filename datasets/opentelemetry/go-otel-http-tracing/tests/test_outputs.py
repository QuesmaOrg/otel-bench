#!/usr/bin/env python3
"""Test the Go HTTP server-client distributed tracing output."""

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
    
    print("✓ Console output is correct")


def test_trace_json_exists():
    """Test that traces.json file exists."""
    assert os.path.exists('/workdir/traces.json'), "traces.json file not found"
    print("✓ traces.json file exists")


def test_trace_structure():
    """Test the structure of the distributed trace."""
    with open('/workdir/traces.json', 'r') as f:
        data = json.load(f)
    
    # Extract spans from various possible formats
    spans = []
    
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
        assert False, f"Unknown JSON structure: {list(data.keys())}"
    
    # Should have exactly 6 spans (or at least 4 from server perspective)
    assert len(spans) >= 4, f"Expected at least 4 spans, got {len(spans)}"
    
    # If we have the full distributed trace, should be 6 spans
    if len(spans) >= 6:
        print(f"✓ Found {len(spans)} spans (full distributed trace)")
    else:
        print(f"✓ Found {len(spans)} spans (server-only perspective)")
    
    # Check for expected span names/types
    span_names = [span.get('name', '') for span in spans]
    
    # Server spans are required
    server_search_found = any('search' in name.lower() or '/search' in name for name in span_names)
    server_result_found = any('result' in name.lower() or '/result' in name for name in span_names)
    
    assert server_search_found, "Server search span not found"
    assert server_result_found, "Server result span not found"
    
    # Check if client spans are present (for full trace)
    client_spans_found = any('client' in name.lower() for name in span_names)
    
    if len(spans) >= 6:
        assert client_spans_found, "Client spans not found in distributed trace"
    
    # Check that all spans have required fields
    for span in spans:
        assert 'spanId' in span or 'span_id' in span, "Span missing ID field"
        assert 'traceId' in span or 'trace_id' in span, "Span missing trace ID field"
        assert 'name' in span, "Span missing name field"
    
    print("✓ Trace structure is valid")
    print(f"✓ Found server spans: search and result")
    if client_spans_found:
        print(f"✓ Found client spans (distributed trace)")


def test_distributed_trace_relationships():
    """Test parent-child relationships in the distributed trace."""
    with open('/workdir/traces.json', 'r') as f:
        data = json.load(f)
    
    spans = []
    if 'resourceSpans' in data:
        for resource_span in data['resourceSpans']:
            if 'scopeSpans' in resource_span:
                for scope_span in resource_span['scopeSpans']:
                    if 'spans' in scope_span:
                        spans.extend(scope_span['spans'])
    elif 'spans' in data:
        spans = data['spans']
    elif isinstance(data, list):
        spans = data
    
    # Group spans by trace ID
    traces = {}
    for span in spans:
        trace_id = span.get('traceId', span.get('trace_id'))
        if trace_id:
            if trace_id not in traces:
                traces[trace_id] = []
            traces[trace_id].append(span)
    
    # Check relationships
    for trace_id, trace_spans in traces.items():
        # Find root span (no parent)
        root_spans = []
        child_spans = []
        
        for span in trace_spans:
            parent_id = span.get('parentSpanId', span.get('parent_span_id'))
            if parent_id:
                child_spans.append(span)
            else:
                root_spans.append(span)
        
        # In a distributed trace, should have one root (client main)
        # In server-only trace, might have two roots (one per request)
        if len(trace_spans) >= 6:
            assert len(root_spans) == 1, f"Expected 1 root span in distributed trace, got {len(root_spans)}"
            assert len(child_spans) >= 5, f"Expected at least 5 child spans, got {len(child_spans)}"
        
        # Check that parent IDs reference existing spans
        span_ids = set()
        for span in trace_spans:
            span_id = span.get('spanId', span.get('span_id'))
            if span_id:
                span_ids.add(span_id)
        
        for child in child_spans:
            parent_id = child.get('parentSpanId', child.get('parent_span_id'))
            if parent_id:
                assert parent_id in span_ids, f"Parent span ID {parent_id} not found in trace"
    
    print("✓ Distributed trace relationships are correct")


def test_span_attributes():
    """Test that spans have the required attributes."""
    with open('/workdir/traces.json', 'r') as f:
        data = json.load(f)
    
    spans = []
    if 'resourceSpans' in data:
        for resource_span in data['resourceSpans']:
            if 'scopeSpans' in resource_span:
                for scope_span in resource_span['scopeSpans']:
                    if 'spans' in scope_span:
                        spans.extend(scope_span['spans'])
    elif 'spans' in data:
        spans = data['spans']
    elif isinstance(data, list):
        spans = data
    
    # Check for HTTP-related attributes in spans
    http_spans = []
    for span in spans:
        attributes = span.get('attributes', [])
        # Convert attributes to dict for easier checking
        attr_dict = {}
        if isinstance(attributes, list):
            for attr in attributes:
                key = attr.get('key', '')
                value = attr.get('value', {})
                attr_dict[key] = value
        elif isinstance(attributes, dict):
            attr_dict = attributes
        
        # Check for HTTP attributes
        if any(k.startswith('http.') for k in attr_dict.keys()):
            http_spans.append(span)
    
    # Should have HTTP attributes in at least some spans
    assert len(http_spans) > 0, "No spans with HTTP attributes found"
    
    print(f"✓ Found {len(http_spans)} spans with HTTP attributes")
    print("✓ Span attributes are properly set")


if __name__ == "__main__":
    try:
        test_console_output()
        test_trace_json_exists()
        test_trace_structure()
        test_distributed_trace_relationships()
        test_span_attributes()
        print("\nAll tests passed!")
        sys.exit(0)
    except AssertionError as e:
        print(f"\nTest failed: {e}")
        sys.exit(1)
    except Exception as e:
        print(f"\nUnexpected error: {e}")
        sys.exit(1)
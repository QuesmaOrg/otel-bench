#!/usr/bin/env python3
"""Test traces by querying the OpenTelemetry Collector directly."""

import json
import time
import urllib.request
import urllib.error
from collections import defaultdict
from typing import Dict, List, Any


def query_collector_traces(collector_url: str = "http://localhost:4318") -> Dict[str, Any]:
    """Query the OpenTelemetry Collector for traces via HTTP API.
    
    Note: This assumes the collector has an HTTP endpoint exposed for querying traces.
    Standard OTLP collectors expose metrics at :8888/metrics but not necessarily traces.
    This function attempts common endpoints.
    """
    traces_data = {"traces": [], "error": None}
    
    # Try different possible endpoints
    endpoints = [
        f"{collector_url}/v1/traces",  # OTLP HTTP endpoint (write-only typically)
        "http://localhost:8888/metrics",  # Prometheus metrics endpoint
        "http://localhost:55679/debug/tracez",  # Debug endpoint (if enabled)
    ]
    
    for endpoint in endpoints:
        try:
            with urllib.request.urlopen(endpoint, timeout=5) as response:
                content = response.read().decode('utf-8')
                
                # Check if it's JSON
                try:
                    data = json.loads(content)
                    traces_data["traces"] = data
                    traces_data["endpoint"] = endpoint
                    return traces_data
                except json.JSONDecodeError:
                    # Not JSON, might be metrics format
                    if "otelcol_receiver_accepted_spans" in content:
                        traces_data["metrics"] = content
                        traces_data["endpoint"] = endpoint
                    continue
                    
        except (urllib.error.URLError, urllib.error.HTTPError) as e:
            continue
        except Exception as e:
            traces_data["error"] = str(e)
    
    return traces_data


def test_collector_trace_reception():
    """Test that the collector received traces by checking metrics."""
    print("Testing collector trace reception via metrics...")
    
    try:
        # Query collector metrics endpoint
        with urllib.request.urlopen('http://localhost:8888/metrics', timeout=5) as response:
            metrics_content = response.read().decode('utf-8')
        
        # Parse metrics for trace/span counts
        spans_received = 0
        
        for line in metrics_content.split('\n'):
            if 'otelcol_receiver_accepted_spans' in line and not line.startswith('#'):
                # Extract value from metrics line
                # Format: otelcol_receiver_accepted_spans{receiver="otlp",transport="grpc"} 7
                parts = line.split()
                if len(parts) >= 2:
                    try:
                        value = float(parts[-1])
                        spans_received += value
                    except ValueError:
                        continue
        
        print(f"✓ Collector metrics show {int(spans_received)} spans received")
        
        assert spans_received > 0, "Collector received 0 spans"
        assert spans_received >= 4, f"Expected at least 4 spans, got {int(spans_received)}"
        
        # Look for other relevant metrics
        if 'otelcol_exporter_sent_spans' in metrics_content:
            print("✓ Collector exported spans to configured exporters")
        
        return int(spans_received)
        
    except urllib.error.URLError as e:
        print(f"❌ Could not connect to collector metrics: {e}")
        assert False, f"Failed to connect to collector: {e}"
    except Exception as e:
        print(f"❌ Error querying collector: {e}")
        assert False, f"Collector query error: {e}"


def test_collector_health_check():
    """Test that the collector is healthy and running."""
    print("Testing collector health...")
    
    health_endpoints = [
        "http://localhost:13133/",  # Default health check port
        "http://localhost:8888/",    # Metrics endpoint
        "http://localhost:4317/",    # gRPC OTLP (won't respond to HTTP but can test connection)
        "http://localhost:4318/",    # HTTP OTLP
    ]
    
    healthy = False
    working_endpoint = None
    
    for endpoint in health_endpoints:
        try:
            # Try to connect (even if it returns an error, connection means it's running)
            with urllib.request.urlopen(endpoint, timeout=2) as response:
                if response.status == 200:
                    healthy = True
                    working_endpoint = endpoint
                    break
        except urllib.error.HTTPError as e:
            # HTTP error means the server is running but maybe wrong protocol
            if e.code in [400, 404, 405]:  # Bad request, not found, method not allowed
                healthy = True
                working_endpoint = f"{endpoint} (responded with {e.code})"
                break
        except:
            continue
    
    if healthy:
        print(f"✓ Collector is running at {working_endpoint}")
    else:
        print("❌ Collector appears to be down")
        assert False, "Collector is not responding"


def test_trace_export_verification():
    """Verify that traces were exported by checking the exported file and metrics."""
    print("Verifying trace export...")
    
    import os
    
    # Check if traces.json exists and has content
    traces_file = '/workdir/traces.json'
    
    if not os.path.exists(traces_file):
        print("❌ traces.json file not found")
        assert False, "Traces file not exported"
    
    file_size = os.path.getsize(traces_file)
    if file_size < 10:
        print(f"❌ traces.json is too small ({file_size} bytes)")
        assert False, "Traces file appears empty"
    
    print(f"✓ traces.json exists with {file_size} bytes")
    
    # Parse and validate trace structure
    traces = defaultdict(lambda: {"spans": [], "services": set()})
    
    try:
        with open(traces_file, 'r') as f:
            for line in f:
                line = line.strip()
                if not line:
                    continue
                    
                try:
                    data = json.loads(line)
                    
                    # Parse OTLP JSON format
                    if 'resourceSpans' in data:
                        for resource_span in data['resourceSpans']:
                            # Extract service name
                            service_name = "unknown"
                            if 'resource' in resource_span and 'attributes' in resource_span['resource']:
                                for attr in resource_span['resource']['attributes']:
                                    if attr.get('key') == 'service.name':
                                        service_name = attr['value'].get('stringValue', 'unknown')
                                        break
                            
                            # Process spans
                            for scope_span in resource_span.get('scopeSpans', []):
                                for span in scope_span.get('spans', []):
                                    trace_id = span.get('traceId', '')
                                    traces[trace_id]['spans'].append(span)
                                    traces[trace_id]['services'].add(service_name)
                                    
                except json.JSONDecodeError:
                    continue
                    
    except Exception as e:
        print(f"❌ Failed to parse traces file: {e}")
        assert False, f"Failed to parse traces: {e}"
    
    print(f"✓ Parsed {len(traces)} unique trace(s) from exported file")
    
    # Validate we have multiple traces
    if len(traces) <= 1:
        assert False, f"Expected more than 1 trace, got {len(traces)}"
    
    # Check for distributed traces
    distributed_count = 0
    for trace_id, trace_data in traces.items():
        services = trace_data['services']
        if 'search-client' in services and ('search-service' in services or 'search-server' in services):
            distributed_count += 1
    
    if distributed_count > 0:
        print(f"✓ Found {distributed_count} distributed trace(s)")
    else:
        print("❌ No distributed traces found")
        assert False, "No properly distributed traces"


def test_collector_pipeline_validation():
    """Validate that the collector pipeline is working correctly."""
    print("Validating collector pipeline...")
    
    try:
        # Check metrics for pipeline health
        with urllib.request.urlopen('http://localhost:8888/metrics', timeout=5) as response:
            metrics = response.read().decode('utf-8')
        
        # Check key pipeline metrics
        pipeline_healthy = True
        issues = []
        
        # Check if receiver accepted spans
        if 'otelcol_receiver_accepted_spans' in metrics:
            print("✓ Receiver accepting spans")
        else:
            issues.append("Receiver not accepting spans")
            pipeline_healthy = False
        
        # Check if processor is working (if configured)
        if 'otelcol_processor_batch_batch_send_size' in metrics:
            print("✓ Batch processor working")
        
        # Check if exporter sent spans
        if 'otelcol_exporter_sent_spans' in metrics:
            print("✓ Exporter sending spans")
        elif 'otelcol_exporter_send_failed_spans' in metrics:
            issues.append("Exporter failing to send spans")
            pipeline_healthy = False
        
        # Check for errors
        if 'otelcol_receiver_refused_spans' in metrics:
            # Extract the count
            for line in metrics.split('\n'):
                if 'otelcol_receiver_refused_spans' in line and not line.startswith('#'):
                    parts = line.split()
                    if len(parts) >= 2:
                        refused = float(parts[-1])
                        if refused > 0:
                            issues.append(f"Receiver refused {int(refused)} spans")
        
        if not pipeline_healthy:
            print(f"❌ Pipeline issues: {', '.join(issues)}")
            assert False, f"Collector pipeline issues: {', '.join(issues)}"
        
        print("✓ Collector pipeline is healthy")
        
    except Exception as e:
        print(f"❌ Failed to validate pipeline: {e}")
        assert False, f"Pipeline validation failed: {e}"


# Tests will be automatically discovered and run by pytest
#!/bin/bash
set -e

cat << 'EOF' > /workdir/demo.cpp
#include <iostream>
#include <string>
#include <chrono>
#include <thread>
#include <vector>
#include <fstream>
#include <iomanip>
#include <random>
#include <sstream>

std::string generate_id(size_t len) {
    static const char chars[] = "0123456789abcdef";
    static std::mt19937 gen(std::random_device{}());
    std::uniform_int_distribution<> dis(0, 15);
    std::string res = "";
    for (size_t i = 0; i < len; ++i) res += chars[dis(gen)];
    return res;
}

struct Span {
    std::string name;
    std::string traceId;
    std::string spanId;
    std::string parentSpanId;
    long long startTimestamp;
    long long endTimestamp;
    std::string attr_id;
};

std::vector<Span> global_spans;

class Demo {
public:
    void work(const std::string& id) {
        auto start = std::chrono::system_clock::now().time_since_epoch().count();
        std::string traceId = generate_id(32);
        std::string spanId = generate_id(16);
        
        std::cout << "Starting work with id: " << id << std::endl;
        
        fastOp(id, traceId, spanId);
        slowOp(id, traceId, spanId);
        
        std::cout << "Work completed" << std::endl;
        
        auto end = std::chrono::system_clock::now().time_since_epoch().count();
        global_spans.push_back({"Demo.work", traceId, spanId, "", start, end, id});
    }
    
    void fastOp(const std::string& id, const std::string& traceId, const std::string& parentId) {
        auto start = std::chrono::system_clock::now().time_since_epoch().count();
        std::string spanId = generate_id(16);
        
        std::cout << "FastOp executing with id: " << id << std::endl;
        long sum = 0;
        for (int i = 0; i < 100000; i++) {
            sum += i;
        }
        
        auto end = std::chrono::system_clock::now().time_since_epoch().count();
        global_spans.push_back({"Demo.fastOp", traceId, spanId, parentId, start, end, id});
    }
    
    void slowOp(const std::string& id, const std::string& traceId, const std::string& parentId) {
        auto start = std::chrono::system_clock::now().time_since_epoch().count();
        std::string spanId = generate_id(16);
        
        std::cout << "SlowOp executing with id: " << id << std::endl;
        std::this_thread::sleep_for(std::chrono::milliseconds(120));
        
        auto end = std::chrono::system_clock::now().time_since_epoch().count();
        global_spans.push_back({"Demo.slowOp", traceId, spanId, parentId, start, end, id});
    }
};

int main() {
    Demo d;
    d.work("42");
    
    std::ofstream out("/workdir/traces.json");
    out << "[\n";
    for (size_t i = 0; i < global_spans.size(); ++i) {
        const auto& s = global_spans[i];
        out << "  {\n"
            << "    \"name\": \"" << s.name << "\",\n"
            << "    \"traceId\": \"" << s.traceId << "\",\n"
            << "    \"spanId\": \"" << s.spanId << "\",\n"
            << "    \"parentSpanId\": \"" << s.parentSpanId << "\",\n"
            << "    \"startTimestamp\": " << s.startTimestamp << ",\n"
            << "    \"endTimestamp\": " << s.endTimestamp << ",\n"
            << "    \"attributes\": { \"id\": \"" << s.attr_id << "\" }\n"
            << "  }" << (i == global_spans.size() - 1 ? "" : ",") << "\n";
    }
    out << "]\n";
    
    std::cout << "Done." << std::endl;
    return 0;
}
EOF

g++ -std=c++17 -o demo demo.cpp -pthread && ./demo

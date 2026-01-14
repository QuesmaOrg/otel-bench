FROM ubuntu:22.04

ENV DEBIAN_FRONTEND=noninteractive

# Install C++ compiler and basic tools
RUN apt-get update && apt-get install -y \
    g++ \
    make \
    cmake \
    curl \
    wget \
    python3 \
    python3-pip \
    && apt-get clean \
    && rm -rf /var/lib/apt/lists/*

WORKDIR /workdir

# Create the demo application
RUN cat > /workdir/demo.cpp << 'EOF'
#include <iostream>
#include <string>
#include <chrono>
#include <thread>

class Demo {
public:
    void work(const std::string& id) {
        std::cout << "Starting work with id: " << id << std::endl;
        fastOp(id);
        slowOp(id);
        std::cout << "Work completed" << std::endl;
    }
    
    void fastOp(const std::string& id) {
        std::cout << "FastOp executing with id: " << id << std::endl;
        long sum = 0;
        for (int i = 0; i < 100000; i++) {
            sum += i;
        }
    }
    
    void slowOp(const std::string& id) {
        std::cout << "SlowOp executing with id: " << id << std::endl;
        std::this_thread::sleep_for(std::chrono::milliseconds(120));
    }
};

int main() {
    Demo d;
    d.work("42");
    std::cout << "Done." << std::endl;
    return 0;
}
EOF

# Create a simple CMakeLists.txt
RUN cat > /workdir/CMakeLists.txt << 'EOF'
cmake_minimum_required(VERSION 3.16)
project(demo)
set(CMAKE_CXX_STANDARD 17)
add_executable(demo demo.cpp)
target_link_libraries(demo pthread)
EOF
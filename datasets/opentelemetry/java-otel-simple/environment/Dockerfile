FROM eclipse-temurin:17-jdk-jammy

ENV DEBIAN_FRONTEND=noninteractive

# Install basic tools and Python for testing
RUN apt-get update && apt-get install -y \
    curl \
    wget \
    python3 \
    python3-pip \
    && apt-get clean \
    && rm -rf /var/lib/apt/lists/*

WORKDIR /workdir

# Create the demo application
RUN cat > /workdir/Demo.java << 'EOF'
import java.util.concurrent.TimeUnit;

public class Demo {
    
    public void work(String id) {
        System.out.println("Starting work with id: " + id);
        fastOp(id);
        slowOp(id);
        System.out.println("Work completed");
    }
    
    private void fastOp(String id) {
        System.out.println("FastOp executing with id: " + id);
        long sum = 0;
        for (int i = 0; i < 100000; i++) {
            sum += i;
        }
    }
    
    private void slowOp(String id) {
        System.out.println("SlowOp executing with id: " + id);
        try {
            TimeUnit.MILLISECONDS.sleep(120);
        } catch (InterruptedException e) {
            Thread.currentThread().interrupt();
        }
    }
    
    public static void main(String[] args) {
        Demo demo = new Demo();
        demo.work("42");
        System.out.println("Done.");
    }
}
EOF
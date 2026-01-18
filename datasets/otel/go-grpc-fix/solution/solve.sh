#!/bin/bash
set -e

cd /workdir/opentelemetry-go-compile-instrumentation-grpc-bug-5/

export PATH=$PATH:/usr/local/go/bin

go version

export PATH=$PATH:$(go env GOPATH)/bin

make test

sed -i '50,52c\                if funcDecl.Name.Name != funcName {
                        return false
                }
                if funcDecl.Recv == nil || len(funcDecl.Recv.List) == 0 {
                        return recv == ""
                }' tool/internal/ast/shared.go

make test

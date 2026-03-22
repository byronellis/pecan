#!/bin/bash
# Regenerate Swift protobuf and gRPC files from pecan.proto
# Requires: brew install swift-protobuf
#
# protoc-gen-swift      → from swift-protobuf (generates .pb.swift)
# protoc-gen-grpc-swift → v1 plugin built from grpc-swift package checkout and
#                         copied to $(brew --prefix)/bin/protoc-gen-grpc-swift
#                         (grpc-swift v2 homebrew installs as protoc-gen-grpc-swift-2,
#                          which is incompatible with grpc-swift 1.x in Package.swift)
set -e

PROTO_DIR="Sources/PecanShared"
OUT_DIR="Sources/PecanShared/Sources/PecanShared"

GRPC_PLUGIN="$(brew --prefix)/bin/protoc-gen-grpc-swift"

if [ ! -f "$GRPC_PLUGIN" ]; then
    echo "Error: protoc-gen-grpc-swift not found at $GRPC_PLUGIN"
    echo "Build it from the grpc-swift package checkout:"
    echo "  cd ~/Library/Developer/Xcode/DerivedData/pecan-*/SourcePackages/checkouts/grpc-swift"
    echo "  swift build -c release --product protoc-gen-grpc-swift"
    echo "  cp .build/release/protoc-gen-grpc-swift $(brew --prefix)/bin/"
    exit 1
fi

echo "Generating protobuf messages (.pb.swift)..."
protoc \
    --proto_path="$PROTO_DIR" \
    --swift_out="$OUT_DIR" \
    --swift_opt=Visibility=Public \
    "$PROTO_DIR/pecan.proto"

echo "Generating gRPC service stubs (.grpc.swift)..."
protoc \
    --proto_path="$PROTO_DIR" \
    --grpc-swift_out="$OUT_DIR" \
    --grpc-swift_opt=Visibility=Public \
    --plugin=protoc-gen-grpc-swift="$GRPC_PLUGIN" \
    "$PROTO_DIR/pecan.proto"

echo "Done. Generated files in $OUT_DIR:"
ls -la "$OUT_DIR/"*.swift

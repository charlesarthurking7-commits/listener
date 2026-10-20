#!/bin/bash
# Regenerates the Swift code in Sources/GoogleSpeech/Generated from Protos/.
#
# The generated files are committed, so this only needs running after a change to
# Protos/ or to the swift-protobuf / grpc-swift-protobuf versions in Package.resolved.
#
# protoc: set PROTOC, or have it on PATH (macOS: `brew install protobuf`), or let the
# script download a pinned release into .build/protoc. The two Swift plugins are built
# from the package's own pinned dependencies, so the generated code always matches the
# runtime libraries it is compiled against.
set -euo pipefail
cd "$(dirname "$0")/.."

protoc_version="36.2"
output="Sources/GoogleSpeech/Generated"
well_known_types=".build/checkouts/swift-protobuf/Protos/Sources/SwiftProtobuf"

sha256_of() {
    if command -v sha256sum >/dev/null; then
        sha256sum "$1" | cut -d " " -f 1
    else
        shasum -a 256 "$1" | cut -d " " -f 1
    fi
}

download_protoc() {
    local platform expected
    case "$(uname -s)-$(uname -m)" in
    Darwin-arm64)
        platform="osx-aarch_64"
        expected="9cd98a532c5c5e0c4161314de0225de27e4c8a323917b6ea7b1b714d3ae23466"
        ;;
    Darwin-x86_64)
        platform="osx-x86_64"
        expected="228cc7add4616cc14ca5e80dee83209d44449a7aee95a914ae748fa374efb078"
        ;;
    Linux-x86_64)
        platform="linux-x86_64"
        expected="121f6c7afe1d4d0e3ea6aab9432038599250134cbf4474cb1167d2c7decd4278"
        ;;
    Linux-aarch64)
        platform="linux-aarch_64"
        expected="8b8f18bd2b30346efbc698dd5a73dd7c805f3ef8380f6dfc95c768f3f1852f6a"
        ;;
    *)
        echo "No pinned protoc for $(uname -s) $(uname -m). Install protoc and set PROTOC." >&2
        exit 1
        ;;
    esac

    local directory=".build/protoc/$protoc_version"
    if [[ ! -x "$directory/bin/protoc" ]]; then
        local archive="$directory.zip"
        mkdir -p "$(dirname "$archive")"
        curl --fail --location --silent --show-error --output "$archive" \
            "https://github.com/protocolbuffers/protobuf/releases/download/v$protoc_version/protoc-$protoc_version-$platform.zip"
        if [[ "$(sha256_of "$archive")" != "$expected" ]]; then
            echo "Checksum mismatch for $archive" >&2
            rm -f "$archive"
            exit 1
        fi
        rm -rf "$directory"
        unzip -q "$archive" -d "$directory"
        rm -f "$archive"
    fi
    echo "$directory/bin/protoc"
}

protoc="${PROTOC:-$(command -v protoc || true)}"
if [[ -z "$protoc" ]]; then
    protoc="$(download_protoc)"
fi
echo "Using $("$protoc" --version) at $protoc"

swift package resolve
swift build --product protoc-gen-swift
swift build --product protoc-gen-grpc-swift-2
plugins="$(swift build --show-bin-path)"

rm -rf "$output"
mkdir -p "$output"

# Server stubs are generated too, internal like everything else, because the tests run
# a fake Speech service in process. The app never registers them.
"$protoc" \
    --proto_path=Protos \
    --proto_path="$well_known_types" \
    --plugin="protoc-gen-swift=$plugins/protoc-gen-swift" \
    --plugin="protoc-gen-grpc-swift-2=$plugins/protoc-gen-grpc-swift-2" \
    --swift_out="$output" \
    --swift_opt=Visibility=Internal,FileNaming=DropPath \
    --grpc-swift-2_out="$output" \
    --grpc-swift-2_opt=Visibility=Internal,FileNaming=DropPath,Client=true,Server=true \
    google/cloud/speech/v2/cloud_speech.proto

echo "Generated:"
ls -1 "$output"

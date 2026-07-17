// swift-tools-version: 5.9

import PackageDescription

let package = Package(
    name: "HappyOysterSDK",
    platforms: [
        .iOS(.v15)
    ],
    products: [
        .library(
            name: "HappyOysterSDK",
            targets: [
                "HappyOysterCore",
                "HappyOysterWorld",
                "HappyOysterStream",
                "HappyOysterSDK"
            ]
        ),
        .library(
            name: "HappyOysterUI",
            targets: [
                "HappyOysterCore",
                "HappyOysterWorld",
                "HappyOysterUI"
            ]
        )
    ],
    targets: [
        .binaryTarget(
            name: "HappyOysterCore",
            url: "https://github.com/Future-Living-Lab/happyoyster-sdk-demo-ios/releases/download/1.0.3/HappyOysterCore.xcframework.zip",
            checksum: "7fbb8ac4666ebf03c3522cd4c6719e81b2210ec1b23d98176cbd1f3e1c6cd480"
        ),
        .binaryTarget(
            name: "HappyOysterWorld",
            url: "https://github.com/Future-Living-Lab/happyoyster-sdk-demo-ios/releases/download/1.0.3/HappyOysterWorld.xcframework.zip",
            checksum: "aacf308205b1b2a644c3cd7b65389823eb260e72c33261faec9843e88a876321"
        ),
        .binaryTarget(
            name: "HappyOysterStream",
            url: "https://github.com/Future-Living-Lab/happyoyster-sdk-demo-ios/releases/download/1.0.3/HappyOysterStream.xcframework.zip",
            checksum: "aa2a6ca76a9d28e0e991336ac3f052adaaf540cb2ae0169143b8c6d002042e5b"
        ),
        .binaryTarget(
            name: "HappyOysterSDK",
            url: "https://github.com/Future-Living-Lab/happyoyster-sdk-demo-ios/releases/download/1.0.3/HappyOysterSDK.xcframework.zip",
            checksum: "e77f32301cda0a5e7d65e4fef61fe3f9647f982947791e9a8c0eaa258010d0dd"
        ),
        .binaryTarget(
            name: "HappyOysterUI",
            url: "https://github.com/Future-Living-Lab/happyoyster-sdk-demo-ios/releases/download/1.0.3/HappyOysterUI.xcframework.zip",
            checksum: "ba8146a33d421c6a9d5ccb11648e032968c5e6c1bc79d7014e49eddfb3e7a8b3"
        )
    ]
)

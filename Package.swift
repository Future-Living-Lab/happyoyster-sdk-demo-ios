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
            url: "https://github.com/Future-Living-Lab/happyoyster-sdk-demo-ios/releases/download/0.1.7/HappyOysterCore.xcframework.zip",
            checksum: "ac7c978228c7f8cb766b17467350d5125b4055752116f63a06301aaa22dfa0b3"
        ),
        .binaryTarget(
            name: "HappyOysterWorld",
            url: "https://github.com/Future-Living-Lab/happyoyster-sdk-demo-ios/releases/download/0.1.7/HappyOysterWorld.xcframework.zip",
            checksum: "e1fdb213c4954457af447e0687464a952baa640d7c9a9d7f6ebb7c38b8062f00"
        ),
        .binaryTarget(
            name: "HappyOysterStream",
            url: "https://github.com/Future-Living-Lab/happyoyster-sdk-demo-ios/releases/download/0.1.7/HappyOysterStream.xcframework.zip",
            checksum: "8b80a999ce6df257cf081da22f81aeed7a1dca4369f1b40b26616ce66f081425"
        ),
        .binaryTarget(
            name: "HappyOysterSDK",
            url: "https://github.com/Future-Living-Lab/happyoyster-sdk-demo-ios/releases/download/0.1.7/HappyOysterSDK.xcframework.zip",
            checksum: "a9ddfdbb83ab043e4a28f2e5659d0e317884067972754f0d06f57b79660a4c66"
        ),
        .binaryTarget(
            name: "HappyOysterUI",
            url: "https://github.com/Future-Living-Lab/happyoyster-sdk-demo-ios/releases/download/0.1.7/HappyOysterUI.xcframework.zip",
            checksum: "9d0af16680f450fc73fef906ffa04b878a7465d5e303f255ec8f0eb4df66c9c6"
        )
    ]
)

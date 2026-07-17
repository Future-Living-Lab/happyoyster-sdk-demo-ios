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
            url: "https://github.com/Future-Living-Lab/happyoyster-sdk-demo-ios/releases/download/0.1.5/HappyOysterCore.xcframework.zip",
            checksum: "5403af8d9d150ca30e0dc884d22811fb563907aee6ab3f87378507d32e27572b"
        ),
        .binaryTarget(
            name: "HappyOysterWorld",
            url: "https://github.com/Future-Living-Lab/happyoyster-sdk-demo-ios/releases/download/0.1.5/HappyOysterWorld.xcframework.zip",
            checksum: "166825ce3ddd95065db8b8928a9f63c27505a50a835c35252d58b15953a0bbe9"
        ),
        .binaryTarget(
            name: "HappyOysterStream",
            url: "https://github.com/Future-Living-Lab/happyoyster-sdk-demo-ios/releases/download/0.1.5/HappyOysterStream.xcframework.zip",
            checksum: "9867c8993bd84668b30e9b42f1f9910dd27e1d0a8ac860a156be0f10b71b3fce"
        ),
        .binaryTarget(
            name: "HappyOysterSDK",
            url: "https://github.com/Future-Living-Lab/happyoyster-sdk-demo-ios/releases/download/0.1.5/HappyOysterSDK.xcframework.zip",
            checksum: "9969d631354604b924c2aaa3fc35f489cb2245962380191507f421312b299572"
        ),
        .binaryTarget(
            name: "HappyOysterUI",
            url: "https://github.com/Future-Living-Lab/happyoyster-sdk-demo-ios/releases/download/0.1.5/HappyOysterUI.xcframework.zip",
            checksum: "facb45c3955be18a23dcda6c4055bc542442d3159d1137ca408ad9bdaa84ae2d"
        )
    ]
)

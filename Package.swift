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
            url: "https://github.com/Future-Living-Lab/happyoyster-sdk-demo-ios/releases/download/0.1.6/HappyOysterCore.xcframework.zip",
            checksum: "611ed26effa4e0a01841a4265feb97f59a9849ceaeb93ab1063f90d5dc016731"
        ),
        .binaryTarget(
            name: "HappyOysterWorld",
            url: "https://github.com/Future-Living-Lab/happyoyster-sdk-demo-ios/releases/download/0.1.6/HappyOysterWorld.xcframework.zip",
            checksum: "1e01d29b75ac7a3b70739ddd8ab65d436accbbaa161ff9e443ccc2f3a7ab0a5c"
        ),
        .binaryTarget(
            name: "HappyOysterStream",
            url: "https://github.com/Future-Living-Lab/happyoyster-sdk-demo-ios/releases/download/0.1.6/HappyOysterStream.xcframework.zip",
            checksum: "b63326cc43fe6e16a15436b67c81472cbcc1ec41c973520bc8e8e12c76f145ab"
        ),
        .binaryTarget(
            name: "HappyOysterSDK",
            url: "https://github.com/Future-Living-Lab/happyoyster-sdk-demo-ios/releases/download/0.1.6/HappyOysterSDK.xcframework.zip",
            checksum: "f7249c34bc2469df6bf4ba67fc3e6d207f41d788a650bcee5aad06c7941e8015"
        ),
        .binaryTarget(
            name: "HappyOysterUI",
            url: "https://github.com/Future-Living-Lab/happyoyster-sdk-demo-ios/releases/download/0.1.6/HappyOysterUI.xcframework.zip",
            checksum: "f600fc01ad6c5311a065747c8fe167383ae965cb70e8a1958bcfcfff514f8e33"
        )
    ]
)

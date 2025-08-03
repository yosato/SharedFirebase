// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "SharedFirebase",
    platforms: [
        .iOS(.v14) // Safe default, adjust to your project's deployment target
    ],
    products: [
        .library(
            name: "SharedFirebase",
            targets: ["SharedFirebase"]
        )
    ],
    dependencies: [
        .package(url: "https://github.com/firebase/firebase-ios-sdk.git", from: "11.15.0")
    ],
    targets: [
        .target(
            name: "SharedFirebase",
            dependencies: [
                .product(name: "FirebaseAuth", package: "firebase-ios-sdk"),
                .product(name: "FirebaseFirestore", package: "firebase-ios-sdk")
            ]
        )
    ]
)

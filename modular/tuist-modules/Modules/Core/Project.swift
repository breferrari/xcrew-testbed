import ProjectDescription

let project = Project(
    name: "Core",
    targets: [
        .target(name: "Core", destinations: .iOS, product: .framework, bundleId: "dev.xcrew.testbed.Core", deploymentTargets: .iOS("18.0"), infoPlist: .default, sources: ["Sources/**"]),
        .target(name: "CoreTests", destinations: .iOS, product: .unitTests, bundleId: "dev.xcrew.testbed.CoreTests", deploymentTargets: .iOS("18.0"), infoPlist: .default, sources: ["Tests/**"], dependencies: [.target(name: "Core")]),
    ]
)

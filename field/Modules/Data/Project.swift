import ProjectDescription

let project = Project(
    name: "Data",
    options: .options(automaticSchemesOptions: .enabled(codeCoverageEnabled: true)),
    targets: [
        .target(name: "Data", destinations: .iOS, product: .framework, bundleId: "dev.xcrew.testbed.Data", deploymentTargets: .iOS("18.0"), infoPlist: .default, sources: ["Sources/**"], dependencies: [.project(target: "Core", path: "../Core")]),
        .target(name: "DataTests", destinations: .iOS, product: .unitTests, bundleId: "dev.xcrew.testbed.DataTests", deploymentTargets: .iOS("18.0"), infoPlist: .default, sources: ["Tests/**"], dependencies: [.target(name: "Data")]),
    ]
)

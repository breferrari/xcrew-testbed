import ProjectDescription

let project = Project(
    name: "Feature",
    options: .options(automaticSchemesOptions: .enabled(codeCoverageEnabled: true)),
    targets: [
        .target(name: "Feature", destinations: .iOS, product: .framework, bundleId: "dev.xcrew.testbed.Feature", deploymentTargets: .iOS("18.0"), infoPlist: .default, sources: ["Sources/**"], dependencies: [.project(target: "Data", path: "../Data")]),
        .target(name: "FeatureTests", destinations: .iOS, product: .unitTests, bundleId: "dev.xcrew.testbed.FeatureTests", deploymentTargets: .iOS("18.0"), infoPlist: .default, sources: ["Tests/**"], dependencies: [.target(name: "Feature")]),
    ]
)

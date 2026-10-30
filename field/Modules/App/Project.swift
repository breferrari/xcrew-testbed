import ProjectDescription

let project = Project(
    name: "App",
    options: .options(automaticSchemesOptions: .enabled(codeCoverageEnabled: true)),
    targets: [
        .target(name: "App", destinations: .iOS, product: .app, bundleId: "dev.xcrew.testbed.App", deploymentTargets: .iOS("18.0"), infoPlist: .default, sources: ["Sources/**"], dependencies: [.project(target: "Feature", path: "../Feature")]),
        .target(name: "AppTests", destinations: .iOS, product: .unitTests, bundleId: "dev.xcrew.testbed.AppTests", deploymentTargets: .iOS("18.0"), infoPlist: .default, sources: ["Tests/**"], dependencies: [.target(name: "App")]),
        .target(name: "AppUITests", destinations: .iOS, product: .uiTests, bundleId: "dev.xcrew.testbed.AppUITests", deploymentTargets: .iOS("18.0"), infoPlist: .default, sources: ["UITests/**"], dependencies: [.target(name: "App")]),
    ]
)

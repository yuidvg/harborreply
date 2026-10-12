import XCTest
@testable import HarborCore

final class GenerationRouteTests: XCTestCase {
    func testEnabledConfiguredProviderIsUsed() {
        XCTAssertEqual(GenerationRoute.select(cloudEnabled: true, configured: true), .provider)
    }
    func testDisabledProviderAlwaysRequiresConfiguration() {
        XCTAssertEqual(GenerationRoute.select(cloudEnabled: false, configured: false), .needsConfiguration)
        XCTAssertEqual(GenerationRoute.select(cloudEnabled: false, configured: true), .needsConfiguration)
    }
    func testEnabledUnconfiguredProviderRequiresConfiguration() {
        XCTAssertEqual(GenerationRoute.select(cloudEnabled: true, configured: false), .needsConfiguration)
    }
}

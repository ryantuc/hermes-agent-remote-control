import XCTest

/// "/model <text>" that matches no model the backend offers opens the model drawer with the text already in its search, so the person carries on from what they typed. Typed into the real composer against the demo backend, whose catalogue is empty, so any name matches nothing.
final class ModelCommandSearchUITests: XCTestCase {

    private var app: XCUIApplication!

    override func setUp() {
        continueAfterFailure = false
        app = XCUIApplication()
        app.launchArguments += ["-hermesScreenshotRoute", "demo-home"]
        app.launch()
    }

    override func tearDown() {
        app = nil
    }

    private var composerField: XCUIElement { app.textViews.firstMatch }
    private var homeMenu: XCUIElement { app.buttons["Menu"] }
    private var modelSearch: XCUIElement { app.textFields["Search models and providers"] }

    func testAModelCommandThatMatchesNothingOpensTheDrawerPreSearched() {
        let deadline = Date().addingTimeInterval(20)
        while Date() < deadline, !(homeMenu.exists && homeMenu.isHittable && composerField.exists) {
            Thread.sleep(forTimeInterval: 0.25)
        }
        XCTAssertTrue(homeMenu.exists, "the demo never reached Home")
        Thread.sleep(forTimeInterval: 1.0)

        XCTAssertTrue(composerField.waitForExistence(timeout: 10), "no composer")
        composerField.tap()
        Thread.sleep(forTimeInterval: 0.5)
        composerField.typeText("/model zqxv")
        Thread.sleep(forTimeInterval: 0.5)
        app.buttons["Send"].tap()

        XCTAssertTrue(modelSearch.waitForExistence(timeout: 8), "\"/model zqxv\" did not open the model drawer")
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = "f1-model-drawer-presearched"
        attachment.lifetime = .keepAlways
        add(attachment)
        let value = (modelSearch.value as? String) ?? ""
        print("[f1-ui] model search value='\(value)'")
        XCTAssertEqual(value, "zqxv", "the drawer opened without the typed name in its search")
    }
}

import XCTest
@testable import FAPages

final class FAChallengeTests: XCTestCase {

    private func fixture(_ name: String) throws -> String {
        guard let url = Bundle.module.url(forResource: name, withExtension: "html", subdirectory: "Fixtures") else {
            XCTFail("找不到 fixture: \(name).html")
            return ""
        }
        return try String(contentsOf: url, encoding: .utf8)
    }

    // MARK: - UA

    func testUserAgentContainsIdentity() {
        let ua = FAChallenge.userAgent(appVersion: "0.1.0")
        XCTAssertTrue(ua.hasPrefix("Mozilla/5.0 (iPhone; CPU iPhone OS 15_8"))
        XCTAssertTrue(ua.contains("FAiOS/0.1.0"))
        // 不能有换行：UA 出现在 HTTP 头里
        XCTAssertFalse(ua.contains("\n"))
    }

    func testUserAgentIsStable() {
        // UA 一旦变化，所有已获得的 cf_clearance 都会失效。
        // 这个测试的作用是「如果你无意中改了它，先看见红灯」。
        XCTAssertEqual(
            FAChallenge.userAgent(appVersion: "0.1.0"),
            "Mozilla/5.0 (iPhone; CPU iPhone OS 15_8 like Mac OS X) "
            + "AppleWebKit/605.1.15 (KHTML, like Gecko) "
            + "Version/15.6 Mobile/15E148 Safari/604.1 FAiOS/0.1.0"
        )
    }

    // MARK: - 识别挑战

    func testRealPagesAreNotChallenges() throws {
        for name in ["browse", "home", "submission", "user"] {
            let html = try fixture(name)
            XCTAssertFalse(
                FAChallenge.isChallenge(status: 200, body: html),
                "\(name).html 被误判成挑战页"
            )
        }
    }

    /// 登录页内嵌了 Turnstile 控件，绝不能因为出现 "turnstile" 就判定为挑战
    func testLoginPageIsNotChallengeDespiteTurnstile() throws {
        let html = try fixture("login")
        XCTAssertTrue(html.contains("turnstile") || html.isEmpty,
                      "fixture 应包含 turnstile 控件才说明这个测试有意义")
        XCTAssertFalse(FAChallenge.isChallenge(status: 200, body: html))
    }

    func testChallengePageIsDetected() {
        let html = """
        <!DOCTYPE html><html><head><title>Just a moment...</title>
        <script>window._cf_chl_opt={cvId:"3",cType:"interactive",cRay:"8a1b"};</script>
        <script src="/cdn-cgi/challenge-platform/h/b/orchestrate/chl_page/v1"></script>
        </head><body>Checking your browser before accessing furaffinity.net</body></html>
        """
        XCTAssertTrue(FAChallenge.isChallenge(status: 403, body: html))
        XCTAssertTrue(FAChallenge.isChallenge(status: 503, body: html))
        XCTAssertTrue(FAChallenge.isChallenge(status: 200, body: html), "JS 挑战也会以 200 返回")
        XCTAssertTrue(FAChallenge.requiresInteraction(body: html))
    }

    func testNonInteractiveChallenge() {
        let html = #"<script>window._cf_chl_opt={"cType":"non-interactive"};</script>"#
        XCTAssertTrue(FAChallenge.isChallenge(status: 403, body: html))
        XCTAssertFalse(FAChallenge.requiresInteraction(body: html))
    }

    func testOtherStatusCodesAreNotChallenges() {
        XCTAssertFalse(FAChallenge.isChallenge(status: 404, body: "_cf_chl_opt"))
        XCTAssertFalse(FAChallenge.isChallenge(status: 500, body: "_cf_chl_opt"))
        XCTAssertFalse(FAChallenge.isChallenge(status: 200, body: "hello"))
    }

    // MARK: - 节流参数

    func testThrottleIsConservative() {
        XCTAssertLessThanOrEqual(FAChallenge.Throttle.maxConcurrent, 3, "并发过高会被 FA 限速")
        XCTAssertGreaterThanOrEqual(FAChallenge.Throttle.minimumSpacingMS, 300)
        XCTAssertGreaterThanOrEqual(FAChallenge.Throttle.challengeTimeout, 25,
                                    "参考项目实测挑战最长要 25 秒才解决")
    }
}

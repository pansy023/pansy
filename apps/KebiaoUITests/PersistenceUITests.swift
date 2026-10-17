import XCTest

/// 测试四：数据持久化。
///
/// 关键点：每一步都**真的杀掉进程再重启**（`app.terminate()` + `app.launch()`），
/// 而不是「等两秒看界面变没变」。模拟器里 App 的容器不会被这次重启清掉，
/// 所以重启后还在 ⇒ 真的写进了 `UserDefaults` / Keychain。
final class PersistenceUITests: KebiaoUITestCase {

    func testCreatedEditedAndDeletedCoursesSurviveRelaunch() {
        let createdName = uniqueCourseName("persist")
        let renamedName = uniqueCourseName("persistx")

        // ① 新增一门课程。
        createCourse(named: createdName)

        // ② 重启：课程仍在。
        app.terminate()
        app.launch()
        XCTAssertTrue(mainScreenIsVisible(), "重启后主界面没有出现")
        XCTAssertTrue(
            card(createdName).waitForExistence(timeout: defaultTimeout),
            "重启后新增的课程「\(createdName)」消失了 —— 说明没有落盘"
        )

        // ③ 改名。
        renameCourse(from: createdName, to: renamedName)

        // ④ 再重启：改名结果保留。
        app.terminate()
        app.launch()
        XCTAssertTrue(mainScreenIsVisible(), "重启后主界面没有出现")
        XCTAssertTrue(
            card(renamedName).waitForExistence(timeout: defaultTimeout),
            "重启后改名结果没有保留（「\(renamedName)」不见了）"
        )
        XCTAssertFalse(
            card(createdName).waitForExistence(timeout: 2),
            "重启后又出现了旧名字的卡片「\(createdName)」"
        )

        // ⑤ 删除。
        deleteCourse(named: renamedName)

        // ⑥ 再重启：已删除的课程不会复活。
        app.terminate()
        app.launch()
        XCTAssertTrue(mainScreenIsVisible(), "重启后主界面没有出现")
        XCTAssertFalse(
            card(renamedName).waitForExistence(timeout: 3),
            "重启后被删除的课程「\(renamedName)」又回来了 —— 删除没有真正落盘"
        )
    }
}

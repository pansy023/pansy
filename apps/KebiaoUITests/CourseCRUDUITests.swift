import XCTest

/// 测试三：课程增删改。
///
/// 全程走真实交互路径：`＋` → 课程编辑页 → 保存 → 主界面卡片；
/// 卡片 → 展开浮层 → 「更多」 → 编辑页 → 改名 / 删除 → 确认。
/// 每一步都断言「界面上的结果」，不直接读内部数据。
final class CourseCRUDUITests: KebiaoUITestCase {

    func testCreateEditAndDeleteCourseIsReflectedOnTimetable() {
        let createdName = uniqueCourseName("crud")
        let renamedName = uniqueCourseName("crudx")

        // ① 新增课程 → 主界面出现卡片。
        createCourse(named: createdName)
        attachScreenshot("crud-created")

        // ② 编辑课程（改课程名）→ 主界面换成新名字。
        renameCourse(from: createdName, to: renamedName)
        attachScreenshot("crud-renamed")

        // ③ 删除课程 → 主界面彻底不再出现。
        deleteCourse(named: renamedName)
        attachScreenshot("crud-deleted")
    }

    /// 「课程名为空不落库」是原版规则（`AddCourseScreenKt.java:1400-1402`）：
    /// iOS 端把它表现成「保存按钮置灰」。这条断言在没有输入任何字符时执行。
    func testSaveIsDisabledWhenCourseNameIsEmpty() {
        app.buttons["tt.nav.addCourse"].tap()

        let field = app.textFields["editor.field.name"]
        XCTAssertTrue(field.waitForExistence(timeout: defaultTimeout), "新增课程页没有出现")

        let save = app.buttons["editor.button.save"]
        XCTAssertTrue(save.exists, "新增课程页找不到保存按钮")
        XCTAssertFalse(save.isEnabled, "课程名为空时「保存」仍可点（违反原版不落库规则）")

        // 只输入空格也应当算「空」。
        field.tap()
        field.typeText("   ")
        XCTAssertFalse(save.isEnabled, "课程名只输入空格时「保存」仍可点")

        // 收尾：取消退出，不留下任何课程。
        let cancel = app.buttons["editor.button.cancel"]
        tapWhenHittable(cancel, message: "新增课程页找不到「取消」")
    }
}

import SwiftUI

struct MenuBarContentView: View {
    @ObservedObject var appModel: AppModel

    var body: some View {
        StickyTaskBoardView(
            appModel: appModel,
            title: "Menu Note",
            subtitle: "低打扰便签，点击任务会从右侧展开"
        )
        .frame(width: 620, height: 440)
    }
}

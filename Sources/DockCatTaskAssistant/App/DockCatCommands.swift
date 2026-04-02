import SwiftUI

struct DockCatCommands: Commands {
    @ObservedObject var appModel: AppModel
    let toggleDockNote: () -> Void
    let showDashboard: () -> Void

    var body: some Commands {
        CommandGroup(replacing: .newItem) {
            Button("新建任务") {
                createTask(title: "新任务", parentTaskID: nil)
            }
            .keyboardShortcut("n", modifiers: [.command])

            Button("新建子任务") {
                createTask(title: "新的子任务", parentTaskID: appModel.currentTask?.id)
            }
            .keyboardShortcut("n", modifiers: [.command, .shift])
            .disabled(appModel.currentTask == nil)
        }

        CommandGroup(after: .undoRedo) {
            EmptyView()
        }

        CommandGroup(after: .pasteboard) {
            EmptyView()
        }

        CommandMenu("任务") {
            Button("显示主页面") {
                showDashboard()
            }
            .keyboardShortcut("0", modifiers: [.command])

            Button("切换 Dock Note") {
                toggleDockNote()
            }
            .keyboardShortcut("d", modifiers: [.command, .option])

            Divider()

            Button("开始当前任务") {
                appModel.startCurrentTask()
            }
            .keyboardShortcut(.return, modifiers: [.command])
            .disabled(appModel.currentTask == nil)

            Button("暂停当前任务") {
                appModel.pauseCurrentTask()
            }
            .keyboardShortcut(.return, modifiers: [.command, .shift])
            .disabled(appModel.currentTask == nil)

            Button("完成当前任务") {
                appModel.completeCurrentTask()
            }
            .keyboardShortcut(.return, modifiers: [.command, .option])
            .disabled(appModel.currentTask == nil)

            Divider()

            Button("删除任务") {
                if let taskID = appModel.currentTask?.id {
                    appModel.archiveTask(id: taskID)
                }
            }
            .keyboardShortcut(.delete, modifiers: [.command])
            .disabled(appModel.currentTask == nil)

            Button("提升任务") {
                if let taskID = appModel.currentTask?.id {
                    appModel.outdentTask(id: taskID)
                }
            }
            .keyboardShortcut("[", modifiers: [.command])
            .disabled(appModel.currentTask == nil)

            Button("降级任务") {
                if let taskID = appModel.currentTask?.id {
                    appModel.indentTask(id: taskID)
                }
            }
            .keyboardShortcut("]", modifiers: [.command])
            .disabled(appModel.currentTask == nil)

            Divider()

            Button(appModel.snapshot.preferences.lowDistractionMode ? "关闭低打扰模式" : "开启低打扰模式") {
                appModel.toggleLowDistractionMode()
            }
            .keyboardShortcut("l", modifiers: [.command, .shift])
        }
    }

    private func createTask(title: String, parentTaskID: UUID?) {
        guard let taskID = appModel.addTask(
            title: title,
            parentTaskID: parentTaskID,
            promptForPriority: true
        ) else { return }
        if parentTaskID == nil {
            appModel.setCurrentTask(id: taskID)
        }
        showDashboard()
    }
}

import SwiftUI
import UniformTypeIdentifiers
import ListoEngine

/// Makes a task row a drop target: hovering shows where the dragged task
/// would land (a line above or below the row, or an outline when it would
/// nest under it), dropping moves it there. Section-level drops (onto a
/// column or heading) still move a task to the end of that section.
private struct TaskDropTarget: ViewModifier {
    @ObservedObject var controller: DocumentController
    let task: ListoTask
    /// The row has subtasks drawn right under it.
    let showsSubtasks: Bool
    @State private var placement: DropPlacement?
    @State private var size: CGSize = .zero

    func body(content: Content) -> some View {
        content
            .background(GeometryReader { geo in
                Color.clear
                    .onAppear { size = geo.size }
                    .onChange(of: geo.size) { _, new in size = new }
            })
            .overlay { indicator.allowsHitTesting(false) }
            .onDrop(of: [.plainText], delegate: TaskDropDelegate(
                controller: controller,
                target: task,
                showsSubtasks: showsSubtasks,
                size: size,
                placement: $placement
            ))
    }

    @ViewBuilder
    private var indicator: some View {
        switch placement {
        case .before:
            VStack { line; Spacer(minLength: 0) }
        case .after:
            VStack { Spacer(minLength: 0); line }
        case .asSubtask:
            RoundedRectangle(cornerRadius: 5)
                .strokeBorder(Color.accentColor, lineWidth: 2)
        case nil:
            EmptyView()
        }
    }

    private var line: some View {
        Capsule().fill(Color.accentColor).frame(height: 3)
    }
}

private struct TaskDropDelegate: DropDelegate {
    let controller: DocumentController
    let target: ListoTask
    let showsSubtasks: Bool
    let size: CGSize
    @Binding var placement: DropPlacement?

    private func resolve(at location: CGPoint) -> DropPlacement? {
        guard let id = controller.draggingTaskID,
              let dragged = controller.document.allTasksRecursive.first(where: { $0.id == id }),
              size.height > 0
        else { return nil }
        return DropRule.placement(
            dragged: dragged,
            target: target,
            in: controller.document,
            fraction: min(max(location.y / size.height, 0), 1),
            targetShowsSubtasks: showsSubtasks
        )
    }

    func validateDrop(info: DropInfo) -> Bool {
        info.hasItemsConforming(to: [.plainText]) && resolve(at: info.location) != nil
    }

    func dropEntered(info: DropInfo) { placement = resolve(at: info.location) }

    func dropUpdated(info: DropInfo) -> DropProposal? {
        placement = resolve(at: info.location)
        return DropProposal(operation: placement == nil ? .forbidden : .move)
    }

    func dropExited(info: DropInfo) { placement = nil }

    func performDrop(info: DropInfo) -> Bool {
        defer { placement = nil; controller.draggingTaskID = nil }
        guard let placement, let draggedID = controller.draggingTaskID else { return false }
        controller.drop(taskID: draggedID, onto: target.id, placement: placement)
        return true
    }
}

extension View {
    /// Row-level drag source and drop target for a task (see `TaskDropTarget`).
    func taskDragAndDrop(controller: DocumentController, task: ListoTask, showsSubtasks: Bool) -> some View {
        self
            .onDrag {
                controller.draggingTaskID = task.id
                return NSItemProvider(object: task.id.uuidString as NSString)
            }
            .modifier(TaskDropTarget(controller: controller, task: task, showsSubtasks: showsSubtasks))
    }
}

@main
enum CombinedChecks {
    static func main() throws {
        try BoardChecks.main()
        try ToolChecks.main()
        try InkReasoningChecks.main()
        try ChainToolChecks.main()
        AnnotationOverlayChecks.main()
        try ReplayRecordingChecks.main()
        try ReplayWorkbenchChecks.main()
        try NativeStorageChecks.main()
        try WorkspaceChecks.main()
        try WorkspaceSharingChecks.run()
        try FilterOptionsChecks.run()
    }
}

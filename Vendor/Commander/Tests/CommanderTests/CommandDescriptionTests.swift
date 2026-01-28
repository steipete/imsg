import Commander
import Testing

@MainActor
private struct SampleRootCommand: ParsableCommand {
    static let commandDescription = CommandDescription(
        commandName: "sample",
        abstract: "Sample command",
        discussion: "Used for verifying Commander metadata",
        version: "1.0",
        subcommands: [SampleSubcommand.self],
        defaultSubcommand: SampleSubcommand.self)
}

@MainActor
private struct SampleSubcommand: ParsableCommand {
    static let commandDescription = CommandDescription(
        commandName: "child",
        abstract: "Child command")
}

@Suite("CommandDescription")
struct CommandDescriptionTests {
    #if !os(Linux)
    @Test("Defaults to empty values")
    func defaultValues() {
        let description = CommandDescription()
        #expect(description.commandName == nil)
        #expect(description.abstract.isEmpty)
        #expect(description.discussion == nil)
        #expect(description.subcommands.isEmpty)
        #expect(description.defaultSubcommand == nil)
    }
    #endif

    @Test("Builder returns captured metadata")
    func builderCapturesValues() {
        let built = MainActorCommandDescription.describe {
            CommandDescription(commandName: "capture", abstract: "Captured")
        }
        #expect(built.commandName == "capture")
        #expect(built.abstract == "Captured")
    }

    @Test("Commands expose metadata without configuration shim")
    func commandMetadataIsAvailable() async {
        let description = await MainActor.run {
            SampleRootCommand.commandDescription
        }
        #expect(description.commandName == "sample")
        #expect(description.subcommands.count == 1)
        #expect(description.defaultSubcommand.map { $0 == SampleSubcommand.self } == true)
    }
}

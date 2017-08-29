import Foundation
import SwiftCLI

CLI.setup(name: "ice")

CLI.register(commands: [
    AddCommand(),
    BuildCommand(),
    CleanCommand(),
    DependCommand(),
    DescribeCommand(),
    InitCommand(),
    TargetCommand(),
    NewCommand(),
    RemoveCommand(),
    RunCommand(),
    SearchCommand(),
    TestCommand(),
    UpgradeCommand(),
    XcCommand()
])

exit(CLI.go())

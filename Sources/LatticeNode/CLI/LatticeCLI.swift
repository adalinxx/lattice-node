import ArgumentParser

@main
struct LatticeCLI: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "lattice-node",
        abstract: "The Lattice blockchain node",
        version: "0.1.0",
        subcommands: [
            NodeCommand.self,
            SendCommand.self,
            DevnetCommand.self,
            ClusterCommand.self,
            KeysCommand.self,
            StatusCommand.self,
            QueryCommand.self,
            InitCommand.self,
            DiagCommand.self,
            IdentityCommand.self,
            FaucetCommand.self,
        ],
        defaultSubcommand: NodeCommand.self
    )
}

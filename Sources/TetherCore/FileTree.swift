import Foundation

/// One entry in the Files panel. `path` is relative to the worktree root.
public struct FileTreeNode: Hashable, Sendable, Identifiable {
    public var name: String
    public var path: String
    public var isDirectory: Bool
    public var children: [FileTreeNode]

    public var id: String { path }

    public init(name: String, path: String, isDirectory: Bool, children: [FileTreeNode] = []) {
        self.name = name
        self.path = path
        self.isDirectory = isDirectory
        self.children = children
    }
}

/// A node as the panel draws it: flattened, with its indent.
public struct FileTreeRow: Hashable, Sendable, Identifiable {
    public var node: FileTreeNode
    public var depth: Int

    public var id: String { node.path }
}

/// The worktree's files as a tree. In a git repository the list comes from
/// `git ls-files`, so ignored files (node_modules, build output) stay out
/// the same way they do in `git status`.
public enum FileTree {
    /// Files git would show: tracked plus untracked-but-not-ignored.
    public static let lsFilesArguments = ["ls-files", "-z", "--cached", "--others", "--exclude-standard"]

    /// Folders skipped when the worktree isn't a git repository.
    static let skippedFolders: Set<String> = [".git", "node_modules", ".build", "DerivedData", "Pods", ".venv", "__pycache__"]

    /// Relative paths of the worktree's files. Tracked files deleted from
    /// disk are left out. Falls back to walking the folder outside git.
    public static func list(in worktreePath: String, runner: GitRunner = GitRunner(),
                            limit: Int = 50_000) async throws -> [String] {
        let output: GitOutput
        do {
            output = try await runner.run(lsFilesArguments, in: worktreePath)
        } catch GitError.notARepository {
            return walk(worktreePath, limit: limit)
        }
        let fm = FileManager.default
        let root = URL(fileURLWithPath: worktreePath)
        return Array(parseLsFiles(output.stdout).prefix(limit)).filter {
            fm.fileExists(atPath: root.appendingPathComponent($0).path)
        }
    }

    /// NUL-separated paths, in order, without duplicates (an unmerged file
    /// is listed once per stage).
    public static func parseLsFiles(_ data: Data) -> [String] {
        var seen: Set<String> = []
        var paths: [String] = []
        for chunk in data.split(separator: 0) {
            let path = String(decoding: chunk, as: UTF8.self)
            if !path.isEmpty, seen.insert(path).inserted { paths.append(path) }
        }
        return paths
    }

    static func walk(_ worktreePath: String, limit: Int) -> [String] {
        // Relative paths, so a symlinked folder (macOS /var) can't skew them.
        guard let enumerator = FileManager.default.enumerator(atPath: worktreePath) else { return [] }
        var paths: [String] = []
        while let path = enumerator.nextObject() as? String, paths.count < limit {
            if enumerator.fileAttributes?[.type] as? FileAttributeType == .typeDirectory {
                if skippedFolders.contains((path as NSString).lastPathComponent) { enumerator.skipDescendants() }
                continue
            }
            paths.append(path)
        }
        return paths
    }

    /// Folders first, then files, each sorted case-insensitively, the way
    /// Finder and the screenshots order them.
    public static func build(paths: [String]) -> [FileTreeNode] {
        build(paths.map { $0.split(separator: "/").map(String.init) }.filter { !$0.isEmpty }, prefix: "")
    }

    private static func build(_ entries: [[String]], prefix: String) -> [FileTreeNode] {
        var files: Set<String> = []
        var folders: [String: [[String]]] = [:]
        for parts in entries {
            if parts.count == 1 {
                files.insert(parts[0])
            } else {
                folders[parts[0], default: []].append(Array(parts.dropFirst()))
            }
        }
        let folderNodes = folders.map { name, rest in
            FileTreeNode(name: name, path: prefix + name, isDirectory: true,
                         children: build(rest, prefix: prefix + name + "/"))
        }
        let fileNodes = files.filter { folders[$0] == nil }.map {
            FileTreeNode(name: $0, path: prefix + $0, isDirectory: false)
        }
        return folderNodes.sorted(by: inOrder) + fileNodes.sorted(by: inOrder)
    }

    static func inOrder(_ a: FileTreeNode, _ b: FileTreeNode) -> Bool {
        let (la, lb) = (a.name.lowercased(), b.name.lowercased())
        return la == lb ? a.name < b.name : la < lb
    }

    /// Keeps files whose path contains every word of `query`, with the folders
    /// that lead to them. A blank query keeps everything.
    public static func filter(_ nodes: [FileTreeNode], query: String) -> [FileTreeNode] {
        let words = query.lowercased().split(whereSeparator: \.isWhitespace).map(String.init)
        guard !words.isEmpty else { return nodes }
        return filter(nodes, words: words)
    }

    private static func filter(_ nodes: [FileTreeNode], words: [String]) -> [FileTreeNode] {
        nodes.compactMap { node in
            if node.isDirectory {
                let kept = filter(node.children, words: words)
                guard !kept.isEmpty else { return nil }
                var copy = node
                copy.children = kept
                return copy
            }
            let path = node.path.lowercased()
            return words.allSatisfy { path.contains($0) } ? node : nil
        }
    }

    /// The rows on screen: children of expanded folders follow their folder.
    /// `expandAll` opens every folder, for filter results.
    public static func rows(_ nodes: [FileTreeNode], expanded: Set<String>, expandAll: Bool = false,
                            depth: Int = 0) -> [FileTreeRow] {
        var result: [FileTreeRow] = []
        for node in nodes {
            result.append(FileTreeRow(node: node, depth: depth))
            if node.isDirectory, expandAll || expanded.contains(node.path) {
                result += rows(node.children, expanded: expanded, expandAll: expandAll, depth: depth + 1)
            }
        }
        return result
    }
}

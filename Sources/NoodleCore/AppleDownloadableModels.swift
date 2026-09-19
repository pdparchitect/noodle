import Foundation

/// Reviewed text/tool checkpoints. Pin revisions and hashes so upstream changes
/// cannot silently change what a model downloads. No Hub code is run.
public struct AppleDownloadableModel: Identifiable, Sendable {
    public var id: String { repository }
    public let name: String
    /// One line on what the model is good for and the memory it suits.
    public let summary: String
    /// Physical memory, in GiB, the model runs comfortably with.
    public let memory: Int
    public let repository: String
    public let revision: String
    let files: [File]

    public var byteCount: Int64 { files.reduce(0) { $0 + $1.byteCount } }
    public var sourceURL: URL { URL(string: "https://huggingface.co/\(repository)")! }

    struct File: Sendable {
        let name: String
        let byteCount: Int64
        let digest: Digest
    }

    enum Digest: Sendable {
        case sha256(String)
        case gitSHA1(String)
    }

    /// The most capable model that runs comfortably in this much physical memory.
    public static func recommended(forPhysicalMemory bytes: UInt64 = ProcessInfo.processInfo.physicalMemory) -> Self? {
        available.last { UInt64($0.memory) << 30 <= bytes }
    }

    /// Listed smallest first, so capability and memory needs rise down the list.
    public static let available: [Self] = [
        .init(name: "Qwen3 1.7B", summary: "Smallest and fastest. Handles simple tool calls when memory is tight.", memory: 0,
              repository: "mlx-community/Qwen3-1.7B-4bit",
              revision: "3b1b1768f8f8cf8351c712464f906e86c2b8269e", files: [
                .init(name: "special_tokens_map.json", byteCount: 613, digest: .gitSHA1("ac23c0aaa2434523c494330aeb79c58395378103")),
                .init(name: "added_tokens.json", byteCount: 707, digest: .gitSHA1("b54f9135e44c1e81047e8d05cb027af8bc039eed")),
                .init(name: "config.json", byteCount: 937, digest: .gitSHA1("0a78ffc3980b062021a450199988d0ed8537239d")),
                .init(name: "tokenizer_config.json", byteCount: 9706, digest: .gitSHA1("7345216a0785dc7086e8c245b2a9d3896ce2b756")),
                .init(name: "model.safetensors.index.json", byteCount: 49731, digest: .gitSHA1("8607d041b6549c15a4db85e7b4c5cf30d3ab890a")),
                .init(name: "merges.txt", byteCount: 1671853, digest: .gitSHA1("31349551d90c7606f325fe0f11bbb8bd5fa0d7c7")),
                .init(name: "vocab.json", byteCount: 2776833, digest: .gitSHA1("4783fe10ac3adce15ac8f358ef5462739852c569")),
                .init(name: "tokenizer.json", byteCount: 11422654, digest: .sha256("aeb13307a71acd8fe81861d94ad54ab689df773318809eed3cbe794b4492dae4")),
                .init(name: "model.safetensors", byteCount: 968080210, digest: .sha256("0e86d9677e519323849eac1bc272caae88567a481ff188c431f70be543d9995f")),
              ]),
        .init(name: "Qwen3 4B Instruct", summary: "Answers directly without thinking first. Reliable tool calls; suits 8 GB of memory.", memory: 8,
              repository: "mlx-community/Qwen3-4B-Instruct-2507-4bit",
              revision: "50d427756c6b1b2fe0c0a10f67fbda1fc8e82c1b", files: [
                .init(name: "generation_config.json", byteCount: 238, digest: .gitSHA1("432531a002c181a19de338313d2375e9d7494d7e")),
                .init(name: "special_tokens_map.json", byteCount: 613, digest: .gitSHA1("ac23c0aaa2434523c494330aeb79c58395378103")),
                .init(name: "added_tokens.json", byteCount: 707, digest: .gitSHA1("b54f9135e44c1e81047e8d05cb027af8bc039eed")),
                .init(name: "config.json", byteCount: 938, digest: .gitSHA1("ce8b8eccd1cdf6d8a30767f58e8ff858dd15eab5")),
                .init(name: "chat_template.jinja", byteCount: 4040, digest: .gitSHA1("a18870ad4ba26ac6c43758fc506c1bb6ff206bb4")),
                .init(name: "tokenizer_config.json", byteCount: 5440, digest: .gitSHA1("474bbcd82077828bdec32b8dbc1826cdff2a792a")),
                .init(name: "model.safetensors.index.json", byteCount: 63964, digest: .gitSHA1("4741a210f9920c2949ca73bbb2a7ce9583e7fd83")),
                .init(name: "merges.txt", byteCount: 1671853, digest: .gitSHA1("31349551d90c7606f325fe0f11bbb8bd5fa0d7c7")),
                .init(name: "vocab.json", byteCount: 2776833, digest: .gitSHA1("4783fe10ac3adce15ac8f358ef5462739852c569")),
                .init(name: "tokenizer.json", byteCount: 11422654, digest: .sha256("aeb13307a71acd8fe81861d94ad54ab689df773318809eed3cbe794b4492dae4")),
                .init(name: "model.safetensors", byteCount: 2263022417, digest: .sha256("2a73c6c248601ab904e035548abd8e6abb65ea27dcb5f342fb0a8910eb44173f")),
              ]),
        .init(name: "Qwen3 8B", summary: "Thinks before answering, for steadier multi-step tool use. Best with 16 GB of memory.", memory: 16,
              repository: "mlx-community/Qwen3-8B-4bit",
              revision: "545dc4251c05440727734bcd94334791f6ab0192", files: [
                .init(name: "special_tokens_map.json", byteCount: 613, digest: .gitSHA1("ac23c0aaa2434523c494330aeb79c58395378103")),
                .init(name: "added_tokens.json", byteCount: 707, digest: .gitSHA1("b54f9135e44c1e81047e8d05cb027af8bc039eed")),
                .init(name: "config.json", byteCount: 939, digest: .gitSHA1("6f2a32b76648381bea25bdc81fad0e7160f86ac5")),
                .init(name: "tokenizer_config.json", byteCount: 9706, digest: .gitSHA1("7345216a0785dc7086e8c245b2a9d3896ce2b756")),
                .init(name: "model.safetensors.index.json", byteCount: 64065, digest: .gitSHA1("4af62897c345f277e7b17aab48230d7ba119d87e")),
                .init(name: "merges.txt", byteCount: 1671853, digest: .gitSHA1("31349551d90c7606f325fe0f11bbb8bd5fa0d7c7")),
                .init(name: "vocab.json", byteCount: 2776833, digest: .gitSHA1("4783fe10ac3adce15ac8f358ef5462739852c569")),
                .init(name: "tokenizer.json", byteCount: 11422654, digest: .sha256("aeb13307a71acd8fe81861d94ad54ab689df773318809eed3cbe794b4492dae4")),
                .init(name: "model.safetensors", byteCount: 4607835174, digest: .sha256("f2d29621aab300336ad645567ff38c42aac755513006ef4e8a579cf7ef5256d8")),
              ]),
        .init(name: "Qwen3 14B", summary: "Strongest reasoning and tool use in this list. Best with 24 GB of memory or more.", memory: 24,
              repository: "mlx-community/Qwen3-14B-4bit",
              revision: "a4d9b2df59d2c150bef02fcbe0d91046b7ca33a4", files: [
                .init(name: "special_tokens_map.json", byteCount: 613, digest: .gitSHA1("ac23c0aaa2434523c494330aeb79c58395378103")),
                .init(name: "added_tokens.json", byteCount: 707, digest: .gitSHA1("b54f9135e44c1e81047e8d05cb027af8bc039eed")),
                .init(name: "config.json", byteCount: 939, digest: .gitSHA1("38386939cee12ed747ace23c207f2d1f1ea111e5")),
                .init(name: "tokenizer_config.json", byteCount: 9706, digest: .gitSHA1("7345216a0785dc7086e8c245b2a9d3896ce2b756")),
                .init(name: "model.safetensors.index.json", byteCount: 86266, digest: .gitSHA1("7ca9a1b8e12ec323d0c74fb3bc3cbf8269aaabdc")),
                .init(name: "merges.txt", byteCount: 1671853, digest: .gitSHA1("31349551d90c7606f325fe0f11bbb8bd5fa0d7c7")),
                .init(name: "vocab.json", byteCount: 2776833, digest: .gitSHA1("4783fe10ac3adce15ac8f358ef5462739852c569")),
                .init(name: "tokenizer.json", byteCount: 11422654, digest: .sha256("aeb13307a71acd8fe81861d94ad54ab689df773318809eed3cbe794b4492dae4")),
                .init(name: "model-00002-of-00002.safetensors", byteCount: 2953517134, digest: .sha256("2814562d654fe2d541fd4682804a0ccaa400e79701872c8e9f5998cf9481fdf8")),
                .init(name: "model-00001-of-00002.safetensors", byteCount: 5354381380, digest: .sha256("5795efcfc7c96fd273e600562e8b111bfcc427415de9001d0a07e70cd99cff19")),
              ]),
    ]
}

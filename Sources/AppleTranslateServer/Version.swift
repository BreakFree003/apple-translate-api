import Foundation

/// 版本号。发布时和 git tag 保持一致 —— 别在多处写死。
/// `--version`（brew formula 的 test 块）和 `/health` 都读这里。
enum Version {
    static let string = "0.1.0"
}

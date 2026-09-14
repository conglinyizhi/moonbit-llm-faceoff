///| 用户数据与配置目录的默认位置。
///
/// 依据：
///   Linux 及其它 Unix    XDG Base Directory：$XDG_DATA_HOME / $XDG_CONFIG_HOME，
///                        默认 ~/.local/share 与 ~/.config
///   Windows              Known Folders：%LOCALAPPDATA% 下开一个以应用命名的目录，
///                        data 与 config 同一个基目录，不碰 roaming（那边的目录会在
///                        登录时走网络同步，只适合放很小的设置）
///   macOS                走上面 XDG 的默认值（CLI 工具的常见取舍，省掉一套平台分支）
///
/// 这里只算路径：不读文件系统，环境变量由调用方通过 `env` 传进来。所以这部分能单测，
/// 也能在 Linux 上验证 Windows 的映射对不对。

///|
/// 应用目录名。所有路径都落在 `<基目录>/faceoff` 下，不额外加作者层级。
let app_dir_name : String = "faceoff"

///|
/// 读一个环境变量，没设或设成空串都当没有。
fn env_or_empty(env : (String) -> String?, name : String) -> String {
  match env(name) {
    Some(value) => value
    None => ""
  }
}

///|
/// 把 `child` 接在 `base` 后面。
///
/// 分隔符跟着 `base` 走：base 里出现过反斜杠就用反斜杠，否则用正斜杠。这样不需要平台
/// 探测，也不会把 Windows 的 `C:\Users\me\AppData\Local` 接成 `C:/Users/...`。
/// base 结尾已经有分隔符时不再补一个。
pub fn join_child(base : String, child : String) -> String {
  if base == "" {
    return child
  }
  let sep = if base.contains("\\") { "\\" } else { "/" }
  if base.has_suffix(sep) {
    return base + child
  }
  base + sep + child
}

///|
/// 家目录：POSIX 用 `HOME`，Windows 上通常只有 `USERPROFILE`。
fn home_dir(env : (String) -> String?) -> String {
  let home = env_or_empty(env, "HOME")
  if home != "" {
    return home
  }
  env_or_empty(env, "USERPROFILE")
}

///|
/// 数据目录的基目录（不含应用名）。
fn data_base(env : (String) -> String?) -> String {
  let xdg = env_or_empty(env, "XDG_DATA_HOME")
  if xdg != "" {
    return xdg
  }
  let local_appdata = env_or_empty(env, "LOCALAPPDATA")
  if local_appdata != "" {
    return local_appdata
  }
  let home = home_dir(env)
  if home != "" {
    return join_child(home, ".local/share")
  }
  ""
}

///|
/// 配置目录的基目录（不含应用名）。Windows 上与数据目录同一个基目录。
fn config_base(env : (String) -> String?) -> String {
  let xdg = env_or_empty(env, "XDG_CONFIG_HOME")
  if xdg != "" {
    return xdg
  }
  let local_appdata = env_or_empty(env, "LOCALAPPDATA")
  if local_appdata != "" {
    return local_appdata
  }
  let home = home_dir(env)
  if home != "" {
    return join_child(home, ".config")
  }
  ""
}

///|
/// 数据目录（运行记录与测试集放在它下面）。判不出基目录时返回空串，调用方保持原样。
pub fn default_data_dir(env : (String) -> String?) -> String {
  let base = data_base(env)
  if base == "" {
    return ""
  }
  join_child(base, app_dir_name)
}

///|
/// 配置目录（预设放在它下面）。判不出基目录时返回空串。
pub fn default_config_dir(env : (String) -> String?) -> String {
  let base = config_base(env)
  if base == "" {
    return ""
  }
  join_child(base, app_dir_name)
}

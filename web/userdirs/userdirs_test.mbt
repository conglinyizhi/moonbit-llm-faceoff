///| 用户目录解析的单测。
///
/// 这些用例在 Linux 上就能验 Windows 的映射：这里只算字符串，不碰文件系统。

///|
fn lookup(pairs : Array[(String, String)], name : String) -> String? {
  for pair in pairs {
    if pair.0 == name {
      return Some(pair.1)
    }
  }
  None
}

///|
test "join_child：分隔符跟着 base 走" {
  assert_eq(join_child("/home/me", ".local/share"), "/home/me/.local/share")
  assert_eq(
    join_child("C:\\Users\\me\\AppData\\Local", "faceoff"),
    "C:\\Users\\me\\AppData\\Local\\faceoff",
  )
}

///|
test "join_child：base 结尾已有分隔符时不再补一个" {
  assert_eq(join_child("/home/me/", "faceoff"), "/home/me/faceoff")
  assert_eq(join_child("C:\\x\\", "faceoff"), "C:\\x\\faceoff")
}

///|
test "join_child：base 为空就直接返回 child" {
  assert_eq(join_child("", "faceoff"), "faceoff")
}

///|
test "数据目录：认 XDG_DATA_HOME" {
  let pairs = [("XDG_DATA_HOME", "/tmp/xdg"), ("HOME", "/home/me")]
  assert_eq(default_data_dir(fn(n) { lookup(pairs, n) }), "/tmp/xdg/faceoff")
}

///|
test "数据目录：Windows 上没有 XDG 时用 LOCALAPPDATA" {
  let pairs = [("LOCALAPPDATA", "C:\\Users\\me\\AppData\\Local")]
  assert_eq(
    default_data_dir(fn(n) { lookup(pairs, n) }),
    "C:\\Users\\me\\AppData\\Local\\faceoff",
  )
}

///|
test "数据目录：只有 HOME 时用 ~/.local/share" {
  let pairs = [("HOME", "/home/me")]
  assert_eq(
    default_data_dir(fn(n) { lookup(pairs, n) }),
    "/home/me/.local/share/faceoff",
  )
}

///|
test "数据目录：只有 USERPROFILE 时走 Unix 那条倒退" {
  // 这分支只在「像是 Windows，但没有 LOCALAPPDATA」时才会走到，实际几乎不会发生。
  // 注意反斜杠基目录会把 `.local/share` 接成 `\.local/share`，Windows 两种分隔符都认
  let pairs = [("USERPROFILE", "C:\\Users\\me")]
  assert_eq(
    default_data_dir(fn(n) { lookup(pairs, n) }),
    "C:\\Users\\me\\.local/share\\faceoff",
  )
}

///|
test "数据目录：什么都读不到时返回空串" {
  assert_eq(default_data_dir(fn(_n) { None }), "")
}

///|
test "配置目录：认 XDG_CONFIG_HOME" {
  let pairs = [("XDG_CONFIG_HOME", "/tmp/cfg"), ("HOME", "/home/me")]
  assert_eq(default_config_dir(fn(n) { lookup(pairs, n) }), "/tmp/cfg/faceoff")
}

///|
test "配置目录：Windows 上与数据目录同一个基目录" {
  let pairs = [("LOCALAPPDATA", "C:\\Users\\me\\AppData\\Local")]
  assert_eq(
    default_config_dir(fn(n) { lookup(pairs, n) }),
    "C:\\Users\\me\\AppData\\Local\\faceoff",
  )
}

///|
test "配置目录：只有 HOME 时用 ~/.config" {
  let pairs = [("HOME", "/home/me")]
  assert_eq(
    default_config_dir(fn(n) { lookup(pairs, n) }),
    "/home/me/.config/faceoff",
  )
}

///|
test "配置目录：什么都读不到时返回空串" {
  assert_eq(default_config_dir(fn(_n) { None }), "")
}
